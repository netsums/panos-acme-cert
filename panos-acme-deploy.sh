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
#   3. Checks the mgmt TLS certificate. If it is not publicly trusted, it shows
#      you the fingerprint and pins that key for every request this script
#      makes, so your password is never sent to an unverified host.
#   4. Gets an API key: reuses one you already have, or generates one from your
#      password via the firewall's own keygen endpoint. The password is read
#      hidden, passed to curl over stdin (never on a command line, so it does
#      not show up in `ps`), sent ONLY to your firewall, then discarded.
#   5. Verifies the key actually works.
#   6. Runs the acme.sh 'panos' deploy hook to import the cert and commit.
#
# SECURITY NOTES — please read before running:
#   * This script talks to exactly ONE host: the mgmt address you give it.
#     It has no other outbound calls. It does not phone home. You can verify
#     that yourself:   grep -nE 'curl|openssl s_client' panos-acme-deploy.sh
#   * Use a RESTRICTED admin (XML API: Import + Commit only), never superuser.
#     Add Operational Requests ONLY for Panorama template-stack pushes: it
#     lets the key run op commands such as 'show config running'.
#     The API key inherits only that account's rights.
#   * acme.sh stores the API key in its domain .conf file BASE64-ENCODED, NOT
#     encrypted. Anyone who can read ~/.acme.sh can use the key. Run this as a
#     dedicated user and keep that directory private.
#   * Don't pipe this from the internet into a shell. Download it, read it,
#     then run it:   bash panos-acme-deploy.sh
#
# Repo:    https://github.com/netsums/panos-acme-cert
# License: MIT
# -----------------------------------------------------------------------------
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/panos-acme"
CONFIG_FILE="$CONFIG_DIR/deploy.env"
KEY_FILE="$CONFIG_DIR/apikey"

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

# ---- input validation -------------------------------------------------------
# Values end up in URLs, the saved config and acme.sh's config, so only allow
# plain hostname / username / domain characters.
valid_host()   { [[ "$1" =~ ^[A-Za-z0-9._:-]+$ ]]; }
valid_user()   { [[ "$1" =~ ^[A-Za-z0-9._@-]+$ ]]; }
valid_domain() { [[ "$1" =~ ^(\*\.)?[A-Za-z0-9.-]+$ ]]; }

