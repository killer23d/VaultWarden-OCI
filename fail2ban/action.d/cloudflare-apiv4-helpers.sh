#!/usr/bin/env bash
# P7-27 fix: changed from #!/bin/sh — this file uses `local` which is not POSIX sh.
# cloudflare-apiv4-helpers.sh
# Shared helper functions sourced by actionban and actionunban in
# cloudflare-apiv4.conf.  Never executed directly.
#
# Callers MUST have set:
#   CF_TOKEN   – Cloudflare API bearer token
#
# Requires: curl, jq, awk, mktemp

# Secured tmpdir for all temp files created by this script.
# Mode 0700 ensures no world-readable file ever appears in /tmp.
# Created on first use; persistent across bans within the same F2B process.
_CF_TMPDIR="/run/fail2ban/curl-cfg"

# ---------------------------------------------------------------------------
# _cf_ensure_tmpdir
# Create the secured temp directory if it does not already exist.
# Called by _make_curl_cfg and _cf_api_call before mktemp.
# ---------------------------------------------------------------------------
_cf_ensure_tmpdir() {
  if [ ! -d "$_CF_TMPDIR" ]; then
    mkdir -p -m 0700 "$_CF_TMPDIR" 2>/dev/null || {
      echo "[cloudflare-apiv4] ERROR: cannot create secured tmpdir $_CF_TMPDIR" >&2
      return 1
    }
  fi
}

# ---------------------------------------------------------------------------
# _cf_load_token
# Read the Cloudflare API bearer token from the Docker secret file into
# CF_TOKEN (exported).  Returns 1 with a descriptive error if the file is
# missing, unreadable, or empty.  Used by actionstart/_cf_validate_token.
# ---------------------------------------------------------------------------
_cf_load_token() {
  local _cf_token_path="/run/secrets/fail2ban_cloudflare_firewall_token"
  if [ ! -e "$_cf_token_path" ]; then
    echo "[cloudflare-apiv4] ERROR: token file not found: $_cf_token_path" >&2
    return 1
  fi
  CF_TOKEN="$(cat "$_cf_token_path")" || {
    echo "[cloudflare-apiv4] ERROR: permission denied reading $_cf_token_path" >&2
    return 1
  }
  [ -n "$CF_TOKEN" ] || {
    echo "[cloudflare-apiv4] ERROR: token file is empty: $_cf_token_path" >&2
    return 1
  }
  export CF_TOKEN
}

# ---------------------------------------------------------------------------
# _validate_ip <candidate>
# Validate <candidate> using Python3 ipaddress module for strict RFC-compliant
# IPv4 and IPv6 parsing.  Returns 0 if valid, 1 otherwise.
# P7-20 fix: moved from inline definitions in actionban/actionunban.
# ---------------------------------------------------------------------------
_validate_ip() {
  local candidate="$1"
  python3 -c "import sys, ipaddress; ipaddress.ip_address(sys.argv[1])" "$candidate" 2>/dev/null || return 1
}

# ---------------------------------------------------------------------------
# _cf_get_or_create_waf_ruleset <zone_id>
# Return the zone WAF Custom Rules (http_request_firewall_custom) ruleset ID.
# Creates an empty zone-level ruleset if none exists yet.
# P7-20 fix: moved from inline definition in actionban.
# ---------------------------------------------------------------------------
_cf_get_or_create_waf_ruleset() {
  local zone_id="$1" out ruleset_id
  out="$(_cf_api_call \
    "https://api.cloudflare.com/client/v4/zones/${zone_id}/rulesets" "GET")" || return 1
  ruleset_id=$(printf "%s" "$out" | jq -r \
    ".result[] | select(.phase==\"http_request_firewall_custom\" and .kind==\"zone\") | .id" \
    | head -n1)

  if [ -n "$ruleset_id" ]; then
    printf "%s" "$ruleset_id"
    return 0
  fi

  # No ruleset yet — create an empty zone-level one.
  local create_body
  create_body="$(printf \
    "{\"name\":\"fail2ban custom rules\",\"kind\":\"zone\",\"phase\":\"http_request_firewall_custom\",\"rules\":[]}")"
  out="$(_cf_retry \
    "https://api.cloudflare.com/client/v4/zones/${zone_id}/rulesets" "POST" "$create_body")" \
    || return 1
  printf "%s" "$out" | jq -r ".result.id"
}

