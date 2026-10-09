package runlight

import (
	"math"
	"regexp"

	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/whatwg"
)

// Payload is what the tracker sends, after validation. Anything malformed is dropped.
type Payload struct {
	// Kind is pageview, event, or engagement.
	Kind         string
	Site         string
	URL          *whatwg.URL
	Referrer     string
	Title        string
	ScreenWidth  *int
	ScreenHeight *int
	Language     string
	Name         string
	Props        *js.Object
	PageviewID   string
	EngagedMs    int64
	Scroll       *int
}

// MaxBody is the longest tracker body read, in UTF-16 code units.
const MaxBody = 8 * 1024

// maxEngagedMs: one engagement ping covers at most the 30 minutes a session can idle.
const maxEngagedMs = 30 * 60 * 1000

const maxProps = 30

func payloadStr(value any, max int) string {
	s, ok := value.(string)
	if !ok {
		return ""
	}
	return head16(s, max)
}

func payloadInt(value any, min, max float64) *int {
	n, ok := value.(float64)
	if !ok || math.IsNaN(n) || math.IsInf(n, 0) {
		return nil
	}
	v := int(math.Min(max, math.Max(min, js.Round(n))))
	return &v
}

func payloadProps(value any) *js.Object {
	o, ok := value.(*js.Object)
	if !ok {
		return nil
	}
	out := &js.Object{}
	count := 0
	for _, key := range o.Keys() {
		if count >= maxProps {
			break
		}
		k := head16(jsTrim(key), 60)
		if k == "" {
			continue
		}
		var value string
		switch raw := o.Value(key).(type) {
		case string:
			value = head16(raw, 500)
		case float64:
			if math.IsNaN(raw) || math.IsInf(raw, 0) {
				continue
			}
			value = js.FormatNumber(raw)
		case bool:
			value = js.String(raw)
		default:
			continue
		}
		// Assigning a string to __proto__ changes nothing in JavaScript, yet it still counts.
		if k != "__proto__" {
			out.Set(k, value)
		}
		count++
	}
	if count == 0 {
		return nil
	}
	return out
}

var alphanumeric = regexp.MustCompile(`^[A-Za-z0-9]+$`)

// ParsePayload reads a tracker body, nil when it is malformed.
func ParsePayload(text string) *Payload {
	if len16(text) > MaxBody {
		return nil
	}
	parsed, err := js.Parse(text)
	if err != nil {
		return nil
	}
	body, ok := parsed.(*js.Object)
	if !ok {
		return nil
	}
	kind, _ := body.Value("k").(string)
	if kind != "pageview" && kind != "event" && kind != "engagement" {
		return nil
	}
	u, err := whatwg.Parse(payloadStr(body.Value("u"), 2048))
	if err != nil {
		return nil
	}
	if u.Protocol != "http:" && u.Protocol != "https:" {
		return nil
	}
	name := jsTrim(payloadStr(body.Value("n"), 120))
	if kind == "event" && name == "" {
		return nil
	}
	pageviewID := payloadStr(body.Value("i"), 32)
	if pageviewID != "" && !alphanumeric.MatchString(pageviewID) {
		return nil
	}
	if kind == "engagement" && pageviewID == "" {
		return nil
	}
	p := &Payload{
		Kind:         kind,
		Site:         payloadStr(body.Value("s"), 64),
		URL:          u,
		Referrer:     payloadStr(body.Value("r"), 2048),
		Title:        payloadStr(body.Value("t"), 500),
		ScreenWidth:  payloadInt(body.Value("w"), 0, 20000),
		ScreenHeight: payloadInt(body.Value("h"), 0, 20000),
		Language:     payloadStr(body.Value("l"), 35),
		Name:         name,
		PageviewID:   pageviewID,
		Scroll:       payloadInt(body.Value("d"), 0, 100),
	}
	if kind == "event" {
		p.Props = payloadProps(body.Value("p"))
	}
	if kind == "engagement" {
		if e := payloadInt(body.Value("e"), 0, maxEngagedMs); e != nil {
			p.EngagedMs = int64(*e)
		}
	}
	return p
}
