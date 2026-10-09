package runlight

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"sync"

	"runlight.sh/go/internal/accounts"
	"runlight.sh/go/internal/js"
)

// Accounts: who may sign in, their password hashes, two-factor, invites, and
// the signed cookie that keeps them signed in. The standalone server always
// has them, and an app turns them on with RoutesOptions.Accounts.

// AccountError is a problem with an account change, to show the person
// making it, with a code and params the dashboard words in its own language.
type AccountError struct{ CodedError }

func (*AccountError) isRangeError() {}

func accountError(message, code string, params ...string) error {
	return &AccountError{coded(message, code, params...)}
}

// SessionCookie is the cookie that keeps someone signed in.
const SessionCookie = "runlight_session"

// SessionMs is thirty days, renewed on every sign-in.
const SessionMs = 30 * 86_400_000

// MinPassword is the shortest password taken.
const MinPassword = 10

// maxThrottled is the most sign-in keys the throttle remembers at once.
const maxThrottled = 10_000

// Roles: the owner can do everything, and nobody else can remove them or
// change their role; they can hand ownership to an admin. An admin can do
// everything the owner can apart from that. A member changes sites, goals,
// links, and the rest, but not people, the mail service, the assistant's
// settings, or deleting a site. A viewer reads every site's stats and
// changes nothing.
var roles = []string{"owner", "admin", "member", "viewer"}

// roleFrom is a stored role read back; anything unknown reads as a viewer, the least it could be.
func roleFrom(value any) string {
	s := str(value)
	if value != nil && contains(roles, s) {
		return s
	}
	return "viewer"
}

// User is an account.
type User struct {
	ID        string `json:"id"`
	Email     string `json:"email"`
	Hash      string `json:"hash"`
	Role      string `json:"role"`
	CreatedAt int64  `json:"createdAt"`
	// TwoFactor says sign-in also asks for a code from an authenticator app.
	TwoFactor bool `json:"twoFactor"`
	// RecoveryLeft is recovery codes not yet used.
	RecoveryLeft int `json:"recoveryLeft"`
}

// InviteMs is how long an invite link works.
const InviteMs = 7 * 86_400_000

// Invite is someone asked to join, until they choose a password. Only a hash of the link's code is kept.
type Invite struct {
	ID        string `json:"id"`
	Email     string `json:"email"`
	Role      string `json:"role"`
	InvitedBy string `json:"invitedBy"`
	CreatedAt int64  `json:"createdAt"`
	ExpiresAt int64  `json:"expiresAt"`
}

func codeHash(code string) string { return sha256Hex(code) }

var (
	decoyOnce sync.Once
	decoyHash string
)

// AccountStore keeps the accounts in the store's database.
type AccountStore struct {
	store  *Store
	secret string

	readyMu  sync.Mutex
	ready    bool
	turnMu   sync.Mutex
	checking sync.Map
}

// NewAccountStore keeps accounts in a store, signing with secret.
func NewAccountStore(store *Store, secret string) *AccountStore {
	return &AccountStore{store: store, secret: secret}
}

// turn makes changes to who has an account take turns, in this process and,
// on Postgres and MySQL, across processes, so two owners demoting each other
// at once cannot leave none, and a double-clicked invite makes one.
func (a *AccountStore) turn(ctx context.Context, fn func() error) error {
	a.turnMu.Lock()
	defer a.turnMu.Unlock()
	if ex, ok := a.store.db.(Exclusiver); ok {
		return ex.Exclusive(ctx, func(Db) error { return fn() })
	}
	return fn()
}

