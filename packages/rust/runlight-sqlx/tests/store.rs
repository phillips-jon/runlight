//! One database, both implementations. packages/php/tests/fixtures/store.db was built by the
//! TypeScript SDK and store.json holds what its SqlStore reads answered; the Rust store must answer the
//! same over a copy of that file, and over the same rows copied into Postgres and MySQL.

#![cfg(all(feature = "sqlite", feature = "postgres", feature = "mysql"))]

mod common;

use runlight::js::{self, Object, Value};
use runlight::query::{Filter, Query};
use runlight::store::{FunnelRow, FunnelStep, GoalRow, GoalTotals, Param, SqlStore};
use runlight::time::Bucket;
use runlight::{arr, obj};

fn num(v: &Value) -> i64 {
    v.as_f64().unwrap_or(0.0) as i64
}

fn s(v: &Value) -> String {
    js::str_or_empty(Some(v))
}

fn query_of(v: &Value) -> Query {
    Query {
        site: s(v.at("site")),
        from: num(v.at("from")),
        to: num(v.at("to")),
        filters: v
            .at("filters")
            .as_array()
            .map(|a| {
                a.iter()
                    .map(|f| Filter { dimension: s(f.at("dimension")), op: s(f.at("op")), value: s(f.at("value")) })
                    .collect()
            })
            .unwrap_or_default(),
    }
}

fn goal_of(v: &Value) -> GoalRow {
    GoalRow {
        id: s(v.at("id")),
        site: s(v.at("site")),
        name: s(v.at("name")),
        kind: s(v.at("kind")),
        match_: s(v.at("match")),
        click_by: s(v.at("clickBy")),
        value_mode: s(v.at("valueMode")),
        value: v.at("value").as_f64().unwrap_or(0.0),
        value_prop: s(v.at("valueProp")),
        currency: s(v.at("currency")),
        created_at: num(v.at("createdAt")),
    }
}

fn funnel_of(v: &Value) -> FunnelRow {
    FunnelRow {
        id: s(v.at("id")),
        site: s(v.at("site")),
        name: s(v.at("name")),
        steps: v
            .at("steps")
            .as_array()
            .unwrap()
            .iter()
            .map(|st| FunnelStep { kind: s(st.at("kind")), match_: s(st.at("match")) })
            .collect(),
        created_at: num(v.at("createdAt")),
    }
}

fn buckets_of(v: &Value) -> Vec<Bucket> {
    v.as_array().unwrap().iter().map(|b| Bucket { start: num(b.at("start")), end: num(b.at("end")) }).collect()
}

fn totals(t: &GoalTotals) -> Value {
    obj! { "conversions" => t.conversions, "visitors" => t.visitors, "revenue" => t.revenue }
}

fn opt_i64(v: Option<i64>) -> Value {
    v.map_or(Value::Null, Value::from)
}

