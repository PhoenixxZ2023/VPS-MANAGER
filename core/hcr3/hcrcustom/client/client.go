package client

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"

	"github.com/hcrcustom/hcrcustom/protocol"
)

const (
	defaultDialTimeout    = 10 * time.Second
	defaultRequestTimeout = 35 * time.Second
	defaultUploadChunk    = 32768
	defaultPollWorkers    = 32
	defaultSlotChunks     = 8
)

type Config struct {
	ServerAddr       string
	TLS              bool
	TLSConfig        *tls.Config
	MaxDownloadFrame uint32
	PollUnits        uint16
	PollWorkers      int
	SlotChunks       uint16
	MaxUploadChunk   int
	DialTimeout      time.Duration
	RequestTimeout   time.Duration
	DialContext      func(ctx context.Context, network, addr string) (net.Conn, error)
}

func (c *Config) setDefaults() {
	if c.PollUnits == 0 {
		c.PollUnits = protocol.DefaultPollUnits
	}
	if c.SlotChunks == 0 {
		c.SlotChunks = defaultSlotChunks
	}
	if c.PollWorkers <= 0 {
		c.PollWorkers = int(c.PollUnits / c.SlotChunks)
		if c.PollWorkers <= 0 {
			c.PollWorkers = 1
		}
		if c.PollWorkers > defaultPollWorkers {
			c.PollWorkers = defaultPollWorkers
		}
	}
	if c.MaxUploadChunk <= 0 || c.MaxUploadChunk > protocol.MaxPayloadSize {
		c.MaxUploadChunk = defaultUploadChunk
	}
	if c.DialTimeout <= 0 {
		c.DialTimeout = defaultDialTimeout
	}
	if c.RequestTimeout <= 0 {
		c.RequestTimeout = defaultRequestTimeout
	}
}

type Conn struct {
	cfg              Config
	sessionID        [16]byte
	token            [32]byte
	maxDownloadFrame uint32
	pollUnits        uint16

	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup

	writeMu   sync.Mutex
	uploadSeq uint64

	recvMu       sync.Mutex
	recvCond     *sync.Cond
	recvChunks   map[uint64][]byte
	recvNext     uint64
	nextSlotSeq  uint64
	readBuf      bytes.Buffer
	remoteEOF    bool
	recvErr      error
	readDeadline time.Time
	closed       bool

	ackCh     chan uint64
	lastAcked uint64
	hasAcked  bool
	closeOnce sync.Once
}

func Dial(ctx context.Context, cfg Config) (*Conn, error) {
	cfg.setDefaults()
	sessionID, err := newSessionID()
	if err != nil {
		return nil, err
	}
	helloPayload, err := protocol.EncodeHelloRequest(protocol.HelloOptions{
		MaxDownloadFrame: cfg.MaxDownloadFrame,
		PollUnits:        cfg.PollUnits,
	})
	if err != nil {
		return nil, err
	}

	cctx, cancel := context.WithCancel(context.Background())
	c := &Conn{
		cfg:        cfg,
		sessionID:  sessionID,
		ctx:        cctx,
		cancel:     cancel,
		recvChunks: make(map[uint64][]byte),
		ackCh:      make(chan uint64, 1),
	}
	c.recvCond = sync.NewCond(&c.recvMu)

	resp, err := c.doRequest(ctx, &protocol.Request{
		Op:        protocol.OpHello,
		Version:   protocol.Version,
		SessionID: sessionID,
		Seq:       0,
		Payload:   helloPayload,
	})
	if err != nil {
		cancel()
		return nil, err
	}
	if resp.Status != protocol.StatusOK {
		cancel()
		return nil, fmt.Errorf("hello failed with status %d: %s", resp.Status, string(resp.Payload))
	}
	token, opts, err := protocol.DecodeHelloResponse(resp.Payload)
	if err != nil {
		cancel()
		return nil, err
	}
	c.token = token
	c.maxDownloadFrame = opts.MaxDownloadFrame
	c.pollUnits = opts.PollUnits

	c.wg.Add(1)
	go c.ackLoop()

	for i := 0; i < cfg.PollWorkers; i++ {
		c.wg.Add(1)
		go c.pollWorker()
	}
	return c, nil
}

func newSessionID() ([16]byte, error) {
	var id [16]byte
	for {
		if _, err := rand.Read(id[:]); err != nil {
			return id, err
		}
		var zero [16]byte
		if id != zero {
			return id, nil
		}
	}
}