func (a *AccountStore) init(ctx context.Context) error {
	a.readyMu.Lock()
	defer a.readyMu.Unlock()
	if a.ready {
		return nil
	}
	db := a.store.db
	// Several processes starting at once create the tables one at a time.
	create := func(Db) error {
		// MySQL keys TEXT only by a prefix, so there the keyed columns are VARCHAR, in the binary collation the store's tables use.
		my := db.Dialect() == "mysql"
		strCol := func(n int) string {
			if my {
				return fmt.Sprintf("VARCHAR(%d)", n)
			}
			return "TEXT"
		}
		table := ""
		if my {
			table = " DEFAULT CHARSET=utf8mb4 COLLATE=" + MySQLCollation
		}
		if err := db.Run(ctx, `CREATE TABLE IF NOT EXISTS rl_users (id `+strCol(100)+` PRIMARY KEY, email `+strCol(320)+` NOT NULL UNIQUE, hash TEXT NOT NULL, created_at BIGINT NOT NULL)`+table); err != nil {
			return err
		}
		// Roles came later; a table from before them gains the column, and its accounts stay owners.
		var columns []Row
		var err error
		if db.Dialect() == "sqlite" {
			columns, err = db.All(ctx, `PRAGMA table_info(rl_users)`)
		} else {
			schema := "current_schema()"
			if my {
				schema = "DATABASE()"
			}
			columns, err = db.All(ctx, `SELECT column_name AS name FROM information_schema.columns WHERE table_name = 'rl_users' AND table_schema = `+schema)
		}
		if err != nil {
			return err
		}
		has := func(name string) bool {
			for _, c := range columns {
				if str(c["name"]) == name {
					return true
				}
			}
			return false
		}
		if !has("role") {
			if err := db.Run(ctx, `ALTER TABLE rl_users ADD COLUMN role `+strCol(20)+` NOT NULL DEFAULT 'owner'`); err != nil {
				return err
			}
		}
		// Two-factor came later still: the secret (sealed), one being set up, recovery code hashes, and the last code's step.
		for _, col := range [][2]string{{"totp_secret", "TEXT"}, {"totp_pending", "TEXT"}, {"totp_recovery", "TEXT"}, {"totp_step", "BIGINT"}} {
			if !has(col[0]) {
				if err := db.Run(ctx, `ALTER TABLE rl_users ADD COLUMN `+col[0]+` `+col[1]); err != nil {
					return err
				}
			}
		}
		if err := db.Run(ctx, `CREATE TABLE IF NOT EXISTS rl_invites (id `+strCol(100)+` PRIMARY KEY, email `+strCol(320)+` NOT NULL UNIQUE, role `+strCol(20)+` NOT NULL, code_hash `+strCol(128)+` NOT NULL UNIQUE, invited_by `+strCol(100)+` NOT NULL, created_at BIGINT NOT NULL, expires_at BIGINT NOT NULL)`+table); err != nil {
			return err
		}
		// A server has one owner. One from before, with several, keeps the first and the rest become admins.
		// Invites to join as an owner become invites as an admin.
		owners, err := db.All(ctx, `SELECT id FROM rl_users WHERE role = 'owner' ORDER BY created_at, id`)
		if err != nil {
			return err
		}
		for i, extra := range owners {
			if i == 0 {
				continue
			}
			if err := db.Run(ctx, `UPDATE rl_users SET role = 'admin' WHERE id = ?`, str(extra["id"])); err != nil {
				return err
			}
		}
		return db.Run(ctx, `UPDATE rl_invites SET role = 'admin' WHERE role = 'owner'`)
	}
	var err error
	if ex, ok := db.(Exclusiver); ok {
		err = ex.Exclusive(ctx, create)
	} else {
		err = create(db)
	}
	if err == nil {
		a.ready = true
	}
	return err
}

func recoveryList(value any) []string {
	out := []string{}
	if value == nil || str(value) == "" {
		return out
	}
	parsed, err := js.Parse(str(value))
	if err != nil {
		return out
	}
	for _, v := range js.Arr(parsed) {
		out = append(out, js.String(v))
	}
	return out
}

func (a *AccountStore) row(r Row) User {
	return User{ID: str(r["id"]), Email: str(r["email"]), Hash: str(r["hash"]), Role: roleFrom(r["role"]), CreatedAt: numInt(r["created_at"]),
		TwoFactor: r["totp_secret"] != nil && str(r["totp_secret"]) != "", RecoveryLeft: len(recoveryList(r["totp_recovery"]))}
}

// seal seals a two-factor secret with the install's secret, so the database alone cannot make codes.
func (a *AccountStore) seal(text string) (string, error) { return accounts.SealText(text, a.secret) }

func (a *AccountStore) unseal(sealed string) (string, bool) { return accounts.UnsealText(sealed, a.secret) }

