#!/usr/bin/env sh

# NOT part of acme.sh. Written by netsums for
# https://github.com/netsums/panos-acme-cert (see FULL-AUTO-PUSH.md).
# MIT License. Provided as is, without warranty of any kind; use at your own
# risk. Test in a lab first and monitor your certificates' expiry dates.
#
# panos_check: acme.sh deploy hook. Runs BEFORE the upstream "panos" hook.
#
#   acme.sh --deploy -d vpn.example.com --ecc \
#     --deploy-hook panos_check --deploy-hook panos --deploy-hook panos_push
#
# What it does, in short:
#   1. Reads the cert's saved Panorama settings (host, API key, template).
#   2. Asks Panorama for all template stacks: <show><template-stack/></show>.
#   3. Keeps the stacks that contain the cert's template, and notes which of
#      them have a firewall that is not "In Sync" (= committed changes on
#      Panorama that were never pushed).
#   4. Saves the result in the cert's config as PANOS_PUSH_STATE, for
#      panos_push to read after the import:
#        none            the cert has no template, nothing to push
#        clean:<stacks>  all stacks in sync, panos_push may push them
#        dirty:<stacks>  these stacks were already out of sync, don't push
#        error:<reason>  something went wrong, don't push
#
# It changes nothing on Panorama and never fails, so the import by the
# "panos" hook always happens. The admin role needs XML API Operational
# Requests. Needs xmllint on the box (apt install libxml2-utils; on RHEL
# it comes with the libxml2 package).

panos_check_deploy() {
  _getdeployconf PANOS_HOST
  _getdeployconf PANOS_KEY
  _getdeployconf PANOS_TEMPLATE

  # No template (e.g. Panorama's own mgmt cert): nothing will need a push
  if [ -z "$PANOS_TEMPLATE" ]; then
    _savedeployconf PANOS_PUSH_STATE "none" 1
    return 0
  fi

  if ! _exists xmllint; then
    _savedeployconf PANOS_PUSH_STATE "error:xmllint is not installed (libxml2-utils / libxml2)" 1
    _err "panos_check: xmllint is not installed, panos_push will not push."
    return 0
  fi

  # Ask Panorama for every template stack, its templates and its firewalls
  export _H1="Content-Type: application/x-www-form-urlencoded"
  _pc_cmd="$(printf '%s' '<show><template-stack/></show>' | _url_encode)"
  _pc_key="$(printf '%s' "$PANOS_KEY" | _url_encode)"
  _pc_resp="$(_post "type=op&cmd=$_pc_cmd&key=$_pc_key" "https://$PANOS_HOST/api/" "" "POST")"

  if [ "$(_panos_check_xpath 'string(/response/@status)')" != "success" ]; then
    _savedeployconf PANOS_PUSH_STATE "error:could not read the template stack status" 1
    _err "panos_check: could not read the template stack status, panos_push will not push."
    return 0
  fi

  # Read the answer with XPath. The stacks we want are the <entry> elements
  # under <template-stack> whose <templates> list has our template. "Dirty"
  # are those of them where any firewall's <template-status> is not "In Sync".
  _pc_mine="//template-stack/entry[templates/member = '$PANOS_TEMPLATE']"
  _pc_stacks="$(_panos_check_names "$_pc_mine")"
  _pc_dirty="$(_panos_check_names "$_pc_mine[.//template-status != 'In Sync']")"

  if [ -z "$_pc_stacks" ]; then
    _savedeployconf PANOS_PUSH_STATE "error:no template stack contains $PANOS_TEMPLATE" 1
  elif [ -n "$_pc_dirty" ]; then
    _savedeployconf PANOS_PUSH_STATE "dirty:$_pc_dirty" 1
  else
    _savedeployconf PANOS_PUSH_STATE "clean:$_pc_stacks" 1
  fi
  _info "panos_check: stacks with $PANOS_TEMPLATE: ${_pc_stacks:-none}; not in sync before import: ${_pc_dirty:-none}"
  return 0
}

# Run an XPath query on Panorama's answer and print the result
_panos_check_xpath() {
  printf '%s' "$_pc_resp" | xmllint --xpath "$1" - 2>/dev/null
}

# Print the name="..." of every element an XPath matches, space-separated
_panos_check_names() {
  _panos_check_xpath "$1/@name" | grep -o 'name="[^"]*"' | cut -d'"' -f2 | tr '\n' ' ' | sed 's/ *$//'
}