# ---------------------------------------------------------------------------
# _cf_get_waf_ruleset_id <zone_id>
# Return the zone WAF Custom Rules ruleset ID, or empty string if none exists.
# P7-20 fix: moved from inline definition in actionunban.
# ---------------------------------------------------------------------------
_cf_get_waf_ruleset_id() {
  local zone_id="$1" out
  out="$(_cf_api_call \
    "https://api.cloudflare.com/client/v4/zones/${zone_id}/rulesets" "GET")" || return 1
  printf "%s" "$out" | jq -r \
    ".result[] | select(.phase==\"http_request_firewall_custom\" and .kind==\"zone\") | .id" \
    | head -n1
}

# ---------------------------------------------------------------------------
# _cf_find_rule_id <zone_id> <ruleset_id> <tag>
# Find a rule inside a ruleset by its exact description tag.
# Returns the rule ID string, or empty string if not found.
# P7-20 fix: moved from inline definitions in actionban/actionunban.
# ---------------------------------------------------------------------------
_cf_find_rule_id() {
  local zone_id="$1" ruleset_id="$2" tag="$3" out
  out="$(_cf_api_call \
    "https://api.cloudflare.com/client/v4/zones/${zone_id}/rulesets/${ruleset_id}" "GET")" \
    || return 1
  printf "%s" "$out" | jq -r \
    ".result.rules // [] | .[] | select(.description == \"${tag}\") | .id" | head -n1
}

# ---------------------------------------------------------------------------
# _cf_validate_token
# Validate the Cloudflare API token by calling the /user/tokens/verify endpoint.
# Returns 0 if valid, 1 otherwise. Used by actionstart for early token detection.
# P7-23 fix: new function for startup token validation.
# ---------------------------------------------------------------------------
_cf_validate_token() {
  local cfg result
  _cf_load_token || return 1
  cfg=$(_make_curl_cfg) || return 1
  result=$(curl -sf --max-time 10 --config "$cfg" \
      "https://api.cloudflare.com/client/v4/user/tokens/verify" \
      | jq -r '.success' 2>/dev/null)
  rm -f "$cfg" 2>/dev/null
  [ "$result" = "true" ]  # P7-26 note: consistent with POSIX [ ] style used elsewhere in file
}

# ---------------------------------------------------------------------------
# _make_curl_cfg
# Write bearer token to a mode-600 temp file so it never appears in
# /proc/<PID>/cmdline.  Prints the tempfile path on stdout.
# Returns 1 on any error (hard — would expose live CF token).
#
# Temp file is created inside $_CF_TMPDIR (mode 0700, under /run/fail2ban)
# instead of /tmp. This eliminates the window where a world-readable empty
# file exists in a world-writable directory before install secures it.
# The install -m 600 step is retained for defence-in-depth.
# ---------------------------------------------------------------------------
_make_curl_cfg() {
  local cfg
  _cf_ensure_tmpdir || return 1
  cfg="$(mktemp --tmpdir="$_CF_TMPDIR" fail2ban-curl-cfg.XXXXXXXXXX)" || {
    echo "[cloudflare-apiv4] ERROR: mktemp failed in $_CF_TMPDIR" >&2
    return 1
  }
  # Secure the file atomically before writing the bearer token.
  # install -m 600 is O_CREAT|O_TRUNC with explicit mode — no chmod race.
  if ! install -m 600 /dev/null "$cfg" 2>/dev/null; then
    rm -f "$cfg"
    echo "[cloudflare-apiv4] ERROR: Failed to secure curl config tempfile — aborting to protect CF token" >&2
    return 1
  fi
  printf "header = \"Authorization: Bearer %s\"\nheader = \"Content-Type: application/json\"\n" \
    "$CF_TOKEN" > "$cfg"
  printf "%s" "$cfg"
}

