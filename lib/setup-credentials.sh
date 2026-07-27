#!/usr/bin/env bash
# lib/setup-credentials.sh — root-only atomic credential handoffs.
# VWOCI-PRR-PATCH-01
#
# This library deliberately does not set shell options. Entry points own them.
# The audited delta schema has no canonical backup_passphrase field; therefore
# this handoff contains only credentials actually generated and consumed by the
# current implementation. Never substitute file_integrity_hmac_key here.

_SETUP_CREDENTIALS_DEFAULT_DIR="/root/vaultwarden-recovery"

_setup_handoff_invalid_value() {
  local value="${1:-}"
  [[ -n "$value" ]] || return 0
  case "$value" in
    CHANGE_ME*|PLACEHOLDER*|NOT_USED_*|your_*_here|"<"*">"|null|NULL) return 0 ;;
  esac
  [[ "$value" =~ ^[[:space:]]*$ ]]
}

_setup_handoff_prepare_dir() {
  local target_dir="$1"
  if [[ -L "$target_dir" ]]; then
    printf 'ERROR: recovery destination is a symlink: %s\n' "$target_dir" >&2
    return 1
  fi
  if [[ -e "$target_dir" && ! -d "$target_dir" ]]; then
    printf 'ERROR: recovery destination is not a directory: %s\n' "$target_dir" >&2
    return 1
  fi
  if [[ "${VW_HANDOFF_TEST_MODE:-false}" == "true" ]]; then
    install -d -m 700 "$target_dir" || return 1
  else
    install -d -m 700 -o root -g root "$target_dir" || return 1
  fi
  [[ ! -L "$target_dir" && -d "$target_dir" ]] || return 1
  [[ "$(stat -c '%a' "$target_dir" 2>/dev/null)" == "700" ]] || return 1
  if [[ "${VW_HANDOFF_TEST_MODE:-false}" != "true" ]]; then
    [[ "$(stat -c '%U:%G' "$target_dir" 2>/dev/null)" == "root:root" ]] || return 1
  fi
}

_setup_handoff_b64_decode() {
  local value="$1" padding
  case $((${#value} % 4)) in
    0) padding="" ;;
    2) padding="==" ;;
    3) padding="=" ;;
    *) return 1 ;;
  esac
  printf '%s%s' "$value" "$padding" | base64 -d
}

_setup_handoff_verify_argon2() {
  local plaintext="$1" encoded="$2"
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$encoded" 3<<<"$plaintext" <<'PY_VERIFY_ARGON2'
import os
import sys
try:
    from argon2 import PasswordHasher
    from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError
except Exception:
    raise SystemExit(1)
stored = sys.argv[1]
plain = os.fdopen(3, encoding="utf-8").read()
if plain.endswith("\n"):
    plain = plain[:-1]
try:
    ok = PasswordHasher().verify(stored, plain)
except (InvalidHashError, VerificationError, VerifyMismatchError):
    ok = False
raise SystemExit(0 if ok else 1)
PY_VERIFY_ARGON2
}

_setup_handoff_verify_bcrypt() (
  # PLAINTEXT is accepted only on fd 3 so it cannot enter argv or the
  # environment. Disable inherited xtrace before reading the descriptor.
  { set +x; } 2>/dev/null
  local encoded="$1"
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$encoded" 3<&3 <<'PY_VERIFY_BCRYPT'
import os
import sys
try:
    import bcrypt
except Exception:
    raise SystemExit(1)
stored = sys.argv[1]
plain = os.fdopen(3, encoding="utf-8").read()
if plain.endswith("\n"):
    plain = plain[:-1]
if not plain:
    raise SystemExit(1)
try:
    ok = bcrypt.checkpw(plain.encode("utf-8"), stored.encode("ascii"))
except Exception:
    ok = False
raise SystemExit(0 if ok else 1)
PY_VERIFY_BCRYPT
)

_setup_handoff_publish_file() {
  local temp_file="$1" final_file="$2"
  if [[ "${VW_HANDOFF_TEST_MODE:-false}" == "true" ]]; then
    chmod 600 "$temp_file" || return 1
  else
    chown root:root "$temp_file" || return 1
    chmod 600 "$temp_file" || return 1
  fi
  [[ "$(stat -c '%a' "$temp_file" 2>/dev/null)" == "600" ]] || return 1
  [[ ! -e "$final_file" && ! -L "$final_file" ]] || return 1
  # Hard-link publication is atomic, same-filesystem, and fails if FINAL exists.
  ln "$temp_file" "$final_file" || return 1
  if ! rm -f "$temp_file"; then
    rm -f -- "$final_file" 2>/dev/null || true
    return 1
  fi
  if [[ ! -s "$final_file" || -L "$final_file" ]]; then
    rm -f -- "$final_file" 2>/dev/null || true
    return 1
  fi
  if [[ "${VW_HANDOFF_TEST_MODE:-false}" != "true" ]]; then
    [[ "$(stat -c '%U:%G' "$final_file" 2>/dev/null)" == "root:root" ]] || return 1
  fi
}

