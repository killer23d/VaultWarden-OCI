#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    echo "usage: retry-command.sh ATTEMPTS INITIAL_DELAY_SECONDS COMMAND [ARG ...]" >&2
    exit 2
}

[[ $# -ge 3 ]] || usage

attempts="$1"
initial_delay="$2"
shift 2

[[ "$attempts" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$initial_delay" =~ ^[0-9]+$ ]] || usage
(( attempts <= 10 )) || {
    echo "retry-command.sh: ATTEMPTS must be <= 10" >&2
    exit 2
}

for ((attempt = 1; attempt <= attempts; attempt++)); do
    if "$@"; then
        exit 0
    else
        status=$?
    fi

    if (( attempt == attempts )); then
        echo "ERROR: command failed after ${attempts} attempt(s); exit=${status}" >&2
        exit "$status"
    fi

    delay=$((initial_delay * attempt))
    echo "WARN: command attempt ${attempt}/${attempts} failed with exit=${status}; retrying in ${delay}s" >&2
    sleep "$delay"
done
