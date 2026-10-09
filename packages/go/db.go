package runlight

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
	"sync"
	"time"

	"runlight.sh/go/internal/js"
)

// Row is one row a query read, by column name. Values are what the driver
// hands back: int64, float64, string, []byte, bool, time.Time, or nil.
type Row map[string]any

// Db is the little a store needs from a database. SQL uses ? placeholders
// and "double quotes" around a name that is a keyword somewhere; the
// Postgres Db numbers the placeholders, and the MySQL one fills them in and
// quotes names its own way.
type Db interface {
	// Dialect is sqlite, postgres, or mysql.
	Dialect() string
	All(ctx context.Context, sql string, params ...any) ([]Row, error)
	Run(ctx context.Context, sql string, params ...any) error
}

// Affecter is a Db that says how many rows an UPDATE or DELETE matched.
// MySQL has no RETURNING, so its Db has this.
type Affecter interface {
	Affected(ctx context.Context, sql string, params ...any) (int64, error)
}

// Exclusiver is a Db that runs fn while holding a database-wide lock, so two
// processes starting at once do not race to create the same tables.
type Exclusiver interface {
	Exclusive(ctx context.Context, fn func(Db) error) error
}

// Transactor is a Db that runs fn in one transaction on one connection.
type Transactor interface {
	Transaction(ctx context.Context, fn func(Db) error) error
}

// Metered is a Db reached one statement at a time over the network with a
// cap on statements per request, so long jobs send fewer, larger pieces.
type Metered interface {
	Metered() bool
}

// migrationLock is arbitrary but fixed, so every Runlight process takes the
// same lock to create tables.
const migrationLock = 7_331_906

// mysqlLock is one lock per MySQL database, so installs sharing a server do
// not wait on each other. Lock names are 64 characters at most.
const mysqlLock = "CONCAT('runlight:', LEFT(SHA2(COALESCE(DATABASE(), ''), 256), 48))"

// SQLDB is a Db over database/sql, with the app's own driver: modernc.org/sqlite
// (or another SQLite driver), pgx's stdlib, or go-sql-driver/mysql.
type SQLDB struct {
	db      *sql.DB
	dialect string
	owned   bool

	// SQLite: one connection, held for the store's statements in turn, as an
	// in-memory database is one per connection and SQLite has one writer anyway.
	mu   sync.Mutex
	conn *sql.Conn

	// The connection or transaction statements go to inside Exclusive or Transaction.
	q querier

	// MySQL: the session's statement timeout, lifted while tables are built.
	statementTimeout int
	mariadb          *bool
}

