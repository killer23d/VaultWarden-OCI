#!/usr/bin/env bash
# setup.sh - VaultWarden-OCI Setup Script

set -euo pipefail

# =============================================================================
# DEPENDENCY VERSION PINS
# To pin a specific version, set the variable. Leave blank ("") to auto-resolve
# the latest release at runtime via the GitHub API.
#
# Examples:
#   SOPS_VERSION="v3.9.4"   <- pinned
#   SOPS_VERSION=""         <- auto-resolve latest (default)
#
# You may also override any of these from the environment before running:
#   SOPS_VERSION=v3.9.4 sudo ./setup.sh --domain ...
# =============================================================================
SOPS_VERSION="${SOPS_VERSION:-}"   # e.g. "v3.9.4" — leave blank for latest
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

old_umask=$(umask)
umask 077
TMP_WORKDIR=$(mktemp -d -t vw_setup.XXXXXXXXXX) || {
    echo "ERROR: Failed to create secure temporary directory" >&2
    exit 1
}
umask "$old_umask"
trap 'rm -rf "$TMP_WORKDIR"' EXIT

REQUIRED_LIBS=("lib/common.sh" "lib/crypto.sh" "lib/docker.sh" "lib/backup-utils.sh" "lib/secrets.sh" "lib/storage.sh")
for lib in "${REQUIRED_LIBS[@]}"; do
    if [[ ! -f "$lib" ]]; then
        echo "ERROR: Required library not found: $lib" >&2
        exit 1
    fi
done

source "lib/common.sh"
init_common_lib "$0"
source "lib/crypto.sh"
source "lib/docker.sh"
source "lib/storage.sh"

DOMAIN=""
ADMIN_EMAIL=""
AUTO_MODE=false
USE_LATEST=false
SKIP_DEPS=false
FORCE=false
DRY_RUN=false
PHASE=""
PHASE_ARGS=()
ENTROPY_THRESHOLD=200
ENTROPY_MAX_WAIT=60
CLEAN_DOMAIN=""
# Storage mode variables (defaults; overridden by --data-device/--data-mount
# CLI flags or by DATA_VOLUME_DEVICE/DATA_VOLUME_MOUNT already set in the
# calling environment).
DATA_VOLUME_DEVICE="${DATA_VOLUME_DEVICE:-}"
DATA_VOLUME_MOUNT="${DATA_VOLUME_MOUNT:-/mnt/vw-data}"

show_help() {
    cat << 'EOF'
VaultWarden-OCI Setup Tool - Security Hardened Edition
USAGE: sudo ./setup.sh --domain DOMAIN --email EMAIL [OPTIONS]

OPTIONS:
  --auto              Non-interactive install. Auto-generates passwords/passphrases;
                      external credentials (CF tokens, SMTP) remain as CHANGE_ME
                      placeholders — the post-install summary lists exact commands
                      to rotate them. Does NOT imply --use-latest.
  --use-latest        Override pinned container versions with 'latest' tags in .env.
  --skip-deps         Skip dependency installation (assumes already installed).
  --force             Overwrite existing .env, secrets, and docker-compose files.
                      WARNING: Also regenerates the Age encryption key. All
                      existing encrypted secrets become permanently unrecoverable
                      without a prior recovery kit export. Run
                      './edit-secrets.sh --export-recovery-kit' BEFORE using
                      --force on a running installation.
  --dry-run           Print what would happen without making any changes.
  --data-device DEV   Use DEV as the dedicated VaultWarden data volume.
                      The device is formatted (ext4, first run only) and
                      mounted at DATA_VOLUME_MOUNT. A Docker systemd drop-in
                      ensures the stack never starts without this mount.
                      Example: --data-device /dev/sdb
  --data-mount PATH   Mount point for the data volume (default: /mnt/vw-data).
                      Must match PROJECT_STATE_DIR when DATA_VOLUME_DEVICE is set.
  --phase=secrets     Run ONLY the secrets configuration phase
  --phase=systemd     Run ONLY the systemd installation phase
  --help              Show this help and exit.
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)       DOMAIN="$2";              shift 2 ;;
        --email)        ADMIN_EMAIL="$2";         shift 2 ;;
        --auto)         AUTO_MODE=true;            shift ;;
        --use-latest)   USE_LATEST=true;           shift ;;
        --skip-deps)    SKIP_DEPS=true;            shift ;;
        --force)        FORCE=true;                shift ;;
        --dry-run)      DRY_RUN=true;              shift ;;
        --data-device)  DATA_VOLUME_DEVICE="$2";   shift 2 ;;
        --data-mount)   DATA_VOLUME_MOUNT="$2";    shift 2 ;;
        --phase=secrets) PHASE="secrets"; shift; PHASE_ARGS=("$@"); break ;;
        --phase=systemd) PHASE="systemd"; shift; PHASE_ARGS=("$@"); break ;;
        --help)         show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

