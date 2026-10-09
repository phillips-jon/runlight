# Deploying runlight.sh

The site is static: `site/dist`, built by `npm run build --workspace site`. On the server it follows the same release pattern as cronwatch.dev and the other sites on the box.

```
/var/www/runlight.sh-repo.git          bare clone that fetches from GitHub
/var/www/runlight.sh-releases/<name>/  one git worktree per release, built where it sits
/var/www/runlight.sh                   symlink to the live release; nginx serves its site/dist
/opt/node-runlight                     the Node the builds and the contact service run on
```

`release-deploy` fetches, takes the commit it was given (the one CI passed; it must be on `main`, and one older than the live release is skipped) or else the tip of `main`, and builds a new worktree beside the live one, installing only the site workspace. It checks that `site/dist/index.html` is the landing page with its screenshots, and that the docs, the contact pages, and the 404 and 50x pages exist. Then it marks the release `.release-ok`, moves the symlink in one rename, and confirms `https://runlight.sh/` answers 200 with exactly the `index.html` it just built. If not, it switches back, and on a first deploy, with nothing to switch back to, it says so loudly and exits non-zero. nginx follows the symlink, so nothing restarts apart from the contact form service (see [Contact form](#contact-form)). The newest three releases that went live are kept, and `rollback` switches to the previous one at once.

## One-time setup

As root:

1. Node: `cp -a /opt/node-v24.18.0-linux-x64 /opt/node-runlight` (or whichever pinned Node the other apps use).
2. The vhost: install `deploy/nginx.conf` as `/etc/nginx/sites-available/runlight.sh` with only the port 80 block, symlink it into `sites-enabled`, `nginx -t`, and reload. Then run `certbot certonly --webroot -w /var/www/certbot -d runlight.sh -d www.runlight.sh`, install the whole file, `nginx -t`, and reload. Check a few neighbouring sites still answer. The 443 blocks put `http2` on the listen line for nginx 1.24; on 1.25.1 or newer, switch to `http2 on;`.
3. The deploy key: generate a keypair for GitHub Actions and add the public half to `/home/joncphillips/.ssh/authorized_keys` as
   `restrict,command="/usr/bin/flock -w 900 /home/joncphillips/.build.lock /var/www/runlight.sh/deploy/release-deploy" ssh-ed25519 ...`
   `restrict` turns off forwarding, the pty, and anything OpenSSH adds later. The 900 second wait for the shared build lock leaves room for the build inside the workflow's 20 minute timeout. The forced command never runs what the client asks for. The workflow sends `deploy <commit>`, which OpenSSH puts in `SSH_ORIGINAL_COMMAND`, and `release-deploy` accepts only `deploy` or `deploy` followed by a 40-character lower-case commit id.

As joncphillips:

4. A read-only GitHub deploy key for the clone, since the repository is private. Generate `~/.ssh/github_deploy_runlight` (no passphrase), add its public half to the repository's deploy keys without write access, and add an alias to `~/.ssh/config`:
   ```
   Host github-runlight
       HostName github.com
       User git
       IdentityFile ~/.ssh/github_deploy_runlight
       IdentitiesOnly yes
   ```
5. The bare clone. A bare clone has no fetch refspec, and `release-deploy` reads `refs/remotes/origin/main`, so add one and fetch once:
   ```
   git clone --bare github-runlight:phillips-jon/runlight.git /var/www/runlight.sh-repo.git
   git -C /var/www/runlight.sh-repo.git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
   git -C /var/www/runlight.sh-repo.git fetch origin
   git -C /var/www/runlight.sh-repo.git rev-parse refs/remotes/origin/main   # prints a commit
   ```
   Once the repository is public, `https://github.com/phillips-jon/runlight.git` works without the key.
6. `mkdir /var/www/runlight.sh-releases`
7. The first release, without switching: run `deploy/release-deploy --prepare` from a checkout of the repository, then `ln -s /var/www/runlight.sh-releases/<name> /var/www/runlight.sh`.

On GitHub: secrets `DEPLOY_SSH_KEY` (the private half from step 3) and `DEPLOY_KNOWN_HOSTS` (`ssh-keyscan -p 2222 runlight.sh`), then the repository variable `DEPLOY_ENABLED=true`. From then on every push to `main` deploys once CI passes on it.

## Day to day

```
ssh joncpu /var/www/runlight.sh/deploy/release-deploy --force            # rebuild the tip of main
ssh joncpu /var/www/runlight.sh/deploy/release-deploy <commit>           # deploy that commit on main
ssh joncpu /var/www/runlight.sh/deploy/release-deploy --force <commit>   # even if it is older than the live one
ssh joncpu /var/www/runlight.sh/deploy/rollback                          # back to the previous release
```

The copy of `release-deploy` that runs is the live release's, so a push that changes the script is deployed by the previous version. Run it once by hand with `--force` to try a new one.

A deploy never touches the nginx vhost, so a change to `deploy/nginx.conf` (the CSP, say) is installed by hand once the release carrying it is live:

```
sudo diff /etc/nginx/sites-available/runlight.sh /var/www/runlight.sh/deploy/nginx.conf
sudo cp /var/www/runlight.sh/deploy/nginx.conf /etc/nginx/sites-available/runlight.sh
sudo nginx -t && sudo systemctl reload nginx
```

## Contact form

The form on `/contact/` posts to `/contact`, which nginx hands to `deploy/contact/server.mjs` on `127.0.0.1:3791`. The service checks the form, sends one email through Amazon SES with the sender's address as Reply-To, and redirects the browser to `/contact/sent/` or `/contact/error/`. It has no dependencies, so it runs straight from the live release. nginx limits it to 5 posts a minute per address and 20 a minute in all, with 16 KB a post, and sends the error page when the service is down or a limit is hit. The service keeps its own hourly and daily caps (`LIMITS` in `server.mjs`) and logs one line per post to the journal with the time, outcome, reason, and IP address, never the message or the sender's details.

Its credentials live only in an env file on the server, never in the repository.

1. **SES.** The sender identity (the domain `runlight.sh`, or the address `hello@runlight.sh`) must be verified in SES in `us-east-1`.

2. **An IAM user that can only send as that address.** Save this as `runlight-contact-policy.json`, with your account ID in place of `<account-id>`:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": "ses:SendEmail",
         "Resource": "arn:aws:ses:us-east-1:<account-id>:identity/*",
         "Condition": { "StringEquals": { "ses:FromAddress": "hello@runlight.sh" } }
       }
     ]
   }
   ```
   Then, with the AWS CLI signed in as an administrator:
   ```
   aws iam create-user --user-name runlight-contact
   aws iam put-user-policy --user-name runlight-contact --policy-name ses-send-contact --policy-document file://runlight-contact-policy.json
   aws iam create-access-key --user-name runlight-contact
   ```
   The last command prints `AccessKeyId` and `SecretAccessKey` once. Put them straight into the env file below and nowhere else.

3. **The env file**, as joncphillips on the server:
   ```
   mkdir -p ~/.config
   install -m 600 /dev/null ~/.config/runlight-contact.env
   nano ~/.config/runlight-contact.env
   ```
   with these lines, pasting the real values in the editor so they stay out of shell history:
   ```
   AWS_ACCESS_KEY_ID=<access key id>
   AWS_SECRET_ACCESS_KEY=<secret access key>
   AWS_REGION=us-east-1
   CONTACT_FROM=Runlight <hello@runlight.sh>
   CONTACT_TO=hello@runlight.sh
   ```
   `stat -c '%a %U' ~/.config/runlight-contact.env` should print `600 joncphillips`.

4. **The service**, once a release containing `deploy/contact` is live, as root:
   ```
   sudo cp /var/www/runlight.sh/deploy/contact/runlight-contact.service /etc/systemd/system/runlight-contact.service
   sudo systemctl daemon-reload
   sudo systemctl enable --now runlight-contact
   journalctl -u runlight-contact -n 20 --no-pager
   ```
   The journal should say `listening on 127.0.0.1:3791`. If a variable is missing, the service names it and exits, and systemd retries every 5 seconds.

5. **Test it.**
   ```
   curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://runlight.sh/contact
   # 301 https://runlight.sh/contact/
   curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' --data-urlencode 'name=Deploy test' --data-urlencode 'email=jon@joncphillips.com' --data-urlencode 'message=Testing the contact form.' https://runlight.sh/contact
   # 303 https://runlight.sh/contact/sent/, and the email arrives
   ```
   Then send one through the form in a browser, and check the journal with `journalctl -u runlight-contact -n 5 --no-pager`. A `"failed"` line names the SES error (`ses-403-AccessDenied`, say, for a policy that does not match the From address).

**After a deploy.** The service keeps running the code it started with, and `release-deploy` runs without sudo, so it does not restart it. When a deploy changes `deploy/contact/`, `release-deploy` prints a reminder to run `sudo systemctl restart runlight-contact`. A restart runs the live release's copy, because the unit's path goes through the `/var/www/runlight.sh` symlink.

**Rotating the key.** `aws iam create-access-key --user-name runlight-contact`, put the new pair in the env file, `sudo systemctl restart runlight-contact`, send a test, then `aws iam delete-access-key --user-name runlight-contact --access-key-id <old access key id>`.
