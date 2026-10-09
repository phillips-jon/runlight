using System;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Runlight.Accounts;
using Runlight.Store;
using Xunit;
using static Runlight.Tests.Fixtures;
using AccountsStore = Runlight.Accounts.Accounts;

namespace Runlight.Tests.Accounts;

/// <summary>Accounts and the throttle on their own, on every database at hand.</summary>
public sealed class AccountsTests : IAsyncLifetime
{
    private const long Now = 1_791_288_000_000;
    private const string Secret = "kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk";

    public ValueTask InitializeAsync() => ValueTask.CompletedTask;

    public async ValueTask DisposeAsync() => await Databases.CleanupAsync();

    private static async Task<SqlStore> StoreAsync(string kind)
    {
        var store = await Databases.FreshAsync(kind);
        await store.MigrateAsync();
        return store;
    }

    private static async Task<string> CodeOfAsync(Func<Task> fn)
    {
        try
        {
            await fn();
            return "";
        }
        catch (AccountError error)
        {
            return error.Code;
        }
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task The_first_account_owns_and_the_rest_are_admins_unless_asked(string kind)
    {
        var accounts = new AccountsStore(await StoreAsync(kind), Secret);
        Assert.Equal(0, await accounts.CountAsync());
        var owner = await accounts.SetPasswordAsync(" Jon@Example.com ", "a long password", Now);
        Assert.Equal(["id", "email", "hash", "role", "createdAt", "twoFactor", "recoveryLeft"], owner.Keys);
        Assert.Equal("jon@example.com", owner.Str("email"));
        Assert.Equal("owner", owner.Str("role"));
        Assert.Matches(new Regex("^[a-f0-9]{24}\\z"), owner.Str("id"));
        var admin = await accounts.SetPasswordAsync("ada@example.com", "another long one", Now + 1, "owner");
        Assert.Equal("admin", admin.Str("role"));
        Assert.Equal(["jon@example.com", "ada@example.com"], (await accounts.ListAsync()).Select(u => u.Str("email")));
        Assert.Equal(J(owner), J(await accounts.ByIdAsync(owner.Str("id")!)));
        Assert.Equal(owner.Str("id"), (await accounts.SignInAsync("JON@example.com", "a long password"))!.Str("id"));
        Assert.Null(await accounts.SignInAsync("jon@example.com", "a wrong password"));
        Assert.Null(await accounts.SignInAsync("nobody@example.com", "a long password"));

        Assert.Equal("email_invalid", await CodeOfAsync(() => accounts.SetPasswordAsync("not an email", "a long password", Now)));
        var error = await Assert.ThrowsAsync<AccountError>(() => accounts.SetPasswordAsync("x@example.com", "short", Now));
        Assert.Equal("password_short", error.Code);
        Assert.Equal("{\"min\":\"10\"}", J(error.ParamsObject()));
        Assert.Equal("Use a password of at least 10 characters", error.Message);
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Roles_handing_over_and_removing(string kind)
    {
        var accounts = new AccountsStore(await StoreAsync(kind), Secret);
        var owner = await accounts.SetPasswordAsync("jon@example.com", "a long password", Now);
        var admin = await accounts.SetPasswordAsync("ada@example.com", "a long password", Now + 1);
        string ownerId = owner.Str("id")!;
        string adminId = admin.Str("id")!;
        Assert.Equal("owner_protected", await CodeOfAsync(() => accounts.SetRoleAsync(ownerId, "admin")));
        Assert.Equal("owner_hand_over", await CodeOfAsync(() => accounts.SetRoleAsync(adminId, "owner")));
        Assert.Equal("unknown_account", await CodeOfAsync(() => accounts.SetRoleAsync(new string('a', 24), "viewer")));
        var member = await accounts.SetRoleAsync(adminId, "member");
        Assert.Equal(admin.Keys, member.Keys);
        Assert.Equal("member", member.Str("role"));
        Assert.Equal("owner_needs_admin", await CodeOfAsync(() => accounts.HandOverAsync(ownerId, adminId)));
        Assert.Equal("owner_hand_over", await CodeOfAsync(() => accounts.HandOverAsync(adminId, ownerId)));
        await accounts.SetRoleAsync(adminId, "admin");
        await accounts.HandOverAsync(ownerId, adminId);
        Assert.Equal("admin", (await accounts.ByIdAsync(ownerId))!.Str("role"));
        Assert.Equal("owner", (await accounts.ByIdAsync(adminId))!.Str("role"));
        Assert.Equal("owner_protected", await CodeOfAsync(() => accounts.RemoveAsync(adminId)));
        await accounts.RemoveAsync(ownerId);
        Assert.Null(await accounts.ByIdAsync(ownerId));
        Assert.Equal("unknown_account", await CodeOfAsync(() => accounts.RemoveAsync(ownerId)));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Invites_work_once_and_the_newest_link_wins(string kind)
    {
        var accounts = new AccountsStore(await StoreAsync(kind), Secret);
        await accounts.SetPasswordAsync("jon@example.com", "a long password", Now);
        var (first, old) = await accounts.InviteAsync(" Mo@Example.com", "member", "jon@example.com", Now);
        Assert.Equal(["id", "email", "role", "invitedBy", "createdAt", "expiresAt"], first.Keys);
        Assert.Equal("mo@example.com", first.Str("email"));
        Assert.Equal(Now + AccountsStore.InviteMs, first.Num("expiresAt"));
        Assert.Matches(new Regex("^[A-Za-z0-9_-]{32}\\z"), old);
        var (second, code) = await accounts.InviteAsync("mo@example.com", "viewer", "jon@example.com", Now + 5);
        Assert.Null(await accounts.InviteByCodeAsync(old, Now + 10));
        Assert.Equal(J(second), J(await accounts.InviteByCodeAsync(code, Now + 10)));
        Assert.Equal(J(new[] { second }), J(await accounts.InvitesAsync(Now + 10)));
        Assert.Null(await accounts.InviteByCodeAsync("short", Now));
        Assert.Null(await accounts.InviteByCodeAsync(code, Now + 5 + AccountsStore.InviteMs));
        var error = await Assert.ThrowsAsync<AccountError>(() => accounts.InviteAsync("jon@example.com", "admin", "jon@example.com", Now));
        Assert.Equal("account_exists", error.Code);
        Assert.Equal("{\"email\":\"jon@example.com\"}", J(error.ParamsObject()));
        var user = await accounts.AcceptInviteAsync(code, "another long one", Now + 20);
        Assert.Equal("viewer", user.Str("role"));
        Assert.Empty(await accounts.InvitesAsync(Now + 20));
        Assert.Equal("invite_gone", await CodeOfAsync(() => accounts.AcceptInviteAsync(code, "another long one", Now + 30)));
        var (third, _) = await accounts.InviteAsync("zed@example.com", "admin", "jon@example.com", Now);
        Assert.True(await accounts.CancelInviteAsync(third.Str("id")!));
        Assert.False(await accounts.CancelInviteAsync(third.Str("id")!));
        await accounts.InviteAsync("old@example.com", "admin", "jon@example.com", Now);
        Assert.Empty(await accounts.InvitesAsync(Now + AccountsStore.InviteMs));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Sessions_tickets_and_devices_are_signed_and_end_with_their_password(string kind)
    {
        var accounts = new AccountsStore(await StoreAsync(kind), Secret);
        var user = await accounts.SetPasswordAsync("jon@example.com", "a long password", Now);
        string session = accounts.SessionFor(user, Now);
        string[] parts = session.Split('.');
        var (id, expires, signature) = (parts[0], parts[1], parts[2]);
        Assert.Equal(user.Str("id"), id);
        Assert.Equal(Js.Str(Now + AccountsStore.SessionMs), expires);
        Assert.Equal(Crypto.Signature(Secret, id + "." + expires, user.Str("hash")!), signature);
        Assert.Equal(J(user), J(await accounts.FromSessionAsync(session, Now + 1)));
        Assert.Null(await accounts.FromSessionAsync(session, Now + AccountsStore.SessionMs));
        Assert.Null(await accounts.FromSessionAsync(id + "." + expires + ".x", Now));
        Assert.Null(await accounts.FromSessionAsync("", Now));
        Assert.Null(await accounts.FromSessionAsync(id + ".later." + signature, Now));

        string pending = accounts.PendingFor(user, Now);
        var real = await accounts.FromPendingAsync(pending, Now);
        Assert.Equal(J(user), J(real!.Value.User));
        Assert.True(real.Value.Real);
        var decoy = await accounts.FromPendingAsync(accounts.DecoyFor(user, Now), Now);
        Assert.Equal(J(user), J(decoy!.Value.User));
        Assert.False(decoy.Value.Real);
        Assert.Null(await accounts.FromPendingAsync(session, Now));
        Assert.Null(await accounts.FromPendingAsync(pending, Now + 5 * 60_000));

        string device = accounts.DeviceFor(user);
        Assert.True(accounts.TrustsDevice(device, user));
        Assert.False(accounts.TrustsDevice("", user));

        string link = accounts.LinkFor(user, Now);
        string earlier = accounts.LinkFor(user, Now - 1000);
        Assert.Equal(J(user), J(await accounts.FromLinkAsync(link, Now + 1)));
        Assert.Null(await accounts.FromLinkAsync(link, Now + 2));
        Assert.Null(await accounts.FromLinkAsync(earlier, Now + 2));

        var changed = await accounts.SetPasswordAsync("jon@example.com", "a new long password", Now);
        Assert.Null(await accounts.FromSessionAsync(session, Now + 1));
        Assert.False(accounts.TrustsDevice(device, changed));
        Assert.NotNull(await accounts.FromSessionAsync(accounts.SessionFor(changed, Now), Now + 1));
    }

    [Theory]
    [MemberData(nameof(Databases.KindData), MemberType = typeof(Databases))]
    public async Task Two_factor_codes_work_once_and_recovery_codes_are_crossed_off(string kind)
    {
        var accounts = new AccountsStore(await StoreAsync(kind), Secret);
        var user = await accounts.SetPasswordAsync("jon@example.com", "a long password", Now);
        string id = user.Str("id")!;
        string secret = await accounts.StartTwoFactorAsync(id);
        Assert.Matches(new Regex("^[A-Z2-7]{32}\\z"), secret);
        long step = Now / 30_000;
        string wrong = Crypto.Totp(secret, step) == "000000" ? "111111" : "000000";
        Assert.Null(await accounts.ConfirmTwoFactorAsync(id, wrong, Now));
        var recovery = await accounts.ConfirmTwoFactorAsync(id, Crypto.Totp(secret, step), Now);
        Assert.Equal(10, recovery!.Count);
        Assert.Matches(new Regex("^[a-z2-7]{4}-[a-z2-7]{4}\\z"), recovery[0]);
        var on = (await accounts.ByIdAsync(id))!;
        Assert.True(on.Bool("twoFactor"));
        Assert.Equal(10, on.Long("recoveryLeft"));
        Assert.Null(await accounts.FromSessionAsync(accounts.SessionFor(user, Now), Now));

        // The code that turned it on still signs in, once.
        Assert.True(await accounts.CheckSecondFactorAsync(id, " " + Crypto.Totp(secret, step) + " ", Now));
        Assert.False(await accounts.CheckSecondFactorAsync(id, Crypto.Totp(secret, step), Now));
        Assert.False(await accounts.CheckSecondFactorAsync(id, Crypto.Totp(secret, step - 1), Now));
        Assert.True(await accounts.CheckSecondFactorAsync(id, Crypto.Totp(secret, step + 1), Now));
        Assert.True(await accounts.CheckSecondFactorAsync(id, recovery[3].Replace("-", "", StringComparison.Ordinal).ToUpperInvariant(), Now));
        Assert.False(await accounts.CheckSecondFactorAsync(id, recovery[3], Now));
        Assert.Equal(9, (await accounts.ByIdAsync(id))!.Long("recoveryLeft"));
        var fresh = await accounts.NewRecoveryCodesAsync(id);
        Assert.False(await accounts.CheckSecondFactorAsync(id, recovery[0], Now));
        Assert.True(await accounts.CheckSecondFactorAsync(id, fresh[0], Now));
        await accounts.DisableTwoFactorAsync(id);
        Assert.False((await accounts.ByIdAsync(id))!.Bool("twoFactor"));
        Assert.False(await accounts.CheckSecondFactorAsync(id, fresh[1], Now));

        await accounts.StartTwoFactorAsync(id);
        await accounts.CancelTwoFactorSetupAsync(id);
        Assert.Null(await accounts.ConfirmTwoFactorAsync(id, Crypto.Totp(secret, step), Now));
    }

    [Fact]
    public async Task An_old_table_gains_roles_and_keeps_one_owner()
    {
        var store = await StoreAsync("sqlite");
        await store.Db.RunAsync("CREATE TABLE rl_users (id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE, hash TEXT NOT NULL, created_at BIGINT NOT NULL)");
        await store.Db.RunAsync("INSERT INTO rl_users VALUES ('b', 'b@example.com', 'x', 2), ('a', 'a@example.com', 'x', 1)");
        var accounts = new AccountsStore(store, Secret);
        Assert.Equal(["a owner", "b admin"], (await accounts.ListAsync()).Select(u => u.Str("id") + " " + u.Str("role")));
    }

    [Fact]
    public async Task The_throttle_counts_before_the_check_and_forgives_a_right_try()
    {
        var store = await StoreAsync("sqlite");
        var throttle = new Throttle(store, "test", 3, 1000);
        for (int i = 0; i < 3; i++)
        {
            Assert.True(await throttle.TakeAsync("jon@example.com", Now));
        }
        Assert.True(await throttle.BlockedAsync("jon@example.com", Now));
        Assert.False(await throttle.TakeAsync("jon@example.com", Now));
        Assert.False(await throttle.BlockedAsync("ada@example.com", Now));
        await throttle.ForgiveAsync("jon@example.com");
        Assert.False(await throttle.BlockedAsync("jon@example.com", Now));
        await throttle.FailAsync("jon@example.com", Now);
        Assert.True(await throttle.BlockedAsync("jon@example.com", Now));
        Assert.False(await throttle.BlockedAsync("jon@example.com", Now + 1000));
        await throttle.ClearAsync("jon@example.com");
        Assert.False(await throttle.BlockedAsync("jon@example.com", Now));
        foreach (var row in await store.SettingsStartingWithAsync("throttle:"))
        {
            Assert.DoesNotContain("jon", row.Str("key"), StringComparison.Ordinal);
        }
        Assert.False(await new Throttle(store, "other", 3, 1000).BlockedAsync("jon@example.com", Now));
        // Another request, with a throttle of its own, sees the same counts.
        await throttle.FailAsync("ada@example.com", Now);
        await throttle.FailAsync("ada@example.com", Now);
        await throttle.FailAsync("ada@example.com", Now);
        Assert.True(await new Throttle(store, "test", 3, 1000).BlockedAsync("ada@example.com", Now));
        // A new entry clears expired ones.
        await throttle.FailAsync("zed@example.com", Now + 2000);
        Assert.Single(await store.SettingsStartingWithAsync("throttle:test:"));
    }
}