validate_domain_secure() {
    local domain="$1"
    if [[ ${#domain} -gt 253 ]]; then return 1; fi
    if [[ "$domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then return 1; fi
    if [[ ! "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then return 1; fi
    return 0
}

validate_email_secure() {
    local email="$1"
    if [[ ${#email} -gt 254 ]]; then return 1; fi
    if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then return 1; fi
    return 0
}

if [[ -z "$PHASE" ]] && ([[ -z "$DOMAIN" ]] || [[ -z "$ADMIN_EMAIL" ]]); then show_help; exit 1; fi
if [[ -z "$PHASE" ]] && ! validate_domain_secure "$DOMAIN"; then log_error "Invalid domain format"; exit 1; fi
if [[ -z "$PHASE" ]] && ! validate_email_secure "$ADMIN_EMAIL"; then log_error "Invalid email format"; exit 1; fi

resolve_github_latest() {
    local repo="$1"
    local tag
    local api_response

    # Use a temp file so curl errors are not silently swallowed by the pipe.
    local api_tmpfile
    api_tmpfile=$(mktemp -p "$TMP_WORKDIR" gh-latest.XXXXXXXXXX.json)

    if ! curl -fsSL --max-time 30 \
            "https://api.github.com/repos/${repo}/releases/latest" \
            -o "$api_tmpfile" 2>/dev/null; then
        log_error "Could not fetch release info for ${repo} from GitHub API."
        log_error "Set SOPS_VERSION=vX.Y.Z at the top of setup.sh to bypass."
        return 1
    fi

    tag=$(jq -r '.tag_name // empty' "$api_tmpfile")

    if [[ -z "$tag" ]] || [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9] ]]; then
        log_error "Could not resolve a valid release tag for ${repo}."
        log_error "Set SOPS_VERSION=vX.Y.Z at the top of setup.sh to bypass."
        return 1
    fi

    echo "$tag"
}

install_docker() {
    # Skip if Docker is already functional
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        log_info "setup" "Docker already installed: $(docker --version)"
        return 0
    fi

    local codename arch keyfile sources_file
    codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    arch=$(dpkg --print-architecture)
    keyfile="/etc/apt/keyrings/docker.asc"
    sources_file="/etc/apt/sources.list.d/docker.sources"

    log_info "setup" "Installing Docker via official apt repository (${codename} codename)..."

    install -m 0755 -d /etc/apt/keyrings

    rm -f /etc/apt/sources.list.d/docker.list
    rm -f /etc/apt/keyrings/docker.gpg

    if ! curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" -o "${keyfile}"; then
        log_error "setup" "Failed to download Docker GPG key"
        return 1
    fi
    chmod a+r "${keyfile}"

    local dearmored_key
    dearmored_key=$(mktemp -p "$TMP_WORKDIR" docker-key.XXXXXXXXXX.gpg)
    if ! gpg --dearmor < "${keyfile}" > "${dearmored_key}" 2>/dev/null; then
        log_error "setup" "Failed to dearmor Docker GPG key"
        rm -f "${dearmored_key}"
        return 1
    fi

    local got_fp
    got_fp=$(gpg --no-default-keyring \
        --keyring "gnupg-ring:${dearmored_key}" \
        --with-colons --fingerprint 2>/dev/null \
        | awk -F: '/^fpr/{print $10; exit}')
    rm -f "${dearmored_key}"

    local want_fp="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
    if [[ "${got_fp}" != "${want_fp}" ]]; then
        log_error "setup" "Docker GPG key fingerprint mismatch: got ${got_fp}, want ${want_fp}"
        return 1
    fi
    log_success "setup" "Docker GPG key fingerprint verified: ${want_fp}"

    cat > "${sources_file}" <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${codename}
Components: stable
Architectures: ${arch}
Signed-By: ${keyfile}
EOF

    if ! apt-get update; then
        log_error "setup" "apt-get update failed after adding Docker repo"
        return 1
    fi

    if ! apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin; then
        log_error "setup" "Docker package installation failed"
        return 1
    fi

    systemctl enable --now docker
    log_success "setup" "Docker installed: $(docker --version)"
}

check_disk_space() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would check disk space"; return 0; fi

    local min_free_kb=$((2 * 1024 * 1024))   # 2 GiB in KiB
    local available_kb
    available_kb=$(df -k "$PROJECT_ROOT" | awk 'NR==2 {print $4}')

    if (( available_kb < min_free_kb )); then
        log_error "Insufficient disk space on $PROJECT_ROOT. Required: 2 GiB, Available: $(( available_kb / 1024 )) MiB"
        return 1
    fi
    log_info "Disk space OK on $PROJECT_ROOT: $(( available_kb / 1024 )) MiB available"

    local docker_root="/var/lib/docker"
    if [[ -d "$docker_root" ]]; then
        local docker_available_kb
        docker_available_kb=$(df -k "$docker_root" | awk 'NR==2 {print $4}')
        if (( docker_available_kb < min_free_kb )); then
            log_error "Insufficient disk space on $docker_root. Required: 2 GiB, Available: $(( docker_available_kb / 1024 )) MiB"
            return 1
        fi
        log_info "Disk space OK on $docker_root: $(( docker_available_kb / 1024 )) MiB available"
    else
        log_info "/var/lib/docker does not exist yet — skipping Docker data-root space check"
    fi

    return 0
}

create_swapfile() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would create swapfile if needed"; return 0; fi

    if swapon --show | grep -q .; then
        log_info "Swap already active — skipping swapfile creation"
        return 0
    fi

    local swapfile="/swapfile"
    log_info "No swap detected — creating 1 GiB swapfile at ${swapfile}..."

    fallocate -l 1G "$swapfile" || dd if=/dev/zero of="$swapfile" bs=1M count=1024 status=none || return 1
    chmod 600 "$swapfile"
    mkswap "$swapfile" >/dev/null || return 1
    swapon "$swapfile" || return 1

    if ! grep -q "^${swapfile}" /etc/fstab 2>/dev/null; then
        echo "${swapfile} none swap sw 0 0" >> /etc/fstab
    fi

    sysctl -q vm.swappiness=10 || true
    if ! grep -q "^vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
        echo "vm.swappiness=10" >> /etc/sysctl.conf
    fi

    log_success "Swapfile created and activated (1 GiB)"
    return 0
}

install_dependencies() {
    if [[ "$SKIP_DEPS" == "true" ]]; then return 0; fi
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would install dependencies"; return 0; fi

    log_info "Installing system dependencies..."

    if ! grep -qE '^deb[[:space:]].*universe' \
            /etc/apt/sources.list \
            /etc/apt/sources.list.d/*.list 2>/dev/null && \
       ! grep -qE '^Components:.*\buniverse\b' \
            /etc/apt/sources.list.d/*.sources 2>/dev/null; then
        log_info "Enabling Ubuntu 'universe' repository (required for python3-argon2)..."
        if command -v add-apt-repository >/dev/null 2>&1; then
            add-apt-repository -y universe 2>/dev/null || {
                log_warn "add-apt-repository failed — adding universe source manually"
                local arch; arch=$(dpkg --print-architecture)
                local archive_url
                local codename
                codename=$(lsb_release -cs 2>/dev/null || echo "noble")
                if [[ "$arch" == "arm64" || "$arch" == "armhf" ]]; then
                    archive_url="http://ports.ubuntu.com/ubuntu-ports"
                else
                    archive_url="http://archive.ubuntu.com/ubuntu"
                fi
                echo "deb ${archive_url} ${codename} universe" \
                    > /etc/apt/sources.list.d/ubuntu-universe.list
                apt-get update -qq || return 1
            }
        else
            local arch; arch=$(dpkg --print-architecture)
            local archive_url
            local codename
            codename=$(lsb_release -cs 2>/dev/null || echo "noble")
            if [[ "$arch" == "arm64" || "$arch" == "armhf" ]]; then
                archive_url="http://ports.ubuntu.com/ubuntu-ports"
            else
                archive_url="http://archive.ubuntu.com/ubuntu"
            fi
            echo "deb ${archive_url} ${codename} universe" \
                > /etc/apt/sources.list.d/ubuntu-universe.list
            apt-get update -qq || return 1
        fi
        log_success "Universe repository enabled"
    fi

    local basic_packages=("age" "make" "nano" "rclone" "sqlite3" "jq" "ufw" "curl" "wget" "unzip" "git" "gpg" "coreutils" "haveged" "dnsutils" "rsync" "python3" "python3-argon2" "apache2-utils" "cron")
    local missing_packages=()
    for pkg in "${basic_packages[@]}"; do
        ! dpkg -s "$pkg" >/dev/null 2>&1 && missing_packages+=("$pkg")
    done

    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        apt-get update -qq || return 1
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}" || return 1
    fi

    if ! systemctl is-active --quiet haveged; then
        systemctl enable haveged 2>/dev/null || true
        systemctl start haveged || log_warn "Failed to start haveged"
    fi

    if ! command -v docker >/dev/null 2>&1; then
        install_docker || return 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin || return 1
    fi

    if ! command -v sops >/dev/null 2>&1; then
        local arch; arch=$(dpkg --print-architecture)
        [[ "$arch" == "armhf" ]] && arch="arm"

        local sops_ver="${SOPS_VERSION:-}"
        if [[ -n "$sops_ver" ]]; then
            if [[ ! "$sops_ver" =~ ^v[0-9]+\.[0-9]+\.[0-9] ]]; then
                log_error "SOPS_VERSION '${sops_ver}' does not match expected format vX.Y.Z — aborting."
                return 1
            fi
            log_info "Using pinned SOPS version: ${sops_ver}"
        else
            log_info "SOPS_VERSION not pinned — resolving latest from GitHub..."
            sops_ver=$(resolve_github_latest "getsops/sops") || return 1
        fi

        log_info "Installing SOPS ${sops_ver} with checksum verification..."

        local sops_filename="sops-${sops_ver}.linux.${arch}"
        local base_url="https://github.com/getsops/sops/releases/download/${sops_ver}"
        local sops_bin="$TMP_WORKDIR/${sops_filename}"
        local sops_checksums="$TMP_WORKDIR/sops-${sops_ver}.checksums.txt"

        wget -q "${base_url}/${sops_filename}"               -O "$sops_bin"       || {
            log_error "Failed to download SOPS binary: ${base_url}/${sops_filename}"
            return 1
        }
        wget -q "${base_url}/sops-${sops_ver}.checksums.txt" -O "$sops_checksums" || {
            log_error "Failed to download SOPS checksums: ${base_url}/sops-${sops_ver}.checksums.txt"
            return 1
        }

        local expected actual
        expected=$(grep "${sops_filename}$" "$sops_checksums" | awk '{print $1}')
        actual=$(sha256sum "$sops_bin" | awk '{print $1}')

        if [[ -z "$expected" ]]; then
            log_error "Could not find checksum entry for '${sops_filename}' in checksums file."
            log_error "The checksums file may not include this architecture/version combination."
            log_error "Pin SOPS_VERSION=vX.Y.Z at the top of setup.sh and retry."
            return 1
        fi

        if [[ "$expected" != "$actual" ]]; then
            log_error "SOPS checksum MISMATCH — refusing to install."
            log_error "  Expected: $expected"
            log_error "  Actual:   $actual"
            log_error "This may indicate a compromised download, MITM, or corrupted file."
            log_error "Pin SOPS_VERSION=vX.Y.Z and retry. Releases: https://github.com/getsops/sops/releases"
            return 1
        fi

        log_success "SOPS checksum verified: $expected"
        install -m 755 "$sops_bin" /usr/local/bin/sops || return 1
    fi
    return 0
}

verify_dependencies() {
    hash -r
    local required_commands=("age" "sops" "docker" "jq" "sqlite3" "ufw" "curl" "python3" "htpasswd")
    require_commands "${required_commands[@]}" || return 1
    python3 -c "from argon2 import PasswordHasher" 2>/dev/null || return 1
    docker compose version >/dev/null 2>&1 || return 1
    return 0
}

setup_user_permissions() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would configure user permissions"; return 0; fi

    local real_user; real_user=$(get_real_user)
    id "$real_user" >/dev/null 2>&1 || return 1

    # Ensure the docker group exists before attempting usermod.
    # On OCI instances where Docker binaries are pre-installed but the daemon
    # has never been started, the package postinst may not have created the
    # group yet (or it was stripped from the base image). This is the
    # post-install step recommended by https://docs.docker.com/engine/install/linux-postinstall/
    if ! getent group docker >/dev/null 2>&1; then
        log_info "'docker' group not found — creating it now"
        groupadd --system docker || return 1
        log_success "Created system group 'docker'"
    fi

    if ! groups "$real_user" | grep -q '\bdocker\b'; then
        usermod -aG docker "$real_user" || return 1
        log_success "Added ${real_user} to the 'docker' group"
        log_info "Note: group membership takes effect on next login / new shell for ${real_user}"
    fi

    find "$PROJECT_ROOT" -maxdepth 1 \
        ! -name 'secrets' \
        ! -path "$PROJECT_ROOT" \
        -exec chown --no-dereference "$real_user:$(id -g -n "$real_user")" {} \; 2>/dev/null || true

    return 0
}

detect_ssh_log_path() {
    local ssh_log_path="/var/log/secure"
    local os_id

    if [[ -f /etc/os-release ]]; then
        os_id=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' | tr -d "'")
        case "$os_id" in
            ol|rhel|centos|rocky|almalinux|fedora) ssh_log_path="/var/log/secure" ;;
            ubuntu|debian) ssh_log_path="/var/log/auth.log" ;;
            *)
                if [[ -f "/var/log/secure" ]]; then ssh_log_path="/var/log/secure"
                else ssh_log_path="/var/log/auth.log"; fi ;;
        esac
    fi
    echo "$ssh_log_path"
}

# ---------------------------------------------------------------------------
# setup_data_volume
# ---------------------------------------------------------------------------
# Provisions the dedicated data volume when DATA_VOLUME_DEVICE is set.
# Idempotent: safe to re-run. All decisions are based on current on-disk state
# rather than flags, so re-running on an already-provisioned system is a no-op.
#
# Steps:
#   1. Validate that DATA_VOLUME_DEVICE is a block device.
#   2. Check filesystem type. Format ext4 only if the device is completely
#      blank (no valid superblock). Aborts if a non-ext4 filesystem is found.
#   3. Create mount point directory.
#   4. Add a UUID-based fstab entry if absent (idempotent).
#   5. Mount the device (idempotent — skips if already mounted).
#   6. Write the sentinel file .vw-data-volume.
# ---------------------------------------------------------------------------
setup_data_volume() {
    if [[ -z "${DATA_VOLUME_DEVICE:-}" ]]; then
        log_info "DATA_VOLUME_DEVICE not set — skipping data volume provisioning (boot-only mode)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would provision data volume: $DATA_VOLUME_DEVICE → $DATA_VOLUME_MOUNT"
        return 0
    fi

    local device="$DATA_VOLUME_DEVICE"
    local mount_point="$DATA_VOLUME_MOUNT"

    # ── Require system utilities ──────────────────────────────────────────
    require_commands blkid || return 1
    require_commands mountpoint || return 1

    # ── 1. Validate device ────────────────────────────────────────────────
    if [[ ! -b "$device" ]]; then
        log_error "DATA_VOLUME_DEVICE is not a block device: $device"
        log_error "Check .env or verify the disk is attached to this instance."
        return 1
    fi

    # Confirm device path has only safe characters to prevent command injection.
    if [[ ! "$device" =~ ^/dev/[a-zA-Z0-9/]+$ ]]; then
        log_error "DATA_VOLUME_DEVICE contains disallowed characters: $device"
        return 1
    fi

    # ── 2. Filesystem check / format ──────────────────────────────────────
    local fs_type
    fs_type=$(blkid -o value -s TYPE "$device" 2>/dev/null || true)

    if [[ -z "$fs_type" ]]; then
        log_info "No filesystem found on $device — formatting as ext4..."
        log_warn "ALL DATA ON $device WILL BE ERASED. This is expected on first run."
        if ! mkfs.ext4 -F -L vw-data "$device" > /dev/null 2>&1; then
            log_error "mkfs.ext4 failed for $device"
            return 1
        fi
        log_success "Formatted $device as ext4 (label: vw-data)"
    elif [[ "$fs_type" == "ext4" ]]; then
        log_info "Existing ext4 filesystem found on $device — skipping format (idempotent)"
    else
        log_error "Unexpected filesystem type on $device: $fs_type"
        log_error "Expected: ext4 or blank. Refusing to overwrite an existing filesystem."
        log_error "If this is correct, set DATA_VOLUME_DEVICE= and manage the volume manually."
        return 1
    fi

    # ── 3. Create mount point ─────────────────────────────────────────────
    if [[ ! -d "$mount_point" ]]; then
        mkdir -p "$mount_point" || { log_error "Cannot create mount point: $mount_point"; return 1; }
        chmod 755 "$mount_point"
        log_info "Created mount point: $mount_point"
    fi

    # ── 4. fstab entry (UUID-based, idempotent) ───────────────────────────
    local dev_uuid
    dev_uuid=$(blkid -o value -s UUID "$device" 2>/dev/null || true)
    if [[ -z "$dev_uuid" ]]; then
        log_error "Cannot determine UUID for $device — cannot create fstab entry"
        return 1
    fi

    if ! grep -qF "UUID=$dev_uuid" /etc/fstab 2>/dev/null; then
        log_info "Adding fstab entry for UUID=$dev_uuid → $mount_point"
        printf 'UUID=%s\t%s\text4\tdefaults,nofail,x-systemd.after=local-fs.target\t0\t2\n' \
            "$dev_uuid" "$mount_point" >> /etc/fstab || {
            log_error "Failed to append to /etc/fstab"
            return 1
        }
        log_success "fstab entry added (UUID=$dev_uuid)"
    else
        log_info "fstab entry already present for UUID=$dev_uuid (idempotent)"
    fi

    # Reload systemd unit state so new fstab mount units are visible.
    systemctl daemon-reload 2>/dev/null || true

    # ── 5. Mount (idempotent) ─────────────────────────────────────────────
    if mountpoint -q "$mount_point" 2>/dev/null; then
        log_info "$mount_point already mounted (idempotent)"
    else
        log_info "Mounting $device at $mount_point ..."
        if ! mount "$mount_point"; then
            log_error "mount failed for $mount_point"
            log_error "Check /etc/fstab and verify the device is attached."
            return 1
        fi
        log_success "Mounted $device at $mount_point"
    fi

    # ── 6. Sentinel file ──────────────────────────────────────────────────
    local sentinel="$mount_point/.vw-data-volume"
    if [[ ! -f "$sentinel" ]]; then
        printf 'VaultWarden-OCI data volume\nDevice: %s\nMounted: %s\nCreated: %s\n' \
            "$device" "$mount_point" "$(date -Iseconds)" > "$sentinel" || {
            log_error "Failed to write sentinel file: $sentinel"
            return 1
        }
        chmod 444 "$sentinel"
        log_success "Sentinel file written: $sentinel"
    else
        log_info "Sentinel file already present: $sentinel (idempotent)"
    fi

    log_success "Data volume provisioning complete: $device → $mount_point"
    return 0
}

# ---------------------------------------------------------------------------
# install_docker_mount_guard
# ---------------------------------------------------------------------------
# Creates a Docker systemd drop-in that adds RequiresMountsFor on
# DATA_VOLUME_MOUNT, preventing Docker from starting if the data volume is
# absent during boot (fail-closed behaviour).
#
# When DATA_VOLUME_DEVICE is blank (boot-only mode), any previously installed
# drop-in is removed so the system is left clean.
# Idempotent: re-running with the same mount path is a no-op.
# ---------------------------------------------------------------------------
install_docker_mount_guard() {
    local drop_in_dir="/etc/systemd/system/docker.service.d"
    local drop_in_file="$drop_in_dir/10-vaultwarden-data-volume.conf"

    if [[ -z "${DATA_VOLUME_DEVICE:-}" ]]; then
        # Boot-only mode: remove any stale guard from a previous configuration.
        if [[ -f "$drop_in_file" ]]; then
            log_info "DATA_VOLUME_DEVICE cleared — removing Docker mount guard drop-in"
            rm -f "$drop_in_file"
            systemctl daemon-reload 2>/dev/null || true
        else
            log_info "DATA_VOLUME_DEVICE not set — Docker mount guard not needed (boot-only mode)"
        fi
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install Docker systemd mount guard for: $DATA_VOLUME_MOUNT"
        return 0
    fi

    local mount_point="$DATA_VOLUME_MOUNT"

    # Validate mount path has only safe characters.
    if [[ ! "$mount_point" =~ ^/[a-zA-Z0-9/_-]+$ ]]; then
        log_error "DATA_VOLUME_MOUNT contains disallowed characters: $mount_point"
        return 1
    fi

    mkdir -p "$drop_in_dir" || { log_error "Cannot create drop-in directory: $drop_in_dir"; return 1; }

    # Check if the drop-in already covers this mount path.
    if [[ -f "$drop_in_file" ]] && grep -qF "RequiresMountsFor=$mount_point" "$drop_in_file" 2>/dev/null; then
        log_info "Docker mount guard already installed for $mount_point (idempotent)"
        return 0
    fi

    log_info "Installing Docker systemd mount guard for: $mount_point"
    cat > "$drop_in_file" << DROPIN
# Managed by VaultWarden-OCI setup.sh — do not edit by hand.
# Requires the data volume to be mounted before Docker starts.
# This prevents the stack from writing to the boot volume if the
# data disk is absent (e.g. accidental detach after a reboot).
[Unit]
RequiresMountsFor=$mount_point
DROPIN

    chmod 644 "$drop_in_file" || return 1
    systemctl daemon-reload 2>/dev/null || true
    log_success "Docker mount guard installed: $drop_in_file"
    return 0
}

create_env_file() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would create .env file"; return 0; fi

    local env_file="$PROJECT_ROOT/.env"
    local env_template="$PROJECT_ROOT/.env.example"

    if [[ -f "$env_file" ]] && [[ "$FORCE" != "true" ]]; then
        local domain_matches=false email_matches=false latest_matches=false
        grep -qF "DOMAIN=$DOMAIN" "$env_file"       && domain_matches=true
        grep -qF "ADMIN_EMAIL=$ADMIN_EMAIL" "$env_file" && email_matches=true

        if [[ "$USE_LATEST" == "true" ]]; then
            # Latest mode: ALL version fields must already be 'latest'
            if grep -qE '^VAULTWARDEN_VERSION=latest' "$env_file" && \
               grep -qE '^CADDY_VERSION=latest'       "$env_file" && \
               grep -qE '^FAIL2BAN_VERSION=latest'    "$env_file" && \
               grep -qE '^POSTFIX_VERSION=latest'     "$env_file" && \
               grep -qE '^BUSYBOX_VERSION=latest'     "$env_file"; then
                latest_matches=true
            fi
        else
            if ! grep -qE '^(VAULTWARDEN|CADDY|FAIL2BAN|POSTFIX|BUSYBOX)_VERSION=latest' "$env_file"; then
                latest_matches=true
            fi
        fi

        if [[ "$domain_matches" == "true" ]] && \
           [[ "$email_matches" == "true" ]] && \
           [[ "$latest_matches" == "true" ]]; then
            return 0
        fi
    fi

    local prev_umask; prev_umask=$(umask)
    umask 077
    cp "$env_template" "$env_file" || { umask "$prev_umask"; return 1; }
    umask "$prev_umask"

    local real_user; real_user=$(get_real_user)
    local user_id; user_id=$(id -u "$real_user")
    local group_id; group_id=$(id -g "$real_user")
    local detected_ssh_log_path; detected_ssh_log_path=$(detect_ssh_log_path 2>/dev/null)

    local domain_with_protocol
    [[ "$DOMAIN" =~ ^https?:// ]] && domain_with_protocol="$DOMAIN" || domain_with_protocol="https://$DOMAIN"

    local clean_domain; clean_domain=$(echo "$domain_with_protocol" | sed -E 's|https?://||; s|/.*$||')
    CLEAN_DOMAIN="$clean_domain"

    local temp_env
    temp_env=$(mktemp -p "$(dirname "$env_file")" .env.tmp.XXXXXXXXXX) || return 1
    # Ensure temp file is cleaned up on any failure path from this point.
    trap 'rm -f "$temp_env" 2>/dev/null || true' RETURN

    # Compute PROJECT_STATE_DIR value: when a data volume is configured it MUST
    # equal DATA_VOLUME_MOUNT; otherwise use the default boot-volume location.
    local awk_state_dir
    if [[ -n "${DATA_VOLUME_DEVICE:-}" ]]; then
        awk_state_dir="${DATA_VOLUME_MOUNT:-/mnt/vw-data}"
    else
        awk_state_dir="/var/lib/vaultwarden"
    fi

    AWK_DOMAIN="$domain_with_protocol" \
    AWK_EMAIL="$ADMIN_EMAIL" \
    AWK_UID="$user_id" \
    AWK_GID="$group_id" \
    AWK_SMTP_FROM="noreply@$clean_domain" \
    AWK_F2B_DEST_MAIL="$ADMIN_EMAIL" \
    AWK_F2B_SENDER="fail2ban@$clean_domain" \
    AWK_ALLOWED_SENDER_DOMAINS="$clean_domain" \
    AWK_SSH_LOG="$detected_ssh_log_path" \
    AWK_DATA_DEVICE="${DATA_VOLUME_DEVICE:-}" \
    AWK_DATA_MOUNT="${DATA_VOLUME_MOUNT:-/mnt/vw-data}" \
    AWK_STATE_DIR="$awk_state_dir" \
    awk '
        {
            sub(/^DOMAIN=.*/, "DOMAIN=" ENVIRON["AWK_DOMAIN"]);
            sub(/^ADMIN_EMAIL=.*/, "ADMIN_EMAIL=" ENVIRON["AWK_EMAIL"]);
            sub(/^PUID=.*/, "PUID=" ENVIRON["AWK_UID"]);
            sub(/^PGID=.*/, "PGID=" ENVIRON["AWK_GID"]);
            sub(/^SMTP_FROM=.*/, "SMTP_FROM=" ENVIRON["AWK_SMTP_FROM"]);
            sub(/^F2B_DEST_MAIL=.*/, "F2B_DEST_MAIL=" ENVIRON["AWK_F2B_DEST_MAIL"]);
            sub(/^F2B_SENDER=.*/, "F2B_SENDER=" ENVIRON["AWK_F2B_SENDER"]);
            sub(/^ALLOWED_SENDER_DOMAINS=.*/, "ALLOWED_SENDER_DOMAINS=" ENVIRON["AWK_ALLOWED_SENDER_DOMAINS"]);
            sub(/^SSH_LOG_PATH=.*/, "SSH_LOG_PATH=" ENVIRON["AWK_SSH_LOG"]);
            sub(/^DATA_VOLUME_DEVICE=.*/, "DATA_VOLUME_DEVICE=" ENVIRON["AWK_DATA_DEVICE"]);
            sub(/^DATA_VOLUME_MOUNT=.*/, "DATA_VOLUME_MOUNT=" ENVIRON["AWK_DATA_MOUNT"]);
            sub(/^PROJECT_STATE_DIR=.*/, "PROJECT_STATE_DIR=" ENVIRON["AWK_STATE_DIR"]);
            print;
        }' "$env_file" > "$temp_env"

    mv "$temp_env" "$env_file" || return 1

    if [[ "$USE_LATEST" == "true" ]]; then
        temp_env=$(mktemp -p "$(dirname "$env_file")" .env.tmp.XXXXXXXXXX) || return 1
        awk '{
            sub(/^VAULTWARDEN_VERSION=.*/, "VAULTWARDEN_VERSION=latest");
            sub(/^CADDY_VERSION=.*/, "CADDY_VERSION=latest");
            sub(/^FAIL2BAN_VERSION=.*/, "FAIL2BAN_VERSION=latest");
            sub(/^POSTFIX_VERSION=.*/, "POSTFIX_VERSION=latest");
            sub(/^BUSYBOX_VERSION=.*/, "BUSYBOX_VERSION=latest");
            print;
        }' "$env_file" > "$temp_env"
        mv "$temp_env" "$env_file" || return 1
    fi

    # Ensure the canonical production Age key path is written to .env so the
    # verification in generate_age_keys() always succeeds on a clean install.
    temp_env=$(mktemp -p "$(dirname "$env_file")" .env.tmp.XXXXXXXXXX) || return 1
    awk '{
        sub(/^SOPS_AGE_KEY_FILE=.*/, "SOPS_AGE_KEY_FILE=/etc/vaultwarden/age-key.txt");
        print;
    }' "$env_file" > "$temp_env"
    mv "$temp_env" "$env_file" || return 1

    chown "$real_user:$(id -g -n "$real_user")" "$env_file" || return 1
    chmod 600 "$env_file" || return 1
    return 0
}

setup_directories() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would setup directories"; return 0; fi

    # If a separate data volume is configured, assert it is mounted and valid
    # before we create any subdirectories inside it. This prevents accidentally
    # writing the directory skeleton onto the boot volume if the mount failed.
    # Export the storage vars so require_project_state_ready can read them.
    export DATA_VOLUME_DEVICE="${DATA_VOLUME_DEVICE:-}"
    export DATA_VOLUME_MOUNT="${DATA_VOLUME_MOUNT:-/mnt/vw-data}"
    # Align PROJECT_STATE_DIR with the storage mode so the consistency check
    # inside require_project_state_ready passes. In boot-only mode this is a no-op.
    if [[ -n "${DATA_VOLUME_DEVICE:-}" ]]; then
        export PROJECT_STATE_DIR="${DATA_VOLUME_MOUNT}"
    else
        export PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    fi
    require_project_state_ready || return 1

    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n "$real_user")

    local secrets_dirs=("secrets" "secrets/keys" "secrets/.docker_secrets")
    for dir in "${secrets_dirs[@]}"; do
        ensure_dir "$dir" 700 || return 1
        chown "$real_user:$real_group" "$dir" || return 1
    done

    local puid; puid=$(id -u "$real_user")
    local pgid; pgid=$(id -g "$real_user")
    local project_state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"

    # Create the backup directory tree that backup.sh and restore.sh require.
    # Derive the default backup location from PROJECT_STATE_DIR so that
    # separate-volume setups land their backups on the data volume, not the
    # boot volume.  Operators who set BACKUP_DIR explicitly in .env always
    # take precedence over this default.
    local backup_base_dir="${BACKUP_DIR:-${project_state_dir}/backups}"
    if ! mkdir -p "${backup_base_dir}"/{db,full,emergency}; then
        log_error "Failed to create backup directories under ${backup_base_dir}"
        return 1
    fi
    chmod 750 "${backup_base_dir}" "${backup_base_dir}"/{db,full,emergency} || return 1
    chown -R "${puid}:${pgid}" "${backup_base_dir}" || return 1
    log_info "Backup directories created: ${backup_base_dir}/{db,full,emergency}"

    if ! mkdir -p "${project_state_dir}"/{data,logs/{vaultwarden,caddy,fail2ban,postfix},caddy/{data,config},fail2ban}; then
        return 1
    fi

    chown -R "${puid}:${pgid}" "$project_state_dir" || return 1

    # Use {} + (batch exec) instead of {} \; (per-file exec) for performance.
    find "${project_state_dir}" -type d -exec chmod 750 {} + 2>/dev/null || return 1
    find "${project_state_dir}" -type f -exec chmod 640 {} + 2>/dev/null || true

    # Caddy runs as root inside its container and writes
    # access logs to ${project_state_dir}/logs/caddy/access.log via a bind-mount.
    #
    # The broad 'find chmod 750' above sets this directory to 750:
    #   owner=PUID  group=PGID  other=---
    #
    # On OCI Compute, Docker maps container UID 0 to an unprivileged host UID
    # (userns-remap or equivalent hypervisor isolation). Container root is NOT
    # host root. Any chmod/chown attempted inside the container on this
    # bind-mount fails with EPERM. Both the init container and caddy/entrypoint.sh
    # attempted 'chmod 755 /logs/caddy' — both fail silently on OCI.
    #
    # The definitive fix: set 755 here, running as real host root (setup.sh
    # is always invoked via 'sudo ./setup.sh'). This executes AFTER the broad
    # find chmod 750, overriding it for this specific directory.
    #
    # 755 rationale: Caddy's container UID falls into 'other' (it is neither
    # PUID nor PGID). 'other' needs at least r-x (5) to enter the directory
    # and rw- (6) on the log file itself. 755 grants r-x to 'other', and
    # Caddy creates access.log with mode 0644 (rw-r--r--), satisfying both.
    #
    # fail2ban uses the same pattern (chown 0:0 + chmod 755 in the init
    # container) because it also runs as root and needs a root-writable dir.
    # Caddy's directory is owned by PUID:PGID (not root) so we cannot simply
    # chown it; 755 on a PUID-owned dir gives Caddy write access via 'other'.
    chmod 755 "${project_state_dir}/logs/caddy" || return 1
    log_info "Set ${project_state_dir}/logs/caddy to 755 (Caddy runs as root in container)"

    # Caddy's TLS storage directories must be owned by
    # root:root and traversable (755) so Caddy can write certificate material
    # during the first ACME negotiation.
    #
    # Why root:root, not PUID:PGID:
    #   Caddy runs as UID 0 inside its container. On OCI Compute, userns-remap
    #   maps container UID 0 to an unprivileged host UID (e.g. 165536+), which
    #   is neither PUID nor PGID. The broad 'chown -R PUID:PGID' pass above
    #   would assign these directories to PUID, making them unreachable by the
    #   remapped container root. We do a second targeted chown pass here,
    #   running as real host root (setup.sh always runs under sudo), so the
    #   inodes end up owned by host UID 0 — the only identity the remapped
    #   container root maps to.
    #
    # Why 755, not 700:
    #   700 is rwx------: only the exact owning UID can enter. The remapped
    #   container UID is not host root (0), so 700 blocks traversal with
    #   EACCES. 755 grants r-x to all, which is sufficient for a
    #   non-world-writable storage directory containing private keys (the
    #   keys themselves are created by Caddy with mode 0600).
    #
    # Pre-creating certificates/, locks/, ocsp/:
    #   Caddy's ACME client attempts to mkdir these paths during the first TLS
    #   negotiation, often under concurrent request load. Pre-creating them
    #   here (owned by root:root, mode 755) eliminates the first-run race
    #   where two goroutines simultaneously attempt to mkdir the same path.
    local caddy_data_dir="${project_state_dir}/caddy/data"
    local caddy_config_dir="${project_state_dir}/caddy/config"

    mkdir -p \
        "${caddy_data_dir}/caddy/certificates" \
        "${caddy_data_dir}/caddy/locks" \
        "${caddy_data_dir}/caddy/ocsp"

    chown -R root:root "${caddy_data_dir}" "${caddy_config_dir}" || return 1
    find "${caddy_data_dir}" "${caddy_config_dir}" -type d -exec chmod 755 {} + || return 1
    find "${caddy_data_dir}" "${caddy_config_dir}" -type f -exec chmod 600 {} + 2>/dev/null || true

    log_info "Set ${caddy_data_dir} and ${caddy_config_dir} to root:root 755 (Caddy ACME storage)"
    log_info "Pre-created Caddy ACME subtree: certificates/ locks/ ocsp/"

    return 0
}

