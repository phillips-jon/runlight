package js

import (
	_ "embed"
	"encoding/json"
	"strconv"
	"strings"
	"sync"
	"unicode"
)

// casing.json is written by scripts/go-casing.mjs from Node's own
// toLowerCase and toUpperCase, so case changes here are JavaScript's
// exactly, full mappings included (İ to i̇, ß to SS), whatever Unicode
// version Go was built with.
//
//go:embed casing.json
var casingJSON []byte

var (
	casingOnce sync.Once
	lowerMap   map[rune]string
	upperMap   map[rune]string
)

func loadCasing() {
	var raw struct {
		Lower map[string]string `json:"lower"`
		Upper map[string]string `json:"upper"`
	}
	if err := json.Unmarshal(casingJSON, &raw); err != nil {
		panic("js: casing.json: " + err.Error())
	}
	conv := func(m map[string]string) map[rune]string {
		out := make(map[rune]string, len(m))
		for k, v := range m {
			n, _ := strconv.ParseUint(k, 16, 32)
			out[rune(n)] = v
		}
		return out
	}
	lowerMap, upperMap = conv(raw.Lower), conv(raw.Upper)
}

// ToLower is String.prototype.toLowerCase.
func ToLower(s string) string {
	ascii := true
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			ascii = false
			break
		}
	}
	if ascii {
		return strings.ToLower(s)
	}
	casingOnce.Do(loadCasing)
	s = WellFormed(s)
	runes := []rune(s)
	var b strings.Builder
	for i, r := range runes {
		if r == 0x3a3 {
			if finalSigma(runes, i) {
				b.WriteRune('ς')
			} else {
				b.WriteRune('σ')
			}
			continue
		}
		if m, ok := lowerMap[r]; ok {
			b.WriteString(m)
		} else {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// ToUpper is String.prototype.toUpperCase.
func ToUpper(s string) string {
	ascii := true
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			ascii = false
			break
		}
	}
	if ascii {
		return strings.ToUpper(s)
	}
	casingOnce.Do(loadCasing)
	s = WellFormed(s)
	var b strings.Builder
	for _, r := range s {
		if m, ok := upperMap[r]; ok {
			b.WriteString(m)
		} else {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// finalSigma is Unicode's Final_Sigma condition: a cased letter before,
// skipping case-ignorable characters, and none after.
func finalSigma(runes []rune, at int) bool {
	before := false
	for i := at - 1; i >= 0; i-- {
		if caseIgnorable(runes[i]) {
			continue
		}
		before = cased(runes[i])
		break
	}
	if !before {
		return false
	}
	for i := at + 1; i < len(runes); i++ {
		if caseIgnorable(runes[i]) {
			continue
		}
		return !cased(runes[i])
	}
	return true
}

func cased(r rune) bool {
	return unicode.IsUpper(r) || unicode.IsLower(r) || unicode.IsTitle(r) || unicode.In(r, unicode.Other_Lowercase, unicode.Other_Uppercase)
}

func caseIgnorable(r rune) bool {
	switch r {
	case '\'', '.', ':', '^', '`', 0xad, 0xb7, 0x2019:
		return true
	}
	return unicode.In(r, unicode.Mn, unicode.Me, unicode.Cf, unicode.Lm, unicode.Sk)
}
