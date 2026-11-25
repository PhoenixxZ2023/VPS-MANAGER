package server

import (
	"bufio"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/hcrcustom/hcrcustom/protocol"
)

const (
	defaultMaxConnections     = 2048
	defaultMaxSessions        = 32
	defaultPollTimeout        = 25 * time.Second
	defaultSessionIdleTimeout = 120 * time.Second
	defaultCleanupInterval    = 10 * time.Second
	handshakeReadTimeout      = 5 * time.Second
	responseWriteTimeout      = 30 * time.Second
)

type Config struct {
	Listen             string
	ProxyHeader        bool
	Transport          string
	Target             string
	TLSConfig          *tls.Config
	MaxConnections     int
	MaxSessions        int
	MaxSessionsPerIP   int
	PollTimeout        time.Duration
	MaxDownloadFrame   uint32
	SessionIdleTimeout time.Duration
	DialTarget         func(ctx context.Context, addr string) (net.Conn, error)
	Verbose            bool
}

type Server struct {
	cfg      Config
	connSem  chan struct{}
	mu       sync.RWMutex
	sessions map[[16]byte]*Session
	ipCounts map[string]int
	ln       net.Listener
	closed   chan struct{}
	once     sync.Once
}

func New(cfg Config) (*Server, error) {
	if cfg.ProxyHeader {
		host, _, err := net.SplitHostPort(cfg.Listen)
		if err != nil || !net.ParseIP(host).IsLoopback() {
			return nil, errors.New("PROXY requires a loopback listener")
		}
	}
	if cfg.Transport == "" {
		cfg.Transport = "auto"
	}
	switch cfg.Transport {
	case "plain", "tls", "auto":
	default:
		return nil, fmt.Errorf("unsupported transport %q (expected plain, tls, or auto)", cfg.Transport)
	}
	if (cfg.Transport == "tls" || cfg.Transport == "auto") && cfg.TLSConfig == nil && cfg.Transport == "tls" {
		return nil, errors.New("tls transport requires TLSConfig")
	}
	if cfg.Target == "" {
		cfg.Target = "127.0.0.1:22"
	}
	if cfg.MaxConnections <= 0 {
		cfg.MaxConnections = defaultMaxConnections
	}
	if cfg.MaxSessions <= 0 {
		cfg.MaxSessions = defaultMaxSessions
	}
	if cfg.MaxSessionsPerIP <= 0 {
		cfg.MaxSessionsPerIP = cfg.MaxSessions
		if cfg.MaxSessionsPerIP > 16 {
			cfg.MaxSessionsPerIP = 16
		}
	}
	if cfg.PollTimeout <= 0 {
		cfg.PollTimeout = defaultPollTimeout
	}
	if cfg.MaxDownloadFrame == 0 || cfg.MaxDownloadFrame > protocol.MaxDownloadFrame {
		cfg.MaxDownloadFrame = protocol.DefaultDownloadFrame
	}
	if cfg.SessionIdleTimeout <= 0 {
		cfg.SessionIdleTimeout = defaultSessionIdleTimeout
	}
	if cfg.DialTarget == nil {
		cfg.DialTarget = func(ctx context.Context, addr string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "tcp", addr)
		}
	}
	return &Server{
		cfg:      cfg,
		connSem:  make(chan struct{}, cfg.MaxConnections),
		sessions: make(map[[16]byte]*Session),
		ipCounts: make(map[string]int),
		closed:   make(chan struct{}),
	}, nil
}

func (s *Server) ListenAndServe() error {
	ln, err := net.Listen("tcp", s.cfg.Listen)
	if err != nil {
		return err
	}
	return s.Serve(ln)
}

func (s *Server) Serve(ln net.Listener) error {

	s.mu.Lock()
	s.ln = ln
	s.mu.Unlock()

	go s.cleanupLoop()

	for {
		conn, err := ln.Accept()
		if err != nil {
			select {
			case <-s.closed:
				return nil
			default:
				return err
			}
		}
		select {
		case s.connSem <- struct{}{}:
			go func(c net.Conn) {
				defer func() { <-s.connSem }()
				s.handleConn(c)
			}(conn)
		default:
			_ = conn.Close()
		}
	}
}

func (s *Server) Close() error {
	var err error
	s.once.Do(func() {
		close(s.closed)
		s.mu.Lock()
		if s.ln != nil {
			err = s.ln.Close()
		}
		var list []*Session
		for id, sess := range s.sessions {
			list = append(list, sess)
			delete(s.sessions, id)
		}
		s.ipCounts = make(map[string]int)
		s.mu.Unlock()
		for _, sess := range list {
			sess.Close()
		}
	})
	return err
}

