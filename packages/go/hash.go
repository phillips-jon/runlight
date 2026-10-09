package runlight

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"sync"
)

// sha256Hex is the SHA-256 of text, as hex.
func sha256Hex(text string) string {
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:])
}

// hmacHex is the HMAC-SHA-256 of text under key, as hex.
func hmacHex(key, text string) string {
	m := hmac.New(sha256.New, []byte(key))
	m.Write([]byte(text))
	return hex.EncodeToString(m.Sum(nil))
}

// visitorHash is the day's visitor hash: SHA-256 of salt, site, IP, and
// user agent, cut to 64 bits. The salt changes every day and old salts are
// deleted, so the hash cannot be recomputed and does not follow anyone
// across days.
func visitorHash(salt, site, ip, ua string) string {
	return sha256Hex(salt + "\n" + site + "\n" + ip + "\n" + ua)[:16]
}

// randomID is bytes random bytes as hex: 24 characters for the usual 12.
func randomID(bytes int) string {
	b := make([]byte, bytes)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func randomSalt() string { return randomID(32) }

// rateLimit counts tracker requests per address in fixed one-minute
// windows, in memory. Addresses are hashed with a key made at start, so the
// map never holds an IP, and the whole map is dropped at the end of each
// window.
type rateLimit struct {
	mu        sync.Mutex
	perMinute int
	now       func() int64
	window    int64
	counts    map[string]int
	key       []byte
}

func newRateLimit(perMinute int, now func() int64) *rateLimit {
	key := make([]byte, 16)
	_, _ = rand.Read(key)
	return &rateLimit{perMinute: perMinute, now: now, counts: map[string]int{}, key: key}
}

// allow reports whether this address is under its limit for the current minute.
func (l *rateLimit) allow(ip string) bool {
	// No address (a bare adapter with no context) cannot be told apart, so it is not limited.
	if ip == "" {
		return true
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	window := floorDiv(l.now(), 60_000)
	if window != l.window {
		l.window = window
		l.counts = map[string]int{}
	}
	sum := sha256.Sum256(append(append([]byte{}, l.key...), ip...))
	id := hex.EncodeToString(sum[:8])
	l.counts[id]++
	return l.counts[id] <= l.perMinute
}

func floorDiv(a, b int64) int64 {
	q := a / b
	if a%b != 0 && (a < 0) != (b < 0) {
		q--
	}
	return q
}