check_entropy() {
    local entropy; entropy=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo "0")
    (( entropy >= ENTROPY_THRESHOLD )) && return 0

    log_warn "Insufficient entropy (${entropy} bits, need ${ENTROPY_THRESHOLD}). Waiting for entropy pool to fill..."
    log_info  "Progress is shown below — do NOT abort. Install haveged to speed this up."

    local waited=0
    while (( waited < ENTROPY_MAX_WAIT )); do
        printf '  [entropy] Waiting' >&2
        local tick
        for (( tick = 0; tick < 5; tick++ )); do
            printf '.' >&2
            sleep 1
        done
        waited=$(( waited + 5 ))
        entropy=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo "0")
        printf ' %d bits (%ds/%ds)\n' "$entropy" "$waited" "$ENTROPY_MAX_WAIT" >&2
        (( entropy >= ENTROPY_THRESHOLD )) && return 0
    done

    log_error "Insufficient entropy after ${ENTROPY_MAX_WAIT}s (got ${entropy} bits, need ${ENTROPY_THRESHOLD}). Install haveged: sudo apt-get install -y haveged"
    return 1
}

generate_age_keys() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would generate Age keys"; return 0; fi

    check_entropy || return 1
    local age_key_file="secrets/keys/age-key.txt"

    if [[ -f "$age_key_file" ]]; then
        if [[ "$FORCE" != "true" ]]; then
            if check_age_key "$age_key_file" 2>/dev/null; then
                return 0
            else
                log_warn "Existing Age key file is present but INVALID/CORRUPT."
                log_warn "It will be replaced. If any usable encrypted data was created"
                log_warn "with a previous key version, it cannot be recovered after this."
                log_warn "If in doubt, abort (Ctrl-C) and inspect: $age_key_file"
            fi
        else
            if check_age_key "$age_key_file" 2>/dev/null; then
                if [[ "$AUTO_MODE" == "true" ]]; then
                    log_error "--force with --auto would regenerate the Age encryption key."
                    log_error "This permanently invalidates ALL existing encrypted secrets."
                    log_error "Run './edit-secrets.sh --export-recovery-kit' first, then"
                    log_error "retry with --force WITHOUT --auto to confirm interactively."
                    return 1
                else
                    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    log_warn "  WARNING: --force will REGENERATE the Age encryption key."
                    log_warn "  ALL existing encrypted secrets will become permanently"
                    log_warn "  unrecoverable without a prior recovery kit export."
                    log_warn "  Run './edit-secrets.sh --export-recovery-kit' FIRST."
                    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    printf '\nType %sROTATE KEY%s to confirm, or anything else to abort: ' \
                        "${COLOR_RED:-}" "${COLOR_RESET:-}"
                    local confirm
                    read -r confirm
                    if [[ "$confirm" != "ROTATE KEY" ]]; then
                        log_info "Key regeneration cancelled — existing key preserved."
                        return 1
                    fi
                fi
            fi
        fi
    fi

    local real_user; real_user=$(get_real_user)
    generate_age_key "$age_key_file" "$FORCE" || return 1
    chown "$real_user:$(id -g -n "$real_user")" "$age_key_file" || return 1
    chmod 600 "$age_key_file" || return 1

    # Wire: verify the freshly written key before create_sops_config() tries
    # to derive the public key from it.  simple_verify_age_key() resolves the
    # path internally (honouring SOPS_AGE_KEY_FILE / _resolve_age_key()), then
    # validates permissions, ownership, and runs a crypto roundtrip.  Catching
    # a corrupt or mis-permissioned key here prevents a confusing failure later
    # when sops --encrypt is first attempted.
    if ! SOPS_AGE_KEY_FILE="$age_key_file" simple_verify_age_key; then
        log_error "Age key verification failed immediately after generation — aborting."
        log_error "Key file: $age_key_file"
        log_error "Check disk space, filesystem errors, or re-run setup."
        return 1
    fi

    # ── Canonical production install ─────────────────────────────────────────
    # Install the key to the canonical root-owned path outside the repo tree.
    # Guard: if the canonical key already exists and FORCE != true, verify it
    # with check_age_key and skip re-install if healthy.
    local canonical_key="/etc/vaultwarden/age-key.txt"
    local do_install=true
    if [[ -f "$canonical_key" ]] && [[ "$FORCE" != "true" ]]; then
        if check_age_key "$canonical_key" 2>/dev/null; then
            log_info "Canonical Age key already present and healthy: $canonical_key"
            do_install=false
        else
            log_warn "Canonical Age key exists but is invalid — reinstalling: $canonical_key"
        fi
    fi

    if [[ "$do_install" == "true" ]]; then
        install -d -m 700 /etc/vaultwarden || {
            log_error "Failed to create /etc/vaultwarden directory."
            return 1
        }
        install -m 600 "$age_key_file" "$canonical_key" || {
            log_error "Failed to install Age key to $canonical_key."
            return 1
        }
        chown root:root /etc/vaultwarden "$canonical_key" || {
            log_error "Failed to set ownership on $canonical_key."
            return 1
        }
        log_success "Age key installed: $canonical_key (mode 600, root:root)"
    fi

    # ── Update .env atomically to the canonical path ─────────────────────────
    local env_file="$PROJECT_ROOT/.env"
    if [[ -f "$env_file" ]]; then
        local temp_env
        temp_env=$(mktemp -p "$(dirname "$env_file")" .env.tmp.XXXXXXXXXX) || return 1
        awk '{
            sub(/^SOPS_AGE_KEY_FILE=.*/, "SOPS_AGE_KEY_FILE=/etc/vaultwarden/age-key.txt");
            print;
        }' "$env_file" > "$temp_env"
        mv "$temp_env" "$env_file" || { rm -f "$temp_env"; return 1; }
        log_success "SOPS_AGE_KEY_FILE updated to $canonical_key in .env"
    fi

    # ── Verify .env now points to the canonical path ─────────────────────────
    local configured_path
    configured_path=$(grep '^SOPS_AGE_KEY_FILE=' "${env_file:-$PROJECT_ROOT/.env}" 2>/dev/null | cut -d= -f2)
    if [[ "$configured_path" != "$canonical_key" ]]; then
        log_error "After installation, .env SOPS_AGE_KEY_FILE still points to: ${configured_path:-<unset>}"
        log_error "Expected: $canonical_key"
        log_error "Update .env manually: SOPS_AGE_KEY_FILE=$canonical_key"
        return 1
    fi

    log_info "Production key: $canonical_key"
    log_info "Repo-local copy retained for local/dev use: $age_key_file"

    return 0
}

