# **VaultWarden-OCI — Permissions, Lock Files, Unbound Variables & Sudo Hygiene Agent Prompt**

## **Repository**

* **Repo:** killer23d/VaultWarden-OCI  
* **Branch:** Beta  
* **Root:** /home/ubuntu/VaultWarden-OCI

## **Context & Goals**

This repository is a self-hosted VaultWarden deployment on OCI Ubuntu. The operator is a junior/solo admin — the design philosophy is set-and-forget with auto-remedy: scripts must fix what they can automatically, fail loudly with actionable guidance when they cannot, and never silently corrupt state.  
You are performing a complete, file-by-file audit and remediation of this repository. The specific files and errors listed in this prompt are confirmed examples of broader patterns — they are not the full scope. You must read every file in the repository and apply the same analysis and fixes to any file that exhibits the same class of problem, regardless of whether it is named here.  
If you find a better, more robust, or more idiomatic solution than the one described, use the superior approach. The goal is best-practice correctness and long-term maintainability, not literal transcription of the patterns described. The one binding constraint is behavioral consistency: all scripts in this project must handle the same class of problem the same way.  
The operator is a junior/solo admin on an OCI Ubuntu server. The design contract is set-and-forget with auto-remedy: scripts must silently self-heal what they safely can, emit clear human-readable diagnostics for everything they change or cannot fix, and never leave the system in a worse state than they found it.

## **Problem 1 — Permissions: Root Cause Analysis & Required Fixes**

### **1a. Lock files in /run/lock are inaccessible under some invocation paths**

* **Symptom:**  
  Plaintext  
  /home/ubuntu/VaultWarden-OCI/utilities/backup-run.sh: line 1166: /run/lock/vaultwarden-operations.lock: Permission denied

* **Root cause:** The first time backup-run.sh is run in a fresh session (or after a reboot), /run/lock/vaultwarden-operations.lock may not yet exist. The script does touch "$OPS\_LOCK" followed immediately by chmod 0660 "$OPS\_LOCK". If the calling user is ubuntu running via sudo, /run/lock/ is owned root:root with mode 1777 on Ubuntu — so touch succeeds but the resulting file is owned root:root 0660, not ubuntu:ubuntu 0660\. A subsequent non-sudo run (or a systemd unit running as ubuntu) then cannot open the file for writing.  
* **Required fix for utilities/backup-run.sh (lines \~1159–1180):**  
  Bash  
  \# BEFORE (problematic):  
  touch "$OPS\_LOCK"  
  chmod 0660 "$OPS\_LOCK"  
  exec {OPS\_LOCK\_FD}\>"$OPS\_LOCK"

  \# AFTER (correct):  
  \# Ensure lock files are owned by the service user with group-write.  
  \# This is idempotent — safe to call on every run.  
  \_ensure\_lock\_file() {  
      local lockpath="$1"  
      if \[\[ \! \-f "$lockpath" \]\]; then  
          touch "$lockpath"  
      fi  
      \# Correct ownership to the invoking real user (not sudo root)  
      local real\_user="${SUDO\_USER:-$USER}"  
      local real\_group  
      real\_group=$(id \-gn "$real\_user")  
      local current\_owner  
      current\_owner=$(stat \-c '%U' "$lockpath")  
      if \[\[ "$current\_owner" \!= "$real\_user" \]\]; then  
          log\_warn "Lock file $lockpath owned by '$current\_owner', correcting to '$real\_user:$real\_group'"  
          chown "${real\_user}:${real\_group}" "$lockpath"  
      fi  
      chmod 0660 "$lockpath"  
  }

  \_ensure\_lock\_file "$OPS\_LOCK"  
  exec {OPS\_LOCK\_FD}\>"$OPS\_LOCK"

* **Action:** Apply \_ensure\_lock\_file to every lock path in the project:  
  * /run/lock/vaultwarden-operations.lock (backup-run.sh)  
  * /run/lock/vaultwarden-backup.lock (backup-run.sh)  
  * /run/lock/vaultwarden-setup.lock (setup.sh)  
* Move \_ensure\_lock\_file into lib/common.sh and export it so all scripts share one canonical implementation.

### **1b. rclone.conf becomes owned by root after sudo rclone config**

