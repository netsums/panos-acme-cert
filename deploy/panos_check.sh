#!/usr/bin/env sh

# panos_check: acme.sh deploy hook, runs BEFORE the upstream "panos" hook.
#
#   acme.sh --deploy -d vpn.example.com --deploy-hook panos_check --deploy-hook panos --deploy-hook panos_push --ecc
#
# Records which template stacks contain the cert's template (PANOS_TEMPLATE)
# and whether any firewall in them is already not "In Sync", i.e. whether
# Panorama holds committed changes that aren't pushed yet. panos_push then
# pushes only if every stack was clean before acme.sh touched it.
# Never fails, so the import always happens. Role needs Operational Requests.

panos_check_deploy() {
  _getdeployconf PANOS_HOST
  _getdeployconf PANOS_KEY
  _getdeployconf PANOS_TEMPLATE

  if [ -z "$PANOS_TEMPLATE" ]; then
    _savedeployconf PANOS_PUSH_STATE "none" 1
    return 0
  fi

  export _H1="Content-Type: application/x-www-form-urlencoded"
  _pc_cmd="$(printf '%s' '<show><template-stack/></show>' | _url_encode)"
  _pc_key="$(printf '%s' "$PANOS_KEY" | _url_encode)"
  _pc_resp="$(_post "type=op&cmd=$_pc_cmd&key=$_pc_key" "https://$PANOS_HOST/api/" "" "POST")"

  if ! _contains "$_pc_resp" 'status="success"'; then
    _savedeployconf PANOS_PUSH_STATE "error:could not read the template stack status" 1
    _err "panos_check: could not read the template stack status, panos_push will not push."
    return 0
  fi

  # "S <stack>" for every stack containing the template,
  # "D <stack>" for those with a firewall whose template-status isn't "In Sync"
  _pc_out="$(printf '%s' "$_pc_resp" | awk -v tpl="$PANOS_TEMPLATE" '
    BEGIN { RS = "<"; d = 0 }
    NR > 1 {
      rec = $0
      tag = rec; sub(/>.*/, "", tag)
      if (tag ~ /^\//) { d--; next }
      if (tag ~ /^[?!]/) next
      txt = ""; if (index(rec, ">")) txt = substr(rec, index(rec, ">") + 1)
      gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", txt)
      t = tag; sub(/[ \t\/].*/, "", t)
      if (t == "entry" && d >= 1 && p[d-1] == "template-stack" && match(tag, /name="[^"]*"/)) {
        cur = substr(tag, RSTART + 6, RLENGTH - 7); order[++n] = cur
      }
      if (t == "member" && p[d-1] == "templates" && p[d-3] == "template-stack" && txt == tpl) has[cur] = 1
      if (t == "template-status" && txt != "In Sync") dirty[cur] = 1
      p[d] = t
      if (tag !~ /\/$/) d++
    }
    END { for (i = 1; i <= n; i++) if (has[order[i]]) { print "S " order[i]; if (dirty[order[i]]) print "D " order[i] } }')"

  _pc_stacks="$(printf '%s\n' "$_pc_out" | sed -n 's/^S //p' | tr '\n' ' ' | sed 's/ *$//')"
  _pc_dirty="$(printf '%s\n' "$_pc_out" | sed -n 's/^D //p' | tr '\n' ' ' | sed 's/ *$//')"

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
