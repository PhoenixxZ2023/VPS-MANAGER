package protocol

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

const (
	Version = uint8(1)

	RequestHeaderSize = 62

	ResponseHeaderSize = 14

	MaxPayloadSize = 262144

	MaxDownloadFrame = 262140

	DefaultDownloadFrame = 16384

	DefaultPollUnits = 256

	MaxPollUnits = 1024

	MaxPollBatch = 32

	MaxCalibrationBytes = 524288
)

const (
	OpHello  = uint8(1)
	OpUpload = uint8(2)
	OpPoll   = uint8(3)
	OpAck    = uint8(4)
	OpClose  = uint8(5)
	OpPing   = uint8(6)
)

const (
	StatusOK     = uint8(0)
	StatusData   = uint8(1)
	StatusNoData = uint8(2)
	StatusClosed = uint8(3)
	StatusError  = uint8(4)
)

const (
	DirClientToServer = uint8(0)
	DirServerToClient = uint8(1)
)

const (
	CalibrationUpload   = uint8(0)
	CalibrationDownload = uint8(1)

	CalibrationEcho       = CalibrationUpload
	CalibrationThroughput = CalibrationDownload
)

func CalibrationByte(sessionID [16]byte, pos int) byte {
	return byte((pos*31 + int(sessionID[pos&15])) % 251)
}

type Request struct {
	Op        uint8
	Version   uint8
	SessionID [16]byte
	Token     [32]byte
	Seq       uint64
	Payload   []byte
}

type Response struct {
	Status  uint8
	Version uint8
	Seq     uint64
	Payload []byte
}

func Transform(sessionID [16]byte, op uint8, seq uint64, dir uint8, payload []byte) {
	if len(payload) == 0 {
		return
	}
	var seed [30]byte
	copy(seed[0:16], sessionID[:])
	seed[16] = op
	binary.BigEndian.PutUint64(seed[17:25], seq)
	seed[25] = dir

	var blockIdx uint32
	for off := 0; off < len(payload); off += 32 {
		binary.BigEndian.PutUint32(seed[26:30], blockIdx)
		blockIdx++
		ks := sha256.Sum256(seed[:])
		rem := len(payload) - off
		if rem > 32 {
			rem = 32
		}
		for i := 0; i < rem; i++ {
			payload[off+i] ^= ks[i]
		}
	}
}

func ReadRequest(r io.Reader) (*Request, error) {
	var hdr [RequestHeaderSize]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return nil, err
	}
	req := &Request{
		Op:      hdr[0],
		Version: hdr[1],
		Seq:     binary.BigEndian.Uint64(hdr[50:58]),
	}
	copy(req.SessionID[:], hdr[2:18])
	copy(req.Token[:], hdr[18:50])

	payloadLen := binary.BigEndian.Uint32(hdr[58:62])
	if payloadLen > MaxPayloadSize {
		return nil, fmt.Errorf("request payload length %d exceeds max %d", payloadLen, MaxPayloadSize)
	}
	if payloadLen > 0 {
		req.Payload = make([]byte, payloadLen)
		if _, err := io.ReadFull(r, req.Payload); err != nil {
			return nil, err
		}
		Transform(req.SessionID, req.Op, req.Seq, DirClientToServer, req.Payload)
	}
	return req, nil
}

func WriteRequest(w io.Writer, req *Request) error {
	if len(req.Payload) > MaxPayloadSize {
		return fmt.Errorf("request payload length %d exceeds max %d", len(req.Payload), MaxPayloadSize)
	}
	ver := req.Version
	if ver == 0 {
		ver = Version
	}
	buf := make([]byte, RequestHeaderSize+len(req.Payload))
	buf[0] = req.Op
	buf[1] = ver
	copy(buf[2:18], req.SessionID[:])
	copy(buf[18:50], req.Token[:])
	binary.BigEndian.PutUint64(buf[50:58], req.Seq)
	binary.BigEndian.PutUint32(buf[58:62], uint32(len(req.Payload)))
	if len(req.Payload) > 0 {
		copy(buf[RequestHeaderSize:], req.Payload)
		Transform(req.SessionID, req.Op, req.Seq, DirClientToServer, buf[RequestHeaderSize:])
	}
	_, err := w.Write(buf)
	return err
}