* **Symptom:**  
  Plaintext  
  rclone config  
  2026/05/29 06:02:40 Failed to load config file "/home/ubuntu/.config/rclone/rclone.conf": permission denied  
  \# Owner is root:ubuntu 0600 — ubuntu cannot read it

* **Root cause:** sudo rclone config writes/modifies /home/ubuntu/.config/rclone/rclone.conf as root. The fix the user applied manually (sudo chown ubuntu: ...) is the correct remedy but should be automated.  
* **Required fix in setup.sh and in the rclone-related code paths (search all scripts for rclone config invocations):**  
  Add a \_fix\_rclone\_ownership function to lib/common.sh:  
  Bash  
  \_fix\_rclone\_ownership() {  
      local real\_user="${SUDO\_USER:-$USER}"  
      local rclone\_conf="${HOME}/.config/rclone/rclone.conf"  
      \# When running under sudo, HOME may be /root — resolve the actual user home  
      if \[\[ \-n "${SUDO\_USER:-}" \]\]; then  
          rclone\_conf=$(eval echo "\~${SUDO\_USER}/.config/rclone/rclone.conf")  
      fi  
      if \[\[ \-f "$rclone\_conf" \]\]; then  
          local owner  
          owner=$(stat \-c '%U' "$rclone\_conf")  
          if \[\[ "$owner" \!= "$real\_user" \]\]; then  
              log\_warn "rclone.conf owned by '$owner' — correcting to '$real\_user'"  
              chown "${real\_user}:$(id \-gn "$real\_user")" "$rclone\_conf"  
              log\_ok "rclone.conf ownership corrected: $rclone\_conf"  
          fi  
      fi  
  }

* Call \_fix\_rclone\_ownership at the end of every code path that invokes or configures rclone, and as a preflight check at the start of backup-run.sh's rclone sync path.

### **1c. Audit all chmod/chown calls across the entire codebase**

* **Action:** Scan every .sh file (root-level, utilities/, lib/), every systemd/\*.service and systemd/\*.timer, and the Makefile for chmod, chown, install \-m, and umask calls. For each occurrence:  
  * Verify the call is necessary. If the file was just created by the same script and ownership is already correct, remove redundant chown.  
  * Verify the target path is what's intended. Never chmod/chown a file relative to $HOME when running under sudo (since $HOME becomes /root).  
  * Add a before/after log line for every ownership or permission change so the admin can see what changed:  
    Bash  
    log\_info "Setting $path to mode 0600 (was: $(stat \-c '%a' "$path" 2\>/dev/null || echo 'new'))"  
    chmod 0600 "$path"

### **1d. systemd units — permission expectations**

* **Action:** Audit all systemd/\*.service files for:  
  * User= and Group= directives — they must match the actual runtime user (ubuntu or vaultwarden)  
  * ExecStartPre= steps that call chmod/chown — confirm they run as the correct user or under the correct capability  
  * Any unit that calls a script passing files owned by ubuntu but running as another user  
* For each unit, add RuntimeDirectory=vaultwarden and RuntimeDirectoryMode=0750 so systemd pre-creates /run/vaultwarden/ with correct ownership, eliminating the /run/lock permission problem entirely for timer-driven runs. Update lock paths in scripts to prefer /run/vaultwarden/\*.lock when the RUNTIME\_DIR env var is set by systemd.

## **Problem 2 — Unbound Variables: AGE\_KEY\_FILE and related**

* **Symptom:**  
  Plaintext  
  /home/ubuntu/VaultWarden-OCI/utilities/secrets-list.sh: line 74: AGE\_KEY\_FILE: unbound variable  
  /home/ubuntu/VaultWarden-OCI/utilities/secrets-export-recovery-kit.sh: line 49: AGE\_KEY\_FILE: unbound variable

