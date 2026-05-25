#!/usr/bin/env bash
# utilities/setup-system.sh — Prepares the host system for VaultWarden-OCI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Use a secure project-local temporary workspace that is cleaned up on exit.
old_umask=$(umask)
umask 077
TMP_WORKDIR=$(mktemp -d -p "${PROJECT_ROOT}" vw_sys_tmp.XXXXXXXXXX) || {
    echo "ERROR: Failed to create secure temporary directory" >&2
    exit 1
}
umask "$old_umask"
trap 'rm -rf "$TMP_WORKDIR"' EXIT
trap 'rm -rf "${TMP_WORKDIR:-}"; exit 130' INT
trap 'rm -rf "${TMP_WORKDIR:-}"; exit 143' TERM

for _lib in "lib/log.sh" "lib/config.sh" "lib/common.sh"; do
    if [[ ! -f "${PROJECT_ROOT}/${_lib}" ]]; then
        echo "ERROR: Required library not found: ${PROJECT_ROOT}/${_lib}" >&2
        exit 1
    fi
done
unset _lib
# shellcheck source=../lib/log.sh
source "${PROJECT_ROOT}/lib/log.sh"
# shellcheck source=../lib/config.sh
source "${PROJECT_ROOT}/lib/config.sh"
# shellcheck source=../lib/common.sh
source "${PROJECT_ROOT}/lib/common.sh"
init_common_lib "$0"

SOPS_VERSION="${SOPS_VERSION:-}"
SKIP_DEPS=false
AUTO_MODE=false
USE_LATEST=false
DRY_RUN=false
FORCE=false
DATA_VOLUME_DEVICE="${DATA_VOLUME_DEVICE:-}"
DATA_VOLUME_MOUNT="${DATA_VOLUME_MOUNT:-/mnt/vw-data}"

# Exported so that any sub-scripts invoked later can inherit these flags.
export USE_LATEST FORCE

show_help() {
    cat <<'EOF'
utilities/setup-system.sh — VaultWarden-OCI system preparation

USAGE:
    sudo utilities/setup-system.sh [OPTIONS]

FLAGS:
    --skip-deps           Skip package installation (assume already installed)
    --auto                Non-interactive mode
    --use-latest          Override pinned versions with 'latest'
    --sops-version VER    Pin SOPS to a specific version (e.g. v3.9.4)
    --dry-run             Preview actions without executing
    --force               Skip confirmations
    --data-device DEV     Data volume device path
    --data-mount PATH     Data volume mount point (default: /mnt/vw-data)
    --help, -h            Show this help
EOF
}

_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-deps)    SKIP_DEPS=true ;;
            --auto)         AUTO_MODE=true ;;
            --use-latest)   USE_LATEST=true ;;
            --dry-run)      DRY_RUN=true ;;
            --force)        FORCE=true ;;
            --sops-version)
                shift
                [[ $# -gt 0 ]] || { log_error "--sops-version requires an argument"; exit 1; }
                SOPS_VERSION="$1"
                ;;
            --data-device)
                shift
                [[ $# -gt 0 ]] || { log_error "--data-device requires an argument"; exit 1; }
                DATA_VOLUME_DEVICE="$1"
                ;;
            --data-mount)
                shift
                [[ $# -gt 0 ]] || { log_error "--data-mount requires an argument"; exit 1; }
                DATA_VOLUME_MOUNT="$1"
                ;;
            --help|-h) show_help; exit 0 ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
        shift
    done
}

# Resolve the latest release tag from the GitHub API.
resolve_github_latest() {
    local repo="$1"
    local tag

    local api_tmpfile
    api_tmpfile=$(mktemp -p "$TMP_WORKDIR" gh-latest.XXXXXXXXXX.json)

    if ! curl -fsSL --max-time 30 \
            "https://api.github.com/repos/${repo}/releases/latest" \
            -o "$api_tmpfile" 2>/dev/null; then
        log_error "Could not fetch release info for ${repo} from GitHub API."
        log_error "Set SOPS_VERSION=vX.Y.Z via --sops-version or the environment to bypass."
        return 1
    fi

    tag=$(jq -r '.tag_name // empty' "$api_tmpfile")

    if [[ -z "$tag" ]] || [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9] ]]; then
        log_error "Could not resolve a valid release tag for ${repo}."
        log_error "Set SOPS_VERSION=vX.Y.Z via --sops-version or the environment to bypass."
        return 1
    fi

    echo "$tag"
}

