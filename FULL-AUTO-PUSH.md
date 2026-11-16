# Full-auto push from Panorama (experimental)

> **Status: draft, not tested against a real Panorama yet.** Don't use this in
> production until the [lab tests](#lab-tests-before-release) below pass.
> The default in [PANORAMA.md](PANORAMA.md) stays: acme.sh imports and commits,
> you push.

With the upstream `panos` hook, a renewed cert in a template is committed to
Panorama but only reaches the firewalls with the next push. This page adds two
small deploy hooks so renewals also push, safely, to every firewall that uses
the template.

## Why not just `PANOS_TEMPLATE_STACK`?

Findings from tests on Panorama (November 2026):

| Finding | Consequence |
|---|---|
| The `panos` hook always does a **partial commit** of `$PANOUSER`'s changes. No option to skip it | Other admins' pending (uncommitted) changes stay untouched. Fine |
| `PANOS_TEMPLATE_STACK` takes **one** stack, pushed with `commit-all` → `template-stack`, scoped to `$PANOUSER` | A template used in 50 stacks would reach the firewalls of one stack only |
| The XML API has no "push everything from admin X" call. One `commit-all` per stack | A script must loop over the stacks |
| Admin-scoped push (`<admin><member>`, `exclude-other-admins` yes) **only isolates changes committed with their own partial commit** | Tested: admin A and admin B each did a partial commit → push scoped to B delivered only B's change |
| After a **normal commit** (all admins' changes together) the attribution is gone | Tested: a push scoped to one admin delivered the other admin's change too. A colleague's committed-but-unpushed work would go out with acme's push |

So scoping the push to the acme admin is not enough. The hooks below push
only when the stacks were **in sync before** acme.sh imported anything. Then
the only change waiting is acme.sh's own.

## How it works

```bash
acme.sh --deploy -d vpn.example.com \
  --deploy-hook panos_check --deploy-hook panos --deploy-hook panos_push --ecc
```

1. **`panos_check`** (before the import): asks Panorama `show template-stack`,
   finds every stack that contains the cert's `PANOS_TEMPLATE`, and records
   whether any firewall in them is not `In Sync`. It never fails, so the
   import always happens.
2. **`panos`** (upstream, unchanged): imports and does the partial commit.
3. **`panos_push`**: if every stack was in sync, waits for the commit job,
   pushes each stack (admin-scoped, `exclude-other-admins` yes), waits for each
   push job and fails if any firewall reports `FAIL`. If a stack was already
   out of sync, it **doesn't push** and fails with a message: the cert is
   committed, push it yourself. Your acme.sh notification tells you.

Certs without a template (Panorama's own mgmt cert) are skipped.

Remaining gap: a colleague committing in the minutes between step 1 and the
push. Their change would go out too.

## Install

You do this once per Panorama, then once per template cert. Prerequisite: the
cert is already issued and deployed with the plain `panos` hook as in
[PANORAMA.md](PANORAMA.md) (step 6, 7a or 7b), and bound in its template.

### 1. Add Operational Requests to the role

**Panorama > Admin Roles >** `acme-deploy` **> XML API** → enable
**Operational Requests** (keep Import and Commit). Commit to Panorama. The
hooks need it to read the sync status and the push jobs. It also lets a stolen
key read your config and push, see
[Operational Requests: think twice](PANORAMA.md#operational-requests-think-twice).

### 2. Put the two hooks on the box

As `acmesh` (`sudo -iu acmesh` from your admin account). This downloads them
from this repo into acme.sh's deploy folder:

```bash
cd ~/.acme.sh/deploy
curl -fsSO https://raw.githubusercontent.com/netsums/panos-acme-cert/main/deploy/panos_check.sh
curl -fsSO https://raw.githubusercontent.com/netsums/panos-acme-cert/main/deploy/panos_push.sh
cd
ls -l ~/.acme.sh/deploy/panos_check.sh ~/.acme.sh/deploy/panos_push.sh
```

Read them before you use them. They're short:

```bash
less ~/.acme.sh/deploy/panos_check.sh ~/.acme.sh/deploy/panos_push.sh
```

### 3. Pick the cert and check its saved config

Set the cert you want to switch over. Change the name before you press
Enter:

```bash
C=vpn.example.com             # the cert's name, as in acme.sh --list
```

Its saved config must have a template and **no** template stack:

```bash
grep '^SAVED_PANOS_' ~/.acme.sh/"${C}_ecc"/"$C".conf | cut -d= -f1
```

You should see `SAVED_PANOS_HOST`, `SAVED_PANOS_USER`, `SAVED_PANOS_KEY` and
`SAVED_PANOS_TEMPLATE`. If `SAVED_PANOS_TEMPLATE_STACK` is there too, remove
it, or the `panos` hook pushes that one stack on its own before the check:

```bash
sed -i '/^SAVED_PANOS_TEMPLATE_STACK/d' ~/.acme.sh/"${C}_ecc"/"$C".conf
```

The shell must not override those saved values. This should print nothing,
or only `PANOS_HOST` and `PANOS_USER` (from the PANORAMA.md shell, same values):

```bash
env | grep '^PANOS_' | cut -d= -f1
```

### 4. Make sure the stacks are in sync

**Panorama > Managed Devices > Summary**, column *Template*: every firewall
whose stack contains the cert's template must show **In Sync**. If one
doesn't, push first (or find out why). Otherwise step 5 imports and commits
but refuses to push, which is the safety stop working, not a bug.

### 5. Deploy once with the three hooks

```bash
acme.sh --deploy -d "$C" --ecc --deploy-hook panos_check --deploy-hook panos --deploy-hook panos_push
```

The order matters. It takes a few minutes (it waits for the commit and for
each push job). What you should see, in this order:

```
panos_check: stacks with GP-Template: Stack-A Stack-B; not in sync before import: none
...                                  (the panos hook: import, commit)
panos_push: pushing 'Stack-A', job 1234
panos_push: 'Stack-A' pushed OK
panos_push: pushing 'Stack-B', job 1235
panos_push: 'Stack-B' pushed OK
```

`NOT pushed` instead means: the cert is imported and committed, but a stack
had something else waiting, so nothing was pushed. Push it yourself, fix the
cause, and run this step again.

### 6. Check it stuck

acme.sh saved the three hooks for this cert, so every renewal uses them:

```bash
grep '^Le_DeployHook' ~/.acme.sh/"${C}_ecc"/"$C".conf
```

Expected: `Le_DeployHook='panos_check,panos,panos_push,'`. On Panorama,
**Task Manager** shows the push jobs with the description
`acme.sh renewal vpn.example.com`, and **Managed Devices** shows every stack
`In Sync`. On a firewall, the cert is there:

```bash
echo | openssl s_client -connect vpn.example.com:443 -servername vpn.example.com 2>/dev/null \
  | openssl x509 -noout -subject -issuer -enddate
```

Optional, the real renewal path (lab test 8). It issues a new cert, so it
counts against Let's Encrypt's limits; don't repeat it many times:

```bash
acme.sh --renew -d "$C" --ecc --force
```

### 7. The other template certs

Repeat steps 3 to 6 for each, e.g. `C='*.fw.example.com'` for the wildcard
(7a). For one cert per firewall (7b), steps 4 and 5 for all of them, from the
same `~/firewalls.txt`:

```bash
while IFS=$' \t\r' read -r FQDN TPL <&3 || [ -n "$FQDN" ]; do
  [ -n "$FQDN" ] || continue
  acme.sh --deploy -d "$FQDN" --ecc --deploy-hook panos_check --deploy-hook panos --deploy-hook panos_push
done 3< ~/firewalls.txt
```

Panorama's own mgmt cert (step 5 of PANORAMA.md) has no template and nothing
to push: leave it on the plain `panos` hook.

### Back to "you push"

Deploy once with the plain hook. acme.sh replaces the saved hook list:

```bash
acme.sh --deploy -d "$C" --ecc --deploy-hook panos
```

`acme.sh --upgrade` doesn't touch extra files in `~/.acme.sh/deploy/`, but
check after upgrades that both files are still there.

## Lab tests before release

Lab: Panorama, 2+ firewalls, `GP-Template` in **two** stacks (`Stack-A`,
`Stack-B`), plus a second admin (`colleague`) with full rights. Staging certs
are fine for all of it. For each test: what you do, what must happen.

| # | Setup | Expected |
|---|---|---|
| 1 | All stacks in sync. Deploy with the three hooks | Both stacks pushed, cert on every firewall, both stacks `In Sync`, exit 0 |
| 2 | `colleague` changes something in `GP-Template`, **normal commit**, no push. Then deploy | `panos_push` refuses, names the stack, exit ≠ 0. Cert committed, not on firewalls. Colleague's change not pushed |
| 3 | `colleague` changes something, **doesn't commit**. Then deploy | Stacks in sync → push happens. Colleague's change stays pending, not pushed, not committed |
| 4 | One firewall disconnected / unreachable | Shows not `In Sync` → no push, clear message. (Expected: a dead firewall blocks auto-push until fixed) |
| 5 | Push fails on one firewall (e.g. commit lock on the firewall) | Job `FAIL` → exit ≠ 0, stack named |
| 6 | Hooks in the wrong order (`panos` first) or `panos_check` missing | `panos_push` refuses: "no result from panos_check" |
| 7 | Panorama's own mgmt cert with the three hooks | Imported to Panorama, `panos_push` says "nothing to push", exit 0 |
| 8 | Renewal path: `acme.sh --renew -d vpn.example.com --force` (staging) | Same as test 1, from the saved config, no env variables set |
| 9 | Template in a third stack added later | Next renewal finds and pushes all three, no config change |
| 10 | Admin-scope proof: after test 1, check Panorama > Managed Devices for both stacks | `In Sync`; job description `acme.sh renewal vpn.example.com` |

## For the video

Show test 1 (the happy path) and test 2 (the safety stop) live. Test 2 is the
one viewers will remember: the colleague's change does *not* go out at night.
