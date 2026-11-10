# Panorama and many firewalls

Scenarios 3 and 4 of [panos-acme-cert](README.md): free, auto-renewing Let's
Encrypt certificates for Panorama's own mgmt, GlobalProtect (into a
template) and the mgmt of every managed firewall, from one Linux box.

- **Video 2: Panorama and many firewalls:** Video will be available soon!
- **Single firewall (scenarios 1 and 2)?** Follow the [README](README.md) and
  [video 1](https://youtu.be/UmRaHxGueyY) instead. This guide builds on it.

acme.sh talks **only to Panorama**: one API admin (on Panorama), one mgmt to
trust (Panorama's), and the firewalls get everything with the normal template
push. The firewalls need no API admin.

| # | Setup | Certificates |
|---|---|---|
| **3** | GlobalProtect on Panorama-managed firewalls | 2: [Panorama mgmt](#certificate-1-panoramas-own-mgmt-always-first) + [GlobalProtect](#certificate-2-globalprotect-into-its-template) |
| **4** | Enterprise: 3 + mgmt of every firewall | 3 or more: the two above + [firewall mgmt](#certificate-3-mgmt-of-every-firewall) (wildcard or one per firewall) |

Scenario 3 without the Panorama mgmt cert only works if Panorama's mgmt is
trusted another way, i.e. with your internal PKI, option
[(B)](README.md#choose-how-the-box-will-trust-mgmt).

<!-- TODO Ricardo, verify in the lab before merging:
     - Panorama role type "Panorama" with XML API Import + Commit (Web UI all off) can import into
       Panorama's own store AND into templates. Palo Alto docs say custom roles committing template
       changes may need read-write on Panorama > Templates.
     - Mgmt SSL/TLS Service Profile set from a shared template (3a) and from a device template (3b)
       is applied on the firewalls after the push.
     - 3b: running the loop again with fw01 done and fw02 added shows "Skipping" for fw01.
     - Panorama HA: does each Panorama peer need its own mgmt cert?
     - SSL Inbound Inspection via Panorama: can a decryption rule in a device group select a
       certificate that lives in a template? -->

---

## Step 0: The box, acme.sh and your names

From the [README](README.md), do these exactly as for a single firewall:

- [Step 0](README.md#step-0-prepare-the-box-and-set-your-names) **0a and 0b**:
  tools, the `acmesh` user, switch to it. Skip 0c, the names are below.
- [Step 2](README.md#step-2-install-acmesh): install acme.sh.

Then set your names. Everything below uses these variables, so the blocks
paste as-is. If you open a new shell later, set `BOXUSER` again, repeat 0b,
then this block.

```bash
PANO=panorama.example.com     # Panorama's mgmt FQDN: the only thing the box talks to
CERT=vpn.example.com          # name your users connect to (GlobalProtect)
FWUSER=acme                   # restricted admin you create on Panorama in step 1
BURNER=burner-domain.net      # throwaway domain for DNS validation
```

## Step 1: Panorama admin user configuration

**Panorama > Admin Roles > Add** → name `acme-deploy`, role type **Panorama**

| Tab | Setting |
|---|---|
| Web UI | disable **everything** |
| XML API | disable everything, then enable **Import** and **Commit** only. Add **Operational Requests** only if acme.sh should push to the firewalls itself (`PANOS_TEMPLATE_STACK`) |
| Command Line | None |
| REST API | disable everything |

New roles start with most permissions *enabled*. Check every tab.

**Panorama > Administrators > Add** → the name you set as `$FWUSER` (e.g.
`acme`), Role Based → `acme-deploy`, long random password (you'll type it
once, in step 4).

**Panorama > Setup > Interfaces > Management** → if *Permitted IP Addresses*
has entries, add the acme.sh box's IP. Commit to Panorama.

## Step 2: Burner zone access

The same burner zone and Cloudflare token as in the README
([step 3](README.md#step-3-dns-delegation-and-issuing) explains both). Every
certificate below goes through that one burner zone, so the token still only
needs **Zone > DNS > Edit** on it. Each issue block below starts with:

```bash
read -rp 'Cloudflare zone ID (burner zone only): ' CF_Zone_ID; export CF_Zone_ID
read -rsp 'Cloudflare token (burner zone only): ' CF_Token; echo; export CF_Token
```

and ends with `unset CF_Token`. acme.sh saves both for renewals.

**Test each new name against staging first**, then run the real issue with
`--force` added (see [step 3](README.md#step-3-dns-delegation-and-issuing)
for why). Certificate 1 shows both runs. The other `--issue` lines below are
the real runs: add `--staging` for the test, `--force` for the real one.

## Step 3: Check you're really talking to Panorama

```bash
if ERR="$(curl -sS -o /dev/null --connect-timeout 5 "https://$PANO/" 2>&1)"; then
  echo "TRUSTED: mgmt cert verifies. Skip the rest of step 3."
  TLS=(); INSECURE=()
else
  echo; echo "NOT TRUSTED: ${ERR%%$'\n'*}"; echo
fi
```

On a first run Panorama's mgmt is usually still self-signed, so it says
`NOT TRUSTED` with `(60) SSL certificate problem`. That's normal. Other
reasons are in the [README step 4 table](README.md#step-4-check-youre-really-talking-to-your-firewall).

Save the cert Panorama presents and look at its fingerprint:

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

## Step 4: API key

```bash
read -rsp "Password for $FWUSER: " P; echo
RESP="$(printf '%s' "$P" | curl -sS "${TLS[@]}" -X POST "https://$PANO/api/?type=keygen" \
    --data-urlencode "user=$FWUSER" --data-urlencode 'password@-')"
unset P
PANOS_KEY="$(sed -n 's:.*<key>\(.*\)</key>.*:\1:p' <<<"$RESP")"
if [ -n "$PANOS_KEY" ]; then echo "API key OK"; else echo "Keygen FAILED: $RESP"; fi
unset RESP
```

Continue only if it says `API key OK`. The
[README step 5a](README.md#step-5-api-key-and-first-deploy) explains why the
password never shows up anywhere.

**Keep this shell open.** Every certificate below is deployed with this same
Panorama API key, so `$PANOS_KEY` must stay set until the last one is done.

## Step 5: Where the cert lands: `PANOS_TEMPLATE`

- **Not set:** the hook imports into the device `PANOS_HOST` points to. With
  Panorama, that's Panorama's own certificate store, for Panorama's mgmt.
- **Set:** the hook imports into that template, and the firewalls get the cert
  with the template push.

```bash
PANOS_TEMPLATE="my-template"         # template to import into
PANOS_TEMPLATE_STACK="my-stack"      # optional: also push the stack (role needs Operational Requests)
PANOS_CERTNAME="gp-le"               # optional: object name, Panorama limits names to 31 chars
```

Put them **in front of the deploy command**, not `export`. acme.sh saves every
`PANOS_*` variable it finds in the environment into the config of the cert
it's deploying. An exported `PANOS_TEMPLATE` is still set when you deploy the
next cert, so that one lands in the template too.

---

## Certificate 1: Panorama's own mgmt (always first)

This cert makes every later deploy trusted. No template variables: the hook
imports into Panorama itself.

In your **real** DNS zone, and check it:

```
_acme-challenge.panorama.example.com.  CNAME  _acme-challenge.burner-domain.net.
```

```bash
dig +short CNAME "_acme-challenge.$PANO"
```

Staging test:

```bash
read -rp 'Cloudflare zone ID (burner zone only): ' CF_Zone_ID; export CF_Zone_ID
read -rsp 'Cloudflare token (burner zone only): ' CF_Token; echo; export CF_Token
acme.sh --issue --staging --dns dns_cf -d "$PANO" --always-force-new-domain-key --challenge-alias "$BURNER"
```

Ended with `Cert success`? Then the real one, and the first deploy, in the
same shell:

```bash
acme.sh --issue --dns dns_cf -d "$PANO" --always-force-new-domain-key --challenge-alias "$BURNER" --force
unset CF_Token
export PANOS_HOST="$PANO" PANOS_USER="$FWUSER" PANOS_KEY
acme.sh --deploy -d "$PANO" --deploy-hook panos --ecc "${INSECURE[@]}"
```

The cert appears under **Panorama > Certificate Management > Certificates**.
`${INSECURE[@]}` is `--insecure` only if step 3 said `NOT TRUSTED`; see the
[README step 5b](README.md#step-5-api-key-and-first-deploy) for what that
means and why to run it right after the fingerprint check.

Bind once: **Panorama > Certificate Management > SSL/TLS Service Profile** →
new profile with this cert → **Panorama > Setup > Management > General
Settings** → SSL/TLS Service Profile. Commit to Panorama. Then prove the box
now trusts Panorama, and drop `--insecure` for good:

```bash
curl -sS -o /dev/null --connect-timeout 5 "https://$PANO/" \
  && acme.sh --deploy -d "$PANO" --deploy-hook panos --ecc \
  && INSECURE=()
```

## Certificate 2: GlobalProtect, into its template

```
_acme-challenge.vpn.example.com.  CNAME  _acme-challenge.burner-domain.net.
```

```bash
read -rp 'Cloudflare zone ID (burner zone only): ' CF_Zone_ID; export CF_Zone_ID
read -rsp 'Cloudflare token (burner zone only): ' CF_Token; echo; export CF_Token
acme.sh --issue --dns dns_cf -d "$CERT" --always-force-new-domain-key --challenge-alias "$BURNER"
unset CF_Token
PANOS_TEMPLATE="GP-Template" PANOS_TEMPLATE_STACK="GP-Stack" \
  acme.sh --deploy -d "$CERT" --deploy-hook panos --ecc
```

`PANOS_TEMPLATE_STACK` is optional. With it, acme.sh also pushes the stack to
the firewalls (the role needs **Operational Requests**). Without it, acme.sh
only commits to Panorama and your next regular push delivers the cert, which
fits change windows. acme.sh renews roughly the last third of a cert's
lifetime early: about a month with 90-day certs, about two weeks with 45-day
certs. Your push schedule must fit inside that.

Bind once, **in the template**: SSL/TLS Service Profile with this cert, used by
the portal and gateway. Commit and push.

The same works for the other uses in the README's
[Other uses](README.md#other-uses-of-the-cert) table (Authentication Portal,
SSL Inbound Inspection): with Panorama, the cert goes into the template.

## Certificate 3: Mgmt of every firewall

Pick one:

| | How | Private keys | Box talks to | Good for |
|---|---|---|---|---|
| **3a** | One wildcard cert, in a shared template | One key on every firewall | Panorama | Simplest. Hides firewall names from CT logs |
| **3b** | One cert per firewall, each into its own device template | One key per firewall | Panorama | Per-device keys, when every firewall has its own template in its stack |
| **3c** | One cert per firewall, deployed to each firewall directly | One key per firewall | Every firewall | No per-device templates |

Not recommended: one cert listing every firewall name. It has the shared key of
3a, and publishes every firewall name in the Certificate Transparency logs.

All three need firewall mgmt names in a public domain you own, e.g.
`fw01.fw.example.com`. They only have to resolve internally; only the
`_acme-challenge` CNAMEs must be public. Names like `fw01.corp.local` can't get
a public cert: use (B) with an internal ACME CA (see
[Enterprise notes](#enterprise-notes)).

### 3a. Wildcard in a shared template

```
_acme-challenge.fw.example.com.  CNAME  _acme-challenge.burner-domain.net.
```

```bash
read -rp 'Cloudflare zone ID (burner zone only): ' CF_Zone_ID; export CF_Zone_ID
read -rsp 'Cloudflare token (burner zone only): ' CF_Token; echo; export CF_Token
acme.sh --issue --dns dns_cf -d '*.fw.example.com' --always-force-new-domain-key --challenge-alias "$BURNER"
unset CF_Token
PANOS_TEMPLATE="FW-Mgmt-Template" PANOS_CERTNAME="fw-mgmt-wildcard" \
  acme.sh --deploy -d '*.fw.example.com' --deploy-hook panos --ecc
```

`PANOS_CERTNAME` gives the object a readable name. Without it, the hook
replaces the `*` and names it `WILDCARD_.fw.example.com`, which breaks
Panorama's 31-character limit on longer domains.

Bind once, in that template: SSL/TLS Service Profile with this cert →
**Device > Setup > Management > General Settings** → that profile. Commit and
push. Every firewall with that template in its stack then presents the cert
for its `fwNN.fw.example.com` name.

If one firewall is compromised, the shared key is compromised everywhere.
Renew now: `acme.sh --renew -d '*.fw.example.com' --force`. The saved
`--always-force-new-domain-key` makes a new key, and the saved deploy imports
it into the template.

### 3b. One cert per firewall, in device templates

Prerequisite: each firewall's template stack contains its own template, named
`<fw>-device` below (e.g. `fw01-device`).

One CNAME per firewall in your **real** zone, all pointing to the same burner
record. Create them by hand: scripting them would put a key for your real zone
on the box, which is exactly what the burner domain avoids. It's one record per
firewall, once; renewals never touch it again.

```
_acme-challenge.fw01.fw.example.com.  CNAME  _acme-challenge.burner-domain.net.
_acme-challenge.fw02.fw.example.com.  CNAME  _acme-challenge.burner-domain.net.
```

List the firewalls in a text file on the box, one full mgmt name per line:

```bash
nano ~/firewalls.txt
```

```
fw01.fw.example.com
fw02.fw.example.com
```

Write it on the box itself. A file written on Windows and copied over has an
invisible `\r` at the end of every line, and acme.sh gets the wrong name.

Check every CNAME. An empty result means: fix the DNS before you go on.

```bash
while read -r FQDN; do echo "$FQDN -> $(dig +short CNAME "_acme-challenge.$FQDN")"; done < ~/firewalls.txt
```

Issue and deploy every firewall in the file:

```bash
read -rp 'Cloudflare zone ID (burner zone only): ' CF_Zone_ID; export CF_Zone_ID
read -rsp 'Cloudflare token (burner zone only): ' CF_Token; echo; export CF_Token
while read -r FQDN <&3; do
  [ -n "$FQDN" ] || continue
  FWN="${FQDN%%.*}"
  acme.sh --issue --dns dns_cf -d "$FQDN" --always-force-new-domain-key --challenge-alias "$BURNER" \
  && PANOS_TEMPLATE="$FWN-device" PANOS_CERTNAME="$FWN-mgmt" \
     acme.sh --deploy -d "$FQDN" --deploy-hook panos --ecc
done 3< ~/firewalls.txt
unset CF_Token
```

`FWN` is the short name (`fw01`), which gives the device template
(`fw01-device`) and the object name (`fw01-mgmt`). The loop reads the file on
its own file descriptor (`3<`, `<&3`), so no command inside it can swallow the
rest of the list.

Templates named differently? Put the template as a second column, e.g.
`fw01.fw.example.com FW01-Berlin`, read it with `while read -r FQDN TPL <&3`
and use `PANOS_TEMPLATE="$TPL"`.

**New firewall?** Add its line and CNAME, and run the same loop again.
Firewalls that already have a cert are skipped (`Skipping`, not due yet); only
the new one is issued and deployed. Renewals don't need the file: acme.sh
remembers every cert with its template.

Bind once per device template (mgmt SSL/TLS Service Profile with that
firewall's cert), commit and push. To have acme.sh push too, add
`PANOS_TEMPLATE_STACK="$FWN-stack"` in front of the deploy (needs Operational
Requests).

### 3c. One cert per firewall, deployed directly

acme.sh now logs into every firewall, so the Panorama advantage is gone for
these certs. Each firewall needs what
[README step 1](README.md#step-1-firewall-admin-user-configuration) creates:
the `acme-deploy` role, the `$FWUSER` admin, and the box in Permitted IP
Addresses. Push those from a Panorama template, so you set them up once.

Then, per firewall, follow the [README](README.md) steps 3 to 7 exactly as for
a single firewall (scenario 2 with only the mgmt name), with `CERT` and `FW`
both set to that firewall's mgmt name. The step 4 fingerprint check is per
firewall, because each one still has its own self-signed cert on the first
run. This is the most work of the three, which is why 3a or 3b are the better
fit when you have Panorama.

---

## Prove it

Panorama: open `https://panorama.example.com` in a browser, the padlock should
show Let's Encrypt. A firewall, after the push:

```bash
echo | openssl s_client -connect fw01.fw.example.com:443 -servername fw01.fw.example.com 2>/dev/null \
  | openssl x509 -noout -subject -issuer -enddate
```

GlobalProtect, with the full chain (`0` your cert, `1` the Let's Encrypt
intermediate):

```bash
echo | openssl s_client -connect "$CERT:443" -servername "$CERT" 2>/dev/null \
  | grep -E '^ *[0-9]+ s:|^ +i:'
```

Every cert on the box, and when each renews next (`Renew` column):

```bash
acme.sh --list
crontab -l | grep acme.sh
```

## Production ready

- **Lock the names with CAA.** As in the README's
  [CAA section](README.md#optional-lock-issuance-to-your-account-caa), one
  record each on `panorama.example.com`, `vpn.example.com` and
  `fw.example.com`. The last one covers the wildcard and every firewall name
  below it. Not on your apex, and only after your staging tests.
- **A new key at every renewal.** Every `--issue` line above has
  `--always-force-new-domain-key`. With one wildcard on many firewalls, that
  matters most. See [Shorter certificate lifetimes](README.md#shorter-certificate-lifetimes-47-days-by-2029).
- **Notifications to a team, not a person.** A shared mailbox or a Teams
  channel, set up as in [README step 7](README.md#step-7-make-renewals-hands-off).
- **Treat the box as important.** It holds the Panorama API key, the burner
  token and your ACME account key, and so does its backup. See
  [Where the credentials live](README.md#where-the-credentials-live).
- **Operational Requests:** think twice. With it, a stolen key can also read
  your whole configuration. Leaving it off and pushing in your change window
  is the safer default.
- **New API key** (e.g. after an API key lifetime expires): acme.sh saves the
  key separately for each cert. Redo steps 3 and 4, then run each cert's
  deploy line once with the new key exported, not just one of them.

## Enterprise notes

- **Keep GlobalProtect and mgmt in separate certs.** Every user sees the names
  on the GlobalProtect cert, and a separate cert means a separate key. The
  combined cert of scenario 2 is fine for a single firewall.
- **Certificate Transparency.** Every name on a public cert is logged publicly,
  forever, and searchable (e.g. crt.sh). A wildcard (3a) shows only
  `*.fw.example.com`.
- **Internal CA for mgmt.** If policy forbids public certs on mgmt, keep the same
  pipeline with your own CA: acme.sh works with any ACME server, via
  `--server https://<your-ca>/acme/directory` on `--issue`. The box must trust
  that CA, see the [(B) prerequisite](README.md#choose-how-the-box-will-trust-mgmt).
  How validation works depends on your CA.
- **Rate limit.** Let's Encrypt issues up to 50 new certs per registered domain
  per 7 days. Roll out more than 50 firewalls (3b, 3c) over several weeks.
  Renewals don't count against it.
- **Change windows.** Leave out `PANOS_TEMPLATE_STACK` and let your regular push
  deliver the certs.

## Troubleshooting

Panorama-specific problems below. Everything else (DNS, keygen, import,
commit, staging) is in the [README troubleshooting table](README.md#troubleshooting).

| Symptom | Cause / fix |
|---|---|
| Cert landed in a template instead of on Panorama itself (or the other way round) | A `PANOS_TEMPLATE` from an earlier `export` was saved into this cert's config. Remove the line: `sed -i '/^SAVED_PANOS_TEMPLATE/d' ~/.acme.sh/<domain>_ecc/<domain>.conf`, then deploy again |
| Deploy to Panorama fails on the object name | Name longer than 31 characters (wildcards become `WILDCARD_.<domain>`). Set a shorter `PANOS_CERTNAME` |
| Cert is in the template, firewalls don't have it | Not pushed yet. Push the template stack, or set `PANOS_TEMPLATE_STACK` (role needs Operational Requests) |
| 3b: only the first firewall gets a cert | A command in the loop read from stdin. Use the loop as shown, with `3<` and `<&3` |
| 3b: issue fails for a name that looks right | Windows line endings in `~/firewalls.txt`. Fix with `sed -i 's/\r$//' ~/firewalls.txt` |
| Issue fails: too many certificates | Let's Encrypt limit of 50 new certs per registered domain per 7 days. Spread the rollout |
