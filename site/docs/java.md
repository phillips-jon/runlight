---
title: Java
description: Runlight runs in Java 21 or later, on the JDK's own HTTP server, in a servlet container, or in a Spring Boot app, or as a server of its own.
group: Platforms
order: 17.5
---

The Java library is Runlight written again in Java. It serves the same dashboard and API, and it gives every request the answer the TypeScript library gives. Its numbers go in the same tables, so either one can read a database the other wrote. It needs Java 21 or later, and the core has no dependencies of its own.

## Install

Add the core to your build. Replace `VERSION` with the latest release on Maven Central.

```xml file=pom.xml
<dependency>
  <groupId>sh.runlight</groupId>
  <artifactId>runlight</artifactId>
  <version>VERSION</version>
</dependency>
```

```kotlin file=build.gradle.kts
implementation("sh.runlight:runlight:VERSION")
```

Runlight reaches your database through JDBC, so your app brings the driver. That is `org.xerial:sqlite-jdbc` for SQLite, `org.postgresql:postgresql` for Postgres, and `com.mysql:mysql-connector-j` or `org.mariadb.jdbc:mariadb-java-client` for MySQL and MariaDB. Two more artifacts fit Runlight into a framework. `sh.runlight:runlight-servlet` serves it in Tomcat 10.1, Jetty 12, or any other Jakarta Servlet 6 container, and `sh.runlight:runlight-spring-boot-starter` sets it up in Spring Boot 3.5 or 4.

## Create the instance

Make one instance when your app starts, and keep it for as long as the app runs.

```java file=Analytics.java
import java.util.List;
import java.util.Map;
import sh.runlight.Runlight;
import sh.runlight.store.Stores;

Runlight rl = new Runlight(new Runlight.Options()
    .store(Stores.sqlite("data/runlight.db"))
    .site(Map.of("name", "example.com", "hostnames", List.of("example.com"), "timezone", "Europe/London")));
```

