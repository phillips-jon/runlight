package mail

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"errors"
	"math/big"
	"net"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"runlight.sh/go/internal/js"
)

// A fake SMTP server on 127.0.0.1, as the PHP tests' smtp-server.php: it serves one connection
// at a time, and after each one sends what the client wrote on conversations.
//
// relay answers as the TS tests' relay does (AUTH PLAIN checks jon/pw, no STARTTLS).
// starttls is relay that offers STARTTLS and turns TLS on when asked.
// tls is relay behind implicit TLS.
// trickle sends "220-still here" every 100 ms and never finishes its greeting.
type fakeSMTP struct {
	listener      net.Listener
	port          int
	mode          string
	certificate   tls.Certificate
	conversations chan conversation
}

type conversation struct {
	received string
	closed   bool
}

func startSMTP(t *testing.T, mode string) *fakeSMTP {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s := &fakeSMTP{listener: listener, port: listener.Addr().(*net.TCPAddr).Port, mode: mode, conversations: make(chan conversation, 16)}
	s.certificate, _ = selfSigned(t)
	if mode == "tls" {
		s.listener = tls.NewListener(listener, &tls.Config{Certificates: []tls.Certificate{s.certificate}})
	}
	t.Cleanup(func() { s.listener.Close() })
	go func() {
		for {
			conn, err := s.listener.Accept()
			if err != nil {
				return
			}
			s.serve(conn)
		}
	}()
	return s
}

func (s *fakeSMTP) config(security string) Config {
	return Config{"service": "smtp", "host": "127.0.0.1", "port": strconv.Itoa(s.port), "security": security}
}

// conversation is what the next finished connection received, waiting up to a few seconds.
func (s *fakeSMTP) conversation(t *testing.T) conversation {
	t.Helper()
	select {
	case c := <-s.conversations:
		return c
	case <-time.After(5 * time.Second):
		t.Fatal("no conversation came")
		return conversation{}
	}
}

func (s *fakeSMTP) serve(conn net.Conn) {
	var received strings.Builder
	defer func() {
		conn.Close()
		s.conversations <- conversation{received: received.String(), closed: true}
	}()
	if s.mode == "trickle" {
		buf := make([]byte, 8192)
		for {
			if _, err := conn.Write([]byte("220-still here\r\n")); err != nil {
				return
			}
			conn.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
			n, err := conn.Read(buf)
			received.Write(buf[:n])
			if err != nil && !isTimeout(err) {
				return
			}
		}
	}
	reader := bufio.NewReader(conn)
	write := func(text string) { conn.Write([]byte(text)) }
	write("220 test ESMTP\r\n")
	inData := false
	for {
		line, err := reader.ReadString('\n')
		received.WriteString(line)
		if err != nil {
			return
		}
		line = strings.TrimSuffix(line, "\r\n")
		if inData {
			if line == "." {
				inData = false
				write("250 queued\r\n")
			}
			continue
		}
		switch {
		case strings.HasPrefix(line, "EHLO"):
			if s.mode == "starttls" {
				if _, ok := conn.(*tls.Conn); !ok {
					write("250-test\r\n250-STARTTLS\r\n250 AUTH PLAIN\r\n")
					continue
				}
			}
			write("250-test\r\n250-SIZE 1000\r\n250 AUTH PLAIN\r\n")
		case line == "STARTTLS":
			write("220 go ahead\r\n")
			conn = tls.Server(conn, &tls.Config{Certificates: []tls.Certificate{s.certificate}})
			reader = bufio.NewReader(conn)
		case strings.HasPrefix(line, "AUTH PLAIN"):
			if plain, _ := base64.StdEncoding.DecodeString(line[11:]); string(plain) == "\x00jon\x00pw" {
				write("235 ok\r\n")
			} else {
				write("535 no\r\n")
			}
		case line == "DATA":
			inData = true
			write("354 go\r\n")
		case line == "QUIT":
			write("221 bye\r\n")
			// Whatever the client still sends before it hangs up.
			conn.SetReadDeadline(time.Now().Add(time.Second))
			rest := make([]byte, 8192)
			for {
				n, err := reader.Read(rest)
				received.Write(rest[:n])
				if err != nil {
					return
				}
			}
		default:
			write("250 ok\r\n")
		}
	}
}

