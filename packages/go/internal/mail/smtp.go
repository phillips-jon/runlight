package mail

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"runlight.sh/go/internal/js"
)

// A small SMTP client: implicit TLS (465), STARTTLS (587), or plain (local
// relays), with AUTH PLAIN, over a net.Dialer connection.

// replyTimeout is how long each reply may take, as the TypeScript socket's idle timeout is.
const replyTimeout = 20 * time.Second

func b64(text string) string { return base64.StdEncoding.EncodeToString([]byte(text)) }

// wrap is `text.replace(/.{1,76}/g, "$&\r\n")` for base64, which has no line breaks.
func wrap(text string) string {
	var b strings.Builder
	for len(text) > 0 {
		n := min(76, len(text))
		b.WriteString(text[:n] + "\r\n")
		text = text[n:]
	}
	return b.String()
}

func encodeWord(text string) string {
	for i := 0; i < len(text); i++ {
		if text[i] < 0x20 || text[i] > 0x7e {
			return "=?UTF-8?B?" + b64(text) + "?="
		}
	}
	return text
}

// randomUUID is crypto.randomUUID(): a random version 4 UUID.
func randomUUID() string {
	var b [16]byte
	rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	h := hex.EncodeToString(b[:])
	return h[:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:]
}

// namedAddress is `/^(.*)<(.+)>$/.exec(from)`: the name and the address of `Name <address>`.
func namedAddress(from string) (string, string, bool) {
	if strings.IndexFunc(from, isLineTerminator) >= 0 || !strings.HasSuffix(from, ">") {
		return "", "", false
	}
	// (.*) is greedy, so the last < that leaves (.+) at least one character.
	i := strings.LastIndex(from[:max(0, len(from)-2)], "<")
	if i < 0 {
		return "", "", false
	}
	return from[:i], from[i+1 : len(from)-1], true
}

// Mime is the message as MIME: text and HTML alternatives, both base64. now is milliseconds
// since the epoch, and uuid stands in for crypto.randomUUID() (random when nil). Exported for
// its test.
func Mime(m Message, from string, now int64, uuid func() string) string {
	if uuid == nil {
		uuid = randomUUID
	}
	boundary := "rl-" + uuid()
	domain := "runlight.local"
	if parts := strings.Split(m.From, "@"); len(parts) > 1 {
		domain = parts[1]
	}
	fromHeader := from
	if name, address, ok := namedAddress(from); ok {
		fromHeader = encodeWord(js.Trim(name)) + " <" + address + ">"
	}
	headers := []string{
		"From: " + fromHeader,
		"To: " + m.To,
		"Subject: " + encodeWord(m.Subject),
		// Date's toUTCString(), with +0000 for GMT.
		"Date: " + time.UnixMilli(now).UTC().Format("Mon, 02 Jan 2006 15:04:05") + " +0000",
		"Message-ID: <" + uuid() + "@" + domain + ">",
		"MIME-Version: 1.0",
	}
	for _, p := range headerPairs(m) {
		headers = append(headers, p[0].(string)+": "+strings.NewReplacer("\r", "", "\n", "").Replace(js.String(p[1])))
	}
	headers = append(headers, `Content-Type: multipart/alternative; boundary="`+boundary+`"`)
	return strings.Join([]string{
		strings.Join(headers, "\r\n"),
		"",
		"--" + boundary,
		"Content-Type: text/plain; charset=utf-8",
		"Content-Transfer-Encoding: base64",
		"",
		wrap(b64(m.Text)),
		"--" + boundary,
		"Content-Type: text/html; charset=utf-8",
		"Content-Transfer-Encoding: base64",
		"",
		wrap(b64(m.HTML)),
		"--" + boundary + "--",
		"",
	}, "\r\n")
}