# ---------------------------------------------------------------------------
# _cf_api_call <endpoint> <method> [body]
# Returns: 0 + prints response body on success (2xx+success:true, or 204).
#          1 on hard error.
#          2 + prints "RETRY_AFTER:<n>" on 429 rate-limit.
# ---------------------------------------------------------------------------
_cf_api_call() {
  local endpoint="$1" method="$2" body="${3:-}"
  local response_file header_file cfg_file http_code

  _cf_ensure_tmpdir || return 1
  response_file="$(mktemp --tmpdir="$_CF_TMPDIR" fail2ban-resp.XXXXXXXXXX)"
  header_file="$(mktemp --tmpdir="$_CF_TMPDIR" fail2ban-hdr.XXXXXXXXXX)"
  cfg_file="$(_make_curl_cfg)" || return 1

  if [ -n "$body" ]; then
    http_code=$(curl -sS -o "$response_file" -D "$header_file" -w "%{http_code}" \
      --connect-timeout 10 --max-time 30 \
      --config "$cfg_file" -X "$method" "$endpoint" --data "$body" || echo "000")
  else
    http_code=$(curl -sS -o "$response_file" -D "$header_file" -w "%{http_code}" \
      --connect-timeout 10 --max-time 30 \
      --config "$cfg_file" -X "$method" "$endpoint" || echo "000")
  fi
  rm -f "$cfg_file" 2>/dev/null || true

  # 429 Rate-limit: signal caller with back-off value from Retry-After header.
  if [ "$http_code" = "429" ]; then
    local retry_after
    retry_after=$(awk -F": *" \
      "tolower(\$1)==\"retry-after\"{gsub(\"\\\r\",\"\",\$2);print \$2;exit}" \
      "$header_file")
    [ -n "$retry_after" ] || retry_after=5
    rm -f "$header_file" "$response_file"
    printf "RETRY_AFTER:%s" "$retry_after"
    return 2
  fi

  # 204 No Content = success (WAF Rulesets DELETE returns this).
  if [ "$http_code" = "204" ]; then
    rm -f "$header_file" "$response_file"
    return 0
  fi

  # P7-24 fix: Guard against non-numeric http_code before arithmetic comparison.
  # curl failures already produce "000" via `|| echo "000"`, but an unexpected
  # non-numeric value would cause `[ -ge ]` to abort with a syntax error.
  case "$http_code" in
    ''|*[!0-9]*)
      echo "[cloudflare-apiv4] ERROR: curl returned non-numeric HTTP code: '${http_code}' (timeout or connection failure)" >&2
      rm -f "$header_file" "$response_file"
      return 1
      ;;
  esac

  # Standard 2xx JSON envelope with success:true.
  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ] && \
     jq -e ".success == true" "$response_file" >/dev/null 2>&1; then
    cat "$response_file"
    rm -f "$header_file" "$response_file"
    return 0
  fi

  echo "[cloudflare-apiv4] ERROR: HTTP ${http_code} from ${method} ${endpoint}" >&2
  jq -r ".errors[]?.message // empty" "$response_file" >&2 2>/dev/null || true
  rm -f "$header_file" "$response_file"
  return 1
}

# ---------------------------------------------------------------------------
# _cf_retry <endpoint> <method> [body] [attempts=4] [delays="2 4 8 16"]
# Retry wrapper with static delay table (POSIX sh portable; no bash ** needed).
# Delays (seconds): attempt 1→2, 2→4, 3→8, 4→16.
# On 429, sleeps the Retry-After value from the header instead.
#
# Defaults are sized to stay safely within Fail2Ban's default actiontimeout
# of 60 s: max accumulated sleep = 30 s, plus up to 30 s of curl --max-time
# per attempt, leaving a comfortable margin before the process is killed.
# If more retries are needed, raise actiontimeout in jail.d before raising
# attempts here (e.g. actiontimeout = 120 in [DEFAULT]).
# ---------------------------------------------------------------------------
_cf_retry() {
  local endpoint="$1" method="$2" body="${3:-}" attempts="${4:-4}"
  local delays="${5:-2 4 8 16}"
  local i=1 out rc delay

  while [ "$i" -le "$attempts" ]; do
    out="$(_cf_api_call "$endpoint" "$method" "$body")" && { printf "%s" "$out"; return 0; }
    rc=$?
    if [ "$rc" -eq 2 ] && printf "%s" "$out" | grep -q "^RETRY_AFTER:"; then
      retry_delay="${out#RETRY_AFTER:}"
      # Validate Retry-After is a positive integer and clamp to
      # max 60s to prevent injected header values from hanging Fail2Ban.
      # Non-numeric or out-of-range values fall back to the safe default of 5s.
      case "$retry_delay" in
        ''|*[!0-9]*) retry_delay=5 ;;
      esac
      if [ "$retry_delay" -gt 60 ]; then retry_delay=60; fi
      sleep "$retry_delay"
    else
      # Pick the i-th element from the static delay table (falls back to last).
      delay="$(printf "%s" "$delays" | awk -v n="$i" '{
        split($0,a," "); v=a[n]; if(v=="")v=a[length(a)]; print v}')"
      sleep "$delay"
    fi
    i=$(( i + 1 ))
  done
  return 1
}