func (s *Server) Addr() net.Addr {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.ln == nil {
		return nil
	}
	return s.ln.Addr()
}

func (s *Server) SnapshotSessions() []SessionStats {
	s.mu.RLock()
	list := make([]*Session, 0, len(s.sessions))
	for _, sess := range s.sessions {
		list = append(list, sess)
	}
	s.mu.RUnlock()

	out := make([]SessionStats, 0, len(list))
	for _, sess := range list {
		out = append(out, sess.Stats())
	}
	return out
}

func (s *Server) cleanupLoop() {
	ticker := time.NewTicker(defaultCleanupInterval)
	defer ticker.Stop()
	for {
		select {
		case <-s.closed:
			return
		case now := <-ticker.C:
			var expired [][16]byte
			s.mu.RLock()
			for id, sess := range s.sessions {
				sess.mu.Lock()
				idle := now.Sub(sess.lastActive)
				closed := sess.closed
				sess.mu.Unlock()
				if closed || idle > s.cfg.SessionIdleTimeout {
					expired = append(expired, id)
				}
			}
			s.mu.RUnlock()
			for _, id := range expired {
				s.removeSession(id)
			}
		}
	}
}

func (s *Server) handleConn(rawConn net.Conn) {
	defer rawConn.Close()
	_ = rawConn.SetReadDeadline(time.Now().Add(handshakeReadTimeout))

	clientIP := extractIP(rawConn.RemoteAddr())
	if s.cfg.ProxyHeader {
		br := bufio.NewReaderSize(rawConn, 128)
		line, err := br.ReadSlice('\n')
		if err != nil || len(line) > 108 {
			return
		}
		fields := strings.Fields(string(line))
		if len(fields) != 6 || fields[0] != "PROXY" || (fields[1] != "TCP4" && fields[1] != "TCP6") {
			return
		}
		ip := net.ParseIP(fields[2])
		if ip == nil {
			return
		}
		clientIP = ip.String()
		rawConn = &bufferedConn{Conn: rawConn, r: br}
	}
	conn, reader, err := s.wrapTransport(rawConn)
	if err != nil {
		return
	}

	req, err := protocol.ReadRequest(reader)
	if err != nil {
		return
	}
	_ = conn.SetReadDeadline(time.Time{})

	if err := validateRequestHeader(req); err != nil {
		s.writeError(conn, req.SessionID, req.Op, req.Seq, err.Error())
		return
	}

	var (
		resp      *protocol.Response
		createdID *[16]byte
	)
	if req.Op == protocol.OpHello {
		resp, createdID = s.handleHello(req, clientIP)
	} else {
		resp = s.handleSessionOp(req)
	}

	_ = conn.SetWriteDeadline(time.Now().Add(responseWriteTimeout))
	if err := protocol.WriteResponse(conn, req.SessionID, req.Op, resp); err != nil && createdID != nil {
		s.removeSession(*createdID)
	}
}

type bufferedConn struct {
	net.Conn
	r *bufio.Reader
}

func (b *bufferedConn) Read(p []byte) (int, error) {
	return b.r.Read(p)
}

func (s *Server) wrapTransport(c net.Conn) (net.Conn, io.Reader, error) {
	switch s.cfg.Transport {
	case "plain":
		return c, c, nil
	case "tls":
		tc := tls.Server(c, s.cfg.TLSConfig)
		if err := tc.Handshake(); err != nil {
			return nil, nil, err
		}
		return tc, tc, nil
	case "auto":
		br := bufio.NewReaderSize(c, 4096)
		b, err := br.Peek(1)
		if err != nil {
			return nil, nil, err
		}
		bc := &bufferedConn{Conn: c, r: br}
		if b[0] == 0x16 {
			if s.cfg.TLSConfig == nil {
				return nil, nil, errors.New("received TLS record but TLSConfig is nil")
			}
			tc := tls.Server(bc, s.cfg.TLSConfig)
			if err := tc.Handshake(); err != nil {
				return nil, nil, err
			}
			return tc, tc, nil
		}
		if b[0] >= protocol.OpHello && b[0] <= protocol.OpPing {
			return bc, br, nil
		}
		return nil, nil, fmt.Errorf("unsupported first byte 0x%02x in auto transport", b[0])
	default:
		return c, c, nil
	}
}

