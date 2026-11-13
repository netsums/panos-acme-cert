# panos-acme-cert

Free, auto-renewing Let's Encrypt certificates for Palo Alto NGFW (GlobalProtect
portal/gateway, mgmt, Authentication Portal, SSL Inbound Inspection, see
[Other uses](#other-uses-of-the-cert)) using
[acme.sh](https://github.com/acmesh-official/acme.sh).

- **No script from this repo to trust.** Every step is a command you can read
  and paste. The firewall deploy is acme.sh's own upstream `panos` hook.
- **No password stored.** The firewall only ever sees an API key from an
  admin that can do nothing but Import and Commit.
- **Your production DNS credentials never touch the box.** Validation goes
  through a delegated throwaway domain.

**Why a separate box?** Up to PAN-OS 12.2, neither the firewall nor Panorama
has a built-in ACME client, so they can't get or renew a public certificate
on their own. PAN-OS auto-enrollment (SCEP) only works with an internal CA. So
the ACME part runs on a small Linux box, and PAN-OS only receives the result
through its API.

---

## Watch the videos

- **Video 1: one firewall** (scenarios 1 and 2): https://youtu.be/UmRaHxGueyY
- **Video 2: Panorama and many firewalls** (scenarios 3 and 4): Video will be available soon!
  The guide for it is [PANORAMA.md](PANORAMA.md).

---

## Which setup are you building?

| # | Setup | Certificates | acme.sh talks to | Mgmt the box must trust |
|---|---|---|---|---|
| **1** | GlobalProtect on one firewall | 1: GlobalProtect name | the firewall | the firewall's, via **(B)** |
| **2** | GlobalProtect + mgmt on one firewall | 1: GlobalProtect + mgmt name, **(A)** | the firewall | the firewall's, via this cert |
| **3** | GlobalProtect on Panorama-managed firewalls | 2: Panorama mgmt + GlobalProtect (into a template) | Panorama only | Panorama's |
| **4** | Enterprise: 3 + mgmt of every firewall | 3 or more: Panorama mgmt, GlobalProtect, firewall mgmt (wildcard or one per firewall) | Panorama only | Panorama's |

Two rules cover all four:

- **One certificate, one target.** acme.sh saves one PAN-OS destination per
  certificate: a device (a firewall, or Panorama itself) or a Panorama
  template. Bigger setups simply have more certificates, on the same box,
  renewed by the same cron job. (Hooks for other systems, e.g. a web server,
  can come on top, see [Other uses](#other-uses-of-the-cert).)
- **The box must trust the mgmt it deploys to.** The renewal with Let's Encrypt
  works regardless, but delivering the new cert means an HTTPS login to mgmt
  with normal TLS checks. If that fails, the new cert stays on the box and the
  firewall keeps serving the old one until it expires.

**Scenarios 1 and 2:** follow steps 0 to 7 below. **Scenarios 3 and 4:**
follow [PANORAMA.md](PANORAMA.md), the guide for Panorama and many firewalls.

---

## Choose how the box will trust mgmt

Renewals run unattended, with normal TLS checks against the mgmt interface.
The acme.sh box must trust the mgmt cert, and `$FW` must be a name (or IP)
on it. With (A) that means a name: Let's Encrypt only issues IP certs for
public IPs, valid for about six days, and validates them over HTTP/TLS from
the internet, never via DNS, so the burner delegation can't be used. With (B)
your internal CA can include the mgmt IP, and `$FW` can then be that IP.
Pick one:

| | Mgmt cert | `$FW` is | Extra work |
|---|---|---|---|
| **(A)** | This Let's Encrypt cert | A public name, e.g. `fw-mgmt.example.com` | One more CNAME; bind the cert to mgmt in step 6 |
| **(B)** | From your internal PKI | An internal name, e.g. `fw01.corp.local`, or the mgmt IP if it's on the cert | The box must trust your internal root CA (see below) |

- **No internal PKI but don't want a public name for mgmt?** Use (B) with the
  firewall as its own CA: **Device > Certificate Management > Certificates >
  Generate**, tick *Certificate Authority*, then generate a mgmt cert signed
  by it with the mgmt FQDN as Common Name **and** as a *Host Name* attribute.
  Bind it to mgmt, and trust the firewall's CA cert on the box as below.
- **Leaving mgmt on its default self-signed cert** works for the first
  deploy only. Every renewal fails. That's not hands-off.

**(B) prerequisite:** issuing the internal mgmt cert is up to your PKI and not
part of this guide, but the acme.sh box must trust the root CA that signed it.
Managed servers often do already. Step 4 tells you: `TRUSTED` means you're set.

<details>
<summary>Box doesn't trust your internal CA yet? (click)</summary>

From your admin account (`acmesh` has no sudo), with the root CA saved as PEM
in `corp-root-ca.crt`:

```bash
# Debian / Ubuntu
sudo cp corp-root-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates
# RHEL / Rocky / Alma
sudo cp corp-root-ca.crt /etc/pki/ca-trust/source/anchors/ && sudo update-ca-trust
```

Don't use acme.sh's `--ca-bundle` instead. It *replaces* the trusted CAs for
all acme.sh traffic, so talking to Let's Encrypt breaks.

</details>

---

## Step 0: Prepare the box and set your names

**0a. Tools and user**, from your normal admin account (needs sudo). This
installs the tools and creates the Linux user in `$BOXUSER` (here `acmesh`),
a user that runs acme.sh and nothing else. It has no password (nobody can log
in as it directly) and no sudo. It's called `acmesh`, not `acme`, so you don't
mix it up with the firewall admin (`$FWUSER`, step 0c). If your company has a
naming rule for service accounts, change `BOXUSER` here.

```bash
BOXUSER=acmesh                # Linux user that runs acme.sh (not the firewall admin)

# Debian / Ubuntu
sudo apt update && sudo apt install -y git curl openssl cron dnsutils
# RHEL / Rocky / Alma
sudo dnf install -y git curl openssl cronie bind-utils && sudo systemctl enable --now crond

sudo useradd --create-home --shell /bin/bash "$BOXUSER"
sudo chmod 700 "/home/$BOXUSER"
```

**0b. Switch to it.** Every later command runs as that user unless it says
otherwise. Keep this shell open while you do step 1 in the firewall GUI.

```bash
sudo -iu "$BOXUSER"
```

**0c. Set your names.** Everything below uses these variables, so the
remaining blocks paste as-is. If you open a new shell later, set `BOXUSER`
again, then repeat 0b and 0c.

```bash
CERT=vpn.example.com          # name your users connect to (GlobalProtect)
FW=fw-mgmt.example.com        # mgmt FQDN: public (A) or internal (B)
FWUSER=acme                   # restricted admin you create in step 1
BURNER=burner-domain.net      # throwaway domain for DNS validation
```

## Step 1: Firewall admin user configuration

**Device > Admin Roles > Add** → name `acme-deploy`

| Tab | Setting |
|---|---|
| Web UI | disable **everything** |
| XML API | disable everything, then enable **Import** and **Commit** only |
| Command Line | None |
| REST API | disable everything |

New roles start with most permissions *enabled*. Check every tab.

**Device > Administrators > Add** → the name you set as `$FWUSER` (e.g.
`acme`), Role Based → `acme-deploy`, long random password (you'll type it
once, in step 5).

**Device > Setup > Interfaces > Management** → if *Permitted IP Addresses*
has entries, add the acme.sh box's IP (an empty list allows any IP). Commit.

## Step 2: Install acme.sh

As `acmesh`, from git, so you can read what you run:

```bash
git clone --depth 1 https://github.com/acmesh-official/acme.sh.git
cd acme.sh && ./acme.sh --install && cd .. && rm -rf acme.sh
. ~/.acme.sh/acme.sh.env                         # load acme.sh into this shell
acme.sh --set-default-ca --server letsencrypt
chmod 700 ~/.acme.sh
```

## Step 3: DNS delegation and issuing

In your **real** DNS zone, one CNAME per name on the cert:

```
_acme-challenge.vpn.example.com.      CNAME  _acme-challenge.burner-domain.net.
_acme-challenge.fw-mgmt.example.com.  CNAME  _acme-challenge.burner-domain.net.   ← (A) only
```

Check them:

```bash
dig +short CNAME "_acme-challenge.$CERT"
dig +short CNAME "_acme-challenge.$FW"     # (A) only
```

**Give acme.sh the burner zone** (Cloudflare shown; any
[acme.sh DNS API](https://github.com/acmesh-official/acme.sh/wiki/dnsapi) works,
with its own variable names).

First the zone ID: in Cloudflare, the burner domain's **Overview** page, on the
right, *Copy zone ID*. It isn't a secret, so it's read without `-s`. With it,
acme.sh knows which zone to write to, so the token needs nothing beyond
**Zone > DNS > Edit** on the burner zone. Without it, acme.sh has to look the
zone up by name, which also needs **Zone > Zone > Read** on the token.

```bash
read -rp 'Cloudflare zone ID (burner zone only): ' CF_Zone_ID; export CF_Zone_ID
```

Then the token: **My Profile > API Tokens > Create Token**, template **Edit
zone DNS**. Give it a name and, under *Zone Resources*, select only the burner
zone. An expiry date is optional, but then replace the token before it
expires, or the next renewal fails. Check the summary, create it, copy it.

```bash
read -rsp 'Cloudflare token (burner zone only): ' CF_Token; echo; export CF_Token
```

`read -s` puts the token in the `CF_Token` variable without showing it on
screen or saving it in shell history. `export` hands it to acme.sh, whose
Cloudflare module reads exactly that variable name. acme.sh saves the token
and zone ID for renewals (see [Where the credentials live](#where-the-credentials-live)),
which is why the token must only be able to edit the burner zone.

**Issue**, in the same shell, in two runs:

1. **Test against staging.** Let's Encrypt's test server runs the same checks
   (CNAMEs, token, challenge alias) without the production rate limits. Its
   certs aren't trusted: don't deploy one.
2. **Issue the real cert, with `--force`.** Without it, acme.sh sees the same
   names, prints `Domains not changed`, skips, and keeps renewing against
   staging.

Paste **one** of the two variants.

**(A)** GlobalProtect name + mgmt name on the cert:

```bash
acme.sh --issue --staging --dns dns_cf -d "$CERT" -d "$FW" --always-force-new-domain-key --challenge-alias "$BURNER"
```

Ended with `Cert success`? Then the real one, in the same shell:

```bash
acme.sh --issue --dns dns_cf -d "$CERT" -d "$FW" --always-force-new-domain-key --challenge-alias "$BURNER" --force
unset CF_Token
acme.sh --list    # CA column: LetsEncrypt.org. LetsEncrypt.org_test = still the staging cert
```

**(B)** GlobalProtect name only: the same two runs, without `-d "$FW"`:

```bash
acme.sh --issue --staging --dns dns_cf -d "$CERT" --always-force-new-domain-key --challenge-alias "$BURNER"
```

```bash
acme.sh --issue --dns dns_cf -d "$CERT" --always-force-new-domain-key --challenge-alias "$BURNER" --force
unset CF_Token
acme.sh --list
```

### Optional: lock issuance to your account (CAA)

A CAA record tells every CA which CA, and which account, may issue for a name.
With it, a stolen burner token alone is useless: the thief's ACME account isn't
yours, so Let's Encrypt refuses.

Get your account URL (production, not staging):

```bash
grep ACCOUNT_URL ~/.acme.sh/ca/acme-v02.api.letsencrypt.org/directory/ca.conf
```

In your **real** zone, one record per name on your certs, with that URL:

```
vpn.example.com.      CAA 0 issue "letsencrypt.org; accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/123456789; validationmethods=dns-01"
fw-mgmt.example.com.  CAA 0 issue "letsencrypt.org; accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/123456789; validationmethods=dns-01"
```

For a wildcard like `*.fw.example.com`, put the record on `fw.example.com`. It
then covers the wildcard and every name below it.

Check what's published:

```bash
dig +short CAA "$CERT"
dig +short CAA "$FW"       # (A) only
```

You should see your record, and no `letsencrypt.org` line without `accounturi`.
If your real zone is on Cloudflare with Universal SSL, Cloudflare can add CAA
records for its own CAs, including a bare `letsencrypt.org`. They don't show in
the dashboard, only in `dig`. If one is there, any Let's Encrypt account can
issue and the lock does nothing.

To test that the record blocks, issue once with a wrong `accounturi` in it.
Deactivate first, or Let's Encrypt reuses the earlier validation and skips the
CAA check:

```bash
acme.sh --deactivate -d "$CERT"
acme.sh --renew -d "$CERT" --force
```

That should fail with a CAA error. Put the right URL back, and the same two
commands should issue again. Each `--force` that succeeds is a real cert, so
mind the 5 duplicate certs per week.

- **Exact names only, not your apex.** A CAA record on `example.com` applies to
  every name below it that has no CAA record of its own, and would block the
  certs of your website and other services.
- **Add it after your staging tests.** The staging server uses a different
  account and would be refused.
- **A name that is a CNAME can't carry a CAA record.** Put it where the CNAME
  points, or leave that name out.
- **It covers a leaked token, not a taken-over box.** The box also holds your
  ACME account key. Keep it small and locked down.

## Step 4: Check you're really talking to your firewall

```bash
if ERR="$(curl -sS -o /dev/null --connect-timeout 5 "https://$FW/" 2>&1)"; then
  echo "TRUSTED: mgmt cert verifies. Skip the rest of step 4."
  TLS=(); INSECURE=()
else
  echo; echo "NOT TRUSTED: ${ERR%%$'\n'*}"; echo
fi
```

Read the reason it prints:

| Reason contains | Meaning | Next |
|---|---|---|
| `(60) SSL certificate problem` | Box can't verify the mgmt cert. Normal for (A) on a first run | Fingerprint check below |
| `(60) … no alternative certificate subject name matches` | Cert is valid, but `$FW` isn't a name on it | Fix `$FW` or the mgmt cert. (B): must match the internal cert |
| `(6) Could not resolve host` | `$FW` doesn't resolve on the box | DNS or `/etc/hosts` |
| `(7) Failed to connect` / `(28) timed out` | Can't reach mgmt on 443 | Permitted IPs, routing, host firewall |

**If it's a certificate problem** (usual for (A) on a first run, mgmt is
still self-signed), save the cert mgmt presents and look at its fingerprint:

```bash
echo | openssl s_client -connect "$FW:443" -servername "$FW" 2>/dev/null \
  | openssl x509 > fw-mgmt.pem
openssl x509 -in fw-mgmt.pem -noout -subject -fingerprint -sha256
```

Compare it with the real one: on the firewall, **Device > Certificate
Management > Certificates**, export the cert used by mgmt, then run
`openssl x509 -in <exported file> -noout -fingerprint -sha256` on it. If mgmt
still uses the factory default cert and it isn't in that list, open the
firewall GUI from your admin PC instead, click the padlock, and read the
cert's SHA-256 fingerprint there. **Only if they match**, pin it:

```bash
PIN="sha256//$(openssl x509 -in fw-mgmt.pem -pubkey -noout \
  | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl base64)"
TLS=(-k --pinnedpubkey "$PIN"); INSECURE=(--insecure)
```

From here on, curl refuses to send anything unless the firewall presents
exactly that key. (acme.sh doesn't use the pin, see step 5b.)

## Step 5: API key and first deploy

**5a. Generate the API key.** The password is read hidden and passed to curl
on stdin, so it never appears on screen, in shell history or in `ps`. It's
sent only to the firewall you verified in step 4, used once to generate the
API key, and removed from the shell right after (`unset P`). The API key goes
straight into a variable and is never shown on screen.

```bash
read -rsp "Password for $FWUSER: " P; echo
RESP="$(printf '%s' "$P" | curl -sS "${TLS[@]}" -X POST "https://$FW/api/?type=keygen" \
    --data-urlencode "user=$FWUSER" --data-urlencode 'password@-')"
unset P
PANOS_KEY="$(sed -n 's:.*<key>\(.*\)</key>.*:\1:p' <<<"$RESP")"
if [ -n "$PANOS_KEY" ]; then echo "API key OK"; else echo "Keygen FAILED: $RESP"; fi
unset RESP
```

Continue only if it says `API key OK`.

**5b. First deploy**, in the same shell:

```bash
acme.sh --list    # KeyLength "ec-256" = ECDSA → keep --ecc. "2048" → remove --ecc
export PANOS_HOST="$FW" PANOS_USER="$FWUSER" PANOS_KEY
acme.sh --deploy -d "$CERT" --deploy-hook panos --ecc "${INSECURE[@]}"
unset PANOS_KEY
```

`${INSECURE[@]}` is `--insecure` only if mgmt wasn't trusted in step 4 (you
checked its identity by fingerprint instead). It applies to this run only and
isn't saved. acme.sh stores host, user and key for renewals.

`--insecure` means acme.sh doesn't check the firewall's identity on this one
run; your pin from step 4 only protected the keygen. Run 5b right after
step 4, so the check you just did still holds. From step 7 on, every deploy
is verified.

The cert appears under **Device > Certificate Management > Certificates**,
named after `$CERT`. The hook commits only the `$FWUSER` admin's changes.

The hook uploads acme.sh's full-chain file: your certificate **plus** the
Let's Encrypt intermediate. The firewall serves the complete chain, so
clients don't fail with "untrusted certificate".

## Step 6: Firewall — bind the cert (once)

- **GlobalProtect:** Device > Certificate Management > SSL/TLS Service Profile
  → the profile used by the portal/gateway → Certificate = `vpn.example.com`
  (or create a profile and select it in the portal and gateway).
- **Mgmt, (A) only:** create an SSL/TLS Service Profile with the same cert →
  **Device > Setup > Management > General Settings** → SSL/TLS Service
  Profile. Mgmt now presents a publicly trusted cert that matches `$FW`.
- Commit.

## Other uses of the cert

GlobalProtect and mgmt are the common cases, not the only ones. A Let's
Encrypt cert fits anywhere the firewall is the **TLS server for a public
name**. Same flow: issue, deploy, bind once.

| Use | Works? | Bind it in |
|---|---|---|
| GlobalProtect portal/gateway | Yes | SSL/TLS Service Profile |
| Mgmt web UI and API | Yes | SSL/TLS Service Profile → Device > Setup > Management |
| Authentication Portal | Yes | SSL/TLS Service Profile → Device > User Identification > Authentication Portal Settings |
| SSL Inbound Inspection | Yes, with the same cert and key on the web server | Decryption policy rule, type SSL Inbound Inspection |
| SSL Forward Proxy | **No.** It needs a CA certificate that signs certs on the fly. No public CA issues one | Keep your internal CA |
| The firewall authenticating as a TLS client | **No.** Let's Encrypt certs are for servers only; the client-auth EKU was dropped in 2026 | Internal PKI |

**SSL Inbound Inspection.** The firewall needs the web server's certificate and
private key, so the firewall and the server must get the same cert. Give the
deploy two hooks: `panos` first, then one for the server (acme.sh ships many,
e.g. `ssh`). Hooks run in the order given, and if one fails the rest are
skipped, so the server never gets a cert the firewall doesn't have yet. That's
also the order Palo Alto recommends: firewall first, then the server.

```bash
acme.sh --deploy -d www.example.com --deploy-hook panos --deploy-hook ssh --ecc
```

Each hook reads its own variables on the first deploy, see the acme.sh
[deploy hooks wiki](https://github.com/acmesh-official/acme.sh/wiki/deployhooks).
Bind once: select the cert in the decryption rule (PAN-OS 10.2 and later accept
several certs per rule). With `--always-force-new-domain-key`, firewall and
server get the new key together at every renewal.

## Step 7: Make renewals hands-off

**Deploy again, without `--insecure`.** For (A), only after step 6 is
committed: mgmt must present the new cert first. The `curl` check in front
stops with the reason if it doesn't yet. If the deploy works, renewals will
too:

```bash
curl -sS -o /dev/null --connect-timeout 5 "https://$FW/" \
  && acme.sh --deploy -d "$CERT" --deploy-hook panos --ecc
```

**Check the cron job and what the firewall serves:**

```bash
crontab -l | grep acme.sh
echo | openssl s_client -connect "$CERT:443" -servername "$CERT" 2>/dev/null \
  | openssl x509 -noout -issuer -enddate
```

**Check the firewall serves the full chain:**

```bash
echo | openssl s_client -connect "$CERT:443" -servername "$CERT" 2>/dev/null \
  | grep -E '^ *[0-9]+ s:|^ +i:'
```

`0` is your certificate, `1` the Let's Encrypt intermediate (e.g. `YE2`), and
there may be a `2`. If you only see `0`, the intermediate is missing and some
clients will reject the certificate.

**Get told about failures.** Notifications at the default level cover errors
and successful renewals, so silence means something is wrong. SMTP example
(other hooks: mail, Teams, Slack, Telegram, …):

```bash
export SMTP_FROM=acme@example.com SMTP_TO=you@example.com \
       SMTP_HOST=smtp.example.com SMTP_SECURE=tls \
       SMTP_USERNAME=acme@example.com
read -rsp 'SMTP password: ' SMTP_PASSWORD; echo; export SMTP_PASSWORD
acme.sh --set-notify --notify-hook smtp
unset SMTP_PASSWORD
```

Mail can fail silently too, so also have your monitoring (e.g. CheckMK) alert
on the expiry date the firewall actually serves.

---

## Shorter certificate lifetimes (47 days by 2029)

Public TLS certificates are getting shorter: 200 days maximum since March
2026, 100 days from March 2027, 47 days from March 2029 (CA/Browser Forum
ballot SC-081). Let's Encrypt is ahead of that: its default drops from 90 to
64 days on 10 February 2027, and to 45 days on 16 February 2028.

**You don't need to change anything.** acme.sh asks Let's Encrypt when to
renew each certificate (ARI) and renews inside that window, so the schedule
follows the lifetime on its own. What changes is how often the firewall gets
an import and commit: with 45-day certs, about once a month.

When is the next renewal planned? See the `Renew` column:

```bash
acme.sh --list
```

**Optional: pick the lifetime.** With Let's Encrypt you can't request a number
of days. You pick a profile by adding it to the `--issue` line in step 3:

| Option on `--issue` | Lifetime |
|---|---|
| *(none)* | Let's Encrypt default: 90 days, 64 from Feb 2027, 45 from Feb 2028 |
| `--cert-profile tlsserver` | 45 days now, to test the short lifetime before it's the default |

**Optional: renew a fixed number of days before expiry.** Add e.g.
`--days -15` to the `--issue` line to renew 15 days before the certificate
expires. Let's Encrypt can still ask for an earlier renewal when it needs to
(for example before revoking certificates). Most people should leave this out:
the default already renews with plenty of margin.

**A new private key on every renewal.** By default acme.sh keeps the same
private key across renewals, so a leaked key stays usable with the next cert
too. That's why every `--issue` line in this guide has
`--always-force-new-domain-key`: every renewal comes with a fresh key. That's
what makes short lifetimes a real security gain: a leaked key dies with its
cert. The deploy imports cert and key together, so the firewall needs nothing
extra.

**Issued without it?** Run your step 3 production `--issue` line again with
the option added (it already has `--force`). That issues a new certificate
now. Then deploy it with the step 7 deploy command. acme.sh saves the options
for all future renewals.

---

## Panorama and many firewalls

Scenarios 3 and 4 (Panorama's own mgmt, GlobalProtect into a template, and the
mgmt of every firewall) have their own guide: **[PANORAMA.md](PANORAMA.md)**.

---

## Where the credentials live

- **Firewall password:** used once in step 5a, never stored.
- **API key:** in `~/.acme.sh/<domain>_ecc/<domain>.conf` (no `_ecc` for RSA),
  **base64-encoded, not encrypted.** Anyone who can read that file can use it.
- **Burner DNS token:** in each cert's `~/.acme.sh/<domain>_ecc/<domain>.conf`,
  next to the API key (with `CF_Zone_ID` set; without it, in
  `~/.acme.sh/account.conf`). It can only change the
  burner zone. It can't touch your real DNS, but it can pass validation for
  every name whose `_acme-challenge` CNAME points to the burner, i.e. get a
  valid cert for those names. [CAA](#optional-lock-issuance-to-your-account-caa)
  closes that.

What a stolen key can do: import certificates or files and trigger a commit.
It can't change policy or read your config. acme.sh's own commit is a partial
commit of the `$FWUSER` admin's changes only, so other admins' pending changes
stay uncommitted.

Keep it small: a dedicated box, the `acmesh` user, `chmod 700 ~/.acme.sh`, mgmt Permitted
IPs limited to that box. If you set an API key lifetime (Device > Setup >
Management > Authentication Settings), renewals fail when the key expires.
Before then, set `BOXUSER` and repeat 0b, 0c, 4 (it should say `TRUSTED` by
now), 5a and 5b. acme.sh saves the key separately for each cert, so with
several certs, run each cert's deploy line once with the new key exported,
not just the one for `$CERT`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `dig` shows no CNAME | Record missing, or created in the burner zone instead of the real one |
| Issue fails with DNS error | Token can't edit the burner zone, or the CNAME target is wrong |
| Step 4: `unable to load certificate` | Box can't reach mgmt on 443: Permitted IPs, routing, or wrong `$FW` |
| (B) Step 4 says NOT TRUSTED | Root CA not in the box's trust store ([see (B) prerequisite](#choose-how-the-box-will-trust-mgmt)), or `$FW` isn't a name on the mgmt cert |
| Keygen: `(90) public key does not match` | The firewall's key changed, or something is intercepting. Redo step 4 |
| Keygen returns error | Wrong password, or the role has no XML API access |
| Import fails | Role missing **Import** |
| Deploy fails: key/cert file not found | ECDSA cert without `--ecc` (or RSA with it). Check `acme.sh --list` |
| Commit fails | Role missing **Commit**, or another admin holds a config lock |
| Step 7 deploy fails with a TLS error | (A) Mgmt isn't presenting the new cert yet, or `$FW` isn't a name on it: redo step 6. (B) The box no longer trusts the mgmt cert: see the (B) prerequisite |
| Users still see the old cert | The SSL/TLS Service Profile points at a different cert object |
| Issue fails with a CAA error | CAA `accounturi` doesn't match: staging account, or a different acme.sh install |
| `Domains not changed` … `Skipping` after the staging test | The real run needs `--force` (step 3). `acme.sh --list` shows `LetsEncrypt.org_test` in the CA column while it's still the staging cert |
| Browser says the cert isn't trusted, issuer mentions "STAGING" | A staging cert was deployed. Issue the real one with `--force` (step 3), then deploy again |

## License

MIT
