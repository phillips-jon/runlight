using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Runlight.Db;
using Runlight.Store;

namespace Runlight.Accounts;

/// <summary>
/// Accounts: who may sign in, their password hashes, two-factor, invites, and the signed cookie that keeps them
/// signed in. The standalone server always has them, and an app turns them on with routes accounts: true.
/// </summary>
/// <remarks>
/// The owner can do everything, and nobody else can remove them or change their role; they can hand ownership to an
/// admin. An admin can do everything the owner can apart from that. A member changes sites, goals, links, and the
/// rest, but not people, the mail service, the assistant's settings, or deleting a site. A viewer reads every site's
/// stats and changes nothing.
///
/// A user is a <see cref="JsObject"/> with the TypeScript User's keys: id, email, hash, role ("owner", "admin",
/// "member", or "viewer"), createdAt, twoFactor (whether sign-in also asks for a code), and recoveryLeft (recovery
/// codes not yet used). An invite has id, email, role, invitedBy, createdAt, and expiresAt.
/// </remarks>
public sealed class Accounts
{
    public const string SessionCookie = "runlight_session";

    /// <summary>Thirty days, renewed on every sign-in.</summary>
    public const long SessionMs = 30 * 86_400_000L;

    public const int MinPassword = 10;

    /// <summary>The most sign-in keys the throttle remembers at once.</summary>
    public const int MaxThrottled = 10_000;

    /// <summary>How long an invite link works.</summary>
    public const long InviteMs = 7 * 86_400_000L;

    public static readonly IReadOnlyList<string> Roles = ["owner", "admin", "member", "viewer"];

    private const string Space = "\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF";

    /// <summary>What passes for an email address, with JavaScript's \s.</summary>
    private static readonly Regex Email = new("^[^" + Space + "@<>\"]+@[^" + Space + "@<>\"]+\\.[^" + Space + "@<>\"]+\\z", RegexOptions.CultureInvariant);

    private static readonly Regex InviteCode = new("^[A-Za-z0-9_-]{20,64}\\z", RegexOptions.CultureInvariant);

    /// <summary>A password checked against nothing, so a wrong email takes as long as a wrong password. Made when first needed.</summary>
    private static string? _decoy;

    private readonly SqlStore _store;
    private readonly string _secret;
    private bool _ready;

    public Accounts(SqlStore store, string secret)
    {
        _store = store;
        _secret = secret;
    }

    private IDb Db => _store.Db;

    /// <summary>A stored role read back; anything unknown reads as a viewer, the least it could be.</summary>
    public static string RoleFrom(object? value) => value is string s && Roles.Contains(s) ? s : "viewer";

    /// <summary>
    /// Changes to who has an account take turns: on Postgres and MySQL across processes, through the database's
    /// lock, so two owners demoting each other at once cannot leave none, and a double-clicked invite makes one.
    /// </summary>
    private Task<T> TurnAsync<T>(Func<Task<T>> fn, CancellationToken cancellationToken) =>
        Db.ExclusiveAsync(_ => fn(), cancellationToken);