func (c *Conn) dialRaw(ctx context.Context) (net.Conn, error) {
	dctx, cancel := context.WithTimeout(ctx, c.cfg.DialTimeout)
	defer cancel()

	var raw net.Conn
	var err error
	if c.cfg.DialContext != nil {
		raw, err = c.cfg.DialContext(dctx, "tcp", c.cfg.ServerAddr)
	} else {
		var d net.Dialer
		raw, err = d.DialContext(dctx, "tcp", c.cfg.ServerAddr)
	}
	if err != nil {
		return nil, err
	}
	if !c.cfg.TLS {
		return raw, nil
	}
	var tlsCfg *tls.Config
	if c.cfg.TLSConfig != nil {
		tlsCfg = c.cfg.TLSConfig.Clone()
	} else {
		tlsCfg = &tls.Config{}
	}
	if tlsCfg.ServerName == "" && !tlsCfg.InsecureSkipVerify {
		host, _, _ := net.SplitHostPort(c.cfg.ServerAddr)
		tlsCfg.ServerName = host
	}
	tc := tls.Client(raw, tlsCfg)
	if err := tc.HandshakeContext(dctx); err != nil {
		_ = raw.Close()
		return nil, err
	}
	return tc, nil
}

func (c *Conn) doRequest(ctx context.Context, req *protocol.Request) (*protocol.Response, error) {
	conn, err := c.dialRaw(ctx)
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	_ = conn.SetDeadline(time.Now().Add(c.cfg.RequestTimeout))
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			_ = conn.SetDeadline(time.Now())
		case <-done:
		}
	}()

	if err := protocol.WriteRequest(conn, req); err != nil {
		return nil, err
	}
	resp, err := protocol.ReadResponse(conn, req.SessionID, req.Op)
	if err != nil {
		return nil, err
	}
	if resp.Status == protocol.StatusError {
		return resp, fmt.Errorf("hcr server error (op=%d seq=%d): %s", req.Op, req.Seq, string(resp.Payload))
	}
	return resp, nil
}

func (c *Conn) claimSlot() (start, end uint64, ok bool) {
	c.recvMu.Lock()
	defer c.recvMu.Unlock()
	for {
		if c.closed || c.remoteEOF || c.recvErr != nil {
			return 0, 0, false
		}

		if c.nextSlotSeq < c.recvNext+uint64(c.pollUnits) {
			start = c.nextSlotSeq
			end = start + uint64(c.cfg.SlotChunks)
			if maxEnd := c.recvNext + uint64(c.pollUnits); end > maxEnd {
				end = maxEnd
			}
			c.nextSlotSeq = end
			return start, end, true
		}
		c.recvCond.Wait()
	}
}

func (c *Conn) pollWorker() {
	defer c.wg.Done()
	for {
		cur, end, ok := c.claimSlot()
		if !ok {
			return
		}
		for cur < end {
			if c.ctx.Err() != nil {
				return
			}

			c.recvMu.Lock()
			for !c.closed && !c.remoteEOF && c.recvErr == nil && cur >= c.recvNext+uint64(c.pollUnits) {
				c.recvCond.Wait()
			}
			if c.closed || c.remoteEOF || c.recvErr != nil {
				c.recvMu.Unlock()
				return
			}
			c.recvMu.Unlock()

			want := uint16(end - cur)
			resp, err := c.doRequest(c.ctx, &protocol.Request{
				Op:        protocol.OpPoll,
				Version:   protocol.Version,
				SessionID: c.sessionID,
				Token:     c.token,
				Seq:       cur,
				Payload:   protocol.EncodePollPayload(want),
			})
			if err != nil {
				if c.ctx.Err() != nil {
					return
				}
				time.Sleep(100 * time.Millisecond)
				continue
			}

			switch resp.Status {
			case protocol.StatusData:
				chunks, err := protocol.UnpackDownloadChunks(resp.Payload)
				if err != nil {
					c.setRecvError(err)
					return
				}
				c.deliverChunks(resp.Seq, chunks)
				cur = resp.Seq + uint64(len(chunks))

			case protocol.StatusNoData:

				continue

			case protocol.StatusClosed:
				c.markRemoteEOF()
				return

			default:
				c.setRecvError(fmt.Errorf("unexpected poll status %d", resp.Status))
				return
			}
		}
	}
}