create_sops_config() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would create SOPS config"; return 0; fi

    local sops_config=".sops.yaml"
    local age_key_file="secrets/keys/age-key.txt"

    local age_public_key; age_public_key=$(get_age_public_key "$age_key_file") || return 1

    if [[ ! "$age_public_key" =~ ^age1[a-z0-9]{58}$ ]]; then
        log_error "Age public key has unexpected format: '${age_public_key}'"
        log_error "Expected format: age1<58 lowercase alphanumeric chars>"
        log_error "Regenerate the key with: rm secrets/keys/age-key.txt && ./setup.sh ..."
        return 1
    fi

    if [[ -f "$sops_config" ]] && [[ "$FORCE" != "true" ]]; then
        if grep -qF "$age_public_key" "$sops_config"; then
            if grep -q "creation_rules:" "$sops_config" && grep -q "age:" "$sops_config"; then
                log_info "SOPS config already up-to-date"
                return 0
            fi
        fi
        log_warn "SOPS config exists but public key has changed — rewriting .sops.yaml"
    fi

    cat > "$sops_config" << EOF
creation_rules:
  - path_regex: .*\.yaml$
    age: $age_public_key
EOF
    chown "$(get_real_user):$(id -g -n "$(get_real_user)")" "$sops_config" || return 1
    return 0
}

