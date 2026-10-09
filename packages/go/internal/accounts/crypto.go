// Package accounts holds the sign-in accounts' cryptography and pages, ported from the TypeScript SDK's
// accounts/crypto.ts and accounts/pages.ts. The two-factor pieces that live in auth.ts in TypeScript (base32,
// TOTP, the otpauth address, recovery codes, and the signature on session cookies) are here too, as functions of
// their inputs alone, so the accounts code can call them.
package accounts

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"hash"
	"strconv"
	"strings"
	"unicode/utf8"

	"runlight.sh/go/internal/js"
)

// The cryptography accounts need. Passwords use scrypt, as the standalone server always has, and a PBKDF2
// hash made on an edge runtime checks out too.

// DOMError is an error WebCrypto or atob would throw: Name is the DOMException's name ("InvalidCharacterError",
// "DataError").
type DOMError struct {
	Name    string
	Message string
}

func (e *DOMError) Error() string { return e.Message }

// RandomBytes is length bytes from the system's secure random source.
func RandomBytes(length int) []byte {
	out := make([]byte, length)
	_, _ = rand.Read(out)
	return out
}

// Base64url is bytes in base64url, without padding.
func Base64url(bytes []byte) string {
	return base64.RawURLEncoding.EncodeToString(bytes)
}

// FromBase64url is bytes from base64url (or plain base64), read as atob() reads them: white space is skipped,
// padding is optional, and anything else that is not base64 fails with an InvalidCharacterError.
func FromBase64url(text string) ([]byte, error) {
	plain := strings.Map(func(r rune) rune {
		switch r {
		case '\t', '\n', '\f', '\r', ' ':
			return -1
		case '-':
			return '+'
		case '_':
			return '/'
		}
		return r
	}, text)
	if len(plain)%4 == 0 {
		if strings.HasSuffix(plain, "==") {
			plain = plain[:len(plain)-2]
		} else if strings.HasSuffix(plain, "=") {
			plain = plain[:len(plain)-1]
		}
	}
	bad := len(plain)%4 == 1
	for i := 0; i < len(plain) && !bad; i++ {
		c := plain[i]
		bad = !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '+' || c == '/')
	}
	if bad {
		return nil, &DOMError{Name: "InvalidCharacterError", Message: "Invalid character"}
	}
	// atob drops the bits left over past the last whole byte, as RawStdEncoding does when not strict.
	return base64.RawStdEncoding.DecodeString(plain)
}

// Hex is bytes in lower-case hex.
func Hex(bytes []byte) string {
	return hex.EncodeToString(bytes)
}

// SHA256 is the SHA-256 digest of the bytes (a string's are its UTF-8).
func SHA256(value []byte) []byte {
	sum := sha256.Sum256(value)
	return sum[:]
}

// HMAC is HMAC under "SHA-1" or "SHA-256". WebCrypto will not import an empty HMAC key, so an empty key fails
// with a DataError.
func HMAC(hashName string, key, data []byte) ([]byte, error) {
	if len(key) == 0 {
		return nil, &DOMError{Name: "DataError", Message: "Zero-length key is not supported"}
	}
	h := sha256.New
	if hashName == "SHA-1" {
		h = func() hash.Hash { return sha1.New() }
	}
	mac := hmac.New(h, key)
	mac.Write(data)
	return mac.Sum(nil), nil
}

// SameText compares two strings in time that does not depend on where they differ.
func SameText(a, b string) bool {
	return sameBytes([]byte(a), []byte(b))
}

func sameBytes(a, b []byte) bool {
	diff := len(a) ^ len(b)
	for i := 0; i < max(len(a), len(b)); i++ {
		var x, y byte
		if i < len(a) {
			x = a[i]
		}
		if i < len(b) {
			y = b[i]
		}
		diff |= int(x ^ y)
	}
	return diff == 0
}

// The scrypt cost Node's standalone server has always hashed with.
const (
	scryptN = 16384
	scryptR = 8
	scryptP = 1
)

// PBKDF2Rounds is as many PBKDF2 rounds as Cloudflare Workers allow, the strictest runtime Runlight runs on.
const PBKDF2Rounds = 100_000

// MinKeyBytes is the shortest stored key accepted. Ours are 32 bytes; an empty or cut key would match too
// easily, or anything.
const MinKeyBytes = 16

// HashPassword is a password hash, in the scrypt form the standalone server has always written. It says which
// it is, so it can be checked later.
func HashPassword(password string) (string, error) {
	salt := RandomBytes(16)
	key, err := Scrypt(password, salt, scryptN, scryptR, scryptP, 32)
	if err != nil {
		return "", err
	}
	return "scrypt$" + Base64url(salt) + "$" + Base64url(key), nil
}