# Install Docker CE from the official apt repository with GPG key verification.
install_docker() {
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

# Verify minimum free space on the project root, Docker data root, and an existing data mount.
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

    # Check the data volume only if it is already mounted (idempotent re-runs).
    local dv_mount="${DATA_VOLUME_MOUNT:-}"
    if [[ -n "${DATA_VOLUME_DEVICE:-}" && -n "$dv_mount" ]] && \
       mountpoint -q "$dv_mount" 2>/dev/null; then
        local dv_available_kb
        dv_available_kb=$(df -k "$dv_mount" | awk 'NR==2 {print $4}')
        if (( dv_available_kb < min_free_kb )); then
            log_error "Insufficient disk space on data volume $dv_mount. Required: 2 GiB, Available: $(( dv_available_kb / 1024 )) MiB"
            return 1
        fi
        log_info "Disk space OK on $dv_mount (data volume): $(( dv_available_kb / 1024 )) MiB available"
    fi

    return 0
}

# Create and activate a 1 GiB swapfile when no swap is active.
create_swapfile() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would create swapfile if needed"; return 0; fi

    if swapon --show | grep -q .; then
        log_info "Swap already active — skipping swapfile creation"
        return 0
    fi

    local swapfile="/swapfile"
    if [[ -f "$swapfile" ]]; then
        # Reuse an existing swapfile on idempotent re-runs.
        log_info "Swapfile already exists at ${swapfile} — reusing existing file"
    else
        log_info "No swap detected — creating 1 GiB swapfile at ${swapfile}..."
        fallocate -l 1G "$swapfile" || dd if=/dev/zero of="$swapfile" bs=1M count=1024 status=none || return 1
    fi

    chmod 600 "$swapfile"
    if ! blkid -o value -s TYPE "$swapfile" 2>/dev/null | grep -q '^swap$'; then
        # Initialise the swap signature only when it is missing.
        mkswap "$swapfile" >/dev/null || return 1
    fi
    swapon "$swapfile" || return 1

    if ! grep -q "^${swapfile}" /etc/fstab 2>/dev/null; then
        # Append the fstab entry only once.
        echo "${swapfile} none swap sw 0 0" >> /etc/fstab
    fi

    sysctl -q vm.swappiness=10 || true
    if ! grep -q "^vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
        # Append the sysctl setting only once.
        echo "vm.swappiness=10" >> /etc/sysctl.conf
    fi

    log_success "Swapfile created and activated (1 GiB)"
    return 0
}

# Install the required system packages, Docker, CrowdSec, and SOPS.
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
    # NOTE: haveged is a userspace entropy daemon included for compatibility with
    # kernels < 5.6 where /dev/random could block.  On Ubuntu 22.04/24.04 LTS
    # (kernel 5.15/6.8) it is a no-op overhead but harmless.  Kept to support
    # any operator who runs on an older kernel variant.
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

    local crowdsec_script="${PROJECT_ROOT}/utilities/setup-crowdsec.sh"
    if [[ -f "$crowdsec_script" ]]; then
        _require_script "$crowdsec_script"
        local _cs_args=()
        [[ "$AUTO_MODE" == "true" ]] && _cs_args+=(--auto)
        [[ "$DRY_RUN" == "true" ]] && _cs_args+=(--dry-run)
        "$crowdsec_script" "${_cs_args[@]}" || return 1
    else
        log_warn "utilities/setup-crowdsec.sh not found — skipping CrowdSec install"
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
            log_error "Pin SOPS_VERSION=vX.Y.Z via --sops-version and retry."
            return 1
        fi

        if [[ "$expected" != "$actual" ]]; then
            log_error "SOPS checksum MISMATCH — refusing to install."
            log_error "  Expected: $expected"
            log_error "  Actual:   $actual"
            log_error "This may indicate a compromised download, MITM, or corrupted file."
            log_error "Pin SOPS_VERSION=vX.Y.Z via --sops-version and retry. Releases: https://github.com/getsops/sops/releases"
            return 1
        fi

        log_success "SOPS checksum verified: $expected"
        install -m 755 "$sops_bin" /usr/local/bin/sops || return 1
    fi
    return 0
}

