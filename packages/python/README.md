# runlight

Runlight is privacy friendly web analytics that runs inside your own Python app. It counts visitors without cookies and without storing anyone’s IP address. The numbers stay in your database, and the dashboard is served from your domain at `/runlight`.

This package is the Python version of [Runlight](https://runlight.sh). It works in Django, Flask, FastAPI, or any WSGI or ASGI app on Python 3.11 or later, and it can also run on its own domain as a standalone server. It answers every request the way the TypeScript library does and uses the same tables, so either one can read the other’s database.

## Get started

Install it with pip.

```bash
pip install runlight
```

Create one instance for your app.

```python
from runlight import Runlight
from runlight.store import Stores

rl = Runlight(
    store=Stores.sqlite("data/runlight.db"),
    site={"name": "example.com", "hostnames": ["example.com"], "timezone": "Europe/London"},
)
```

Put it in front of your app. In Flask that is one line.

```python
import runlight.flask

runlight.flask.init_app(app, rl)
```

Add the script to every page, just before `</head>`.

```html
<script defer src="/runlight/s.js"></script>
```

Set `RUNLIGHT_TOKEN` to a long random string, then open `/runlight/?token=` followed by that string to sign in.

The [Python guide](https://runlight.sh/docs/python/) has the code for Django, FastAPI, and plain WSGI or ASGI apps, the Postgres, MySQL, and MariaDB stores, the scheduled check, and the standalone server.

## License

Runlight is MIT licensed.
