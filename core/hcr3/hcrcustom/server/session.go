package server

import (
	"crypto/rand"
	"crypto/subtle"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"

	"github.com/hcrcustom/hcrcustom/protocol"
)

const (
	maxUploadWindow       = 256
	maxUploadPendingBytes = 2 << 20
	maxReplayBytes        = 8 << 20
	calibrationTTL        = 8 * time.Second
)

var (
	ErrSessionClosed      = errors.New("session closed")
	ErrUploadBackpressure = errors.New("upload buffer limit exceeded")
	ErrPollWindow         = errors.New("poll sequence outside active window")
)

type SessionStats struct {
	ID            [16]byte
	ClientIP      string
	UploadNext    uint64
	UploadPending int
	PendingBytes  int
	TargetWritten uint64
	DownloadNext  uint64
	DeliveryBase  uint64
	Acked         uint64
	HasAck        bool
	ReplayBytes   int
	TargetRead    uint64
	Closed        bool
}

type Session struct {
	id               [16]byte
	token            [32]byte
	clientIP         string
	target           net.Conn
	maxDownloadFrame uint32
	pollUnits        uint16
	isCalibration    bool
	calibMode        uint8
	calibTotalBytes  uint32

	mu              sync.Mutex
	notifyCh        chan struct{}
	lastActive      time.Time
	uploadNext      uint64
	uploadPending   map[uint64][]byte
	pendingBytes    int
	targetWritten   uint64
	downloadNext    uint64
	downloadBase    uint64
	deliveredBitmap [16]uint64
	replayMap       map[uint64][]byte
	replayBytes     int
	lastAck         uint64
	hasAck          bool
	targetRead      uint64
	targetEOF       bool
	targetErr       error
	closed          bool
}

func newSession(id [16]byte, clientIP string, target net.Conn, maxFrame uint32, pollUnits uint16) (*Session, error) {
	var token [32]byte
	if _, err := rand.Read(token[:]); err != nil {
		return nil, err
	}
	if maxFrame == 0 || maxFrame > protocol.MaxDownloadFrame {
		maxFrame = protocol.DefaultDownloadFrame
	}
	if pollUnits < protocol.DefaultPollUnits || pollUnits > protocol.MaxPollUnits {
		pollUnits = protocol.DefaultPollUnits
	}
	s := &Session{
		id:               id,
		token:            token,
		clientIP:         clientIP,
		target:           target,
		maxDownloadFrame: maxFrame,
		pollUnits:        pollUnits,
		notifyCh:         make(chan struct{}),
		lastActive:       time.Now(),
		uploadPending:    make(map[uint64][]byte),
		replayMap:        make(map[uint64][]byte),
	}
	if target != nil {
		go s.readTargetLoop()
	}
	return s, nil
}

func newCalibrationSession(id [16]byte, clientIP string, cfg protocol.CalibrationConfig, defaultMaxFrame uint32) (*Session, error) {
	effFrame := cfg.MaxFrame
	if effFrame == 0 {
		effFrame = defaultMaxFrame
	}
	if effFrame == 0 || effFrame > protocol.MaxDownloadFrame {
		effFrame = protocol.DefaultDownloadFrame
	}
	s, err := newSession(id, clientIP, nil, effFrame, cfg.PollUnits)
	if err != nil {
		return nil, err
	}
	s.isCalibration = true
	s.calibMode = cfg.Mode
	s.calibTotalBytes = cfg.TotalBytes

	if cfg.Mode == protocol.CalibrationDownload {
		rem := int(cfg.TotalBytes)
		step := int(effFrame)
		offset := 0
		for rem > 0 {
			n := step
			if rem < n {
				n = rem
			}
			chunk := make([]byte, n)
			for i := 0; i < n; i++ {
				chunk[i] = protocol.CalibrationByte(id, offset+i)
			}
			s.appendDownloadChunkLocked(chunk)
			offset += n
			rem -= n
		}
		s.targetEOF = true
	}
	return s, nil
}

func (s *Session) Token() [32]byte          { return s.token }
func (s *Session) MaxDownloadFrame() uint32 { return s.maxDownloadFrame }
func (s *Session) PollUnits() uint16        { return s.pollUnits }
func (s *Session) ClientIP() string         { return s.clientIP }

func (s *Session) ValidateToken(tok [32]byte) bool {
	return subtle.ConstantTimeCompare(s.token[:], tok[:]) == 1
}

func (s *Session) touchLocked() {
	s.lastActive = time.Now()
}