type querier interface {
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

// SQLite is a Db for a SQLite database opened with database/sql. The
// connection is put in WAL mode with a busy timeout, as the SDK's is.
func SQLite(db *sql.DB) *SQLDB { return &SQLDB{db: db, dialect: "sqlite"} }

// Postgres is a Db for a Postgres database opened with database/sql (pgx's
// stdlib, say). Its pool needs two connections at least.
func Postgres(db *sql.DB) *SQLDB { return &SQLDB{db: db, dialect: "postgres"} }

// MySQL is a Db for MySQL 8.4 or MariaDB 11.4 and later, opened with
// database/sql (go-sql-driver/mysql). Text is utf8mb4 with a binary
// collation, so it compares and sorts by code point, as SQLite and Postgres
// do. Its pool needs two connections at least.
func MySQL(db *sql.DB) *SQLDB { return &SQLDB{db: db, dialect: "mysql"} }

// Owned marks the database as Runlight's own, so Close closes it, and on
// MySQL sets each session's statement timeout in milliseconds (0 for none).
func (d *SQLDB) Owned(statementTimeout int) *SQLDB {
	d.owned = true
	d.statementTimeout = statementTimeout
	return d
}

// Dialect is sqlite, postgres, or mysql.
func (d *SQLDB) Dialect() string { return d.dialect }

// DB is the database/sql handle.
func (d *SQLDB) DB() *sql.DB { return d.db }

func (d *SQLDB) target(ctx context.Context) (querier, func(), error) {
	if d.q != nil {
		return d.q, func() {}, nil
	}
	if d.dialect != "sqlite" {
		return d.db, func() {}, nil
	}
	d.mu.Lock()
	if d.conn == nil {
		conn, err := d.db.Conn(ctx)
		if err != nil {
			d.mu.Unlock()
			return nil, nil, err
		}
		if err := sqlitePragmas(ctx, conn); err != nil {
			conn.Close()
			d.mu.Unlock()
			return nil, nil, err
		}
		d.conn = conn
	}
	return d.conn, d.mu.Unlock, nil
}

func sqlitePragmas(ctx context.Context, conn *sql.Conn) error {
	// An in-memory database has no journal to change, and answers "memory".
	for _, pragma := range []string{"PRAGMA journal_mode = WAL", "PRAGMA synchronous = NORMAL", "PRAGMA busy_timeout = 5000"} {
		rows, err := conn.QueryContext(ctx, pragma)
		if err != nil {
			return err
		}
		rows.Close()
	}
	return nil
}

func (d *SQLDB) text(sql string, params []any) (string, []any, error) {
	switch d.dialect {
	case "postgres":
		return numberPlaceholders(sql), bindParams(params), nil
	case "mysql":
		text, err := mysqlText(sql, params)
		return text, nil, err
	}
	return sql, bindParams(params), nil
}

// bindParams gives the driver each value as the SDK binds it: whole numbers as integers.
func bindParams(params []any) []any {
	out := make([]any, len(params))
	for i, p := range params {
		switch v := p.(type) {
		case int:
			out[i] = int64(v)
		case float64:
			if v == math.Trunc(v) && math.Abs(v) <= js.MaxSafeInteger {
				out[i] = int64(v)
			} else {
				out[i] = v
			}
		case *string:
			if v == nil {
				out[i] = nil
			} else {
				out[i] = *v
			}
		case *int64:
			if v == nil {
				out[i] = nil
			} else {
				out[i] = *v
			}
		case *int:
			if v == nil {
				out[i] = nil
			} else {
				out[i] = int64(*v)
			}
		default:
			out[i] = p
		}
	}
	return out
}

// All runs a query and reads every row.
func (d *SQLDB) All(ctx context.Context, sql string, params ...any) ([]Row, error) {
	q, done, err := d.target(ctx)
	if err != nil {
		return nil, err
	}
	defer done()
	text, args, err := d.text(sql, params)
	if err != nil {
		return nil, err
	}
	rows, err := q.QueryContext(ctx, text, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		return nil, err
	}
	// A REAL (float4) reads as Postgres writes it in text, the shortest digits that read back
	// as a float4: 9.99, not 9.989999771118164.
	real := make([]bool, len(cols))
	if d.dialect == "postgres" {
		if types, err := rows.ColumnTypes(); err == nil {
			for i, t := range types {
				real[i] = strings.EqualFold(t.DatabaseTypeName(), "FLOAT4")
			}
		}
	}
	out := []Row{}
	for rows.Next() {
		values := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range values {
			ptrs[i] = &values[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return nil, err
		}
		row := make(Row, len(cols))
		for i, c := range cols {
			if b, ok := values[i].([]byte); ok {
				values[i] = string(b)
			}
			if f, ok := values[i].(float64); ok && real[i] {
				values[i], _ = strconv.ParseFloat(strconv.FormatFloat(float64(float32(f)), 'g', -1, 32), 64)
			}
			row[c] = values[i]
		}
		out = append(out, row)
	}
	return out, rows.Err()
}

// Run runs a statement.
func (d *SQLDB) Run(ctx context.Context, sql string, params ...any) error {
	_, err := d.Affected(ctx, sql, params...)
	return err
}

// Affected runs an UPDATE or DELETE and says how many rows it matched.
func (d *SQLDB) Affected(ctx context.Context, sql string, params ...any) (int64, error) {
	q, done, err := d.target(ctx)
	if err != nil {
		return 0, err
	}
	defer done()
	text, args, err := d.text(sql, params)
	if err != nil {
		return 0, err
	}
	result, err := q.ExecContext(ctx, text, args...)
	if err != nil {
		return 0, err
	}
	n, err := result.RowsAffected()
	if err != nil {
		return 0, nil
	}
	return n, nil
}

// Transaction runs fn in one transaction on one connection.
func (d *SQLDB) Transaction(ctx context.Context, fn func(Db) error) error {
	if d.q != nil {
		return fn(d)
	}
	if d.dialect == "sqlite" {
		q, done, err := d.target(ctx)
		if err != nil {
			return err
		}
		defer done()
		inner := &SQLDB{db: d.db, dialect: d.dialect, q: q}
		if _, err := q.ExecContext(ctx, "BEGIN"); err != nil {
			return err
		}
		if err := fn(inner); err != nil {
			_, _ = q.ExecContext(ctx, "ROLLBACK")
			return err
		}
		_, err = q.ExecContext(ctx, "COMMIT")
		return err
	}
	conn, err := d.db.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	if d.dialect == "mysql" {
		// As Postgres does by default: each statement sees what was committed before it began, and
		// InnoDB takes no gap locks, so two writers to neighbouring rows do not deadlock.
		if _, err := conn.ExecContext(ctx, "SET TRANSACTION ISOLATION LEVEL READ COMMITTED"); err != nil {
			return err
		}
	}
	tx, err := conn.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	inner := &SQLDB{db: d.db, dialect: d.dialect, q: tx}
	if err := fn(inner); err != nil {
		if rollback := tx.Rollback(); rollback != nil {
			// A connection still in its transaction must never go back to the pool.
			_ = conn.Raw(func(any) error { return driver.ErrBadConn })
		}
		return err
	}
	return tx.Commit()
}

// Exclusive runs fn holding a database-wide lock: Postgres's advisory lock,
// MySQL's named lock. SQLite's file lock already serialises its writers.
func (d *SQLDB) Exclusive(ctx context.Context, fn func(Db) error) error {
	if d.dialect == "sqlite" || d.q != nil {
		return fn(d)
	}
	conn, err := d.db.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	inner := &SQLDB{db: d.db, dialect: d.dialect, q: conn, statementTimeout: d.statementTimeout}
	if d.dialect == "postgres" {
		// Asked for again and again rather than waited on: a waiting statement would hold up an index being
		// built CONCURRENTLY by whoever has the lock, and the two would wait on each other for good.
		for {
			var ok bool
			if err := conn.QueryRowContext(ctx, "SELECT pg_try_advisory_lock($1)", migrationLock).Scan(&ok); err != nil {
				return err
			}
			if ok {
				break
			}
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(100 * time.Millisecond):
			}
		}
		// A lost connection ends its session, and the lock with it.
		defer conn.ExecContext(context.WithoutCancel(ctx), "SELECT pg_advisory_unlock($1)", migrationLock)
		return fn(inner)
	}
	for {
		var ok sql.NullInt64
		if err := conn.QueryRowContext(ctx, "SELECT GET_LOCK("+mysqlLock+", 5) AS ok").Scan(&ok); err != nil {
			return err
		}
		if !ok.Valid {
			return errors.New("Runlight: MySQL refused the lock for creating tables")
		}
		if ok.Int64 == 1 {
			break
		}
		// Not got within 5 seconds: another process is creating the tables. Ask again.
	}
	defer conn.ExecContext(context.WithoutCancel(ctx), "DO RELEASE_LOCK("+mysqlLock+")")
	// An index on a big table takes a while to build, so the build may run past the statement timeout.
	if d.statementTimeout > 0 {
		if err := d.limitStatements(ctx, conn, 0); err != nil {
			return err
		}
	}
	if err := fn(inner); err != nil {
		// The session may be left without its statement timeout, so the connection goes.
		_ = conn.Raw(func(any) error { return driver.ErrBadConn })
		return err
	}
	if d.statementTimeout > 0 {
		return d.limitStatements(ctx, conn, d.statementTimeout)
	}
	return nil
}

// limitStatements sets MySQL's statement timeout for a session, which MySQL
// and MariaDB name differently.
func (d *SQLDB) limitStatements(ctx context.Context, conn *sql.Conn, ms int) error {
	if d.mariadb == nil {
		var version string
		if err := conn.QueryRowContext(ctx, "SELECT VERSION() AS v").Scan(&version); err != nil {
			return err
		}
		m := strings.Contains(strings.ToLower(version), "mariadb")
		d.mariadb = &m
	}
	if *d.mariadb {
		_, err := conn.ExecContext(ctx, "SET SESSION max_statement_time = "+js.FormatNumber(float64(ms)/1000))
		return err
	}
	_, err := conn.ExecContext(ctx, "SET SESSION max_execution_time = "+strconv.Itoa(ms))
	return err
}

// Close closes the database when Runlight opened it, and lets the held
// SQLite connection go.
func (d *SQLDB) Close() error {
	d.mu.Lock()
	if d.conn != nil {
		d.conn.Close()
		d.conn = nil
	}
	d.mu.Unlock()
	if d.owned {
		return d.db.Close()
	}
	return nil
}

// numberPlaceholders turns ? placeholders into $1, $2, ..., leaving quoted text alone.
func numberPlaceholders(sql string) string {
	var b strings.Builder
	n := 0
	var quote rune
	for _, ch := range sql {
		switch {
		case quote != 0:
			if ch == quote {
				quote = 0
			}
			b.WriteRune(ch)
		case ch == '\'' || ch == '"':
			quote = ch
			b.WriteRune(ch)
		case ch == '?':
			n++
			b.WriteString("$" + strconv.Itoa(n))
		default:
			b.WriteRune(ch)
		}
	}
	return b.String()
}

// mysqlText is SQL written for SQLite and Postgres, as MySQL and MariaDB
// read it: each ? becomes its value, escaped as mysql2 escapes it; a
// "quoted" identifier is quoted with backticks; and a backslash inside
// 'text' is doubled, since MySQL reads it as an escape where standard SQL
// takes it literally.
func mysqlText(sql string, params []any) (string, error) {
	var b strings.Builder
	n := 0
	var quote rune
	for _, ch := range sql {
		switch {
		case quote != 0:
			switch {
			case ch == quote:
				quote = 0
				if ch == '"' {
					b.WriteByte('`')
				} else {
					b.WriteRune(ch)
				}
			case quote == '\'' && ch == '\\':
				b.WriteString(`\\`)
			case quote == '"' && ch == '`':
				b.WriteString("``")
			default:
				b.WriteRune(ch)
			}
		case ch == '\'' || ch == '"' || ch == '`':
			quote = ch
			if ch == '"' {
				b.WriteByte('`')
			} else {
				b.WriteRune(ch)
			}
		case ch == '?':
			if n >= len(params) {
				return "", errors.New("Runlight: a statement has more placeholders than values")
			}
			b.WriteString(mysqlEscape(params[n]))
			n++
		default:
			b.WriteRune(ch)
		}
	}
	if n != len(params) {
		return "", errors.New("Runlight: a statement has more values than placeholders")
	}
	return b.String(), nil
}

// mysqlEscape is a value as a MySQL literal, as mysql2's escape() writes the values Runlight binds.
func mysqlEscape(value any) string {
	switch v := bindParams([]any{value})[0].(type) {
	case nil:
		return "NULL"
	case bool:
		if v {
			return "true"
		}
		return "false"
	case int64:
		return strconv.FormatInt(v, 10)
	case float64:
		return js.FormatNumber(v)
	case string:
		var b strings.Builder
		b.WriteByte('\'')
		for i := 0; i < len(v); i++ {
			switch c := v[i]; c {
			case 0:
				b.WriteString(`\0`)
			case '\b':
				b.WriteString(`\b`)
			case '\t':
				b.WriteString(`\t`)
			case '\n':
				b.WriteString(`\n`)
			case '\r':
				b.WriteString(`\r`)
			case 0x1a:
				b.WriteString(`\Z`)
			case '"':
				b.WriteString(`\"`)
			case '\'':
				b.WriteString(`\'`)
			case '\\':
				b.WriteString(`\\`)
			default:
				b.WriteByte(c)
			}
		}
		b.WriteByte('\'')
		return b.String()
	}
	return mysqlEscape(fmt.Sprint(value))
}

// num is Number(value ?? 0) for a value a driver read, 0 when it is not finite.
func num(v any) float64 {
	var n float64
	switch t := v.(type) {
	case nil:
		return 0
	case int64:
		return float64(t)
	case int:
		return float64(t)
	case int32:
		return float64(t)
	case float64:
		n = t
	case float32:
		// A REAL as Postgres writes it in text, the shortest digits that read back: 9.99, not 9.989999771118164.
		n, _ = strconv.ParseFloat(strconv.FormatFloat(float64(t), 'g', -1, 32), 64)
	case bool:
		if t {
			return 1
		}
		return 0
	case string:
		n = js.Number(t)
	case []byte:
		n = js.Number(string(t))
	default:
		n = js.Number(fmt.Sprint(t))
	}
	if math.IsNaN(n) || math.IsInf(n, 0) {
		return 0
	}
	return n
}

// numInt is num as a whole number.
func numInt(v any) int64 { return int64(num(v)) }

// str is String(value) for a value a driver read.
func str(v any) string {
	switch t := v.(type) {
	case nil:
		return "null"
	case string:
		return t
	case []byte:
		return string(t)
	case int64:
		return strconv.FormatInt(t, 10)
	case float64:
		return js.FormatNumber(t)
	case bool:
		if t {
			return "true"
		}
		return "false"
	case time.Time:
		return t.String()
	}
	return fmt.Sprint(v)
}

// strOr is String(value ?? fallback).
func strOr(v any, fallback string) string {
	if v == nil {
		return fallback
	}
	return str(v)
}

// nullableInt is a column that may be NULL, as a number or nil.
func nullableInt(v any) *int64 {
	if v == nil {
		return nil
	}
	n := int64(js.ToNumber(stringOrNumber(v)))
	return &n
}

func stringOrNumber(v any) any {
	switch t := v.(type) {
	case []byte:
		return string(t)
	case int64:
		return float64(t)
	}
	return v
}
