---
title: Python
description: Runlight runs in Python 3.11 or later, inside a Django, Flask, or FastAPI app or any WSGI or ASGI app, or as a server of its own.
group: Platforms
order: 17.1
---

The Python package is Runlight written again in Python. It serves the same dashboard and API, and it gives every request the answer the TypeScript library gives. Its numbers go in the same tables, so either one can read a database the other wrote. It needs Python 3.11 or later and has no dependencies of its own.

## Install

Add the package with pip.

```bash
pip install runlight
```

SQLite comes with Python. For Postgres, install the `postgres` extra, which adds psycopg 3, and for MySQL or MariaDB, install the `mysql` extra, which adds PyMySQL.

```bash
pip install "runlight[postgres]"
pip install "runlight[mysql]"
```

Time zones come from the system’s time zone database. Windows has none, so add the `tzdata` extra there.

## Create the instance

Make one module that creates the instance, and import it wherever you need Runlight.

```python file=myproject/analytics.py
from runlight import Runlight
from runlight.store import Stores

rl = Runlight(
    store=Stores.sqlite("data/runlight.db"),
    site={"name": "example.com", "hostnames": ["example.com"], "timezone": "Europe/London"},
)
```

The options have the same names as in [Configuration](/docs/configuration/#runlight-options). Pass them as keyword arguments in snake case, such as `trust_proxy=False` and `rate_limit=60`, or as one dict with the TypeScript names, such as `Runlight({"store": ..., "trustProxy": False})`. The tables are created on the first request.

## Stores

### SQLite

```python
Stores.sqlite("data/runlight.db")
```

Keep the file outside any folder your web server serves, in a folder the app can write to, since SQLite writes a journal beside it. The folder is made when it is missing.

### Postgres

```python
Stores.postgres("postgres://runlight:password@127.0.0.1:5432/runlight")
```

`statement_timeout` stops any one statement after that many milliseconds, and the default is 120000. `schema` keeps the tables in a schema of their own, as in `Stores.postgres(url, schema="analytics")`. In place of a URL you can pass a psycopg connection your app already has, which Runlight uses as it is and never closes.

### MySQL and MariaDB

```python
Stores.mysql("mysql://runlight:password@127.0.0.1:3306/runlight")
```

This store works with MySQL 8.4 or later and MariaDB 11.4 or later. A `mariadb://` URL works too. It takes `statement_timeout` as Postgres does, which MySQL applies to reads and MariaDB to every statement, as in [Configuration](/docs/configuration/#mysql-and-mariadb).

`Stores.url()` picks the store from a `DATABASE_URL` that starts with `postgres://`, `mysql://`, `mariadb://`, or `sqlite:`.

## Django

Add Runlight’s app and its middleware to your settings, and name the instance in `RUNLIGHT`. The middleware goes first, so no other middleware changes Runlight’s requests or its answers.

```python file=settings.py
INSTALLED_APPS = [
    # ...
    "runlight.django",
]

MIDDLEWARE = [
    "runlight.django.RunlightMiddleware",
    # ...
]

RUNLIGHT = "myproject.analytics.rl"
```

`RUNLIGHT` holds the instance itself or the dotted path to it, and a path to a function that makes one works too. `RUNLIGHT_ROUTES` passes options to the routes with their TypeScript names, such as `{"accounts": True}`. The middleware serves the dashboard and API under `/runlight`, short links at `/go`, and every link domain you add in **Settings**, before Django’s own URLs. Each link domain must also be in `ALLOWED_HOSTS`.

Run the [scheduled check](/docs/cron/) from cron with the management command.

```bash
*/5 * * * * cd /srv/myproject && python manage.py runlight_check
```

## Flask

Pass the app and the instance to `init_app`, which puts Runlight in front of the app’s own views. It answers under `/runlight`, at `/go`, and on every link domain you add in **Settings**, and passes everything else to your app.

```python file=app.py
from flask import Flask

import runlight.flask
from myproject.analytics import rl

app = Flask(__name__)
runlight.flask.init_app(app, rl)
```

Options for the routes go in as keyword arguments, such as `runlight.flask.init_app(app, rl, accounts=True)`. `init_app` also adds a command that runs the [scheduled check](/docs/cron/), for cron.

```bash
*/5 * * * * cd /srv/myproject && flask --app app runlight check
```

## FastAPI

`init_app` adds Runlight as middleware in front of the app’s routes, so it answers under `/runlight`, at `/go`, and on every link domain you add in **Settings**. It works for Starlette apps as well.

```python file=main.py
from fastapi import FastAPI

import runlight.fastapi
from myproject.analytics import rl

app = FastAPI()
runlight.fastapi.init_app(app, rl)
```

Runlight’s own work runs in worker threads, so it never holds up the event loop. For the [scheduled check](/docs/cron/), call `rl.check()` from a script that cron runs, or set `CRON_SECRET` and call the check over HTTP.

## Any WSGI or ASGI app

Bottle, Pyramid, and any other WSGI app take the WSGI middleware.

```python
from runlight.wsgi import RunlightMiddleware

application = RunlightMiddleware(application, rl)
```

Quart, Django under ASGI, and any other ASGI app take the ASGI middleware, which takes the instance as `runlight=`.

```python
from runlight.asgi import RunlightMiddleware

application = RunlightMiddleware(application, runlight=rl)
```

Both answer under `/runlight`, at `/go`, and on every link domain, and pass everything else to your app. Options for the routes go in as keyword arguments, as with Flask. To run Runlight as an app of its own, without one of yours behind it, use `runlight.wsgi.app(rl)` with a WSGI server such as gunicorn, or `runlight.asgi.app(rl)` with an ASGI server such as uvicorn. Paths outside Runlight’s then answer 404.

Whichever way you add it, put the script on every page, just before `</head>`.

```html
<script defer src="/runlight/s.js"></script>
```

Then set `RUNLIGHT_TOKEN` to a long random string and open `/runlight/?token=` followed by that string once to sign in, as [Getting started](/docs/#5-sign-in) describes. With `accounts=True` and a `RUNLIGHT_SECRET`, people sign in with their own email and password, as in [Accounts](/docs/configuration/#accounts).

## AI agents

The middleware records the fetches of [AI agents](/docs/ai/#agents-that-read-your-pages) as your app serves its pages, and lets every other request through untouched. Pass `observe=False` to `init_app` or to the middleware to turn that off, or set `"observe": False` in `RUNLIGHT_ROUTES` in Django. Without middleware, call `rl.observe(request)` with a `runlight.http.Request` for each page request.

## The scheduled check

The [scheduled check](/docs/cron/) rotates the daily salts, sends email reports that are due, applies how long each site keeps its visits, and builds the rollups that keep long ranges quick. Run it every few minutes with `python manage.py runlight_check` in Django, `flask runlight check` in Flask, or `rl.check()` from any script. When nothing can run a command on a timer, set `CRON_SECRET` and have a scheduler call `/runlight/api/check` with it, as [Scheduled check](/docs/cron/#anywhere-else) shows.

## The standalone server

The package includes the [standalone server](/docs/server/), which runs Runlight on a domain of its own, such as `stats.example.com`, with the dashboard at the root, sites added in the dashboard, sign-in accounts, and short links on any domain you point at it. Install the package and run the `runlight` command.

```bash
pip install runlight
runlight
```

The server listens on port 3000 and keeps its data in a folder called `runlight-data` in the directory you start it from. On its first start it prints a setup link with a one-time code. Open that link and make your account, as [Make your account](/docs/server/#make-your-account) describes. The server runs the scheduled check itself every five minutes, and it downloads the month’s location data as the Node server does. Put it behind a proxy that adds HTTPS, as in [Put it on the internet](/docs/server/#put-it-on-the-internet).

### Settings

The server reads its settings from environment variables.

| Variable | What it does |
| --- | --- |
| `PORT` | The port to listen on. The default is 3000. |
| `HOST` | The address to listen on. The default is `0.0.0.0`. |
| `DATA_DIR` | The folder for the SQLite file, the secret, and the location data. The default is `./runlight-data`. |
| `DATABASE_URL` | A `postgres://` address keeps the data in Postgres instead of SQLite, and a `mysql://` or `mariadb://` address keeps it in MySQL or MariaDB. |
| `RUNLIGHT_SECRET` | The key that signs sign-ins and encrypts saved keys. Without it, the server makes one and keeps it in `DATA_DIR`, readable only by the user that runs it. |
| `RUNLIGHT_URL` | The server’s public address, such as `https://stats.example.com`, which can never become a link domain. Invite and report emails link to it. |
| `RUNLIGHT_TOKEN` | A token that scripts can send as a bearer, in addition to the [API tokens](/docs/mcp/) made in the dashboard. |
| `RUNLIGHT_OBSERVE_KEY` | One key for every site’s AI agent reports. Each site’s own key from **Settings**, **Install** is the better choice. |
| `TRUST_PROXY` | Set to `false` when no proxy sits in front of the server, or to `x-real-ip` or `cf-connecting-ip` when that header holds the visitor’s address. |
| `RUNLIGHT_GEO` | Where locations come from when no header gives them, as in [Locations](/docs/server/#locations). It is `city` by default, and can be `country`, `off`, or a path to an MMDB file. |
| `CRON_SECRET` | Lets a scheduler run the check at `POST /api/check`. |

### Commands

`runlight check` runs the scheduled check once and fetches the month’s location data. `runlight migrate` creates or updates the tables at once. The tables also update themselves when the server starts, so an upgrade needs only `pip install --upgrade runlight` and a restart. Back up the data folder, since saved keys cannot be read without the secret in it.

### Forgotten passwords

Run the `password` command where the server runs to give an account a new password, which it prints. It also turns off two-factor sign-in for that account, and it makes the account when there is none, as the owner on a server with nobody yet and as an admin otherwise.

```bash
runlight password someone@example.com
```

### AI agents from a log

AI agents such as GPTBot and ClaudeBot fetch pages without running JavaScript, so the script tag never sees them. A Python app with Runlight inside counts them where the page is served, as [AI agents](#ai-agents) shows. For any other site you host yourself, the web server’s access log has them, and the `agents` command reads it.

```bash
runlight agents --log /var/log/nginx/access.log --to https://stats.example.com --key rlo_... --site https://example.com --follow
```

The key is the site’s own, from **Settings**, **Install**, **Key for CMS plugins**, and it can only report fetches for that site. When `--to` or `--key` is left out, the command reads `RUNLIGHT_URL` or `RUNLIGHT_OBSERVE_KEY` from the environment. The command works as it does on the [standalone server](/docs/server/#ai-agents-from-a-log), with `--follow` to keep running and `--state` to pick up where the last run stopped. Only successful page fetches from known AI agents leave the machine, and visitors’ addresses stay where they are.

## How it differs from the TypeScript library

The Python package passes the conformance tests the TypeScript library is held to, on SQLite, Postgres, MySQL, and MariaDB. The differences come from how Python runs.

- Runlight’s work is synchronous and runs in threads. The ASGI middleware hands each of its requests to a worker thread, so an event loop stays free for the rest of your app.
- SQLite keeps one connection, which every thread shares under a lock. Postgres and MySQL open one connection for each thread, so a server with sixteen threads holds up to sixteen connections.
- What the TypeScript library does in the background, such as deleting visits after a shorter retention is chosen, runs once the answer has been sent.
- The tracker’s rate limit and the cached lists of link domains and site icons are kept in memory, so each process keeps its own. A server with several worker processes allows each address the limit once in every process. Wrong-password limits are kept in the database, so every process shares them.
- Passwords are hashed with scrypt through Python’s `hashlib`. The hashes match the TypeScript library’s, so accounts carry over.
