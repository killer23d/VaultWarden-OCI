#!/bin/sh
# cloudflare-apiv4-helpers.sh
# Shared helper functions sourced by actionban and actionunban in
# cloudflare-apiv4.conf.  Never executed directly.
#
# Callers MUST have set:
#   CF_TOKEN   – Cloudflare API bearer token
#
# Requires: curl, jq, awk, mktemp

# ---------------------------------------------------------------------------
# _make_curl_cfg
# Write bearer token to a mode-600 temp file so it never appears in
# /proc/<PID>/cmdline.  Prints the tempfile path on stdout.
# Returns 1 on chmod failure (hard error — would expose live CF token).
# ---------------------------------------------------------------------------
_make_curl_cfg() {
  # BUG-#16 FIX: Use install -m 600 to create the temp file at mode 600
  # atomically, eliminating the mktemp (world-readable) → chmod 600 race window.
  # The bearer token is never written until after the file is secured.
  local cfg
  cfg="$(mktemp)"
  # Secure the file atomically before writing the bearer token.
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

  response_file="$(mktemp)"
  header_file="$(mktemp)"
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
      "tolower(\$1)==\"retry-after\"{gsub(\"\\r\",\"\",\$2);print \$2;exit}" \
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
      # BUG-#37 FIX: Validate Retry-After is a positive integer and clamp to
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
