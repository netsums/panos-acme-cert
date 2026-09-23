#!/usr/bin/env bash
#
# panos-acme-deploy.sh
# -----------------------------------------------------------------------------
# Interactive helper that pushes an acme.sh (Let's Encrypt) certificate to a
# Palo Alto firewall or Panorama over the XML API, using an API KEY instead of
# the admin password.
#
# WHAT IT DOES, in order:
#   1. Makes you confirm the prerequisites (restricted admin, reachable mgmt,
#      an already-issued cert). It does NOT create anything on the firewall.
#   2. Asks for the mgmt address and admin username (remembers them next time).
#   3. Gets an API key: reuses one you already have, or generates one from your
#      password via the firewall's own keygen endpoint. The password is read
#      hidden, sent ONLY to your firewall, converted to a key, then discarded.
#      It is never written to disk and never printed.
#   4. Verifies the box can reach mgmt, and that the key actually works.
#   5. Runs the acme.sh 'panos' deploy hook to import the cert and commit.
#
# SECURITY NOTES — please read before running:
#   * This script talks to exactly ONE host: the mgmt address you give it.
#     It has no other outbound calls. It does not phone home. You can verify
#     that yourself:   grep -n curl panos-acme-deploy.sh
#   * Use a RESTRICTED admin (XML API: Import, Commit, Operational Requests
#     only), never superuser. The API key inherits only that account's rights.
#   * Don't pipe this from the internet into a shell. Download it, read it,
#     then run it:   bash panos-acme-deploy.sh
#
# Repo:    https://github.com/<your-user>/panos-acme-deploy   (pin a release tag)
# License: MIT
# -----------------------------------------------------------------------------
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/panos-acme"
CONFIG_FILE="$CONFIG_DIR/deploy.env"
KEY_FILE="$CONFIG_DIR/apikey"

# Wipe secrets from the environment on any exit (including Ctrl-C).
trap 'unset PANPASS PANOS_KEY 2>/dev/null || true' EXIT

# ---- output helpers ---------------------------------------------------------
bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '\033[32m  OK: %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---- prompt helpers (read -p writes the prompt to stderr, so $(...) is safe) --
ask() {                       # ask "Prompt" "default" -> echoes the answer
  local prompt="$1" default="${2:-}" reply
  if [ -n "$default" ]; then
    read -rp "$prompt [$default]: " reply || true
    printf '%s' "${reply:-$default}"
  else
    read -rp "$prompt: " reply || true
    printf '%s' "$reply"
  fi
}
ask_secret() {                # ask_secret "Prompt" -> echoes the secret (hidden)
  local prompt="$1" reply
  read -rsp "$prompt: " reply || true; echo >&2
  printf '%s' "$reply"
}
confirm() {                   # confirm "Question" -> returns 0 on yes
  local reply
  read -rp "$1 [y/N]: " reply || true
  [[ "${reply,,}" == y || "${reply,,}" == yes ]]
}

# ---- load saved (non-secret) defaults ---------------------------------------
mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
# shellcheck disable=SC1090
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# Environment variables win over the saved file; both become prompt defaults.
PANOS_HOST="${PANOS_HOST:-${SAVED_HOST:-}}"
PANOS_USER="${PANOS_USER:-${SAVED_USER:-acme}}"
ACME_DOMAIN="${ACME_DOMAIN:-${SAVED_DOMAIN:-}}"

bold "PAN-OS + acme.sh certificate deploy"

# ---- 0. prerequisites -------------------------------------------------------
bold "Step 0 — Prerequisites (this script changes nothing until you confirm)"
info "This will only work if the following are ALREADY true:"
info "  1. A restricted admin exists on the firewall, whose Admin Role enables"
info "     (XML API):  Import,  Commit,  Operational Requests  — and nothing"
info "     else. NOT superuser."
info "  2. You have that account's password (used once), OR an API key already."
info "  3. This machine can reach the firewall mgmt interface on TCP 443"
info "     (mgmt 'Permitted IP Addresses' includes this machine's IP)."
info "  4. The certificate has already been issued by acme.sh on this machine."
echo
confirm "Have you done all four?" || die "Set up the prerequisites first, then re-run. See the runbook."

# ---- 1. target --------------------------------------------------------------
bold "Step 1 — Firewall / Panorama"
PANOS_HOST="$(ask "  Mgmt address (IP or hostname)" "$PANOS_HOST")"
[ -n "$PANOS_HOST" ] || die "Mgmt address is required."
PANOS_USER="$(ask "  Restricted admin username"     "$PANOS_USER")"
[ -n "$PANOS_USER" ] || die "Username is required."

# ---- 2. reachability --------------------------------------------------------
bold "Step 2 — Reachability check (5s timeout, so it can't hang)"
if curl -skI --connect-timeout 5 "https://$PANOS_HOST/" >/dev/null 2>&1; then
  ok "$PANOS_HOST answers HTTPS on 443."
else
  die "Can't reach $PANOS_HOST:443. Check mgmt Permitted IP Addresses, routing, and that this really is the mgmt interface."
fi