func (s *Session) broadcastLocked() {
	close(s.notifyCh)
	s.notifyCh = make(chan struct{})
}

func (s *Session) appendDownloadChunkLocked(chunk []byte) {
	seq := s.downloadNext
	s.downloadNext++
	s.replayMap[seq] = chunk
	s.replayBytes += len(chunk)
	s.targetRead += uint64(len(chunk))
}

func (s *Session) readTargetLoop() {
	buf := make([]byte, s.maxDownloadFrame)
	for {
		n, err := s.target.Read(buf)
		if n > 0 {
			chunk := make([]byte, n)
			copy(chunk, buf[:n])

			s.mu.Lock()
			for !s.closed && s.replayBytes+len(chunk) > maxReplayBytes {
				ch := s.notifyCh
				s.mu.Unlock()
				<-ch
				s.mu.Lock()
			}
			if s.closed {
				s.mu.Unlock()
				return
			}
			s.appendDownloadChunkLocked(chunk)
			s.broadcastLocked()
			s.mu.Unlock()
		}
		if err != nil {
			s.mu.Lock()
			s.targetEOF = true
			if !errors.Is(err, io.EOF) {
				s.targetErr = err
			}
			s.broadcastLocked()
			s.mu.Unlock()
			return
		}
	}
}

func (s *Session) Upload(seq uint64, payload []byte) (uint64, error) {
	if len(payload) == 0 {
		return 0, errors.New("empty upload payload")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return s.uploadNext, ErrSessionClosed
	}
	s.touchLocked()

	if seq < s.uploadNext {
		return s.uploadNext, nil
	}

	if seq > s.uploadNext {
		if seq-s.uploadNext > maxUploadWindow {
			return s.uploadNext, ErrUploadBackpressure
		}
		if _, exists := s.uploadPending[seq]; !exists {
			if s.pendingBytes+len(payload) > maxUploadPendingBytes {
				return s.uploadNext, ErrUploadBackpressure
			}
			cp := make([]byte, len(payload))
			copy(cp, payload)
			s.uploadPending[seq] = cp
			s.pendingBytes += len(cp)
		}
		return s.uploadNext, nil
	}

	var toWrite [][]byte
	toWrite = append(toWrite, payload)
	s.uploadNext++
	for {
		nextBuf, ok := s.uploadPending[s.uploadNext]
		if !ok {
			break
		}
		delete(s.uploadPending, s.uploadNext)
		s.pendingBytes -= len(nextBuf)
		toWrite = append(toWrite, nextBuf)
		s.uploadNext++
	}
	nextSeq := s.uploadNext

	if s.isCalibration {
		if s.calibMode != protocol.CalibrationUpload {
			return nextSeq, errors.New("calibration session does not accept uploads")
		}
		for _, b := range toWrite {
			if s.targetWritten+uint64(len(b)) > uint64(s.calibTotalBytes) {
				return nextSeq, errors.New("calibration upload exceeds total bytes")
			}
			base := int(s.targetWritten)
			for i, v := range b {
				if v != protocol.CalibrationByte(s.id, base+i) {
					return nextSeq, errors.New("calibration upload byte mismatch")
				}
			}
			s.targetWritten += uint64(len(b))
		}
		return nextSeq, nil
	}

	target := s.target
	s.mu.Unlock()
	var writeErr error
	var written uint64
	for _, b := range toWrite {
		n, err := target.Write(b)
		written += uint64(n)
		if err != nil {
			writeErr = err
			break
		}
	}
	s.mu.Lock()
	s.targetWritten += written
	if writeErr != nil {
		return s.uploadNext, writeErr
	}
	return s.uploadNext, nil
}

func (s *Session) markDeliveredLocked(seq uint64, count int) {
	for i := 0; i < count; i++ {
		cur := seq + uint64(i)
		if cur < s.downloadBase {
			continue
		}
		rel := cur - s.downloadBase
		if rel >= protocol.MaxPollUnits {
			continue
		}
		s.deliveredBitmap[rel/64] |= 1 << (rel % 64)
	}
	s.advanceDownloadBaseLocked()
}

func (s *Session) advanceDownloadBaseLocked() {
	for (s.deliveredBitmap[0] & 1) != 0 {
		s.downloadBase++
		for w := 0; w < 15; w++ {
			s.deliveredBitmap[w] = (s.deliveredBitmap[w] >> 1) | (s.deliveredBitmap[w+1] << 63)
		}
		s.deliveredBitmap[15] >>= 1
	}
}

