//! Accounts on their own, on every database at hand: roles, invites, signed sessions and tickets, and
//! two-factor, as packages/sdk/test/accounts.test.ts and the PHP port's AccountsTest check them.

#![cfg(all(feature = "sqlite", feature = "postgres", feature = "mysql"))]

mod common;

use std::sync::Arc;

use runlight::accounts::auth::{Pending, match_step};
use runlight::accounts::crypto::{HmacHash, base64url, hmac};
use runlight::accounts::{Accounts, AuthError, INVITE_MS, Role, SESSION_MS, User, totp};
use runlight::store::SqlStore;

const NOW: i64 = 1_791_288_000_000;
const SECRET: &str = "kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk";

/// The code an accounts call was refused with, or "" when it was not.
fn code_of<T>(result: Result<T, AuthError>) -> String {
    match result {
        Ok(_) => String::new(),
        Err(AuthError::Account(e)) => e.code,
        Err(other) => panic!("not a refusal: {other}"),
    }
}

async fn each(test: impl AsyncFn(&str, SqlStore)) {
    for (kind, url) in common::kinds() {
        let fresh = common::fresh(kind, &url).await;
        fresh.store.migrate().await.unwrap();
        test(kind, fresh.store.clone()).await;
        fresh.done().await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn the_first_account_owns_and_the_rest_are_admins_unless_asked() {
    each(async |kind, store| {
        let accounts = Accounts::new(store, SECRET);
        assert_eq!(accounts.count().await.unwrap(), 0, "{kind}");
        let owner = accounts.set_password(" Jon@Example.com ", "a long password", NOW, None).await.unwrap();
        assert_eq!(
            owner.to_value().as_object().unwrap().keys().collect::<Vec<_>>(),
            ["id", "email", "hash", "role", "createdAt", "twoFactor", "recoveryLeft"]
        );
        assert_eq!(owner.email, "jon@example.com");
        assert_eq!(owner.role, Role::Owner);
        assert!(owner.id.len() == 24 && owner.id.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()));
        let admin =
            accounts.set_password("ada@example.com", "another long one", NOW + 1, Some(Role::Owner)).await.unwrap();
        assert_eq!(admin.role, Role::Admin, "a server has one owner");
        let emails: Vec<String> = accounts.list().await.unwrap().into_iter().map(|u| u.email).collect();
        assert_eq!(emails, ["jon@example.com", "ada@example.com"]);
        assert_eq!(accounts.by_id(&owner.id).await.unwrap(), Some(owner.clone()));
        assert_eq!(
            accounts.sign_in("JON@example.com", "a long password").await.unwrap().map(|u| u.id),
            Some(owner.id.clone())
        );
        assert_eq!(accounts.sign_in("jon@example.com", "a wrong password").await.unwrap(), None);
        assert_eq!(accounts.sign_in("nobody@example.com", "a long password").await.unwrap(), None);

        assert_eq!(code_of(accounts.set_password("not an email", "a long password", NOW, None).await), "email_invalid");
        assert_eq!(code_of(accounts.set_password("a@b", "a long password", NOW, None).await), "email_invalid");
        assert_eq!(code_of(accounts.set_password("a@b.", "a long password", NOW, None).await), "email_invalid");
        assert_eq!(
            code_of(accounts.set_password("a\u{a0}b@c.de", "a long password", NOW, None).await),
            "email_invalid"
        );
        let Err(AuthError::Account(short)) = accounts.set_password("x@example.com", "short", NOW, None).await else {
            panic!("a short password is refused");
        };
        assert_eq!(short.code, "password_short");
        assert_eq!(short.params, [("min".to_string(), "10".to_string())]);
        assert_eq!(short.message, "Use a password of at least 10 characters");
        // Ten UTF-16 code units, as JavaScript counts a password's length.
        assert!(
            accounts
                .set_password("emoji@example.com", "\u{1F642}\u{1F642}\u{1F642}\u{1F642}\u{1F642}", NOW, None)
                .await
                .is_ok()
        );

        // A new password replaces the hash, and the old one stops working.
        let changed = accounts.set_password("jon@example.com", "a new long password", NOW, None).await.unwrap();
        assert_eq!(changed.id, owner.id);
        assert_ne!(changed.hash, owner.hash);
        assert_eq!(accounts.sign_in("jon@example.com", "a long password").await.unwrap(), None);
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn roles_handing_over_and_removing() {
    each(async |_, store| {
        let accounts = Accounts::new(store.clone(), SECRET);
        let owner = accounts.set_password("jon@example.com", "a long password", NOW, None).await.unwrap();
        let admin = accounts.set_password("ada@example.com", "a long password", NOW + 1, None).await.unwrap();
        assert_eq!(code_of(accounts.set_role(&owner.id, Role::Admin).await), "owner_protected");
        assert_eq!(code_of(accounts.set_role(&admin.id, Role::Owner).await), "owner_hand_over");
        assert_eq!(code_of(accounts.set_role(&"a".repeat(24), Role::Viewer).await), "unknown_account");
        let member = accounts.set_role(&admin.id, Role::Member).await.unwrap();
        assert_eq!(member, User { role: Role::Member, ..admin.clone() }, "the role changes in place");
        assert_eq!(code_of(accounts.hand_over(&owner.id, &admin.id).await), "owner_needs_admin");
        assert_eq!(code_of(accounts.hand_over(&admin.id, &owner.id).await), "owner_hand_over");
        assert_eq!(code_of(accounts.hand_over(&owner.id, "nobody").await), "unknown_account");
        accounts.set_role(&admin.id, Role::Admin).await.unwrap();
        accounts.hand_over(&owner.id, &admin.id).await.unwrap();
        assert_eq!(accounts.by_id(&owner.id).await.unwrap().unwrap().role, Role::Admin);
        assert_eq!(accounts.by_id(&admin.id).await.unwrap().unwrap().role, Role::Owner);
        assert_eq!(code_of(accounts.remove(&admin.id).await), "owner_protected");
        let link = accounts.link_for(&owner, NOW).unwrap();
        accounts.from_link(&link, NOW).await.unwrap().unwrap();
        assert!(store.setting(&format!("login-link-used:{}", owner.id)).await.unwrap().is_some());
        accounts.remove(&owner.id).await.unwrap();
        assert_eq!(accounts.by_id(&owner.id).await.unwrap(), None);
        assert_eq!(
            store.setting(&format!("login-link-used:{}", owner.id)).await.unwrap(),
            None,
            "its link record goes too"
        );
        assert_eq!(code_of(accounts.remove(&owner.id).await), "unknown_account");
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn invites_work_once_and_the_newest_link_wins() {
    each(async |_, store| {
        let accounts = Accounts::new(store, SECRET);
        accounts.set_password("jon@example.com", "a long password", NOW, None).await.unwrap();
        let first = accounts.invite(" Mo@Example.com", Role::Member, "jon@example.com", NOW).await.unwrap();
        assert_eq!(
            first.invite.to_value().as_object().unwrap().keys().collect::<Vec<_>>(),
            ["id", "email", "role", "invitedBy", "createdAt", "expiresAt"]
        );
        assert_eq!(first.invite.email, "mo@example.com");
        assert_eq!(first.invite.expires_at, NOW + INVITE_MS);
        assert!(
            first.code.len() == 32 && first.code.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        );
        let second = accounts.invite("mo@example.com", Role::Viewer, "jon@example.com", NOW + 5).await.unwrap();
        assert_eq!(
            accounts.invite_by_code(&first.code, NOW + 10).await.unwrap(),
            None,
            "asking again replaces the earlier invite"
        );
        assert_eq!(accounts.invite_by_code(&second.code, NOW + 10).await.unwrap(), Some(second.invite.clone()));
        assert_eq!(accounts.invites(NOW + 10).await.unwrap(), std::slice::from_ref(&second.invite));
        assert_eq!(accounts.invite_by_code("short", NOW).await.unwrap(), None);
        assert_eq!(
            accounts.invite_by_code(&second.code, NOW + 5 + INVITE_MS).await.unwrap(),
            None,
            "an invite runs out"
        );
        let Err(AuthError::Account(exists)) =
            accounts.invite("jon@example.com", Role::Admin, "jon@example.com", NOW).await
        else {
            panic!("someone with an account is not invited");
        };
        assert_eq!(exists.code, "account_exists");
        assert_eq!(exists.message, "jon@example.com already has an account");
        assert_eq!(exists.params, [("email".to_string(), "jon@example.com".to_string())]);
        assert_eq!(code_of(accounts.invite("nope", Role::Admin, "jon@example.com", NOW).await), "email_invalid");
        let user = accounts.accept_invite(&second.code, "another long one", NOW + 20).await.unwrap();
        assert_eq!(user.role, Role::Viewer);
        assert_eq!(accounts.invites(NOW + 20).await.unwrap(), []);
        assert_eq!(
            code_of(accounts.accept_invite(&second.code, "another long one", NOW + 30).await),
            "invite_gone",
            "an invite works once"
        );
        let third = accounts.invite("zed@example.com", Role::Admin, "jon@example.com", NOW).await.unwrap();
        assert!(accounts.cancel_invite(&third.invite.id).await.unwrap());
        assert!(!accounts.cancel_invite(&third.invite.id).await.unwrap());
        accounts.invite("old@example.com", Role::Admin, "jon@example.com", NOW).await.unwrap();
        assert_eq!(accounts.invites(NOW + INVITE_MS).await.unwrap(), [], "expired invites are cleared on the way");
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_double_clicked_invite_makes_one() {
    each(async |_, store| {
        let accounts = Arc::new(Accounts::new(store, SECRET));
        accounts.set_password("jon@example.com", "a long password", NOW, None).await.unwrap();
        let runs: Vec<_> = (0..4)
            .map(|i| {
                let accounts = accounts.clone();
                tokio::spawn(async move {
                    accounts.invite("mo@example.com", Role::Member, "jon@example.com", NOW + i).await
                })
            })
            .collect();
        for run in runs {
            run.await.unwrap().unwrap();
        }
        assert_eq!(accounts.invites(NOW).await.unwrap().len(), 1);
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn sessions_tickets_and_devices_are_signed_and_end_with_their_password() {
    each(async |_, store| {
        let accounts = Accounts::new(store, SECRET);
        let user = accounts.set_password("jon@example.com", "a long password", NOW, None).await.unwrap();
        let session = accounts.session_for(&user, NOW).unwrap();
        let parts: Vec<&str> = session.split('.').collect();
        let (id, expires, signature) = (parts[0], parts[1], parts[2]);
        assert_eq!(id, user.id);
        assert_eq!(expires, (NOW + SESSION_MS).to_string());
        let signed =
            hmac(HmacHash::Sha256, SECRET.as_bytes(), format!("{id}.{expires}.{}", user.hash).as_bytes()).unwrap();
        assert_eq!(signature, base64url(&signed), "signed as TypeScript signs it");
        assert_eq!(accounts.from_session(&session, NOW + 1).await.unwrap(), Some(user.clone()));
        assert_eq!(accounts.from_session(&session, NOW + SESSION_MS).await.unwrap(), None, "a session runs out");
        assert_eq!(accounts.from_session(&format!("{id}.{expires}.x"), NOW).await.unwrap(), None);
        assert_eq!(accounts.from_session("", NOW).await.unwrap(), None);
        assert_eq!(accounts.from_session(&format!("{id}.later.{signature}"), NOW).await.unwrap(), None);
        assert_eq!(
            accounts.from_session(&format!("{session}.extra"), NOW).await.unwrap(),
            Some(user.clone()),
            "split as TypeScript splits it"
        );

        let pending = accounts.pending_for(&user, NOW).unwrap();
        assert_eq!(
            accounts.from_pending(&pending, NOW).await.unwrap(),
            Some(Pending { user: user.clone(), real: true })
        );
        assert_eq!(
            accounts.from_pending(&accounts.decoy_for(&user, NOW).unwrap(), NOW).await.unwrap(),
            Some(Pending { user: user.clone(), real: false })
        );
        assert_eq!(accounts.from_pending(&session, NOW).await.unwrap(), None, "a session is not a code-step ticket");
        assert_eq!(accounts.from_pending(&pending, NOW + 5 * 60_000).await.unwrap(), None);

        let device = accounts.device_for(&user).unwrap();
        assert!(accounts.trusts_device(&device, &user).unwrap());
        assert!(!accounts.trusts_device("", &user).unwrap());

        let link = accounts.link_for(&user, NOW).unwrap();
        let earlier = accounts.link_for(&user, NOW - 1000).unwrap();
        assert_eq!(accounts.from_link(&link, NOW + 1).await.unwrap(), Some(user.clone()));
        assert_eq!(accounts.from_link(&link, NOW + 2).await.unwrap(), None, "a link works once");
        assert_eq!(
            accounts.from_link(&earlier, NOW + 2).await.unwrap(),
            None,
            "and withdraws every link sent before it"
        );
        assert_eq!(accounts.from_link(&pending, NOW).await.unwrap(), None, "a code-step ticket is not a link");

        let changed = accounts.set_password("jon@example.com", "a new long password", NOW, None).await.unwrap();
        assert_eq!(
            accounts.from_session(&session, NOW + 1).await.unwrap(),
            None,
            "a new password signs out every other browser"
        );
        assert!(!accounts.trusts_device(&device, &changed).unwrap());
        assert!(accounts.from_session(&accounts.session_for(&changed, NOW).unwrap(), NOW + 1).await.unwrap().is_some());
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_link_opened_twice_at_once_lets_one_in() {
    each(async |_, store| {
        let accounts = Arc::new(Accounts::new(store, SECRET));
        let user = accounts.set_password("jon@example.com", "a long password", NOW, None).await.unwrap();
        let link = accounts.link_for(&user, NOW).unwrap();
        let runs: Vec<_> = (0..4)
            .map(|_| {
                let (accounts, link) = (accounts.clone(), link.clone());
                tokio::spawn(async move { accounts.from_link(&link, NOW).await.unwrap() })
            })
            .collect();
        let mut opened = 0;
        for run in runs {
            opened += usize::from(run.await.unwrap().is_some());
        }
        assert_eq!(opened, 1);
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn two_factor_codes_work_once_and_recovery_codes_are_crossed_off() {
    each(async |_, store| {
        let accounts = Accounts::new(store, SECRET);
        let user = accounts.set_password("jon@example.com", "a long password", NOW, None).await.unwrap();
        let secret = accounts.start_two_factor(&user.id).await.unwrap();
        assert!(secret.len() == 32 && secret.chars().all(|c| c.is_ascii_uppercase() || ('2'..='7').contains(&c)));
        let step = NOW / 30_000;
        let code = |n: i64| totp(&secret, n).unwrap();
        let wrong = if code(step) == "000000" { "111111" } else { "000000" };
        assert_eq!(accounts.confirm_two_factor(&user.id, wrong, NOW).await.unwrap(), None);
        let recovery = accounts.confirm_two_factor(&user.id, &code(step), NOW).await.unwrap().unwrap();
        assert_eq!(recovery.len(), 10);
        let on = accounts.by_id(&user.id).await.unwrap().unwrap();
        assert!(on.two_factor);
        assert_eq!(on.recovery_left, 10);
        assert_eq!(
            accounts.from_session(&accounts.session_for(&user, NOW).unwrap(), NOW).await.unwrap(),
            None,
            "turning two-factor on ends other sessions"
        );

        // The code that turned it on still signs in, once.
        assert!(accounts.check_second_factor(&user.id, &format!(" {} ", code(step)), NOW).await.unwrap());
        assert!(!accounts.check_second_factor(&user.id, &code(step), NOW).await.unwrap(), "a code works once");
        assert!(!accounts.check_second_factor(&user.id, &code(step - 1), NOW).await.unwrap(), "and an older one never");
        assert!(
            accounts.check_second_factor(&user.id, &code(step + 1), NOW).await.unwrap(),
            "one step ahead, for a clock that drifts"
        );
        assert!(
            accounts.check_second_factor(&user.id, &recovery[3].replace('-', "").to_uppercase(), NOW).await.unwrap()
        );
        assert!(
            !accounts.check_second_factor(&user.id, &recovery[3], NOW).await.unwrap(),
            "a recovery code is crossed off"
        );
        assert_eq!(accounts.by_id(&user.id).await.unwrap().unwrap().recovery_left, 9);
        let fresh = accounts.new_recovery_codes(&user.id).await.unwrap();
        assert!(!accounts.check_second_factor(&user.id, &recovery[0], NOW).await.unwrap());
        assert!(accounts.check_second_factor(&user.id, &fresh[0], NOW).await.unwrap());
        accounts.disable_two_factor(&user.id).await.unwrap();
        assert!(!accounts.by_id(&user.id).await.unwrap().unwrap().two_factor);
        assert!(!accounts.check_second_factor(&user.id, &fresh[1], NOW).await.unwrap());

        accounts.start_two_factor(&user.id).await.unwrap();
        accounts.cancel_two_factor_setup(&user.id).await.unwrap();
        assert_eq!(
            accounts.confirm_two_factor(&user.id, &code(step), NOW).await.unwrap(),
            None,
            "a cancelled set-up confirms nothing"
        );
        assert!(!accounts.check_second_factor("nobody", "123456", NOW).await.unwrap());
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_code_used_by_two_sign_ins_at_once_lets_one_in() {
    each(async |_, store| {
        let accounts = Arc::new(Accounts::new(store, SECRET));
        let user = accounts.set_password("jon@example.com", "a long password", NOW, None).await.unwrap();
        let secret = accounts.start_two_factor(&user.id).await.unwrap();
        let step = NOW / 30_000;
        let code = totp(&secret, step).unwrap();
        accounts.confirm_two_factor(&user.id, &code, NOW).await.unwrap().unwrap();
        assert_eq!(match_step(&secret, &code, NOW, -1), Ok(Some(step)));
        let runs: Vec<_> = (0..4)
            .map(|_| {
                let (accounts, id, code) = (accounts.clone(), user.id.clone(), code.clone());
                tokio::spawn(async move { accounts.check_second_factor(&id, &code, NOW).await.unwrap() })
            })
            .collect();
        let mut passed = 0;
        for run in runs {
            passed += usize::from(run.await.unwrap());
        }
        assert_eq!(passed, 1);
    })
    .await;
}

#[tokio::test]
async fn an_old_table_gains_roles_and_keeps_one_owner() {
    let store = runlight_sqlx::connect(":memory:").await.unwrap();
    store.migrate().await.unwrap();
    let db = store.db();
    db.run("CREATE TABLE rl_users (id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE, hash TEXT NOT NULL, created_at BIGINT NOT NULL)", vec![])
        .await
        .unwrap();
    db.run("INSERT INTO rl_users VALUES ('b', 'b@example.com', 'x', 2), ('a', 'a@example.com', 'x', 1)", vec![])
        .await
        .unwrap();
    db.run("CREATE TABLE rl_invites (id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE, role TEXT NOT NULL, code_hash TEXT NOT NULL UNIQUE, invited_by TEXT NOT NULL, created_at BIGINT NOT NULL, expires_at BIGINT NOT NULL)", vec![])
        .await
        .unwrap();
    db.run("INSERT INTO rl_invites VALUES ('i', 'c@example.com', 'owner', 'h', 'a', 1, 9999999999999)", vec![])
        .await
        .unwrap();
    let accounts = Accounts::new(store.clone(), SECRET);
    let roles: Vec<(String, Role)> = accounts.list().await.unwrap().into_iter().map(|u| (u.id, u.role)).collect();
    assert_eq!(roles, [("a".to_string(), Role::Owner), ("b".to_string(), Role::Admin)]);
    assert_eq!(
        accounts.invites(NOW).await.unwrap()[0].role,
        Role::Admin,
        "an invite as an owner becomes one as an admin"
    );
    // A role nobody knows reads as a viewer.
    db.run("UPDATE rl_users SET role = 'boss' WHERE id = 'b'", vec![]).await.unwrap();
    assert_eq!(accounts.by_id("b").await.unwrap().unwrap().role, Role::Viewer);
}

#[tokio::test]
async fn an_empty_secret_is_refused_as_webcrypto_refuses_it() {
    let store = runlight_sqlx::connect(":memory:").await.unwrap();
    let accounts = Accounts::new(store, "");
    let user = accounts.set_password("jon@example.com", "a long password", NOW, None).await.unwrap();
    assert!(matches!(accounts.session_for(&user, NOW), Err(AuthError::Crypto(_))));
}
