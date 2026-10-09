// Package intl is the pieces of JavaScript's Intl the email reports use, for
// the dashboard's languages (en, de, es, fr, and pt): Intl.NumberFormat for
// counts, percents, one decimal place, and currencies, Intl.DateTimeFormat
// for a month and year or a short day, and Intl.DisplayNames for regions.
// Region names and how currencies are written come from intl.json, written
// from Node's ICU by scripts/go-intl.mjs.
//
// Numbers round as ICU does, half away from zero on the number's shortest
// decimal form, so 2.05 to one place is 2.1, though the double just under it
// is what is stored.
package intl

import (
	_ "embed"
	"encoding/json"
	"math"
	"regexp"
	"strconv"
	"strings"
	"sync"
)

//go:embed intl.json
var data []byte

var (
	loaded sync.Once
	table  struct {
		Regions    map[string]map[string]string `json:"regions"`
		Currencies map[string]map[string][]any  `json:"currencies"`
	}
)

func load() {
	if err := json.Unmarshal(data, &table); err != nil {
		panic("intl: intl.json: " + err.Error())
	}
}

var (
	group   = map[string]string{"en": ",", "de": ".", "es": ".", "fr": " ", "pt": "."}
	decimal = map[string]string{"en": ".", "de": ",", "es": ",", "fr": ",", "pt": ","}
	percent = map[string][2]string{"en": {"", "%"}, "de": {"", " %"}, "es": {"", " %"}, "fr": {"", " %"}, "pt": {"", "%"}}
	months  = map[string][]string{
		"en": {"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"},
		"de": {"Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"},
		"es": {"enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"},
		"fr": {"janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"},
		"pt": {"janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro"},
	}
	shortMonths = map[string][]string{
		"en": {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"},
		"de": {"Jan.", "Feb.", "März", "Apr.", "Mai", "Juni", "Juli", "Aug.", "Sept.", "Okt.", "Nov.", "Dez."},
		"es": {"ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sept", "oct", "nov", "dic"},
		"fr": {"janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."},
		"pt": {"jan.", "fev.", "mar.", "abr.", "mai.", "jun.", "jul.", "ago.", "set.", "out.", "nov.", "dez."},
	}
	// datePatterns are { month: "long", year: "numeric" }, then { month: "short", day: "numeric" } without and with the year.
	datePatterns = map[string][3]string{
		"en": {"{M} {y}", "{m} {d}", "{m} {d}, {y}"},
		"de": {"{M} {y}", "{d}. {m}", "{d}. {m} {y}"},
		"es": {"{M} de {y}", "{d} {m}", "{d} {m} {y}"},
		"fr": {"{M} {y}", "{d} {m}", "{d} {m} {y}"},
		"pt": {"{M} de {y}", "{d} de {m}", "{d} de {m} de {y}"},
	}
)

func language(lang string) string {
	if _, ok := group[lang]; ok {
		return lang
	}
	return "en"
}

// Number is new Intl.NumberFormat(lang, { minimumFractionDigits, maximumFractionDigits }).format(n); the defaults are 0 and 3.
func Number(lang string, n float64, minFraction, maxFraction int) string {
	lang = language(lang)
	if math.IsNaN(n) {
		return "NaN"
	}
	if math.IsInf(n, 0) {
		if n < 0 {
			return "-∞"
		}
		return "∞"
	}
	negative, whole, fraction := rounded(n, minFraction, maxFraction)
	// Spanish groups only from five digits on (CLDR's minimum grouping digits of 2).
	if !(lang == "es" && len(whole) < 5) {
		var b strings.Builder
		for i, c := range whole {
			if i > 0 && (len(whole)-i)%3 == 0 {
				b.WriteString(group[lang])
			}
			b.WriteRune(c)
		}
		whole = b.String()
	}
	out := whole
	if fraction != "" {
		out += decimal[lang] + fraction
	}
	if negative {
		out = "-" + out
	}
	return out
}

// Percent is new Intl.NumberFormat(lang, { style: "percent", maximumFractionDigits: 0 }).format(n).
func Percent(lang string, n float64) string {
	lang = language(lang)
	p := percent[lang]
	return p[0] + Number(lang, times100(n), 0, 0) + p[1]
}

var currencyCode = regexp.MustCompile(`^[A-Za-z]{3}$`)

// Currency is new Intl.NumberFormat(lang, { style: "currency", currency, maximumFractionDigits }).format(n),
// or `${n} ${currency}` where Intl throws (a currency code that is not three letters), as the reports write it.
func Currency(lang string, n float64, currency string, maxFraction int, fallback string) string {
	lang = language(lang)
	if !currencyCode.MatchString(currency) {
		return fallback
	}
	code := strings.ToUpper(currency)
	loaded.Do(load)
	before, after, digits := "", " "+code, 2
	if lang == "en" || lang == "pt" {
		before, after = code+" ", ""
	}
	if f, ok := table.Currencies[lang][code]; ok && len(f) == 3 {
		before, _ = f[0].(string)
		after, _ = f[1].(string)
		if d, ok := f[2].(float64); ok {
			digits = int(d)
		}
	}
	return before + Number(lang, n, min(digits, maxFraction), maxFraction) + after
}

// MonthYear is a date, YYYY-MM-DD, as { month: "long", year: "numeric" } writes it.
func MonthYear(lang, date string) string { return formatDate(lang, date, 0) }

// ShortDay is a date as { month: "short", day: "numeric" } writes it, with year: "numeric" too when asked.
func ShortDay(lang, date string, withYear bool) string {
	if withYear {
		return formatDate(lang, date, 2)
	}
	return formatDate(lang, date, 1)
}

func formatDate(lang, date string, pattern int) string {
	lang = language(lang)
	parts := strings.Split(date, "-")
	y, _ := strconv.Atoi(parts[0])
	m, _ := strconv.Atoi(parts[1])
	d, _ := strconv.Atoi(parts[2])
	return strings.NewReplacer("{M}", months[lang][m-1], "{m}", shortMonths[lang][m-1], "{d}", strconv.Itoa(d), "{y}", strconv.Itoa(y)).Replace(datePatterns[lang][pattern])
}

var regionCode = regexp.MustCompile(`^([A-Z]{2}|\d{3})$`)

// Region is new Intl.DisplayNames(lang, { type: "region" }).of(code), or
// the code where ICU has no name. Only an upper case code is looked up;
// Intl gives any other back as it came.
func Region(lang, code string) string {
	if !regionCode.MatchString(code) {
		return code
	}
	loaded.Do(load)
	if name, ok := table.Regions[language(lang)][code]; ok {
		return name
	}
	return code
}

// times100 is n * 100, worked out on the decimal digits, as ICU scales a
// percent, so 0.135 is 13.5 and not 13.500000000000002.
func times100(n float64) float64 {
	negative, digits, point := decimalForm(n)
	f, _ := strconv.ParseFloat(plain(digits, point+2), 64)
	if negative {
		return -f
	}
	return f
}

// rounded is the number's sign, whole digits, and fraction digits, rounded
// half away from zero to at most max places and padded to at least min.
func rounded(n float64, minFraction, maxFraction int) (bool, string, string) {
	negative, digits, point := decimalForm(n)
	keep := point + maxFraction
	var units string
	switch {
	case keep < 0:
		units = "0"
	case len(digits) > keep:
		if keep == 0 {
			units = "0"
		} else {
			units = digits[:keep]
		}
		if digits[keep] >= '5' {
			units = increment(units)
		}
	default:
		units = digits + strings.Repeat("0", keep-len(digits))
	}
	if len(units) < maxFraction+1 {
		units = strings.Repeat("0", maxFraction+1-len(units)) + units
	}
	whole := strings.TrimLeft(units[:len(units)-maxFraction], "0")
	fraction := ""
	if maxFraction > 0 {
		fraction = strings.TrimRight(units[len(units)-maxFraction:], "0")
	}
	if len(fraction) < minFraction {
		fraction += strings.Repeat("0", minFraction-len(fraction))
	}
	if whole == "" {
		whole = "0"
	}
	return negative, whole, fraction
}

func increment(digits string) string {
	b := []byte(digits)
	i := len(b) - 1
	for i >= 0 && b[i] == '9' {
		b[i] = '0'
		i--
	}
	if i < 0 {
		return "1" + string(b)
	}
	b[i]++
	return string(b)
}

// decimalForm is the shortest decimal form of a double: its sign, its
// significant digits, and where the point goes (the number of digits
// before it, which may be zero or negative).
func decimalForm(n float64) (bool, string, int) {
	negative := n < 0 || (n == 0 && math.Signbit(n))
	text := strconv.FormatFloat(math.Abs(n), 'e', -1, 64)
	mantissa, exp, _ := strings.Cut(text, "e")
	e, _ := strconv.Atoi(exp)
	digits := strings.Replace(mantissa, ".", "", 1)
	digits = strings.TrimRight(digits, "0")
	if digits == "" {
		return negative, "0", 1
	}
	return negative, digits, e + 1
}

// plain is digits with the point after point of them, written out in full.
func plain(digits string, point int) string {
	switch {
	case point <= 0:
		return "0." + strings.Repeat("0", -point) + digits
	case point >= len(digits):
		return digits + strings.Repeat("0", point-len(digits))
	}
	return digits[:point] + "." + digits[point:]
}