The options have the same names as in [Configuration](/docs/configuration/#runlight-options), as setters on `Runlight.Options`, so `sites`, `trustProxy`, `rateLimit`, `mail`, and `managedSites` all work as they do there. One instance serves every thread of your app at once. The tables are created on the first request.

## Stores

### SQLite

```java
Stores.sqlite("data/runlight.db");
```

Keep the file outside any folder your web server serves, in a folder the app can write to, since SQLite writes a journal beside it. The folder is made when it is missing.

### Postgres

```java
Stores.postgres("postgres://runlight:password@127.0.0.1:5432/runlight");
```

Any one statement stops after two minutes. `Stores.postgres(url, 30_000, "analytics")` sets another limit in milliseconds and keeps the tables in a schema of their own.

### MySQL and MariaDB

```java
Stores.mysql("mysql://runlight:password@127.0.0.1:3306/runlight");
```

This store works with MySQL 8.4 or later and MariaDB 11.4 or later. A `mariadb://` URL works too. `Stores.mysql(url, 30_000)` sets the statement timeout, which MySQL applies to reads and MariaDB to every statement, as in [Configuration](/docs/configuration/#mysql-and-mariadb).

### Your app's own DataSource

```java
Stores.dataSource(dataSource);
```

Runlight borrows a connection from your app's pool for each statement and gives it back, and its tables all start with `rl_`, so they can live in your app's own database. `Stores.url()` picks the store from a `DATABASE_URL` that starts with `postgres://`, `mysql://`, `mariadb://`, or `sqlite:`.

## The JDK's own HTTP server

An app on `com.sun.net.httpserver.HttpServer` mounts the dashboard, the API, and the tracker at `/runlight`.

```java file=Main.java
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.util.concurrent.Executors;
import sh.runlight.Routes;
import sh.runlight.server.JdkServer;

HttpServer server = HttpServer.create(new InetSocketAddress(8080), 0);
server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
JdkServer.mount(server, rl, rl.routes(new Routes.Options().basePath("/runlight")));
var app = server.createContext("/", yourHandler);
app.getFilters().add(JdkServer.linkDomains(rl));
app.getFilters().add(JdkServer.observer(rl));
server.start();
```

Give the server an executor, since the routes read the database and the JDK's default runs every request on one thread. `mount` also answers [short links](/docs/links/) at `/go/`. The `linkDomains` filter answers them on any link domain added in **Settings**, and `observer` records the fetches of [AI agents](/docs/ai/#agents-that-read-your-pages) as your app serves its pages.

## Servlet containers

Add `sh.runlight:runlight-servlet`, then register the servlet at `/runlight/*` and the filter on every path, in a `ServletContainerInitializer` or a listener.

```java
import sh.runlight.servlet.RunlightFilter;
import sh.runlight.servlet.RunlightServlet;

context.addServlet("runlight", new RunlightServlet(rl)).addMapping("/runlight/*");
context.addFilter("runlight-links", new RunlightFilter(rl)).addMappingForUrlPatterns(null, false, "/*");
```

The servlet takes its base path from its mapping. The filter answers short links and link domains and records AI agent fetches, and it never reads a request body, which stays your app's. Link domains need the app at the root context, since their slugs are read from the whole path.

## Spring Boot

Add `sh.runlight:runlight-spring-boot-starter` and set Runlight up in `application.properties`.

```properties file=application.properties
runlight.site.name=example.com
runlight.site.hostnames=example.com
runlight.site.timezone=Europe/London
runlight.token=${RUNLIGHT_TOKEN}
```

The starter keeps its tables in your app's own `DataSource`, or in the database `runlight.database-url` names. It serves the routes at `runlight.base-path` (`/runlight`) and short links at `runlight.link-path` (`/go`), and it runs the scheduled check every minute. Its filters run ahead of Spring Security's. Set `runlight.open=true` to serve the dashboard without a token, behind your app's own sign-in, and its filter moves behind Spring Security so your rules guard it. A `Runlight` or `Routes` bean of your own takes the place of the one the starter makes. The other settings are `runlight.sites[0].*`, `managed-sites`, `secret`, `trust-proxy`, `rate-limit`, `origin`, `accounts`, `cron-secret`, `observe-key`, `observe`, `check.every`, and `web.enabled`.

## Add the script

Add the script to every page, just before `</head>`.

```html
<script defer src="/runlight/s.js"></script>
```

Then set `RUNLIGHT_TOKEN` to a long random string and open `/runlight/?token=` followed by that string once to sign in, as [Getting started](/docs/#5-sign-in) describes. With `.accounts(true)` in `Routes.Options` and a `RUNLIGHT_SECRET`, people sign in with their own email and password, as in [Accounts](/docs/configuration/#accounts).

## The scheduled check

The [scheduled check](/docs/cron/) rotates the daily salts, sends email reports that are due, applies how long each site keeps its visits, and builds the rollups that keep long ranges quick. The Spring Boot starter runs it for you. Anywhere else, call `rl.check()` every few minutes from a `ScheduledExecutorService`, or set `CRON_SECRET` and have a scheduler call `/runlight/api/check` with it, as [Scheduled check](/docs/cron/#anywhere-else) shows.

## The standalone server

The core jar includes the [standalone server](/docs/server/), which runs Runlight on a domain of its own, such as `stats.example.com`, with the dashboard at the root, sites added in the dashboard, sign-in accounts, and short links on any domain you point at it. Download the `runlight` jar and your database's JDBC driver from Maven Central, put them side by side, and start it.

```bash
java -cp runlight.jar:sqlite-jdbc.jar sh.runlight.server.Cli
```

On Windows, separate the jars with `;`. The server listens on port 3000 and keeps its data in a folder called `runlight-data` in the directory you start it from. On its first start it prints a setup link with a one-time code. Open that link and make your account, as [Make your account](/docs/server/#make-your-account) describes. The server runs the scheduled check itself every five minutes, and it downloads the month’s location data as the Node server does. Put it behind a proxy that adds HTTPS, as in [Put it on the internet](/docs/server/#put-it-on-the-internet).

### Settings

The server reads its settings from environment variables, or from lines such as `PORT=8080` in `runlight.properties` in the directory you start it from. The environment wins over the file, and `--config` names another file.

| Variable | What it does |
| --- | --- |
| `PORT` | The port to listen on. The default is 3000. |
| `HOST` | The address to listen on. The default is `0.0.0.0`. |
| `DATA_DIR` | The folder for the SQLite file, the secret, and the location data. The default is `./runlight-data`. |
| `DATABASE_URL` | A `postgres://` address keeps the data in Postgres instead of SQLite, and a `mysql://` or `mariadb://` address keeps it in MySQL or MariaDB. Put that database's driver on the class path. |
| `RUNLIGHT_SECRET` | The key that signs sign-ins and encrypts saved keys. Without it, the server makes one and keeps it in `DATA_DIR`, readable only by the user that runs it. |
| `RUNLIGHT_URL` | The server’s public address, such as `https://stats.example.com`, which can never become a link domain. Invite and report emails link to it. |
| `RUNLIGHT_TOKEN` | A token that scripts can send as a bearer, in addition to the [API tokens](/docs/mcp/) made in the dashboard. |
| `RUNLIGHT_OBSERVE_KEY` | One key for every site’s AI agent reports. Each site’s own key from **Settings**, **Install** is the better choice. |
| `TRUST_PROXY` | Set to `false` when no proxy sits in front of the server, or to `x-real-ip` or `cf-connecting-ip` when that header holds the visitor’s address. |
| `RUNLIGHT_GEO` | Where locations come from when no header gives them, as in [Locations](/docs/server/#locations). It is `city` by default, and can be `country`, `off`, or a path to an MMDB file. |
| `CRON_SECRET` | Lets a scheduler run the check at `POST /api/check`. |

### Commands

Each command goes after `sh.runlight.server.Cli`. `cron` runs the scheduled check once and fetches the month’s location data, and `migrate` creates or updates the tables at once. The tables also update themselves when the server starts, so an upgrade needs only the new jar and a restart. Back up the data folder, since saved keys cannot be read without the secret in it.

### Forgotten passwords

Run the `password` command where the server runs to give an account a new password, which it prints. It also turns off two-factor sign-in for that account, and it makes the account when there is none, as the owner on a server with nobody yet and as an admin otherwise.

```bash
java -cp runlight.jar:sqlite-jdbc.jar sh.runlight.server.Cli password someone@example.com
```

### AI agents from a log

AI agents such as GPTBot and ClaudeBot fetch pages without running JavaScript, so the script tag never sees them. A Java app with Runlight inside counts them where the page is served, as the filters above do. For any other site you host yourself, the web server’s access log has them, and the `agents` command reads it. It needs no database driver.

```bash
java -jar runlight.jar agents --log /var/log/nginx/access.log --to https://stats.example.com --key rlo_... --site https://example.com --follow
```

The key is the site’s own, from **Settings**, **Install**, **Key for CMS plugins**, and it can only report fetches for that site. When `--to` or `--key` is left out, the command reads `RUNLIGHT_URL` or `RUNLIGHT_OBSERVE_KEY` from the environment. The command works as it does on the [standalone server](/docs/server/#ai-agents-from-a-log), with `--follow` to keep running and `--state` to pick up where the last run stopped. Only successful page fetches from known AI agents leave the machine, and visitors’ addresses stay where they are.

## How it differs from the TypeScript library

The Java library passes the conformance tests the TypeScript library is held to, on SQLite, Postgres, MySQL, and MariaDB. The differences come from how Java runs.

- Runlight’s work is synchronous and runs on your server’s threads, platform or virtual. One instance is safe to share between them.
- SQLite keeps one connection, which every thread takes in turn. Postgres and MySQL keep a small pool of their own, or borrow from your app’s `DataSource`.
- What the TypeScript library does in the background, such as deleting visits after a shorter retention is chosen, runs once the answer has been sent. The adapters call `rl.idle()` for that, and an app that answers requests its own way should call it too.
- The tracker’s rate limit and the cached lists of link domains and site icons are kept in memory, so each process keeps its own. Wrong-password limits are kept in the database, so every process shares them.
- Passwords are hashed with scrypt, written in Java since the JDK has none. The hashes match the TypeScript library’s, so accounts carry over.
