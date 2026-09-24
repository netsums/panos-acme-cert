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

Print this, or tick it off as you follow the steps below.

**Firewall**
- [ ] Admin Role `acme-deploy`: XML API **Import** + **Commit** only, everything else off
- [ ] Administrator `acme` with that role and a long random password
- [ ] acme.sh box's IP added to mgmt *Permitted IP Addresses*, if list not empty
- [ ] Mgmt reachable from the box by an FQDN (DNS or `/etc/hosts`)

**DNS**
- [ ] Throwaway ("burner") domain on a DNS provider acme.sh supports (https://github.com/acmesh-official/acme.sh/wiki/dnsapi)
- [ ] API token scoped to the burner zone only
- [ ] `_acme-challenge` CNAME for **each** name on the cert → `_acme-challenge.<burner>`

**acme.sh box**
- [ ] acme.sh installed as a dedicated, non-root user, default CA set to Let's Encrypt
- [ ] Certificate issued (GlobalProtect name **+ mgmt FQDN**)
- [ ] Mgmt certificate fingerprint verified before sending the password
- [ ] API key generated, password discarded
- [ ] First deploy done

**Firewall, once**
- [ ] Cert bound to the GlobalProtect portal/gateway SSL/TLS Service Profile
- [ ] Cert bound to the mgmt SSL/TLS Service Profile (**renewals depend on this**)
- [ ] Commit

**Hands-off check**
- [ ] Deploy works *without* `--insecure`
- [ ] Renewal notifications go to a mailbox someone reads
- [ ] Calendar reminder at 80 days in case everything else fails

---

## Step 0: Set your names (paste in every new shell)

Everything below uses these variables, so the remaining blocks paste as-is.

```bash
CERT=vpn.example.com          # name your users connect to (GlobalProtect)
FW=fw-mgmt.example.com        # mgmt FQDN, also put on the cert (see step 3)
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

**Device > Administrators > Add** → `acme`, Role Based → `acme-deploy`, long
random password (you'll type it once, below).

**Device > Setup > Interfaces > Management** → add the acme.sh box's IP to
*Permitted IP Addresses*. Commit.

## Step 2: acme.sh box — install

Use a dedicated user, not root. Install from git so you can read what you run:

```bash
git clone --depth 1 https://github.com/acmesh-official/acme.sh.git
cd acme.sh && ./acme.sh --install -m you@example.com && cd .. && rm -rf acme.sh
exec "$SHELL"                                    # reload so 'acme.sh' is on PATH
acme.sh --set-default-ca --server letsencrypt
chmod 700 ~/.acme.sh
```

## Step 3: DNS delegation and issuing

Put **both** the GlobalProtect name and the mgmt FQDN on the cert. Binding it
to mgmt later is what makes renewals work without `--insecure`.

In your **real** DNS zone, one CNAME per name:

```
_acme-challenge.vpn.example.com.      CNAME  _acme-challenge.burner-domain.net.
_acme-challenge.fw-mgmt.example.com.  CNAME  _acme-challenge.burner-domain.net.
```

Check them:

```bash
dig +short CNAME "_acme-challenge.$CERT"
dig +short CNAME "_acme-challenge.$FW"
```

Issue (Cloudflare shown; any [acme.sh DNS API](https://github.com/acmesh-official/acme.sh/wiki/dnsapi) works):

```bash
read -rsp 'Cloudflare token (burner zone only): ' CF_Token; echo; export CF_Token
acme.sh --issue --dns dns_cf -d "$CERT" -d "$FW" --challenge-alias "$BURNER"
unset CF_Token
```

acme.sh saves the token for renewals. That's why it must only be able to edit
the burner zone.

## Step 4: API key

**4a. Check you're really talking to your firewall.** Mgmt is probably still
on its self-signed cert, so TLS can't verify it for you. Save the cert it
presents and look at its fingerprint:

```bash
echo | openssl s_client -connect "$FW:443" -servername "$FW" 2>/dev/null \
  | openssl x509 > fw-mgmt.pem
openssl x509 -in fw-mgmt.pem -noout -subject -fingerprint -sha256
```

Compare it with the real one: on the firewall, **Device > Certificate
Management > Certificates**, export the cert used by mgmt, then run
`openssl x509 -in <exported file> -noout -fingerprint -sha256` on it. **Only
continue if they match.**

**4b. Generate the key.** The password is read hidden and handed to curl on
stdin, so it isn't in shell history or `ps`. `--pinnedpubkey` makes curl
refuse to send anything unless the firewall presents the key you just checked.

```bash
PIN="sha256//$(openssl x509 -in fw-mgmt.pem -pubkey -noout \
  | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl base64)"

read -rsp 'Password for acme: ' P; echo
printf '%s' "$P" | curl -sS -k --pinnedpubkey "$PIN" -X POST "https://$FW/api/?type=keygen" \
    --data-urlencode 'user=acme' --data-urlencode 'password@-'; echo
unset P
```

Output: `<response status = 'success'><result><key>LUFRPT…</key></result></response>`.
Copy the key.

## Step 5: First deploy

```bash
read -rsp 'API key: ' PANOS_KEY; echo
export PANOS_HOST="$FW" PANOS_USER=acme PANOS_KEY

acme.sh --list    # KeyLength "ec-256" = ECDSA → keep --ecc. "2048" → remove --ecc
acme.sh --deploy -d "$CERT" --deploy-hook panos --ecc --insecure
unset PANOS_KEY
```

`--insecure` is needed **this once** because mgmt is still self-signed (you
checked its identity in 4a). It is not saved. acme.sh stores host, user and key
for renewals.

The cert appears under **Device > Certificate Management > Certificates**,
named after `$CERT`. The hook commits only the `acme` admin's changes.

## Step 6: Firewall — bind the cert (once)

- **GlobalProtect:** Device > Certificate Management > SSL/TLS Service Profile
  → the profile used by the portal/gateway → Certificate = `vpn.example.com`
  (or create a profile and select it in the portal and gateway).
- **Mgmt:** create an SSL/TLS Service Profile with the same cert → **Device >
  Setup > Management > General Settings** → SSL/TLS Service Profile.
- Commit.

Mgmt now presents a publicly trusted cert that matches `$FW`.

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

- **Firewall password:** used once in step 4, never stored.
- **API key:** in `~/.acme.sh/<domain>_ecc/<domain>.conf` (no `_ecc` for RSA),
  **base64-encoded, not encrypted.** Anyone who can read that file can use it.
- **Burner DNS token:** in `~/.acme.sh/account.conf`. It can only change the
  burner zone.

What a stolen key can do: import certificates or files and trigger a commit,
which also pushes other admins' pending changes. It can't change policy or
read your config.

Keep it small: a dedicated box or user, `chmod 700 ~/.acme.sh`, mgmt Permitted
IPs limited to that box. If you set an API key lifetime (Device > Setup >
Management > Authentication Settings), renewals fail when the key expires.
Repeat step 4 before then.

## Panorama

Set these before the deploy in step 5. They're saved for renewals:

```bash
export PANOS_TEMPLATE="my-template"              # template to import into
export PANOS_TEMPLATE_STACK="my-stack"           # optional: also push the stack
export PANOS_CERTNAME="gp-le"                    # optional: Panorama limits names to 31 chars
```

Pushing a template stack needs **Operational Requests** on the role.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `dig` shows no CNAME | Record missing, or created in the burner zone instead of the real one |
| Issue fails with DNS error | Token can't edit the burner zone, or the CNAME target is wrong |
| Keygen: `(90) public key does not match` | The firewall's key changed, or something is intercepting. Redo 4a |
| Keygen returns error | Wrong password, or the role has no XML API access |
| Import fails | Role missing **Import** |
| Deploy fails: key/cert file not found | ECDSA cert without `--ecc` (or RSA with it). Check `acme.sh --list` |
| Commit fails | Role missing **Commit**, or another admin holds a config lock |
| Step 7 deploy fails with a TLS error | Mgmt isn't presenting the new cert yet, or `$FW` isn't a name on it. Redo step 6 |
| Users still see the old cert | The SSL/TLS Service Profile points at a different cert object |

## License

MIT
