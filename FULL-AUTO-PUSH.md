# Full-auto push from Panorama (optional)

By default ([PANORAMA.md](PANORAMA.md)), acme.sh imports a renewed cert into
its template and commits it on Panorama, and **you push** it to the firewalls.
This page adds two small deploy hooks (scripts acme.sh runs after every renewal)
so the firewall pushes are done automatically.

> **Use at your own risk.** No warranty, no liability. See the [disclaimer](#disclaimer).

## What the two hooks do

`panos_check` and `panos_push` are **not part of acme.sh**. They were written
for this guide and live in this repo (`deploy/`). Only the `panos` hook comes
with acme.sh. Read them before you use them.

acme.sh runs three hooks, in this order:

1. **`panos_check`** asks Panorama which template stacks contain the cert's
   template, and notes any of them that is **not In Sync** (it already has
   committed changes that weren't pushed).
2. **`panos`** (acme.sh's own hook) imports the cert and commits it.
3. **`panos_push`** pushes every one of those stacks and waits for the result.
   If `panos_check` found a stack that wasn't In Sync, it pushes **nothing**
   and fails with a message, so your acme.sh notification tells you to push
   by hand.

One small gap remains: a template change that someone else commits to
Panorama in the short window between the check and the push (usually a minute
or two, while the import's commit finishes) would be pushed too.

**Tip: renew at night.** That shrinks the gap, and it pushes outside business
hours anyway. acme.sh installed a daily cron job for `acmesh` and renews only
when a cert is due, so you only choose the time. As `acmesh`, see the line:

```bash
crontab -l | grep acme.sh
```

Then `crontab -e` and change only the first two fields, minute and hour. For example, 02:30 every night. **Leave the path to acme.sh and its parameters untouched**:

```
30 2 * * * "/home/acmesh/.acme.sh"/acme.sh --cron --home "/home/acmesh/.acme.sh" > /dev/null
```

The hour is in the box's timezone, often UTC (check with `date`).

> **Requirement:** every template stack that holds the cert must be **In Sync**
> when the renewal runs. If someone left committed changes unpushed, the
> renewal still imports and commits the cert, but doesn't push.

## Step 1: Add Operational Requests to the role

**Panorama > Admin Roles >** `acme-deploy` **> XML API** → enable
**Operational Requests** (keep Import and Commit). Commit to Panorama. The
hooks need it to read the sync status and the push jobs. It also lets a stolen
key read your config and push, see
[Operational Requests: think twice](PANORAMA.md#operational-requests-think-twice).

Without it, the renewal log shows `panos_check: could not read the template
stack status, panos_push will not push.` followed by Panorama's own error. The
panos hook still imports and commits the cert, only the push is skipped.

## Step 2: Download the two hooks

The hooks read Panorama's XML answers with `xmllint`, the standard XML tool
from libxml2. [PANORAMA.md step 0a](PANORAMA.md#step-0-prepare-the-box-and-set-your-names)
already installs it. On a box set up from the README, install it from your
admin account (on RHEL it's usually there already):

```bash
# Debian / Ubuntu
sudo apt install -y libxml2-utils
# RHEL / Rocky / Alma
sudo dnf install -y libxml2
```

Then, as `acmesh` (`sudo -iu acmesh` from your admin account):

```bash
cd ~/.acme.sh/deploy
curl -fsSO https://raw.githubusercontent.com/netsums/panos-acme-cert/main/deploy/panos_check.sh
curl -fsSO https://raw.githubusercontent.com/netsums/panos-acme-cert/main/deploy/panos_push.sh
cd
```

Read them before you use them:

```bash
less ~/.acme.sh/deploy/panos_check.sh ~/.acme.sh/deploy/panos_push.sh
```

## Step 3: Switch your template certs to the three hooks

If you're still in the shell from PANORAMA.md, clear the per-cert variables
first. A `PANOS_TEMPLATE` left over from another cert would win over the
template acme.sh saved for this one, and send the cert to the wrong template:

```bash
unset PANOS_TEMPLATE PANOS_TEMPLATE_STACK PANOS_CERTNAME 
```

Check that the stacks are in sync: **Panorama > Managed Devices > Summary**,
column *Template*, must show **In Sync** for every firewall that uses the
cert's template.

Set which cert to switch. Pick **one** line and change the name:

```bash
CERTS='vpn.example.com'               # one cert, e.g. GlobalProtect
# CERTS='*.fw.example.com'            # the wildcard firewall mgmt cert (PANORAMA.md 4a)
# CERTS="$(cat ~/.acme.sh/firewalls.txt)"  # one mgmt cert per firewall (PANORAMA.md 4b)
```

To use another line, remove its `#` and add one to the first line.

Then deploy them once with the three hooks:

```bash
while IFS=$' \t\r' read -r C _ <&3 || [ -n "$C" ]; do
  [ -n "$C" ] || continue
  acme.sh --deploy -d "$C" --ecc --deploy-hook panos_check --deploy-hook panos --deploy-hook panos_push
done 3<<< "$CERTS"
```

Each cert takes a few minutes: it waits for the commit and for each push.
acme.sh saves the three hooks per cert, so every renewal from now on uses
them. If one says `NOT pushed`, the loop carries on with the next. Push that
one by hand.

Repeat with the next `CERTS=` line for your other template certs.

## Stop the automatic push

If you want to stop the automatic push and start pushing yourself, deploy once with the plain hook. acme.sh replaces the saved hook list. Set
`CERTS` as in step 3:

```bash
CERTS='vpn.example.com'               # one cert, e.g. GlobalProtect
# CERTS='*.fw.example.com'            # the wildcard firewall mgmt cert (PANORAMA.md 4a)
# CERTS="$(cat ~/.acme.sh/firewalls.txt)"  # one mgmt cert per firewall (PANORAMA.md 4b)
```

To use another line, remove its `#` and add one to the first line.

Then deploy only with the acme.sh hook:

```bash
while IFS=$' \t\r' read -r C _ <&3 || [ -n "$C" ]; do
  [ -n "$C" ] || continue
  acme.sh --deploy -d "$C" --ecc --deploy-hook panos
done 3<<< "$CERTS"
```

`acme.sh --upgrade` should not change extra files in `~/.acme.sh/deploy/`.

## Disclaimer

This guide and everything in this repository are provided **as is**, without
warranty of any kind, under the MIT License. You use them at your own risk. I
accept no liability for certificates that don't renew, expired certificates,
outages or any other damage, including damage caused by changes in acme.sh,
Let's Encrypt, PAN-OS or anything else outside my control. Test in a lab
first, and **monitor your certificates' expiry dates yourself**: automation
can fail without anyone noticing.
