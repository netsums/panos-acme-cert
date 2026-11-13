#!/usr/bin/env sh

# panos_push: acme.sh deploy hook, runs AFTER the upstream "panos" hook.
#
#   acme.sh --deploy -d vpn.example.com --deploy-hook panos_check --deploy-hook panos --deploy-hook panos_push --ecc
#
# Pushes the cert's template to every firewall that uses it, but only if
# panos_check found every template stack containing that template "In Sync"
# before the import. Then the only change pending is acme.sh's own, so the
# push can't carry anyone else's committed work. Otherwise it doesn't push and
# fails with a message, so your acme.sh notification tells you to push by hand.
#
# Leave PANOS_TEMPLATE_STACK unset. Panorama role (XML API): Import, Commit,
# Operational Requests. Remaining gap: a colleague committing in the minutes
# between panos_check and the push.

_PANOS_PUSH_WAIT=30  # seconds between job checks
_PANOS_PUSH_TRIES=40 # 40 * 30 s = 20 minutes per job

panos_push_deploy() {
  _getdeployconf PANOS_HOST
  _getdeployconf PANOS_USER
  _getdeployconf PANOS_KEY
  _getdeployconf PANOS_PUSH_STATE
  _pp_state="$PANOS_PUSH_STATE"
  _savedeployconf PANOS_PUSH_STATE "" 1 # one result per deploy run

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

  _info "panos_push: waiting for Panorama commit jobs to finish"
  if ! _panos_push_wait_idle; then
    _err "panos_push: a commit job is still running after $((_PANOS_PUSH_WAIT * _PANOS_PUSH_TRIES)) s, not pushing."
    return 1
  fi

  # 3 + 4. Push each stack, admin-scoped, and wait for the result
  _pp_failed=""
  for _pp_stack in $_pp_stacks; do
    _pp_cmd="<commit-all><template-stack><exclude-other-admins>yes</exclude-other-admins><name>$_pp_stack</name><admin><member>$PANOS_USER</member></admin><description>acme.sh renewal $1</description></template-stack></commit-all>"
    _pp_resp="$(_panos_push_api "type=commit&action=all&cmd=$(printf '%s' "$_pp_cmd" | _url_encode)")"
    _pp_job="$(printf '%s' "$_pp_resp" | tr -d '\n' | sed -n 's:.*<job>\([0-9]*\)</job>.*:\1:p')"
    if [ -z "$_pp_job" ]; then
      _err "panos_push: push of '$_pp_stack' not accepted: $_pp_resp"
      _pp_failed="$_pp_failed $_pp_stack"
      continue
    fi
    _info "panos_push: pushing '$_pp_stack', job $_pp_job"
    if _panos_push_wait_job "$_pp_job"; then
      _info "panos_push: '$_pp_stack' pushed OK"
    else
      _err "panos_push: push of '$_pp_stack' failed (job $_pp_job): $_pp_job_xml"
      _pp_failed="$_pp_failed $_pp_stack"
    fi
  done

  if [ -n "$_pp_failed" ]; then
    _err "panos_push: failed stacks:$_pp_failed"
    return 1
  fi
  return 0
}

_panos_push_api() {
  _post "$1&key=$(printf '%s' "$PANOS_KEY" | _url_encode)" "$_pp_url" "" "POST"
}

# Wait until no commit-type job is pending or active
_panos_push_wait_idle() {
  _pp_i=0
  while [ "$_pp_i" -lt "$_PANOS_PUSH_TRIES" ]; do
    _pp_jobs="$(_panos_push_api "type=op&cmd=$(printf '%s' '<show><jobs><all/></jobs></show>' | _url_encode)")"
    if ! printf '%s' "$_pp_jobs" | tr -d '\n' | sed 's:</job>:&\
:g' | grep -i '<type>[^<]*commit[^<]*</type>' | grep -qE '<status>(ACT|PEND)</status>'; then
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
    if _contains "$_pp_job_xml" '<status>FIN</status>'; then
      if _contains "$_pp_job_xml" '<result>OK</result>' && ! _contains "$_pp_job_xml" '<result>FAIL</result>'; then
        return 0
      fi
      return 1
    fi
    _sleep "$_PANOS_PUSH_WAIT"
    _pp_i=$((_pp_i + 1))
  done
  _pp_job_xml="still not finished after $((_PANOS_PUSH_WAIT * _PANOS_PUSH_TRIES)) s"
  return 1
}
