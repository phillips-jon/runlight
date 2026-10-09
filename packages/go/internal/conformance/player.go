package conformance

import (
	"bytes"
	"compress/flate"
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base32"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"sync"

	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
	"runlight.sh/go/internal/whatwg"
)

// Env is the environment the SDK reads defaults from, cleared while a
// scenario plays so nothing outside it counts.
var Env = []string{"RUNLIGHT_TOKEN", "RUNLIGHT_SECRET", "CRON_SECRET", "RUNLIGHT_OBSERVE_KEY", "NODE_ENV"}

// textBodyType is the content type JavaScript's Request gives a string body sent with none.
const textBodyType = "text/plain;charset=UTF-8"

// Target takes a scenario's requests: the routes, the app's own short-link
// path, and the link-domain middleware.
type Target interface {
	Handle(ctx context.Context, request *web.Request) *web.Response
	Links(ctx context.Context, request *web.Request) *web.Response
	// LinkDomain is nil to let the request pass on to the app.
	LinkDomain(ctx context.Context, request *web.Request) *web.Response
	// Idle finishes work a request started after answering (retention).
	Idle()
}

// Setup is what a scenario says to make its Runlight with.
type Setup struct {
	// Runlight options as JSON: managedSites, sites, site, secret, rateLimit.
	Runlight *js.Object
	// Routes options as JSON: token (string, "" none, or null open), observeKey, cronSecret, accounts, origin.
	Routes *js.Object
	// Now is the scenario's clock, in epoch milliseconds.
	Now func() int64
	// Fetcher plays the scenario's upstream servers.
	Fetcher web.Fetcher
}

// RunlightOptions are the options a scenario's Runlight gets, without the store, the clock, and the fetcher.
func RunlightOptions(scenario any) *js.Object {
	options := js.Obj(js.Dig(scenario, "options"))
	out := &js.Object{}
	switch {
	case js.Truthy(options.Value("managedSites")):
		out.Set("managedSites", true)
	case js.Dig(scenario, "sites") != nil:
		out.Set("sites", js.Dig(scenario, "sites"))
	default:
		out.Set("site", js.Dig(scenario, "site"))
	}
	if s, ok := options.Value("secret").(string); ok && s != "" {
		out.Set("secret", s)
	}
	if v, ok := options.Get("rateLimit"); ok {
		out.Set("rateLimit", v)
	}
	return out
}

// RoutesOptions are the options a scenario's routes get. The token is
// always there: a string, "" for none, or null to leave the routes open.
func RoutesOptions(scenario any) *js.Object {
	options := js.Obj(js.Dig(scenario, "options"))
	out := js.NewObject("token", js.Dig(scenario, "token"), "observeKey", stringOr(options.Value("observeKey")), "cronSecret", stringOr(options.Value("cronSecret")))
	if js.Truthy(options.Value("accounts")) {
		out.Set("accounts", true)
	}
	if js.Truthy(options.Value("origin")) {
		out.Set("origin", options.Value("origin"))
	}
	return out
}

func stringOr(v any) string {
	s, _ := v.(string)
	return s
}

// envMu keeps scenarios that clear the environment from overlapping.
var envMu sync.Mutex

// Play runs a scenario's steps and returns each answer, normalized.
func Play(scenario any, makeTarget func(Setup) (Target, error)) ([]any, error) {
	envMu.Lock()
	defer envMu.Unlock()
	saved := map[string]*string{}
	for _, name := range Env {
		if v, ok := os.LookupEnv(name); ok {
			saved[name] = &v
		} else {
			saved[name] = nil
		}
		os.Unsetenv(name)
	}
	defer func() {
		for name, v := range saved {
			if v == nil {
				os.Unsetenv(name)
			} else {
				os.Setenv(name, *v)
			}
		}
	}()
	p := &player{now: int64(js.Num(js.Dig(scenario, "start"))), fetcher: newUpstream(js.Arr(js.Dig(scenario, "upstream"))), kept: map[string]string{}, jars: map[string]*jar{}}
	target, err := makeTarget(Setup{Runlight: RunlightOptions(scenario), Routes: RoutesOptions(scenario), Now: func() int64 {
		p.mu.Lock()
		defer p.mu.Unlock()
		return p.now
	}, Fetcher: p.fetcher})
	if err != nil {
		return nil, err
	}
	answers := []any{}
	for i, step := range js.Arr(js.Dig(scenario, "steps")) {
		answer, err := p.step(step, target)
		if err != nil {
			return answers, fmt.Errorf("%s: step %d, %s %s: %w", js.Str(js.Dig(scenario, "name")), i+1, js.Str(js.Dig(step, "method")), js.Str(js.Dig(step, "path")), err)
		}
		answers = append(answers, answer)
	}
	return answers, nil
}

