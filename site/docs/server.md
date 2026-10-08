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

In Docker, the log is where to look.

```bash
docker logs runlight
```

The link starts with `http://localhost:3000`. When the server runs somewhere else, keep everything from `/setup` on and put the server's own address in front, such as `https://stats.example.com/setup?code=...`. Each start makes a new code, so after a restart use the link from the newest log lines.

Owners add people in **Settings**, **People**, as an owner or a viewer. An owner can change everything, and a viewer can read every site's stats without changing anything. A new person gets a password shown once, which they can change under **Account** at the bottom of the dashboard. The server always keeps at least one owner.

### Forgotten passwords

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
<script defer src="https://stats.example.com/s.js?site=example.com" data-site="example.com"></script>
```

Add more sites from the menu beside the site's name. In **Settings**, **General**, you can change a site's domains, name, and timezone, or delete the site along with everything recorded for it.

## Connect sites that count themselves

A site with Runlight inside its own app can join this server too, so every site is in one dashboard. Choose **Add a site**, **Connect another Runlight**, and enter the app's Runlight address, such as `https://example.com/runlight`. Your browser opens that app's Runlight, where you sign in if you need to, pick the site, and choose **Allow**. You land back here with the site added.

The site's numbers stay in the app's own database. This server reads them through the app's API each time you look, so they are always current. Its goals, funnels, short links, link domains, email reports, share links, and how long it keeps visits can all be changed from here, and each change is saved in the app. People, tokens, imports, and the app's mail service stay with the app. **All sites** in the site menu lines every site up side by side for the dates you pick.

The app keeps the permission as a token in its **Settings**, **API and AI**, limited to the one site. Deleting it there disconnects this server at once. A site connected with a read-only token before this existed shows **Allow changes** in its settings, which runs the same steps.

If the app runs a Runlight older than this, connect it with a token instead. Make one in the app's **Settings**, **API and AI**, then choose **Use an API token instead** when you connect. A read token shows the site's numbers here, and its settings stay on the app.

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
| `RUNLIGHT_OBSERVE_KEY` | One key a [WordPress](/docs/wordpress/), [Drupal](/docs/drupal/), or [Craft](/docs/craft/) site can use to report AI agents, for any site. Each site also has its own key in **Settings**, **Install**, limited to that site, which is the better choice. |
| `TRUST_PROXY` | Set to `false` when no proxy sits in front of the server. |
| `RUNLIGHT_GEO` | Where locations come from when no header gives them. It is `city` by default, and can be `country`, `off`, or a path to an MMDB file. |

## Email reports and the scheduled check

The server runs Runlight's [scheduled check](/docs/cron/) itself every five minutes, so it needs no cron. Set up a mail service in **Settings**, **Email reports**, and reports go out on their own.

## Backups and upgrades

Back up the data folder. It holds the SQLite file and the `secret` file, and without the secret the saved mail keys cannot be read and everyone has to sign in again. To upgrade, pull the new image or run `npx runlight.sh@latest`, and the database updates itself on start.

## Running more than one copy

Several copies of the server can share one Postgres database, for example behind a load balancer. Each copy rereads the list of sites and connected installs every five minutes, so one added on any copy appears on the others within five minutes. Everything else, from visits to goals and links, is shared at once.

## What comes next

A log reader that counts AI agents on sites with only the script tag is planned. It would read your web server's access log and report the agents it finds.
