package accounts

import (
	"encoding/hex"
	"errors"
	"regexp"
	"testing"

	"runlight.sh/go/internal/fixture"
	"runlight.sh/go/internal/js"
)

// Accounts' cryptography against tests/fixtures/crypto.json, written by the TypeScript SDK and Node's own crypto.

func cases(t *testing.T, name string) []any {
	t.Helper()
	list := js.Arr(js.Dig(fixture.PHP(t, "crypto.json"), name))
	if len(list) == 0 {
		t.Fatalf("no %s cases", name)
	}
	return list
}

func str(c any, key string) string { return js.Str(js.Dig(c, key)) }

func throws(c any) bool { return js.Obj(c).Has("throws") }

func mustBase64(t *testing.T, text string) []byte {
	t.Helper()
	b, err := FromBase64url(text)
	if err != nil {
		t.Fatalf("%q: %v", text, err)
	}
	return b
}

func TestScryptGivesNodesBytes(t *testing.T) {
	for _, c := range cases(t, "scrypt") {
		n, r, p, length := int(js.Num(js.Dig(c, "N"))), int(js.Num(js.Dig(c, "r"))), int(js.Num(js.Dig(c, "p"))), int(js.Num(js.Dig(c, "length")))
		key, err := Scrypt(str(c, "password"), mustBase64(t, str(c, "salt")), n, r, p, length)
		if err != nil || hex.EncodeToString(key) != str(c, "key") {
			t.Errorf("%q N=%d r=%d p=%d len=%d: got %x, %v", str(c, "password"), n, r, p, length, key, err)
		}
	}
}

func TestScryptTestVectorsFromRfc7914(t *testing.T) {
	key, _ := Scrypt("", nil, 16, 1, 1, 64)
	if hex.EncodeToString(key) != "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906" {
		t.Errorf("first vector: %x", key)
	}
	key, _ = Scrypt("password", []byte("NaCl"), 1024, 8, 16, 64)
	if hex.EncodeToString(key) != "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640" {
		t.Errorf("second vector: %x", key)
	}
}

func TestScryptRefusesABadCost(t *testing.T) {
	if _, err := Scrypt("x", []byte("y"), 1000, 8, 1, 32); err == nil {
		t.Error("N of 1000 should fail")
	}
}

func TestPasswordsHashedByTypeScriptCheckHere(t *testing.T) {
	for i, c := range cases(t, "hashes") {
		if !CheckPassword(str(c, "password"), str(c, "hash")) {
			t.Errorf("%s does not check out", str(c, "hash"))
		}
		if i == 0 && CheckPassword(str(c, "password")+"!", str(c, "hash")) {
			t.Error("a wrong password checked out")
		}
	}
}

func TestNewHashesUseScryptAndCheck(t *testing.T) {
	hash, err := HashPassword("a long password")
	if err != nil || !regexp.MustCompile(`^scrypt\$[A-Za-z0-9_-]{22}\$[A-Za-z0-9_-]{43}$`).MatchString(hash) {
		t.Fatalf("%q %v", hash, err)
	}
	if !CheckPassword("a long password", hash) {
		t.Error("a new hash does not check out")
	}
	if again, _ := HashPassword("a long password"); again == hash {
		t.Error("a new salt each time")
	}
}

func TestCheckPasswordAnswersAsTypeScriptDoes(t *testing.T) {
	for _, c := range cases(t, "checks") {
		if throws(c) {
			t.Fatalf("checkPassword no longer throws, but the fixture has %v", c)
		}
		if got := CheckPassword(str(c, "password"), str(c, "stored")); got != js.Dig(c, "value").(bool) {
			t.Errorf("%s against %s: %v", str(c, "password"), str(c, "stored"), got)
		}
	}
}

