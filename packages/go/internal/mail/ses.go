package mail

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"regexp"
	"sort"
	"strings"
	"time"

	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
	"runlight.sh/go/internal/whatwg"
)

// Amazon SES (API v2) with a hand-rolled Signature Version 4, so there is no
// AWS SDK to install. https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html

func sha256Hex(text string) string {
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:])
}

func hmacSHA256(key []byte, text string) []byte {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(text))
	return mac.Sum(nil)
}

// SignInput is what SignV4 signs.
type SignInput struct {
	Method          string
	URL             *whatwg.URL
	Body            string
	Region          string
	Service         string
	AccessKeyID     string
	SecretAccessKey string
	// Now is milliseconds since the epoch.
	Now int64
	// Headers are the request's headers, in order, each value a string.
	Headers *js.Object
}

var (
	millis       = regexp.MustCompile(`\.\d{3}`)
	jsWhitespace = regexp.MustCompile(`[` + js.Whitespace + `]+`)
)

// SignV4 signs a request: the headers given, then host, x-amz-date, and authorization. It is
// exported for its test against AWS's published example, and fails only where TypeScript's
// decodeURIComponent would, on a path with a broken escape.
func SignV4(input SignInput) (*js.Object, error) {
	amzDate := strings.NewReplacer("-", "", ":", "").Replace(js.ISOString(input.Now))
	if loc := millis.FindStringIndex(amzDate); loc != nil {
		amzDate = amzDate[:loc[0]] + amzDate[loc[1]:]
	}
	day := js.Head16(amzDate, 8)
	payloadHash := sha256Hex(input.Body)
	headers := js.NewObject()
	if input.Headers != nil {
		headers = input.Headers.Clone()
	}
	headers.Set("host", input.URL.Host())
	headers.Set("x-amz-date", amzDate)
	var names []string
	lower := map[string]string{}
	headers.Each(func(k string, v any) {
		name := js.ToLower(k)
		names = append(names, name)
		lower[name] = jsWhitespace.ReplaceAllString(js.Trim(js.String(v)), " ")
	})
	sort.SliceStable(names, func(i, j int) bool { return lessUnits(names[i], names[j]) })

	segments := strings.Split(input.URL.Pathname, "/")
	for i, p := range segments {
		decoded, err := decodeURIComponent(p)
		if err != nil {
			return nil, err
		}
		if segments[i], err = encodeURIComponent(decoded); err != nil {
			return nil, err
		}
	}
	path := strings.Join(segments, "/")
	if path == "" {
		path = "/"
	}
	pairs := input.URL.SearchParams().Pairs()
	sort.SliceStable(pairs, func(i, j int) bool { return lessUnits(pairs[i][0], pairs[j][0]) })
	query := make([]string, len(pairs))
	for i, p := range pairs {
		k, err := encodeURIComponent(p[0])
		if err != nil {
			return nil, err
		}
		v, err := encodeURIComponent(p[1])
		if err != nil {
			return nil, err
		}
		query[i] = k + "=" + v
	}
	var canonicalHeaders strings.Builder
	for _, n := range names {
		canonicalHeaders.WriteString(n + ":" + lower[n] + "\n")
	}
	signed := strings.Join(names, ";")
	canonical := strings.Join([]string{input.Method, path, strings.Join(query, "&"), canonicalHeaders.String(), signed, payloadHash}, "\n")
	scope := day + "/" + input.Region + "/" + input.Service + "/aws4_request"
	toSign := strings.Join([]string{"AWS4-HMAC-SHA256", amzDate, scope, sha256Hex(canonical)}, "\n")
	key := hmacSHA256([]byte("AWS4"+input.SecretAccessKey), day)
	key = hmacSHA256(key, input.Region)
	key = hmacSHA256(key, input.Service)
	key = hmacSHA256(key, "aws4_request")
	signature := hex.EncodeToString(hmacSHA256(key, toSign))
	headers.Set("authorization", "AWS4-HMAC-SHA256 Credential="+input.AccessKeyID+"/"+scope+", SignedHeaders="+signed+", Signature="+signature)
	return headers, nil
}

var awsRegion = regexp.MustCompile(`^[a-z]{2}(-[a-z]+)+-\d$`)

// SESSend sends one message through Amazon SES, from the address given.
func SESSend(ctx context.Context, fetcher web.Fetcher, config Config, m Message, from string, opts Options) error {
	region := js.Trim(config["region"])
	if !awsRegion.MatchString(region) {
		return mailError("That is not an AWS region, like us-east-1", "mail_region")
	}
	url := whatwg.MustParse("https://email." + region + ".amazonaws.com/v2/email/outbound-emails")
	body := js.Stringify(js.NewObject(
		"FromEmailAddress", from,
		"Destination", js.NewObject("ToAddresses", []any{m.To}),
		"Content", js.NewObject(
			"Simple", js.NewObject(
				"Subject", js.NewObject("Data", m.Subject, "Charset", "UTF-8"),
				"Body", js.NewObject("Html", js.NewObject("Data", m.HTML, "Charset", "UTF-8"), "Text", js.NewObject("Data", m.Text, "Charset", "UTF-8")),
				"Headers", headerList(m, "Name", "Value"),
			),
		),
	))
	signed, err := SignV4(SignInput{
		Method:          "POST",
		URL:             url,
		Body:            body,
		Region:          region,
		Service:         "ses",
		AccessKeyID:     js.Trim(config["accessKeyId"]),
		SecretAccessKey: js.Trim(config["secretAccessKey"]),
		Now:             opts.now(),
		Headers:         js.NewObject("content-type", "application/json"),
	})
	if err != nil {
		return err
	}
	signed.Delete("host")
	headers := web.NewHeaders()
	signed.Each(func(k string, v any) { headers.Append(k, js.String(v)) })
	response, err := fetcher.Fetch(ctx, url.Href(), web.FetchInit{Method: "POST", Headers: headers, Body: []byte(body), Timeout: 20 * time.Second})
	if err != nil {
		return mailError("Could not reach Amazon SES: "+err.Error(), "mail_unreachable", "host", "Amazon SES", "detail", err.Error())
	}
	if !response.OK() {
		return refused("Amazon SES", response.Status, ServiceMessage(response.Text()))
	}
	return nil
}