# ---- saved (non-secret) defaults: parsed, never sourced ---------------------
SAVED_HOST="" SAVED_USER="" SAVED_DOMAIN="" SAVED_PIN=""
load_config() {
  local line k v
  [ -f "$CONFIG_FILE" ] || return 0
  while IFS= read -r line; do
    k="${line%%=*}" v="${line#*=}"   # not IFS='=': that eats a trailing '=' (base64)
    case "$k" in
      SAVED_HOST)   valid_host   "$v" && SAVED_HOST="$v" ;;
      SAVED_USER)   valid_user   "$v" && SAVED_USER="$v" ;;
      SAVED_DOMAIN) valid_domain "$v" && SAVED_DOMAIN="$v" ;;
      SAVED_PIN)    [[ "$v" =~ ^sha256//[A-Za-z0-9+/=]+$ ]] && SAVED_PIN="$v" ;;
    esac
  done < "$CONFIG_FILE"
  return 0
}
save_config() {
  (umask 077; printf '%s\n' \
    "# panos-acme-deploy saved defaults (non-secret). Parsed, not sourced." \
    "SAVED_HOST=$PANOS_HOST" \
    "SAVED_USER=$PANOS_USER" \
    "SAVED_DOMAIN=$ACME_DOMAIN" \
    "SAVED_PIN=$TLS_PIN" > "$CONFIG_FILE")
}

# ---- TLS to the firewall ----------------------------------------------------
# TLS_MODE=verified : mgmt cert chains to a trusted CA and matches the name.
# TLS_MODE=pinned   : self-signed / untrusted; we pin the public key the user
#                     confirmed, so a MITM can't swap it mid-run.
TLS_MODE="" TLS_PIN=""
fw_curl() {                   # curl to the firewall with the right TLS mode
  if [ "$TLS_MODE" = verified ]; then
    curl -sS --connect-timeout 5 --max-time 60 "$@"
  else
    # -k skips CA/name checks; --pinnedpubkey is still enforced and aborts the
    # connection before any data is sent if the key doesn't match.
    curl -sS -k --pinnedpubkey "$TLS_PIN" --connect-timeout 5 --max-time 60 "$@"
  fi
}
fetch_server_cert() {         # PEM of the cert the host presents
  local connect="$PANOS_HOST:443"
  [[ "$PANOS_HOST" == *:* ]] && connect="[$PANOS_HOST]:443"   # IPv6 literal
  timeout 10 openssl s_client -connect "$connect" -servername "$PANOS_HOST" \
      </dev/null 2>/dev/null | openssl x509 2>/dev/null
}

# ---- API helpers: secrets always go to curl on stdin ------------------------
api_version() {               # type=version needs no op rights -> response
  printf '%s' "$PANOS_KEY" | fw_curl -X POST "https://$PANOS_HOST/api/?type=version" \
      --data-urlencode "key@-"
}

load_config

# Environment variables win over the saved file; both become prompt defaults.
PANOS_HOST="${PANOS_HOST:-$SAVED_HOST}"
PANOS_USER="${PANOS_USER:-${SAVED_USER:-acme}}"
ACME_DOMAIN="${ACME_DOMAIN:-$SAVED_DOMAIN}"

command -v curl    >/dev/null 2>&1 || die "curl is required."
command -v openssl >/dev/null 2>&1 || die "openssl is required."

bold "PAN-OS + acme.sh certificate deploy"

# ---- 0. prerequisites -------------------------------------------------------
bold "Step 0 — Prerequisites (this script changes nothing until you confirm)"
info "This will only work if the following are ALREADY true:"
info "  1. A restricted admin exists on the firewall, whose Admin Role enables"
info "     (XML API):  Import  and  Commit  — and nothing else. NOT superuser."
info "     (Panorama pushing to a template stack also needs Operational Requests.)"
info "  2. You have that account's password (used once), OR an API key already."
info "  3. This machine can reach the firewall mgmt interface on TCP 443"
info "     (mgmt 'Permitted IP Addresses' includes this machine's IP)."
info "  4. The certificate has already been issued by acme.sh on this machine."
echo
confirm "Have you done all four?" || die "Set up the prerequisites first, then re-run. See the README."

# ---- 1. target --------------------------------------------------------------
bold "Step 1 — Firewall / Panorama"
PANOS_HOST="$(ask "  Mgmt address (FQDN recommended, or IP)" "$PANOS_HOST")"
valid_host "$PANOS_HOST" || die "Mgmt address is missing or contains invalid characters."
PANOS_USER="$(ask "  Restricted admin username" "$PANOS_USER")"
valid_user "$PANOS_USER" || die "Username is missing or contains invalid characters."
[ "$PANOS_HOST" = "$SAVED_HOST" ] || SAVED_PIN=""   # a pin only applies to its host

# ---- 2. reachability + TLS identity -----------------------------------------
bold "Step 2 — Reachability and TLS identity of $PANOS_HOST"
if curl -sSI --connect-timeout 5 --max-time 15 "https://$PANOS_HOST/" >/dev/null 2>&1; then
  TLS_MODE=verified
  ok "$PANOS_HOST answers on 443 with a trusted certificate that matches its name."
else
  cert="$(fetch_server_cert || true)"
  [ -n "$cert" ] || die "Can't reach $PANOS_HOST:443. Check mgmt Permitted IP Addresses, routing, and that this really is the mgmt interface."
  TLS_MODE=pinned
  TLS_PIN="sha256//$(openssl x509 -pubkey -noout <<<"$cert" \
      | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl base64)"
  fp="$(openssl x509 -noout -fingerprint -sha256 <<<"$cert" | cut -d= -f2)"
  subj="$(openssl x509 -noout -subject <<<"$cert" | sed 's/^subject= *//')"
  warn "The mgmt certificate is NOT publicly trusted (self-signed, private CA,"
  warn "or it doesn't match '$PANOS_HOST')."
  info "  Subject:            $subj"
  info "  SHA-256 fingerprint: $fp"
  if [ -n "$SAVED_PIN" ] && [ "$SAVED_PIN" = "$TLS_PIN" ]; then
    ok "Same key you confirmed on a previous run."
  else
    if [ -n "$SAVED_PIN" ]; then
      warn "THIS KEY IS DIFFERENT FROM THE ONE YOU CONFIRMED LAST TIME."
      warn "Expected if the mgmt cert was replaced. Otherwise: possible interception."
    fi
    info "Compare that fingerprint with the mgmt certificate on the firewall"
    info "(GUI: Device > Certificate Management > Certificates, open the cert"
    info "used by the mgmt SSL/TLS Service Profile). Only continue if they match,"
    info "or you're on a network path you fully trust."
    confirm "  Does the fingerprint match?" || die "Aborted. Nothing was sent to the firewall."
  fi
  ok "Pinned that key for every request this script makes."
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
  info "Generating a new key. Your password is read hidden, handed to curl on"
  info "stdin, sent only to $PANOS_HOST, and discarded. It is never stored."
  PANPASS="$(ask_secret "  Password for \"$PANOS_USER\"")"
  [ -n "$PANPASS" ] || die "Password was empty."
  resp="$(printf '%s' "$PANPASS" | fw_curl -X POST "https://$PANOS_HOST/api/?type=keygen" \
      --data-urlencode "user=$PANOS_USER" \
      --data-urlencode "password@-" || true)"
  unset PANPASS
  PANOS_KEY="$(sed -n 's:.*<key>\(.*\)</key>.*:\1:p' <<<"$resp")"
  unset resp
  [ -n "$PANOS_KEY" ] || die "Keygen failed: wrong username/password, or the account has no API access. Check the restricted admin's role."
  ok "Key generated."
  if confirm "  Save this key to $KEY_FILE (mode 600) so you can reuse it?"; then
    mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
    (umask 077; printf '%s' "$PANOS_KEY" > "$KEY_FILE")
    ok "Saved. This file is a live credential — protect it accordingly."
  fi