func TestCheckPasswordRefusesAHashThatIsNotBase64(t *testing.T) {
	key := "FcGYjCCSlbHmKWA3V4___zmHCpuJn9C3-muNyTgOOBI"
	for _, stored := range []string{
		"scrypt$Xn_mYpTI3PoQhj0lEUmHtw$a",
		"scrypt$!!$" + key,
		"pbkdf2$1000$Xn_mYpTI3PoQhj0lEUmHtw$a",
		"pbkdf2$1000$!!$" + key,
	} {
		if CheckPassword("a long password", stored) {
			t.Errorf("%s matched", stored)
		}
	}
}

func TestSealedTextOpensBothWays(t *testing.T) {
	for _, c := range cases(t, "sealedByTs") {
		text, secret := str(c, "text"), str(c, "secret")
		if got, ok := UnsealText(str(c, "sealed"), secret); !ok || got != text {
			t.Errorf("unseal %q: %q %v", str(c, "sealed"), got, ok)
		}
		sealed, err := SealText(text, secret)
		if err != nil {
			t.Fatal(err)
		}
		if got, ok := UnsealText(sealed, secret); !ok || got != text {
			t.Errorf("round trip %q: %q %v", text, got, ok)
		}
	}
	for _, c := range cases(t, "sealedWithIv") {
		sealed, err := sealWith(str(c, "text"), str(c, "secret"), mustBase64(t, str(c, "iv")))
		if err != nil || sealed != str(c, "sealed") {
			t.Errorf("seal %q with %s: %q %v", str(c, "text"), str(c, "iv"), sealed, err)
		}
	}
}

func TestUnsealAnswersAsTypeScriptDoes(t *testing.T) {
	for _, c := range cases(t, "unseal") {
		got, ok := UnsealText(str(c, "sealed"), str(c, "secret"))
		want := js.Dig(c, "result")
		if want == nil {
			if ok {
				t.Errorf("%q under %q: %q, want nothing", str(c, "sealed"), str(c, "secret"), got)
			}
			continue
		}
		if !ok || got != want.(string) {
			t.Errorf("%q: %q %v, want %q", str(c, "sealed"), got, ok, want)
		}
	}
}

func TestBase64AndBase32(t *testing.T) {
	for _, c := range cases(t, "base64") {
		got, err := FromBase64url(str(c, "text"))
		if throws(c) {
			var dom *DOMError
			if !errors.As(err, &dom) || dom.Name != "InvalidCharacterError" {
				t.Errorf("%q should fail, got %x", str(c, "text"), got)
			}
			continue
		}
		if err != nil || hex.EncodeToString(got) != str(c, "value") {
			t.Errorf("%q: %x %v", str(c, "text"), got, err)
		}
	}
	for _, c := range cases(t, "encode") {
		bytes, _ := hex.DecodeString(str(c, "hex"))
		if got := Base64url(bytes); got != str(c, "base64url") {
			t.Errorf("base64url %s: %s", str(c, "hex"), got)
		}
		if got := Base32(bytes); got != str(c, "base32") {
			t.Errorf("base32 %s: %s", str(c, "hex"), got)
		}
		if got := hex.EncodeToString(mustBase64(t, str(c, "base64url"))); got != str(c, "hex") {
			t.Errorf("from base64url %s: %s", str(c, "base64url"), got)
		}
		if got := hex.EncodeToString(Unbase32(str(c, "base32"))); got != str(c, "hex") {
			t.Errorf("from base32 %s: %s", str(c, "base32"), got)
		}
	}
}

func TestTotpCodes(t *testing.T) {
	for _, c := range cases(t, "totp") {
		// The fixture's step is a JavaScript number; the TypeScript callers only pass whole ones, as PHP's (int) does.
		step := int64(js.Num(js.Dig(c, "step")))
		got, err := TOTP(str(c, "secret"), step)
		if throws(c) {
			var dom *DOMError
			if !errors.As(err, &dom) || dom.Name != str(c, "throws") {
				t.Errorf("%q at %d should fail, got %q", str(c, "secret"), step, got)
			}
			continue
		}
		if err != nil || got != str(c, "value") {
			t.Errorf("%q at %d: %q %v, want %s", str(c, "secret"), step, got, err, str(c, "value"))
		}
	}
}

