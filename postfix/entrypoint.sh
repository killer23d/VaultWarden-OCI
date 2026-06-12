#!/bin/sh
# postfix/entrypoint.sh — Postfix spool pre-initialisation
#
# Purpose:
#   Run as root (UID 0) to chown /var/spool/postfix and /var/log/postfix
#   before dropping into the boky/postfix entrypoint. This allows CHOWN,
#   DAC_OVERRIDE, and FOWNER to be removed from the compose cap_add list —
#   those capabilities are only needed during this one-time setup phase, not
#   for the lifetime of the Postfix relay process.
#
# Security model:
#   This container starts as root, runs the chown block below, then exec's
#   into /docker-entrypoint.sh (the upstream boky/postfix entrypoint), which
#   itself drops to the `postfix` user via SETUID/SETGID before starting the
#   Postfix master process. The three broad caps (CHOWN, DAC_OVERRIDE, FOWNER)
#   are present only for the duration of this script — measured in
#   milliseconds — rather than the entire container lifetime.
#
# NOTE: POSIX sh only — boky/postfix is based on Alpine/Debian and may have
#   busybox sh. Do NOT use bash constructs (arrays, [[ ]], pipefail, etc.).
set -eu

echo "==================================================================="
echo " Postfix Entrypoint - Spool Pre-Initialisation"
echo "==================================================================="

# ---------------------------------------------------------------------------
# SMTP password secret — validate it is readable before Postfix starts so
# the error is clear rather than a silent authentication failure.
# ---------------------------------------------------------------------------
SMTP_SECRET_PATH="/run/secrets/smtp_password"

if [ ! -f "$SMTP_SECRET_PATH" ]; then
    echo "ERROR: Docker secret not found: $SMTP_SECRET_PATH" >&2
    echo "       Ensure smtp_password is declared in docker-compose.yml and" >&2
    echo "       the stack has been restarted after secrets setup." >&2
    exit 1
fi

if ! cat "$SMTP_SECRET_PATH" > /dev/null 2>&1; then
    echo "ERROR: Cannot read secret: $SMTP_SECRET_PATH" >&2
    echo "       Check that the secret file permissions are 0444 (world-readable)." >&2
    exit 1
fi
echo "SMTP password secret validated."

# ---------------------------------------------------------------------------
# Postfix spool and log directory ownership
#
# The boky/postfix image's own entrypoint does:
#   chown -R postfix:postfix /var/spool/postfix
#   chown root:postdrop /var/spool/postfix/public /var/spool/postfix/maildrop
# Those operations require CHOWN. We do them here, ONCE, then the caps are
# no longer exercised by any running process.
#
# /var/spool/postfix sub-directory ownership requirements (from Postfix docs):
#   postfix:postfix  — most spool dirs
#   root:postdrop    — public, maildrop (set-group-ID delivery)
# ---------------------------------------------------------------------------
echo "Pre-initialising Postfix spool directories..."

# Ensure the top-level spool tree exists.
mkdir -p \
    /var/spool/postfix/active \
    /var/spool/postfix/bounce \
    /var/spool/postfix/corrupt \
    /var/spool/postfix/defer \
    /var/spool/postfix/deferred \
    /var/spool/postfix/flush \
    /var/spool/postfix/hold \
    /var/spool/postfix/incoming \
    /var/spool/postfix/private \
    /var/spool/postfix/public \
    /var/spool/postfix/saved \
    /var/spool/postfix/trace \
    /var/spool/postfix/maildrop \
    /var/log/postfix

# Main spool tree: owned by postfix:postfix
chown -R postfix:postfix /var/spool/postfix
chmod 750 /var/spool/postfix

# Delivery sub-dirs require root:postdrop so the postdrop set-gid helper works
chown root:postdrop /var/spool/postfix/public /var/spool/postfix/maildrop
chmod 730 /var/spool/postfix/maildrop
chmod 710 /var/spool/postfix/public

# Log directory owned by postfix so the relay process can write without root
chown postfix:postfix /var/log/postfix
chmod 750 /var/log/postfix

echo "Spool pre-initialisation complete."

# ---------------------------------------------------------------------------
# Hand off to the upstream boky/postfix entrypoint.
#
# 'exec' replaces this shell process so the upstream script becomes PID 1's
# child and receives signals (SIGTERM, etc.) correctly. The upstream script
# will itself call SETUID/SETGID to drop from root to the postfix user before
# starting the Postfix master daemon.
# ---------------------------------------------------------------------------
echo "==================================================================="
echo " Handing off to upstream boky/postfix entrypoint"
echo "==================================================================="

exec /docker-entrypoint.sh "$@"