func (c *Conn) deliverChunks(baseSeq uint64, chunks [][]byte) {
	c.recvMu.Lock()
	for i, ch := range chunks {
		seq := baseSeq + uint64(i)
		if seq >= c.recvNext {
			if _, exists := c.recvChunks[seq]; !exists {
				c.recvChunks[seq] = ch
			}
		}
	}
	advanced := false
	for {
		ch, ok := c.recvChunks[c.recvNext]
		if !ok {
			break
		}
		delete(c.recvChunks, c.recvNext)
		c.readBuf.Write(ch)
		c.recvNext++
		advanced = true
	}
	var ackSeq uint64
	if advanced {
		ackSeq = c.recvNext - 1
		c.recvCond.Broadcast()
	}
	c.recvMu.Unlock()

	if advanced {
		select {
		case c.ackCh <- ackSeq:
		default:
			select {
			case <-c.ackCh:
			default:
			}
			select {
			case c.ackCh <- ackSeq:
			default:
			}
		}
	}
}

func (c *Conn) ackLoop() {
	defer c.wg.Done()
	for {
		select {
		case <-c.ctx.Done():
			return
		case seq := <-c.ackCh:
			if c.hasAcked && seq <= c.lastAcked {
				continue
			}
			resp, err := c.doRequest(c.ctx, &protocol.Request{
				Op:        protocol.OpAck,
				Version:   protocol.Version,
				SessionID: c.sessionID,
				Token:     c.token,
				Seq:       seq,
			})
			if err == nil && resp.Status == protocol.StatusOK {
				c.lastAcked = seq
				c.hasAcked = true
			}
		}
	}
}

func (c *Conn) markRemoteEOF() {
	c.recvMu.Lock()
	c.remoteEOF = true
	c.recvCond.Broadcast()
	c.recvMu.Unlock()
}

func (c *Conn) setRecvError(err error) {
	c.recvMu.Lock()
	if c.recvErr == nil {
		c.recvErr = err
	}
	c.recvCond.Broadcast()
	c.recvMu.Unlock()
}

func (c *Conn) Read(b []byte) (int, error) {
	c.recvMu.Lock()
	defer c.recvMu.Unlock()
	for c.readBuf.Len() == 0 {
		if c.closed {
			return 0, net.ErrClosed
		}
		if c.recvErr != nil {
			return 0, c.recvErr
		}
		if c.remoteEOF {
			return 0, io.EOF
		}
		if !c.readDeadline.IsZero() && !time.Now().Before(c.readDeadline) {
			return 0, os_ErrDeadlineExceeded()
		}
		c.recvCond.Wait()
	}
	return c.readBuf.Read(b)
}

type timeoutError struct{}

func (timeoutError) Error() string   { return "i/o timeout" }
func (timeoutError) Timeout() bool   { return true }
func (timeoutError) Temporary() bool { return true }

func os_ErrDeadlineExceeded() error { return timeoutError{} }