func ReadResponse(r io.Reader, sessionID [16]byte, reqOp uint8) (*Response, error) {
	var hdr [ResponseHeaderSize]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return nil, err
	}
	resp := &Response{
		Status:  hdr[0],
		Version: hdr[1],
		Seq:     binary.BigEndian.Uint64(hdr[2:10]),
	}
	payloadLen := binary.BigEndian.Uint32(hdr[10:14])
	if payloadLen > MaxPayloadSize {
		return nil, fmt.Errorf("response payload length %d exceeds max %d", payloadLen, MaxPayloadSize)
	}
	if payloadLen > 0 {
		resp.Payload = make([]byte, payloadLen)
		if _, err := io.ReadFull(r, resp.Payload); err != nil {
			return nil, err
		}
		Transform(sessionID, reqOp, resp.Seq, DirServerToClient, resp.Payload)
	}
	return resp, nil
}

func WriteResponse(w io.Writer, sessionID [16]byte, reqOp uint8, resp *Response) error {
	if len(resp.Payload) > MaxPayloadSize {
		return fmt.Errorf("response payload length %d exceeds max %d", len(resp.Payload), MaxPayloadSize)
	}
	ver := resp.Version
	if ver == 0 {
		ver = Version
	}
	buf := make([]byte, ResponseHeaderSize+len(resp.Payload))
	buf[0] = resp.Status
	buf[1] = ver
	binary.BigEndian.PutUint64(buf[2:10], resp.Seq)
	binary.BigEndian.PutUint32(buf[10:14], uint32(len(resp.Payload)))
	if len(resp.Payload) > 0 {
		copy(buf[ResponseHeaderSize:], resp.Payload)
		Transform(sessionID, reqOp, resp.Seq, DirServerToClient, buf[ResponseHeaderSize:])
	}
	_, err := w.Write(buf)
	return err
}

type HelloOptions struct {
	MaxDownloadFrame uint32
	PollUnits        uint16
}

func EncodeHelloRequest(opts HelloOptions) ([]byte, error) {
	if opts.MaxDownloadFrame > MaxDownloadFrame {
		return nil, fmt.Errorf("max download frame %d exceeds %d", opts.MaxDownloadFrame, MaxDownloadFrame)
	}
	if opts.PollUnits == 0 {
		opts.PollUnits = DefaultPollUnits
	}
	if opts.PollUnits < DefaultPollUnits || opts.PollUnits > MaxPollUnits {
		return nil, fmt.Errorf("poll units %d out of range [%d, %d]", opts.PollUnits, DefaultPollUnits, MaxPollUnits)
	}
	if opts.MaxDownloadFrame == 0 && opts.PollUnits == DefaultPollUnits {
		return nil, nil
	}
	if opts.PollUnits == DefaultPollUnits {
		var b [5]byte
		b[0] = 1
		binary.BigEndian.PutUint32(b[1:5], opts.MaxDownloadFrame)
		return b[:], nil
	}
	var b [7]byte
	b[0] = 2
	binary.BigEndian.PutUint32(b[1:5], opts.MaxDownloadFrame)
	binary.BigEndian.PutUint16(b[5:7], opts.PollUnits)
	return b[:], nil
}

