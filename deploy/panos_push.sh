#!/usr/bin/env sh

# NOT part of acme.sh. Written by netsums for
# https://github.com/netsums/panos-acme-cert (see FULL-AUTO-PUSH.md).
# MIT License. Provided as is, without warranty of any kind; use at your own
# risk. Test in a lab first and monitor your certificates' expiry dates.
#
# panos_push: acme.sh deploy hook. Runs AFTER the upstream "panos" hook,
# which has already imported the cert into its template and committed it.
#
#   acme.sh --deploy -d vpn.example.com --ecc \
#     --deploy-hook panos_check --deploy-hook panos --deploy-hook panos_push
#
# What it does, in short:
#   1. Reads what panos_check saved (PANOS_PUSH_STATE) and clears it.
#      - no template      -> nothing to push, success
#      - stacks were dirty or panos_check failed -> push nothing, fail with a
#        message, so the acme.sh notification tells you to push by hand
#      - all stacks clean -> go on
#   2. Waits until Panorama has no commit job running (the "panos" hook's
#      commit must be finished before a push).
#   3. Pushes each stack: commit-all, template-stack, scoped to the acme
#      admin, with the description "acme.sh renewal <cert>".
#   4. Waits for each push job and fails if any firewall reports FAIL.
#
# Because the stacks were in sync before the import, the only change being
# pushed is acme.sh's own cert. Leave PANOS_TEMPLATE_STACK unset, or the
# "panos" hook pushes one stack on its own first. Admin role (XML API):
# Import, Commit, Operational Requests. Needs xmllint (see panos_check).

_PANOS_PUSH_WAIT=30  # seconds between job checks
_PANOS_PUSH_TRIES=40 # 40 * 30 s = 20 minutes per job

panos_push_deploy() {
  _getdeployconf PANOS_HOST
  _getdeployconf PANOS_USER
  _getdeployconf PANOS_KEY
  _getdeployconf PANOS_PUSH_STATE
  # 1. Read panos_check's result, then clear it so the next run starts fresh
  _pp_state="$PANOS_PUSH_STATE"
  _savedeployconf PANOS_PUSH_STATE "" 1

  case "$_pp_state" in
    none)
      _info "panos_push: $1 has no PANOS_TEMPLATE, nothing to push."
      return 0 ;;
    clean:*)
      _pp_stacks="${_pp_state#clean:}" ;;
    dirty:*)
      _err "panos_push: $1 is imported and committed, NOT pushed. These stacks already had unpushed changes: ${_pp_state#dirty:}. Push them yourself."
      return 1 ;;
    error:*)
      _err "panos_push: $1 is imported and committed, NOT pushed: ${_pp_state#error:}. Push it yourself."
      return 1 ;;
    *)
      _err "panos_push: no result from panos_check. Use --deploy-hook panos_check --deploy-hook panos --deploy-hook panos_push, in that order."
      return 1 ;;
  esac

  export _H1="Content-Type: application/x-www-form-urlencoded"
  _pp_url="https://$PANOS_HOST/api/"

  # 2. The "panos" hook's commit must be done before we push
  _info "panos_push: waiting for Panorama commit jobs to finish"
  if ! _panos_push_wait_idle; then
    _err "panos_push: a commit job is still running after $((_PANOS_PUSH_WAIT * _PANOS_PUSH_TRIES)) s, not pushing."
    return 1
  fi

  # 3 + 4. Push each stack, scoped to the acme admin, and wait for the result
  _pp_failed=""
  for _pp_stack in $_pp_stacks; do
    _pp_cmd="<commit-all><template-stack><exclude-other-admins>yes</exclude-other-admins><name>$_pp_stack</name><admin><member>$PANOS_USER</member></admin><description>acme.sh renewal $1</description></template-stack></commit-all>"
    _pp_resp="$(_panos_push_api "type=commit&action=all&cmd=$(printf '%s' "$_pp_cmd" | _url_encode)")"
    _pp_job="$(_panos_push_xpath "$_pp_resp" 'string(/response/result/job)')"
    if [ -z "$_pp_job" ]; then
      _err "panos_push: push of '$_pp_stack' not accepted: $_pp_resp"
      _pp_failed="$_pp_failed $_pp_stack"
      continue
    fi
    _info "panos_push: pushing '$_pp_stack', job $_pp_job"
    if _panos_push_wait_job "$_pp_job"; then
      _info "panos_push: '$_pp_stack' pushed OK"
    else
      _err "panos_push: push of '$_pp_stack' failed (job $_pp_job):"
      _panos_push_explain "$_pp_job_xml"
      _pp_failed="$_pp_failed $_pp_stack"
    fi
  done

  if [ -n "$_pp_failed" ]; then
    _err "panos_push: failed stacks:$_pp_failed"
    return 1
  fi
  return 0
}