// StartTwoFactor starts turning on two-factor: a new secret, kept aside until a code from it is confirmed.
func (a *AccountStore) StartTwoFactor(ctx context.Context, id string) (string, error) {
	if err := a.init(ctx); err != nil {
		return "", err
	}
	secret := accounts.Base32(accounts.RandomBytes(20))
	sealed, err := a.seal(secret)
	if err != nil {
		return "", err
	}
	return secret, a.store.db.Run(ctx, `UPDATE rl_users SET totp_pending = ? WHERE id = ?`, sealed, id)
}

func recoveryHashes(codes []string) string {
	hashes := make([]string, len(codes))
	for i, c := range codes {
		hashes[i] = accounts.RecoveryHash(c)
	}
	return js.Stringify(hashes)
}

// ConfirmTwoFactor turns two-factor on once a code from the new secret
// checks out, and returns ten recovery codes, shown once; nil when the code is wrong.
func (a *AccountStore) ConfirmTwoFactor(ctx context.Context, id, code string, now int64) ([]string, error) {
	if err := a.init(ctx); err != nil {
		return nil, err
	}
	rows, err := a.store.db.All(ctx, `SELECT totp_pending FROM rl_users WHERE id = ?`, id)
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 || rows[0]["totp_pending"] == nil || str(rows[0]["totp_pending"]) == "" {
		return nil, nil
	}
	secret, ok := a.unseal(str(rows[0]["totp_pending"]))
	if !ok {
		return nil, nil
	}
	if _, matched, err := accounts.MatchStep(secret, code, now, -1); err != nil || !matched {
		return nil, err
	}
	recovery := accounts.RecoveryCodes()
	sealed, err := a.seal(secret)
	if err != nil {
		return nil, err
	}
	// The code that turned it on is not marked used, so signing in again at once with it works.
	return recovery, a.store.db.Run(ctx, `UPDATE rl_users SET totp_secret = ?, totp_pending = NULL, totp_recovery = ?, totp_step = NULL WHERE id = ?`, sealed, recoveryHashes(recovery), id)
}

// NewRecoveryCodes are new recovery codes in place of the old ones.
func (a *AccountStore) NewRecoveryCodes(ctx context.Context, id string) ([]string, error) {
	if err := a.init(ctx); err != nil {
		return nil, err
	}
	recovery := accounts.RecoveryCodes()
	return recovery, a.store.db.Run(ctx, `UPDATE rl_users SET totp_recovery = ? WHERE id = ?`, recoveryHashes(recovery), id)
}

// CancelTwoFactorSetup drops a set-up left half done, after too many wrong codes, so it must start again with the password.
func (a *AccountStore) CancelTwoFactorSetup(ctx context.Context, id string) error {
	if err := a.init(ctx); err != nil {
		return err
	}
	return a.store.db.Run(ctx, `UPDATE rl_users SET totp_pending = NULL WHERE id = ?`, id)
}

// DisableTwoFactor turns two-factor off.
func (a *AccountStore) DisableTwoFactor(ctx context.Context, id string) error {
	if err := a.init(ctx); err != nil {
		return err
	}
	return a.store.db.Run(ctx, `UPDATE rl_users SET totp_secret = NULL, totp_pending = NULL, totp_recovery = NULL, totp_step = NULL WHERE id = ?`, id)
}

var (
	sixDigits = regexp.MustCompile(`^\d{6}$`)
	jsSpaces  = regexp.MustCompile(`[\t\n\v\f\r \x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}\x{feff}]`)
)

