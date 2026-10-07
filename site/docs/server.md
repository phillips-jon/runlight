---
title: Standalone server
description: The standalone server runs Runlight as its own app for any number of sites, with a sign-in, short links on your own domains, and email reports.
group: Platforms
order: 13
---

The standalone server is Runlight packaged as an app of its own. It suits sites that are not Node apps, and it gives several sites one dashboard. It runs the same code as the library, so reports, goals, short links, and email reports all work the same way.

## Start it

With Docker, run this.

```bash
docker run -d --name runlight -p 3000:3000 -v runlight:/data ghcr.io/phillips-jon/runlight
```

With Node 22 or later, run this instead.

```bash
npx runlight.sh
```

The server listens on port 3000. It keeps its data in a folder called `runlight-data` in the directory you start it from, or in `/data` inside Docker.

## Make your account

On its first start the server prints a setup link with a one-time code in its log. Open that link and enter your email address and a password of at least ten characters. The link only works while the server has no account, so nobody who finds a new server first can claim it.

Owners add people in **Settings**, **People**, as an owner or a viewer. An owner can change everything, and a viewer can read every site's stats without changing anything. A new person gets a password shown once, which they can change under **Account** at the bottom of the dashboard. The server always keeps at least one owner.

If an owner is locked out, run the `password` command on the server to give the account a new password, which it prints. The same command makes a new owner account.

```bash
npx runlight.sh password someone@example.com
```

In Docker, run the same command inside the container.

```bash
docker exec runlight node node_modules/runlight.sh/dist/cli.js password someone@example.com
```

## Add your sites

After you sign in, the dashboard asks for your first site's domain. The next screen gives you the script tag for that site's pages, with the server's address and the site's id filled in.

```html
<script defer src="https://stats.example.com/s.js" data-site="example.com"></script>
```

Add more sites from the menu beside the site's name. In **Settings**, **General**, you can change a site's domains, name, and timezone, or delete the site along with everything recorded for it.

## Put it on the internet

The server speaks plain HTTP, so run it behind a proxy that adds HTTPS. With [Caddy](https://caddyserver.com), the whole setup for a server at `stats.example.com` is this.

```text file=Caddyfile
stats.example.com {
  reverse_proxy localhost:3000
}
```

Runlight reads each visitor's address from the proxy's `X-Forwarded-For` header. Set `TRUST_PROXY=false` when nothing sits in front of the server, so a visitor cannot send a false address.

## Short links on your own domains

Any domain pointed at the server can serve short links at its root, with nothing else to install. Point the domain at the server with a CNAME record, have your proxy accept it with HTTPS, and then add it in **Settings**, **Custom domains**. In Caddy that means listing the domain beside the server's own.

```text file=Caddyfile
stats.example.com, go.example.com {
  reverse_proxy localhost:3000
}
```

Every link also answers at `/go/your-slug` on the server's own domain.

## Locations

Behind Cloudflare, Runlight takes each visitor's country, region, and city from the headers Cloudflare adds. Without them, the server downloads the free [DB-IP](https://db-ip.com) city database into its data folder on the first start and fetches each month's new release. The file is about 130 MB and the server keeps it in memory. DB-IP's license asks for credit, so the dashboard's footer names it.

Set `RUNLIGHT_GEO=country` to use DB-IP's smaller country database, which is about 8 MB and has no regions or cities. Set it to `off` to look nothing up, or to the path of an MMDB file of your own, such as MaxMind's GeoLite2 City.

## Settings

The server reads its settings from environment variables.

| Variable | What it does |
| --- | --- |
| `PORT` | The port to listen on. The default is 3000. |
| `HOST` | The address to listen on. The default is `0.0.0.0`. |
| `DATA_DIR` | The folder for the SQLite file, the secret, and the location data. The default is `./runlight-data`, or `/data` in Docker. |
| `DATABASE_URL` | A `postgres://` address, to keep the data in Postgres instead of SQLite. |
| `RUNLIGHT_SECRET` | The key that signs sign-ins and encrypts saved mail keys. Without it, the server makes one and keeps it in `DATA_DIR`. |
| `RUNLIGHT_TOKEN` | A token that scripts can send as a bearer, in addition to the [API tokens](/docs/mcp/) made in the dashboard. |
| `TRUST_PROXY` | Set to `false` when no proxy sits in front of the server. |
| `RUNLIGHT_GEO` | Where locations come from when no header gives them. It is `city` by default, and can be `country`, `off`, or a path to an MMDB file. |

## Email reports and the scheduled check

The server runs Runlight's [scheduled check](/docs/cron/) itself every five minutes, so it needs no cron. Set up a mail service in **Settings**, **Email reports**, and reports go out on their own.

## Backups and upgrades

Back up the data folder. It holds the SQLite file and the `secret` file, and without the secret the saved mail keys cannot be read and everyone has to sign in again. To upgrade, pull the new image or run `npx runlight.sh@latest`, and the database updates itself on start.

## What comes next

One database should have one server process for now, because a site added in one process only appears in another after a restart. Two more pieces are planned. The first brings stats from library installs into this dashboard, and the second imports visit history from an Umami database.
