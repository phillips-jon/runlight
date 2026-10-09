package server

// runlight agents: counts AI agents on a site that has only the script tag,
// by reading its web server's access log. Agents do not run JavaScript, so
// the tracker never sees them; the server that answered them did.
//
// It reads nginx and Apache's combined format and Caddy's JSON lines, keeps
// successful GETs from known AI agents, and sends them in batches to a
// Runlight's /api/observe with the site's observe key. Nothing else in the log
// leaves the machine. With Follow it keeps reading as the log grows and
// carries on after the log is rotated. Without it, it reads what is new and
// stops, for cron. In both modes State remembers how far it read, so the next
// run, or a restarted follow, carries on from there.

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	runlight "runlight.sh/go"
	"runlight.sh/go/internal/importers"
	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
	"runlight.sh/go/internal/whatwg"
)

// Fetch is one page an AI agent fetched.
type Fetch struct {
	URL       string  `json:"url"`
	UserAgent string  `json:"userAgent"`
	At        float64 `json:"at"`
}

// Hit is one log line as a request.
type Hit struct {
	Method    any     `json:"method"`
	URL       string  `json:"url"`
	Status    float64 `json:"status"`
	UserAgent string  `json:"userAgent"`
	At        float64 `json:"at"`
}

// pageURL is a request target as a page on the site. Absolute targets ("GET
// http://other/x", a proxy request) name somewhere else and are skipped. The
// target is set as the path and query of the site's own address, never
// parsed as a URL, so "//x" and "/\x" stay paths on the site.
func pageURL(target, base string) (string, bool) {
	if !strings.HasPrefix(target, "/") {
		return "", false
	}
	u, err := whatwg.Parse(base)
	if err != nil {
		return "", false
	}
	path, search := target, ""
	if at := strings.Index(target, "?"); at >= 0 {
		path, search = target[:at], target[at:]
	}
	u.SetPathname("/" + strings.TrimLeft(path, "/"))
	u.SetSearch(search)
	u.SetHash("")
	return u.Href(), true
}

var months = map[string]time.Month{"Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6, "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12}

var logTimePattern = regexp.MustCompile(`^(\d{2})/(\w{3})/(\d{4}):(\d{2}):(\d{2}):(\d{2}) ([+-])(\d{2})(\d{2})$`)

// logTime is "07/Oct/2026:13:55:36 -0400" as epoch milliseconds, NaN when it is not one.
func logTime(value string) float64 {
	m := logTimePattern.FindStringSubmatch(value)
	if m == nil {
		return math.NaN()
	}
	mon, ok := months[m[2]]
	if !ok {
		return math.NaN()
	}
	n := func(s string) int { v, _ := strconv.Atoi(s); return v }
	// Date.UTC reads a year from 0 to 99 as 1900 to 1999.
	year := n(m[3])
	if year <= 99 {
		year += 1900
	}
	local := time.Date(year, mon, n(m[1]), n(m[4]), n(m[5]), n(m[6]), 0, time.UTC).UnixMilli()
	offset := int64(n(m[8])*60+n(m[9])) * 60_000
	if m[7] == "-" {
		offset = -offset
	}
	return float64(local - offset)
}

var (
	// host? ip - user [time] "METHOD /path HTTP/x" status bytes "referrer" "user agent"
	combined   = regexp.MustCompile(`^(?:(\S+) )?\S+ \S+ \S+ \[([^\]]+)\] "(\S+) (\S+)[^"]*" (\d{3}) \S+ "(?:[^"\\]|\\.)*" "((?:[^"\\]|\\.)*)"`)
	hasLetter  = regexp.MustCompile(`(?i)[a-z]`)
	onlyDigits = regexp.MustCompile(`^[\d.:]+$`)
	portSuffix = regexp.MustCompile(`:\d+$`)
	hostless   = regexp.MustCompile(`"\S+ /\S* [^"]*" \d{3}`)
)

func truthy(v any) bool { return js.Truthy(v) }

