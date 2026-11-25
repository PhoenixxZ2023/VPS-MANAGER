package client

import (
	"context"
	"fmt"
	"net"
	"time"

	"golang.org/x/crypto/ssh"
)

type SSHConfig struct {
	HCR           Config
	User          string
	Password      string
	ClientVersion string
}

type SSHTunnel struct {
	hcrConn   *Conn
	sshConn   ssh.Conn
	sshClient *ssh.Client
}

func DialSSH(ctx context.Context, cfg SSHConfig) (*SSHTunnel, error) {
	hcrConn, err := Dial(ctx, cfg.HCR)
	if err != nil {
		return nil, err
	}
	ver := cfg.ClientVersion
	if ver == "" {
		ver = "SSH-2.0-TrileadSSH2Java_213"
	}
	sshCfg := &ssh.ClientConfig{
		User: cfg.User,
		Auth: []ssh.AuthMethod{
			ssh.Password(cfg.Password),
			ssh.KeyboardInteractive(func(name, instruction string, questions []string, echos []bool) ([]string, error) {
				ans := make([]string, len(questions))
				for i := range ans {
					ans[i] = cfg.Password
				}
				return ans, nil
			}),
		},
		ClientVersion:   ver,
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         20 * time.Second,
	}
	c, chans, reqs, err := ssh.NewClientConn(hcrConn, cfg.HCR.ServerAddr, sshCfg)
	if err != nil {
		_ = hcrConn.Close()
		return nil, fmt.Errorf("ssh handshake over hcr failed: %w", err)
	}
	return &SSHTunnel{
		hcrConn:   hcrConn,
		sshConn:   c,
		sshClient: ssh.NewClient(c, chans, reqs),
	}, nil
}

func (t *SSHTunnel) DialTCP(addr string) (net.Conn, error) {
	return t.sshClient.Dial("tcp", addr)
}

func (t *SSHTunnel) RunCommand(cmd string) ([]byte, error) {
	sess, err := t.sshClient.NewSession()
	if err != nil {
		return nil, err
	}
	defer sess.Close()
	return sess.CombinedOutput(cmd)
}

func (t *SSHTunnel) ServerVersion() string {
	return string(t.sshConn.ServerVersion())
}

func (t *SSHTunnel) Close() error {
	_ = t.sshClient.Close()
	return t.hcrConn.Close()
}
