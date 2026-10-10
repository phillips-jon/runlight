---
title: PHP
description: Runlight runs in PHP 8.2 or later, inside a Laravel, Symfony, or plain PHP app, or on a domain of its own on ordinary PHP hosting.
group: Platforms
order: 14
---

The PHP package is Runlight written again in PHP. It serves the same dashboard and API, and it gives every request the answer the TypeScript library gives. Its numbers go in the same tables, so either one can read a database the other wrote. It needs PHP 8.2 or later with PDO and the driver for your database.

## Install

Add the package with Composer.

```bash
composer require runlight/runlight
```

Runlight uses the curl, intl, sodium, and APCu extensions when they are loaded, and falls back to plain PHP for any that are missing.

## Create the instance

Make one file that returns the instance, and require it wherever you need Runlight.

```php file=runlight.php
<?php

use Runlight\Runlight;
use Runlight\Store\Stores;

return new Runlight([
    'store' => Stores::sqlite(__DIR__ . '/data/runlight.db'),
    'site' => ['name' => 'example.com', 'hostnames' => ['example.com'], 'timezone' => 'Europe/London'],
]);
```

The options have the same names as in [Configuration](/docs/configuration/#runlight-options), so `sites`, `trustProxy`, `rateLimit`, `mail`, and `managedSites` all work as they do there. The tables are created on the first request.

## Stores

### SQLite

```php
Stores::sqlite(__DIR__ . '/data/runlight.db');
```

SQLite needs the `pdo_sqlite` extension, which most PHP installs have. Keep the file outside your web root, in a folder the web server can write to, since SQLite writes a journal beside it. The folder is made when it is missing.

### MySQL and MariaDB

```php
Stores::mysql('mysql://runlight:password@127.0.0.1:3306/runlight');
```

This store needs `pdo_mysql` and works with MySQL 8.4 or later and MariaDB 11.4 or later. A `mariadb://` URL works too. A second argument such as `['statementTimeout' => 30000]` stops any one query after that many milliseconds, and the default is 120000, as in [Configuration](/docs/configuration/#mysql-and-mariadb).

### Postgres

```php
Stores::postgres('postgres://runlight:password@127.0.0.1:5432/runlight');
```

This store needs `pdo_pgsql`. It takes `statementTimeout` in its second argument too, and `['schema' => 'analytics']` keeps the tables in a schema of their own. `Stores::url()` picks the store from a `DATABASE_URL` that starts with `postgres://`, `mysql://`, `mariadb://`, or `sqlite:`.

## Plain PHP

In an app with one `index.php` that every request goes through, send paths under `/runlight` and `/go` to Runlight at the top.

```php file=public/index.php
<?php

require __DIR__ . '/../vendor/autoload.php';

use Runlight\Http\Request;
use Runlight\Server\FrontController;

$rl = require __DIR__ . '/../runlight.php';

$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
if ($path === '/runlight' || str_starts_with($path, '/runlight/') || str_starts_with($path, '/go/')) {
    FrontController::serve($rl, $rl->routes());
    return;
}

// AI agents reading your pages; optional.
$rl->observe(Request::fromGlobals());

// The rest of your app.
```

`FrontController::serve()` reads the request from PHP’s globals and sends the answer. `observe()` records the fetches of [AI agents](/docs/ai/#agents-that-read-your-pages) and returns at once for everyone else. Add the script to every page, just before `</head>`.

```html
<script defer src="/runlight/s.js"></script>
```

Then set `RUNLIGHT_TOKEN` to a long random string and open `/runlight/?token=` followed by that string once to sign in, as [Getting started](/docs/#5-sign-in) describes. With `routes(['accounts' => true])` and a `RUNLIGHT_SECRET`, people sign in with their own email and password, as in [Accounts](/docs/configuration/#accounts).

A [link domain](/docs/links/#custom-domains) answers short links at the root of a name of its own, so its requests never match the paths above. To serve one from the app, ask `linkDomainResponse()` first. It answers only on your link domains and returns `null` for every other host, so the rest of the app carries on as before.

```php
$request = Request::fromGlobals();
$linked = $rl->linkDomainResponse($request, ['ip' => $request->remoteAddress]);
if ($linked !== null) {
    $linked->emit();
    return;
}
```

The Laravel and Symfony routes below answer only `/runlight` and `/go` too, so a link domain there needs the same check in a middleware or an event listener that runs first.

## Laravel

Runlight’s routes go outside Laravel’s `web` middleware group. That group asks every POST for a CSRF token, which the tracker cannot send, and it encrypts cookies, which Runlight could then not read back. Runlight checks requests its own way.

Register the instance in `AppServiceProvider`.

```php file=app/Providers/AppServiceProvider.php
use Runlight\Runlight;
use Runlight\Store\Stores;

public function register(): void
{
    $this->app->singleton(Runlight::class, fn () => new Runlight([
        'store' => Stores::sqlite(storage_path('app/runlight.db')),
        'site' => ['name' => 'example.com', 'hostnames' => ['example.com'], 'timezone' => 'Europe/London'],
    ]));
}
```

Add a controller.

```php file=app/Http/Controllers/RunlightController.php
<?php

namespace App\Http\Controllers;

use Illuminate\Http\Request;
use Runlight\Bridge\HttpFoundation;
use Runlight\Runlight;
use Symfony\Component\HttpFoundation\Response;

class RunlightController
{
    public function __invoke(Request $request, Runlight $rl): Response
    {
        $routes = $rl->routes(['token' => (string) config('services.runlight.token')]);

        return HttpFoundation::handle($rl, $routes, $request);
    }
}
```

Give it a routes file of its own.

```php file=routes/runlight.php
<?php

use App\Http\Controllers\RunlightController;
use Illuminate\Support\Facades\Route;

Route::any('/runlight/{path?}', RunlightController::class)->where('path', '.*');
Route::get('/go/{slug}', RunlightController::class);
```

Load that file in `bootstrap/app.php` with `then`, which registers routes outside the `web` group.

```php file=bootstrap/app.php
use Illuminate\Support\Facades\Route;

->withRouting(
    web: __DIR__.'/../routes/web.php',
    commands: __DIR__.'/../routes/console.php',
    health: '/up',
    then: fn () => Route::group([], base_path('routes/runlight.php')),
)
```

Read the token through the config, so it still works after `php artisan config:cache`, and set `RUNLIGHT_TOKEN` in `.env`.

```php file=config/services.php
'runlight' => [
    'token' => env('RUNLIGHT_TOKEN'),
],
```

The `(string)` in the controller turns a missing token into an empty one, which keeps the dashboard closed. Passing `null` would leave it open to everyone. Run the [scheduled check](/docs/cron/) from Laravel’s scheduler.

```php file=routes/console.php
use Illuminate\Support\Facades\Schedule;
use Runlight\Runlight;

Schedule::call(fn () => app(Runlight::class)->check())->hourly();
```

## Symfony

One controller serves everything under `/runlight` and the short links at `/go`.

```php file=src/Controller/RunlightController.php
<?php

namespace App\Controller;

use Runlight\Bridge\HttpFoundation;
use Runlight\Runlight;
use Runlight\Store\Stores;
use Symfony\Component\DependencyInjection\Attribute\Autowire;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;

final class RunlightController
{
    public function __construct(
        #[Autowire('%kernel.project_dir%/var/runlight.db')] private readonly string $database,
        #[Autowire('%env(RUNLIGHT_TOKEN)%')] private readonly string $token,
    ) {
    }

    #[Route('/runlight/{path}', name: 'runlight', requirements: ['path' => '.*'], defaults: ['path' => ''])]
    #[Route('/go/{slug}', name: 'runlight_link', methods: ['GET'])]
    public function __invoke(Request $request): Response
    {
        $rl = new Runlight([
            'store' => Stores::sqlite($this->database),
            'site' => ['name' => 'example.com', 'hostnames' => ['example.com'], 'timezone' => 'Europe/London'],
        ]);

        return HttpFoundation::handle($rl, $rl->routes(['token' => $this->token]), $request);
    }
}
```

Set `RUNLIGHT_TOKEN` in `.env.local`. Symfony stops with an error when it is missing, so the dashboard is never left open by accident. For the [scheduled check](/docs/cron/), call `$rl->check()` from a console command that cron runs, or set `CRON_SECRET` and call the check over HTTP.

`Runlight\Bridge\HttpFoundation` turns a Symfony or Laravel request into Runlight’s and its answer back again. It needs `symfony/http-foundation`, which both frameworks already have.

## Other PHP apps

Any PHP app can hand Runlight a request and send back its answer. Build a `Runlight\Http\Request` from the URL, method, headers, body, and the connection’s address, then pass it to `FrontController::answer()`.

```php
use Runlight\Http\Request;
use Runlight\Server\FrontController;

$request = new Request($url, $method, $headers, $body, $_SERVER['REMOTE_ADDR'] ?? '');
$answer = FrontController::answer($rl, $rl->routes(), $request);
// $answer->status, $answer->headers->all(), and $answer->text() are what to send.
```

Pass the address the connection came from. Runlight reads forwarded headers itself when `trustProxy` allows.

A site on WordPress, Drupal, or Craft needs none of this code. Its plugin connects it to a Runlight you run elsewhere, such as the drop-in below, as the [WordPress](/docs/wordpress/), [Drupal](/docs/drupal/), and [Craft](/docs/craft/) pages show.

## The standalone drop-in

The drop-in is the PHP counterpart of the [standalone server](/docs/server/). It runs Runlight on a domain of its own, such as `stats.example.com`, with the dashboard at the root, sites added in the dashboard, sign-in accounts, and short links on any domain you point at it. It suits hosting that runs PHP without Node.

### Set it up

Make a project folder beside your web root, install the package there, and copy the drop-in into the folder the domain serves.

```bash
mkdir stats && cd stats
composer require runlight/runlight
cp -r vendor/runlight/runlight/standalone public
```

Point the domain at `public`. On Apache and LiteSpeed, the `.htaccess` file that came with it sends every request to `index.php`. On nginx, add a server block like this one.

```nginx file=nginx.conf
server {
    server_name stats.example.com;
    root /var/www/stats/public;
    index index.php;

    location / {
        try_files $uri /index.php$is_args$args;
    }

    location = /index.php {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root/index.php;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
```

The data lives in `runlight-data` in the project folder, outside the web root, and is made on the first request. It holds the SQLite file and the secret that signs sign-ins, with the location data in a folder of its own. The web server’s user needs to be able to write to the project folder, or to a `runlight-data` folder you make for it.

### Make your account

The first request writes a setup link with a one-time code to `setup.txt` in the data folder. Open that link and enter your email address and a password of at least ten characters, typed twice. Without `RUNLIGHT_URL`, the link starts with a stand-in address, so put your own in front of `/setup`. The link works only while there is no account, and the cron command deletes the file once there is one. To print the link again, run this in the project folder.

```bash
vendor/bin/runlight setup
```

With `RUNLIGHT_TOKEN` set, the setup page asks for the token instead, and no file is written. You can also make the first account from the command line with `vendor/bin/runlight password you@example.com`, which prints its password. Roles, invites, two-factor sign-in, and adding sites work as they do on the [standalone server](/docs/server/#make-your-account).

### Settings

Settings come from environment variables, or from a `config.php` in the project folder that returns the same names. Environment variables win when both are set. Copy the example to start one.

```bash
cp vendor/runlight/runlight/config.example.php config.php
```

```php file=config.php
<?php

return [
    'RUNLIGHT_URL' => 'https://stats.example.com',
    'DATABASE_URL' => 'mysql://runlight:password@localhost:3306/runlight',
];
```

| Setting | What it does |
| --- | --- |
| `RUNLIGHT_URL` | The dashboard’s public address, such as `https://stats.example.com`. It can never become a link domain, and invite and report emails link to it. |
| `DATABASE_URL` | A `postgres://`, `mysql://`, or `mariadb://` address keeps the data in that database instead of SQLite. |
| `DATA_DIR` | The data folder, `runlight-data` in the project folder by default. A relative path is read from the project folder. |
| `RUNLIGHT_SECRET` | The key that signs sign-ins and encrypts saved keys. Without it, the drop-in makes one and keeps it in the data folder. |
| `RUNLIGHT_TOKEN` | A bearer token for scripts, which also makes the first account in place of the setup link. |
| `TRUST_PROXY` | Set to `false` when nothing sits in front of the web server, or to `x-real-ip` or `cf-connecting-ip` when that header holds the visitor’s address. |
| `RUNLIGHT_GEO` | Where locations come from, as on the [standalone server](/docs/server/#locations). It is `city` by default, and can be `country`, `off`, or the path to an MMDB file. |
| `CRON_SECRET` | Lets a scheduler run the check at `POST /api/check` when it cannot run the cron command. |
| `RUNLIGHT_OBSERVE_KEY` | One key for every site’s AI agent reports. Each site’s own key from **Settings**, **Install** is the better choice. |
| `RUNLIGHT_CONFIG` | The path of a config file somewhere other than the project folder. |

`TRUST_PROXY` matters on PHP hosting, where Apache or nginx often answers visitors with no proxy in front. Runlight reads each visitor’s address from the last `X-Forwarded-For` entry by default, and with nothing in front to add that entry, a visitor can write it. Set `TRUST_PROXY=false` on such a server.

### Cron

Add one line to the crontab of the user the site runs as. Every five minutes it runs the [scheduled check](/docs/cron/), and once a month it downloads the new location data.

```bash
*/5 * * * * cd /var/www/stats && vendor/bin/runlight cron
```

The command prints nothing when all is well, apart from one line when a new month’s location data is ready. If a run is still going when the next one starts, the second one leaves the work to it. When the host has no cron, set `CRON_SECRET` and have any scheduler call `/api/check` with it, as [Scheduled check](/docs/cron/#anywhere-else) shows, though locations then need `RUNLIGHT_GEO` set to a file of your own.

### Forgotten passwords

Run the `password` command in the project folder to give an account a new password, which it prints. It also turns off two-factor sign-in for that account, and it makes the account when there is none.

```bash
vendor/bin/runlight password someone@example.com
```

### Upgrades and backups

Run `composer update runlight/runlight` in the project folder. The tables update themselves on the next request, or run `vendor/bin/runlight migrate` to update them at once. Back up the data folder and `config.php`, since saved keys cannot be read without the secret.

### AI agents from a log

AI agents such as GPTBot and ClaudeBot fetch pages without running JavaScript, so the script tag never sees them. A PHP app with Runlight inside counts them where the page is served, with `observe()` as [Plain PHP](#plain-php) shows. For any other site you host yourself, the web server’s access log has them, and the `agents` command reads it.

```bash
vendor/bin/runlight agents --log /var/log/nginx/access.log --to https://stats.example.com --key rlo_... --site https://example.com --follow
```

The key is the site’s own, from **Settings**, **Install**, **Key for CMS plugins**, and it can only report fetches for that site. When `--to` or `--key` is left out, the command reads `RUNLIGHT_URL` or `RUNLIGHT_OBSERVE_KEY` from the environment or `config.php`, as the other commands read their settings. `--site` is the site’s address, for logs in nginx or Apache’s usual format, which leave the host out. Caddy’s JSON logs carry the host, so it is not needed there. The user that runs the command needs to be able to read the log.

With `--follow` the command keeps running, sends fetches as they happen, and carries on when the log is rotated, finishing the old file before it moves to the new one. A systemd service or a process manager keeps it going. Add `--state agents.json` so a restart picks up where it stopped. Without `--follow` it reads the log once and stops, and with `--state` the next run starts where the last one finished, which suits cron.

```bash
*/5 * * * * cd /var/www/stats && vendor/bin/runlight agents --log /var/log/nginx/access.log --to https://stats.example.com --key rlo_... --site https://example.com --state agents.json
```

Only one run at a time can use a state file. It holds a lock beside the file (`agents.json.lock`), so a second run, such as a cron job that starts while the last one is still sending, stops with a message and sends nothing twice. A lock left by a run that crashed is taken over.

Only successful page fetches from known AI agents leave the machine, each with the page’s address, the agent’s user agent, and when it was served. Visitors’ addresses and everything else in the log stay where they are. Runlight counts only page fetches from the last week, so the first run over a long log skips the old ones.

### What the Node server does that the drop-in does not

PHP keeps nothing running between requests, so a few things work differently from `npx runlight.sh`.

- The scheduled check and the monthly DB-IP download run from cron. Until the first `runlight cron`, visits get a location only from headers such as Cloudflare’s.
- The setup link is written to a file once and kept until there is an account.
- There is no Docker image, and nothing listens on a port of its own. The web server runs the drop-in.

Several web servers can share one database, as copies of the Node server can. Each request reads the list of sites afresh, so a site added on one shows on the others at once.

## How it differs from the TypeScript library

The PHP package passes the conformance tests the TypeScript library is held to, on SQLite, Postgres, MySQL, and MariaDB. The differences come from how PHP runs.

- There is no connection pool. Each request opens its own database connection and closes it when it ends, so a busy site holds one connection for each PHP worker.
- What the TypeScript library does in the background, such as deleting visits after a shorter retention is chosen, runs after the answer is sent. PHP-FPM and LiteSpeed close the connection first, and other servers keep it open until the work is done. The scheduled check runs from cron or a framework’s scheduler, since nothing in PHP runs on a timer.
- Passwords are hashed with scrypt in plain PHP, which takes about 0.7 seconds a sign-in without OPcache’s JIT compiler and about 0.2 seconds with it. The hashes match the TypeScript library’s, so accounts carry over.
- The TypeScript library keeps some counts in memory, which PHP forgets between requests. Wrong-password limits are kept in the database, so every worker shares them. The tracker’s rate limit lives in APCu when it is loaded, and in small files in the system’s temporary folder otherwise.
- Runlight reads `RUNLIGHT_TOKEN` and the other variables from `getenv()`, then `$_ENV`, then `$_SERVER`, since hosts set them in different places.
