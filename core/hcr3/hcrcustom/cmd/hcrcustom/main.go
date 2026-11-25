package main

import (
	"context"
	"crypto/tls"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/hcrcustom/hcrcustom/client"
	"github.com/hcrcustom/hcrcustom/protocol"
	"github.com/hcrcustom/hcrcustom/socks5"
)

func main() {
	var (
		account      = flag.String("s", "", "server in HTTP Custom form: host:port@user:pass")
		serverAddr   = flag.String("server", "", "hcr-server host:port (when using -forward or -calibrate without SSH auth)")
		listenSOCKS  = flag.String("l", "127.0.0.1:1080", "local SOCKS5 listen address")
		forwardLocal = flag.String("forward", "", "optional local TCP address to bridge raw HCR streams (e.g. 127.0.0.1:2222)")
		sshCmd       = flag.String("cmd", "", "run a single SSH command over HCR and exit")
		useTLS       = flag.Bool("tls", false, "use TLS transport to hcr-server")
		sni          = flag.String("sni", "", "TLS ServerName (default: server host)")
		insecure     = flag.Bool("insecure", true, "skip TLS certificate verification")
		maxFrame     = flag.Uint("max-frame", 0, "requested max download frame (0 = server default 16384)")
		pollUnits    = flag.Uint("poll-units", 256, "download sliding window in chunks (256..1024)")
		workers      = flag.Int("workers", 32, "parallel download poll workers")
		slotChunks   = flag.Uint("slot-chunks", 8, "chunks per poll worker slot (1..32)")
		calibrate    = flag.String("calibrate", "", "run calibration mode (echo or throughput) and exit")
		calibBytes   = flag.Uint("calibrate-bytes", 65536, "total bytes for calibration (1..524288)")
	)
	flag.Parse()

	var hostPort, user, pass string
	if *account != "" {
		var err error
		hostPort, user, pass, err = parseAccount(*account)
		if err != nil {
			log.Fatal(err)
		}
	} else if *serverAddr != "" {
		hostPort = *serverAddr
	} else {
		flag.Usage()
		os.Exit(2)
	}

	hcrCfg := client.Config{
		ServerAddr:       hostPort,
		TLS:              *useTLS,
		TLSConfig:        &tls.Config{ServerName: *sni, InsecureSkipVerify: *insecure},
		MaxDownloadFrame: uint32(*maxFrame),
		PollUnits:        uint16(*pollUnits),
		PollWorkers:      *workers,
		SlotChunks:       uint16(*slotChunks),
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if *calibrate != "" {
		var mode uint8
		switch strings.ToLower(*calibrate) {
		case "upload", "echo":
			mode = protocol.CalibrationUpload
		case "download", "throughput":
			mode = protocol.CalibrationDownload
		default:
			log.Fatalf("unknown calibration mode %q (expected upload or download)", *calibrate)
		}
		n, dur, err := client.Calibrate(ctx, hcrCfg, mode, uint32(*calibBytes))
		if err != nil {
			log.Fatalf("calibration failed: %v", err)
		}
		kbps := float64(n*8) / dur.Seconds() / 1000.0
		fmt.Printf("calibration %s OK: %d bytes in %v (%.1f kbps)\n", *calibrate, n, dur.Round(time.Millisecond), kbps)
		return
	}

	if *forwardLocal != "" {
		ln, err := net.Listen("tcp", *forwardLocal)
		if err != nil {
			log.Fatal(err)
		}
		defer ln.Close()
		go func() {
			<-ctx.Done()
			_ = ln.Close()
		}()
		log.Printf("HCR raw TCP bridge listening on %s -> %s", *forwardLocal, hostPort)
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(local net.Conn) {
				defer local.Close()
				remote, err := client.Dial(ctx, hcrCfg)
				if err != nil {
					log.Printf("HCR dial failed: %v", err)
					return
				}
				defer remote.Close()
				done := make(chan struct{}, 2)
				go func() { _, _ = io.Copy(remote, local); done <- struct{}{} }()
				go func() { _, _ = io.Copy(local, remote); done <- struct{}{} }()
				<-done
			}(c)
		}
	}

	if user == "" {
		log.Fatal("-s host:port@user:pass is required for SSH/SOCKS5 mode")
	}

	tun, err := client.DialSSH(ctx, client.SSHConfig{
		HCR:      hcrCfg,
		User:     user,
		Password: pass,
	})
	if err != nil {
		log.Fatal(err)
	}
	defer tun.Close()
	log.Printf("connected to %s via HCR (remote SSH: %s)", hostPort, tun.ServerVersion())

	if *sshCmd != "" {
		out, err := tun.RunCommand(*sshCmd)
		if len(out) > 0 {
			_, _ = os.Stdout.Write(out)
		}
		if err != nil {
			log.Fatal(err)
		}
		return
	}

	socksSrv, err := socks5.NewServer(tun, *listenSOCKS, 15*time.Second)
	if err != nil {
		log.Fatal(err)
	}
	go func() {
		<-ctx.Done()
		_ = socksSrv.Close()
	}()
	log.Printf("SOCKS5 listening on %s", *listenSOCKS)
	if err := socksSrv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

func parseAccount(s string) (server, user, pass string, err error) {
	at := strings.LastIndex(s, "@")
	if at < 0 {
		return "", "", "", fmt.Errorf("expected host:port@user:pass")
	}
	server = s[:at]
	cred := s[at+1:]
	colon := strings.Index(cred, ":")
	if colon < 0 {
		return "", "", "", fmt.Errorf("expected host:port@user:pass")
	}
	return server, cred[:colon], cred[colon+1:], nil
}
