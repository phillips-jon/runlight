// Package assets holds the dashboard and tracker the TypeScript SDK builds,
// copied here byte for byte by scripts/go-assets.mts, so the Go port serves
// the very same files. Never edit the files beside this one.
package assets

import (
	"bytes"
	_ "embed"
	"encoding/json"
)

var (
	//go:embed dashboard.js
	DashboardJS string
	//go:embed dashboard.css
	DashboardCSS string
	//go:embed world.json
	WorldJSON string
	//go:embed tracker.js
	Tracker string
	//go:embed picker.js
	Picker string
	//go:embed locales.json
	localesJSON []byte
	//go:embed build.json
	buildJSON []byte
)

// Build is what build.json says about the copied files.
var Build struct {
	Version       string `json:"version"`
	APIVersion    int    `json:"apiVersion"`
	DashboardHash string `json:"dashboardHash"`
	WorldHash     string `json:"worldHash"`
	LocalesHash   string `json:"localesHash"`
	TrackerHash   string `json:"trackerHash"`
	Icon          string `json:"icon"`
}

// Locales is each language's dashboard strings, as the JSON text the SDK
// holds them in; "en" is English.
var Locales map[string]string

// LocaleOrder is the languages in the order the SDK lists them: English,
// then the others.
var LocaleOrder []string

func init() {
	if err := json.Unmarshal(buildJSON, &Build); err != nil {
		panic("assets: build.json: " + err.Error())
	}
	if err := json.Unmarshal(localesJSON, &Locales); err != nil {
		panic("assets: locales.json: " + err.Error())
	}
	// locales.json is written with English first and the rest in the SDK's own order.
	dec := json.NewDecoder(bytes.NewReader(localesJSON))
	_, _ = dec.Token()
	for dec.More() {
		key, _ := dec.Token()
		LocaleOrder = append(LocaleOrder, key.(string))
		var skip json.RawMessage
		_ = dec.Decode(&skip)
	}
}