type jar struct {
	names  []string
	values map[string]string
}

func (j *jar) set(name, value string) {
	if _, ok := j.values[name]; !ok {
		j.names = append(j.names, name)
	}
	j.values[name] = value
}

func (j *jar) remove(name string) {
	if _, ok := j.values[name]; !ok {
		return
	}
	delete(j.values, name)
	for i, n := range j.names {
		if n == name {
			j.names = append(j.names[:i], j.names[i+1:]...)
			break
		}
	}
}

type player struct {
	mu      sync.Mutex
	now     int64
	fetcher *upstream
	kept    map[string]string
	jars    map[string]*jar
}

var (
	totpTemplate = regexp.MustCompile(`\{\{totp:(\w+)\}\}`)
	template     = regexp.MustCompile(`\{\{(\w+)\}\}`)
	maxAgeZero   = regexp.MustCompile(`(?i)^[\t\n\v\f\r ]*max-age=0[\t\n\v\f\r ]*$`)
)

// fillTotp is {{totp:name}} as the six-digit code for the captured secret at the step's clock, then {{name}}.
func (p *player) fillTotp(text string) string {
	out := totpTemplate.ReplaceAllStringFunc(text, func(m string) string {
		name := totpTemplate.FindStringSubmatch(m)[1]
		return Totp(p.kept[name], p.now/30_000)
	})
	return template.ReplaceAllStringFunc(out, func(m string) string { return p.kept[m[2:len(m)-2]] })
}

func (p *player) fillDeep(value any) any {
	switch v := value.(type) {
	case string:
		return p.fillTotp(v)
	case []any:
		out := make([]any, len(v))
		for i, e := range v {
			out[i] = p.fillDeep(e)
		}
		return out
	case *js.Object:
		out := &js.Object{}
		v.Each(func(k string, e any) { out.Set(k, p.fillDeep(e)) })
		return out
	}
	return value
}

func (p *player) step(step any, target Target) (any, error) {
	ctx := context.Background()
	p.mu.Lock()
	p.now += int64(js.Num(js.Dig(step, "advance")))
	p.mu.Unlock()
	headers := web.NewHeaders()
	js.Obj(js.Dig(step, "headers")).Each(func(k string, v any) { headers.Set(strings.ToLower(k), p.fillTotp(js.String(v))) })
	var body []byte
	hasBody := false
	s := js.Obj(step)
	if form := js.Obj(s.Value("form")); form != nil {
		fields := whatwg.NewSearchParams()
		js.Obj(p.fillDeep(form)).Each(func(k string, v any) { fields.Append(k, js.String(v)) })
		body, hasBody = []byte(fields.String()), true
		if !headers.Has("content-type") {
			headers.Set("content-type", "application/x-www-form-urlencoded")
		}
	} else if s.Has("body") {
		hasBody = true
		if text, ok := s.Value("body").(string); ok {
			body = []byte(p.fillTotp(text))
		} else {
			body = []byte(js.Stringify(p.fillDeep(s.Value("body"))))
		}
	}
	// JavaScript's Request gives a string body this type when none is named, and the core may read it.
	if hasBody && !headers.Has("content-type") {
		headers.Set("content-type", textBodyType)
	}
	var j *jar
	if v, has := s.Get("jar"); !has || v != false {
		name := "main"
		if n, ok := v.(string); ok {
			name = n
		}
		if p.jars[name] == nil {
			p.jars[name] = &jar{values: map[string]string{}}
		}
		j = p.jars[name]
	}
	if j != nil && len(j.names) > 0 && !headers.Has("cookie") {
		pairs := []string{}
		for _, name := range j.names {
			pairs = append(pairs, name+"="+j.values[name])
		}
		headers.Set("cookie", strings.Join(pairs, "; "))
	}
	to := "routes"
	if v, ok := s.Value("to").(string); ok {
		to = v
	}
	prefix := ""
	if to == "routes" && !js.Truthy(s.Value("absolute")) {
		prefix = "/runlight"
	}
	host := "example.com"
	if v, ok := s.Value("host").(string); ok {
		host = v
	}
	raw := "https://" + host + prefix + p.fillTotp(js.Str(s.Value("path")))
	url := raw
	if u, err := whatwg.Parse(raw); err == nil {
		url = u.Href()
	}
	request := web.NewRequest(js.Str(s.Value("method")), url, headers, body)
	p.fetcher.take()
	var answer *web.Response
	switch to {
	case "links":
		answer = target.Links(ctx, request)
	case "linkDomain":
		answer = target.LinkDomain(ctx, request)
	default:
		answer = target.Handle(ctx, request)
	}
	// Work the request started after answering (retention) finishes before the next one, as it would between real requests.
	target.Idle()
	sent := p.fetcher.take()
	outbound := []any{}
	for _, f := range sent {
		outbound = append(outbound, Normalize(f.seen, ""))
	}
	if answer == nil {
		out := js.NewObject("pass", true)
		if len(outbound) > 0 {
			out.Set("fetched", outbound)
		}
		return out, nil
	}
	return p.answer(s, answer, sent, outbound, j)
}