func DecodeHelloRequest(b []byte) (HelloOptions, error) {
	switch len(b) {
	case 0:
		return HelloOptions{MaxDownloadFrame: 0, PollUnits: DefaultPollUnits}, nil
	case 5:
		if b[0] != 1 {
			return HelloOptions{}, errors.New("invalid 5-byte hello tag")
		}
		mf := binary.BigEndian.Uint32(b[1:5])
		if mf == 0 || mf > MaxDownloadFrame {
			return HelloOptions{}, fmt.Errorf("invalid 5-byte hello max frame %d", mf)
		}
		return HelloOptions{MaxDownloadFrame: mf, PollUnits: DefaultPollUnits}, nil
	case 7:
		if b[0] != 2 {
			return HelloOptions{}, errors.New("invalid 7-byte hello tag")
		}
		mf := binary.BigEndian.Uint32(b[1:5])
		if mf > MaxDownloadFrame {
			return HelloOptions{}, fmt.Errorf("invalid 7-byte hello max frame %d", mf)
		}
		pu := binary.BigEndian.Uint16(b[5:7])
		if pu <= DefaultPollUnits || pu > MaxPollUnits {
			return HelloOptions{}, fmt.Errorf("invalid 7-byte hello poll units %d", pu)
		}
		return HelloOptions{MaxDownloadFrame: mf, PollUnits: pu}, nil
	default:
		return HelloOptions{}, fmt.Errorf("unexpected hello payload length %d", len(b))
	}
}

func EncodeHelloResponse(token [32]byte, requested HelloOptions, effectiveMaxFrame uint32) []byte {
	if requested.MaxDownloadFrame == 0 && requested.PollUnits <= DefaultPollUnits {
		out := make([]byte, 32)
		copy(out, token[:])
		return out
	}
	if requested.PollUnits <= DefaultPollUnits {
		out := make([]byte, 37)
		copy(out[0:32], token[:])
		out[32] = 1
		binary.BigEndian.PutUint32(out[33:37], effectiveMaxFrame)
		return out
	}
	out := make([]byte, 39)
	copy(out[0:32], token[:])
	out[32] = 2
	binary.BigEndian.PutUint32(out[33:37], effectiveMaxFrame)
	binary.BigEndian.PutUint16(out[37:39], requested.PollUnits)
	return out
}

func DecodeHelloResponse(b []byte) (token [32]byte, opts HelloOptions, err error) {
	if len(b) < 32 {
		return token, opts, fmt.Errorf("hello response too short: %d bytes", len(b))
	}
	copy(token[:], b[0:32])
	opts.MaxDownloadFrame = DefaultDownloadFrame
	opts.PollUnits = DefaultPollUnits
	switch len(b) {
	case 32:
		return token, opts, nil
	case 37:
		if b[32] != 1 {
			return token, opts, fmt.Errorf("invalid 37-byte hello response tag %d", b[32])
		}
		opts.MaxDownloadFrame = binary.BigEndian.Uint32(b[33:37])
		return token, opts, nil
	case 39:
		if b[32] != 2 {
			return token, opts, fmt.Errorf("invalid 39-byte hello response tag %d", b[32])
		}
		opts.MaxDownloadFrame = binary.BigEndian.Uint32(b[33:37])
		opts.PollUnits = binary.BigEndian.Uint16(b[37:39])
		return token, opts, nil
	default:
		return token, opts, fmt.Errorf("unexpected hello response length %d", len(b))
	}
}

type CalibrationConfig struct {
	Mode       uint8
	MaxFrame   uint32
	TotalBytes uint32
	PollUnits  uint16
}

func EncodeCalibrationHello(cfg CalibrationConfig) ([]byte, error) {
	if cfg.Mode > CalibrationThroughput {
		return nil, fmt.Errorf("invalid calibration mode %d", cfg.Mode)
	}
	if cfg.MaxFrame > MaxDownloadFrame {
		return nil, fmt.Errorf("invalid calibration max frame %d", cfg.MaxFrame)
	}
	if cfg.TotalBytes == 0 || cfg.TotalBytes > MaxCalibrationBytes {
		return nil, fmt.Errorf("invalid calibration total bytes %d", cfg.TotalBytes)
	}
	if cfg.PollUnits == 0 {
		cfg.PollUnits = DefaultPollUnits
	}
	if cfg.PollUnits < DefaultPollUnits || cfg.PollUnits > MaxPollUnits {
		return nil, fmt.Errorf("invalid calibration poll units %d", cfg.PollUnits)
	}
	var b [12]byte
	b[0] = 3
	b[1] = cfg.Mode
	binary.BigEndian.PutUint32(b[2:6], cfg.MaxFrame)
	binary.BigEndian.PutUint32(b[6:10], cfg.TotalBytes)
	binary.BigEndian.PutUint16(b[10:12], cfg.PollUnits)
	return b[:], nil
}