# Confirm that all required commands and Python modules are present.
verify_dependencies() {
    hash -r
    local required_commands=("age" "sops" "docker" "jq" "sqlite3" "ufw" "curl" "python3" "htpasswd")
    require_commands "${required_commands[@]}" || return 1
    python3 -c "from argon2 import PasswordHasher" 2>/dev/null || return 1
    docker compose version >/dev/null 2>&1 || return 1
    return 0
}

# Add the invoking user to the docker group and set project file ownership.
setup_user_permissions() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would configure user permissions"; return 0; fi

    local real_user; real_user=$(get_real_user)
    id "$real_user" >/dev/null 2>&1 || return 1

    # Ensure the docker group exists before attempting usermod.
    # On OCI instances where Docker binaries are pre-installed but the daemon
    # has never been started, the package postinst may not have created the
    # group yet on some OCI images. This matches Docker's post-install guidance:
    # https://docs.docker.com/engine/install/linux-postinstall/
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

# Ensures all operator-facing scripts are executable. Git does not always
# preserve execute bits across clones on all systems or clients.
#
# Covers:
#   - Root-level *.sh scripts (operator-facing).
#   - caddy/entrypoint.sh (run as container CMD; must be +x before 'make up').
#   - lib/*.sh (sourced, not executed directly, so kept 644).
set_script_permissions() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would set script permissions"; return 0; fi

    local real_user; real_user=$(get_real_user)
    local real_group; real_group=$(id -g -n "$real_user")

    # Normalize directory permissions before touching executable bits. Keep
    # lib/ excluded because those files are sourced and managed separately below.
    while IFS= read -r dir; do
        chmod 755 "$dir" 2>/dev/null || true
        chown "$real_user:$real_group" "$dir" 2>/dev/null || true
    done < <(find . -path "./lib" -prune -o -type d -print)

    local root_scripts=(
        "setup.sh"
        "utilities/secrets-edit.sh"
        "backup.sh"
        "restore.sh"
        "startup.sh"
        "maintenance.sh"
    )
    for script in "${root_scripts[@]}"; do
        if [[ -f "$script" ]]; then
            chmod +x "$script"
            chown "$real_user:$real_group" "$script" 2>/dev/null || true
            log_success "Set +x: $script"
        fi
    done

    if [[ -d "utilities" ]]; then
        while IFS= read -r script; do
            chmod +x "$script"
            chown "$real_user:$real_group" "$script" 2>/dev/null || true
            log_success "Set +x: $script"
        done < <(find "utilities" -maxdepth 1 -name "*.sh")
    fi

    # caddy/entrypoint.sh must be executable before 'make up'. Docker copies
    # it into the image with its host permissions, so a missing +x bit causes
    # 'permission denied' at container start. Use process substitution so
    # log_success runs in the current shell.
    if [[ -d "caddy" ]]; then
        while IFS= read -r script; do
            chmod +x "$script"
            chown "$real_user:$real_group" "$script" 2>/dev/null || true
            log_success "Set +x: $script"
        done < <(find "caddy" -maxdepth 1 -name "*.sh")
    fi

    # Keep lib/*.sh at 644 because those files are sourced, not executed.
    if [[ -d "lib" ]]; then
        find "lib" -name "*.sh" -exec chown "$real_user:$real_group" {} + 2>/dev/null || true
        find "lib" -name "*.sh" -exec chmod 644 {} + 2>/dev/null || true
    fi

    return 0
}

# Warn when root SSH login is enabled.
validate_ssh_config() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would validate SSH config"; return 0; fi

    if grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config 2>/dev/null; then
        log_warn "SSH root login is enabled - consider disabling"
    fi
    return 0
}

# Remove orphaned packages installed as transitive setup dependencies.
cleanup_setup_deps() {
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would cleanup dependencies"; return 0; fi

    apt-get autoremove -y >/dev/null 2>&1 || true
    return 0
}

main() {
    _parse_args "$@"

    (( EUID == 0 )) || { log_error "Must run as root."; exit 1; }

    [[ "$DRY_RUN" == "true" ]] && log_info "DRY RUN mode — no changes will be made"

    check_disk_space
    create_swapfile
    install_dependencies
    verify_dependencies
    setup_user_permissions
    set_script_permissions
    validate_ssh_config
    cleanup_setup_deps

    log_success "System setup complete"
}

main "$@"
