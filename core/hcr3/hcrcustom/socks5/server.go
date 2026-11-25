package socks5

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"log"
	"net"
	"strconv"
	"sync"
	"time"
)

const (
	socksVersion = 5

	cmdConnect      = 1
	cmdUDPAssociate = 3

	atypIPv4   = 1
	atypDomain = 3
	atypIPv6   = 4

	repSuccess             = 0
	repServerFailure       = 1
	repHostUnreachable     = 4
	repCommandNotSupported = 7
	repAddrNotSupported    = 8
)

type Dialer interface {
	DialTCP(addr string) (net.Conn, error)
}

type Server struct {
	dialer  Dialer
	listen  string
	timeout time.Duration

	mu       sync.Mutex
	listener net.Listener
	closed   bool
}

func NewServer(d Dialer, listen string, timeout time.Duration) (*Server, error) {
	if _, _, err := net.SplitHostPort(listen); err != nil {
		return nil, err
	}
	return &Server{dialer: d, listen: listen, timeout: timeout}, nil
}

func (s *Server) ListenAndServe() error {
	l, err := net.Listen("tcp", s.listen)
	if err != nil {
		return err
	}
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		_ = l.Close()
		return net.ErrClosed
	}
	s.listener = l
	s.mu.Unlock()
	for {
		c, err := l.Accept()
		if err != nil {
			s.mu.Lock()
			closed := s.closed
			s.mu.Unlock()
			if closed {
				return nil
			}
			return err
		}
		go s.handle(c)
	}
}

func (s *Server) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closed = true
	if s.listener != nil {
		return s.listener.Close()
	}
	return nil
}

func (s *Server) handle(c net.Conn) {
	defer c.Close()
	if s.timeout > 0 {
		_ = c.SetDeadline(time.Now().Add(s.timeout))
	}
	if err := s.negotiate(c); err != nil {
		return
	}
	cmd, addr, err := readRequest(c)
	if err != nil {
		if errors.Is(err, errAddrType) {
			_ = sendReply(c, repAddrNotSupported, nil)
		}
		return
	}
	_ = c.SetDeadline(time.Time{})
	switch cmd {
	case cmdConnect:
		s.handleTCP(c, addr)
	case cmdUDPAssociate:
		s.handleUDP(c)
	default:
		_ = sendReply(c, repCommandNotSupported, nil)
	}
}

func (s *Server) handleTCP(c net.Conn, addr string) {
	rc, err := s.dialer.DialTCP(addr)
	if err != nil {
		log.Printf("SOCKS5 TCP request to %s failed: %v", addr, err)
		_ = sendReply(c, repHostUnreachable, nil)
		return
	}
	defer rc.Close()
	if err := sendReply(c, repSuccess, nil); err != nil {
		return
	}
	errCh := make(chan error, 2)
	go func() { _, err := io.Copy(rc, c); errCh <- err }()
	go func() { _, err := io.Copy(c, rc); errCh <- err }()
	<-errCh
}

func (s *Server) handleUDP(c net.Conn) {
	host, _, _ := net.SplitHostPort(c.LocalAddr().String())
	udpAddr, err := net.ResolveUDPAddr("udp", net.JoinHostPort(host, "0"))
	if err != nil {
		_ = sendReply(c, repServerFailure, nil)
		return
	}
	uc, err := net.ListenUDP("udp", udpAddr)
	if err != nil {
		_ = sendReply(c, repServerFailure, nil)
		return
	}
	defer uc.Close()
	if err := sendReply(c, repSuccess, uc.LocalAddr()); err != nil {
		return
	}

	done := make(chan struct{})
	var once sync.Once
	finish := func() { once.Do(func() { close(done) }) }

	go func() {
		defer finish()
		buf := make([]byte, 65535)
		for {
			n, from, err := uc.ReadFromUDP(buf)
			if err != nil {
				return
			}
			if n < 4 || buf[2] != 0 {
				continue
			}
			r := bytes.NewReader(buf[3:n])
			dst, err := readAddr(r)
			if err != nil {
				continue
			}
			if _, port, err := net.SplitHostPort(dst); err != nil || port != "53" {
				continue
			}
			payload := make([]byte, r.Len())
			_, _ = io.ReadFull(r, payload)
			go s.forwardDNSOverTCP(uc, from, dst, payload)
		}
	}()

	go func() {
		defer finish()
		_, _ = io.Copy(io.Discard, c)
	}()

	<-done
}