// CheckSecondFactor checks a six-digit code, or a recovery code, for an
// account with two-factor on. A code works once: one already used, or
// older, is refused, and a recovery code is crossed off.
func (a *AccountStore) CheckSecondFactor(ctx context.Context, id, code string, now int64) (bool, error) {
	// One check at a time per account, so two sign-ins at once cannot both use the same code.
	m, _ := a.checking.LoadOrStore(id, &sync.Mutex{})
	m.(*sync.Mutex).Lock()
	defer m.(*sync.Mutex).Unlock()
	if err := a.init(ctx); err != nil {
		return false, err
	}
	rows, err := a.store.db.All(ctx, `SELECT totp_secret, totp_recovery, totp_step FROM rl_users WHERE id = ?`, id)
	if err != nil || len(rows) == 0 || rows[0]["totp_secret"] == nil || str(rows[0]["totp_secret"]) == "" {
		return false, err
	}
	row := rows[0]
	given := jsTrim(code)
	digits := jsSpaces.ReplaceAllString(given, "")
	if sixDigits.MatchString(digits) {
		secret, ok := a.unseal(str(row["totp_secret"]))
		if !ok {
			return false, nil
		}
		after := int64(-1)
		if row["totp_step"] != nil {
			after = numInt(row["totp_step"])
		}
		step, matched, err := accounts.MatchStep(secret, digits, now, after)
		if err != nil || !matched {
			return false, err
		}
		return true, a.store.db.Run(ctx, `UPDATE rl_users SET totp_step = ? WHERE id = ?`, step, id)
	}
	hashes := recoveryList(row["totp_recovery"])
	at := indexOf(hashes, accounts.RecoveryHash(given))
	if at < 0 {
		return false, nil
	}
	hashes = append(hashes[:at], hashes[at+1:]...)
	return true, a.store.db.Run(ctx, `UPDATE rl_users SET totp_recovery = ? WHERE id = ?`, js.Stringify(hashes), id)
}

// PendingFor is a short-lived ticket naming an account whose password
// checked out and which still owes a code. Signed like a session, so it cannot be made up.
func (a *AccountStore) PendingFor(user User, now int64) (string, error) {
	return a.ticket("pending", user, now+5*60_000)
}

// DecoyFor is a ticket that looks and acts like PendingFor's, except that no
// code ever passes with it. A wrong password gets one once an account with
// two-factor has had too many, so the answer never tells a right password.
func (a *AccountStore) DecoyFor(user User, now int64) (string, error) {
	return a.ticket("decoy", user, now+5*60_000)
}

// FromPending is the account a code-step ticket names, and whether a right code may sign in with it.
func (a *AccountStore) FromPending(ctx context.Context, value string, now int64) (*User, bool, error) {
	user, err := a.fromTicket(ctx, "pending", value, now)
	if err != nil || user != nil {
		return user, user != nil, err
	}
	decoy, err := a.fromTicket(ctx, "decoy", value, now)
	return decoy, false, err
}

// LinkFor is a ticket for a sign-in link sent by email, for fifteen minutes. A new password withdraws it.
func (a *AccountStore) LinkFor(user User, now int64) (string, error) {
	return a.ticket("link", user, now+15*60_000)
}

// FromLink is the account a sign-in link is for. A link works once: using
// it withdraws it, and every link sent before it. Uses take turns, so a link
// opened twice at once lets one in.
func (a *AccountStore) FromLink(ctx context.Context, value string, now int64) (*User, error) {
	user, err := a.fromTicket(ctx, "link", value, now)
	if err != nil || user == nil {
		return nil, err
	}
	expires := js.Number(strings.Split(value, ".")[1])
	var out *User
	err = a.turn(ctx, func() error {
		key := "login-link-used:" + user.ID
		used, ok, err := a.store.Setting(ctx, key)
		if err != nil {
			return err
		}
		last := 0.0
		if ok {
			last = js.Number(used)
		}
		if expires <= last {
			return nil
		}
		out = user
		return a.store.SetSetting(ctx, key, ptr(js.FormatNumber(expires)))
	})
	return out, err
}

func (a *AccountStore) ticket(kind string, user User, expires int64) (string, error) {
	body := user.ID + "." + strconv.FormatInt(expires, 10)
	signature, err := a.sign(kind+"."+body, user.Hash)
	return body + "." + signature, err
}

func (a *AccountStore) fromTicket(ctx context.Context, kind, value string, now int64) (*User, error) {
	parts := strings.Split(value, ".")
	if len(parts) < 3 || parts[0] == "" || parts[1] == "" || parts[2] == "" || !(js.Number(parts[1]) > float64(now)) {
		return nil, nil
	}
	user, err := a.ByID(ctx, parts[0])
	if err != nil || user == nil {
		return nil, err
	}
	signature, err := a.sign(kind+"."+parts[0]+"."+parts[1], user.Hash)
	if err != nil {
		return nil, err
	}
	if accounts.SameText(signature, parts[2]) {
		return user, nil
	}
	return nil, nil
}