// SMTPSend sends one message over SMTP, from the address given. Each reply must come within
// 20 s, and the whole send within the deadline (60 s, or opts.Deadline), so a server that
// trickles a line now and then cannot hold the scheduled check that sends reports.
func SMTPSend(ctx context.Context, config Config, m Message, from string, opts Options) error {
	host := js.Trim(config["host"])
	security := config["security"]
	if security == "" {
		security = "starttls"
	}
	port := js.Number(config["port"])
	if port == 0 || math.IsNaN(port) {
		port = 587
		if security == "tls" {
			port = 465
		}
	}
	if port != math.Trunc(port) || port < 0 || port >= 65536 {
		// net.connect refuses it before anything is sent.
		return fmt.Errorf("Port should be >= 0 and < 65536. Received type number (%s).", js.FormatNumber(port))
	}
	deadline := opts.Deadline
	if deadline <= 0 {
		deadline = 60 * time.Second
	}
	address := host + ":" + js.FormatNumber(port)
	until := time.Now().Add(deadline)
	limited, cancel := context.WithDeadline(ctx, until)
	defer cancel()
	s := &session{ctx: ctx, limited: limited, until: until, host: host, port: int(port), address: address}
	s.lateMessage = "SMTP: " + address + " took longer than " + js.FormatNumber(js.Round(float64(deadline.Milliseconds())/1000)) + " s"
	defer s.close()
	stop := context.AfterFunc(limited, func() { s.interrupt() })
	defer stop()
	return s.converse(config, m, from, security, opts)
}

// session is one SMTP connection: the socket, the replies read from it (multi-line included,
// one at a time), and the whole send's deadline, which every wait is held to.
type session struct {
	ctx, limited  context.Context
	until         time.Time
	host, address string
	port          int
	lateMessage   string
	buffer        []byte
	lines         []string
	// mu guards conn, which interrupt reads from the goroutine that ends a send.
	mu   sync.Mutex
	conn net.Conn
}

type reply struct {
	code float64
	text string
}

// stopped is the error for a send its deadline or its caller ended, or nil.
func (s *session) stopped() error {
	if s.limited.Err() == nil && time.Now().Before(s.until) {
		return nil
	}
	if err := s.ctx.Err(); err != nil {
		return err
	}
	return mailError(s.lateMessage, "mail_slow", "host", s.address)
}

// interrupt wakes whatever the session is waiting on once the deadline passes.
func (s *session) interrupt() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.conn != nil {
		s.conn.SetDeadline(time.Unix(1, 0))
	}
}

func (s *session) setConn(conn net.Conn) {
	s.mu.Lock()
	s.conn = conn
	s.mu.Unlock()
}

// wait is when a wait of d must end: d from now, or the deadline if sooner.
func (s *session) wait(d time.Duration) time.Time {
	if t := time.Now().Add(d); t.Before(s.until) {
		return t
	}
	return s.until
}

func (s *session) close() {
	if s.conn != nil {
		s.conn.Close()
	}
}

func (s *session) tlsConfig(base *tls.Config) *tls.Config {
	var c *tls.Config
	if base != nil {
		c = base.Clone()
	} else {
		c = &tls.Config{}
	}
	c.ServerName = s.host
	return c
}

func (s *session) connect(useTLS bool, opts Options) error {
	dialer := net.Dialer{Timeout: replyTimeout}
	conn, err := dialer.DialContext(s.limited, "tcp", net.JoinHostPort(s.host, strconv.Itoa(s.port)))
	if err == nil && useTLS {
		secured := tls.Client(conn, s.tlsConfig(opts.TLS))
		conn = secured
		s.setConn(conn)
		conn.SetDeadline(s.wait(replyTimeout))
		err = secured.HandshakeContext(s.limited)
	} else if conn != nil {
		s.setConn(conn)
	}
	if s.limited.Err() != nil {
		return s.stopped()
	}
	if err != nil {
		detail := nodeMessage(err, s.host)
		return mailError("SMTP: could not connect to "+s.address+": "+detail, "mail_unreachable", "host", s.address, "detail", detail)
	}
	return nil
}

func (s *session) write(data string) error {
	s.conn.SetWriteDeadline(s.wait(replyTimeout))
	if _, err := io.WriteString(s.conn, data); err != nil {
		if stop := s.stopped(); stop != nil {
			return stop
		}
		return s.failure(err)
	}
	return nil
}

// failure is the error a socket's error event becomes.
func (s *session) failure(err error) error {
	if errors.Is(err, io.EOF) || errors.Is(err, net.ErrClosed) {
		return NewMailError("SMTP: the server closed the connection")
	}
	return NewMailError("SMTP: " + nodeMessage(err, s.host))
}

