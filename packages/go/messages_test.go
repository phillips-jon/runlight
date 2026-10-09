package runlight

import (
	"encoding/base64"
	"math"
	"testing"

	"runlight.sh/go/internal/fixture"
	"runlight.sh/go/internal/js"
)

func varsOf(v any) Vars {
	out := Vars{}
	js.Obj(v).Each(func(k string, v any) { out[k] = v })
	return out
}

func numberOf(v any) float64 {
	switch js.Str(v) {
	case "NaN":
		return math.NaN()
	case "Infinity":
		return math.Inf(1)
	case "-Infinity":
		return math.Inf(-1)
	}
	return js.Num(v)
}

func TestMessages(t *testing.T) {
	f := fixture.PHP(t, "messages.json")
	same(t, "languages", Languages(), js.Dig(f, "languages"))
	numbers := js.Arr(js.Dig(f, "numbers"))
	for _, lang := range js.Arr(js.Dig(f, "languages")) {
		forms := js.Arr(js.Dig(f, "plural", js.Str(lang)))
		for i, n := range numbers {
			if got := PluralForm(js.Str(lang), numberOf(n)); got != js.Str(forms[i]) {
				t.Errorf("%s %v: %s not %s", lang, n, got, forms[i])
			}
		}
	}
	for _, w := range js.Arr(js.Dig(f, "words")) {
		tr := NewTranslator(js.Str(js.Dig(w, "lang")))
		if tr.Lang != js.Str(js.Dig(w, "code")) {
			t.Errorf("lang %v: %s", js.Dig(w, "lang"), tr.Lang)
		}
		for _, c := range js.Arr(js.Dig(w, "t")) {
			if got := tr.T(js.Str(js.Dig(c, "key")), varsOf(js.Dig(c, "vars"))); got != js.Str(js.Dig(c, "text")) {
				t.Errorf("%s %v: %q not %q", tr.Lang, js.Dig(c, "key"), got, js.Dig(c, "text"))
			}
		}
		for _, c := range js.Arr(js.Dig(w, "tn")) {
			n := numberOf(js.Dig(c, "n"))
			vars := varsOf(js.Dig(c, "vars"))
			if js.Dig(c, "vars") == nil {
				vars = Vars{"n": n}
			}
			if got := tr.TN(js.Str(js.Dig(c, "key")), n, vars); got != js.Str(js.Dig(c, "text")) {
				t.Errorf("%s %v %v: %q not %q", tr.Lang, js.Dig(c, "key"), n, got, js.Dig(c, "text"))
			}
		}
	}
}

func cellOf(v any) any {
	if o := js.Obj(v); o != nil && o.Has("js") {
		switch js.Str(o.Value("js")) {
		case "undefined":
			return js.Undefined{}
		case "NaN":
			return math.NaN()
		case "Infinity":
			return math.Inf(1)
		case "-Infinity":
			return math.Inf(-1)
		case "-0":
			return math.Copysign(0, -1)
		}
	}
	return v
}

func TestZipAndCsv(t *testing.T) {
	f := fixture.PHP(t, "zip.json")
	for _, c := range js.Arr(js.Dig(f, "rows")) {
		if got := CsvRow([]any{cellOf(js.Dig(c, "cell"))}); got != js.Str(js.Dig(c, "row")) {
			t.Errorf("row %s: %q not %q", js.Stringify(js.Dig(c, "cell")), got, js.Dig(c, "row"))
		}
	}
	for _, c := range js.Arr(js.Dig(f, "csvs")) {
		header := []string{}
		for _, h := range js.Arr(js.Dig(c, "header")) {
			header = append(header, js.Str(h))
		}
		rows := [][]any{}
		for _, r := range js.Arr(js.Dig(c, "rows")) {
			row := []any{}
			for _, cell := range js.Arr(r) {
				row = append(row, cellOf(cell))
			}
			rows = append(rows, row)
		}
		if got := Csv(header, rows); got != js.Str(js.Dig(c, "csv")) {
			t.Errorf("csv: %q not %q", got, js.Dig(c, "csv"))
		}
	}
	for _, c := range js.Arr(js.Dig(f, "zips")) {
		files := []ZipFile{}
		for _, file := range js.Arr(js.Dig(c, "files")) {
			files = append(files, ZipFile{js.Str(js.Dig(file, "name")), js.Str(js.Dig(file, "text"))})
		}
		if got := base64.StdEncoding.EncodeToString(Zip(files, int64(js.Num(js.Dig(c, "now"))))); got != js.Str(js.Dig(c, "base64")) {
			t.Errorf("zip %s:\n got %s\nwant %s", js.Stringify(js.Dig(c, "files")), got, js.Dig(c, "base64"))
		}
	}
}