// Count is how many accounts there are.
func (a *AccountStore) Count(ctx context.Context) (int64, error) {
	if err := a.init(ctx); err != nil {
		return 0, err
	}
	rows, err := a.store.db.All(ctx, `SELECT COUNT(*) AS n FROM rl_users`)
	if err != nil || len(rows) == 0 {
		return 0, err
	}
	return numInt(rows[0]["n"]), nil
}

// ByEmail is the account with an email address.
func (a *AccountStore) ByEmail(ctx context.Context, email string) (*User, error) {
	if err := a.init(ctx); err != nil {
		return nil, err
	}
	rows, err := a.store.db.All(ctx, `SELECT * FROM rl_users WHERE email = ?`, lower(jsTrim(email)))
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	u := a.row(rows[0])
	return &u, nil
}

// ByID is the account with an id.
func (a *AccountStore) ByID(ctx context.Context, id string) (*User, error) {
	if err := a.init(ctx); err != nil {
		return nil, err
	}
	rows, err := a.store.db.All(ctx, `SELECT * FROM rl_users WHERE id = ?`, id)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	u := a.row(rows[0])
	return &u, nil
}

// List is every account, oldest first.
func (a *AccountStore) List(ctx context.Context) ([]User, error) {
	if err := a.init(ctx); err != nil {
		return nil, err
	}
	rows, err := a.store.db.All(ctx, `SELECT * FROM rl_users ORDER BY created_at, id`)
	if err != nil {
		return nil, err
	}
	out := []User{}
	for _, r := range rows {
		out = append(out, a.row(r))
	}
	return out, nil
}

func findUser(users []User, id string) *User {
	for i := range users {
		if users[i].ID == id {
			return &users[i]
		}
	}
	return nil
}

// SetRole changes a role. The owner's never changes here, and nobody becomes the owner here: see HandOver.
func (a *AccountStore) SetRole(ctx context.Context, id, role string) (User, error) {
	// The tables first: making them takes the same lock as a turn.
	if err := a.init(ctx); err != nil {
		return User{}, err
	}
	var out User
	err := a.turn(ctx, func() error {
		users, err := a.List(ctx)
		if err != nil {
			return err
		}
		user := findUser(users, id)
		if user == nil {
			return accountError("Unknown account", "unknown_account")
		}
		if user.Role == "owner" {
			return accountError("Only the owner can change their own role, by handing ownership to an admin", "owner_protected")
		}
		if role == "owner" {
			return accountError("Ownership is handed over by the owner", "owner_hand_over")
		}
		if err := a.store.db.Run(ctx, `UPDATE rl_users SET role = ? WHERE id = ?`, role, id); err != nil {
			return err
		}
		out = *user
		out.Role = role
		return nil
	})
	return out, err
}

// HandOver makes an admin the owner, and the owner an admin.
func (a *AccountStore) HandOver(ctx context.Context, from, to string) error {
	if err := a.init(ctx); err != nil {
		return err
	}
	return a.turn(ctx, func() error {
		users, err := a.List(ctx)
		if err != nil {
			return err
		}
		owner, next := findUser(users, from), findUser(users, to)
		if owner == nil || owner.Role != "owner" {
			return accountError("Only the owner can hand over ownership", "owner_hand_over")
		}
		if next == nil {
			return accountError("Unknown account", "unknown_account")
		}
		if next.Role != "admin" {
			return accountError("Make them an admin first", "owner_needs_admin")
		}
		if err := a.store.db.Run(ctx, `UPDATE rl_users SET role = 'owner' WHERE id = ?`, to); err != nil {
			return err
		}
		return a.store.db.Run(ctx, `UPDATE rl_users SET role = 'admin' WHERE id = ?`, from)
	})
}

// Remove removes an account. The owner cannot be removed.
func (a *AccountStore) Remove(ctx context.Context, id string) error {
	if err := a.init(ctx); err != nil {
		return err
	}
	return a.turn(ctx, func() error {
		users, err := a.List(ctx)
		if err != nil {
			return err
		}
		user := findUser(users, id)
		if user == nil {
			return accountError("Unknown account", "unknown_account")
		}
		if user.Role == "owner" {
			return accountError("The owner cannot be removed", "owner_protected")
		}
		if err := a.store.db.Run(ctx, `DELETE FROM rl_users WHERE id = ?`, id); err != nil {
			return err
		}
		return a.store.SetSetting(ctx, "login-link-used:"+id, nil)
	})
}