create_empty_secrets_structure() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would create secrets structure"; return 0; fi

    local secrets_file="$PROJECT_ROOT/secrets/secrets.yaml"
    local age_key_file="$PROJECT_ROOT/secrets/keys/age-key.txt"

    if [[ -f "$secrets_file" ]] && [[ "$FORCE" != "true" ]]; then
        local decrypt_ok=false
        ( export SOPS_AGE_KEY_FILE="$age_key_file"; sops -d "$secrets_file" >/dev/null 2>&1 ) \
            && decrypt_ok=true
        if [[ "$decrypt_ok" == "true" ]]; then
            return 0
        else
            log_error "Existing secrets.yaml is unreadable with current key. Use --force to overwrite."
            return 1
        fi
    fi

    local temp_secrets; temp_secrets=$(mktemp -p "$TMP_WORKDIR" vwsecrets.XXXXXXXXXX.yaml) || return 1
    cat > "$temp_secrets" << 'EOF'
admin_token: PLACEHOLDER_NOT_CONFIGURED
admin_basic_auth_hash: PLACEHOLDER_NOT_CONFIGURED
smtp_password: PLACEHOLDER_NOT_CONFIGURED
email_api_token: PLACEHOLDER_NOT_CONFIGURED
backup_passphrase: PLACEHOLDER_NOT_CONFIGURED
push_installation_id: PLACEHOLDER_NOT_CONFIGURED
push_installation_key: PLACEHOLDER_NOT_CONFIGURED
caddy_cloudflare_dns_token: PLACEHOLDER_NOT_CONFIGURED
fail2ban_cloudflare_firewall_token: PLACEHOLDER_NOT_CONFIGURED
EOF
    chmod 600 "$temp_secrets"

    ( export SOPS_AGE_KEY_FILE="$age_key_file"; \
      sops --encrypt --output "$secrets_file" "$temp_secrets" ) || return 1

    chmod 600 "$secrets_file" || return 1
    chown "$(get_real_user):$(id -g -n "$(get_real_user)")" "$secrets_file" || return 1
    return 0
}