/// A read's answer in JSON's terms, as the TypeScript script wrote it.
async fn answer(store: &SqlStore, method: &str, args: &[Value]) -> Result<Value, String> {
    let e = |e: runlight::store::DbError| e.0;
    Ok(match method {
        "sites" => Value::Array(store.sites().await.map_err(e)?.iter().map(|s| s.to_value()).collect()),
        "siteOverrides" => {
            let mut map: Vec<(String, Object)> = store.site_overrides().await.map_err(e)?.into_iter().collect();
            map.sort_by(|a, b| a.0.cmp(&b.0));
            let mut o = Object::new();
            for (k, v) in map {
                o.set(k, v);
            }
            Value::Object(o)
        }
        "lastSeen" => opt_i64(store.last_seen(&s(&args[0])).await.map_err(e)?),
        "firstSeen" => opt_i64(store.first_seen(&s(&args[0])).await.map_err(e)?),
        "firstOwnVisit" => opt_i64(store.first_own_visit(&s(&args[0])).await.map_err(e)?),
        "rollupDays" => {
            let mut days: Vec<String> = store.rollup_days(&s(&args[0])).await.map_err(e)?.into_iter().collect();
            days.sort();
            Value::Array(days.into_iter().map(Value::from).collect())
        }
        "stats" => store.stats(&query_of(&args[0])).await.map_err(e)?.to_value(),
        "visitors" => store.visitors(&query_of(&args[0])).await.map_err(e)?.into(),
        "hourly" => Value::Array(
            store
                .hourly(&query_of(&args[0]))
                .await
                .map_err(e)?
                .into_iter()
                .map(|(q, visits, visitors, pageviews, bounced)| obj! { "quarter" => q, "visits" => visits, "visitors" => visitors, "pageviews" => pageviews, "bounced" => bounced })
                .collect(),
        ),
        "breakdown" => Value::Array(store.breakdown(&query_of(&args[0]), &s(&args[1]), num(&args[2]), num(&args[3])).await.map_err(e)?),
        "goalTotalsAll" => {
            let goals: Vec<GoalRow> = args[1].as_array().unwrap().iter().map(goal_of).collect();
            let all = store.goal_totals_all(&query_of(&args[0]), &goals).await.map_err(e)?;
            let mut o = Object::new();
            for g in &goals {
                o.set(g.id.clone(), totals(&all[&g.id]));
            }
            Value::Object(o)
        }
        "funnelCounts" => Value::Array(store.funnel_counts(&query_of(&args[0]), &funnel_of(&args[1])).await.map_err(e)?.into_iter().map(Value::from).collect()),
        "journeyPages" => {
            let (rows, sampled) = store.journey_pages(&query_of(&args[0]), num(&args[1])).await.map_err(e)?;
            obj! {
                "rows" => Value::Array(rows.into_iter().map(|(session, path)| obj! { "session" => session, "path" => path }).collect()),
                "sampled" => sampled,
            }
        }
        "eventPropKeys" => Value::Array(
            store
                .event_prop_keys(&query_of(&args[0]), &s(&args[1]))
                .await
                .map_err(e)?
                .into_iter()
                .map(|(key, events)| obj! { "key" => key, "events" => events })
                .collect(),
        ),
        "eventPropValues" => Value::Array(
            store
                .event_prop_values(&query_of(&args[0]), &s(&args[1]), &s(&args[2]), num(&args[3]))
                .await
                .map_err(e)?
                .into_iter()
                .map(|(value, events, visitors)| obj! { "value" => value, "events" => events, "visitors" => visitors })
                .collect(),
        ),
        "goalTotals" => totals(&store.goal_totals(&query_of(&args[0]), &goal_of(&args[1])).await.map_err(e)?),
        "goalBreakdown" => Value::Array(
            store
                .goal_breakdown(&query_of(&args[0]), &goal_of(&args[1]), &s(&args[2]), num(&args[3]))
                .await
                .map_err(e)?
                .into_iter()
                .map(|(value, t)| obj! { "value" => value, "conversions" => t.conversions, "visitors" => t.visitors, "revenue" => t.revenue })
                .collect(),
        ),
        "links" => Value::Array(
            store
                .links(&s(&args[0]), num(&args[1]), num(&args[2]))
                .await
                .map_err(e)?
                .into_iter()
                .map(|(link, clicks, visitors)| {
                    let mut o = link.to_object();
                    o.set("clicks", clicks);
                    o.set("visitors", visitors);
                    Value::Object(o)
                })
                .collect(),
        ),
        "linkBreakdown" => Value::Array(
            store.link_breakdown(&s(&args[0]), &s(&args[1]), num(&args[2]), num(&args[3]), &s(&args[4]), num(&args[5])).await.map_err(e)?,
        ),
        "series" => {
            let q = &args[0];
            let filters = query_of(q).filters;
            Value::Array(store.series(&s(q.at("site")), &filters, &buckets_of(&args[1])).await.map_err(e)?)
        }
        "goalSeries" => {
            let q = &args[0];
            Value::Array(
                store
                    .goal_series(&s(q.at("site")), &query_of(q).filters, &goal_of(&args[1]), &buckets_of(&args[2]))
                    .await
                    .map_err(e)?
                    .into_iter()
                    .map(|(start, conversions, revenue)| obj! { "start" => start, "conversions" => conversions, "revenue" => revenue })
                    .collect(),
            )
        }
        "linkSeries" => Value::Array(
            store
                .link_series(&s(&args[0]), &s(&args[1]), &buckets_of(&args[2]))
                .await
                .map_err(e)?
                .into_iter()
                .map(|(start, clicks, visitors)| obj! { "start" => start, "clicks" => clicks, "visitors" => visitors })
                .collect(),
        ),
        "realtime" => store.realtime(&s(&args[0]), num(&args[1])).await.map_err(e)?,
        "goals" => Value::Array(store.goals(args.first().map(s).as_deref()).await.map_err(e)?.iter().map(GoalRow::to_value).collect()),
        "goalById" => store.goal_by_id(&s(&args[0])).await.map_err(e)?.map_or(Value::Null, |g| g.to_value()),
        "funnels" => Value::Array(store.funnels(&s(&args[0])).await.map_err(e)?.iter().map(FunnelRow::to_value).collect()),
        "linkBySlug" => store.link_by_slug(&s(&args[0])).await.map_err(e)?.map_or(Value::Null, |l| Value::Object(l.to_object())),
        "linkById" => store.link_by_id(&s(&args[0])).await.map_err(e)?.map_or(Value::Null, |l| Value::Object(l.to_object())),
        "linkDomains" => Value::Array(
            store.link_domains().await.map_err(e)?.into_iter().map(|(domain, site)| obj! { "domain" => domain, "site" => site }).collect(),
        ),
        "shares" => Value::Array(store.shares(&s(&args[0])).await.map_err(e)?.iter().map(|x| x.to_value()).collect()),
        "shareById" => store.share_by_id(&s(&args[0])).await.map_err(e)?.map_or(Value::Null, |x| x.to_value()),
        "tokens" => Value::Array(store.tokens().await.map_err(e)?.iter().map(token).collect()),
        "tokenByHash" => store.token_by_hash(&s(&args[0])).await.map_err(e)?.as_ref().map_or(Value::Null, token),
        "reports" => Value::Array(
            store.reports(args.first().map(s).as_deref()).await.map_err(e)?.iter().map(|r| r.to_value()).collect(),
        ),
        "reportBy" => store.report_by(s(&args[0]) == "token", &s(&args[1])).await.map_err(e)?.map_or(Value::Null, |r| r.to_value()),
        "setting" => store.setting(&s(&args[0])).await.map_err(e)?.into(),
        "settingsStartingWith" => Value::Array(
            store.settings_starting_with(&s(&args[0])).await.map_err(e)?.into_iter().map(|(key, value)| obj! { "key" => key, "value" => value }).collect(),
        ),
        "pageview" => store.pageview(&s(&args[0]), &s(&args[1])).await.map_err(e)?.map_or(Value::Null, |p| {
            obj! { "session" => p.session, "visitor" => p.visitor, "path" => p.path, "hostname" => p.hostname, "ts" => p.ts, "startedAt" => p.started_at, "lastAt" => p.last_at }
        }),
        "openSession" => {
            let visitors: Vec<String> = args[1].as_array().unwrap().iter().map(s).collect();
            store.open_session(&s(&args[0]), &visitors, num(&args[2])).await.map_err(e)?.map_or(Value::Null, |(id, visitor)| obj! { "id" => id, "visitor" => visitor })
        }
        "saltIfExists" => store.salt_if_exists(&s(&args[0])).await.map_err(e)?.into(),
        other => return Err(format!("no such read: {other}")),
    })
}