// ParseLine is one log line as a request, or nil. site is the address
// pages live at (https://example.com), for formats that do not record the
// host.
func ParseLine(line, site string) *Hit {
	text := js.Trim(line)
	if text == "" {
		return nil
	}
	if strings.HasPrefix(text, "{") {
		// Caddy: {"ts": 1696..., "request": {"method", "host", "uri", "headers": {"User-Agent": [...]}}, "status": 200}
		entry, err := js.Parse(text)
		if err != nil {
			return nil
		}
		request := js.Dig(entry, "request")
		uri, method := js.Dig(request, "uri"), js.Dig(request, "method")
		if !truthy(uri) || !truthy(method) {
			return nil
		}
		host := site
		if h := js.Dig(request, "host"); truthy(h) {
			scheme := "https"
			if !truthy(js.Dig(request, "tls")) && strings.HasPrefix(site, "http://") {
				scheme = "http"
			}
			host = scheme + "://" + js.String(h)
		}
		if host == "" {
			return nil
		}
		ua := ""
		for _, name := range []string{"User-Agent", "user-agent"} {
			if v := js.Dig(request, "headers", name, 0); v != nil {
				if _, u := v.(js.Undefined); !u {
					ua = js.String(v)
					break
				}
			}
		}
		var at float64
		switch ts := js.Dig(entry, "ts").(type) {
		case float64:
			at = ts * 1000
		case nil, js.Undefined:
			at = importers.ParseDate("")
		default:
			at = importers.ParseDate(js.String(ts))
		}
		target, ok := uri.(string)
		if !ok {
			return nil
		}
		url, ok := pageURL(target, host)
		if !ok {
			return nil
		}
		status := js.Dig(entry, "status")
		if status == nil {
			status = 0.0
		} else if _, u := status.(js.Undefined); u {
			status = 0.0
		}
		return &Hit{Method: method, URL: url, Status: js.ToNumber(status), UserAgent: ua, At: at}
	}
	m := combined.FindStringSubmatch(text)
	if m == nil {
		return nil
	}
	// A vhost column first ("example.com:443 1.2.3.4 - - [...]") names the host; otherwise site does.
	base := site
	if m[1] != "" && hasLetter.MatchString(m[1]) && !onlyDigits.MatchString(m[1]) {
		base = "https://" + portSuffix.ReplaceAllString(m[1], "")
	}
	if base == "" {
		return nil
	}
	url, ok := pageURL(m[4], base)
	if !ok {
		return nil
	}
	status, _ := strconv.Atoi(m[5])
	return &Hit{Method: m[3], URL: url, Status: float64(status), UserAgent: strings.ReplaceAll(m[6], `\"`, `"`), At: logTime(m[2])}
}

// AgentFetch is a line worth sending: a GET that succeeded, from a known AI
// agent. now stands in for a time the line does not give.
func AgentFetch(line, site string, now int64) *Fetch {
	hit := ParseLine(line, site)
	if hit == nil || hit.Method != "GET" || hit.Status < 200 || hit.Status >= 400 || runlight.AiAgentOf(hit.UserAgent) == nil {
		return nil
	}
	at := hit.At
	if math.IsNaN(at) || math.IsInf(at, 0) {
		at = float64(now)
	}
	return &Fetch{URL: hit.URL, UserAgent: hit.UserAgent, At: at}
}

// AgentsOptions configure a run of RunAgents.
type AgentsOptions struct {
	Log string
	// To is the Runlight to report to, as its dashboard address.
	To  string
	Key string
	// Site is the site's address, for logs with no host in them.
	Site   string
	Follow bool
	// State is where runs remember how far they read, so the next one (or a restarted follow) carries on.
	State string
	// Out gets each line to show; nil prints them.
	Out func(line string)
	// Poll is how often a follow looks at the log, 2 seconds by default.
	Poll    time.Duration
	Fetcher runlight.Fetcher
}

// batchSize is the most fetches /api/observe takes at once.
const batchSize = 500

// sendError is a failure to reach Runlight or have it take a batch, told apart from a failure to read the log.
type sendError struct{ message string }

func (e *sendError) Error() string { return e.message }

func send(ctx context.Context, o AgentsOptions, fetches []Fetch) (float64, error) {
	fetcher := o.Fetcher
	if fetcher == nil {
		fetcher = web.HTTPFetcher{}
	}
	body := js.Stringify(js.NewObject("fetches", fetches))
	answer, err := fetcher.Fetch(ctx, strings.TrimRight(o.To, "/")+"/api/observe", web.FetchInit{Method: "POST",
		Headers: web.NewHeaders("authorization", "Bearer "+o.Key, "content-type", "application/json"), Body: []byte(body), Timeout: 30 * time.Second})
	if err != nil {
		return 0, &sendError{err.Error()}
	}
	if answer.Status == 401 {
		return 0, &sendError{"Runlight refused the key. Use the site's key from Settings, Install, Key for CMS plugins."}
	}
	if !answer.OK() {
		return 0, &sendError{fmt.Sprintf("Runlight answered %d: %s", answer.Status, js.Head16(answer.Text(), 200))}
	}
	parsed, _ := answer.JSON()
	if n, ok := js.Dig(parsed, "recorded").(float64); ok {
		return n, nil
	}
	return 0, nil
}