func validateRequestHeader(req *protocol.Request) error {
	if req.Version != protocol.Version {
		return fmt.Errorf("unsupported protocol version %d", req.Version)
	}
	if req.Op < protocol.OpHello || req.Op > protocol.OpPing {
		return fmt.Errorf("unsupported opcode %d", req.Op)
	}
	var zeroID [16]byte
	if req.SessionID == zeroID {
		return errors.New("session ID must not be all zeros")
	}
	var zeroTok [32]byte
	if req.Op == protocol.OpHello {
		if req.Seq != 0 {
			return errors.New("hello seq must be 0")
		}
		if req.Token != zeroTok {
			return errors.New("hello token must be all zeros")
		}
		switch len(req.Payload) {
		case 0, 5, 7, 12:
		default:
			return fmt.Errorf("invalid hello payload length %d", len(req.Payload))
		}
		return nil
	}
	if req.Token == zeroTok {
		return errors.New("missing session token")
	}
	switch req.Op {
	case protocol.OpUpload:
		if len(req.Payload) == 0 {
			return errors.New("empty upload payload")
		}
	case protocol.OpPoll:
		if len(req.Payload) != 0 && len(req.Payload) != 2 {
			return fmt.Errorf("invalid poll payload length %d", len(req.Payload))
		}
	case protocol.OpAck, protocol.OpClose, protocol.OpPing:
		if len(req.Payload) != 0 {
			return fmt.Errorf("op %d requires empty payload", req.Op)
		}
	}
	return nil
}