create_docker_compose() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would create docker-compose.yml"; return 0; fi

    local compose_file="$PROJECT_ROOT/docker-compose.yml"
    local compose_template="$PROJECT_ROOT/docker-compose.yml.example"

    if [[ -f "$compose_file" ]] && [[ "$FORCE" != "true" ]]; then
        docker compose -f "$compose_file" config >/dev/null 2>&1 && return 0
    fi

    cp "$compose_template" "$compose_file" || return 1
    chown "$(get_real_user):$(id -g -n "$(get_real_user)")" "$compose_file" || return 1
    chmod 640 "$compose_file" || return 1
    return 0
}

# ---------------------------------------------------------------------------
# set_script_permissions
# ---------------------------------------------------------------------------
# Ensures every script that an admin might invoke after a fresh clone is
# executable without requiring a manual 'chmod +x' pass. Git does not
# preserve execute bits across clones on some systems/clients, so we set
# them here explicitly.
#
# Covers:
#   - Root-level *.sh scripts (operator-facing)
#   - caddy/entrypoint.sh  (run as container CMD; must be +x before 'make up')
#   - fail2ban/*.sh        (any helper scripts present in that subdir)
#   - lib/*.sh             (sourced, not executed directly — kept 644)
# ---------------------------------------------------------------------------
set_script_permissions() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would set script permissions"; return 0; fi

    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n "$real_user")

    # ------------------------------------------------------------------
    # 1. Root-level operator scripts — chmod +x
    # ------------------------------------------------------------------
    local root_scripts=(
        "setup.sh"
        "edit-secrets.sh"
        "backup.sh"
        "restore.sh"
        "startup.sh"
        "maintenance.sh"
        "create-breakglass-admin.sh"
        "uninstall-vaultwarden.sh"
    )
    for script in "${root_scripts[@]}"; do
        if [[ -f "$script" ]]; then
            chmod +x "$script"
            chown "$real_user:$real_group" "$script" 2>/dev/null || true
            log_success "Set +x: $script"
        fi
    done

    # ------------------------------------------------------------------
    # 2. caddy/entrypoint.sh — must be executable before 'make up';
    #    Docker copies it into the image with its host permissions, so a
    #    missing +x bit causes 'permission denied' at container start.
    #    Use process substitution to avoid a pipe-subshell so log_success
    #    calls take effect in the current shell.
    # ------------------------------------------------------------------
    if [[ -d "caddy" ]]; then
        while IFS= read -r script; do
            chmod +x "$script"
            chown "$real_user:$real_group" "$script" 2>/dev/null || true
            log_success "Set +x: $script"
        done < <(find "caddy" -maxdepth 1 -name "*.sh")
    fi

    # ------------------------------------------------------------------
    # 3. fail2ban/*.sh — same rationale as caddy/entrypoint.sh
    # ------------------------------------------------------------------
    if [[ -d "fail2ban" ]]; then
        while IFS= read -r script; do
            chmod +x "$script"
            chown "$real_user:$real_group" "$script" 2>/dev/null || true
            log_success "Set +x: $script"
        done < <(find "fail2ban" -maxdepth 1 -name "*.sh")
    fi

    # ------------------------------------------------------------------
    # 4. lib/*.sh — sourced (not executed), keep 644 read-only for non-root
    # ------------------------------------------------------------------
    if [[ -d "lib" ]]; then
        find "lib" -name "*.sh" -exec chown "$real_user:$real_group" {} + 2>/dev/null || true
        find "lib" -name "*.sh" -exec chmod 644 {} + 2>/dev/null || true
    fi

    return 0
}