    private async Task InitAsync(CancellationToken cancellationToken)
    {
        if (_ready)
        {
            return;
        }
        // Several processes starting at once create the tables one at a time.
        await Db.ExclusiveAsync(
            async db =>
            {
                // MySQL keys TEXT only by a prefix, so there the keyed columns are VARCHAR, in the binary collation the store's tables use.
                bool my = db.Dialect == "mysql";
                string Str(int n) => my ? "VARCHAR(" + Js.Str(n) + ")" : "TEXT";
                string table = my ? " DEFAULT CHARSET=utf8mb4 COLLATE=" + SqlStore.MysqlCollation : "";
                await db.RunAsync("CREATE TABLE IF NOT EXISTS rl_users (id " + Str(100) + " PRIMARY KEY, email " + Str(320) + " NOT NULL UNIQUE, hash TEXT NOT NULL, created_at BIGINT NOT NULL)" + table, null, cancellationToken).ConfigureAwait(false);
                // Roles came later; a table from before them gains the column, and its accounts stay owners.
                var columns = db.Dialect == "sqlite"
                    ? await db.AllAsync("PRAGMA table_info(rl_users)", null, cancellationToken).ConfigureAwait(false)
                    : await db.AllAsync("SELECT column_name AS name FROM information_schema.columns WHERE table_name = 'rl_users' AND table_schema = " + (my ? "DATABASE()" : "current_schema()"), null, cancellationToken).ConfigureAwait(false);
                var names = columns.Select(c => Sql.S(c.Get("name") ?? c.Get("NAME"))).ToList();
                if (!names.Contains("role"))
                {
                    await db.RunAsync("ALTER TABLE rl_users ADD COLUMN role " + Str(20) + " NOT NULL DEFAULT 'owner'", null, cancellationToken).ConfigureAwait(false);
                }
                // Two-factor came later still: the secret (sealed), one being set up, recovery code hashes, and the last code's step.
                foreach (var (name, type) in new[] { ("totp_secret", "TEXT"), ("totp_pending", "TEXT"), ("totp_recovery", "TEXT"), ("totp_step", "BIGINT") })
                {
                    if (!names.Contains(name))
                    {
                        await db.RunAsync("ALTER TABLE rl_users ADD COLUMN " + name + " " + type, null, cancellationToken).ConfigureAwait(false);
                    }
                }
                await db.RunAsync(
                    "CREATE TABLE IF NOT EXISTS rl_invites (id " + Str(100) + " PRIMARY KEY, email " + Str(320) + " NOT NULL UNIQUE, role " + Str(20) + " NOT NULL, code_hash " + Str(128) + " NOT NULL UNIQUE, invited_by " + Str(100) + " NOT NULL, created_at BIGINT NOT NULL, expires_at BIGINT NOT NULL)" + table,
                    null,
                    cancellationToken).ConfigureAwait(false);
                // A server has one owner. One from before, with several, keeps the first and the rest become admins,
                // who can still do everything but remove the owner. Invites to join as an owner become invites as an admin.
                var owners = await db.AllAsync("SELECT id FROM rl_users WHERE role = 'owner' ORDER BY created_at, id", null, cancellationToken).ConfigureAwait(false);
                foreach (var extra in owners.Skip(1))
                {
                    await db.RunAsync("UPDATE rl_users SET role = 'admin' WHERE id = ?", [Sql.S(extra.Get("id"))], cancellationToken).ConfigureAwait(false);
                }
                await db.RunAsync("UPDATE rl_invites SET role = 'admin' WHERE role = 'owner'", null, cancellationToken).ConfigureAwait(false);
                return true;
            },
            cancellationToken).ConfigureAwait(false);
        _ready = true;
    }

    private static List<object?> RecoveryList(object? stored) =>
        Js.Truthy(stored) && Json.Parse(Sql.S(stored)) is List<object?> list ? list : [];

    private static JsObject Row(JsObject r) => new()
    {
        ["id"] = Sql.S(r.Get("id")),
        ["email"] = Sql.S(r.Get("email")),
        ["hash"] = Sql.S(r.Get("hash")),
        ["role"] = RoleFrom(r.Get("role")),
        ["createdAt"] = Js.Number(r.Get("created_at")),
        ["twoFactor"] = Js.Truthy(r.Get("totp_secret")),
        ["recoveryLeft"] = (long)RecoveryList(r.Get("totp_recovery")).Count,
    };

    private static string Id(JsObject user) => user.Str("id")!;

    private static string UserHash(JsObject user) => user.Str("hash")!;

    /// <summary>Seals a two-factor secret with the install's secret, so the database alone cannot make codes.</summary>
    private string Seal(string text) => Crypto.SealText(text, _secret);

    private string? Unseal(string sealedText) => Crypto.UnsealText(sealedText, _secret);

