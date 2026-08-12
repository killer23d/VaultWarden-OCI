from pathlib import Path


def replace_function(path, name, body):
    p = Path(path)
    lines = p.read_text().splitlines(True)
    start = next(i for i, line in enumerate(lines) if line.startswith(name + '() {'))
    end = next(i for i in range(start + 1, len(lines)) if lines[i].rstrip('\n') == '}')
    lines[start:end + 1] = [body.rstrip() + '\n']
    p.write_text(''.join(lines))


replace_function('lib/secrets.sh', '_ork_generate_and_secure', r'''_ork_generate_and_secure() {
  # Render and validate plaintext only in a verified volatile workspace. The
  # persistent pathname is reserved using an empty same-directory stub; only
  # the intentional final recovery artifact ever contains plaintext on disk.
  local output_file="$1" output_dir sensitive_workspace temp_file publish_stub old_umask
  output_dir="$(dirname -- "$output_file")"
  [[ -d "$output_dir" && ! -L "$output_dir" ]] || return 1
  [[ ! -e "$output_file" && ! -L "$output_file" ]] || {
    log_error "Refusing to overwrite recovery kit: $output_file"
    return 1
  }

  sensitive_workspace="$(create_sensitive_workspace recovery-kit)" || return 1
  temp_file="${sensitive_workspace}/recovery-kit.txt"
  old_umask="$(umask)"; umask 077
  publish_stub="$(mktemp "${output_dir}/.vaultwarden-recovery-publish.XXXXXXXX")" || {
    umask "$old_umask"
    remove_sensitive_workspace "$sensitive_workspace" 2>/dev/null || true
    return 1
  }
  umask "$old_umask"
  chmod 0600 -- "$publish_stub" || {
    rm -f -- "$publish_stub"
    remove_sensitive_workspace "$sensitive_workspace" 2>/dev/null || true
    return 1
  }

  (
    local linked=false completed=false
    _ork_rollback_incomplete_publication() {
      [[ "$completed" == "true" ]] && return 0
      # The same-inode check closes the signal window after ln succeeds but
      # before linked=true. The disk-side stub is empty and never holds secrets.
      if [[ "$linked" == "true" ]] \
          || { [[ -e "$output_file" && -e "$publish_stub" ]] && [[ "$output_file" -ef "$publish_stub" ]]; }; then
        _remove_sensitive_file "$output_file" 2>/dev/null || true
      fi
      rm -f -- "$publish_stub" 2>/dev/null || true
      remove_sensitive_workspace "$sensitive_workspace" 2>/dev/null || true
    }
    trap _ork_rollback_incomplete_publication EXIT
    trap 'completed=false; exit 130' INT
    trap 'completed=false; exit 129' HUP
    trap 'completed=false; exit 143' TERM

    generate_recovery_kit "$temp_file" || exit 1
    [[ -s "$temp_file" ]] || exit 1
    grep -Fq 'END OF RECOVERY KIT' "$temp_file" || exit 1
    grep -Fq 'AGE-SECRET-KEY-1' "$temp_file" || exit 1
    chmod 0600 -- "$temp_file" || exit 1
    if (( EUID == 0 )); then
      chown root:root -- "$temp_file" || exit 1
    fi

    # Reserve the final path without placing plaintext in a persistent temp.
    ln -- "$publish_stub" "$output_file" || exit 1
    linked=true
    rm -f -- "$publish_stub" || exit 1
    cat -- "$temp_file" > "$output_file" || exit 1
    chmod 0600 -- "$output_file" || exit 1
    if (( EUID == 0 )); then
      chown root:root -- "$output_file" || exit 1
    fi
    cmp -s -- "$temp_file" "$output_file" || exit 1
    grep -Fq 'END OF RECOVERY KIT' "$output_file" || exit 1
    grep -Fq 'AGE-SECRET-KEY-1' "$output_file" || exit 1

    if ! remove_sensitive_workspace "$sensitive_workspace"; then
      log_error "Recovery-kit volatile plaintext cleanup failed; rolling back publication."
      exit 1
    fi
    if ! _schedule_recovery_cleanup "$output_file" "30m"; then
      log_error "Recovery-kit cleanup could not be scheduled; rolling back published plaintext."
      exit 1
    fi
    completed=true
  ) || return 1
  return 0
}''')

# The main candidate already moves the runtime-decryption cache under the
# shared volatile helper. Assert both equivalent plaintext workspaces here.
p = Path('tests/suites/security/case-secrets.bash')
t = p.read_text()
anchor = 'grep -Fq \'_check_editor_forks || return 1\' utilities/secrets-edit.sh || fail "known forking editor refusal is not enforced"\n'
if anchor not in t:
    raise SystemExit('sensitive cleanup assertion anchor missing')
checks = '''grep -Fq 'create_sensitive_workspace recovery-kit' lib/secrets.sh || fail "recovery-kit temporary plaintext is not volatile"\ngrep -Fq 'create_sensitive_workspace runtime-secrets' lib/secrets.sh || fail "runtime secret export staging is not volatile"\n! grep -Fq 'mktemp -d -t vaultwarden-secrets.' lib/secrets.sh || fail "runtime secret export still stages plaintext in generic tmp"\n! grep -Fq 'mktemp "${output_dir}/.vaultwarden-recovery-kit.' lib/secrets.sh || fail "recovery kit still stages plaintext beside its persistent output"\n'''
t = t.replace(anchor, checks + anchor, 1)

# Recovery publication still exercises the same unlink and signal rollback
# windows, but the same-directory artifact is now an empty publish stub rather
# than a plaintext staging file. Retarget only those dot-file fixture patterns.
t = t.replace("*'.vaultwarden-recovery-kit.'*", "*'.vaultwarden-recovery-publish.'*", 1)
t = t.replace("-name '.vaultwarden-recovery-kit.*'", "-name '.vaultwarden-recovery-publish.*'")
p.write_text(t)