// SetPassword makes an account, or sets a new password on an existing one.
// A new account is the owner when it is the first, and otherwise an admin
// unless a role is given ("" for none), since a server has one owner.
func (a *AccountStore) SetPassword(ctx context.Context, email, password string, now int64, role string) (User, error) {
	if err := a.init(ctx); err != nil {
		return User{}, err
	}
	address := lower(jsTrim(email))
	if !emailPattern.MatchString(address) {
		return User{}, accountError("Enter an email address", "email_invalid")
	}
	if len16(password) < MinPassword {
		return User{}, accountError(fmt.Sprintf("Use a password of at least %d characters", MinPassword), "password_short", "min", strconv.Itoa(MinPassword))
	}
	hash, err := accounts.HashPassword(password)
	if err != nil {
		return User{}, err
	}
	existing, err := a.ByEmail(ctx, address)
	if err != nil {
		return User{}, err
	}
	if existing != nil {
		if err := a.store.db.Run(ctx, `UPDATE rl_users SET hash = ? WHERE id = ?`, hash, existing.ID); err != nil {
			return User{}, err
		}
		existing.Hash = hash
		return *existing, nil
	}
	count, err := a.Count(ctx)
	if err != nil {
		return User{}, err
	}
	first := count == 0
	given := role
	if given == "" {
		given = "admin"
		if first {
			given = "owner"
		}
	}
	if given == "owner" && !first {
		given = "admin"
	}
	user := User{ID: accounts.Hex(accounts.RandomBytes(12)), Email: address, Hash: hash, Role: given, CreatedAt: now}
	return user, a.store.db.Run(ctx, `INSERT INTO rl_users (id, email, hash, role, created_at) VALUES (?, ?, ?, ?, ?)`, user.ID, user.Email, user.Hash, user.Role, user.CreatedAt)
}

func inviteRow(r Row) Invite {
	return Invite{ID: str(r["id"]), Email: str(r["email"]), Role: roleFrom(r["role"]), InvitedBy: str(r["invited_by"]), CreatedAt: numInt(r["created_at"]), ExpiresAt: numInt(r["expires_at"])}
}

// Invites are invites that still work, newest first. Expired ones are cleared on the way.
func (a *AccountStore) Invites(ctx context.Context, now int64) ([]Invite, error) {
	if err := a.init(ctx); err != nil {
		return nil, err
	}
	if err := a.store.db.Run(ctx, `DELETE FROM rl_invites WHERE expires_at <= ?`, now); err != nil {
		return nil, err
	}
	rows, err := a.store.db.All(ctx, `SELECT * FROM rl_invites ORDER BY created_at DESC, id`)
	if err != nil {
		return nil, err
	}
	out := []Invite{}
	for _, r := range rows {
		out = append(out, inviteRow(r))
	}
	return out, nil
}