    /// <summary>Starts turning on two-factor: a new secret, kept aside until a code from it is confirmed.</summary>
    public async Task<string> StartTwoFactorAsync(string id, CancellationToken cancellationToken = default)
    {
        await InitAsync(cancellationToken).ConfigureAwait(false);
        string secret = Crypto.Base32(Crypto.RandomBytes(20));
        await Db.RunAsync("UPDATE rl_users SET totp_pending = ? WHERE id = ?", [Seal(secret), id], cancellationToken).ConfigureAwait(false);
        return secret;
    }

    /// <summary>Turns two-factor on once a code from the new secret checks out, and returns ten recovery codes, shown once.</summary>
    public async Task<List<string>?> ConfirmTwoFactorAsync(string id, string code, long now, CancellationToken cancellationToken = default)
    {
        await InitAsync(cancellationToken).ConfigureAwait(false);
        var row = await Db.FirstAsync("SELECT totp_pending FROM rl_users WHERE id = ?", [id], cancellationToken).ConfigureAwait(false);
        string? secret = row != null && Js.Truthy(row.Get("totp_pending")) ? Unseal(Sql.S(row.Get("totp_pending"))) : null;
        long? step = !string.IsNullOrEmpty(secret) ? Crypto.MatchStep(secret, code, now, -1) : null;
        if (step == null)
        {
            return null;
        }
        var recovery = Crypto.RecoveryCodes();
        // The code that turned it on is not marked used, so signing in again at once with it works.
        await Db.RunAsync(
            "UPDATE rl_users SET totp_secret = ?, totp_pending = NULL, totp_recovery = ?, totp_step = NULL WHERE id = ?",
            [Seal(secret!), HashesJson(recovery), id],
            cancellationToken).ConfigureAwait(false);
        return recovery;
    }

    private static string HashesJson(IEnumerable<string> codes) =>
        Json.Stringify(codes.Select(c => (object?)Crypto.RecoveryHash(c)).ToList());

    /// <summary>New recovery codes in place of the old ones.</summary>
    public async Task<List<string>> NewRecoveryCodesAsync(string id, CancellationToken cancellationToken = default)
    {
        await InitAsync(cancellationToken).ConfigureAwait(false);
        var recovery = Crypto.RecoveryCodes();
        await Db.RunAsync("UPDATE rl_users SET totp_recovery = ? WHERE id = ?", [HashesJson(recovery), id], cancellationToken).ConfigureAwait(false);
        return recovery;
    }

    /// <summary>Drops a set-up left half done, after too many wrong codes, so it must start again with the password.</summary>
    public async Task CancelTwoFactorSetupAsync(string id, CancellationToken cancellationToken = default)
    {
        await InitAsync(cancellationToken).ConfigureAwait(false);
        await Db.RunAsync("UPDATE rl_users SET totp_pending = NULL WHERE id = ?", [id], cancellationToken).ConfigureAwait(false);
    }

