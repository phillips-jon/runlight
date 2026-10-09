package importers

import (
	"context"

	"runlight.sh/go/internal/js"
	"runlight.sh/go/internal/web"
)

// https://developers.rebrandly.com/docs
const (
	rebrandlyBase = "https://api.rebrandly.com/v1"
	rebrandlyPage = 25
)

type rebrandly struct{}

// Rebrandly is Rebrandly. Its API gives only total clicks, with no dates, so
// links come across with their slugs and domains and start their history fresh.
var Rebrandly Importer = rebrandly{}

func (rebrandly) Step(ctx context.Context, client *Client, in StepInput) (*StepResult, error) {
	key := trimmed(in.Credentials, "apiKey")
	if key == "" {
		return nil, NewImportError("Enter a Rebrandly API key", "import_key", "service", "Rebrandly")
	}
	headers := web.NewHeaders("apikey", key)
	if workspace := trimmed(in.Credentials, "workspace"); workspace != "" {
		headers.Set("workspace", workspace)
	}
	last := ""
	if in.Cursor != nil && *in.Cursor != "" {
		last = "&last=" + encodeURIComponent(*in.Cursor)
	}
	body, err := client.GetJSON(ctx, rebrandlyBase+"/links?orderBy=createdAt&orderDir=desc&limit=25"+last, RequestInit{Headers: headers})
	if err != nil {
		return nil, err
	}
	all, err := list(body, "list")
	if err != nil {
		return nil, err
	}
	links := make([]ForeignItem, len(all))
	for i, l := range all {
		links[i] = ForeignItem{Link: ForeignLink{
			SourceID:  js.String(field(l, "id")),
			Slug:      text(field(l, "slashtag")),
			Domain:    text(coalesce(field(field(l, "domain"), "fullName"), "")),
			Name:      text(or(field(l, "title"), "")),
			URL:       text(field(l, "destination")),
			CreatedAt: createdAt(field(l, "createdAt"), in.Now),
		}}
	}
	result := &StepResult{Links: links}
	if len(all) == rebrandlyPage && js.Truthy(all[len(all)-1]) {
		result.Cursor = strPtr(js.String(field(all[len(all)-1], "id")))
	}
	return result, nil
}