func DecodeCalibrationHello(b []byte) (CalibrationConfig, error) {
	if len(b) != 12 || b[0] != 3 {
		return CalibrationConfig{}, errors.New("invalid 12-byte calibration hello")
	}
	cfg := CalibrationConfig{
		Mode:       b[1],
		MaxFrame:   binary.BigEndian.Uint32(b[2:6]),
		TotalBytes: binary.BigEndian.Uint32(b[6:10]),
		PollUnits:  binary.BigEndian.Uint16(b[10:12]),
	}
	if cfg.Mode > CalibrationThroughput || cfg.MaxFrame > MaxDownloadFrame ||
		cfg.TotalBytes == 0 || cfg.TotalBytes > MaxCalibrationBytes ||
		cfg.PollUnits < DefaultPollUnits || cfg.PollUnits > MaxPollUnits {
		return CalibrationConfig{}, errors.New("calibration hello parameters out of range")
	}
	return cfg, nil
}

func EncodeCalibrationResponse(token [32]byte, reqPayload []byte, effectiveMaxFrame uint32) []byte {
	out := make([]byte, 48)
	copy(out[0:32], token[:])
	copy(out[32:44], reqPayload[0:12])
	binary.BigEndian.PutUint32(out[44:48], effectiveMaxFrame)
	return out
}

func EncodePollPayload(maxChunks uint16) []byte {
	if maxChunks <= 1 {
		return nil
	}
	if maxChunks > MaxPollBatch {
		maxChunks = MaxPollBatch
	}
	var b [2]byte
	binary.BigEndian.PutUint16(b[:], maxChunks)
	return b[:]
}

func DecodePollPayload(b []byte) (uint16, error) {
	if len(b) == 0 {
		return 1, nil
	}
	if len(b) != 2 {
		return 0, fmt.Errorf("invalid poll payload length %d", len(b))
	}
	n := binary.BigEndian.Uint16(b)
	if n == 0 {
		return 1, nil
	}
	if n > MaxPollBatch {
		return MaxPollBatch, nil
	}
	return n, nil
}

func PackDownloadChunks(chunks [][]byte) []byte {
	total := 0
	for _, c := range chunks {
		total += 4 + len(c)
	}
	out := make([]byte, 0, total)
	var lenBuf [4]byte
	for _, c := range chunks {
		binary.BigEndian.PutUint32(lenBuf[:], uint32(len(c)))
		out = append(out, lenBuf[:]...)
		out = append(out, c...)
	}
	return out
}

func UnpackDownloadChunks(b []byte) ([][]byte, error) {
	var chunks [][]byte
	pos := 0
	for pos < len(b) {
		if pos+4 > len(b) {
			return nil, fmt.Errorf("truncated chunk length at offset %d", pos)
		}
		clen := int(binary.BigEndian.Uint32(b[pos : pos+4]))
		pos += 4
		if clen < 0 || pos+clen > len(b) {
			return nil, fmt.Errorf("truncated chunk body (len %d) at offset %d", clen, pos)
		}
		chunk := make([]byte, clen)
		copy(chunk, b[pos:pos+clen])
		chunks = append(chunks, chunk)
		pos += clen
	}
	if len(chunks) == 0 {
		return nil, errors.New("empty StatusData payload")
	}
	return chunks, nil
}