func mediaType(contentType string) string {
	return strings.TrimSpace(strings.Split(contentType, ";")[0])
}

func (p *player) answer(step *js.Object, answer *web.Response, sent []fetched, outbound []any, j *jar) (any, error) {
	text := web.DecodeUTF8(answer.Body)
	if strings.HasPrefix(string(answer.Body), "\xef\xbb\xbf") {
		// TextDecoder drops a byte order mark too.
		text = web.DecodeUTF8(answer.Body)
	}
	kind := mediaType(answer.Header.Get("content-type"))
	var parsed any
	hasParsed := false
	if kind != "application/zip" && text != "" {
		if v, err := js.Parse(text); err == nil {
			parsed, hasParsed = v, true
		}
	}
	var captureErr error
	js.Obj(step.Value("capture")).Each(func(name string, spec any) {
		value, err := capture(js.String(spec), answer, text, parsed, sent)
		if err != nil {
			captureErr = err
		}
		p.kept[name] = value
	})
	if captureErr != nil {
		return nil, captureErr
	}
	for _, cookie := range answer.Header.SetCookies() {
		if j == nil {
			continue
		}
		attributes := strings.Split(cookie, ";")
		pair := attributes[0]
		var name, value string
		if at := strings.Index(pair, "="); at >= 0 {
			name, value = strings.TrimSpace(pair[:at]), strings.TrimSpace(pair[at+1:])
		} else {
			// As pair.slice(0, pair.indexOf("=")): with no "=", indexOf is -1, and the last character is cut.
			name, value = strings.TrimSpace(pair[:max(0, len(pair)-1)]), strings.TrimSpace(pair)
		}
		clears := false
		for _, a := range attributes[1:] {
			if maxAgeZero.MatchString(a) {
				clears = true
			}
		}
		if value == "" || clears {
			j.remove(name)
		} else {
			j.set(name, value)
		}
	}
	headers := &js.Object{}
	for _, name := range Headers {
		if name == "set-cookie" {
			cookies := answer.Header.SetCookies()
			if len(cookies) > 0 {
				shapes := []any{}
				for _, c := range cookies {
					shapes = append(shapes, CookieShape(c))
				}
				headers.Set(name, shapes)
			}
			continue
		}
		if v, ok := answer.Header.Lookup(name); ok && v != "" {
			if name == "content-type" {
				headers.Set(name, mediaType(v))
			} else {
				headers.Set(name, Normalize(v, ""))
			}
		}
	}
	out := js.NewObject("status", answer.Status)
	if headers.Len() > 0 {
		out.Set("headers", headers)
	}
	if hasParsed {
		out.Set("body", Normalize(parsed, ""))
	}
	if !hasParsed && (kind == "text/plain" || kind == "text/csv") {
		out.Set("text", Normalize(text, ""))
	}
	if kind == "application/zip" {
		files, err := Unzip(answer.Body)
		if err != nil {
			return nil, err
		}
		list := []any{}
		for _, f := range files {
			list = append(list, js.NewObject("name", f[0], "text", Normalize(f[1], "")))
		}
		out.Set("files", list)
	}
	if look := js.Arr(step.Value("look")); step.Has("look") {
		found := []any{}
		for _, l := range look {
			found = append(found, strings.Contains(text, js.String(l)))
		}
		out.Set("found", found)
	}
	if len(outbound) > 0 {
		out.Set("fetched", outbound)
	}
	return out, nil
}