var (
	certificate tls.Certificate
	roots       *x509.CertPool
)

// selfSigned is a certificate for 127.0.0.1, and a pool that trusts it.
func selfSigned(t *testing.T) (tls.Certificate, *x509.CertPool) {
	t.Helper()
	if roots != nil {
		return certificate, roots
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "runlight test"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IPAddresses: []net.IP{net.IPv4(127, 0, 0, 1)}, IsCA: true, BasicConstraintsValid: true,
		KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	parsed, _ := x509.ParseCertificate(der)
	certificate = tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
	roots = x509.NewCertPool()
	roots.AddCert(parsed)
	return certificate, roots
}

func TestSMTPSendsTheTypeScriptConversation(t *testing.T) {
	server := startSMTP(t, "relay")
	f := outbound(t)
	now := int64(js.Num(f.Value("now")))
	cases := js.Arr(f.Value("smtp"))
	for i, c := range cases {
		config := configFrom(js.Dig(c, "config"))
		config["service"], config["host"], config["port"] = "smtp", "127.0.0.1", strconv.Itoa(server.port)
		err := SMTPSend(context.Background(), config, messageFrom(js.Dig(c, "message")), js.Str(js.Dig(c, "from")),
			Options{Now: func() int64 { return now }, UUID: counting()})
		if got, want := js.Stringify(errorValue(err)), js.Stringify(js.Dig(c, "error")); got != want {
			t.Errorf("case %d error\n got %s\nwant %s", i, got, want)
		}
		if got, want := server.conversation(t).received, js.Str(js.Dig(c, "received")); got != want {
			t.Errorf("case %d received\n got %q\nwant %q", i, got, want)
		}
	}
	if len(cases) != 4 {
		t.Fatalf("%d smtp cases", len(cases))
	}
}

// commands are the SMTP verbs a conversation holds, and the message text between DATA and the dot.
func commands(received string) ([]string, string) {
	var seen []string
	var data strings.Builder
	inData := false
	for _, line := range strings.Split(received, "\r\n") {
		if inData {
			if line == "." {
				inData = false
			} else {
				data.WriteString(line + "\n")
			}
			continue
		}
		if line != "" {
			seen = append(seen, strings.Split(line, " ")[0])
		}
		inData = line == "DATA"
	}
	return seen, data.String()
}

func TestSMTPStartTLSRefusedIsAnErrorAndAPlainRelayTakesTheMessage(t *testing.T) {
	server := startSMTP(t, "relay")
	ctx := context.Background()
	mustMatch(t, `does not offer STARTTLS`, SMTPSend(ctx, server.config("starttls"), message, "reports@example.com", Options{}))
	server.conversation(t)
	config := server.config("none")
	config["username"], config["password"] = "jon", "pw"
	m := message
	m.Text = ".starts with a dot"
	if err := SMTPSend(ctx, config, m, "Runlight <reports@example.com>", Options{}); err != nil {
		t.Fatal(err)
	}
	seen, data := commands(server.conversation(t).received)
	if strings.Join(seen, " ") != "EHLO AUTH MAIL RCPT DATA QUIT" {
		t.Fatal(seen)
	}
	for _, want := range []string{"Subject: Hello", "List-Unsubscribe: <https://x/u>", "multipart/alternative"} {
		if !strings.Contains(data, want) {
			t.Fatalf("%q not in %q", want, data)
		}
	}
}

func TestSMTPThroughSendSendsToo(t *testing.T) {
	server := startSMTP(t, "relay")
	if err := Send(context.Background(), nil, server.config("none"), message); err != nil {
		t.Fatal(err)
	}
	if received := server.conversation(t).received; !strings.Contains(received, "From: Runlight <reports@example.com>\r\n") {
		t.Fatal(received)
	}
}

func TestSMTPServerThatTricklesIsCutOffAtTheDeadline(t *testing.T) {
	server := startSMTP(t, "trickle")
	started := time.Now()
	err := SMTPSend(context.Background(), server.config("none"), message, "reports@example.com", Options{Deadline: 600 * time.Millisecond})
	want := `{"message":"SMTP: 127.0.0.1:` + strconv.Itoa(server.port) + ` took longer than 1 s","code":"mail_slow","params":{"host":"127.0.0.1:` + strconv.Itoa(server.port) + `"}}`
	if got := js.Stringify(errorValue(err)); got != want {
		t.Fatal(got)
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatal("the send gives up at its deadline, not", elapsed)
	}
	if !server.conversation(t).closed {
		t.Fatal("the connection is closed")
	}
}

func TestSMTPCallerCancelsTheSend(t *testing.T) {
	server := startSMTP(t, "trickle")
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	err := SMTPSend(ctx, server.config("none"), message, "reports@example.com", Options{})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal(err)
	}
}