* **Root cause:** Both scripts have set \-euo pipefail at the top (line 5). They source lib/config.sh, lib/common.sh, and then lib/secrets.sh. AGE\_KEY\_FILE is referenced in check\_prerequisites() before it is defined. lib/config.sh does not export AGE\_KEY\_FILE with a default — it only sets it when .env is loaded and the key exists in the file. When .env is missing or the variable is absent, AGE\_KEY\_FILE is never set, and \-u (nounset) causes an immediate abort with "unbound variable".  
* **Required fix in lib/config.sh:**  
  Bash  
  \# After load\_env\_file / source of .env, add a canonical default block.  
  \# Use ${VAR:-default} pattern to provide a fallback without breaking \-u.  
  AGE\_KEY\_FILE="${AGE\_KEY\_FILE:-/etc/vaultwarden/age-key.txt}"  
  SECRETS\_FILE="${SECRETS\_FILE:-${PROJECT\_ROOT}/secrets.yaml}"  
  SOPS\_AGE\_KEY\_FILE="${SOPS\_AGE\_KEY\_FILE:-${AGE\_KEY\_FILE}}"  
  export AGE\_KEY\_FILE SECRETS\_FILE SOPS\_AGE\_KEY\_FILE

  *Note: export \-f is not needed for variables (only functions), but they must be exported so sub-shells and sourced scripts see them.*  