# ---- 3. API key -------------------------------------------------------------
bold "Step 3 — API key"
PANOS_KEY="${PANOS_KEY:-}"
if [ -z "$PANOS_KEY" ] && [ -f "$KEY_FILE" ]; then
  PANOS_KEY="$(cat "$KEY_FILE")"
  info "Found a saved API key at $KEY_FILE."
fi

# We never display a key as a default; we only offer to reuse it.
if [ -n "$PANOS_KEY" ] && confirm "  Reuse the existing API key?"; then
  info "Reusing existing key."
else
  info "Generating a new key. Your password is read hidden, sent only to"
  info "$PANOS_HOST, converted to a key, and discarded. It is never stored."
  PANPASS="$(ask_secret "  Password for \"$PANOS_USER\"")"
  [ -n "$PANPASS" ] || die "Password was empty."
  PANOS_KEY="$(curl -sk --connect-timeout 5 -X POST "https://$PANOS_HOST/api/?type=keygen" \
      --data-urlencode "user=$PANOS_USER" \
      --data-urlencode "password=$PANPASS" \
      | sed -n 's:.*<key>\(.*\)</key>.*:\1:p')"
  unset PANPASS
  [ -n "$PANOS_KEY" ] || die "Keygen failed: wrong username/password, or the account has no API access. Check the restricted admin's role."
  ok "Key generated."
  if confirm "  Save this key to $KEY_FILE (mode 600) so you can reuse it?"; then
    (umask 077; printf '%s' "$PANOS_KEY" > "$KEY_FILE")
    ok "Saved. This file is a live credential — protect it accordingly."
  fi
fi

# ---- 4. verify the key ------------------------------------------------------
bold "Step 4 — Verifying the key actually works"
resp="$(curl -sk --connect-timeout 5 -X POST "https://$PANOS_HOST/api/?type=op" \
    --data-urlencode "cmd=<show><system><info></info></system></show>" \
    --data-urlencode "key=$PANOS_KEY" || true)"
if grep -q 'status="success"' <<<"$resp"; then
  model="$(sed -n 's:.*<model>\(.*\)</model>.*:\1:p'         <<<"$resp")"
  ver="$(sed -n 's:.*<sw-version>\(.*\)</sw-version>.*:\1:p' <<<"$resp")"
  ok "Key authenticates. ${model:-Firewall} on PAN-OS ${ver:-(version unknown)}."
  info "(This proves auth + API access. It does NOT prove Import/Commit rights —"
  info " only the deploy below exercises those.)"
else
  warn "Key rejected, or the account lacks API access. Raw response:"
  echo "$resp"
  die "Fix the account/role, then re-run."
fi

# ---- 5. locate the issued certificate --------------------------------------
bold "Step 5 — Certificate to deploy"
ACME_DOMAIN="$(ask "  acme.sh domain (the cert's main FQDN)" "$ACME_DOMAIN")"
[ -n "$ACME_DOMAIN" ] || die "Domain is required."

ACME=""
if command -v acme.sh >/dev/null 2>&1; then ACME="acme.sh"
elif [ -x "$HOME/.acme.sh/acme.sh" ]; then ACME="$HOME/.acme.sh/acme.sh"
else die "acme.sh not found. Install it and issue the certificate first."; fi

if ! "$ACME" --list 2>/dev/null | grep -q "$ACME_DOMAIN"; then
  warn "acme.sh has no issued cert for $ACME_DOMAIN. Issue it first, e.g.:"
  info "  acme.sh --issue --dns dns_cf -d $ACME_DOMAIN --challenge-alias <burner-domain> --server letsencrypt"
  die "Nothing to deploy yet."
fi
ok "Found an issued cert for $ACME_DOMAIN."

# ---- 6. confirm & deploy ----------------------------------------------------
bold "Step 6 — Deploy"
info "This imports the certificate + key into $PANOS_HOST and commits"
info "(a partial commit scoped to the '$PANOS_USER' admin)."
confirm "Proceed?" || die "Aborted. Nothing was changed on the firewall."

deploy_args=(--deploy -d "$ACME_DOMAIN" --deploy-hook panos)
if confirm "  Is mgmt still on its default self-signed cert (first-ever run)?"; then
  deploy_args+=(--insecure)
fi

export PANOS_HOST PANOS_USER PANOS_KEY
if "$ACME" "${deploy_args[@]}"; then
  ok "Deploy hook finished."
else
  die "Deploy failed — see acme.sh output above. Most common cause: the role is missing Import or Commit."
fi

# ---- 7. persist non-secret defaults, clean up ------------------------------
{
  echo "# panos-acme-deploy saved defaults (non-secret)"
  echo "SAVED_HOST=\"$PANOS_HOST\""
  echo "SAVED_USER=\"$PANOS_USER\""
  echo "SAVED_DOMAIN=\"$ACME_DOMAIN\""
} > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

unset PANOS_KEY
bold "Done"
info "acme.sh saved the host/user/key (key encrypted) for automatic renewals —"
info "the next renewal re-imports and commits with no input from you."
info "If you haven't yet: bind the cert once in PAN-OS via an SSL/TLS Service Profile."