func TestRfc6238Vector(t *testing.T) {
	// RFC 6238's SHA-1 secret "12345678901234567890" at 59 seconds: 94287082, of which authenticator apps show the last six.
	secret := Base32([]byte("12345678901234567890"))
	if got, _ := TOTP(secret, 1); got != "287082" {
		t.Errorf("at 59 seconds: %s", got)
	}
	if got, _ := TOTP(secret, 1234567890/30); got != "005924" {
		t.Errorf("at 1234567890: %s", got)
	}
}

func TestMatchStepAllowsOneStepEitherSideAndNeverAnOldOne(t *testing.T) {
	secret := "JBSWY3DPEHPK3PXP"
	now := int64(1_759_900_000_000)
	step := now / StepMS
	code := func(s int64) string { c, _ := TOTP(secret, s); return c }
	for _, s := range []int64{step, step - 1, step + 1} {
		if got, ok, err := MatchStep(secret, code(s), now, 0); !ok || got != s || err != nil {
			t.Errorf("step %d: %d %v %v", s, got, ok, err)
		}
	}
	if _, ok, _ := MatchStep(secret, code(step+2), now, 0); ok {
		t.Error("two steps ahead matched")
	}
	if _, ok, _ := MatchStep(secret, code(step), now, step); ok {
		t.Error("a code used once is not taken again")
	}
	if _, _, err := MatchStep("", "123456", now, 0); err == nil {
		t.Error("an empty secret should fail as WebCrypto does")
	}
}

func TestOtpauthSignaturesRecoveryAndSameText(t *testing.T) {
	for _, c := range cases(t, "uris") {
		if got := OtpauthURI(str(c, "secret"), str(c, "email"), str(c, "host")); got != str(c, "uri") {
			t.Errorf("uri: %s", got)
		}
	}
	for _, c := range cases(t, "signatures") {
		if got, err := Signature(str(c, "secret"), str(c, "body"), str(c, "hash")); err != nil || got != str(c, "signature") {
			t.Errorf("signature: %s %v", got, err)
		}
	}
	if _, err := Signature("", "a", "b"); err == nil {
		t.Error("an empty secret should fail as WebCrypto does")
	}
	for _, c := range cases(t, "recovery") {
		if got := RecoveryHash(str(c, "code")); got != str(c, "hash") {
			t.Errorf("recovery %q: %s", str(c, "code"), got)
		}
	}
	for _, c := range cases(t, "same") {
		if got := SameText(str(c, "a"), str(c, "b")); got != js.Dig(c, "same").(bool) {
			t.Errorf("same %q %q: %v", str(c, "a"), str(c, "b"), got)
		}
	}
	codes := RecoveryCodes()
	if len(codes) != 10 {
		t.Fatalf("%d codes", len(codes))
	}
	for _, code := range codes {
		if !regexp.MustCompile(`^[a-z2-7]{4}-[a-z2-7]{4}$`).MatchString(code) {
			t.Errorf("code %q", code)
		}
	}
}

func TestDecodeUTF8ReplacesAsTextDecoderDoes(t *testing.T) {
	for in, want := range map[string]string{
		"\xEF\xBB\xBFa":          "a",
		"a\xE2\x82b":             "a�b",
		"\xF0\x9F\x99":           "�",
		"\xED\xA0\x80":           "���",
		"\xC0\xAF":               "��",
		"\xF4\x90\x80\x80":       "����",
		"x\xE0\x80y\xE2\x82\xAC": "x��y€",
	} {
		if got := decodeUTF8([]byte(in)); got != want {
			t.Errorf("%q: %q, want %q", in, got, want)
		}
	}
}