* **Required fix in every script's check\_prerequisites() function:**  
  Replace bare $AGE\_KEY\_FILE references with ${AGE\_KEY\_FILE:-/etc/vaultwarden/age-key.txt} as a belt-and-suspenders guard:  
  Bash  
  check\_prerequisites() {  
      local age\_key="${AGE\_KEY\_FILE:-/etc/vaultwarden/age-key.txt}"  
      local secrets="${SECRETS\_FILE:-${PROJECT\_ROOT}/secrets.yaml}"  
      local missing=()

      \[\[ \! \-f "$age\_key" \]\] && missing+=("Age encryption key: $age\_key")  
      \[\[ \! \-f ".sops.yaml" \]\] && missing+=("SOPS configuration: .sops.yaml")  
      \[\[ \! \-f "$secrets" \]\] && missing+=("Secrets file: $secrets")

      if \[\[ ${\#missing\[@\]} \-gt 0 \]\]; then  
          log\_error "Missing prerequisites:"  
          for item in "${missing\[@\]}"; do log\_error "  \- $item"; done  
          log\_info "To create secrets, run: ./setup.sh secrets"  
          return 1  
      fi  
      return 0  
  }

* **Search scope:** Apply this fix to:  
  * utilities/secrets-list.sh  
  * utilities/secrets-export-recovery-kit.sh  
  * Any other utility that references $AGE\_KEY\_FILE, $SECRETS\_FILE, or $SOPS\_AGE\_KEY\_FILE without a prior guaranteed assignment (grep the entire codebase: grep \-rn 'AGE\_KEY\_FILE\\|SECRETS\_FILE\\|SOPS\_AGE\_KEY\_FILE' \--include='\*.sh')

## **Problem 3 — Unnecessary sudo Usage**

* **Symptom:**  
  * sudo rclone config creates root-owned rclone.conf  
  * sudo ./backup.sh run full \--rclone opens lock files as root, which then cannot be accessed by the service user  
  * Potentially other scripts are invoked with sudo when they only need elevated access for specific sub-operations

### **3a. Add sudo necessity guards to every entry-point script**

At the top of each script (after the shebang, before sourcing libs), add a \_check\_sudo\_requirement guard:

Bash  
\# Only operations that write to /etc, /run/lock, or call Docker need root.  
\# All read-only subcommands must work without sudo.  
\_check\_sudo\_requirement() {  
    local cmd="${1:-}"  
    local readonly\_cmds=("list" "help" "--help" "-h" "verify")  
    for ro in "${readonly\_cmds\[@\]}"; do  
        if \[\[ "$cmd" \== "$ro" \]\]; then  
            if \[\[ "$EUID" \-eq 0 \]\]; then  
                log\_warn "This subcommand ('$cmd') does not require root. Run without sudo:"  
                log\_warn "  ./${0\#\#\*/} $cmd"  
                log\_warn "Continuing anyway, but file ownership may be affected."  
            fi  
            return 0  
        fi  
    done  
}

### **3b. Protect rclone invocations from being called under sudo**

In every script that calls rclone, add a guard:

Bash  
\_run\_rclone() {  
    if \[\[ "$EUID" \-eq 0 && \-n "${SUDO\_USER:-}" \]\]; then  
        \# Drop to the real user to keep rclone.conf ownership clean  
        log\_warn "rclone called as root — dropping to user '${SUDO\_USER}' to avoid config ownership drift"  
        sudo \-u "${SUDO\_USER}" rclone "$@"  
    else  
        rclone "$@"  
    fi  
}

* Replace all bare rclone calls in backup scripts with \_run\_rclone.  
* Move \_run\_rclone into lib/common.sh and export it.

### **3c. Use sudo \-E where environment pass-through is needed**

Any legitimate sudo path must use sudo \-E (preserve environment) or explicitly pass variables like SOPS\_AGE\_KEY\_FILE to avoid the script being surprised by a clean root environment. Document this in the script header comment.

## **Problem 4 — Lock File Logic Is Broken for the Current User Model**

Current logic flaw in backup-run.sh lines 1159–1180:

Bash  
touch "$OPS\_LOCK"  
chmod 0660 "$OPS\_LOCK"  
exec {OPS\_LOCK\_FD}\>"$OPS\_LOCK"  
if \! flock \-n "$OPS\_LOCK\_FD"; then ...

If the script fails between touch and flock, the lock file exists but is not held. On re-run, flock \-n will succeed (no process holds it), which is correct — but only if the ownership is right. The real issue is the missing \_ensure\_lock\_file check.  
Additionally: LOCK\_FILE="" is initialized at script scope (line 163), which is correct for cleanup. But the cleanup function checks \[\[ \-n "${LOCK\_FILE:-}" \]\] — the :- is redundant here since LOCK\_FILE is already declared. This pattern is fine but verify the \-u guard is consistent everywhere — either always use ${VAR:-} for optionals, or declare all expected globals with declare \-g at the top.

### **Required additional lock fix — systemd RuntimeDirectory:**

In each .service file that runs backup or maintenance scripts, add:

Plaintext  
\[Service\]  
RuntimeDirectory=vaultwarden  
RuntimeDirectoryMode=0750  
RuntimeDirectoryPreserve=yes

This makes systemd create and own /run/vaultwarden/ with correct ownership before the script runs, completely bypassing the /run/lock permission issue for timer-driven invocations. Update scripts to use /run/vaultwarden/backup.lock when RUNTIME\_DIRECTORY env var is set (systemd sets this automatically), falling back to /run/lock/vaultwarden-backup.lock for manual runs.

Bash  
LOCK\_DIR="${RUNTIME\_DIRECTORY:-/run/lock}"  
LOCK\_FILE="${LOCK\_DIR}/vaultwarden-backup.lock"  
OPS\_LOCK="${LOCK\_DIR}/vaultwarden-operations.lock"

## **Acceptance Criteria**

After applying all fixes, the following must hold:

| Test | Expected Result |
| :---- | :---- |
| sudo ./backup.sh run full \--rclone | No "Permission denied" on lock files. Lock files owned by ubuntu. |
| ./backup.sh list | Works without sudo, emits a warning if accidentally called with sudo. |
| sudo ./edit-secrets.sh list | No "AGE\_KEY\_FILE: unbound variable". Prints key list or clear "missing prerequisites" message. |
| sudo ./edit-secrets.sh export-recovery-kit | No unbound variable abort. Either succeeds or prints actionable error. |
| rclone config (after a sudo backup run) | \~ubuntu/.config/rclone/rclone.conf is owned by ubuntu, not root. |
| Systemd timer fires vaultwarden-full-backup.service | Lock files are created in /run/vaultwarden/ by systemd, no permission error. |
| Re-run after partial failure | Idempotent — no stale lock, no double-chmod, clean state. |
| Junior admin runs a broken command | Gets a clear human-readable explanation of what is wrong and the exact command to fix it. |

## **Files to Scan and Modify**

You must read and audit every file below before making any changes. This is not a minimum scope — it is the full scope. Apply the same fixes to any additional files you discover during your sweep.

### **Entry-point scripts (root level)**

backup.sh, restore.sh, setup.sh, startup.sh, maintenance.sh, dashboard.sh, edit-secrets.sh

### **Library files (lib/)**

lib/log.sh, lib/config.sh, lib/defaults.sh, lib/common.sh, lib/crypto.sh, lib/secrets.sh, lib/docker.sh, lib/email.sh, lib/storage.sh, lib/backup-utils.sh, lib/maintenance-utils.sh, lib/validate.sh

### **Utility scripts (utilities/)**

All .sh files in this directory — including but not limited to: backup-run.sh, restore-run.sh, maintenance-run.sh, maintenance-health.sh, maintenance-update.sh, maintenance-update-dns.sh, maintenance-update-firewall.sh, maintenance-db-maint.sh, maintenance-email.sh, secrets-edit.sh, secrets-list.sh, secrets-export-recovery-kit.sh, secrets-rotate.sh, secrets-view.sh, setup-env.sh, setup-secrets.sh, setup-storage.sh, setup-system.sh, setup-systemd.sh, setup-firewall.sh, setup-crowdsec.sh, pre-production-drill.sh, smoke-test.sh, uninstall-vaultwarden.sh, write-command-reference.sh

### **systemd units (systemd/)**

All .service and .timer files.

### **Other**

Makefile — audit for chmod/chown calls and sudo usage.

### **Discovery commands**

Run these first and treat the output as your work list:

Bash  
grep \-rn 'chmod\\|chown\\|install \-m\\|umask' \--include='\*.sh' .  
grep \-rn 'AGE\_KEY\_FILE\\|SOPS\_AGE\_KEY\_FILE\\|SECRETS\_FILE' \--include='\*.sh' .  
grep \-rn 'flock\\|\\.lock\\|LOCK\_FILE\\|OPS\_LOCK' \--include='\*.sh' .  
grep \-rn '\\bsudo\\b\\|EUID' \--include='\*.sh' . | grep \-v '^\\s\*\#'  
grep \-rn 'chmod\\|chown\\|User=\\|Group=' systemd/

## **Implementation Order**

\[\!NOTE\]  
Before touching any file: read lib/log.sh for the logging API, lib/defaults.sh to understand the existing readonly \_VW\_DEFAULT\_\* convention and idempotency guard, lib/config.sh for the .env loading lifecycle, and lib/common.sh for what shared helpers already exist. Do not duplicate a helper that already exists. When adding new canonical defaults, follow the lib/defaults.sh convention — it is the single source of truth for default values in this project.

1. **lib/config.sh** — Add variable defaults. This unblocks all unbound variable failures.  
2. **lib/common.sh** — Add \_ensure\_lock\_file, \_run\_rclone, \_fix\_rclone\_ownership, \_check\_sudo\_requirement. Export all.  
3. **utilities/secrets-list.sh \+ utilities/secrets-export-recovery-kit.sh** — Update check\_prerequisites().  
4. **utilities/backup-run.sh** — Replace lock creation with \_ensure\_lock\_file; use \_run\_rclone; add LOCK\_DIR from RUNTIME\_DIRECTORY.  
5. **setup.sh** — Add \_fix\_rclone\_ownership; use \_ensure\_lock\_file for setup lock.  
6. **systemd/\*.service** — Add RuntimeDirectory directives to all backup/maintenance/startup services.  
7. **Full grep sweep** — Catch any remaining AGE\_KEY\_FILE, chmod/chown, and rclone call not covered above.  
8. **Test matrix** — Verify all acceptance criteria above.

## **Constraints**

* Do not change the public API of any entry-point script (argument names, subcommand names, exit codes).  
* Do not remove the existing set \-euo pipefail from any script — the fix must work with strict mode, not by disabling it.  
* Do not change .env structure or add required new .env keys — all new defaults must be compile-time fallbacks in the scripts.  
* All new diagnostic log lines must use the existing log\_warn / log\_info / log\_ok / log\_error functions from lib/log.sh.  
* The fix for rclone.conf ownership must be backward-compatible — if already owned by the correct user, the function must be a silent no-op.  
* Prefer the superior method. If a better, more idiomatic, or more robust approach exists than what is described here, use it — as long as the external behavior (subcommand names, exit codes, log output format) does not change.  
* lib/defaults.sh is the single source of truth for default values. Follow its existing readonly \_VW\_DEFAULT\_\* pattern when adding new defaults, unless that pattern is genuinely incompatible with the variable's lifecycle (e.g., it needs to be reassigned after .env is loaded).