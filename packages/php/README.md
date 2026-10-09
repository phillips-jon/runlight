# runlight/runlight

Runlight is privacy friendly web analytics that runs inside your own PHP app. It counts visitors without cookies and without storing anyone’s IP address. The numbers stay in your database, and the dashboard is served from your domain at `/runlight`.

This package is the PHP version of [Runlight](https://runlight.sh). It works in Laravel, Symfony, or plain PHP on PHP 8.2 or later, and it can also run on its own domain on ordinary PHP hosting. It answers every request the way the TypeScript library does and uses the same tables, so either one can read the other’s database.

## Get started

Install it with Composer.

```bash
composer require runlight/runlight
```

Create one instance for your app.

```php
use Runlight\Runlight;
use Runlight\Store\Stores;

$rl = new Runlight([
    'store' => Stores::sqlite(__DIR__ . '/data/runlight.db'),
    'site' => ['name' => 'example.com', 'hostnames' => ['example.com'], 'timezone' => 'Europe/London'],
]);
```

Send requests under `/runlight` and `/go` to it. In plain PHP that is a few lines at the top of your `index.php`.

```php
use Runlight\Server\FrontController;

$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
if ($path === '/runlight' || str_starts_with($path, '/runlight/') || str_starts_with($path, '/go/')) {
    FrontController::serve($rl, $rl->routes());
    return;
}
```

Add the script to every page, just before `</head>`.

```html
<script defer src="/runlight/s.js"></script>
```

Set `RUNLIGHT_TOKEN` to a long random string, then open `/runlight/?token=` followed by that string to sign in.

The [PHP guide](https://runlight.sh/docs/php/) has the code for Laravel and Symfony, the MySQL, MariaDB, and Postgres stores, the scheduled check, and the drop-in that runs Runlight on a domain of its own with sign-in accounts.

## License

Runlight is MIT licensed.