func (c *Conn) Write(b []byte) (int, error) {
	if len(b) == 0 {
		return 0, nil
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()

	total := 0
	for len(b) > 0 {
		if c.ctx.Err() != nil {
			return total, net.ErrClosed
		}
		n := len(b)
		if n > c.cfg.MaxUploadChunk {
			n = c.cfg.MaxUploadChunk
		}
		chunk := b[:n]
		seq := c.uploadSeq
		c.uploadSeq++

		var lastErr error
		for attempt := 0; attempt < 3; attempt++ {
			resp, err := c.doRequest(c.ctx, &protocol.Request{
				Op:        protocol.OpUpload,
				Version:   protocol.Version,
				SessionID: c.sessionID,
				Token:     c.token,
				Seq:       seq,
				Payload:   chunk,
			})
			if err != nil {
				lastErr = err
				time.Sleep(50 * time.Millisecond)
				continue
			}
			if resp.Status == protocol.StatusClosed {
				return total, io.ErrClosedPipe
			}
			lastErr = nil
			break
		}
		if lastErr != nil {
			return total, lastErr
		}
		total += n
		b = b[n:]
	}
	return total, nil
}

func (c *Conn) Ping(ctx context.Context) error {
	resp, err := c.doRequest(ctx, &protocol.Request{
		Op:        protocol.OpPing,
		Version:   protocol.Version,
		SessionID: c.sessionID,
		Token:     c.token,
		Seq:       0,
	})
	if err != nil {
		return err
	}
	if resp.Status == protocol.StatusClosed {
		return net.ErrClosed
	}
	return nil
}

func (c *Conn) Close() error {
	c.closeOnce.Do(func() {
		c.recvMu.Lock()
		c.closed = true
		c.recvCond.Broadcast()
		c.recvMu.Unlock()

		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		_, _ = c.doRequest(ctx, &protocol.Request{
			Op:        protocol.OpClose,
			Version:   protocol.Version,
			SessionID: c.sessionID,
			Token:     c.token,
			Seq:       0,
		})
		cancel()
		c.cancel()
	})
	return nil
}

func (c *Conn) LocalAddr() net.Addr  { return dummyAddr("hcr-local") }
func (c *Conn) RemoteAddr() net.Addr { return dummyAddr(c.cfg.ServerAddr) }

func (c *Conn) SetDeadline(t time.Time) error {
	_ = c.SetReadDeadline(t)
	return nil
}

func (c *Conn) SetReadDeadline(t time.Time) error {
	c.recvMu.Lock()
	c.readDeadline = t
	c.recvCond.Broadcast()
	c.recvMu.Unlock()
	if !t.IsZero() {
		if d := time.Until(t); d > 0 {
			time.AfterFunc(d, func() {
				c.recvMu.Lock()
				c.recvCond.Broadcast()
				c.recvMu.Unlock()
			})
		}
	}
	return nil
}

func (c *Conn) SetWriteDeadline(t time.Time) error { return nil }

type dummyAddr string

func (d dummyAddr) Network() string { return "hcr" }
func (d dummyAddr) String() string  { return string(d) }

func Calibrate(ctx context.Context, cfg Config, mode uint8, totalBytes uint32) (int, time.Duration, error) {
	cfg.setDefaults()
	sessionID, err := newSessionID()
	if err != nil {
		return 0, 0, err
	}
	helloPayload, err := protocol.EncodeCalibrationHello(protocol.CalibrationConfig{
		Mode:       mode,
		MaxFrame:   cfg.MaxDownloadFrame,
		TotalBytes: totalBytes,
		PollUnits:  cfg.PollUnits,
	})
	if err != nil {
		return 0, 0, err
	}

	c := &Conn{
		cfg:       cfg,
		sessionID: sessionID,
		ctx:       ctx,
	}
	start := time.Now()
	resp, err := c.doRequest(ctx, &protocol.Request{
		Op:        protocol.OpHello,
		Version:   protocol.Version,
		SessionID: sessionID,
		Seq:       0,
		Payload:   helloPayload,
	})
	if err != nil {
		return 0, 0, err
	}
	if resp.Status != protocol.StatusOK || len(resp.Payload) < 32 {
		return 0, 0, fmt.Errorf("calibration hello failed: status=%d len=%d", resp.Status, len(resp.Payload))
	}
	copy(c.token[:], resp.Payload[:32])
	defer func() {
		_, _ = c.doRequest(context.Background(), &protocol.Request{
			Op:        protocol.OpClose,
			Version:   protocol.Version,
			SessionID: sessionID,
			Token:     c.token,
		})
	}()

	if mode == protocol.CalibrationUpload {
		buf := make([]byte, totalBytes)
		for i := range buf {
			buf[i] = protocol.CalibrationByte(sessionID, i)
		}
		n, err := c.Write(buf)
		return n, time.Since(start), err
	}

	var received int
	var seq uint64
	for received < int(totalBytes) {
		presp, err := c.doRequest(ctx, &protocol.Request{
			Op:        protocol.OpPoll,
			Version:   protocol.Version,
			SessionID: sessionID,
			Token:     c.token,
			Seq:       seq,
			Payload:   protocol.EncodePollPayload(8),
		})
		if err != nil {
			return received, time.Since(start), err
		}
		if presp.Status == protocol.StatusClosed {
			break
		}
		if presp.Status != protocol.StatusData {
			return received, time.Since(start), errors.New("unexpected status in calibration poll")
		}
		chunks, err := protocol.UnpackDownloadChunks(presp.Payload)
		if err != nil {
			return received, time.Since(start), err
		}
		for _, ch := range chunks {
			for i, b := range ch {
				if b != protocol.CalibrationByte(sessionID, received+i) {
					return received, time.Since(start), fmt.Errorf("calibration download byte mismatch at offset %d", received+i)
				}
			}
			received += len(ch)
		}
		seq += uint64(len(chunks))
		_, _ = c.doRequest(ctx, &protocol.Request{
			Op:        protocol.OpAck,
			Version:   protocol.Version,
			SessionID: sessionID,
			Token:     c.token,
			Seq:       seq - 1,
		})
	}
	return received, time.Since(start), nil
}
