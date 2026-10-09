package js

import (
	"math"
	"sort"
	"strconv"
)

// Dig reads a parsed JSON value by keys and indexes in turn, nil where
// any step is missing.
func Dig(v any, path ...any) any {
	for _, step := range path {
		switch k := step.(type) {
		case string:
			o, ok := v.(*Object)
			if !ok {
				return nil
			}
			v, _ = o.Get(k)
		case int:
			a, ok := v.([]any)
			if !ok || k < 0 || k >= len(a) {
				return nil
			}
			v = a[k]
		}
	}
	return v
}

// Str is a value that is a string, else "".
func Str(v any) string {
	s, _ := v.(string)
	return s
}

// Num is a value that is a number, else 0.
func Num(v any) float64 {
	switch n := v.(type) {
	case float64:
		return n
	case int:
		return float64(n)
	case int64:
		return float64(n)
	}
	return 0
}

// Arr is a value that is an array, else nil.
func Arr(v any) []any {
	a, _ := v.([]any)
	return a
}

// Obj is a value that is an object, else nil.
func Obj(v any) *Object {
	o, _ := v.(*Object)
	return o
}

// Each calls fn for every key and value of an object, in order.
func (o *Object) Each(fn func(key string, value any)) {
	if o == nil {
		return
	}
	for _, k := range o.keys {
		fn(k, o.vals[k])
	}
}

// Value is the value at key, nil when it is not there.
func (o *Object) Value(key string) any {
	v, _ := o.Get(key)
	return v
}

// String is String(value) for a JSON value, as JavaScript writes one in a
// template: null as "null", arrays joined with commas, objects as
// [object Object].
func String(v any) string {
	switch t := v.(type) {
	case nil:
		return "null"
	case Undefined:
		return "undefined"
	case string:
		return t
	case bool:
		if t {
			return "true"
		}
		return "false"
	case float64:
		return FormatNumber(t)
	case int:
		return strconv.Itoa(t)
	case int64:
		return strconv.FormatInt(t, 10)
	case []any:
		out := ""
		for i, e := range t {
			if i > 0 {
				out += ","
			}
			if e != nil {
				if _, u := e.(Undefined); !u {
					out += String(e)
				}
			}
		}
		return out
	case []string:
		out := ""
		for i, e := range t {
			if i > 0 {
				out += ","
			}
			out += e
		}
		return out
	}
	return "[object Object]"
}

// Truthy is whether JavaScript reads a value as true.
func Truthy(v any) bool {
	switch t := v.(type) {
	case nil, Undefined:
		return false
	case bool:
		return t
	case string:
		return t != ""
	case float64:
		return t != 0 && !math.IsNaN(t)
	case int:
		return t != 0
	case int64:
		return t != 0
	}
	return true
}

// ToNumber is Number(value) for a JSON value.
func ToNumber(v any) float64 {
	switch t := v.(type) {
	case nil:
		return 0
	case Undefined:
		return math.NaN()
	case bool:
		if t {
			return 1
		}
		return 0
	case float64:
		return t
	case int:
		return float64(t)
	case int64:
		return float64(t)
	case string:
		return Number(t)
	case []any:
		return Number(String(t))
	}
	return math.NaN()
}

// Canonical is a value's JSON with every object's keys sorted, so two
// values compare as JavaScript's deepEqual compares them.
func Canonical(v any) string {
	return Stringify(sortKeys(ToValue(v)))
}

func sortKeys(v any) any {
	switch t := v.(type) {
	case *Object:
		keys := t.Keys()
		sort.Strings(keys)
		out := &Object{}
		for _, k := range keys {
			out.keys = append(out.keys, k)
			if out.vals == nil {
				out.vals = map[string]any{}
			}
			out.vals[k] = sortKeys(t.Value(k))
		}
		return out
	case []any:
		out := make([]any, len(t))
		for i, e := range t {
			out[i] = sortKeys(e)
		}
		return out
	}
	return v
}

// Round is Math.round: halves go up, toward positive infinity, so -2.5
// becomes -2.
func Round(x float64) float64 {
	if math.IsNaN(x) || math.IsInf(x, 0) {
		return x
	}
	f := math.Floor(x)
	if x-f >= 0.5 {
		return f + 1
	}
	return f
}
