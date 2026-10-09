# Runlight for .NET

Runlight is privacy friendly web analytics that runs inside your own ASP.NET Core app. It counts visitors without cookies and without storing anyone’s IP address. The numbers stay in your database, and the dashboard is served from your domain at `/runlight`.

These packages are the .NET version of [Runlight](https://runlight.sh). They need .NET 10 or later, and the `runlight` tool also runs Runlight on a domain of its own. They answer every request the way the TypeScript library does and use the same tables, so either one can read the other’s database.

| Package | What it is |
| --- | --- |
| `Runlight` | The library, with no dependencies of its own. |
| `Runlight.AspNetCore` | `MapRunlight()` and `UseRunlight()` for ASP.NET Core. |
| `Runlight.Server` | The `runlight` tool, which runs the standalone server. |

## Get started

Add the ASP.NET Core package and the driver for your database.

```bash
dotnet add package Runlight.AspNetCore
dotnet add package Microsoft.Data.Sqlite
```

Create one instance for your app, and map its routes.

```csharp
using Microsoft.Data.Sqlite;
using Runlight;
using Runlight.Store;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton(new Runlight.Runlight(new RunlightOptions
{
    Store = Stores.Sqlite(SqliteFactory.Instance, "data/runlight.db"),
    Site = new SiteOptions { Name = "example.com", Hostnames = ["example.com"], Timezone = "Europe/London" },
}));

var app = builder.Build();
app.MapRunlight();
app.Run();
```

Add the script to every page, just before `</head>`.

```html
<script defer src="/runlight/s.js"></script>
```

Set `RUNLIGHT_TOKEN` to a long random string, then open `/runlight/?token=` followed by that string to sign in.

To run Runlight on a domain of its own, install the tool and start it in an empty folder.

```bash
dotnet tool install --global Runlight.Server
runlight serve
```

The [.NET guide](https://runlight.sh/docs/dotnet/) has the Postgres, MySQL, and MariaDB stores, the scheduled check, sign-in accounts, and the standalone server’s settings.

## License

Runlight is MIT licensed.