func TestSMTPThatCannotConnectSaysSo(t *testing.T) {
	// A port that was free a moment ago.
	probe, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := strconv.Itoa(probe.Addr().(*net.TCPAddr).Port)
	probe.Close()
	err = SMTPSend(context.Background(), Config{"service": "smtp", "host": "127.0.0.1", "port": port, "security": "none"}, message, "reports@example.com", Options{})
	want := `{"message":"SMTP: could not connect to 127.0.0.1:` + port + `: connect ECONNREFUSED 127.0.0.1:` + port + `","code":"mail_unreachable","params":{"host":"127.0.0.1:` + port + `","detail":"connect ECONNREFUSED 127.0.0.1:` + port + `"}}`
	if got := js.Stringify(errorValue(err)); got != want {
		t.Fatal(got)
	}
}

func TestSMTPBadPortIsRefusedAsNodeRefusesIt(t *testing.T) {
	err := SMTPSend(context.Background(), Config{"service": "smtp", "host": "127.0.0.1", "port": "70000", "security": "none"}, message, "a@b", Options{})
	if err == nil || err.Error() != "Port should be >= 0 and < 65536. Received type number (70000)." {
		t.Fatal(err)
	}
}

func TestSMTPStartTLSAndImplicitTLS(t *testing.T) {
	_, pool := selfSigned(t)
	trusted := Options{TLS: &tls.Config{RootCAs: pool}}
	ctx := context.Background()

	server := startSMTP(t, "starttls")
	if err := SMTPSend(ctx, server.config("starttls"), message, "Runlight <reports@example.com>", trusted); err != nil {
		t.Fatal(err)
	}
	received := server.conversation(t).received
	if !strings.HasPrefix(received, "EHLO example.com\r\nSTARTTLS\r\nEHLO example.com\r\nMAIL FROM:<reports@example.com>\r\n") || !strings.HasSuffix(received, "\r\n.\r\nQUIT\r\n") {
		t.Fatal(received)
	}
	err := SMTPSend(ctx, server.config("starttls"), message, "reports@example.com", Options{})
	if got := js.Stringify(errorValue(err)); got != `{"message":"SMTP: TLS failed: self-signed certificate","code":"mail_failed","params":{"detail":"SMTP: TLS failed: self-signed certificate"}}` {
		t.Fatal(got)
	}
	server.conversation(t)

	server = startSMTP(t, "tls")
	if err := SMTPSend(ctx, server.config("tls"), message, "reports@example.com", trusted); err != nil {
		t.Fatal(err)
	}
	if seen, _ := commands(server.conversation(t).received); strings.Join(seen, " ") != "EHLO MAIL RCPT DATA QUIT" {
		t.Fatal(seen)
	}
	err = SMTPSend(ctx, server.config("tls"), message, "reports@example.com", Options{})
	port := strconv.Itoa(server.port)
	if got := js.Stringify(errorValue(err)); got != `{"message":"SMTP: could not connect to 127.0.0.1:`+port+`: self-signed certificate","code":"mail_unreachable","params":{"host":"127.0.0.1:`+port+`","detail":"self-signed certificate"}}` {
		t.Fatal(got)
	}
}

func TestSMTPReplyCodesAreReadAsNumberReadsThem(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		conn.Write([]byte("2x0-first\r\n2x0 second\r\n"))
		time.Sleep(time.Second)
	}()
	port := strconv.Itoa(listener.Addr().(*net.TCPAddr).Port)
	err = SMTPSend(context.Background(), Config{"host": "127.0.0.1", "port": port, "security": "none"}, message, "a@b", Options{})
	if got := js.Stringify(errorValue(err)); !regexp.MustCompile(`^\{"message":"SMTP greeting: NaN first second"`).MatchString(got) {
		t.Fatal(got)
	}
}
