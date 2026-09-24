# panos-acme-cert

Free, auto-renewing Let's Encrypt certificates for Palo Alto NGFW (GlobalProtect
portal/gateway, mgmt, captive portal, …) using
[acme.sh](https://github.com/acmesh-official/acme.sh).

- **No script from this repo to trust.** Every step is a command you can read
  and paste. The firewall deploy is acme.sh's own upstream `panos` hook.
- **No password stored.** The firewall only ever sees an API key from an
  admin that can do nothing but Import and Commit.
- **Your production DNS credentials never touch the box.** Validation goes
  through a delegated throwaway domain.

---

## How it works

```
acme.sh (Linux box) ──DNS-01──▶ Let's Encrypt
        │                         ▲
        │                         └─ _acme-challenge.vpn.example.com  CNAME ─▶ _acme-challenge.burner-domain.net
        │                                                             (only the burner zone's DNS token
        │                                                              lives on the box)
        └──XML API (API key)──▶ PAN-OS: import cert + key, partial commit
```

acme.sh renews by cron every ~60 days and re-runs the deploy: import, commit,
done. The cert object keeps its name, so every SSL/TLS Service Profile that
uses it picks up the new cert.

---

## Checklist

Print this, or tick it off as you follow the steps below. **(A)** / **(B)**
marks items that depend on your mgmt choice ([see below](#choose-how-the-box-will-trust-mgmt)).

**Box prep**
- [ ] Tools installed, `acmesh` user created (no password, no sudo)

**Firewall**
- [ ] Admin Role `acme-deploy`: XML API **Import** + **Commit** only, everything else off
- [ ] Administrator (e.g. `acme`) with that role and a long random password
- [ ] acme.sh box's IP added to mgmt *Permitted IP Addresses*, if list not empty
- [ ] Mgmt reachable from the box by an FQDN (DNS or `/etc/hosts`)

**DNS**
- [ ] Throwaway ("burner") domain on a DNS provider [acme.sh](https://github.com/acmesh-official/acme.sh/wiki/dnsapi) supports 
- [ ] API token scoped to the burner zone only
- [ ] `_acme-challenge` CNAME for **each** name on the cert → `_acme-challenge.<burner>`

**acme.sh box**
- [ ] acme.sh installed as `acmesh`, default CA set to Let's Encrypt
- [ ] Certificate issued: GlobalProtect name, **(A)** + mgmt FQDN
- [ ] **(B)** Internal root CA trusted by the box
- [ ] Mgmt identity checked (trusted cert, or fingerprint verified)
- [ ] API key generated, password discarded
- [ ] *(Panorama)* Template variables set
- [ ] First deploy done

**Firewall, once**
- [ ] Cert bound to the GlobalProtect portal/gateway SSL/TLS Service Profile
- [ ] **(A)** Cert bound to the mgmt SSL/TLS Service Profile
- [ ] Commit (*Panorama:* commit and push)

**Hands-off check**
- [ ] Deploy works *without* `--insecure`
- [ ] Renewal notifications go to a mailbox someone reads
- [ ] Calendar reminder at 80 days in case everything else fails

---

## Choose how the box will trust mgmt

Renewals run unattended, with normal TLS checks against the mgmt interface.
The acme.sh box must trust the mgmt cert, and `$FW` must be a name on it.
Pick one:

| | Mgmt cert | `$FW` is | Extra work |
|---|---|---|---|
| **(A)** | This Let's Encrypt cert | A public name, e.g. `fw-mgmt.example.com` | One more CNAME; bind the cert to mgmt in step 6 |
| **(B)** | From your internal PKI | An internal name, e.g. `fw01.corp.local` | The box must trust your internal root CA (see below) |

- **No internal PKI but don't want a public name for mgmt?** Use (B) with the
  firewall as its own CA: **Device > Certificate Management > Certificates >
  Generate**, tick *Certificate Authority*, then generate a mgmt cert signed
  by it with the mgmt FQDN as Common Name **and** as a *Host Name* attribute.
  Bind it to mgmt, and trust the firewall's CA cert on the box as below.
- **Leaving mgmt on its default self-signed cert** works for the first
  deploy only. Every renewal fails. That's not hands-off.
- **Panorama:** the cert is imported into a template, not onto Panorama
  itself, so Panorama's own mgmt can't use it. Use (B) for Panorama.

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
installs the tools and creates `acmesh`, a user that runs acme.sh and nothing
else. It has no password (nobody can log in as it directly) and no sudo. It's
called `acmesh`, not `acme`, so you don't mix it up with the firewall admin.

```bash
# Debian / Ubuntu
sudo apt update && sudo apt install -y git curl openssl cron dnsutils
# RHEL / Rocky / Alma
sudo dnf install -y git curl openssl cronie bind-utils && sudo systemctl enable --now crond

sudo useradd --create-home --shell /bin/bash acmesh
sudo chmod 700 /home/acmesh
```

**0b. Switch to it.** Every later command runs as `acmesh` unless it says
otherwise. Keep this shell open while you do step 1 in the firewall GUI.

```bash
sudo -iu acmesh
```

**0c. Set your names.** Everything below uses these variables, so the
remaining blocks paste as-is. If you open a new shell later, repeat 0b and 0c.

```bash
CERT=vpn.example.com          # name your users connect to (GlobalProtect)
FW=fw-mgmt.example.com        # mgmt FQDN: public (A) or internal (B)
FWUSER=acme                   # restricted admin you create in step 1
BURNER=burner-domain.net      # throwaway domain for DNS validation
```

## Step 1: Firewall — role and admin

**Device > Admin Roles > Add** → name `acme-deploy`

| Tab | Setting |
|---|---|
| Web UI | disable **everything** |
| XML API | disable everything, then enable **Import** and **Commit** only |
| Command Line | None |
| REST API | disable everything |

New roles start with most permissions *enabled*. Check every tab.

> Leave **Operational Requests** off. It would let a stolen key run
> `show config running`. Only Panorama pushing to a template stack needs it.

**Device > Administrators > Add** → the name you set as `$FWUSER` (e.g.
`acme`), Role Based → `acme-deploy`, long random password (you'll type it
once, in step 5).

**Device > Setup > Interfaces > Management** → if *Permitted IP Addresses*
has entries, add the acme.sh box's IP (an empty list allows any IP). Commit.

On **Panorama**, create the role (type *Panorama*) and admin the same way,
under **Panorama > Admin Roles** and **Panorama > Administrators**.

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

Issue (Cloudflare shown; any [acme.sh DNS API](https://github.com/acmesh-official/acme.sh/wiki/dnsapi) works).
Paste **one** of the two blocks.

**(A)** GlobalProtect name + mgmt name on the cert:

```bash
read -rsp 'Cloudflare token (burner zone only): ' CF_Token; echo; export CF_Token
acme.sh --issue --dns dns_cf -d "$CERT" -d "$FW" --challenge-alias "$BURNER"
unset CF_Token
```

**(B)** GlobalProtect name only:

```bash
read -rsp 'Cloudflare token (burner zone only): ' CF_Token; echo; export CF_Token
acme.sh --issue --dns dns_cf -d "$CERT" --challenge-alias "$BURNER"
unset CF_Token
```

`read -s` puts the token in the `CF_Token` variable without showing it on
screen or saving it in shell history. `export` hands it to acme.sh, whose
Cloudflare module reads exactly that variable name. acme.sh then saves the
token for renewals (see [Where the credentials live](#where-the-credentials-live)),
which is why it must only be able to edit the burner zone.

## Step 4: Check you're really talking to your firewall

```bash
if ERR="$(curl -sS -o /dev/null --connect-timeout 5 "https://$FW/" 2>&1)"; then
  echo "TRUSTED: mgmt cert verifies. Skip the rest of step 4."
  TLS=(); INSECURE=()
else
  echo "NOT TRUSTED: ${ERR%%$'\n'*}"
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
`openssl x509 -in <exported file> -noout -fingerprint -sha256` on it. **Only
if they match**, pin it:

```bash
PIN="sha256//$(openssl x509 -in fw-mgmt.pem -pubkey -noout \
  | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl base64)"
TLS=(-k --pinnedpubkey "$PIN"); INSECURE=(--insecure)
```

From here on, curl refuses to send anything unless the firewall presents
exactly that key.

## Panorama only: before step 5

Set these in the same shell. acme.sh saves them for renewals:

```bash
export PANOS_TEMPLATE="my-template"              # template to import into
export PANOS_TEMPLATE_STACK="my-stack"           # optional: also push the stack
export PANOS_CERTNAME="gp-le"                    # optional: Panorama limits names to 31 chars
```

Pushing a template stack needs **Operational Requests** on the role.
If the GlobalProtect config lives in a Panorama template, deploy to Panorama:
the firewalls get the cert with the template push.

## Step 5: API key and first deploy

**5a. Generate the API key.** The password is read hidden and handed to curl
on stdin, so it isn't in shell history or `ps`. The API key goes straight
into a variable and is never shown, so there's nothing to copy.

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

The cert appears under **Device > Certificate Management > Certificates**
(Panorama: in the template), named after `$CERT` or `$PANOS_CERTNAME`. The
hook commits only the `$FWUSER` admin's changes.

## Step 6: Firewall — bind the cert (once)

- **GlobalProtect:** Device > Certificate Management > SSL/TLS Service Profile
  → the profile used by the portal/gateway → Certificate = `vpn.example.com`
  (or create a profile and select it in the portal and gateway).
- **(A) Mgmt:** create an SSL/TLS Service Profile with the same cert →
  **Device > Setup > Management > General Settings** → SSL/TLS Service
  Profile. Mgmt now presents a publicly trusted cert that matches `$FW`.
- **(B) Mgmt:** nothing to do, it keeps its internal cert.
- Commit. **Panorama:** make these changes in the template, then commit and
  push to the devices.

## Step 7: Make renewals hands-off

**Deploy again, without `--insecure`.** If this works, renewals will too:

```bash
acme.sh --deploy -d "$CERT" --deploy-hook panos --ecc
```

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

**Check the cron job and what the firewall serves:**

```bash
crontab -l | grep acme.sh
echo | openssl s_client -connect "$CERT:443" -servername "$CERT" 2>/dev/null \
  | openssl x509 -noout -issuer -enddate
```

---

## Where the credentials live

- **Firewall password:** used once in step 5a, never stored.
- **API key:** in `~/.acme.sh/<domain>_ecc/<domain>.conf` (no `_ecc` for RSA),
  **base64-encoded, not encrypted.** Anyone who can read that file can use it.
- **Burner DNS token:** in `~/.acme.sh/account.conf`. It can only change the
  burner zone.

What a stolen key can do: import certificates or files and trigger a commit,
which also pushes other admins' pending changes. It can't change policy or
read your config.

Keep it small: a dedicated box, the `acmesh` user, `chmod 700 ~/.acme.sh`, mgmt Permitted
IPs limited to that box. If you set an API key lifetime (Device > Setup >
Management > Authentication Settings), renewals fail when the key expires.
Before then, repeat 0b, 0c, 4 (it should say `TRUSTED` by now), 5a and 5b.

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

## License

MIT