    public async Task DisableTwoFactorAsync(string id, CancellationToken cancellationToken = default)
    {
        await InitAsync(cancellationToken).ConfigureAwait(false);
        await Db.RunAsync("UPDATE rl_users SET totp_secret = NULL, totp_pending = NULL, totp_recovery = NULL, totp_step = NULL WHERE id = ?", [id], cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Checks a six-digit code, or a recovery code, for an account with two-factor on. A code works once: one
    /// already used, or older, is refused, and a recovery code is crossed off. One check at a time, so two
    /// sign-ins at once cannot both use the same code: TypeScript queues them per account in its process, and
    /// here, as in PHP, the database's lock does.
    /// </summary>
    public async Task<bool> CheckSecondFactorAsync(string id, string code, long now, CancellationToken cancellationToken = default)
    {
        await InitAsync(cancellationToken).ConfigureAwait(false);
        return await TurnAsync(() => CheckSecondFactorNowAsync(id, code, now, cancellationToken), cancellationToken).ConfigureAwait(false);
    }

    private async Task<bool> CheckSecondFactorNowAsync(string id, string code, long now, CancellationToken cancellationToken)
    {
        var row = await Db.FirstAsync("SELECT totp_secret, totp_recovery, totp_step FROM rl_users WHERE id = ?", [id], cancellationToken).ConfigureAwait(false);
        if (row == null || !Js.Truthy(row.Get("totp_secret")))
        {
            return false;
        }
        string given = Js.Trim(code);
        string digits = string.Concat(given.Where(c => !Js.IsSpace(c)));
        if (digits.Length == 6 && digits.All(char.IsAsciiDigit))
        {
            string? secret = Unseal(Sql.S(row.Get("totp_secret")));
            long after = row.Get("totp_step") == null ? -1 : Js.ToLong(Js.Number(row.Get("totp_step")));
            long? step = !string.IsNullOrEmpty(secret) ? Crypto.MatchStep(secret, digits, now, after) : null;
            if (step == null)
            {
                return false;
            }
            await Db.RunAsync("UPDATE rl_users SET totp_step = ? WHERE id = ?", [step.Value, id], cancellationToken).ConfigureAwait(false);
            return true;
        }
        var hashes = RecoveryList(row.Get("totp_recovery"));
        string wanted = Crypto.RecoveryHash(given);
        int at = hashes.FindIndex(h => h is string s && s == wanted);
        if (at < 0)
        {
            return false;
        }
        hashes.RemoveAt(at);
        await Db.RunAsync("UPDATE rl_users SET totp_recovery = ? WHERE id = ?", [Json.Stringify(hashes), id], cancellationToken).ConfigureAwait(false);
        return true;
    }

    /// <summary>
    /// A short-lived ticket naming an account whose password checked out and which still owes a code. Signed
    /// like a session, so it cannot be made up.
    /// </summary>
    public string PendingFor(JsObject user, long now) => Ticket("pending", user, now + 5 * 60_000);

    /// <summary>
    /// A ticket that looks and acts like <see cref="PendingFor"/>'s, except that no code ever passes with it. A
    /// wrong password gets one once an account with two-factor has had too many, so the answer never tells a
    /// right password.
    /// </summary>
    public string DecoyFor(JsObject user, long now) => Ticket("decoy", user, now + 5 * 60_000);

    /// <summary>The account a code-step ticket names, and whether a right code may sign in with it.</summary>
    public async Task<(JsObject User, bool Real)?> FromPendingAsync(string value, long now, CancellationToken cancellationToken = default)
    {
        var user = await FromTicketAsync("pending", value, now, cancellationToken).ConfigureAwait(false);
        if (user != null)
        {
            return (user, true);
        }
        var decoy = await FromTicketAsync("decoy", value, now, cancellationToken).ConfigureAwait(false);
        return decoy != null ? (decoy, false) : null;
    }

    /// <summary>A ticket for a sign-in link sent by email, for fifteen minutes. A new password withdraws it.</summary>
    public string LinkFor(JsObject user, long now) => Ticket("link", user, now + 15 * 60_000);

    /// <summary>
    /// The account a sign-in link is for. A link works once: using it withdraws it, and every link sent before
    /// it. Uses take turns, so a link opened twice at once lets one in.
    /// </summary>
    public async Task<JsObject?> FromLinkAsync(string value, long now, CancellationToken cancellationToken = default)
    {
        var user = await FromTicketAsync("link", value, now, cancellationToken).ConfigureAwait(false);
        if (user == null)
        {
            return null;
        }
        string[] parts = value.Split('.');
        double expires = Js.Number(parts.Length > 1 ? parts[1] : "");
        return await TurnAsync<JsObject?>(
            async () =>
            {
                string key = "login-link-used:" + Id(user);
                string? used = await _store.SettingAsync(key, cancellationToken).ConfigureAwait(false);
                if (expires <= (used == null ? 0 : Js.Number(used)))
                {
                    return null;
                }
                await _store.SetSettingAsync(key, Js.String(expires), cancellationToken).ConfigureAwait(false);
                return user;
            },
            cancellationToken).ConfigureAwait(false);
    }

    private string Ticket(string kind, JsObject user, long expires)
    {
        string body = Id(user) + "." + Js.Str(expires);
        return body + "." + Sign(kind + "." + body, UserHash(user));
    }

    private async Task<JsObject?> FromTicketAsync(string kind, string value, long now, CancellationToken cancellationToken)
    {
        string[] parts = value.Split('.');
        string id = parts[0];
        string expires = parts.Length > 1 ? parts[1] : "";
        string signature = parts.Length > 2 ? parts[2] : "";
        if (id.Length == 0 || expires.Length == 0 || signature.Length == 0 || !(Js.Number(expires) > now))
        {
            return null;
        }
        var user = await ByIdAsync(id, cancellationToken).ConfigureAwait(false);
        if (user == null)
        {
            return null;
        }
        return Crypto.SameText(Sign(kind + "." + id + "." + expires, UserHash(user)), signature) ? user : null;
    }

    public async Task<long> CountAsync(CancellationToken cancellationToken = default)
    {
        await InitAsync(cancellationToken).ConfigureAwait(false);
        var row = await Db.FirstAsync("SELECT COUNT(*) AS n FROM rl_users", null, cancellationToken).ConfigureAwait(false);
        return Js.ToLong(Js.Number(row?.Get("n") ?? 0L));
    }

    public async Task<JsObject?> ByEmailAsync(string email, CancellationToken cancellationToken = default)
    {
        await InitAsync(cancellationToken).ConfigureAwait(false);
        var row = await Db.FirstAsync("SELECT * FROM rl_users WHERE email = ?", [Js.Lower(Js.Trim(email))], cancellationToken).ConfigureAwait(false);
        return row != null ? Row(row) : null;
    }

    public async Task<JsObject?> ByIdAsync(string id, CancellationToken cancellationToken = default)
    {
        await InitAsync(cancellationToken).ConfigureAwait(false);
        var row = await Db.FirstAsync("SELECT * FROM rl_users WHERE id = ?", [id], cancellationToken).ConfigureAwait(false);
        return row != null ? Row(row) : null;
    }

    public async Task<List<JsObject>> ListAsync(CancellationToken cancellationToken = default)
    {
        await InitAsync(cancellationToken).ConfigureAwait(false);
        return (await Db.AllAsync("SELECT * FROM rl_users ORDER BY created_at, id", null, cancellationToken).ConfigureAwait(false)).Select(Row).ToList();
    }

    /// <summary>Changes a role. The owner's never changes here, and nobody becomes the owner here: see <see cref="HandOverAsync"/>.</summary>
    public async Task<JsObject> SetRoleAsync(string id, string role, CancellationToken cancellationToken = default)
    {
        // The tables first: making them takes the same lock as a turn.
        await InitAsync(cancellationToken).ConfigureAwait(false);
        return await TurnAsync(
            async () =>
            {
                var user = await FindAsync(id, cancellationToken).ConfigureAwait(false) ?? throw new AccountError("Unknown account", "unknown_account");
                if (user.Str("role") == "owner")
                {
                    throw new AccountError("Only the owner can change their own role, by handing ownership to an admin", "owner_protected");
                }
                if (role == "owner")
                {
                    throw new AccountError("Ownership is handed over by the owner", "owner_hand_over");
                }
                await Db.RunAsync("UPDATE rl_users SET role = ? WHERE id = ?", [role, id], cancellationToken).ConfigureAwait(false);
                user.Set("role", role);
                return user;
            },
            cancellationToken).ConfigureAwait(false);
    }

    private async Task<JsObject?> FindAsync(string id, CancellationToken cancellationToken) =>
        (await ListAsync(cancellationToken).ConfigureAwait(false)).FirstOrDefault(u => u.Str("id") == id);

    /// <summary>Makes an admin the owner, and the owner an admin.</summary>
    public async Task HandOverAsync(string from, string to, CancellationToken cancellationToken = default)
    {
        await InitAsync(cancellationToken).ConfigureAwait(false);
        await TurnAsync(
            async () =>
            {
                var owner = await FindAsync(from, cancellationToken).ConfigureAwait(false);
                var next = await FindAsync(to, cancellationToken).ConfigureAwait(false);
                if (owner == null || owner.Str("role") != "owner")
                {
                    throw new AccountError("Only the owner can hand over ownership", "owner_hand_over");
                }
                if (next == null)
                {
                    throw new AccountError("Unknown account", "unknown_account");
                }
                if (next.Str("role") != "admin")
                {
                    throw new AccountError("Make them an admin first", "owner_needs_admin");
                }
                await Db.RunAsync("UPDATE rl_users SET role = 'owner' WHERE id = ?", [to], cancellationToken).ConfigureAwait(false);
                await Db.RunAsync("UPDATE rl_users SET role = 'admin' WHERE id = ?", [from], cancellationToken).ConfigureAwait(false);
                return true;
            },
            cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Removes an account. The owner cannot be removed.</summary>
    public async Task RemoveAsync(string id, CancellationToken cancellationToken = default)
    {
        // The tables first: making them takes the same lock as a turn.
        await InitAsync(cancellationToken).ConfigureAwait(false);
        await TurnAsync(
            async () =>
            {
                var user = await FindAsync(id, cancellationToken).ConfigureAwait(false) ?? throw new AccountError("Unknown account", "unknown_account");
                if (user.Str("role") == "owner")
                {
                    throw new AccountError("The owner cannot be removed", "owner_protected");
                }
                await Db.RunAsync("DELETE FROM rl_users WHERE id = ?", [id], cancellationToken).ConfigureAwait(false);
                await _store.SetSettingAsync("login-link-used:" + id, null, cancellationToken).ConfigureAwait(false);
                return true;
            },
            cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Makes an account, or sets a new password on an existing one. A new account is the owner when it is the first,
    /// and otherwise an admin unless a role is given, since a server has one owner.
    /// </summary>
    public async Task<JsObject> SetPasswordAsync(string email, string password, long now, string? role = null, CancellationToken cancellationToken = default)
    {
        await InitAsync(cancellationToken).ConfigureAwait(false);
        string address = Js.Lower(Js.Trim(email));
        if (!Email.IsMatch(address))
        {
            throw new AccountError("Enter an email address", "email_invalid");
        }
        if (password.Length < MinPassword)
        {
            throw new AccountError(
                "Use a password of at least " + Js.Str(MinPassword) + " characters",
                "password_short",
                new Dictionary<string, string>(StringComparer.Ordinal) { ["min"] = Js.Str(MinPassword) });
        }
        string hash = Crypto.HashPassword(password);
        var existing = await ByEmailAsync(address, cancellationToken).ConfigureAwait(false);
        if (existing != null)
        {
            await Db.RunAsync("UPDATE rl_users SET hash = ? WHERE id = ?", [hash, Id(existing)], cancellationToken).ConfigureAwait(false);
            existing.Set("hash", hash);
            return existing;
        }
        bool first = await CountAsync(cancellationToken).ConfigureAwait(false) == 0;
        string given = role ?? (first ? "owner" : "admin");
        var user = new JsObject
        {
            ["id"] = Crypto.Hex(Crypto.RandomBytes(12)),
            ["email"] = address,
            ["hash"] = hash,
            ["role"] = given == "owner" && !first ? "admin" : given,
            ["createdAt"] = now,
            ["twoFactor"] = false,
            ["recoveryLeft"] = 0L,
        };
        await Db.RunAsync(
            "INSERT INTO rl_users (id, email, hash, role, created_at) VALUES (?, ?, ?, ?, ?)",
            [user.Get("id"), user.Get("email"), user.Get("hash"), user.Get("role"), now],
            cancellationToken).ConfigureAwait(false);
        return user;
    }

    private static JsObject InviteRow(JsObject r) => new()
    {
        ["id"] = Sql.S(r.Get("id")),
        ["email"] = Sql.S(r.Get("email")),
        ["role"] = RoleFrom(r.Get("role")),
        ["invitedBy"] = Sql.S(r.Get("invited_by")),
        ["createdAt"] = Js.Number(r.Get("created_at")),
        ["expiresAt"] = Js.Number(r.Get("expires_at")),
    };

    /// <summary>Invites that still work, newest first. Expired ones are cleared on the way.</summary>
    public async Task<List<JsObject>> InvitesAsync(long now, CancellationToken cancellationToken = default)
    {
        await InitAsync(cancellationToken).ConfigureAwait(false);
        await Db.RunAsync("DELETE FROM rl_invites WHERE expires_at <= ?", [now], cancellationToken).ConfigureAwait(false);
        return (await Db.AllAsync("SELECT * FROM rl_invites ORDER BY created_at DESC, id", null, cancellationToken).ConfigureAwait(false)).Select(InviteRow).ToList();
    }

    /// <summary>
    /// Invites someone to join with a role, and returns the code for their link. Asking again replaces the
    /// earlier invite, so only the newest link works.
    /// </summary>
    public async Task<(JsObject Invite, string Code)> InviteAsync(string email, string role, string invitedBy, long now, CancellationToken cancellationToken = default)
    {
        await InitAsync(cancellationToken).ConfigureAwait(false);
        return await TurnAsync(() => InviteNowAsync(email, role, invitedBy, now, cancellationToken), cancellationToken).ConfigureAwait(false);
    }

    private async Task<(JsObject Invite, string Code)> InviteNowAsync(string email, string role, string invitedBy, long now, CancellationToken cancellationToken)
    {
        string address = Js.Lower(Js.Trim(email));
        if (!Email.IsMatch(address))
        {
            throw new AccountError("Enter an email address", "email_invalid");
        }
        if (await ByEmailAsync(address, cancellationToken).ConfigureAwait(false) != null)
        {
            throw new AccountError(address + " already has an account", "account_exists", new Dictionary<string, string>(StringComparer.Ordinal) { ["email"] = address });
        }
        string code = Crypto.Base64url(Crypto.RandomBytes(24));
        var invite = new JsObject
        {
            ["id"] = Crypto.Hex(Crypto.RandomBytes(12)),
            ["email"] = address,
            ["role"] = role,
            ["invitedBy"] = invitedBy,
            ["createdAt"] = now,
            ["expiresAt"] = now + InviteMs,
        };
        await Db.RunAsync("DELETE FROM rl_invites WHERE email = ?", [address], cancellationToken).ConfigureAwait(false);
        await Db.RunAsync(
            "INSERT INTO rl_invites (id, email, role, code_hash, invited_by, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [invite.Get("id"), address, role, CodeHash(code), invitedBy, now, now + InviteMs],
            cancellationToken).ConfigureAwait(false);
        return (invite, code);
    }

    private static string CodeHash(string code) => Crypto.Hex(Crypto.Sha256(code));

    /// <summary>The invite a link's code belongs to, while it still works.</summary>
    public async Task<JsObject?> InviteByCodeAsync(string code, long now, CancellationToken cancellationToken = default)
    {
        await InitAsync(cancellationToken).ConfigureAwait(false);
        if (!InviteCode.IsMatch(code))
        {
            return null;
        }
        var row = await Db.FirstAsync("SELECT * FROM rl_invites WHERE code_hash = ? AND expires_at > ?", [CodeHash(code), now], cancellationToken).ConfigureAwait(false);
        return row != null ? InviteRow(row) : null;
    }

    public async Task<bool> CancelInviteAsync(string id, CancellationToken cancellationToken = default)
    {
        await InitAsync(cancellationToken).ConfigureAwait(false);
        int before = (await Db.AllAsync("SELECT id FROM rl_invites WHERE id = ?", [id], cancellationToken).ConfigureAwait(false)).Count;
        await Db.RunAsync("DELETE FROM rl_invites WHERE id = ?", [id], cancellationToken).ConfigureAwait(false);
        return before > 0;
    }

    /// <summary>Turns an invite into an account with the password its person chose. The link then stops working.</summary>
    public async Task<JsObject> AcceptInviteAsync(string code, string password, long now, CancellationToken cancellationToken = default)
    {
        var invite = await InviteByCodeAsync(code, now, cancellationToken).ConfigureAwait(false)
            ?? throw new AccountError("This invite has expired or was already used. Ask for a new one.", "invite_gone");
        string email = invite.Str("email")!;
        if (await ByEmailAsync(email, cancellationToken).ConfigureAwait(false) != null)
        {
            throw new AccountError(email + " already has an account", "account_exists", new Dictionary<string, string>(StringComparer.Ordinal) { ["email"] = email });
        }
        var user = await SetPasswordAsync(email, password, now, invite.Str("role"), cancellationToken).ConfigureAwait(false);
        await Db.RunAsync("DELETE FROM rl_invites WHERE id = ?", [invite.Str("id")], cancellationToken).ConfigureAwait(false);
        return user;
    }

    /// <summary>The account for an email and password, or null. Takes the same time either way.</summary>
    public async Task<JsObject?> SignInAsync(string email, string password, CancellationToken cancellationToken = default)
    {
        var user = await ByEmailAsync(email, cancellationToken).ConfigureAwait(false);
        if (user == null)
        {
            Crypto.CheckPassword(password, _decoy ??= Crypto.HashPassword(Crypto.Hex(Crypto.RandomBytes(16))));
            return null;
        }
        return Crypto.CheckPassword(password, UserHash(user)) ? user : null;
    }

    /// <summary>
    /// A cookie value naming the user and when it expires, signed with the server's secret and the user's
    /// password hash, so changing a password signs out every other browser.
    /// </summary>
    public string SessionFor(JsObject user, long now)
    {
        long expires = now + SessionMs;
        string body = Id(user) + "." + Js.Str(expires);
        return body + "." + Sign(body, SessionKey(user));
    }

    /// <summary>The signed-in user for a cookie value, or null.</summary>
    public async Task<JsObject?> FromSessionAsync(string value, long now, CancellationToken cancellationToken = default)
    {
        string[] parts = value.Split('.');
        string id = parts[0];
        string expires = parts.Length > 1 ? parts[1] : "";
        string signature = parts.Length > 2 ? parts[2] : "";
        if (id.Length == 0 || expires.Length == 0 || signature.Length == 0 || !(Js.Number(expires) > now))
        {
            return null;
        }
        var user = await ByIdAsync(id, cancellationToken).ConfigureAwait(false);
        if (user == null)
        {
            return null;
        }
        return Crypto.SameText(Sign(id + "." + expires, SessionKey(user)), signature) ? user : null;
    }

    /// <summary>What a session is signed with: the password hash, and whether two-factor is on, so changing either ends other sessions.</summary>
    private static string SessionKey(JsObject user) => UserHash(user) + (user.Bool("twoFactor") ? ".2fa" : "");

    /// <summary>
    /// A long-lived mark for a browser that signed in to an account. With it, failed tries by others against that
    /// account cannot lock this browser out; the per-address limit still applies. A new password withdraws it.
    /// </summary>
    public string DeviceFor(JsObject user) => Id(user) + "." + Sign("device." + Id(user), UserHash(user));

    public bool TrustsDevice(string value, JsObject user)
    {
        string[] parts = value.Split('.');
        string id = parts[0];
        string signature = parts.Length > 1 ? parts[1] : "";
        if (id != Id(user) || signature.Length == 0)
        {
            return false;
        }
        return Crypto.SameText(Sign("device." + Id(user), UserHash(user)), signature);
    }

    private string Sign(string body, string hash) => Crypto.Signature(_secret, body, hash);
}