// capture is a value kept from an answer: a dotted path into its JSON body,
// header:<name>, text, or fetched, any of them followed by ~<regex> to keep
// the regex's first group instead. Read before normalizing.
func capture(spec string, answer *web.Response, text string, parsed any, sent []fetched) (string, error) {
	source, pattern, hasPattern := strings.Cut(spec, "~")
	var value string
	switch {
	case source == "text":
		value = text
	case source == "fetched":
		parts := []string{}
		for _, f := range sent {
			parts = append(parts, f.text)
		}
		value = strings.Join(parts, "\n")
	case strings.HasPrefix(source, "header:"):
		header := strings.ToLower(source[len("header:"):])
		if header == "set-cookie" {
			value = strings.Join(answer.Header.SetCookies(), "\n")
		} else {
			value = answer.Header.Get(header)
		}
	default:
		value = jsString(dig(parsed, source))
	}
	if !hasPattern {
		return value, nil
	}
	re, err := regexp.Compile(pattern)
	if err != nil {
		return "", fmt.Errorf("the capture pattern %s is not one Go reads: %w", pattern, err)
	}
	if m := re.FindStringSubmatch(value); len(m) > 1 {
		return m[1], nil
	}
	return "", nil
}

// dig is path.split(".").reduce((v, k) => (v && typeof v === "object" ? v[k] : undefined), value).
func dig(value any, path string) any {
	for _, k := range strings.Split(path, ".") {
		switch v := value.(type) {
		case *js.Object:
			value = v.Value(k)
		case []any:
			n, err := fmt.Sscanf(k, "%d", new(int))
			if err != nil || n != 1 {
				return nil
			}
			var i int
			fmt.Sscanf(k, "%d", &i)
			if i < 0 || i >= len(v) || fmt.Sprint(i) != k {
				return nil
			}
			value = v[i]
		default:
			return nil
		}
	}
	return value
}

// jsString is String(value ?? ""), as JavaScript writes a JSON value as text.
func jsString(value any) string {
	if value == nil {
		return ""
	}
	return js.String(value)
}

// Totp is the six-digit TOTP code (RFC 6238: SHA-1, 30 second steps) for a base32 secret at a step.
func Totp(secret string, step int64) string {
	key, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(strings.ToUpper(strings.TrimRight(strings.ReplaceAll(secret, " ", ""), "=")))
	if err != nil {
		key = nil
	}
	counter := make([]byte, 8)
	binary.BigEndian.PutUint64(counter, uint64(step))
	m := hmac.New(sha1.New, key)
	m.Write(counter)
	sum := m.Sum(nil)
	offset := sum[len(sum)-1] & 15
	code := (uint32(sum[offset])&0x7f)<<24 | uint32(sum[offset+1])<<16 | uint32(sum[offset+2])<<8 | uint32(sum[offset+3])
	return fmt.Sprintf("%06d", code%1_000_000)
}

// Unzip is the files in a ZIP, stored or deflated, by their local headers: name and text.
func Unzip(b []byte) ([][2]string, error) {
	files := [][2]string{}
	at := 0
	for at+30 <= len(b) && binary.LittleEndian.Uint32(b[at:]) == 0x04034b50 {
		method := binary.LittleEndian.Uint16(b[at+8:])
		size := int(binary.LittleEndian.Uint32(b[at+18:]))
		nameLength := int(binary.LittleEndian.Uint16(b[at+26:]))
		extra := int(binary.LittleEndian.Uint16(b[at+28:]))
		name := web.DecodeUTF8(b[at+30 : at+30+nameLength])
		start := at + 30 + nameLength + extra
		data := b[start:min(len(b), start+size)]
		if method == 8 {
			inflated, err := io.ReadAll(flate.NewReader(bytes.NewReader(data)))
			if err != nil {
				return nil, fmt.Errorf("the ZIP's %s does not inflate", name)
			}
			data = inflated
		}
		files = append(files, [2]string{name, web.DecodeUTF8(data)})
		at = start + size
	}
	return files, nil
}
