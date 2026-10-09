# Changelog

Every notable change to Runlight is listed here, newest first. The library, the standalone server, the PHP package, and the WordPress plugin share one version, so each release is one section here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the versions follow [Semantic Versioning](https://semver.org). The WordPress plugin keeps its changelog in its readme, and the Craft plugin keeps one of its own for the Craft Plugin Store.

## Unreleased

This is Runlight's first release.

### Added

- `@runlight/sdk` is privacy friendly web analytics that runs inside an app you already have. It counts visitors without cookies and without storing anyone's IP address, keeps the numbers in your own SQLite, Postgres, MySQL, MariaDB, Turso, or Cloudflare D1 database, and serves its dashboard at `/runlight` on your own domain. It runs on Node 22 or later, Bun, Deno, and Cloudflare Workers.
- `runlight.sh` is the same code as a server of its own, with one dashboard for any number of sites and sign-in for the people you invite. It starts with `npx runlight.sh`, and the Docker image is `ghcr.io/phillips-jon/runlight`.
- `runlight/runlight` is the PHP version of the library, for Laravel, Symfony, or plain PHP on PHP 8.2 or later. It uses the same tables as the TypeScript library, so either one can read the other's database.
- Runlight counts goals and the revenue they bring, funnels, and the paths visits take through a site. It makes short links on your own domains and counts their clicks.
- Runlight emails weekly or monthly reports and shares a read-only dashboard by link.
- An assistant in the dashboard, and an MCP server for AI apps, answer questions about your numbers.
- `runlight` on PyPI is the Python version, for Django, Flask, FastAPI, or any WSGI or ASGI app on Python 3.11 or later, with a standalone server of its own. It answers exactly as the TypeScript library does and shares its tables.
- The `runlight` gem is the Ruby version, a Rails engine with an install generator for Rails 7.2, 8.0, and 8.1, or a Rack app or middleware anywhere else, on Ruby 3.2 or later. It also answers exactly as the TypeScript library does and shares its tables.
- The `runlight.sh/go` module is the Go version, for net/http, chi, Echo, or any router that takes an `http.Handler` on Go 1.25 or later, with a standalone server and a `runlight` command of its own. It answers exactly as the TypeScript library does and shares its tables.
- `runlight` on Hex is the Elixir version, for Phoenix or any Plug app on Elixir 1.18 or later and Erlang/OTP 27 or later, with its tables in your own Ecto repo. It answers exactly as the TypeScript library does and reads and writes the same tables.
- `sh.runlight:runlight` on Maven Central is the Java version, for the JDK's own HTTP server, Tomcat, Jetty, or any Jakarta Servlet 6 container, or Spring Boot 3.5 or 4, on Java 21 or later, with a standalone server of its own. It answers exactly as the TypeScript library does and shares its tables.
- `Runlight` on NuGet is the .NET version, for ASP.NET Core or any other .NET app on .NET 10 or later, with a standalone server that installs as the `runlight` tool. It answers exactly as the TypeScript library does and shares its tables.
- The `runlight` crate is the Rust version, for axum, hyper, or any tokio server that takes a tower service, on Rust 1.88 or later, with its tables in your own database through `runlight-sqlx`. It answers exactly as the TypeScript library does and shares its tables.
- Plugins for WordPress, Drupal, and Craft CMS add the script to a site and report the AI agents that read its pages to a Runlight you run elsewhere.