// next is the next whole reply. With quiet, no reply within the timeout is nil rather than an
// error; the deadline's error comes either way.
func (s *session) next(timeout time.Duration, quiet bool) (*reply, error) {
	chunk := make([]byte, 8192)
	for {
		for {
			at := bytes.Index(s.buffer, []byte("\r\n"))
			if at < 0 {
				break
			}
			line := js.WellFormed(string(s.buffer[:at]))
			s.buffer = s.buffer[at+2:]
			units := js.Units(line)
			s.lines = append(s.lines, js.Slice16(line, 4, len(units)))
			if len(units) <= 3 || units[3] != '-' {
				r := &reply{code: js.Number(js.Slice16(line, 0, 3)), text: strings.Join(s.lines, " ")}
				s.lines = nil
				return r, nil
			}
		}
		if err := s.stopped(); err != nil {
			return nil, err
		}
		s.conn.SetReadDeadline(s.wait(timeout))
		n, err := s.conn.Read(chunk)
		s.buffer = append(s.buffer, chunk[:n]...)
		if err == nil || n > 0 && !isTimeout(err) {
			continue
		}
		if stop := s.stopped(); stop != nil {
			return nil, stop
		}
		if isTimeout(err) {
			if n > 0 {
				continue
			}
			if quiet {
				return nil, nil
			}
			return nil, NewMailError("SMTP: timed out")
		}
		return nil, s.failure(err)
	}
}

func isTimeout(err error) bool {
	var t interface{ Timeout() bool }
	return errors.As(err, &t) && t.Timeout()
}

// startTLS turns on TLS after STARTTLS. Anything the server sent before it is dropped, as a new
// reader would.
func (s *session) startTLS(opts Options) error {
	s.buffer, s.lines = nil, nil
	secured := tls.Client(s.conn, s.tlsConfig(opts.TLS))
	s.setConn(secured)
	secured.SetDeadline(s.wait(replyTimeout))
	err := secured.HandshakeContext(s.limited)
	if stop := s.stopped(); stop != nil {
		return stop
	}
	if err != nil {
		return NewMailError("SMTP: TLS failed: " + nodeMessage(err, s.host))
	}
	secured.SetDeadline(time.Time{})
	return nil
}

func (s *session) converse(config Config, m Message, from, security string, opts Options) error {
	if err := s.connect(security == "tls", opts); err != nil {
		return err
	}
	s.conn.SetDeadline(time.Time{})
	expect := func(what string, codes ...float64) (*reply, error) {
		r, err := s.next(replyTimeout, false)
		if err != nil {
			return nil, err
		}
		for _, c := range codes {
			if r.code == c {
				return r, nil
			}
		}
		return nil, NewMailError(js.Head16("SMTP "+what+": "+js.FormatNumber(r.code)+" "+r.text, 300))
	}
	line := func(text string) error { return s.write(text + "\r\n") }
	// Each step writes a line and expects one of the codes; the first failure ends the send.
	step := func(text, what string, codes ...float64) (*reply, error) {
		if err := line(text); err != nil {
			return nil, err
		}
		return expect(what, codes...)
	}

	if _, err := expect("greeting", 220); err != nil {
		return err
	}
	name := ""
	if parts := strings.Split(from, "@"); len(parts) > 1 {
		name = strings.TrimSuffix(parts[1], ">")
	}
	if name == "" {
		name = "localhost"
	}
	ehlo, err := step("EHLO "+name, "EHLO", 250)
	if err != nil {
		return err
	}
	if security == "starttls" {
		if !strings.Contains(asciiUpper(ehlo.text), "STARTTLS") {
			return mailError("SMTP: the server does not offer STARTTLS; pick tls or none", "smtp_starttls")
		}
		if _, err := step("STARTTLS", "STARTTLS", 220); err != nil {
			return err
		}
		if err := s.startTLS(opts); err != nil {
			return err
		}
		if _, err := step("EHLO "+name, "EHLO", 250); err != nil {
			return err
		}
	}
	if config["username"] != "" {
		if _, err := step("AUTH PLAIN "+b64("\x00"+config["username"]+"\x00"+config["password"]), "sign-in", 235); err != nil {
			return err
		}
	}
	if _, err := step("MAIL FROM:<"+m.From+">", "MAIL FROM", 250); err != nil {
		return err
	}
	if _, err := step("RCPT TO:<"+m.To+">", "RCPT TO", 250, 251); err != nil {
		return err
	}
	if _, err := step("DATA", "DATA", 354); err != nil {
		return err
	}
	// A line starting with a dot gets a second one, so it is not read as the end.
	now := opts.now()
	if err := s.write(strings.ReplaceAll(Mime(m, from, now, opts.UUID), "\r\n.", "\r\n..") + "\r\n.\r\n"); err != nil {
		return err
	}
	if _, err := expect("message", 250); err != nil {
		return err
	}
	if err := line("QUIT"); err != nil {
		// The message is sent; only the deadline still counts.
		var late *MailError
		if errors.As(err, &late) && late.Code == "mail_slow" || s.ctx.Err() != nil {
			return err
		}
		return nil
	}
	// Wait for the goodbye, but never fail a sent message over it.
	if _, err := s.next(2*time.Second, true); err != nil {
		var late *MailError
		if errors.As(err, &late) && late.Code == "mail_slow" || s.ctx.Err() != nil {
			return err
		}
	}
	return nil
}

