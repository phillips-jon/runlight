package mail

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"strings"

	"runlight.sh/go/internal/web"
)

// Keys kept in the database (the mail service's, the AI Assistant's, and the tokens for connected
// installs) are encrypted with AES-GCM, under a key derived from a secret only the server has:
// `RUNLIGHT_SECRET`, or else the dashboard token. A copied database alone does not give them away.
// The label says "mail" because mail came first; changing it would make every saved key unreadable.
//
// The sealed form is Web Crypto's: base64 of the 12 byte IV, and base64 of the ciphertext followed
// by its 16 byte tag, so either implementation opens what the other sealed.

func keyFor(secret string) []byte {
	sum := sha256.Sum256([]byte("runlight-mail:" + secret))
	return sum[:]
}

// gcm is AES-256-GCM with a nonce of the given size; Web Crypto takes any
// IV of 12 bytes or more.
func gcm(secret string, ivSize int) cipher.AEAD {
	block, _ := aes.NewCipher(keyFor(secret))
	aead, _ := cipher.NewGCMWithNonceSize(block, ivSize)
	return aead
}

// Seal is `v1:<iv>:<ciphertext>`, or `plain:<value>` when the server has no
// secret to encrypt with ("" is no secret, as null and "" are in TypeScript).
func Seal(value, secret string) string {
	if secret == "" {
		return "plain:" + value
	}
	iv := make([]byte, 12)
	rand.Read(iv)
	data := gcm(secret, len(iv)).Seal(nil, iv, []byte(value), nil)
	return "v1:" + base64.StdEncoding.EncodeToString(iv) + ":" + base64.StdEncoding.EncodeToString(data)
}

// Unseal is the sealed value, and false when it cannot be opened (a
// different secret, or damaged).
func Unseal(sealed, secret string) (string, bool) {
	if rest, ok := strings.CutPrefix(sealed, "plain:"); ok {
		return rest, true
	}
	parts := strings.Split(sealed, ":")
	part := func(i int) string {
		if i < len(parts) {
			return parts[i]
		}
		return ""
	}
	version, ivText, dataText := part(0), part(1), part(2)
	if version != "v1" || ivText == "" || dataText == "" || secret == "" {
		return "", false
	}
	iv, err := atob(ivText)
	if err != nil {
		return "", false
	}
	data, err := atob(dataText)
	if err != nil || len(iv) < 12 || len(data) < 16 {
		return "", false
	}
	plain, err := gcm(secret, len(iv)).Open(nil, iv, data, nil)
	if err != nil {
		return "", false
	}
	return web.DecodeUTF8(plain), true
}