setup_firewall() {
    # SECURITY: UFW rules must be applied AFTER Docker installation.
    # Docker rewrites iptables chains during installation; rules set before
    # Docker is installed are silently bypassed by Docker's DOCKER-USER chain.
    # This function is called after install_dependencies (which installs Docker),
    # ensuring the correct order of operations.
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would configure firewall"; return 0; fi

    local ssh_port
    ssh_port=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    if [[ -z "$ssh_port" ]]; then
        ssh_port=$(awk '/^Port[[:space:]]/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)
    fi
    ssh_port=${ssh_port:-22}
    log_info "Detected SSH port: ${ssh_port}"

    local cf_ipv4_url="https://www.cloudflare.com/ips-v4"
    local cf_ipv6_url="https://www.cloudflare.com/ips-v6"
    local cf_cidrs=()
    local cf_fetch_failed=false

    log_info "Fetching Cloudflare CIDR lists for firewall restriction..."
    local ipv4_list ipv6_list
    ipv4_list=$(curl -fsSL --max-time 15 "$cf_ipv4_url" 2>/dev/null) || cf_fetch_failed=true
    ipv6_list=$(curl -fsSL --max-time 15 "$cf_ipv6_url" 2>/dev/null) || cf_fetch_failed=true

    if [[ "$cf_fetch_failed" == "false" ]] && \
       [[ -n "$ipv4_list" ]] && [[ -n "$ipv6_list" ]]; then
        while IFS= read -r cidr; do
            [[ -z "$cidr" || "$cidr" == \#* ]] && continue
            cf_cidrs+=("$cidr")
        done <<< "$ipv4_list"
        while IFS= read -r cidr; do
            [[ -z "$cidr" || "$cidr" == \#* ]] && continue
            cf_cidrs+=("$cidr")
        done <<< "$ipv6_list"
        log_info "Fetched ${#cf_cidrs[@]} Cloudflare CIDRs"
    else
        log_warn "Could not fetch Cloudflare CIDR lists — falling back to unrestricted allow rules."
        log_warn "SECURITY: Ports 80/443 will be open to all IPs. Restrict manually after setup:"
        log_warn "  See: https://www.cloudflare.com/ips-v4 and https://www.cloudflare.com/ips-v6"
    fi

    # Check firewall state once and reuse the result.
    local ufw_active=false
    ufw status | grep -q "Status: active" && ufw_active=true

    if [[ "$ufw_active" == "true" ]] && \
       ufw status | grep -q "80/tcp" && \
       ufw status | grep -q "443/tcp" && \
       ufw status | grep -q "${ssh_port}/tcp"; then
        log_success "Firewall already configured and active"
        return 0
    fi

    ufw allow "${ssh_port}/tcp"

    if [[ ${#cf_cidrs[@]} -gt 0 ]]; then
        for cidr in "${cf_cidrs[@]}"; do
            ufw allow from "$cidr" to any port 80 proto tcp  2>/dev/null || true
            ufw allow from "$cidr" to any port 443 proto tcp 2>/dev/null || true
        done
        log_success "Firewall: ports 80/443 restricted to ${#cf_cidrs[@]} Cloudflare CIDRs"
    else
        # Fallback: unrestricted (already warned above)
        ufw allow 80/tcp
        ufw allow 443/tcp
    fi

    [[ "$ufw_active" == "false" ]] && ufw --force enable
    return 0
}

validate_ssh_config() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would validate SSH config"; return 0; fi

    if grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config 2>/dev/null; then
        log_warn "SSH root login is enabled - consider disabling"
    fi
    return 0
}

cleanup_setup_deps() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would cleanup dependencies"; return 0; fi

    apt-get autoremove -y >/dev/null 2>&1 || true
    return 0
}

execute_phase() {
    local phase_func="$1"
    local phase_name="$2"
    local phase_critical="${3:-false}"

    log_info "=== Phase: $phase_name ==="
    [[ "$phase_func" == "verify_dependencies" ]] && hash -r

    local exit_code=0
    "$phase_func" || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Phase failed: $phase_name (exit code: $exit_code)"
        [[ "$phase_critical" == "true" ]] && return 1 || return 2
    fi

    log_success "Phase completed: $phase_name"
    return 0
}

show_post_install_summary() {
    local mode="${1:-interactive}"
    [[ "$mode" == "interactive" ]] && clear

    printf '%s' "${COLOR_RED}"    cat << "EOF"
    ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! !
    !                                                             !
    !   CRITICAL: SAVE THIS INFORMATION FOR DISASTER RECOVERY     !
    !                                                             !
    ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! ! !
EOF
    printf '%s' "${COLOR_RESET}"

    if [[ -f "secrets/keys/age-key.txt" ]]; then
        local age_pub_key
        age_pub_key=$(get_age_public_key "secrets/keys/age-key.txt" 2>/dev/null || echo "MISSING")
        local age_key_content
        age_key_content=$(cat "secrets/keys/age-key.txt" 2>/dev/null || echo "ERROR: Could not read key file")
        printf 'SOPS Age Public Key:  %s%s%s\n' "${COLOR_GREEN}" "${age_pub_key}" "${COLOR_RESET}"
        printf '\n%sSECRET KEY (BACKUP THIS FILE!):%s\n' "${COLOR_RED}" "${COLOR_RESET}"
        printf '%sSECRET KEY (production): %s/etc/vaultwarden/age-key.txt%s\n' "${COLOR_RED}" "${COLOR_GREEN}" "${COLOR_RESET}"
        printf '%sSECRET KEY (repo-local): %ssecrets/keys/age-key.txt%s\n' "${COLOR_RED}" "${COLOR_GREEN}" "${COLOR_RESET}"
        printf '%s%s%s\n' "${COLOR_GREEN}" "${age_key_content}" "${COLOR_RESET}"
        printf '\n%sTo view again at any time:%s\n' "${COLOR_RED}" "${COLOR_RESET}"
        printf '  %ssudo cat /etc/vaultwarden/age-key.txt%s  %s(production — root-owned, mode 600)%s\n' \
            "${COLOR_GREEN}" "${COLOR_RESET}" "${COLOR_RED}" "${COLOR_RESET}"
        printf '  %scat secrets/keys/age-key.txt%s  %s(repo-local copy — intentional for local dev only)%s\n' \
            "${COLOR_GREEN}" "${COLOR_RESET}" "${COLOR_RED}" "${COLOR_RESET}"
    fi

    # Determine correct edit command based on actual .env ownership
    local env_owner
    env_owner=$(stat -c '%U' "$PROJECT_ROOT/.env" 2>/dev/null || echo "root")
    local env_edit_cmd="nano .env"
    [[ "$env_owner" == "root" ]] && env_edit_cmd="sudo nano .env"

    if [[ "$mode" == "auto" ]]; then
        printf '\n%s--- AUTO-GENERATED CREDENTIALS (scroll up to save plaintext passwords) ---%s\n' \
            "${COLOR_CYAN}" "${COLOR_RESET}"
        printf '  %s✔%s VaultWarden admin token    : GENERATED (Argon2id hash stored in secrets)\n' \
            "${COLOR_GREEN}" "${COLOR_RESET}"
        printf '  %s✔%s Caddy admin password       : GENERATED (bcrypt hash stored in secrets)\n' \
            "${COLOR_GREEN}" "${COLOR_RESET}"
        printf '  %s✔%s Backup passphrase          : GENERATED (stored in secrets)\n' \
            "${COLOR_GREEN}" "${COLOR_RESET}"

        printf '\n%s--- CREDENTIALS REQUIRING MANUAL CONFIGURATION ---%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf 'These fields still contain CHANGE_ME placeholders.\n'
        printf 'Set them BEFORE running %smake up%s:\n\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %s./edit-secrets.sh --rotate caddy_cloudflare_dns_token%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %s./edit-secrets.sh --rotate fail2ban_cloudflare_firewall_token%s\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %s./edit-secrets.sh --rotate smtp_password%s         (if using SMTP/email notifications)\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %s./edit-secrets.sh --rotate email_api_token%s       (if using API-based email, e.g. MAILERSEND_API_TOKEN)\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %s./edit-secrets.sh --rotate push_installation_id%s  (optional — mobile push)\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf '  %s./edit-secrets.sh --rotate push_installation_key%s (optional — mobile push)\n' \
            "${COLOR_YELLOW}" "${COLOR_RESET}"

        printf '\n%s--- NEXT STEPS ---%s\n' "${COLOR_CYAN}" "${COLOR_RESET}"
