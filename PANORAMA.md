# Panorama and many firewalls

Free, auto-renewing Let's Encrypt certificates for Panorama's own mgmt,
GlobalProtect (into a template) and the mgmt of every managed firewall, from
one Linux box, using [acme.sh](https://github.com/acmesh-official/acme.sh).

- **Video 2: Panorama and many firewalls:** Video will be available soon!
- **Single firewall, no Panorama?** Follow the
  [README](README.md) and [video 1](https://youtu.be/UmRaHxGueyY) instead.

> **Use at your own risk.** No warranty, no liability. See the [disclaimer](#disclaimer).

**Why a separate box?** Up to PAN-OS 12.2, neither the firewall nor Panorama
has a built-in ACME client, so they can't get or renew a public certificate
on their own. PAN-OS auto-enrollment (SCEP) only works with an internal CA. So
the ACME part runs on a small Linux box, and Panorama only receives the result
through its API, via acme.sh's `panos` deploy hook (a small script acme.sh runs
after every renewal to install the cert).

**Why a burner domain?** Let's Encrypt checks that you own a name by asking for
a DNS record under it. To renew on its own, acme.sh needs API access to that
DNS, but your real zone's credentials shouldn't sit on the box. So you use a
cheap throwaway domain (the "burner") at a DNS provider with an API. In your
real zone, each name gets one CNAME pointing to the burner, set once by hand.
acme.sh only ever writes to the burner zone, so a stolen box can't change your
real DNS. [Step 2a](#2a-dns-delegation-and-burner-zone-access) sets it up.

| Setup | Certificates you create |
|---|---|
| **GlobalProtect** on Panorama-managed firewalls | [Panorama mgmt](#step-2-panoramas-own-mgmt-cert) (Step 2) + [GlobalProtect](#step-3-globalprotect-cert) (Step 3) |
| **GlobalProtect + firewall mgmt** | the two above + [firewall mgmt](#step-4-mgmt-cert-of-every-firewall) (Step 4: one wildcard, or one per firewall) |

Two rules cover both:

- **One certificate, one target.** acme.sh saves one PAN-OS destination per
  certificate: a device (Panorama itself, or a firewall) or a Panorama
  template. More certificates simply means more entries on the same box,
  renewed by the same cron job.
- **The box must trust the mgmt it deploys to.** The renewal with Let's Encrypt
  works regardless, but delivering the new cert means an HTTPS login to
  Panorama's mgmt with normal TLS checks. If that fails, the new cert stays on
  the box and the old one keeps being served until it expires.

Without the Panorama mgmt cert (Step 2), this only works if Panorama's mgmt is
trusted another way, i.e. with a cert from your internal PKI that the box
trusts (see [If Panorama's mgmt uses your internal PKI](#if-panoramas-mgmt-uses-your-internal-pki)).
Leaving Panorama's mgmt on its default self-signed cert works for the first
deploy only. Every renewal fails. That's not hands-off.

---

## Step 0: Prepare the box and set your names

**Box already set up for a single firewall ([README](README.md), video 1)?**
Skip 0a to 0c. Run `BOXUSER=acmesh` (or the user you created then) and
`sudo -iu "$BOXUSER"`, then do 0d: set the names.

**0a. Tools**, from your normal admin account (needs sudo). This
installs the tools and sets the name of the Linux user in `$BOXUSER` (here `acmesh`),
a user that runs acme.sh and nothing else. It has no password (nobody can log
in as it directly) and no sudo. It's called `acmesh`, not `acme`, so you don't
mix it up with the Panorama admin (`$PANOUSER`, step 0d). If your company has
a naming rule for service accounts, change `BOXUSER` here.

Set the user name:

```bash
BOXUSER=acmesh
```

Install the tools. Debian / Ubuntu:

```bash
sudo apt update && sudo apt install -y git curl openssl cron dnsutils libxml2-utils
```

RHEL / Rocky / Alma:

```bash
sudo dnf install -y git curl openssl cronie bind-utils libxml2 && sudo systemctl enable --now crond
```

**0b. Create the user and switch to it.** This creates the user, locks its
home folder so only that user can read it, and opens a shell as that user.
Every later command runs as that user unless it says otherwise. Keep this
shell open while you do step 1 in the Panorama GUI.

```bash
sudo useradd --create-home --shell /bin/bash "$BOXUSER"
sudo chmod 700 "/home/$BOXUSER"
sudo -iu "$BOXUSER"
```

**0c. Install acme.sh**, as `acmesh`, from git, so you can read what you run:

```bash
git clone --depth 1 https://github.com/acmesh-official/acme.sh.git
cd acme.sh && ./acme.sh --install && cd .. && rm -rf acme.sh
. ~/.acme.sh/acme.sh.env                         # load acme.sh into this shell
acme.sh --set-default-ca --server letsencrypt
chmod 700 ~/.acme.sh
```

**0d. Set your names.** Everything below uses these variables, so the blocks
paste as-is. If you open a new shell later, you need to reset the variables.

```bash
PANO=panorama.example.com     # Panorama's mgmt FQDN: the only thing the box talks to
CERT=vpn.example.com          # name your users connect to (GlobalProtect)
PANOUSER=acme                 # restricted admin you create on Panorama in step 1
BURNER=burner-domain.net      # throwaway domain for DNS validation
```

`$PANO` must be a name on Panorama's mgmt cert. For a Let's Encrypt cert
(step 2) that's a name in a public domain you own. It only has to
resolve internally; only its `_acme-challenge` CNAME must be public.

## Step 1: Panorama admin user configuration

**Panorama > Admin Roles > Add** → name `acme-deploy`, role type **Panorama**

| Tab | Setting |
|---|---|
| Web UI | disable **everything** |
| XML API | disable everything, then enable **Import** and **Commit** only. Add **Operational Requests** only for the [full-auto push](FULL-AUTO-PUSH.md) |
| Command Line | None |
| REST API | disable everything |

New roles start with most permissions *enabled*. Check every tab.

**Panorama > Administrators > Add** → the name you set as `$PANOUSER` (e.g.
`acme`), Role Based → `acme-deploy`, long random password (you'll type it
once, in step 2c).

**Panorama > Setup > Interfaces > Management** → if *Permitted IP Addresses*
has entries, add the acme.sh box's IP (an empty list allows any IP). Commit
to Panorama.

## Step 2: Panorama's own mgmt cert

This is the first certificate, because it makes every later deploy trusted.
It's for Panorama itself, so there's no template here: the hook imports into
the device `PANOS_HOST` points to, which is Panorama. Templates only come in
at step 3.

Getting it there takes three things the other certificates reuse: access to
the burner zone (2a), a verified connection to Panorama (2b) and an API key
(2c). Then you issue and deploy it (2d) and bind it to Panorama's mgmt (2e).

### 2a. DNS delegation and burner zone access

Every certificate below is validated through one **burner domain**: a cheap
throwaway domain whose DNS is at a provider with an API (Cloudflare shown; any
[acme.sh DNS API](https://github.com/acmesh-official/acme.sh/wiki/dnsapi) works,
with its own variable names). In your **real** DNS zone, each name on a cert
gets one CNAME pointing to the burner, e.g.:

```
_acme-challenge.panorama.example.com.  CNAME  _acme-challenge.burner-domain.net.
```

Let's Encrypt follows the CNAME, and acme.sh writes the challenge into the
burner zone only. Your real zone is never touched by the box. Each certificate
section below lists its CNAMEs.

**The zone ID:** in Cloudflare, the burner domain's **Overview** page, on the
right, *Copy zone ID*. It isn't a secret, so it's read without `-s`. With it,
acme.sh knows which zone to write to, so the token needs nothing beyond
**Zone > DNS > Edit** on the burner zone. Without it, acme.sh has to look the
zone up by name, which also needs **Zone > Zone > Read** on the token.

**The token:** **My Profile > API Tokens > Create Token**, template **Edit
zone DNS**. Give it a name and, under *Zone Resources*, select only the burner
zone. An expiry date is optional, but then replace the token before it
expires, or the next renewal fails. Check the summary, create it, copy it.
One token covers every certificate below.

Enter both once, here, in the shell you keep open:

```bash
read -rp 'Cloudflare zone ID (burner zone only): ' CF_Zone_ID; export CF_Zone_ID
read -rsp 'Cloudflare token (burner zone only): ' CF_Token; echo; export CF_Token
```

`read -s` puts the token in the `CF_Token` variable without showing it on
screen or saving it in shell history. `export` hands it to acme.sh, whose
Cloudflare module reads exactly that variable name. Every `--issue` below uses
it from there, so you don't enter it again. It stays set until the
[cleanup in step 5](#step-5-cleanup), like the API key from step 2c. acme.sh
saves the token and zone ID into each cert's config for its renewals (see
[Where the credentials live](#where-the-credentials-live)), which is why the
token must only be able to edit the burner zone.

**Test each new name against staging first, then issue the real cert with
`--force`:**

1. **Staging.** Let's Encrypt's test server runs the same checks (CNAMEs,
   token, challenge alias) without the production rate limits. Its certs
   aren't trusted: don't deploy one.
2. **Real cert, with `--force`.** Without it, acme.sh sees the same names,
   prints `Domains not changed`, skips, and keeps renewing against staging.

Step 2d shows both runs. The other `--issue` lines below are the real
runs: for the test, run the same line with `--staging` instead of `--force`.
After the real run, `acme.sh --list` shows `LetsEncrypt.org` in the CA column;
`LetsEncrypt.org_test` means it's still the staging cert.

### 2b. Check you're really talking to Panorama

```bash
if ERR="$(curl -sS -o /dev/null --connect-timeout 5 "https://$PANO/" 2>&1)"; then
  echo "TRUSTED: mgmt cert verifies. Skip the rest of step 2b."
  TLS=(); INSECURE=()
else
  echo; echo "NOT TRUSTED: ${ERR%%$'\n'*}"; echo
fi
```

Read the reason it prints:

| Reason contains | Meaning | Next |
|---|---|---|
| `(60) SSL certificate problem` | Box can't verify Panorama's mgmt cert. Normal on a first run (still self-signed) | Fingerprint check below |
| `(60) … no alternative certificate subject name matches` | Cert is valid, but `$PANO` isn't a name on it | Fix `$PANO` or the mgmt cert |
| `(6) Could not resolve host` | `$PANO` doesn't resolve on the box | DNS or `/etc/hosts` |
| `(7) Failed to connect` / `(28) timed out` | Can't reach Panorama's mgmt on 443 | Permitted IPs, routing, host firewall |

**If it's a certificate problem**, save the cert Panorama presents and look at
its fingerprint:

```bash
echo | openssl s_client -connect "$PANO:443" -servername "$PANO" 2>/dev/null \
  | openssl x509 > pano-mgmt.pem
openssl x509 -in pano-mgmt.pem -noout -subject -fingerprint -sha256
```

Compare it with the real one: on Panorama, **Panorama > Certificate
Management > Certificates**, export the cert used by mgmt, then run
`openssl x509 -in <exported file> -noout -fingerprint -sha256` on it. If mgmt
still uses the factory default cert and it isn't in that list, open the
Panorama GUI from your admin PC instead, click the padlock, and read the
cert's SHA-256 fingerprint there. **Only if they match**, pin it:

```bash
PIN="sha256//$(openssl x509 -in pano-mgmt.pem -pubkey -noout \
  | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl base64)"
TLS=(-k --pinnedpubkey "$PIN"); INSECURE=(--insecure)
```

From here on, curl refuses to send anything unless Panorama presents exactly
that key. (acme.sh doesn't use the pin, see step 2d.)

### 2c. API key

The password is read hidden and passed to curl on stdin, so it never appears
on screen, in shell history or in `ps`. It's sent only to the Panorama you
verified in step 2b, used once to generate the API key, and removed from the
shell right after (`unset P`). The API key goes straight into a variable and
is never shown on screen.

```bash
read -rsp "Password for $PANOUSER: " P; echo
RESP="$(printf '%s' "$P" | curl -sS "${TLS[@]}" -X POST "https://$PANO/api/?type=keygen" \
    --data-urlencode "user=$PANOUSER" --data-urlencode 'password@-')"
unset P
PANOS_KEY="$(sed -n 's:.*<key>\(.*\)</key>.*:\1:p' <<<"$RESP")"
if [ -n "$PANOS_KEY" ]; then echo "API key OK"; else echo "Keygen FAILED: $RESP"; fi
unset RESP
```

Continue only if it says `API key OK`.

**Keep this shell open.** Every certificate below is deployed with this same
Panorama API key, so `$PANOS_KEY` must stay set until the last one is done.

### 2d. Issue and deploy

In your **real** DNS zone, and check it:

```
_acme-challenge.panorama.example.com.  CNAME  _acme-challenge.burner-domain.net.
```

```bash
dig +short CNAME "_acme-challenge.$PANO"
```

Staging test:

```bash
acme.sh --issue --staging --dns dns_cf -d "$PANO" --always-force-new-domain-key --challenge-alias "$BURNER"
```

Ended with `Cert success`? Then the real one, and the first deploy, in the
same shell:

```bash
acme.sh --issue --dns dns_cf -d "$PANO" --always-force-new-domain-key --challenge-alias "$BURNER" --force
export PANOS_HOST="$PANO" PANOS_USER="$PANOUSER" PANOS_KEY
acme.sh --deploy -d "$PANO" --deploy-hook panos --ecc "${INSECURE[@]}"
```

`${INSECURE[@]}` is `--insecure` only if step 2b said `NOT TRUSTED` (you
checked Panorama's identity by fingerprint instead). It applies to this run
only and isn't saved. acme.sh stores host, user and key for renewals.

`--insecure` means acme.sh doesn't check Panorama's identity on this one run;
your pin from step 2b only protected the keygen. Run this deploy right after
step 2b, so the check you just did still holds. After the bind below, every
deploy is verified.

The cert appears under **Panorama > Certificate Management > Certificates**,
named after `$PANO`. The hook commits only the `$PANOUSER` admin's changes.
It uploads acme.sh's full-chain file: your certificate **plus** the Let's
Encrypt intermediate, so clients don't fail with "untrusted certificate".

### 2e. Bind it to Panorama's mgmt

Bind once: **Panorama > Certificate Management > SSL/TLS Service Profile** →
new profile with this cert → **Panorama > Setup > Management > General
Settings** → SSL/TLS Service Profile. Commit to Panorama. Then prove the box
now trusts Panorama, and drop `--insecure` for good. The `curl` check in front
stops with the reason if Panorama doesn't present the new cert yet:

```bash
curl -sS -o /dev/null --connect-timeout 5 "https://$PANO/" \
  && acme.sh --deploy -d "$PANO" --deploy-hook panos --ecc \
  && INSECURE=()
```

**Last certificate you need?** Go to [Step 5: Cleanup](#step-5-cleanup).

## Step 3: GlobalProtect cert

This cert needs to go into the template your
GlobalProtect firewalls use, and they get it with the template push. You need to specify the template in the variable `PANOS_TEMPLATE`. If you don't set any template, acme.sh imports the certificate into Panorama's own certificate store.

Optional: `PANOS_CERTNAME` sets the object name (Panorama limits names to 31
characters). Without it, the object is named after the domain
(`vpn.example.com`), which is what the bind below assumes. If you want another
name, add e.g. `export PANOS_CERTNAME="gp-le"` under the `PANOS_TEMPLATE` line
and select that name in the bind.

Both need `export`, and **unset them right after the deploy**: acme.sh saves
them for this cert's renewals, and a leftover one would also apply to the next
cert you deploy.

In your **real** DNS zone:

```
_acme-challenge.vpn.example.com.  CNAME  _acme-challenge.burner-domain.net.
```

Set the template. Change `GP-Template` to your template's name before you
press Enter:

```bash
export PANOS_TEMPLATE="GP-Template"         # template your GlobalProtect firewalls use
```

Issue and deploy:

```bash
acme.sh --issue --dns dns_cf -d "$CERT" --always-force-new-domain-key --challenge-alias "$BURNER"
acme.sh --deploy -d "$CERT" --deploy-hook panos --ecc
```

Unset and check:

```bash
unset PANOS_TEMPLATE PANOS_CERTNAME
env | grep '^PANOS_' | cut -d= -f1          # should only show PANOS_HOST, PANOS_USER, PANOS_KEY
```

**Commit to Panorama.** The hook always commits to Panorama after the import,
and there's no option to skip it. It's a partial commit of the
`$PANOUSER` admin's changes only, so other admins' pending changes stay
uncommitted.

**The push.** acme.sh has the variable `PANOS_TEMPLATE_STACK` for it. If it's not set, acme.sh doesn't push the configuration. The problem is that the variable allows the naming of only **one**
stack, and a template like this one usually is used from many stacks. So leave it
out and pick one of two ways:

- **acme.sh commits, you push (default).** The cert waits on Panorama until
  your next regular push, in your change window. acme.sh renews roughly the
  last third of a cert's lifetime early: about a month with 90-day certs,
  about two weeks with 45-day certs. Your push schedule must fit inside that.
- **Full-auto push (optional).** Two small extra hooks push every stack
  that contains the template. See
  [FULL-AUTO-PUSH.md](FULL-AUTO-PUSH.md).

Bind once, **in the template**: **Device > Certificate Management > SSL/TLS
Service Profile** → the profile used by the portal and gateway → Certificate =
`vpn.example.com` (or create a profile and select it in the portal and
gateway). Commit and push.

**Last certificate you need?** Go to [Step 5: Cleanup](#step-5-cleanup).

### Other uses of the cert

GlobalProtect and mgmt are the common cases, not the only ones. A Let's
Encrypt cert fits anywhere the firewall is the **TLS server for a public
name**. Same flow: issue, deploy into the template, bind once in the template.

| Use | Works? | Bind it in (template) |
|---|---|---|
| GlobalProtect portal/gateway | Yes | SSL/TLS Service Profile |
| Mgmt web UI and API | Yes | SSL/TLS Service Profile → Device > Setup > Management (see step 4) |
| Authentication Portal | Yes | SSL/TLS Service Profile → Device > User Identification > Authentication Portal Settings |
| SSL Inbound Inspection | Yes, with the same cert and key on the web server | Decryption policy rule (device group), type SSL Inbound Inspection |
| SSL Forward Proxy | **No.** It needs a CA certificate that signs certs on the fly. No public CA issues one | Keep your internal CA |
| The firewall authenticating as a TLS client | **No.** Let's Encrypt certs are for servers only; the client-auth EKU was dropped in 2026 | Internal PKI |

**SSL Inbound Inspection.** The firewall needs the web server's certificate and
private key, so the firewall and the server must get the same cert. Give the
deploy two hooks: `panos` first, then one for the server (acme.sh ships many,
e.g. `ssh`). Hooks run in the order given, and if one fails the rest are
skipped, so the server never gets a cert the firewall doesn't have yet. That's
also the order Palo Alto recommends: firewall first, then the server. With
Panorama, add `PANOS_TEMPLATE_STACK` so the firewalls actually have it before
the server does. It pushes that **one** stack only, so it fits a template that
sits in a single stack; for more, see the [full-auto push](FULL-AUTO-PUSH.md):

```bash
PANOS_TEMPLATE="Web-Template" PANOS_TEMPLATE_STACK="Web-Stack" \
  acme.sh --deploy -d www.example.com --deploy-hook panos --deploy-hook ssh --ecc
```

Each hook reads its own variables on the first deploy, see the acme.sh
[deploy hooks wiki](https://github.com/acmesh-official/acme.sh/wiki/deployhooks).
Bind once: select the cert in the decryption rule (PAN-OS 10.2 and later accept
several certs per rule). With `--always-force-new-domain-key`, firewall and
server get the new key together at every renewal.

## Step 4: Mgmt cert of every firewall

Step 3 unset `PANOS_TEMPLATE`, so nothing from GlobalProtect carries over.

Pick one:

| | How | Private keys | Box talks to | Good for |
|---|---|---|---|---|
| **4a** | One wildcard cert, in a shared template | One key on every firewall | Panorama | Simplest. Hides firewall names from CT logs |
| **4b** | One cert per firewall, each into its own device template | One key per firewall | Panorama | Per-device keys, when every firewall has its own template in its stack. **Recommended for production** |
| **4c** | One cert per firewall, deployed to each firewall directly | One key per firewall | Every firewall | Exceptions only: a firewall with no device template |

Not recommended: one cert listing every firewall name. It has the same private key on all firewalls, is more complicated to manage, and lists all firewall names in it. 

All of them need firewall mgmt names in a public domain you own, e.g.
`fw01.fw.example.com`. They only have to resolve internally; only the
`_acme-challenge` CNAMEs must be public. Names like `fw01.corp.local` can't get
a public cert: use an internal ACME CA (see
[Enterprise notes](#enterprise-notes)).

### 4a. Wildcard in a shared template

```
_acme-challenge.fw.example.com.  CNAME  _acme-challenge.burner-domain.net.
```

```bash
WILD='*.fw.example.com'
export PANOS_TEMPLATE="FW-Mgmt-Template"
export PANOS_CERTNAME="fw-mgmt-wildcard"     # '*' is not allowed
```

```bash
acme.sh --issue --dns dns_cf -d "$WILD" --always-force-new-domain-key --challenge-alias "$BURNER"
acme.sh --deploy -d "$WILD" --deploy-hook panos --ecc

unset PANOS_TEMPLATE PANOS_CERTNAME
env | grep '^PANOS_' | cut -d= -f1          # should only show PANOS_HOST, PANOS_USER, PANOS_KEY
```

`PANOS_CERTNAME` gives the object a readable name. Without it, the hook
replaces the `*` and names it `WILDCARD_.fw.example.com`, which breaks
Panorama's 31-character limit on longer domains.

Bind once, in that template: SSL/TLS Service Profile with this cert →
**Device > Setup > Management > General Settings** → that profile. Commit and
push.

If one firewall is compromised, the shared key is compromised everywhere.
Renew now: `acme.sh --renew -d '*.fw.example.com' --force`. The saved
`--always-force-new-domain-key` makes a new key, and the saved deploy imports
it into the template.

**Last certificate you need?** Go to [Step 5: Cleanup](#step-5-cleanup).

### 4b. One cert per firewall, in device templates

Prerequisite: each firewall's template stack contains a template of its own
(a device template), which no other firewall uses.

One CNAME per firewall in your **real** zone, all pointing to the same burner
record. It's one record per
firewall, once.

```
_acme-challenge.fw01.fw.example.com.  CNAME  _acme-challenge.burner-domain.net.
_acme-challenge.fw02.fw.example.com.  CNAME  _acme-challenge.burner-domain.net.
```

List the firewalls in a text file in the acme.sh folder, one firewall per line,
columns separated by a space:

1. **Full mgmt name** of the firewall, e.g. `fw01.fw.example.com`
2. **Device template** of that firewall, exactly as it's named on Panorama
3. **Panorama certificate name** (optional): the name of the cert object on
   Panorama

```bash
nano ~/.acme.sh/firewalls.txt
```

```
fw01.fw.example.com FW01-Berlin
fw02.fw.example.com FW02-Paris paris-fw-mgmt
```

Without a Panorama certificate name the loop uses the short name plus `-mgmt`
(`fw01-mgmt`). Panorama allows up to 31 characters.

No template stacks in the file: the deploy only needs the template. The stacks
only matter for the push, and the [full-auto push](FULL-AUTO-PUSH.md) looks them
up on Panorama by itself.

Check every line. An empty CNAME means: fix the DNS before you go on. A
missing template means: fix the file.

```bash
while IFS=$' \t\r' read -r FQDN TPL CN <&3 || [ -n "$FQDN" ]; do
  [ -n "$FQDN" ] && echo "$FQDN [${TPL:-NO TEMPLATE}] [${CN:-${FQDN%%.*}-mgmt}] -> $(dig +short CNAME "_acme-challenge.$FQDN")"
done 3< ~/.acme.sh/firewalls.txt
```

Issue and deploy every firewall in the file:

```bash
while IFS=$' \t\r' read -r FQDN TPL CN <&3 || [ -n "$FQDN" ]; do
  [ -n "$FQDN" ] || continue
  [ -n "$TPL" ] || { echo "SKIPPED $FQDN: no template in firewalls.txt"; continue; }
  export PANOS_TEMPLATE="$TPL" PANOS_CERTNAME="${CN:-${FQDN%%.*}-mgmt}"
  acme.sh --issue --dns dns_cf -d "$FQDN" --always-force-new-domain-key --challenge-alias "$BURNER" \
  && acme.sh --deploy -d "$FQDN" --deploy-hook panos --ecc
done 3< ~/.acme.sh/firewalls.txt
unset PANOS_TEMPLATE PANOS_CERTNAME
env | grep '^PANOS_' | cut -d= -f1          # should only show PANOS_HOST, PANOS_USER, PANOS_KEY
```

Each pass of the loop sets the template and the object name from the file
(no name in the file: the short name, `fw01-mgmt`), so every firewall's cert
goes into its own template. A line without a template is skipped, not deployed.

**New firewall?** Add its line and CNAME, and run the same loop again.
Firewalls that already have a cert are skipped (`Skipping`, not due yet); only
the new one is issued and deployed. Renewals don't need the file, acme.sh
remembers every cert with its template.

Bind once per device template (mgmt SSL/TLS Service Profile with that
firewall's cert), commit and push. If you want renewals to get automatically pushed, use the
[full-auto push](FULL-AUTO-PUSH.md) hooks.

**Last certificate you need?** Go to [Step 5: Cleanup](#step-5-cleanup).

### 4c. Deploy directly to each firewall (not recommended with Panorama)

If a firewall has no device template in its stack, acme.sh can deploy to it
directly, exactly as in the single-firewall [README](README.md). Each firewall
then needs its own API admin, API key and trust check, which doesn't scale.
Use it only for an odd firewall or two, and move to 4a or 4b as soon as you
can.

## Step 5: Cleanup

Do this after your last certificate, whichever step that was. It removes the
Cloudflare token and the Panorama API key from the shell. acme.sh already has
its own copies for the renewals, so nothing stops working:

```bash
unset CF_Token CF_Zone_ID PANOS_KEY
env | grep -E '^(CF_|PANOS_)' | cut -d= -f1   # should only show PANOS_HOST and PANOS_USER
```

Closing the shell (`exit`, or closing the SSH session) clears every variable
too. So if you skipped this step and the shell is already closed, there's
nothing left to clean. The `unset` is for when you keep working in the same
shell, e.g. for the checks below.

---

## Prove it

Panorama: open `https://panorama.example.com` in a browser, the padlock should
show Let's Encrypt. A firewall, after the push:

```bash
echo | openssl s_client -connect fw01.fw.example.com:443 -servername fw01.fw.example.com 2>/dev/null \
  | openssl x509 -noout -subject -issuer -enddate
```

GlobalProtect, with the full chain:

```bash
echo | openssl s_client -connect "$CERT:443" -servername "$CERT" 2>/dev/null \
  | grep -E '^ *[0-9]+ s:|^ +i:'
```

`0` is your certificate, `1` the Let's Encrypt intermediate (e.g. `YE2`), and
there may be a `2`. If you only see `0`, the intermediate is missing and some
clients will reject the certificate.

Every cert on the box, when each renews next (`Renew` column), and the cron
job that does it:

```bash
acme.sh --list
crontab -l | grep acme.sh
```

What acme.sh saved for one cert: the hooks it runs (`Le_DeployHook`), and the
template and object name it deploys to (`SAVED_PANOS_TEMPLATE`,
`SAVED_PANOS_CERTNAME`). Use a `Main_Domain` from the `--list` output:

```bash
acme.sh --info -d fw01.fw.example.com
```

The output also shows `SAVED_PANOS_KEY`, your API key. Don't share it, and
blur it in screenshots.

## Production ready

### Get told about failures

Send notifications to a team, not a person: a shared mailbox or a Teams
channel. At the default level they cover errors and successful renewals, so
silence means something is wrong. SMTP example (other hooks: mail, Teams,
Slack, Telegram, …):

```bash
export SMTP_FROM=acme@example.com SMTP_TO=pki-team@example.com \
       SMTP_HOST=smtp.example.com SMTP_SECURE=tls \
       SMTP_USERNAME=acme@example.com
read -rsp 'SMTP password: ' SMTP_PASSWORD; echo; export SMTP_PASSWORD
acme.sh --set-notify --notify-hook smtp
unset SMTP_PASSWORD
```

Mail can fail silently too, so also have your monitoring (e.g. CheckMK) alert
on the expiry date Panorama and the firewalls actually serve.

### Monitor expiry from outside

Don't rely on the box to report its own failures. Point the monitoring you
already have at every mgmt interface and the GlobalProtect portal, and alert
well before expiry. Any TLS expiry check works; the bare version, which fails
when less than 14 days remain:

```bash
echo | openssl s_client -connect fw01.fw.example.com:443 -servername fw01.fw.example.com 2>/dev/null \
  | openssl x509 -noout -checkend 1209600
```

### Lock the names with CAA

A CAA record tells every CA which CA, and which account, may issue for a name.
With it, a stolen burner token alone is useless: the thief's ACME account isn't
yours, so Let's Encrypt refuses.

Get your account URL (production, not staging):

```bash
grep ACCOUNT_URL ~/.acme.sh/ca/acme-v02.api.letsencrypt.org/directory/ca.conf
```

In your **real** zone, one record each on `panorama.example.com`,
`vpn.example.com` and `fw.example.com`, with that URL. The `fw.example.com`
record covers the wildcard and every firewall name below it:

```
panorama.example.com.  CAA 0 issue "letsencrypt.org; accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/123456789; validationmethods=dns-01"
vpn.example.com.       CAA 0 issue "letsencrypt.org; accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/123456789; validationmethods=dns-01"
fw.example.com.        CAA 0 issue "letsencrypt.org; accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/123456789; validationmethods=dns-01"
```

Check what's published:

```bash
dig +short CAA "$PANO"
dig +short CAA "$CERT"
dig +short CAA fw.example.com
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

### Shorter certificate lifetimes (47 days by 2029)

Public TLS certificates are getting shorter: 200 days maximum since March
2026, 100 days from March 2027, 47 days from March 2029 (CA/Browser Forum
ballot SC-081). Let's Encrypt is ahead of that: its default drops from 90 to
64 days on 10 February 2027, and to 45 days on 16 February 2028.

**You don't need to change anything.** acme.sh asks Let's Encrypt when to
renew each certificate (ARI) and renews inside that window, so the schedule
follows the lifetime on its own. What changes is how often Panorama gets an
import and commit, and how much time your push schedule has (see
step 3): with 45-day certs, a renewal about once a month, two weeks
before expiry.

**Optional: pick the lifetime.** With Let's Encrypt you can't request a number
of days. You pick a profile by adding it to the `--issue` line:

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
too. That's why every `--issue` line above has `--always-force-new-domain-key`:
every renewal comes with a fresh key, and a leaked key dies with its cert. With
one wildcard on many firewalls (4a), that matters most. The deploy imports
cert and key together, so nothing else is needed.

**Issued without it?** Run that cert's production `--issue` line again with
the option and `--force` added. That issues a new certificate now. Then run
its deploy line (with its `PANOS_TEMPLATE`, if any). acme.sh saves the options
for all future renewals.

### Operational Requests: think twice

With it, a stolen key can also read your whole configuration and push to every
firewall. Leaving it off and pushing in your change window is the safer
default.

### Where the credentials live

- **Panorama password:** used once in step 2c, never stored.
- **API key:** in each cert's `~/.acme.sh/<domain>_ecc/<domain>.conf` (no
  `_ecc` for RSA), **base64-encoded, not encrypted.** Anyone who can read that
  file can use it.
- **Burner DNS token:** in each cert's `~/.acme.sh/<domain>_ecc/<domain>.conf`,
  next to the API key (with `CF_Zone_ID` set; without it, in
  `~/.acme.sh/account.conf`). It can only change the burner zone. It can't
  touch your real DNS, but it can pass validation for every name whose
  `_acme-challenge` CNAME points to the burner, i.e. get a valid cert for those
  names. [CAA](#lock-the-names-with-caa) closes that.

What a stolen Panorama key can do: import certificates or files into Panorama
and its templates, and trigger a commit. That commit is partial, only the acme
admin's own changes, so other admins' pending changes stay uncommitted. Without
Operational Requests it can't push, change policy or read your config.

The box holds the Panorama API key, the burner token and your ACME account
key, and so does its backup. Treat it as important, and keep it small: a
dedicated box, the `acmesh` user, `chmod 700 ~/.acme.sh`, mgmt Permitted IPs
limited to that box.

### New API key

If you set an API key lifetime (Panorama > Setup > Management >
Authentication Settings), renewals fail when the key expires. Before then:
set `BOXUSER`, run `sudo -iu "$BOXUSER"` and repeat 0d, then steps 2b (it should say `TRUSTED` by
now) and 2c. acme.sh saves the key separately for each cert, so run **each**
cert's deploy line once with the new key exported (and its `PANOS_TEMPLATE`
in front, if it has one), not just one of them:

```bash
export PANOS_HOST="$PANO" PANOS_USER="$PANOUSER" PANOS_KEY
acme.sh --deploy -d "$PANO" --deploy-hook panos --ecc
PANOS_TEMPLATE="GP-Template" acme.sh --deploy -d "$CERT" --deploy-hook panos --ecc
# ... one line per cert from acme.sh --list
unset PANOS_KEY
```

## Enterprise notes

- **Keep GlobalProtect and mgmt in separate certs.** Every user sees the names
  on the GlobalProtect cert, and a separate cert means a separate key.
- **Certificate Transparency.** Every name on a public cert is logged publicly,
  forever, and searchable (e.g. crt.sh). A wildcard (4a) shows only
  `*.fw.example.com`.
- **Internal CA for mgmt.** If policy forbids public certs on mgmt, keep the same
  pipeline with your own CA: acme.sh works with any ACME server, via
  `--server https://<your-ca>/acme/directory` on `--issue`. The box must trust
  that CA, see below. How validation works depends on your CA.
- **Rate limit.** Let's Encrypt issues up to 50 new certs per registered domain
  per 7 days. Roll out more than 50 firewalls (4b) over several weeks.
  Renewals don't count against it.
- **Change windows.** Leave out `PANOS_TEMPLATE_STACK` and let your regular push
  deliver the certs.
- **Panorama HA.** Put both peers' names on Panorama's own mgmt cert (step 2):
  `-d panorama1.example.com -d panorama2.example.com`, each with its own
  `_acme-challenge` CNAME, and deploy with `PANOS_HOST` set to the primary
  peer. HA syncs the certificate and the SSL/TLS Service Profile to the other
  peer, but not the mgmt **General Settings**, so select the profile there
  once on **each** peer. If the primary is down
  when a renewal runs, the deploy fails and acme.sh retries the next day.

### If Panorama's mgmt uses your internal PKI

Then you can skip steps 2d and 2e, but the box must trust the root CA that signed
Panorama's mgmt cert, and `$PANO` must be a name on that cert (or the mgmt IP,
if your CA put it on the cert). Managed servers often trust the corporate root
already. Step 2b tells you: `TRUSTED` means you're set.

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

No internal PKI but don't want a public name for Panorama's mgmt? Use Panorama
as its own CA: **Panorama > Certificate Management > Certificates >
Generate**, tick *Certificate Authority*, then generate a mgmt cert signed by
it with the mgmt FQDN as Common Name **and** as a *Host Name* attribute. Bind
it to mgmt, and trust Panorama's CA cert on the box as above.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `dig` shows no CNAME | Record missing, or created in the burner zone instead of the real one |
| Issue fails with DNS error | Token can't edit the burner zone, or the CNAME target is wrong |
| Step 2b: `unable to load certificate` | Box can't reach Panorama's mgmt on 443: Permitted IPs, routing, or wrong `$PANO` |
| Step 2b says NOT TRUSTED with an internal mgmt cert | Root CA not in the box's trust store ([see above](#if-panoramas-mgmt-uses-your-internal-pki)), or `$PANO` isn't a name on the mgmt cert |
| Keygen: `(90) public key does not match` | Panorama's key changed, or something is intercepting. Redo step 2b |
| Keygen returns error | Wrong password, or the role has no XML API access |
| Import fails | Role missing **Import** |
| Deploy fails: key/cert file not found | ECDSA cert without `--ecc` (or RSA with it). Check `acme.sh --list` |
| Commit fails | Role missing **Commit**, or another admin holds a config lock |
| Verified deploy after the bind fails with a TLS error | Panorama isn't presenting the new cert yet, or the name isn't on it: check the bind and commit |
| Cert landed in a template instead of on Panorama itself (or the other way round) | A `PANOS_TEMPLATE` from an earlier `export` was saved into this cert's config. Remove the line: `sed -i '/^SAVED_PANOS_TEMPLATE/d' ~/.acme.sh/<domain>_ecc/<domain>.conf`, then deploy again |
| Deploy to Panorama fails on the object name | Name longer than 31 characters (wildcards become `WILDCARD_.<domain>`). Set a shorter `PANOS_CERTNAME` |
| Full-auto push: `panos_check: could not read the template stack status` | Role missing **Operational Requests** (the next log line shows Panorama's own error). Enable it, commit on Panorama, rerun. See [FULL-AUTO-PUSH.md Step 1](FULL-AUTO-PUSH.md#step-1-add-operational-requests-to-the-role) |
| Full-auto push: `panos_push: … There is no connected device to perform selective push.` | No firewall in that template stack is connected to Panorama. Check **Panorama > Managed Devices > Summary**, then push the stack yourself. The cert is imported and committed on Panorama already |
| Cert is in the template, firewalls don't have it | Not pushed yet. Push the template stack, or use the [full-auto push](FULL-AUTO-PUSH.md) |
| Users still see the old cert | Not pushed yet, or the SSL/TLS Service Profile in the template points at a different cert object |
| 4b: only the first firewall gets a cert | A command in the loop read from stdin. Use the loop as shown, with `3<` and `<&3` |
| 4b: issue fails for a name that looks right | Check `~/.acme.sh/firewalls.txt` with `cat -A ~/.acme.sh/firewalls.txt`: each line must end in `$` with nothing hidden before it. The loop strips `\r`, but not other stray characters |
| Issue fails: too many certificates | Let's Encrypt limit of 50 new certs per registered domain per 7 days. Spread the rollout |
| Issue fails with a CAA error | CAA `accounturi` doesn't match: staging account, or a different acme.sh install |
| `Domains not changed` … `Skipping` after the staging test | The real run needs `--force` (step 2a). `acme.sh --list` shows `LetsEncrypt.org_test` in the CA column while it's still the staging cert |
| Browser says the cert isn't trusted, issuer mentions "STAGING" | A staging cert was deployed. Issue the real one with `--force`, then deploy again |

## Disclaimer

This guide and everything in this repository are provided **as is**, without
warranty of any kind, under the MIT License. You use them at your own risk. I
accept no liability for certificates that don't renew, expired certificates,
outages or any other damage, including damage caused by changes in acme.sh,
Let's Encrypt, PAN-OS or anything else outside my control. Test in a lab
first, and **monitor your certificates' expiry dates yourself**: automation
can fail without anyone noticing.

## License

MIT
