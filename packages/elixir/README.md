# Runlight for Elixir

Runlight is privacy friendly web analytics that runs inside your own Elixir app. It counts visitors without cookies and without storing anyone's IP address. The numbers stay in your database, and the dashboard is served from your domain at `/runlight`.

This package is the Elixir version of [Runlight](https://runlight.sh). It works in Phoenix or any Plug app on Elixir 1.18 or later and Erlang/OTP 27 or later, and keeps its tables in your own Ecto repo on SQLite, Postgres, MySQL, or MariaDB. It answers every request the way the TypeScript library does and uses the same tables, so either one can read the other's database.

## Get started

Add the package to `mix.exs`.

```elixir
def deps do
  [
    {:runlight, ">= 0.0.0"}
  ]
end
```

Start an instance in your application's supervision tree, after your repo.

```elixir
children = [
  MyApp.Repo,
  {Runlight,
   store: {Runlight.Store, repo: MyApp.Repo},
   site: [name: "example.com", hostnames: ["example.com"], timezone: "Europe/London"],
   check_every: :timer.hours(1)}
]
```

Forward `/runlight` and `/go` to it in your router, outside the `:browser` pipeline.

```elixir
scope "/" do
  forward "/runlight", Runlight.Plug
  forward "/go", Runlight.Plug.Links
end
```

Add the script to every page, just before `</head>`.

```html
<script defer src="/runlight/s.js"></script>
```

Set `RUNLIGHT_TOKEN` to a long random string, then open `/runlight/?token=` followed by that string to sign in.

The [Elixir guide](https://runlight.sh/docs/elixir/) has the stores, `Plug.Router`, link domains, the observer for AI agents, and several instances in one app.

## License

Runlight is MIT licensed.
