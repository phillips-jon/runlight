# Runlight for Java

Runlight is privacy friendly web analytics that runs inside your own Java app. It counts visitors without cookies and without storing anyone’s IP address. The numbers stay in your database, and the dashboard is served from your domain at `/runlight`.

This is the Java version of [Runlight](https://runlight.sh). It runs on Java 21 or later, on the JDK’s own HTTP server, in a servlet container, or in a Spring Boot app, and it can also run on its own domain as a standalone server. It answers every request the way the TypeScript library does and uses the same tables, so either one can read the other’s database.

## Get started

Add `sh.runlight:runlight` from Maven Central to your build, with the JDBC driver for your database. In a Spring Boot app, add `sh.runlight:runlight-spring-boot-starter` in its place and set `runlight.site.hostnames` in `application.properties`. It keeps its tables in the app’s own `DataSource`.

```xml
<dependency>
  <groupId>sh.runlight</groupId>
  <artifactId>runlight</artifactId>
  <version>0.0.0</version>
</dependency>
```

In Gradle, that is `implementation("sh.runlight:runlight:0.0.0")`.

Create one instance for your app.

```java
Runlight rl = new Runlight(new Runlight.Options()
    .store(Stores.sqlite("data/runlight.db"))
    .site(Map.of("name", "example.com", "hostnames", List.of("example.com"), "timezone", "Europe/London")));
```

Mount it on your server. On the JDK’s own HTTP server that is one line.

```java
JdkServer.mount(server, rl, rl.routes());
```

Add the script to every page, just before `</head>`.

```html
<script defer src="/runlight/s.js"></script>
```

Set `RUNLIGHT_TOKEN` to a long random string, then open `/runlight/?token=` followed by that string to sign in.

The [Java guide](https://runlight.sh/docs/java/) has the code for servlet containers and Spring Boot, the Postgres, MySQL, and MariaDB stores, the scheduled check, and the standalone server.

## License

Runlight is MIT licensed.