func (s *Server) handleHello(req *protocol.Request, clientIP string) (*protocol.Response, *[16]byte) {

	if len(req.Payload) == 12 {
		calCfg, err := protocol.DecodeCalibrationHello(req.Payload)
		if err != nil {
			return s.errorResponse(req.Seq, err.Error()), nil
		}
		sess, err := newCalibrationSession(req.SessionID, clientIP, calCfg, s.cfg.MaxDownloadFrame)
		if err != nil {
			return s.errorResponse(req.Seq, err.Error()), nil
		}
		if err := s.registerSession(sess); err != nil {
			sess.Close()
			return s.errorResponse(req.Seq, err.Error()), nil
		}
		id := req.SessionID
		time.AfterFunc(calibrationTTL, func() {
			s.removeSession(id)
		})
		if s.cfg.Verbose {
			log.Printf("[hcr-server] CALIBRATION HELLO sid=%x ip=%s mode=%d total=%d frame=%d",
				req.SessionID[:4], clientIP, calCfg.Mode, calCfg.TotalBytes, sess.MaxDownloadFrame())
		}
		return &protocol.Response{
			Status:  protocol.StatusOK,
			Version: protocol.Version,
			Seq:     0,
			Payload: protocol.EncodeCalibrationResponse(sess.Token(), req.Payload, sess.MaxDownloadFrame()),
		}, &id
	}

	opts, err := protocol.DecodeHelloRequest(req.Payload)
	if err != nil {
		return s.errorResponse(req.Seq, err.Error()), nil
	}
	effFrame := opts.MaxDownloadFrame
	if effFrame == 0 {
		effFrame = s.cfg.MaxDownloadFrame
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	targetConn, err := s.cfg.DialTarget(ctx, s.cfg.Target)
	cancel()
	if err != nil {
		return s.errorResponse(req.Seq, err.Error()), nil
	}

	sess, err := newSession(req.SessionID, clientIP, targetConn, effFrame, opts.PollUnits)
	if err != nil {
		_ = targetConn.Close()
		return s.errorResponse(req.Seq, err.Error()), nil
	}
	if err := s.registerSession(sess); err != nil {
		sess.Close()
		return s.errorResponse(req.Seq, err.Error()), nil
	}
	if s.cfg.Verbose {
		log.Printf("[hcr-server] HELLO sid=%x ip=%s frame=%d pollUnits=%d -> %s",
			req.SessionID[:4], clientIP, sess.MaxDownloadFrame(), sess.PollUnits(), s.cfg.Target)
	}
	id := req.SessionID
	return &protocol.Response{
		Status:  protocol.StatusOK,
		Version: protocol.Version,
		Seq:     0,
		Payload: protocol.EncodeHelloResponse(sess.Token(), opts, sess.MaxDownloadFrame()),
	}, &id
}

func (s *Server) handleSessionOp(req *protocol.Request) *protocol.Response {
	sess := s.getSession(req.SessionID)
	if sess == nil {
		if req.Op == protocol.OpClose || req.Op == protocol.OpPing {
			return &protocol.Response{Status: protocol.StatusClosed, Version: protocol.Version, Seq: req.Seq}
		}
		return s.errorResponse(req.Seq, "unknown session")
	}
	if !sess.ValidateToken(req.Token) {
		return s.errorResponse(req.Seq, "invalid session token")
	}

	switch req.Op {
	case protocol.OpUpload:
		nextSeq, err := sess.Upload(req.Seq, req.Payload)
		if err != nil {
			if errors.Is(err, ErrSessionClosed) {
				s.removeSession(req.SessionID)
				return &protocol.Response{Status: protocol.StatusClosed, Version: protocol.Version, Seq: nextSeq}
			}
			if !errors.Is(err, ErrUploadBackpressure) {
				s.removeSession(req.SessionID)
			}
			return s.errorResponse(nextSeq, err.Error())
		}
		return &protocol.Response{Status: protocol.StatusOK, Version: protocol.Version, Seq: nextSeq}

	case protocol.OpPoll:
		maxChunks, err := protocol.DecodePollPayload(req.Payload)
		if err != nil {
			return s.errorResponse(req.Seq, err.Error())
		}
		status, rseq, payload, err := sess.Poll(req.Seq, maxChunks, s.cfg.PollTimeout)
		if err != nil {
			return s.errorResponse(rseq, err.Error())
		}
		if status == protocol.StatusClosed {
			s.removeSession(req.SessionID)
		}
		return &protocol.Response{Status: status, Version: protocol.Version, Seq: rseq, Payload: payload}

	case protocol.OpAck:
		if err := sess.Acknowledge(req.Seq); err != nil {
			if errors.Is(err, ErrSessionClosed) {
				s.removeSession(req.SessionID)
				return &protocol.Response{Status: protocol.StatusClosed, Version: protocol.Version, Seq: req.Seq}
			}
			return s.errorResponse(req.Seq, err.Error())
		}
		return &protocol.Response{Status: protocol.StatusOK, Version: protocol.Version, Seq: req.Seq}

	case protocol.OpClose:
		s.removeSession(req.SessionID)
		return &protocol.Response{Status: protocol.StatusClosed, Version: protocol.Version, Seq: req.Seq}

	case protocol.OpPing:
		if sess.IsClosed() {
			s.removeSession(req.SessionID)
			return &protocol.Response{Status: protocol.StatusClosed, Version: protocol.Version, Seq: req.Seq}
		}
		return &protocol.Response{Status: protocol.StatusOK, Version: protocol.Version, Seq: req.Seq}

	default:
		return s.errorResponse(req.Seq, "unsupported opcode")
	}
}

func (s *Server) registerSession(sess *Session) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.sessions[sess.id]; exists {
		return errors.New("session ID already exists")
	}
	if len(s.sessions) >= s.cfg.MaxSessions {
		return errors.New("max sessions reached")
	}
	if s.ipCounts[sess.clientIP] >= s.cfg.MaxSessionsPerIP {
		return errors.New("max sessions per IP reached")
	}
	s.sessions[sess.id] = sess
	s.ipCounts[sess.clientIP]++
	return nil
}

func (s *Server) getSession(id [16]byte) *Session {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.sessions[id]
}

func (s *Server) removeSession(id [16]byte) {
	s.mu.Lock()
	sess, ok := s.sessions[id]
	if ok {
		delete(s.sessions, id)
		if s.ipCounts[sess.clientIP] <= 1 {
			delete(s.ipCounts, sess.clientIP)
		} else {
			s.ipCounts[sess.clientIP]--
		}
	}
	s.mu.Unlock()
	if ok {
		sess.Close()
	}
}

func (s *Server) errorResponse(seq uint64, msg string) *protocol.Response {
	return &protocol.Response{
		Status:  protocol.StatusError,
		Version: protocol.Version,
		Seq:     seq,
		Payload: []byte(msg),
	}
}

func (s *Server) writeError(w io.Writer, sessionID [16]byte, reqOp uint8, seq uint64, msg string) {
	_ = protocol.WriteResponse(w, sessionID, reqOp, s.errorResponse(seq, msg))
}

func extractIP(addr net.Addr) string {
	if addr == nil {
		return ""
	}
	host, _, err := net.SplitHostPort(addr.String())
	if err != nil {
		return addr.String()
	}
	return host
}
