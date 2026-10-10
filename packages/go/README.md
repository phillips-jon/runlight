# runlight.sh/go

Runlight is privacy friendly web analytics that runs inside your own Go app. It counts visitors without cookies and without storing anyone’s IP address. The numbers stay in your database, and the dashboard is served from your domain at `/runlight`.

This module is the Go version of [Runlight](https://runlight.sh). It works with net/http, chi, Echo, or any router that takes an `http.Handler` on Go 1.25 or later, and it can also run on its own domain as a standalone server. It answers every request the way the TypeScript library does and uses the same tables, so either one can read the other’s database. The module itself requires no other module.

## Get started

Add it with `go get`, along with a SQLite driver.

```bash
go get runlight.sh/go modernc.org/sqlite
```

Create one instance for your app.

```go
db, err := sql.Open("sqlite", "data/runlight.db")
if err != nil {
	log.Fatal(err)
}
rl, err := runlight.New(runlight.Options{
	Store: runlight.NewStore(runlight.SQLite(db).Owned(0)),
	Site:  &runlight.SiteOptions{Name: "example.com", Hostnames: []string{"example.com"}, Timezone: "Europe/London"},
})
if err != nil {
	log.Fatal(err)
}
```

Mount its routes and short links beside your app.

```go
routes, err := rl.Routes(runlight.RoutesOptions{})
if err != nil {
	log.Fatal(err)
}
mux.Handle("/runlight", routes)
mux.Handle("/runlight/", routes)
mux.Handle("GET /go/{slug}", rl.LinksHTTP())
```

Add the script to every page, just before `</head>`.

```html
<script defer src="/runlight/s.js"></script>
```

Set `RUNLIGHT_TOKEN` to a long random string, then open `/runlight/?token=` followed by that string to sign in.

The [Go guide](https://runlight.sh/docs/go/) has the chi and Echo adapters, the Postgres, MySQL, and MariaDB stores, the scheduled check, and the `runlight` command that runs Runlight on a domain of its own with sign-in accounts.

## Modules

The core module is `runlight.sh/go`, with the standalone server in `runlight.sh/go/server`. The chi adapter (`runlight.sh/go/chi`), the Echo adapter (`runlight.sh/go/echo`), and the command (`runlight.sh/go/cmd/runlight`) are modules of their own, so their requirements stay out of the core. `dbtest` holds the tests that need database drivers, the conformance tests among them. The workspace in `go.work` builds them all against the core in this folder; `go mod tidy` ignores it, so tidy the nested modules with `node scripts/go-tidy.mjs` from the repository root.

Run the tests from `packages/go`. The database tests use SQLite, and Postgres, MySQL, and MariaDB too when `RUNLIGHT_TEST_PG`, `RUNLIGHT_TEST_MYSQL`, and `RUNLIGHT_TEST_MARIADB` hold their URLs.

```bash
go test ./...
(cd dbtest && go test ./...)
```

## License

Runlight is MIT licensed.