fn token(t: &runlight::store::TokenRow) -> Value {
    obj! {
        "id" => t.id.clone(), "name" => t.name.clone(), "site" => t.site.clone(), "scope" => t.scope.clone(), "hash" => t.hash.clone(),
        "hint" => t.hint.clone(), "createdAt" => t.created_at, "lastUsedAt" => t.last_used_at,
    }
}

async fn assert_answers(store: &SqlStore, label: &str) {
    let fixture = common::fixture("store");
    let calls = fixture.at("calls").as_array().unwrap();
    let mut failures = Vec::new();
    for (i, call) in calls.iter().enumerate() {
        let method = s(call.at("method"));
        let args = call.at("args").as_array().unwrap();
        let expected = call.at("result").to_json();
        let actual = match answer(store, &method, args).await {
            Ok(v) => v.to_json(),
            Err(e) => format!("error: {e}"),
        };
        if actual != expected {
            failures.push(format!(
                "#{i} {method}({})\n  expected {}\n  actual   {}",
                js::head16(&arr![].to_json(), 0) + &js::head16(&call.at("args").to_json(), 300),
                js::head16(&expected, 600),
                js::head16(&actual, 600)
            ));
        }
    }
    let count = failures.len();
    failures.truncate(12);
    assert!(failures.is_empty(), "{label}: {count} of {} reads differ\n{}", calls.len(), failures.join("\n"));
}

fn copy_db() -> tempfile_path::Temp {
    tempfile_path::Temp::copy(&common::root().join("packages/php/tests/fixtures/store.db"))
}

mod tempfile_path {
    /// A copy of a file, removed with its WAL files when dropped.
    pub struct Temp(pub std::path::PathBuf);