// CheckPassword is whether a password matches a hash, scrypt or PBKDF2. A stored hash whose salt or key is not
// base64url matches nothing, rather than failing the sign-in.
func CheckPassword(password, stored string) bool {
	parts := strings.Split(stored, "$")
	if parts[0] == "scrypt" && len(parts) == 3 {
		expected, err := FromBase64url(parts[2])
		salt, saltErr := FromBase64url(parts[1])
		if err != nil || saltErr != nil || len(expected) < MinKeyBytes {
			return false
		}
		key, err := Scrypt(password, salt, scryptN, scryptR, scryptP, len(expected))
		return err == nil && sameBytes(key, expected)
	}
	if parts[0] == "pbkdf2" && len(parts) == 4 {
		rounds := js.Number(parts[1])
		if !js.IsInteger(rounds) || rounds < 1 || rounds > 10_000_000 {
			return false
		}
		expected, err := FromBase64url(parts[3])
		salt, saltErr := FromBase64url(parts[2])
		if err != nil || saltErr != nil || len(expected) < MinKeyBytes {
			return false
		}
		key, err := pbkdf2.Key(sha256.New, password, salt, int(rounds), len(expected))
		return err == nil && sameBytes(key, expected)
	}
	return false
}

func sealKey(secret string) []byte {
	return SHA256([]byte("totp:" + secret))
}

// SealText seals text with AES-256-GCM under a key from the secret, as "iv.body.tag" in base64url, the form the
// standalone server has always stored two-factor secrets in.
func SealText(text, secret string) (string, error) {
	return sealWith(text, secret, RandomBytes(12))
}

func sealWith(text, secret string, iv []byte) (string, error) {
	gcm, err := newGCM(secret, len(iv))
	if err != nil {
		return "", err
	}
	out := gcm.Seal(nil, iv, []byte(text), nil)
	return Base64url(iv) + "." + Base64url(out[:len(out)-16]) + "." + Base64url(out[len(out)-16:]), nil
}

func newGCM(secret string, ivLength int) (cipher.AEAD, error) {
	block, err := aes.NewCipher(sealKey(secret))
	if err != nil {
		return nil, err
	}
	if ivLength == 12 {
		return cipher.NewGCM(block)
	}
	return cipher.NewGCMWithNonceSize(block, ivLength)
}

// UnsealText opens what SealText sealed, and is false for anything that does not open under the secret.
func UnsealText(sealed, secret string) (string, bool) {
	parts := strings.Split(sealed, ".")
	if parts[0] == "" || len(parts) < 3 || parts[2] == "" {
		return "", false
	}
	body, err := FromBase64url(parts[1])
	if err != nil {
		return "", false
	}
	tag, err := FromBase64url(parts[2])
	if err != nil {
		return "", false
	}
	iv, err := FromBase64url(parts[0])
	// WebCrypto reads the tag as the last 16 bytes of body and tag together, wherever the dot fell, and refuses an
	// IV shorter than 12 bytes.
	joined := append(body, tag...)
	if err != nil || len(iv) < 12 || len(joined) < 16 {
		return "", false
	}
	gcm, err := newGCM(secret, len(iv))
	if err != nil {
		return "", false
	}
	plain, err := gcm.Open(nil, iv, joined, nil)
	if err != nil {
		return "", false
	}
	return decodeUTF8(plain), true
}

// decodeUTF8 is TextDecoder's reading: a leading byte order mark goes, and each maximal run of bytes that is not
// UTF-8 becomes one U+FFFD.
func decodeUTF8(b []byte) string {
	if len(b) >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF {
		b = b[3:]
	}
	if utf8.Valid(b) {
		return string(b)
	}
	var out strings.Builder
	for i := 0; i < len(b); {
		c := b[i]
		if c < 0x80 {
			out.WriteByte(c)
			i++
			continue
		}
		need, lo, hi := 0, byte(0x80), byte(0xBF)
		switch {
		case c >= 0xC2 && c <= 0xDF:
			need = 1
		case c == 0xE0:
			need, lo = 2, 0xA0
		case c == 0xED:
			need, hi = 2, 0x9F
		case c >= 0xE1 && c <= 0xEF:
			need = 2
		case c == 0xF0:
			need, lo = 3, 0x90
		case c == 0xF4:
			need, hi = 3, 0x8F
		case c >= 0xF1 && c <= 0xF3:
			need = 3
		}
		j := i + 1
		for k := 0; k < need; k++ {
			if j >= len(b) || b[j] < lo || b[j] > hi {
				break
			}
			lo, hi = 0x80, 0xBF
			j++
		}
		if need == 0 || j-i != need+1 {
			out.WriteRune(utf8.RuneError)
			i = max(j, i+1)
			continue
		}
		out.Write(b[i:j])
		i = j
	}
	return out.String()
}

// Two-factor: TOTP as authenticator apps expect it (RFC 6238): SHA-1, six digits, 30 seconds.