publish_setup_credentials() {
  (
    # Preserve the caller's xtrace state while ensuring generated values and
    # verification calls cannot be echoed by an inherited `set -x`.
    { set +x; } 2>/dev/null
    local age_key_file="$1" vw_plain_file="$2" vw_hash_file="$3"
  local caddy_plain_file="$4" caddy_hash_file="$5"
  [[ -s "$age_key_file" && -s "$vw_plain_file" && -s "$vw_hash_file" \
     && -s "$caddy_plain_file" && -s "$caddy_hash_file" ]] || return 1

  local private_identity public_recipient vw_plain vw_hash caddy_plain caddy_hash
  private_identity="$(cat "$age_key_file")" || return 1
  public_recipient="$(age-keygen -y "$age_key_file" 2>/dev/null)" || return 1
  vw_plain="$(cat "$vw_plain_file")" || return 1
  vw_hash="$(cat "$vw_hash_file")" || return 1
  caddy_plain="$(cat "$caddy_plain_file")" || return 1
  caddy_hash="$(cat "$caddy_hash_file")" || return 1
  caddy_hash="${caddy_hash#admin }"

  _setup_handoff_invalid_value "$private_identity" && return 1
  _setup_handoff_invalid_value "$public_recipient" && return 1
  _setup_handoff_invalid_value "$vw_plain" && return 1
  _setup_handoff_invalid_value "$caddy_plain" && return 1
  [[ "$public_recipient" =~ ^age1[a-z0-9]{58}$ ]] || return 1
  [[ "$private_identity" == *AGE-SECRET-KEY-1* ]] || return 1
  _setup_handoff_verify_argon2 "$vw_plain" "$vw_hash" || return 1
  _setup_handoff_verify_bcrypt "$caddy_hash" 3<<<"$caddy_plain" || return 1

  local target_dir="${SETUP_CREDENTIALS_DIR:-$_SETUP_CREDENTIALS_DEFAULT_DIR}"
  _setup_handoff_prepare_dir "$target_dir" || return 1
  local stamp final_file temp_file old_umask
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  final_file="${target_dir}/vaultwarden-setup-credentials-${stamp}.txt"
  [[ ! -e "$final_file" && ! -L "$final_file" ]] || return 1
  old_umask="$(umask)"
  umask 077
  temp_file="$(mktemp "${target_dir}/.vaultwarden-setup-credentials.XXXXXXXX")" || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"

  (
    local published=false
    cleanup_setup_handoff() {
      [[ "$published" == "true" ]] || rm -f -- "$temp_file"
    }
    trap cleanup_setup_handoff EXIT
    trap 'exit 130' INT
    trap 'exit 129' HUP
    trap 'exit 143' TERM
    cat > "$temp_file" <<EOF_SETUP_CREDENTIALS
╔══════════════════════════════════════════════════════════════════════════════╗
║                                                                              ║
║                       V A U L T W A R D E N  ·  O C I                        ║
║                                                                              ║
║                            SETUP CREDENTIALS                                 ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝

┌──────────────────────────────────────────────────────────────────────────────┐
│  01  SOPS AGE IDENTITY                                                       │
└──────────────────────────────────────────────────────────────────────────────┘

  PUBLIC RECIPIENT

    ${public_recipient}

  PRIVATE IDENTITY

${private_identity}

┌──────────────────────────────────────────────────────────────────────────────┐
│  02  VAULTWARDEN ADMIN                                                       │
└──────────────────────────────────────────────────────────────────────────────┘

  PASSWORD

    ${vw_plain}

┌──────────────────────────────────────────────────────────────────────────────┐
│  03  CADDY ADMIN                                                             │
└──────────────────────────────────────────────────────────────────────────────┘

  USERNAME

    admin

  PASSWORD

    ${caddy_plain}

╔══════════════════════════════════════════════════════════════════════════════╗
║                          END OF SETUP CREDENTIALS                             ║
╚══════════════════════════════════════════════════════════════════════════════╝
EOF_SETUP_CREDENTIALS
    [[ "$(grep -c '^│  0[123]  ' "$temp_file")" == "3" ]] || exit 1
    grep -Fqx '║                          END OF SETUP CREDENTIALS                             ║' "$temp_file" || exit 1
    _setup_handoff_publish_file "$temp_file" "$final_file" || exit 1
    published=true
  ) || return 1

    printf '%s\n' "$final_file"
  )
}

publish_age_rotation_handoff() {
  local age_key_file="$1" public_recipient="$2" generated_at="$3"
  [[ -s "$age_key_file" && "$public_recipient" =~ ^age1[a-z0-9]{58}$ ]] || return 1
  local derived
  derived="$(age-keygen -y "$age_key_file" 2>/dev/null)" || return 1
  [[ "$derived" == "$public_recipient" ]] || return 1
  local target_dir="${SETUP_CREDENTIALS_DIR:-$_SETUP_CREDENTIALS_DEFAULT_DIR}"
  _setup_handoff_prepare_dir "$target_dir" || return 1
  local final_file temp_file old_umask
  final_file="${target_dir}/vaultwarden-age-key-rotation-${generated_at}.txt"
  [[ ! -e "$final_file" && ! -L "$final_file" ]] || return 1
  old_umask="$(umask)"; umask 077
  temp_file="$(mktemp "${target_dir}/.vaultwarden-age-key-rotation.XXXXXXXX")" || {
    umask "$old_umask"; return 1;
  }
  umask "$old_umask"
  (
    local published=false
    trap '[[ "$published" == "true" ]] || rm -f -- "$temp_file"' EXIT
    trap 'exit 130' INT; trap 'exit 129' HUP; trap 'exit 143' TERM
    {
      printf 'VAULTWARDEN · OCI — AGE KEY ROTATION HANDOFF\n\n'
      printf 'PUBLIC RECIPIENT\n\n  %s\n\n' "$public_recipient"
      printf 'PRIVATE IDENTITY\n\n'
      cat "$age_key_file"
      printf '\nEND OF AGE KEY ROTATION HANDOFF\n'
    } > "$temp_file"
    _setup_handoff_publish_file "$temp_file" "$final_file" || exit 1
    published=true
  ) || return 1
  printf '%s\n' "$final_file"
}
