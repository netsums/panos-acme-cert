# panos-acme-cert

Auto-renew PAN-OS certificates (GlobalProtect portal/gateway, mgmt, captive
portal, …) with Let's Encrypt via [acme.sh](https://github.com/acmesh-official/acme.sh).
DNS-01 validation through a delegated challenge domain, deploy with a
restricted admin's API key. No password stored anywhere.

**The deploy itself is done by acme.sh's own, upstream `panos` hook.** This repo
adds a guide and an optional interactive helper around it. You can do
everything by hand with the commands in [Option A](#option-a--by-hand-no-script)
and never run code from this repo.

---

## How it works

```
acme.sh (Linux box) ──DNS-01──▶ Let's Encrypt
        │                         ▲
        │                         └─ _acme-challenge.fw.example.com  CNAME ─▶ burner domain
        │                                                            (only the burner's DNS API
        │                                                             token lives on the box)
        └──XML API (API key)──▶ PAN-OS mgmt: import cert + key, partial commit
```

Every ~60 days acme.sh renews via cron and re-runs the deploy hook: import,
commit, done.

## 1. Prerequisites on the firewall

1. **Admin Role** (Device > Admin Roles), *XML API* tab: enable only
   **Import** and **Commit**. Web UI and REST API: all disabled. Command line:
   None. (Panorama pushing to a template stack also needs **Operational
   Requests**. Leave it off otherwise: it lets the key run
   `show config running`.)
2. **Administrator** `acme` using that role, with a long random password.
3. **Mgmt access**: add the acme.sh box's IP to the mgmt interface's
   *Permitted IP Addresses*.
4. **Mgmt TLS** (important for unattended renewals): the box must trust the
   mgmt certificate. If mgmt is still on its self-signed cert, the first deploy
   can be forced, but **renewals will fail** until mgmt presents a publicly
   trusted cert whose name matches `PANOS_HOST`. Easiest fix: issue a cert for
   the mgmt FQDN too and bind it to the mgmt SSL/TLS Service Profile.

## 2. Issue the certificate (DNS delegation)

Point the challenge record of your real domain at a throwaway domain whose DNS
API you're happy to hand to a script:

```
_acme-challenge.fw.example.com.  CNAME  _acme-challenge.fw.burner-domain.net.
```

Then issue on the acme.sh box (Cloudflare shown; any acme.sh DNS API works):

```bash
export CF_Token="<token scoped to the burner zone only>"
acme.sh --issue --dns dns_cf -d fw.example.com \
        --challenge-alias burner-domain.net --server letsencrypt
```

Your production DNS credentials never touch the box.

## 3. Deploy to the firewall

### Option A — by hand, no script

```bash
FW=fw.example.com   # mgmt address

# 1. Generate an API key. Password is read hidden and sent to curl on stdin,
#    so it never appears in shell history or `ps`.
read -rsp 'Password for acme: ' P; echo
printf '%s' "$P" | curl -sS -X POST "https://$FW/api/?type=keygen" \
    --data-urlencode 'user=acme' --data-urlencode 'password@-'
unset P
# -> <response status = 'success'><result><key>LUFRPT...</key></result></response>

# 2. Hand host/user/key to acme.sh (key pasted hidden, not into history).
read -rsp 'API key: ' PANOS_KEY; echo
export PANOS_HOST="$FW" PANOS_USER=acme PANOS_KEY

# 3. Deploy. Add --ecc if the cert is ECDSA (acme.sh default since v3).
acme.sh --deploy -d fw.example.com --deploy-hook panos --ecc
unset PANOS_KEY
```

If mgmt is still self-signed, curl in step 1 needs `-k`. Only do that from a
network path you trust, since the password goes to a host you haven't verified.

### Option B — the helper script

```bash
curl -fsSLO https://raw.githubusercontent.com/netsums/panos-acme-cert/<tag>/panos-acme-deploy.sh
less panos-acme-deploy.sh          # read it; it's ~300 lines of bash
bash panos-acme-deploy.sh
```

It does what Option A does, with guard rails:

- checks the mgmt cert; if it isn't publicly trusted, shows the SHA-256
  fingerprint, asks you to confirm it and **pins that public key** for every
  request, and warns loudly if it changes on a later run
- sends the password and key to curl **on stdin**, never as arguments
- verifies the key works before touching acme.sh
- matches the acme.sh cert exactly and adds `--ecc` automatically
- talks to exactly one host, your mgmt address: `grep -nE 'curl|openssl s_client' panos-acme-deploy.sh`

## Where the credential lives, honestly

- The password is used once to mint the API key, then discarded.
- acme.sh stores `PANOS_HOST`, `PANOS_USER` and `PANOS_KEY` in
  `~/.acme.sh/<domain>/<domain>.conf`, **base64-encoded, not encrypted**.
  Anyone who can read that file can use the key.
- The key has only Import and Commit rights. Worst case if it leaks: someone
  imports certificates/files and triggers a commit, which can also push other
  admins' pending changes. They can't edit policy or read your config through
  it (that's why Operational Requests stays off).
- Mitigations: a dedicated box or user for acme.sh, `chmod 700 ~/.acme.sh`,
  mgmt Permitted IPs limited to that box, and an API key lifetime set under
  Device > Setup > Management > Authentication Settings (you then re-run
  keygen when it expires).

## Troubleshooting

| Symptom | Cause |
|---|---|
| Keygen returns error | Wrong password, or the role has no XML API access |
| Import fails | Role missing **Import** |
| Commit fails | Role missing **Commit**, or another admin holds a config lock |
| First deploy works, renewal fails with a TLS error | Mgmt still self-signed; see prerequisite 4 |
| Cert name truncated on Panorama | Set `PANOS_CERTNAME` (31-char limit) |

## License

MIT
