package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/xjasonlyu/tun2socks/v2/engine"

	"github.com/hcrcustom/hcrcustom/client"
	"github.com/hcrcustom/hcrcustom/protocol"
	"github.com/hcrcustom/hcrcustom/socks5"
)

type vpnConfig struct {
	Server    string `json:"server"`
	User      string `json:"user"`
	Auth      string `json:"auth"`
	TLS       bool   `json:"tls"`
	Insecure  bool   `json:"insecure"`
	SNI       string `json:"sni"`
	Calibrate bool   `json:"calibrate"`
	MaxFrame  uint32 `json:"max_frame"`
	PollUnits uint16 `json:"poll_units"`
	SOCKS5    struct {
		Listen string `json:"listen"`
	} `json:"socks5"`
}

func main() {
	configPath := flag.String("c", "", "JSON config path")
	tunSock := flag.String("tun-sock", "", "unix socket path on which to receive the TUN fd")
	mtu := flag.Int("mtu", 1500, "TUN MTU")
	flag.Parse()
	log.SetFlags(log.Ltime)

	data, err := os.ReadFile(*configPath)
	if err != nil {
		log.Fatal(err)
	}
	var cfg vpnConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		log.Fatalf("invalid config: %v", err)
	}
	if cfg.SOCKS5.Listen == "" {
		cfg.SOCKS5.Listen = "127.0.0.1:10809"
	}
	if cfg.MaxFrame == 0 {
		cfg.MaxFrame = protocol.DefaultDownloadFrame
	}
	if cfg.PollUnits == 0 {
		cfg.PollUnits = protocol.DefaultPollUnits
	}

	var tlsCfg *tls.Config
	if cfg.TLS {
		host, _, _ := net.SplitHostPort(cfg.Server)
		sni := cfg.SNI
		if sni == "" {
			sni = host
		}
		tlsCfg = &tls.Config{
			ServerName:         sni,
			InsecureSkipVerify: cfg.Insecure,
		}
	}

	hcrCfg := client.Config{
		ServerAddr:       cfg.Server,
		TLS:              cfg.TLS,
		TLSConfig:        tlsCfg,
		MaxDownloadFrame: cfg.MaxFrame,
		PollUnits:        cfg.PollUnits,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if cfg.Calibrate {
		n, dur, err := client.Calibrate(ctx, hcrCfg, protocol.CalibrationDownload, 32768)
		if err != nil {
			log.Printf("calibration warning: %v", err)
		} else {
			kbps := float64(n*8) / dur.Seconds() / 1000.0
			log.Printf("CALIBRATED download %d bytes in %v (%.1f kbps)", n, dur.Round(time.Millisecond), kbps)
		}
	}

	log.Printf("connecting HCR + SSH to %s as %s (tls=%v, frame=%d, poll=%d)...",
		cfg.Server, cfg.User, cfg.TLS, cfg.MaxFrame, cfg.PollUnits)

	tun, err := client.DialSSH(ctx, client.SSHConfig{
		HCR:      hcrCfg,
		User:     cfg.User,
		Password: cfg.Auth,
	})
	if err != nil {
		log.Printf("ERROR %v", err)
		os.Exit(1)
	}
	defer tun.Close()

	socksSrv, err := socks5.NewServer(tun, cfg.SOCKS5.Listen, 15*time.Second)
	if err != nil {
		log.Printf("ERROR %v", err)
		os.Exit(1)
	}
	defer socksSrv.Close()

	errCh := make(chan error, 1)
	go func() { errCh <- socksSrv.ListenAndServe() }()

	log.Printf("CONNECTED %s (%s), SOCKS5 %s", cfg.Server, tun.ServerVersion(), cfg.SOCKS5.Listen)

	if *tunSock != "" {
		fd, err := receiveFD(ctx, *tunSock)
		if err != nil {
			log.Printf("ERROR receiving TUN fd: %v", err)
			os.Exit(1)
		}
		engine.Insert(&engine.Key{
			Device:     fmt.Sprintf("fd://%d", fd),
			Proxy:      "socks5://" + cfg.SOCKS5.Listen,
			MTU:        *mtu,
			LogLevel:   "warn",
			UDPTimeout: time.Minute,
		})
		engine.Start()
		defer engine.Stop()
		log.Printf("TUN STARTED (fd %d)", fd)
	}

	select {
	case <-ctx.Done():
		log.Printf("stopping")
	case err := <-errCh:
		log.Printf("SOCKS5 server stopped: %v", err)
	}
}

func receiveFD(ctx context.Context, path string) (int, error) {
	_ = os.Remove(path)
	l, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		return -1, err
	}
	defer l.Close()
	defer os.Remove(path)
	_ = l.SetDeadline(time.Now().Add(30 * time.Second))
	go func() {
		<-ctx.Done()
		_ = l.Close()
	}()
	c, err := l.AcceptUnix()
	if err != nil {
		return -1, err
	}
	defer c.Close()
	buf := make([]byte, 1)
	oob := make([]byte, syscall.CmsgSpace(4))
	_, oobn, _, _, err := c.ReadMsgUnix(buf, oob)
	if err != nil {
		return -1, err
	}
	msgs, err := syscall.ParseSocketControlMessage(oob[:oobn])
	if err != nil {
		return -1, err
	}
	for _, m := range msgs {
		fds, err := syscall.ParseUnixRights(&m)
		if err == nil && len(fds) > 0 {
			return fds[0], nil
		}
	}
	return -1, errors.New("no file descriptor received")
}
