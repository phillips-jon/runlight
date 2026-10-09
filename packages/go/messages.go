package runlight

import (
	"math"
	"regexp"
	"strconv"
	"strings"
	"sync"

	"runlight.sh/go/internal/assets"
	"runlight.sh/go/internal/js"
)

// The dashboard's translations, for text the server writes (email reports).
// Same keys, same placeholders, so every language stays in one place.

var (
	tablesMu sync.Mutex
	tables   = map[string]map[string]string{}
)

func messageTable(lang string) map[string]string {
	tablesMu.Lock()
	defer tablesMu.Unlock()
	if found, ok := tables[lang]; ok {
		return found
	}
	found := map[string]string{}
	if raw, ok := assets.Locales[lang]; ok {
		if v, err := js.Parse(raw); err == nil {
			js.Obj(v).Each(func(k string, v any) { found[k] = js.Str(v) })
		}
	}
	tables[lang] = found
	return found
}

// Languages are the languages the dashboard and email reports come in.
func Languages() []string { return assets.LocaleOrder }

// Vars fill a message's {placeholders}: strings, or numbers written as
// JavaScript writes them.
type Vars map[string]any

var placeholder = regexp.MustCompile(`\{(\w+)\}`)

func fillMessage(text string, vars Vars) string {
	return placeholder.ReplaceAllStringFunc(text, func(m string) string {
		if v, ok := vars[m[1:len(m)-1]]; ok {
			return js.String(v)
		}
		return m
	})
}

// Translator writes the dashboard's messages in one language.
type Translator struct {
	Lang string
}

// NewTranslator is the translator for a language, English for one there is none of.
func NewTranslator(lang string) Translator {
	for _, l := range Languages() {
		if l == lang {
			return Translator{lang}
		}
	}
	return Translator{"en"}
}

// T is a message, its placeholders filled; the key itself when no language has it.
func (tr Translator) T(key string, vars Vars) string {
	if text, ok := messageTable(tr.Lang)[key]; ok {
		return fillMessage(text, vars)
	}
	if text, ok := messageTable("en")[key]; ok {
		return fillMessage(text, vars)
	}
	return fillMessage(key, vars)
}

// TN is a message for a count, in the plural form the language uses for it.
func (tr Translator) TN(key string, n float64, vars Vars) string {
	form := PluralForm(tr.Lang, n)
	table := messageTable(tr.Lang)
	own, ok := table[key+"_"+form]
	if !ok {
		own, ok = table[key+"_other"]
	}
	if ok {
		return fillMessage(own, vars)
	}
	return tr.T(key+"_other", vars)
}

// PluralForm is Intl.PluralRules(lang).select(n) for the languages Runlight
// speaks: one, many, or other.
func PluralForm(lang string, n float64) string {
	if math.IsNaN(n) || math.IsInf(n, 0) {
		return "other"
	}
	// The number as Intl reads it: at most three fraction digits, halves away from zero.
	text := roundDecimal(strconv.FormatFloat(math.Abs(n), 'f', -1, 64), 3)
	whole, fraction, _ := strings.Cut(text, ".")
	fraction = strings.TrimRight(fraction, "0")
	v := len(fraction)
	// ICU keeps the integer part's last 18 digits only, so 1e18 reads as 0.
	if len(whole) > 18 {
		whole = whole[len(whole)-18:]
	}
	i, err := strconv.ParseFloat(whole, 64)
	if err != nil {
		return "other"
	}
	million := v == 0 && i != 0 && math.Mod(i, 1_000_000) == 0
	switch lang {
	case "en", "de":
		if i == 1 && v == 0 {
			return "one"
		}
	case "es":
		if i == 1 && v == 0 {
			return "one"
		}
		if million {
			return "many"
		}
	case "fr", "pt":
		if i == 0 || i == 1 {
			return "one"
		}
		if million {
			return "many"
		}
	}
	return "other"
}

// roundDecimal rounds decimal digits to at most places fraction digits,
// halves away from zero, on the text itself so 99.9995 is 100.
func roundDecimal(text string, places int) string {
	whole, fraction, _ := strings.Cut(text, ".")
	if len(fraction) <= places {
		return text
	}
	up := fraction[places] >= '5'
	digits := []byte(whole + fraction[:places])
	if up {
		i := len(digits) - 1
		for ; i >= 0; i-- {
			if digits[i] == '9' {
				digits[i] = '0'
				continue
			}
			digits[i]++
			break
		}
		if i < 0 {
			digits = append([]byte{'1'}, digits...)
		}
	}
	cut := len(digits) - places
	return string(digits[:cut]) + "." + string(digits[cut:])
}