fi

# ---- 4. verify the key ------------------------------------------------------
bold "Step 4 — Verifying the key actually works"
resp="$(api_version || true)"
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
valid_domain "$ACME_DOMAIN" || die "Domain is missing or contains invalid characters."

ACME=""
if command -v acme.sh >/dev/null 2>&1; then ACME="acme.sh"
elif [ -x "$HOME/.acme.sh/acme.sh" ]; then ACME="$HOME/.acme.sh/acme.sh"
else die "acme.sh not found. Install it and issue the certificate first."; fi

# Exact match on the Main_Domain column; pick up the key type for --ecc.
keylen="$("$ACME" --list --listraw 2>/dev/null \
    | awk -F'|' -v d="$ACME_DOMAIN" 'NR>1 && $1==d {gsub(/"/,"",$2); print $2; exit}')"
if ! "$ACME" --list --listraw 2>/dev/null | awk -F'|' -v d="$ACME_DOMAIN" 'NR>1 && $1==d {f=1} END{exit !f}'; then
  warn "acme.sh has no issued cert whose main domain is exactly $ACME_DOMAIN. Issue it first, e.g.:"
  info "  acme.sh --issue --dns dns_cf -d $ACME_DOMAIN --challenge-alias <burner-domain> --server letsencrypt"
  die "Nothing to deploy yet."
fi
ok "Found an issued cert for $ACME_DOMAIN (key: ${keylen:-default})."

# ---- 6. confirm & deploy ----------------------------------------------------
bold "Step 6 — Deploy"
info "This imports the certificate + key into $PANOS_HOST and commits"
info "(a partial commit scoped to the '$PANOS_USER' admin)."

deploy_args=(--deploy -d "$ACME_DOMAIN" --deploy-hook panos)
[[ "$keylen" == ec-* ]] && deploy_args+=(--ecc)
if [ "$TLS_MODE" = pinned ]; then
  # acme.sh can't pin a key, so this run needs --insecure. We checked the key
  # above, seconds ago; that's the best available for this one run.
  deploy_args+=(--insecure)
  warn "acme.sh can't pin keys, so this deploy uses --insecure (for this run only)."
  warn "AUTOMATIC RENEWALS WILL FAIL to deploy while mgmt presents an untrusted"
  warn "cert: renewals run the hook with normal TLS checks. Fix: bind a publicly"
  warn "trusted cert to the mgmt SSL/TLS Service Profile (e.g. this one) and set"
  warn "the mgmt address to a name on that cert. Don't set HTTPS_INSECURE=1 in"
  warn "acme.sh's account.conf — that disables TLS checks for ALL acme.sh traffic,"
  warn "including Let's Encrypt and your DNS provider API."
fi
confirm "Proceed?" || die "Aborted. Nothing was changed on the firewall."

export PANOS_HOST PANOS_USER PANOS_KEY
if "$ACME" "${deploy_args[@]}"; then
  ok "Deploy hook finished."
else
  die "Deploy failed — see acme.sh output above. Most common cause: the role is missing Import or Commit."
fi
unset PANOS_KEY

# ---- 7. persist non-secret defaults ----------------------------------------
mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
save_config

bold "Done"
info "acme.sh saved the host, user and API key in its domain .conf for renewals."
info "The key is only BASE64-ENCODED there, not encrypted — protect ~/.acme.sh."
if [ "$TLS_MODE" = verified ]; then
  info "Mgmt TLS verifies, so each renewal re-imports and commits on its own."
else
  warn "Renewals won't deploy until mgmt presents a trusted cert (see Step 6)."
fi
info "If you haven't yet: bind the cert once in PAN-OS via an SSL/TLS Service Profile."