func asciiUpper(s string) string {
	return strings.Map(func(r rune) rune {
		if 'a' <= r && r <= 'z' {
			return r - 32
		}
		return r
	}, s)
}

// nodeMessage is the message Node gives for a socket or TLS error, where Go's words differ, so
// the dashboard reads the same whichever server sent the mail.
func nodeMessage(err error, host string) string {
	var dns *net.DNSError
	if errors.As(err, &dns) && dns.IsNotFound {
		return "getaddrinfo ENOTFOUND " + host
	}
	if isTimeout(err) {
		return "timed out"
	}
	var op *net.OpError
	if errors.As(err, &op) {
		names := map[syscall.Errno]string{
			syscall.ECONNREFUSED: "ECONNREFUSED", syscall.ECONNRESET: "ECONNRESET", syscall.EHOSTUNREACH: "EHOSTUNREACH",
			syscall.ENETUNREACH: "ENETUNREACH", syscall.ETIMEDOUT: "ETIMEDOUT", syscall.EPIPE: "EPIPE",
		}
		var errno syscall.Errno
		if errors.As(err, &errno) {
			if name, ok := names[errno]; ok {
				switch op.Op {
				case "dial":
					if addr, ok := op.Addr.(*net.TCPAddr); ok {
						return "connect " + name + " " + addr.IP.String() + ":" + strconv.Itoa(addr.Port)
					}
					return "connect " + name
				case "read", "write":
					return op.Op + " " + name
				}
			}
		}
	}
	var unknown x509.UnknownAuthorityError
	if errors.As(err, &unknown) {
		if c := unknown.Cert; c != nil && bytes.Equal(c.RawIssuer, c.RawSubject) {
			return "self-signed certificate"
		}
		return "unable to get local issuer certificate"
	}
	var invalid x509.CertificateInvalidError
	if errors.As(err, &invalid) && invalid.Reason == x509.Expired {
		return "certificate has expired"
	}
	var hostname x509.HostnameError
	if errors.As(err, &hostname) && hostname.Certificate != nil {
		c := hostname.Certificate
		if ip := net.ParseIP(hostname.Host); ip != nil {
			ips := make([]string, len(c.IPAddresses))
			for i, a := range c.IPAddresses {
				ips[i] = a.String()
			}
			return "Hostname/IP does not match certificate's altnames: IP: " + hostname.Host + " is not in the cert's list: " + strings.Join(ips, ", ")
		}
		var alt []string
		for _, d := range c.DNSNames {
			alt = append(alt, "DNS:"+d)
		}
		for _, a := range c.IPAddresses {
			alt = append(alt, "IP Address:"+a.String())
		}
		return "Hostname/IP does not match certificate's altnames: Host: " + hostname.Host + ". is not in the cert's altnames: " + strings.Join(alt, ", ")
	}
	return err.Error()
}
