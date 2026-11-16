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

As `acmesh`, copy the two files from [deploy/](deploy/) into
`~/.acme.sh/deploy/`, read them, then deploy each template cert once with
the three hooks above (with `PANOS_TEMPLATE` exported as in PANORAMA.md).
acme.sh saves the hook list and uses it for every renewal.

- Leave `PANOS_TEMPLATE_STACK` **unset**, or the `panos` hook pushes one stack
  on its own, before the check.
- Role on Panorama, XML API: **Import, Commit, Operational Requests**. No
  Configuration permission needed.
- `acme.sh --upgrade` doesn't touch extra files in `~/.acme.sh/deploy/`, but
  check after upgrades.

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