func (s *Server) forwardDNSOverTCP(uc *net.UDPConn, clientAddr *net.UDPAddr, dst string, query []byte) {
	if len(query) == 0 || len(query) > 65535 {
		return
	}
	target := dst
	if host, _, err := net.SplitHostPort(dst); err == nil && (host == "10.255.0.1" || host == "127.0.0.1") {
		target = "1.1.1.1:53"
	}
	rc, err := s.dialer.DialTCP(target)
	if err != nil && target != "8.8.8.8:53" {
		rc, err = s.dialer.DialTCP("8.8.8.8:53")
	}
	if err != nil {
		return
	}
	defer rc.Close()
	_ = rc.SetDeadline(time.Now().Add(8 * time.Second))

	frame := make([]byte, 2+len(query))
	binary.BigEndian.PutUint16(frame[:2], uint16(len(query)))
	copy(frame[2:], query)
	if _, err := rc.Write(frame); err != nil {
		return
	}

	var lenBuf [2]byte
	if _, err := io.ReadFull(rc, lenBuf[:]); err != nil {
		return
	}
	respLen := int(binary.BigEndian.Uint16(lenBuf[:]))
	if respLen <= 0 || respLen > 65535 {
		return
	}
	resp := make([]byte, respLen)
	if _, err := io.ReadFull(rc, resp); err != nil {
		return
	}

	pkt := appendAddr([]byte{0, 0, 0}, dst)
	pkt = append(pkt, resp...)
	_, _ = uc.WriteToUDP(pkt, clientAddr)
}

func (s *Server) negotiate(c net.Conn) error {
	var hdr [2]byte
	if _, err := io.ReadFull(c, hdr[:]); err != nil {
		return err
	}
	if hdr[0] != socksVersion {
		return errors.New("unsupported SOCKS version")
	}
	methods := make([]byte, hdr[1])
	if _, err := io.ReadFull(c, methods); err != nil {
		return err
	}
	if bytes.IndexByte(methods, 0) < 0 {
		_, _ = c.Write([]byte{socksVersion, 0xff})
		return errors.New("no acceptable auth method")
	}
	_, err := c.Write([]byte{socksVersion, 0})
	return err
}

var errAddrType = errors.New("unsupported address type")

func readRequest(r io.Reader) (byte, string, error) {
	var hdr [3]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return 0, "", err
	}
	if hdr[0] != socksVersion {
		return 0, "", errors.New("unsupported SOCKS version")
	}
	addr, err := readAddr(r)
	return hdr[1], addr, err
}

func readAddr(r io.Reader) (string, error) {
	var t [1]byte
	if _, err := io.ReadFull(r, t[:]); err != nil {
		return "", err
	}
	var host string
	switch t[0] {
	case atypIPv4:
		var ip [4]byte
		if _, err := io.ReadFull(r, ip[:]); err != nil {
			return "", err
		}
		host = net.IP(ip[:]).String()
	case atypIPv6:
		var ip [16]byte
		if _, err := io.ReadFull(r, ip[:]); err != nil {
			return "", err
		}
		host = net.IP(ip[:]).String()
	case atypDomain:
		var l [1]byte
		if _, err := io.ReadFull(r, l[:]); err != nil {
			return "", err
		}
		d := make([]byte, l[0])
		if _, err := io.ReadFull(r, d); err != nil {
			return "", err
		}
		host = string(d)
	default:
		return "", errAddrType
	}
	var p [2]byte
	if _, err := io.ReadFull(r, p[:]); err != nil {
		return "", err
	}
	return net.JoinHostPort(host, strconv.Itoa(int(binary.BigEndian.Uint16(p[:])))), nil
}

func appendAddr(b []byte, addr string) []byte {
	host, portStr, err := net.SplitHostPort(addr)
	if err != nil {
		return append(b, atypIPv4, 0, 0, 0, 0, 0, 0)
	}
	port, _ := strconv.Atoi(portStr)
	if ip := net.ParseIP(host); ip != nil {
		if ip4 := ip.To4(); ip4 != nil {
			b = append(b, atypIPv4)
			b = append(b, ip4...)
		} else {
			b = append(b, atypIPv6)
			b = append(b, ip.To16()...)
		}
	} else {
		if len(host) > 255 {
			host = host[:255]
		}
		b = append(b, atypDomain, byte(len(host)))
		b = append(b, host...)
	}
	return binary.BigEndian.AppendUint16(b, uint16(port))
}

func sendReply(w io.Writer, rep byte, bind net.Addr) error {
	b := []byte{socksVersion, rep, 0}
	if bind != nil {
		b = appendAddr(b, bind.String())
	} else {
		b = appendAddr(b, "0.0.0.0:0")
	}
	_, err := w.Write(b)
	return err
}
