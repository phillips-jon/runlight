package runlight

import (
	"context"
	"crypto/rand"
	"errors"
	"regexp"

	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/whatwg"
)

// LinkInput is what a person or an import may set on a link. A nil field is not given.
type LinkInput struct {
	URL  string
	Name *string
	Slug *string
	// Domain is a link domain added in Settings, or "" (the default) for the app's own.
	Domain *string
}

// SlugPattern is what a slug may be.
var SlugPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$`)

const slugAlphabet = "abcdefghijkmnpqrstuvwxyz23456789"

// RandomSlug is six characters from an alphabet without look-alikes (no 0/o, 1/l).
func RandomSlug() string {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	out := make([]byte, 6)
	for i, c := range b {
		out[i] = slugAlphabet[int(c)%len(slugAlphabet)]
	}
	return string(out)
}

func cleanURL(value string) (string, error) {
	text := jsTrim(value)
	u, err := whatwg.Parse(text)
	if err != nil {
		return "", linkError("The destination must be a full URL, starting with https://", "link_url")
	}
	if u.Protocol != "https:" && u.Protocol != "http:" {
		return "", linkError("The destination must start with http:// or https://", "link_protocol")
	}
	if len16(text) > 2000 {
		return "", linkError("The destination is longer than 2,000 characters", "link_long")
	}
	return u.Href(), nil
}

func defaultName(url string) string {
	u := whatwg.MustParse(url)
	path := u.Pathname
	if path == "/" {
		path = ""
	}
	return head16(StripWww(u.Hostname)+path, 100)
}

// Links creates, changes, deletes, and imports short links, with the rules every route shares.
type Links struct{ r *Runlight }

func (l *Links) domainFor(ctx context.Context, site, value string) (string, error) {
	domain := StripWww(jsTrim(value))
	if domain == "" {
		return "", nil
	}
	known, err := l.r.Store.LinkDomains(ctx)
	if err != nil {
		return "", err
	}
	for _, d := range known {
		if d.Domain == domain && d.Site == site {
			return domain, nil
		}
	}
	return "", linkError("Add "+domain+" as a link domain in Settings first", "link_domain", "domain", domain)
}

// freeSlug: slugs are unique across every domain, so a link can always fall back to the app's own path.
func (l *Links) freeSlug(ctx context.Context, wanted *string, except string) (string, error) {
	if wanted != nil && *wanted != "" {
		if !SlugPattern.MatchString(*wanted) {
			return "", linkError("A slug is letters, digits, dashes, and underscores, up to 100", "link_slug")
		}
		taken, err := l.r.Store.LinkBySlug(ctx, *wanted)
		if err != nil {
			return "", err
		}
		if taken != nil && taken.ID != except {
			return "", linkError("/"+*wanted+" is already taken", "link_taken", "slug", *wanted)
		}
		return *wanted, nil
	}
	for i := 0; i < 8; i++ {
		slug := RandomSlug()
		found, err := l.r.Store.LinkBySlug(ctx, slug)
		if err != nil {
			return "", err
		}
		if found == nil {
			return slug, nil
		}
	}
	return "", linkError("Could not find a free slug; try again", "link_no_slug")
}

func trimmed(s *string) *string {
	if s == nil {
		return nil
	}
	return ptr(jsTrim(*s))
}

// Create makes a link.
func (l *Links) Create(ctx context.Context, site string, input LinkInput) (LinkRow, error) {
	if err := l.r.Init(ctx); err != nil {
		return LinkRow{}, err
	}
	url, err := cleanURL(input.URL)
	if err != nil {
		return LinkRow{}, err
	}
	domain := ""
	if input.Domain != nil {
		if domain, err = l.domainFor(ctx, site, *input.Domain); err != nil {
			return LinkRow{}, err
		}
	}
	slug, err := l.freeSlug(ctx, trimmed(input.Slug), "")
	if err != nil {
		return LinkRow{}, err
	}
	now := l.r.now()
	name := ""
	if input.Name != nil {
		name = jsTrim(*input.Name)
	}
	if name == "" {
		name = defaultName(url)
	}
	link := LinkRow{ID: randomID(12), Site: site, Domain: domain, Slug: slug, Name: head16(name, 100), URL: url, CreatedAt: now, UpdatedAt: now}
	return link, l.r.Store.InsertLink(ctx, link)
}

// Update changes a link; a nil field of input is left as it is.
func (l *Links) Update(ctx context.Context, id string, url, name, slug, domain *string) (LinkRow, error) {
	if err := l.r.Init(ctx); err != nil {
		return LinkRow{}, err
	}
	link, err := l.r.Store.LinkByID(ctx, id)
	if err != nil {
		return LinkRow{}, err
	}
	if link == nil {
		return LinkRow{}, rangeError("Unknown link")
	}
	next := *link
	if url != nil {
		if next.URL, err = cleanURL(*url); err != nil {
			return LinkRow{}, err
		}
	}
	if name != nil {
		next.Name = head16(jsTrim(*name), 100)
		if next.Name == "" {
			next.Name = defaultName(next.URL)
		}
	}
	// Keeping a link's domain needs no check, even while that domain is removed.
	if domain != nil && StripWww(jsTrim(*domain)) != link.Domain {
		if next.Domain, err = l.domainFor(ctx, link.Site, *domain); err != nil {
			return LinkRow{}, err
		}
	}
	if slug != nil {
		if next.Slug, err = l.freeSlug(ctx, ptr(jsTrim(*slug)), link.ID); err != nil {
			return LinkRow{}, err
		}
	}
	next.UpdatedAt = l.r.now()
	return next, l.r.Store.UpdateLink(ctx, next)
}

// Remove deletes a link.
func (l *Links) Remove(ctx context.Context, id string) error {
	if err := l.r.Init(ctx); err != nil {
		return err
	}
	link, err := l.r.Store.LinkByID(ctx, id)
	if err != nil {
		return err
	}
	if link == nil {
		return rangeError("Unknown link")
	}
	return l.r.Store.DeleteLink(ctx, id, l.r.now())
}

// LinkImportFailure is one row an import could not make.
type LinkImportFailure struct {
	Row    int        `json:"row"`
	Reason string     `json:"reason"`
	Code   string     `json:"code"`
	Params *js.Object `json:"params"`
}

// LinkImport is how an import went.
type LinkImport struct {
	Created int                 `json:"created"`
	Failed  []LinkImportFailure `json:"failed"`
}

// Import creates many links at once, as from a CSV. Rows that fail are
// reported with their reason and the rest go in. Headers match the Umami
// fork's export: name or link_name, url or destination_url, slug or
// link_slug, domain or tracking_domain.
func (l *Links) Import(ctx context.Context, site string, rows []*js.Object) (LinkImport, error) {
	out := LinkImport{Failed: []LinkImportFailure{}}
	for i, raw := range rows {
		pick := func(keys ...string) *string {
			for _, key := range keys {
				if v, ok := raw.Value(key).(string); ok && jsTrim(v) != "" {
					return ptr(jsTrim(v))
				}
			}
			return nil
		}
		url := ""
		if u := pick("url", "destination_url"); u != nil {
			url = *u
		}
		_, err := l.Create(ctx, site, LinkInput{URL: url, Name: pick("name", "link_name"), Slug: pick("slug", "link_slug"), Domain: pick("domain", "tracking_domain")})
		if err != nil {
			// A bad row is reported and skipped; a failing database stops the whole import.
			var le *LinkError
			if !errors.As(err, &le) {
				return LinkImport{}, err
			}
			out.Failed = append(out.Failed, LinkImportFailure{Row: i + 1, Reason: le.Message, Code: le.Code, Params: le.Params})
			continue
		}
		out.Created++
	}
	return out, nil
}