# Call the Panorama XML API with the saved key
_panos_push_api() {
  _post "$1&key=$(printf '%s' "$PANOS_KEY" | _url_encode)" "$_pp_url" "" "POST"
}

# Run an XPath query on an XML answer: _panos_push_xpath "<xml>" "<xpath>"
_panos_push_xpath() {
  printf '%s' "$1" | xmllint --xpath "$2" - 2>/dev/null
}

# Log why a push job failed: Panorama's own <details> lines (job level, then
# per firewall), plus a hint for errors we know. Raw XML only if none found.
_panos_push_explain() {
  _pp_lines="$(_panos_push_lines "$1" '//job/details//line')"
  _pp_n="$(_panos_push_xpath "$1" 'count(//devices/entry[result = "FAIL"])')"
  _pp_d=1
  while [ "$_pp_d" -le "${_pp_n:-0}" ]; do
    _pp_dev="(//devices/entry[result = \"FAIL\"])[$_pp_d]"
    _pp_name="$(_panos_push_xpath "$1" "string($_pp_dev/devicename)")"
    [ -n "$_pp_name" ] || _pp_name="$(_panos_push_xpath "$1" "string($_pp_dev/serial-no)")"
    _pp_dlines="$(_panos_push_lines "$1" "$_pp_dev/details//line")"
    [ -n "$_pp_dlines" ] || _pp_dlines="push failed"
    _pp_lines="$_pp_lines
$(printf '%s\n' "$_pp_dlines" | sed "s|^|$_pp_name: |")"
    _pp_d=$((_pp_d + 1))
  done
  _pp_lines="$(printf '%s\n' "$_pp_lines" | sed '/^$/d')"

  if [ -z "$_pp_lines" ]; then
    _err "panos_push:   $1"
    return
  fi
  printf '%s\n' "$_pp_lines" | while IFS= read -r _pp_line; do
    _err "panos_push:   $_pp_line"
  done
  case "$_pp_lines" in
    *"no connected device"*)
      _err "panos_push: hint: no firewall in '$_pp_stack' is connected to Panorama. Check Panorama > Managed Devices > Summary, then push the stack yourself." ;;
    *"out of the config-audit range"*|*"Perform a full push"*)
      _err "panos_push: hint: Panorama may need one full push of '$_pp_stack'. Push it yourself, then selective pushes work again." ;;
  esac
}

# Print each non-empty node matching an XPath as one trimmed line:
# _panos_push_lines "<xml>" "<xpath>"
_panos_push_lines() {
  _pp_c="$(_panos_push_xpath "$1" "count($2)")"
  _pp_k=1
  while [ "$_pp_k" -le "${_pp_c:-0}" ]; do
    _panos_push_xpath "$1" "normalize-space(($2)[$_pp_k])"
    echo
    _pp_k=$((_pp_k + 1))
  done | sed '/^$/d'
}

# Wait until no commit-type job is pending or active
_panos_push_wait_idle() {
  _pp_i=0
  while [ "$_pp_i" -lt "$_PANOS_PUSH_TRIES" ]; do
    _pp_jobs="$(_panos_push_api "type=op&cmd=$(printf '%s' '<show><jobs><all/></jobs></show>' | _url_encode)")"
    _pp_busy="$(_panos_push_xpath "$_pp_jobs" 'count(//job[contains(type, "Commit") or contains(type, "commit")][status = "ACT" or status = "PEND"])')"
    if [ "$_pp_busy" = "0" ]; then
      return 0
    fi
    _sleep "$_PANOS_PUSH_WAIT"
    _pp_i=$((_pp_i + 1))
  done
  return 1
}

# Wait for one job; success = finished, overall result OK, no device FAIL
_panos_push_wait_job() {
  _pp_i=0
  while [ "$_pp_i" -lt "$_PANOS_PUSH_TRIES" ]; do
    _pp_job_xml="$(_panos_push_api "type=op&cmd=$(printf '%s' "<show><jobs><id>$1</id></jobs></show>" | _url_encode)" | tr -d '\n')"
    if [ "$(_panos_push_xpath "$_pp_job_xml" 'string(//job/status)')" = "FIN" ]; then
      [ "$(_panos_push_xpath "$_pp_job_xml" 'boolean(//result[. = "OK"]) and not(//result[. = "FAIL"])')" = "true" ]
      return
    fi
    _sleep "$_PANOS_PUSH_WAIT"
    _pp_i=$((_pp_i + 1))
  done
  _pp_job_xml="still not finished after $((_PANOS_PUSH_WAIT * _PANOS_PUSH_TRIES)) s"
  return 1
}
