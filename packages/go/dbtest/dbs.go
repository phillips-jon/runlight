// Package dbtest holds the tests that need real database drivers: the store
// on SQLite, Postgres, MySQL, and MariaDB, the SQLite file the TypeScript
// SDK wrote, and the HTTP conformance scenarios on every database. It is a
// module of its own so the drivers never reach an app that requires
// runlight.sh/go.
//
// SQLite in memory always runs. Postgres runs when RUNLIGHT_TEST_PG is a
// connection URL (each store gets a schema of its own, dropped after), and
// MySQL and MariaDB when RUNLIGHT_TEST_MYSQL and RUNLIGHT_TEST_MARIADB are
// (the database the URL names is used, its rl_ tables dropped before each
// store; set to 1, the local defaults below are used).
package dbtest

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"fmt"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"

	_ "github.com/go-sql-driver/mysql"
	_ "github.com/jackc/pgx/v5/stdlib"
	_ "modernc.org/sqlite"

	runlight "runlight.sh/go"
)

// Local defaults, for RUNLIGHT_TEST_PG=1 and the like.
const (
	DefaultPG      = "postgres://joncphillips@127.0.0.1:5432/runlight_test_go"
	DefaultMySQL   = "mysql://root:runlight@127.0.0.1:33084/runlight_test_go"
	DefaultMariaDB = "mysql://root:runlight@127.0.0.1:33114/runlight_test_go"
)

// Kind is one database the tests run on.
type Kind struct {
	Name string
	URL  string
}

func env(name, fallback string) string {
	v := strings.TrimSpace(os.Getenv(name))
	if v == "" {
		return ""
	}
	if !strings.Contains(v, "://") {
		return fallback
	}
	return v
}

// Kinds are the databases to run on: SQLite always, the others when their variable is set.
func Kinds() []Kind {
	kinds := []Kind{{"sqlite", ""}}
	if u := env("RUNLIGHT_TEST_PG", DefaultPG); u != "" {
		kinds = append(kinds, Kind{"postgres", u})
	}
	if u := env("RUNLIGHT_TEST_MYSQL", DefaultMySQL); u != "" {
		kinds = append(kinds, Kind{"mysql", u})
	}
	if u := env("RUNLIGHT_TEST_MARIADB", DefaultMariaDB); u != "" {
		kinds = append(kinds, Kind{"mariadb", u})
	}
	return kinds
}

// mysqlLocks keeps MySQL tests on one database from running at once.
var mysqlLocks sync.Map

// MySQLDSN is a mysql:// URL as go-sql-driver/mysql's DSN.
func MySQLDSN(raw string) (string, error) {
	u, err := url.Parse(strings.Replace(raw, "mariadb://", "mysql://", 1))
	if err != nil {
		return "", err
	}
	pass, _ := u.User.Password()
	host := u.Host
	if !strings.Contains(host, ":") {
		host += ":3306"
	}
	return fmt.Sprintf("%s:%s@tcp(%s)/%s?charset=utf8mb4&loc=UTC", u.User.Username(), pass, host, strings.TrimPrefix(u.Path, "/")), nil
}

// Open is a fresh, empty database of a kind, closed and cleaned up when the test ends.
func Open(t testing.TB, kind Kind) runlight.Db {
	t.Helper()
	ctx := context.Background()
	switch kind.Name {
	case "sqlite":
		db, err := sql.Open("sqlite", ":memory:")
		if err != nil {
			t.Fatal(err)
		}
		d := runlight.SQLite(db).Owned(0)
		t.Cleanup(func() { d.Close() })
		return d
	case "postgres":
		b := make([]byte, 5)
		_, _ = rand.Read(b)
		schema := "rl_go_" + hex.EncodeToString(b)
		admin, err := sql.Open("pgx", kind.URL)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := admin.ExecContext(ctx, `CREATE SCHEMA "`+schema+`"`); err != nil {
			t.Fatal(err)
		}
		sep := "?"
		if strings.Contains(kind.URL, "?") {
			sep = "&"
		}
		db, err := sql.Open("pgx", kind.URL+sep+"search_path="+schema)
		if err != nil {
			t.Fatal(err)
		}
		d := runlight.Postgres(db).Owned(0)
		t.Cleanup(func() {
			d.Close()
			_, _ = admin.ExecContext(ctx, `DROP SCHEMA IF EXISTS "`+schema+`" CASCADE`)
			admin.Close()
		})
		return d
	}
	dsn, err := MySQLDSN(kind.URL)
	if err != nil {
		t.Fatal(err)
	}
	lock, _ := mysqlLocks.LoadOrStore(kind.URL, &sync.Mutex{})
	lock.(*sync.Mutex).Lock()
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		lock.(*sync.Mutex).Unlock()
		t.Fatal(err)
	}
	if err := DropTables(ctx, db); err != nil {
		lock.(*sync.Mutex).Unlock()
		t.Fatal(err)
	}
	d := runlight.MySQL(db).Owned(0)
	t.Cleanup(func() {
		_ = DropTables(ctx, db)
		d.Close()
		lock.(*sync.Mutex).Unlock()
	})
	return d
}

// DropTables drops every rl_ table of the MySQL database a handle uses.
func DropTables(ctx context.Context, db *sql.DB) error {
	rows, err := db.QueryContext(ctx, "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name LIKE 'rl\\_%'")
	if err != nil {
		return err
	}
	var names []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			rows.Close()
			return err
		}
		names = append(names, name)
	}
	rows.Close()
	for _, name := range names {
		if _, err := db.ExecContext(ctx, "DROP TABLE IF EXISTS `"+name+"`"); err != nil {
			return err
		}
	}
	return nil
}

// Store is a fresh, migrated store on a kind of database.
func Store(t testing.TB, kind Kind) *runlight.Store {
	t.Helper()
	store := runlight.NewStore(Open(t, kind))
	if err := store.Migrate(context.Background()); err != nil {
		t.Fatalf("%s: migrate: %v", kind.Name, err)
	}
	return store
}