// StepMS is how long each TOTP code lasts.
const StepMS = 30_000

const base32Letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

// Base32 is bytes in RFC 4648 base32, without padding.
func Base32(bytes []byte) string {
	bits := 0
	value := 0
	var out strings.Builder
	for _, b := range bytes {
		// Only the low bits are ever read, so the rest are dropped before they grow.
		value = ((value << 8) | int(b)) & 0xffff
		bits += 8
		for bits >= 5 {
			out.WriteByte(base32Letters[(value>>(bits-5))&31])
			bits -= 5
		}
	}
	if bits > 0 {
		out.WriteByte(base32Letters[(value<<(5-bits))&31])
	}
	return out.String()
}

// Unbase32 is bytes from base32, skipping anything that is not a base32 letter, as authenticator apps' secrets
// come.
func Unbase32(text string) []byte {
	bits := 0
	value := 0
	out := []byte{}
	for _, c := range js.ToUpper(strings.TrimRight(text, "=")) {
		i := strings.IndexRune(base32Letters, c)
		if i < 0 {
			continue
		}
		value = ((value << 5) | i) & 0xffff
		bits += 5
		if bits >= 8 {
			out = append(out, byte(value>>(bits-8)))
			bits -= 8
		}
	}
	return out
}

// TOTP is the six-digit code for a secret at a time step. A secret with no base32 letters in it fails with a
// DataError, as WebCrypto refuses the empty key.
func TOTP(secret string, step int64) (string, error) {
	var counter [8]byte
	// setBigUint64 takes a step below zero modulo 2^64.
	binary.BigEndian.PutUint64(counter[:], uint64(step))
	mac, err := HMAC("SHA-1", Unbase32(secret), counter[:])
	if err != nil {
		return "", err
	}
	at := mac[len(mac)-1] & 15
	n := uint32(mac[at]&127)<<24 | uint32(mac[at+1])<<16 | uint32(mac[at+2])<<8 | uint32(mac[at+3])
	code := strconv.FormatUint(uint64(n%1_000_000), 10)
	return strings.Repeat("0", 6-len(code)) + code, nil
}

// MatchStep is the time step a code matches, one step either side for clocks that drift, newer than after;
// false when none does.
func MatchStep(secret, code string, now, after int64) (int64, bool, error) {
	current := js.FloorDiv(now, StepMS)
	for _, step := range []int64{current, current - 1, current + 1} {
		if step <= after {
			continue
		}
		got, err := TOTP(secret, step)
		if err != nil {
			return 0, false, err
		}
		if got == code {
			return step, true, nil
		}
	}
	return 0, false, nil
}

// OtpauthURI is the address an authenticator app reads from the QR code.
func OtpauthURI(secret, email, host string) string {
	label := encodeURIComponent("Runlight (" + host + "):" + email)
	return "otpauth://totp/" + label + "?secret=" + secret + "&issuer=" + encodeURIComponent("Runlight ("+host+")") + "&algorithm=SHA1&digits=6&period=30"
}

// encodeURIComponent is encodeURIComponent(text).
func encodeURIComponent(text string) string {
	text = js.WellFormed(text)
	var b strings.Builder
	for i := 0; i < len(text); i++ {
		c := text[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || strings.IndexByte("-_.!~*'()", c) >= 0 {
			b.WriteByte(c)
			continue
		}
		b.WriteByte('%')
		b.WriteByte("0123456789ABCDEF"[c>>4])
		b.WriteByte("0123456789ABCDEF"[c&15])
	}
	return b.String()
}

// RecoveryCodes is ten one-use recovery codes, like "k7dq-2mfa".
func RecoveryCodes() []string {
	codes := make([]string, 10)
	for i := range codes {
		raw := strings.ToLower(Base32(RandomBytes(5)))
		codes[i] = raw[:4] + "-" + raw[4:8]
	}
	return codes
}

// RecoveryHash is what a recovery code is kept as: SHA-256 of its letters and digits in lower case, so dashes and
// case do not matter.
func RecoveryHash(code string) string {
	var kept strings.Builder
	for i := 0; i < len(code); i++ {
		c := code[i]
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') {
			kept.WriteByte(c)
		} else if c >= 'A' && c <= 'Z' {
			kept.WriteByte(c + 'a' - 'A')
		}
	}
	return Hex(SHA256([]byte(kept.String())))
}

// Signature is the signature on a session, sign-in, or device value: HMAC-SHA-256 of "body.hash" under the
// install's secret, in base64url. An empty secret fails, as WebCrypto refuses the empty key.
func Signature(secret, body, hash string) (string, error) {
	mac, err := HMAC("SHA-256", []byte(secret), []byte(body+"."+hash))
	if err != nil {
		return "", err
	}
	return Base64url(mac), nil
}