// InviteSomeone invites someone to join with a role, and returns the code
// for their link. Asking again replaces the earlier invite, so only the
// newest link works.
func (a *AccountStore) InviteSomeone(ctx context.Context, email, role, invitedBy string, now int64) (Invite, string, error) {
	if err := a.init(ctx); err != nil {
		return Invite{}, "", err
	}
	var invite Invite
	var code string
	err := a.turn(ctx, func() error {
		address := lower(jsTrim(email))
		if !emailPattern.MatchString(address) {
			return accountError("Enter an email address", "email_invalid")
		}
		existing, err := a.ByEmail(ctx, address)
		if err != nil {
			return err
		}
		if existing != nil {
			return accountError(address+" already has an account", "account_exists", "email", address)
		}
		code = accounts.Base64url(accounts.RandomBytes(24))
		invite = Invite{ID: accounts.Hex(accounts.RandomBytes(12)), Email: address, Role: role, InvitedBy: invitedBy, CreatedAt: now, ExpiresAt: now + InviteMs}
		if err := a.store.db.Run(ctx, `DELETE FROM rl_invites WHERE email = ?`, address); err != nil {
			return err
		}
		return a.store.db.Run(ctx, `INSERT INTO rl_invites (id, email, role, code_hash, invited_by, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
			invite.ID, invite.Email, invite.Role, codeHash(code), invite.InvitedBy, invite.CreatedAt, invite.ExpiresAt)
	})
	return invite, code, err
}

var inviteCode = regexp.MustCompile(`^[A-Za-z0-9_-]{20,64}$`)

// InviteByCode is the invite a link's code belongs to, while it still works.
func (a *AccountStore) InviteByCode(ctx context.Context, code string, now int64) (*Invite, error) {
	if err := a.init(ctx); err != nil {
		return nil, err
	}
	if !inviteCode.MatchString(code) {
		return nil, nil
	}
	rows, err := a.store.db.All(ctx, `SELECT * FROM rl_invites WHERE code_hash = ? AND expires_at > ?`, codeHash(code), now)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	i := inviteRow(rows[0])
	return &i, nil
}

// CancelInvite withdraws an invite; false when there was none.
func (a *AccountStore) CancelInvite(ctx context.Context, id string) (bool, error) {
	if err := a.init(ctx); err != nil {
		return false, err
	}
	rows, err := a.store.db.All(ctx, `SELECT id FROM rl_invites WHERE id = ?`, id)
	if err != nil {
		return false, err
	}
	return len(rows) > 0, a.store.db.Run(ctx, `DELETE FROM rl_invites WHERE id = ?`, id)
}

// AcceptInvite turns an invite into an account with the password its person chose. The link then stops working.
func (a *AccountStore) AcceptInvite(ctx context.Context, code, password string, now int64) (User, error) {
	invite, err := a.InviteByCode(ctx, code, now)
	if err != nil {
		return User{}, err
	}
	if invite == nil {
		return User{}, accountError("This invite has expired or was already used. Ask for a new one.", "invite_gone")
	}
	existing, err := a.ByEmail(ctx, invite.Email)
	if err != nil {
		return User{}, err
	}
	if existing != nil {
		return User{}, accountError(invite.Email+" already has an account", "account_exists", "email", invite.Email)
	}
	user, err := a.SetPassword(ctx, invite.Email, password, now, invite.Role)
	if err != nil {
		return User{}, err
	}
	return user, a.store.db.Run(ctx, `DELETE FROM rl_invites WHERE id = ?`, invite.ID)
}

// SignIn is the account for an email and password, or nil. Takes the same time either way.
func (a *AccountStore) SignIn(ctx context.Context, email, password string) (*User, error) {
	user, err := a.ByEmail(ctx, email)
	if err != nil {
		return nil, err
	}
	if user == nil {
		decoyOnce.Do(func() { decoyHash, _ = accounts.HashPassword(accounts.Hex(accounts.RandomBytes(16))) })
		accounts.CheckPassword(password, decoyHash)
		return nil, nil
	}
	if accounts.CheckPassword(password, user.Hash) {
		return user, nil
	}
	return nil, nil
}

// SessionFor is a cookie value naming the user and when it expires, signed
// with the server's secret and the user's password hash, so changing a
// password signs out every other browser.
func (a *AccountStore) SessionFor(user User, now int64) (string, error) {
	body := user.ID + "." + strconv.FormatInt(now+SessionMs, 10)
	signature, err := a.sign(body, sessionKey(user))
	return body + "." + signature, err
}

// FromSession is the signed-in user for a cookie value, or nil.
func (a *AccountStore) FromSession(ctx context.Context, value string, now int64) (*User, error) {
	parts := strings.Split(value, ".")
	if len(parts) < 3 || parts[0] == "" || parts[1] == "" || parts[2] == "" || !(js.Number(parts[1]) > float64(now)) {
		return nil, nil
	}
	user, err := a.ByID(ctx, parts[0])
	if err != nil || user == nil {
		return nil, err
	}
	signature, err := a.sign(parts[0]+"."+parts[1], sessionKey(*user))
	if err != nil {
		return nil, err
	}
	if accounts.SameText(signature, parts[2]) {
		return user, nil
	}
	return nil, nil
}

// sessionKey is what a session is signed with: the password hash, and
// whether two-factor is on, so changing either ends other sessions.
func sessionKey(user User) string {
	if user.TwoFactor {
		return user.Hash + ".2fa"
	}
	return user.Hash
}

// DeviceFor is a long-lived mark for a browser that signed in to an
// account. With it, failed tries by others against that account cannot lock
// this browser out; the per-address limit still applies. A new password withdraws it.
func (a *AccountStore) DeviceFor(user User) (string, error) {
	signature, err := a.sign("device."+user.ID, user.Hash)
	return user.ID + "." + signature, err
}

// TrustsDevice reports whether a device mark is this account's.
func (a *AccountStore) TrustsDevice(value string, user User) bool {
	parts := strings.Split(value, ".")
	if parts[0] != user.ID || len(parts) < 2 || parts[1] == "" {
		return false
	}
	signature, err := a.sign("device."+user.ID, user.Hash)
	return err == nil && accounts.SameText(signature, parts[1])
}

func (a *AccountStore) sign(body, hash string) (string, error) {
	return accounts.Signature(a.secret, body, hash)
}

// Throttle counts failed sign-ins under a key and refuses more than a few
// in a while. Keys are hashed with a key made at start, so the map never
// holds an address or an email as it was given.
type Throttle struct {
	mu       sync.Mutex
	limit    int
	windowMs int64
	salt     []byte
	failures map[string]*throttled
	order    []string
}

type throttled struct {
	count int
	until int64
}

// NewThrottle refuses more than limit failures in windowMs (10 in 15 minutes when zero).
func NewThrottle(limit int, windowMs int64) *Throttle {
	if limit == 0 {
		limit = 10
	}
	if windowMs == 0 {
		windowMs = 15 * 60_000
	}
	return &Throttle{limit: limit, windowMs: windowMs, salt: accounts.RandomBytes(16), failures: map[string]*throttled{}}
}

func (t *Throttle) id(key string) string {
	m := hmac.New(sha256.New, t.salt)
	m.Write([]byte(key))
	return accounts.Base64url(m.Sum(nil))[:22]
}

func (t *Throttle) isBlocked(id string, now int64) bool {
	entry := t.failures[id]
	if entry == nil || entry.until <= now {
		return false
	}
	return entry.count >= t.limit
}

// Blocked reports whether a key is at its limit.
func (t *Throttle) Blocked(key string, now int64) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.isBlocked(t.id(key), now)
}

// Take counts a try before the slow check it guards, so a burst that
// arrives while earlier tries are still being checked cannot get past the
// limit. False, counting nothing, when the key is already at its limit. A
// try that turns out right is taken back with Forgive.
func (t *Throttle) Take(key string, now int64) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	id := t.id(key)
	if t.isBlocked(id, now) {
		return false
	}
	t.count(id, now)
	return true
}

// Forgive takes back one counted try, for one that turned out right.
func (t *Throttle) Forgive(key string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if entry := t.failures[t.id(key)]; entry != nil && entry.count > 0 {
		entry.count--
	}
}

// Fail counts a failure.
func (t *Throttle) Fail(key string, now int64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.count(t.id(key), now)
}

func (t *Throttle) count(id string, now int64) {
	entry := t.failures[id]
	if entry == nil || entry.until <= now {
		t.delete(id)
		t.failures[id] = &throttled{count: 1, until: now + t.windowMs}
		t.order = append(t.order, id)
	} else {
		entry.count++
	}
	// Expired entries go first, then the oldest that are not blocked, and blocked ones last, so the map
	// has a hard ceiling and a flood of made-up names cannot wipe out a real block.
	if len(t.failures) > maxThrottled {
		for _, k := range append([]string(nil), t.order...) {
			if t.failures[k].until <= now {
				t.delete(k)
			}
		}
		for _, k := range append([]string(nil), t.order...) {
			if len(t.failures) <= maxThrottled {
				break
			}
			if t.failures[k].count < t.limit {
				t.delete(k)
			}
		}
		for _, k := range append([]string(nil), t.order...) {
			if len(t.failures) <= maxThrottled {
				break
			}
			t.delete(k)
		}
	}
}

func (t *Throttle) delete(id string) {
	if _, ok := t.failures[id]; !ok {
		return
	}
	delete(t.failures, id)
	for i, k := range t.order {
		if k == id {
			t.order = append(t.order[:i], t.order[i+1:]...)
			break
		}
	}
}

// Clear forgets a key's failures.
func (t *Throttle) Clear(key string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.delete(t.id(key))
}