    impl Temp {
        pub fn copy(from: &std::path::Path) -> Temp {
            let path = std::env::temp_dir().join(format!("rl-store-{}.db", runlight::hash::random_id(6)));
            std::fs::copy(from, &path).expect("a copy");
            Temp(path)
        }
    }

    impl Drop for Temp {
        fn drop(&mut self) {
            for suffix in ["", "-wal", "-shm"] {
                let _ = std::fs::remove_file(format!("{}{suffix}", self.0.display()));
            }
        }
    }
}

#[tokio::test]
async fn rust_reads_a_database_the_typescript_sdk_wrote_and_answers_the_same() {
    let file = copy_db();
    let store = runlight_sqlx::connect(file.0.to_str().unwrap()).await.unwrap();
    store.migrate().await.unwrap();
    assert_answers(&store, "sqlite").await;
    let rows = store.db().all("SELECT value FROM rl_meta WHERE \"key\" = 'schema'", vec![]).await.unwrap();
    assert_eq!(rows[0].text("value"), "11");
    store.close().await;
}

#[tokio::test]
async fn the_same_rows_in_postgres_and_mysql_answer_the_same() {
    let tables = [
        "rl_meta",
        "rl_sites",
        "rl_salts",
        "rl_sessions",
        "rl_events",
        "rl_links",
        "rl_link_domains",
        "rl_shares",
        "rl_goals",
        "rl_settings",
        "rl_reports",
        "rl_tokens",
        "rl_funnels",
        "rl_rollup_days",
        "rl_rollups",
    ];
    for (kind, url) in common::kinds() {
        if kind == "sqlite" {
            continue;
        }
        let file = copy_db();
        let source = runlight_sqlx::connect(file.0.to_str().unwrap()).await.unwrap();
        let fresh = common::fresh(kind, &url).await;
        let target = fresh.store.clone();
        target.migrate().await.unwrap();
        let source2 = source.clone();
        target
            .transaction(|into| async move {
                for table in tables {
                    into.db().run(&format!("DELETE FROM {table}"), vec![]).await?;
                    for row in source2.db().all(&format!("SELECT * FROM {table}"), vec![]).await? {
                        let columns: Vec<String> = row.0.iter().map(|(c, _)| format!("\"{c}\"")).collect();
                        let params: Vec<Param> = row
                            .0
                            .iter()
                            .map(|(_, c)| match c {
                                runlight::store::Cell::Null => Param::Null,
                                runlight::store::Cell::Int(n) => Param::Int(*n),
                                runlight::store::Cell::Float(f) => Param::Float(*f),
                                runlight::store::Cell::Text(t) => Param::Text(t.clone()),
                            })
                            .collect();
                        into.db()
                            .run(
                                &format!(
                                    "INSERT INTO {table} ({}) VALUES ({})",
                                    columns.join(", "),
                                    vec!["?"; params.len()].join(", ")
                                ),
                                params,
                            )
                            .await?;
                    }
                }
                Ok(())
            })
            .await
            .unwrap();
        assert_answers(&target, kind).await;
        source.close().await;
        fresh.done().await;
    }
}

#[tokio::test]
async fn a_value_stays_inside_its_quotes_whatever_the_sql_mode() {
    let hostile = "x\\' OR 1=1 UNION SELECT 'pwned";
    for (kind, url) in common::kinds() {
        if kind != "mysql" && kind != "mariadb" {
            continue;
        }
        // An app's own pool whose server mode reads a backslash as plain text.
        let plain = sqlx::mysql::MySqlPoolOptions::new()
            .max_connections(2)
            .after_connect(|conn, _| {
                Box::pin(async move {
                    sqlx::raw_sql("SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES'").execute(conn).await.map(|_| ())
                })
            })
            .connect(&url)
            .await
            .unwrap();
        let store = runlight_sqlx::mysql(plain.clone());
        let rows = store.db().all("SELECT ? AS v", vec![Param::Text(hostile.into())]).await.unwrap();
        assert_eq!(rows.len(), 1, "{kind}");
        assert_eq!(rows[0].text("v"), hostile, "{kind}: the mode is dropped, so the value comes back as it went in");
        let rows = store.db().all("SELECT @@SESSION.sql_mode AS m", vec![]).await.unwrap();
        assert!(!rows[0].text("m").contains("NO_BACKSLASH_ESCAPES"), "{kind}");
        plain.close().await;
    }
}
