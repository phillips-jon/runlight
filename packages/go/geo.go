package runlight

import (
	"errors"
	"regexp"
	"strings"

	"runlight.sh/go/internal/js"
	"runlight.sh/go/mmdb"
)

// Location is where a visitor is.
type Location struct {
	// Country is ISO 3166-1 alpha-2, upper case.
	Country string `json:"country"`
	// Region is ISO 3166-2, such as "US-CA".
	Region string `json:"region"`
	City   string `json:"city"`
}

// GeoLookup looks a client IP up in a database of the app's choosing, such
// as an MMDB file (FileLookup). Any field may be left empty; nil is no
// answer.
type GeoLookup func(ip string) (*Location, error)

func geoDecode(value string) string {
	if value == "" {
		return ""
	}
	if decoded, ok := decodeURIComponent(value); ok {
		return jsTrim(decoded)
	}
	return jsTrim(value)
}

var (
	countryCode = regexp.MustCompile(`^[A-Z]{2}$`)
	regionCode  = regexp.MustCompile(`^([A-Za-z]{2}-)?[A-Za-z0-9]{1,3}$`)
	regionPre   = regexp.MustCompile(`^[A-Z]{2}-`)
)

func cleanLocation(l Location) Location {
	country := head16(upper(l.Country), 2)
	if !countryCode.MatchString(country) || country == "XX" || country == "T1" {
		country = ""
	}
	// A code ("CA", "US-CA") is kept as ISO 3166-2; a name from a database
	// that has no codes ("California") is kept readable, as "US-California".
	raw := jsTrim(l.Region)
	var region string
	if regionCode.MatchString(raw) {
		region = upper(raw)
	} else {
		region = head16(raw, 80)
	}
	if region != "" && !regionPre.MatchString(region) && country != "" {
		region = country + "-" + region
	}
	if country == "" {
		region = ""
	}
	city := ""
	if country != "" {
		city = head16(l.City, 100)
	}
	return Location{country, region, city}
}

// headerGetter is what location reads of a request's headers.
type headerGetter interface {
	Get(name string) string
}

// LocationFromHeaders is the location a hosting platform's headers give,
// if any: Vercel's, Cloudflare's, or Netlify's.
func LocationFromHeaders(headers headerGetter) *Location {
	if vercel := headers.Get("x-vercel-ip-country"); vercel != "" {
		l := cleanLocation(Location{vercel, geoDecode(headers.Get("x-vercel-ip-country-region")), geoDecode(headers.Get("x-vercel-ip-city"))})
		return &l
	}
	if cloudflare := headers.Get("cf-ipcountry"); cloudflare != "" {
		l := cleanLocation(Location{cloudflare, geoDecode(headers.Get("cf-region-code")), geoDecode(headers.Get("cf-ipcity"))})
		return &l
	}
	if netlify := headers.Get("x-nf-geo"); netlify != "" {
		text, err := atob(netlify)
		if err != nil {
			return nil
		}
		geo, err := js.Parse(text)
		if err != nil || geo == nil {
			return nil
		}
		// A field that is there but not text has no string methods, which JavaScript throws on
		// where it calls one: always for the country and region, and for the city only when there
		// is a country.
		field := func(path ...any) (string, bool) {
			v := js.Dig(geo, path...)
			if v == nil {
				return "", true
			}
			s, ok := v.(string)
			return s, ok
		}
		country, ok1 := field("country", "code")
		region, ok2 := field("subdivision", "code")
		city, ok3 := field("city")
		if !ok1 || !ok2 {
			return nil
		}
		l := cleanLocation(Location{country, region, city})
		if !ok3 && l.Country != "" {
			return nil
		}
		return &l
	}
	return nil
}

var asciiSpace = regexp.MustCompile(`[\t\n\f\r ]`)

// atob is forgiving base64 to a binary string, each byte one character.
func atob(text string) (string, error) {
	text = asciiSpace.ReplaceAllString(text, "")
	if len(text)%4 == 0 {
		text = strings.TrimSuffix(text, "=")
		text = strings.TrimSuffix(text, "=")
	}
	if len(text)%4 == 1 || strings.ContainsFunc(text, func(r rune) bool {
		return !(r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '+' || r == '/')
	}) {
		return "", errors.New("The string to be decoded is not correctly encoded.")
	}
	b := forgivingDecode(text)
	runes := make([]rune, len(b))
	for i, c := range b {
		runes[i] = rune(c)
	}
	return string(runes), nil
}

// forgivingDecode decodes base64 ignoring any leftover bits.
func forgivingDecode(text string) []byte {
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	var out []byte
	buffer, bits := 0, 0
	for i := 0; i < len(text); i++ {
		buffer = buffer<<6 | strings.IndexByte(alphabet, text[i])
		bits += 6
		if bits >= 8 {
			bits -= 8
			out = append(out, byte(buffer>>bits))
		}
	}
	return out
}

// Locate is where a request comes from: its platform's headers when they
// name a country, else the lookup's answer for its address, else nowhere.
func Locate(headers headerGetter, ip string, lookup GeoLookup) Location {
	if from := LocationFromHeaders(headers); from != nil && from.Country != "" {
		return *from
	}
	if lookup != nil && ip != "" {
		found, err := safeLookup(lookup, ip)
		if err == nil && found != nil {
			return cleanLocation(*found)
		}
		// A broken lookup must never lose the event.
	}
	return Location{}
}

func safeLookup(lookup GeoLookup, ip string) (found *Location, err error) {
	defer func() {
		if recover() != nil {
			found, err = nil, errors.New("lookup panicked")
		}
	}()
	return lookup(ip)
}

var district = regexp.MustCompile(`[` + js.Whitespace + `]*\([^)]*\)[` + js.Whitespace + `]*$`)

// cityName is a city as people say it: DB-IP adds districts in brackets,
// as in "Toronto (Old Toronto)".
func cityName(name string) string {
	return jsTrim(district.ReplaceAllString(js.WellFormed(name), ""))
}

// LookupFrom is a lookup answering from an MMDB reader. DB-IP's records
// follow MaxMind's city layout, with names but no subdivision codes.
func LookupFrom(reader *mmdb.Reader) GeoLookup {
	return func(ip string) (*Location, error) {
		found, err := reader.Get(ip)
		if err != nil {
			return nil, nil
		}
		country, _ := js.Dig(found, "country", "iso_code").(string)
		if country == "" {
			return nil, nil
		}
		sub := js.Dig(found, "subdivisions", 0)
		region, ok := js.Dig(sub, "iso_code").(string)
		if !ok {
			region, _ = js.Dig(sub, "names", "en").(string)
		}
		city, _ := js.Dig(found, "city", "names", "en").(string)
		return &Location{Country: country, Region: region, City: cityName(city)}, nil
	}
}

// FileLookup is a lookup from an MMDB file the owner supplies, such as
// MaxMind's GeoLite2 City or DB-IP's free databases.
func FileLookup(file string) (GeoLookup, error) {
	reader, err := mmdb.Open(file)
	if err != nil {
		return nil, err
	}
	return LookupFrom(reader), nil
}