// saved is where a run stopped: the log's inode, the byte offset, and a fingerprint of the log's start.
type saved struct {
	Ino    float64 `json:"ino"`
	Offset float64 `json:"offset"`
	Head   string  `json:"head,omitempty"`
	Length *int64  `json:"length,omitempty"`
}

const (
	// chunkSize is the most of a log read at once, so a log of any size fits in memory a piece at a time.
	chunkSize = 32 * 1024 * 1024
	// headSize is how many bytes at the start of a log identify it.
	headSize = 256
)

type fingerprint struct {
	head   string
	length int64
}

// headOf is a fingerprint of the log's first bytes. A log rotated by
// copying and truncating keeps its inode, so a different start is how a new
// log shows itself.
func headOf(f *os.File, length int64) (fingerprint, error) {
	info, err := f.Stat()
	if err != nil {
		return fingerprint{}, err
	}
	buffer := make([]byte, min(length, info.Size()))
	if _, err := f.ReadAt(buffer, 0); err != nil && !errors.Is(err, io.EOF) {
		return fingerprint{}, err
	}
	sum := sha256.Sum256(buffer)
	return fingerprint{hex.EncodeToString(sum[:]), int64(len(buffer))}, nil
}

func headOfPath(path string, length int64) (fingerprint, error) {
	f, err := os.Open(path)
	if err != nil {
		return fingerprint{}, err
	}
	defer f.Close()
	return headOf(f, length)
}

// sameLog is whether the log at this inode still starts the way it did, so a saved place in it still holds.
func sameLog(path string, s saved, ino uint64, size int64) bool {
	if uint64(s.Ino) != ino {
		return false
	}
	if s.Head == "" || s.Length == nil {
		return true
	}
	if size < *s.Length {
		return false
	}
	h, err := headOfPath(path, *s.Length)
	return err == nil && h.head == s.Head
}

type chunk struct {
	lines []string
	ends  []int64
	next  int64
	more  bool
}

// readFrom reads whole lines from a byte offset, at most a chunk, and says
// where the next read starts. Offsets count bytes up to each newline byte,
// so a malformed character cannot shift them. ends holds where the line
// after each one starts, so a place can be saved part way through a chunk.
func readFrom(f *os.File, offset int64) (chunk, error) {
	info, err := f.Stat()
	if err != nil {
		return chunk{}, err
	}
	size := info.Size()
	if size <= offset {
		return chunk{next: offset}, nil
	}
	buffer := make([]byte, min(size-offset, chunkSize))
	n, err := f.ReadAt(buffer, offset)
	if err != nil && !errors.Is(err, io.EOF) {
		return chunk{}, err
	}
	buffer = buffer[:n]
	end := bytes.LastIndexByte(buffer, '\n')
	// A half-written last line waits for the next read (or, in a chunk with no newline at all, is skipped).
	if end < 0 {
		if len(buffer) == chunkSize {
			return chunk{next: offset + int64(len(buffer)), more: true}, nil
		}
		return chunk{next: offset}, nil
	}
	out := chunk{next: offset + int64(end) + 1, more: offset+int64(len(buffer)) < size}
	for start := 0; start <= end; {
		newline := start + bytes.IndexByte(buffer[start:], '\n')
		out.lines = append(out.lines, web.DecodeUTF8(buffer[start:newline]))
		out.ends = append(out.ends, offset+int64(newline)+1)
		start = newline + 1
	}
	return out, nil
}