func (s *Session) Poll(seq uint64, maxChunks uint16, timeout time.Duration) (status uint8, rseq uint64, payload []byte, err error) {
	if maxChunks == 0 {
		maxChunks = 1
	}
	if maxChunks > protocol.MaxPollBatch {
		maxChunks = protocol.MaxPollBatch
	}

	deadline := time.Now().Add(timeout)
	var timer *time.Timer
	defer func() {
		if timer != nil {
			timer.Stop()
		}
	}()

	s.mu.Lock()
	defer s.mu.Unlock()
	s.touchLocked()

	for {
		if s.closed {
			return protocol.StatusClosed, seq, nil, nil
		}

		if s.hasAck && seq <= s.lastAck {
			return protocol.StatusError, seq, nil, ErrPollWindow
		}

		if first, ok := s.replayMap[seq]; ok {

			chunks := make([][]byte, 0, maxChunks)
			chunks = append(chunks, first)
			totalBytes := 4 + len(first)
			for k := uint16(1); k < maxChunks; k++ {
				nxt, ok := s.replayMap[seq+uint64(k)]
				if !ok {
					break
				}
				if totalBytes+4+len(nxt) > protocol.MaxPayloadSize {
					break
				}
				chunks = append(chunks, nxt)
				totalBytes += 4 + len(nxt)
			}
			s.markDeliveredLocked(seq, len(chunks))
			s.broadcastLocked()
			return protocol.StatusData, seq, protocol.PackDownloadChunks(chunks), nil
		}

		if s.targetEOF && seq >= s.downloadNext {

			if s.downloadNext == 0 || (s.hasAck && s.lastAck+1 >= s.downloadNext) || seq == s.downloadBase {
				return protocol.StatusClosed, seq, nil, nil
			}
		}

		if seq >= s.downloadBase+uint64(s.pollUnits) {
			return protocol.StatusError, seq, nil, fmt.Errorf("%w: seq=%d window=[%d,%d)", ErrPollWindow, seq, s.downloadBase, s.downloadBase+uint64(s.pollUnits))
		}

		rem := time.Until(deadline)
		if rem <= 0 {
			return protocol.StatusNoData, seq, nil, nil
		}
		if timer == nil {
			timer = time.NewTimer(rem)
		} else {
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer.Reset(rem)
		}
		ch := s.notifyCh
		s.mu.Unlock()
		select {
		case <-ch:
		case <-timer.C:
			s.mu.Lock()
			return protocol.StatusNoData, seq, nil, nil
		}
		s.mu.Lock()
	}
}

func (s *Session) Acknowledge(seq uint64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return ErrSessionClosed
	}
	s.touchLocked()
	if seq >= s.downloadNext {
		return fmt.Errorf("ack seq %d exceeds produced chunks %d", seq, s.downloadNext)
	}
	if !s.hasAck || seq > s.lastAck {
		start := uint64(0)
		if s.hasAck {
			start = s.lastAck + 1
		}
		for i := start; i <= seq; i++ {
			if chunk, ok := s.replayMap[i]; ok {
				delete(s.replayMap, i)
				s.replayBytes -= len(chunk)
			}
		}
		s.lastAck = seq
		s.hasAck = true
		if s.downloadBase <= seq {
			s.markDeliveredLocked(s.downloadBase, int(seq-s.downloadBase+1))
		}
		s.broadcastLocked()
	}
	return nil
}

func (s *Session) IsClosed() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.closed
}

func (s *Session) Close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	target := s.target
	s.replayMap = nil
	s.uploadPending = nil
	s.replayBytes = 0
	s.pendingBytes = 0
	s.broadcastLocked()
	s.mu.Unlock()
	if target != nil {
		_ = target.Close()
	}
}

func (s *Session) Stats() SessionStats {
	s.mu.Lock()
	defer s.mu.Unlock()
	return SessionStats{
		ID:            s.id,
		ClientIP:      s.clientIP,
		UploadNext:    s.uploadNext,
		UploadPending: len(s.uploadPending),
		PendingBytes:  s.pendingBytes,
		TargetWritten: s.targetWritten,
		DownloadNext:  s.downloadNext,
		DeliveryBase:  s.downloadBase,
		Acked:         s.lastAck,
		HasAck:        s.hasAck,
		ReplayBytes:   s.replayBytes,
		TargetRead:    s.targetRead,
		Closed:        s.closed,
	}
}
