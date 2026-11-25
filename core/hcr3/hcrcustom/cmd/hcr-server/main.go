package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"flag"
	"fmt"
	"log"
	"math/big"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/hcrcustom/hcrcustom/server"
)

const versionString = "VPS-MANAGER HCR 3.0 (base hcr-server 0.1.29 Patch 1)"

func main() {
	var (
		listen        = flag.String("listen", "", "required listen address")
		proxyHeader   = flag.Bool("proxy-protocol", false, "receive HAProxy PROXY v1 on a loopback listener")
		transport     = flag.String("transport", "auto", "transport mode: plain, tls, or auto")
		target        = flag.String("target", "127.0.0.1:22", "backend TCP target address")
		tlsCert       = flag.String("tls-cert", "", "path to TLS certificate PEM (optional; generates self-signed if empty)")
		tlsKey        = flag.String("tls-key", "", "path to TLS private key PEM")
		maxConns      = flag.Int("max-connections", 2048, "maximum concurrent TCP connections")
		maxSessions   = flag.Int("max-sessions", 32, "maximum active HCR sessions")
		maxPerIP      = flag.Int("max-sessions-per-ip", 16, "maximum active HCR sessions per client IP")
		pollTimeout   = flag.Duration("download-poll-timeout", 25*time.Second, "poll long-Wait timeout (0 = 25s)")
		maxFrame      = flag.Uint("max-download-frame", 16384, "default max download chunk size (1..262140)")
		statsInterval = flag.Duration("session-stats-interval", 0, "periodic session stats log interval")
		diagInterval  = flag.Duration("diagnostics-interval", 0, "periodic diagnostics log interval")
		logLevel      = flag.String("log-level", "info", "log level (debug, info, warn, error)")
		showVersion   = flag.Bool("version", false, "print version and exit")
		verbose       = flag.Bool("v", true, "log session lifecycle events")
	)
	flag.Parse()
	if *logLevel == "error" || *logLevel == "none" {
		*verbose = false
	}

	if *showVersion {
		fmt.Println(versionString)
		return
	}

	if *listen == "" {
		log.Fatal("informe --listen HOST:PORT")
	}

	var tlsCfg *tls.Config
	if *transport == "tls" || *transport == "auto" {
		var cert tls.Certificate
		var err error
		if *tlsCert != "" && *tlsKey != "" {
			cert, err = tls.LoadX509KeyPair(*tlsCert, *tlsKey)
			if err != nil {
				log.Fatalf("failed to load TLS keypair: %v", err)
			}
		} else {
			cert = selfSignedCert()
		}
		tlsCfg = &tls.Config{
			Certificates: []tls.Certificate{cert},
			MinVersion:   tls.VersionTLS12,
		}
	}

	srv, err := server.New(server.Config{
		Listen:           *listen,
		ProxyHeader:      *proxyHeader,
		Transport:        *transport,
		Target:           *target,
		TLSConfig:        tlsCfg,
		MaxConnections:   *maxConns,
		MaxSessions:      *maxSessions,
		MaxSessionsPerIP: *maxPerIP,
		PollTimeout:      *pollTimeout,
		MaxDownloadFrame: uint32(*maxFrame),
		Verbose:          *verbose,
	})
	if err != nil {
		log.Fatal(err)
	}

	if *statsInterval > 0 || *diagInterval > 0 {
		interval := *statsInterval
		if interval <= 0 || (*diagInterval > 0 && *diagInterval < interval) {
			interval = *diagInterval
		}
		go func() {
			t := time.NewTicker(interval)
			defer t.Stop()
			for range t.C {
				for _, st := range srv.SnapshotSessions() {
					log.Printf("session_stats sid=%x ip=%s up_next=%d up_pending=%d target_written=%d down_next=%d base=%d acked=%d replay_bytes=%d target_read=%d",
						st.ID[:4], st.ClientIP, st.UploadNext, st.UploadPending, st.TargetWritten,
						st.DownloadNext, st.DeliveryBase, st.Acked, st.ReplayBytes, st.TargetRead)
				}
			}
		}()
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sigCh
		_ = srv.Close()
	}()

	log.Printf("hcr-server listening on %s (transport=%s, target=%s, max_frame=%d)", *listen, *transport, *target, *maxFrame)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

func selfSignedCert() tls.Certificate {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "hcr-server"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(365 * 24 * time.Hour),
		DNSNames:     []string{"localhost"},
	}
	der, _ := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}