// lock takes the lock beside a state file, so two runs never read from the
// same place and send the same lines twice. The lock holds the run's process
// id; a lock left by a process that is no longer running is taken over.
// Returns the release.
func lock(state string) (func(), error) {
	path := state + ".lock"
	mine := strconv.Itoa(os.Getpid())
	for attempt := 0; attempt < 3; attempt++ {
		f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
		if err == nil {
			_, err = f.WriteString(mine)
			f.Close()
			if err != nil {
				return nil, err
			}
			return func() {
				if held, err := os.ReadFile(path); err == nil && string(held) == mine {
					os.Remove(path)
				}
			}, nil
		}
		if !errors.Is(err, os.ErrExist) {
			return nil, err
		}
		raw, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		held := strings.TrimSpace(string(raw))
		pid, _ := strconv.Atoi(held)
		// A lock being written has no id in it yet, so it counts as held.
		if held == "" || (pid > 0 && running(pid)) {
			break
		}
		// Stale. Moving it aside is atomic, so of two runs taking it over only one moves this lock; one
		// that finds a newer lock moved aside puts it back.
		aside := path + "." + mine
		if err := os.Rename(path, aside); err != nil {
			continue
		}
		if moved, _ := os.ReadFile(aside); strings.TrimSpace(string(moved)) != held {
			_ = os.Link(aside, path)
			os.Remove(aside)
			break
		}
		os.Remove(aside)
	}
	holder := ""
	if raw, err := os.ReadFile(path); err == nil {
		holder = strings.TrimSpace(string(raw))
	}
	who := ""
	if holder != "" {
		who = " (process " + holder + ")"
	}
	return nil, fmt.Errorf("Another run is using %s%s. Wait for it to finish, or delete %s if none is running.", state, who, path)
}

// writeState writes the state whole or not at all, so a crash part way never leaves it empty.
func writeState(state string, s saved) error {
	temp := state + "." + strconv.Itoa(os.Getpid()) + ".tmp"
	if err := os.WriteFile(temp, []byte(js.Stringify(s)), 0o644); err != nil {
		return err
	}
	return os.Rename(temp, state)
}

// RunAgents reads the log and sends the AI agent fetches in it. Without
// Follow it returns once it has read what is new; with Follow it runs until
// ctx ends. It returns how many fetches Runlight kept.
func RunAgents(ctx context.Context, o AgentsOptions) (float64, error) {
	release := func() {}
	if o.State != "" {
		var err error
		if release, err = lock(o.State); err != nil {
			return 0, err
		}
	}
	defer release()
	return readLog(ctx, o)
}

func readLog(ctx context.Context, o AgentsOptions) (float64, error) {
	out := o.Out
	if out == nil {
		out = func(line string) { fmt.Println(line) }
	}
	if _, err := os.Stat(o.Log); err != nil {
		return 0, fmt.Errorf("No log at %s", o.Log)
	}
	total := 0.0
	warned := false
	// handle sends the agent fetches among lines read, a batch at a time, calling done with where the next
	// unsent line starts after each batch, so a failure part way sends none of the earlier batches again.
	handle := func(read chunk, done func(offset int64) error) (float64, error) {
		// Lines with no host and no site cannot be placed on a site; say so once rather than skip them silently.
		if o.Site == "" && !warned {
			for _, line := range read.lines {
				if !strings.HasPrefix(js.Trim(line), "{") && hostless.MatchString(line) && ParseLine(line, "") == nil {
					warned = true
					out("Some lines have no host in them. Add --site https://your-site.example so they can be counted.")
					break
				}
			}
		}
		kept := 0.0
		batch := []Fetch{}
		now := time.Now().UnixMilli()
		for i, line := range read.lines {
			if found := AgentFetch(line, o.Site, now); found != nil {
				batch = append(batch, *found)
			}
			if len(batch) == batchSize || (i == len(read.lines)-1 && len(batch) > 0) {
				recorded, err := send(ctx, o, batch)
				if err != nil {
					return kept, err
				}
				kept += recorded
				total += recorded
				batch = []Fetch{}
				if err := done(read.ends[i]); err != nil {
					return kept, err
				}
			}
		}
		return kept, nil
	}
	// save keeps the place: the file being read, by its inode and its own start, and how far into it.
	save := func(ino uint64, offset int64, head fingerprint) error {
		if o.State == "" {
			return nil
		}
		length := head.length
		return writeState(o.State, saved{Ino: float64(ino), Offset: float64(offset), Head: head.head, Length: &length})
	}
	// readState is where the last run stopped, or nil with a word about it when the state file cannot be read.
	readState := func() *saved {
		if o.State == "" {
			return nil
		}
		raw, err := os.ReadFile(o.State)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err == nil {
			if parsed, err := js.Parse(string(raw)); err == nil {
				ino, okIno := js.Dig(parsed, "ino").(float64)
				offset, okOffset := js.Dig(parsed, "offset").(float64)
				if okIno && okOffset {
					s := &saved{Ino: ino, Offset: offset}
					if head, ok := js.Dig(parsed, "head").(string); ok {
						s.Head = head
					}
					if length, ok := js.Dig(parsed, "length").(float64); ok {
						l := int64(length)
						s.Length = &l
					}
					return s
				}
			}
		}
		out("Could not read " + o.State + ", so this run starts as if it were the first.")
		return nil
	}

	if !o.Follow {
		// Where the last run stopped, unless the log was rotated since (a new file, a shorter one, or a new start).
		last := readState()
		info, err := os.Stat(o.Log)
		if err != nil {
			return 0, err
		}
		ino := inode(info)
		var offset int64
		if last != nil && int64(last.Offset) <= info.Size() && sameLog(o.Log, *last, ino, info.Size()) {
			offset = int64(last.Offset)
		}
		f, err := os.Open(o.Log)
		if err != nil {
			return 0, err
		}
		defer f.Close()
		count := 0
		// A batch at a time, saving the place after each, so a failure part way resends nothing already sent.
		for {
			read, err := readFrom(f, offset)
			if err != nil {
				return total, err
			}
			if _, err := handle(read, func(at int64) error {
				head, err := headOfPath(o.Log, headSize)
				if err != nil {
					return err
				}
				return save(ino, at, head)
			}); err != nil {
				return total, err
			}
			count += len(read.lines)
			offset = read.next
			head, err := headOfPath(o.Log, headSize)
			if err != nil {
				return total, err
			}
			if err := save(ino, offset, head); err != nil {
				return total, err
			}
			if !read.more {
				break
			}
		}
		out(fmt.Sprintf("Sent %s AI agent fetches from %d new lines.", js.FormatNumber(total), count))
		return total, nil
	}

	// Follow: start where State says, else at the end like tail -F. A log that was rotated since the
	// state was saved is all new, so it is read from its start.
	resumed := readState()
	info, err := os.Stat(o.Log)
	if err != nil {
		return 0, err
	}
	ino := inode(info)
	offset := info.Size()
	if resumed != nil {
		offset = 0
		if int64(resumed.Offset) <= info.Size() && sameLog(o.Log, *resumed, ino, info.Size()) {
			offset = int64(resumed.Offset)
		}
	}
	out("Following " + o.Log + ". AI agent fetches go to " + o.To + " as they happen.")
	// The log stays open, so when it is renamed in a rotation, what was written to it before the
	// switch is still read to the end before the new log starts. Its fingerprint is taken from the
	// open file too, so a place saved while finishing an old log names that log, never the new one.
	f, err := os.Open(o.Log)
	if err != nil {
		return 0, err
	}
	defer func() { f.Close() }()
	known, err := headOf(f, headSize)
	if err != nil {
		return 0, err
	}
	poll := o.Poll
	if poll <= 0 {
		poll = 2 * time.Second
	}
	// The same trouble every two seconds is said once, until something changes.
	trouble := ""
	for {
		select {
		case <-ctx.Done():
			return total, nil
		case <-time.After(poll):
		}
		err := func() error {
			stat, statErr := os.Stat(o.Log)
			renamed := statErr != nil || inode(stat) != ino
			// Copied and truncated in place: the same file, shorter or with a new start.
			if !renamed {
				length := known.length
				if stat.Size() < offset || !sameLog(o.Log, saved{Ino: float64(ino), Head: known.head, Length: &length}, ino, stat.Size()) {
					offset = 0
				}
			}
			read, err := readFrom(f, offset)
			if err != nil {
				return err
			}
			sent, err := handle(read, func(at int64) error {
				offset = at
				return save(ino, offset, known)
			})
			if err != nil {
				return err
			}
			// Only past lines that were sent, so a failed send is tried again next time.
			offset = read.next
			if err := save(ino, offset, known); err != nil {
				return err
			}
			if sent > 0 {
				out("Sent " + js.FormatNumber(sent) + " AI agent fetches.")
			}
			if renamed && statErr == nil && !read.more {
				// The old log is finished; the new one is read from its start.
				next, err := os.Open(o.Log)
				if err != nil {
					return err
				}
				f.Close()
				f = next
				ino = inode(stat)
				offset = 0
			}
			// The start grows until it is headSize bytes long, so the fingerprint is taken again each time.
			known, err = headOf(f, headSize)
			return err
		}()
		if err == nil {
			trouble = ""
			continue
		}
		var said string
		var se *sendError
		if errors.As(err, &se) {
			said = "Could not send, trying again shortly: " + se.message
		} else {
			said = "Could not read " + o.Log + ", trying again shortly: " + err.Error()
		}
		if said != trouble {
			out(said)
		}
		trouble = said
	}
}
