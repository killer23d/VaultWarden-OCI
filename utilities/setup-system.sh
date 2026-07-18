#!/usr/bin/env bash
# utilities/setup-system.sh — Prepares the host system for VaultWarden-OCI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SUPPORTED_UBUNTU_VERSION_ID="24.04"
SUPPORTED_UBUNTU_CODENAME="noble"
SUPPORTED_HOST_MESSAGE="VaultWarden-OCI supports Ubuntu 24.04 LTS Noble only."
SOPS_DEFAULT_VERSION="v3.13.2"
YQ_VERSION="v4.53.3"
YQ_SHA256_AMD64="fa52a4e758c63d38299163fbdd1edfb4c4963247918bf9c1c5d31d84789eded4"
YQ_SHA256_ARM64="578648e463a11c1b6db6010cbf41eafed6bee79466fcffa1bb446672cf7945ea"
YQ_INSTALL_PATH="/usr/local/bin/yq"

_ubuntu_archive_url_for_arch() {
    local arch="$1"
    case "$arch" in
        amd64)
            printf '%s\n' "http://archive.ubuntu.com/ubuntu"
            ;;
        arm64)
            printf '%s\n' "http://ports.ubuntu.com/ubuntu-ports"
            ;;
        *)
            return 1
            ;;
    esac
}

_sops_release_arch_for_dpkg() {
    local arch="$1"
    case "$arch" in
        amd64|arm64)
            printf '%s\n' "$arch"
            ;;
        *)
            return 1
            ;;
    esac
}

_yq_release_asset_for_dpkg() {
    local arch="$1"
    case "$arch" in
        amd64)
            printf '%s\n' "yq_linux_amd64"
            ;;
        arm64)
            printf '%s\n' "yq_linux_arm64"
            ;;
        *)
            return 1
            ;;
    esac
}

_yq_release_sha256_for_dpkg() {
    local arch="$1"
    case "$arch" in
        amd64)
            printf '%s\n' "$YQ_SHA256_AMD64"
            ;;
        arm64)
            printf '%s\n' "$YQ_SHA256_ARM64"
            ;;
        *)
            return 1
            ;;
    esac
}

_supported_host_error() {
    local detail="${1:-}"
    printf '%s\n' "$SUPPORTED_HOST_MESSAGE" >&2
    [[ -n "$detail" ]] && printf '%s\n' "$detail" >&2
}

_validate_supported_host_contract() {
    local os_release_file="${1:-${VAULTWARDEN_OS_RELEASE_FILE:-/etc/os-release}}"
    local arch="${2:-}"

    if [[ ! -r "$os_release_file" ]]; then
        _supported_host_error "Cannot read required release information: ${os_release_file}"
        return 1
    fi

    local ID="" VERSION_ID="" VERSION_CODENAME="" UBUNTU_CODENAME=""
    # shellcheck disable=SC1090
    . "$os_release_file"

    if [[ -z "$ID" ]]; then
        _supported_host_error "Missing ID in ${os_release_file}."
        return 1
    fi
    if [[ "$ID" != "ubuntu" ]]; then
        _supported_host_error "Unsupported operating system ID: ${ID}"
        return 1
    fi
    if [[ -z "$VERSION_ID" ]]; then
        _supported_host_error "Missing VERSION_ID in ${os_release_file}."
        return 1
    fi
    if [[ "$VERSION_ID" != "$SUPPORTED_UBUNTU_VERSION_ID" ]]; then
        _supported_host_error "Unsupported Ubuntu VERSION_ID: ${VERSION_ID}"
        return 1
    fi

    local codename=""
    if [[ -n "$VERSION_CODENAME" && -n "$UBUNTU_CODENAME" && "$VERSION_CODENAME" != "$UBUNTU_CODENAME" ]]; then
        _supported_host_error "VERSION_CODENAME (${VERSION_CODENAME}) and UBUNTU_CODENAME (${UBUNTU_CODENAME}) disagree."
        return 1
    fi
    codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    if [[ -z "$codename" ]]; then
        _supported_host_error "Missing Ubuntu codename in ${os_release_file}."
        return 1
    fi
    if [[ "$codename" != "$SUPPORTED_UBUNTU_CODENAME" ]]; then
        _supported_host_error "Unsupported Ubuntu codename: ${codename}"
        return 1
    fi

    if [[ -z "$arch" ]]; then
        if ! arch=$(dpkg --print-architecture 2>/dev/null); then
            _supported_host_error "Cannot determine host CPU architecture with dpkg --print-architecture."
            return 1
        fi
    fi
    case "$arch" in
        amd64|arm64) ;;
        *)
            _supported_host_error "Unsupported CPU architecture: ${arch}. Supported architectures: amd64, arm64."
            return 1
            ;;
    esac

    printf '%s %s\n' "$codename" "$arch"
}

_yq_resolved_version() {
    local yq_bin="${1:-}"
    [[ -n "$yq_bin" ]] || yq_bin="$(command -v yq 2>/dev/null || true)"
    [[ -n "$yq_bin" && -x "$yq_bin" ]] || return 1

    local version_output
    version_output=$("$yq_bin" --version 2>&1) || return 1
    [[ "$version_output" == *"mikefarah/yq"* ]] || return 1
    if [[ "$version_output" =~ version[[:space:]]v?([0-9]+\.[0-9]+\.[0-9]+)([[:space:]]|$) ]]; then
        printf 'v%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

_validate_yq_contract() {
    local yq_bin="${1:-}"
    [[ -n "$yq_bin" ]] || yq_bin="$(command -v yq 2>/dev/null || true)"
    [[ -n "$yq_bin" && -x "$yq_bin" ]] || return 1

    local resolved_version
    resolved_version=$(_yq_resolved_version "$yq_bin") || return 1
    [[ "$resolved_version" =~ ^v4\. ]] || return 1

    local raw_probe schema_probe
    raw_probe=$(printf 'answer: plain-value\n' | "$yq_bin" -r '.answer' - 2>/dev/null) || return 1
    [[ "$raw_probe" == "plain-value" ]] || return 1
    schema_probe=$(printf 'schema_version: 1\nsecrets:\n  - key: cloudflare_zone_id\n    required: true\n' \
        | "$yq_bin" -r '.secrets[] | select(.required == true) | .key' - 2>/dev/null) || return 1
    [[ "$schema_probe" == "cloudflare_zone_id" ]] || return 1
    return 0
}

_validate_yq_exact_contract() {
    local yq_bin="${1:-}" actual
    [[ -n "$yq_bin" ]] || yq_bin="$(command -v yq 2>/dev/null || true)"
    actual=$(_yq_resolved_version "$yq_bin") || return 1
    [[ "$actual" == "$YQ_VERSION" ]] || return 1
    _validate_yq_contract "$yq_bin"
}

_validate_sops_version_format() {
    [[ "${1:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

_sops_normalize_version_output() {
    local line
    while IFS= read -r line; do
        if [[ "$line" =~ ^sops[[:space:]]+(version[[:space:]]+)?v?([0-9]+\.[0-9]+\.[0-9]+)([[:space:]]|$|\() ]]; then
            printf 'v%s\n' "${BASH_REMATCH[2]}"
            return 0
        fi
    done
    return 1
}

_sops_resolved_version() {
    local sops_bin="${1:-}"
    [[ -n "$sops_bin" ]] || sops_bin="$(command -v sops 2>/dev/null || true)"
    [[ -n "$sops_bin" && -x "$sops_bin" ]] || return 1

    local version_output
    version_output=$("$sops_bin" --version 2>&1) || return 1
    _sops_normalize_version_output <<<"$version_output"
}

_validate_sops_contract() {
    _sops_resolved_version >/dev/null
}

if [[ "${VAULTWARDEN_TEST_ARCH_HELPERS:-}" == "1" ]]; then
    case "${1:-}" in
        ubuntu-archive-url)
            _ubuntu_archive_url_for_arch "${2:-}"
            ;;
        sops-release-arch)
            _sops_release_arch_for_dpkg "${2:-}"
            ;;
        yq-release-asset)
            _yq_release_asset_for_dpkg "${2:-}"
            ;;
        yq-release-sha256)
            _yq_release_sha256_for_dpkg "${2:-}"
            ;;
        supported-host)
            _validate_supported_host_contract "${2:-}" "${3:-}"
            ;;
        sops-default-version)
            printf '%s\n' "$SOPS_DEFAULT_VERSION"
            ;;
        yq-version)
            printf '%s\n' "$YQ_VERSION"
            ;;
        validate-yq)
            _validate_yq_contract "${2:-}"
            ;;
        validate-yq-exact)
            _validate_yq_exact_contract "${2:-}"
            ;;
        yq-resolved-version)
            _yq_resolved_version "${2:-}"
            ;;
        sops-version)
            _sops_resolved_version "${2:-}"
            ;;
        sops-version-equals)
            [[ -n "${2:-}" && -n "${3:-}" ]] || exit 2
            actual="$(_sops_resolved_version "${2:-}")" || exit 1
            [[ "$actual" == "$3" ]]
            ;;
        *)
            printf 'usage: VAULTWARDEN_TEST_ARCH_HELPERS=1 %s {ubuntu-archive-url|sops-release-arch|yq-release-asset|yq-release-sha256|supported-host|sops-default-version|yq-version|validate-yq|validate-yq-exact|yq-resolved-version|sops-version|sops-version-equals} [ARG...]\n' "$0" >&2
            exit 2
            ;;
    esac
    exit $?
fi

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

for _lib in "lib/log.sh" "lib/config.sh" "lib/common.sh" "lib/operations.sh"; do
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
# shellcheck source=../lib/operations.sh
source "${PROJECT_ROOT}/lib/operations.sh"
# shellcheck source=../lib/defaults.sh
source "${PROJECT_ROOT}/lib/defaults.sh"

_SOPS_VERSION_ENV_SET=false
if [[ -n "${SOPS_VERSION+x}" && -n "${SOPS_VERSION:-}" ]]; then
    _SOPS_VERSION_ENV_SET=true
fi
SOPS_VERSION="${SOPS_VERSION:-$SOPS_DEFAULT_VERSION}"
SOPS_VERSION_CLI_SET=false
SKIP_DEPS=false
AUTO_MODE=false
USE_LATEST=false
DRY_RUN=false
FORCE=false
DATA_VOLUME_DEVICE="${DATA_VOLUME_DEVICE:-}"
DATA_VOLUME_MOUNT="${DATA_VOLUME_MOUNT:-${_VW_DEFAULT_DATA_MOUNT}}"
SUPPORTED_HOST_CODENAME=""
SUPPORTED_HOST_ARCH=""
SUPPORTED_HOST_ARCHIVE_URL=""

# Exported so that any sub-scripts invoked later can inherit these flags.
export USE_LATEST FORCE

show_help() {
    cat <<'EOF' | sed "s|@DEFAULT_DATA_MOUNT@|${_VW_DEFAULT_DATA_MOUNT}|g"
VaultWarden-OCI System Preparation

USAGE:
    sudo utilities/setup-system.sh [OPTIONS]

DESCRIPTION:
    Prepares the host system for VaultWarden-OCI: installs dependencies
    (Docker, Age, SOPS, rclone, sqlite3), configures user permissions, and
    sets script execute bits. Called automatically by setup.sh phase 1.

OPTIONS:
    --skip-deps           Skip package installation (assume already installed)
    --auto                Non-interactive mode
    --use-latest          Resolve the latest SOPS release instead of the pinned default
    --sops-version VER    Use a specific SOPS version (default: v3.13.2)
    --dry-run             Preview actions without executing
    --force               Skip confirmations
    --data-device DEV     Data volume device path
    --data-mount PATH     Data volume mount point (default: @DEFAULT_DATA_MOUNT@)
    --help, -h            Show this help
    --version, -V         Print the VaultWarden-OCI version and exit

EXAMPLES:
    sudo utilities/setup-system.sh
    sudo utilities/setup-system.sh --dry-run
    sudo utilities/setup-system.sh --skip-deps
EOF
}

_parse_args() {
    _require_cli_value() {
        local opt="$1" value="${2-}"
        if [[ -z "$value" || "$value" == --* ]]; then
            log_error "$opt requires an argument"
            exit 1
        fi
    }

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-deps)    SKIP_DEPS=true ;;
            --auto)         AUTO_MODE=true ;;
            --use-latest)   USE_LATEST=true ;;
            --dry-run)      DRY_RUN=true ;;
            --force)        FORCE=true ;;
            --version|-V)
                print_project_version "VaultWarden-OCI" "$PROJECT_ROOT"
                exit 0
                ;;
            --sops-version)
                shift
                _require_cli_value "--sops-version" "${1-}"
                SOPS_VERSION="$1"
                SOPS_VERSION_CLI_SET=true
                ;;
            --data-device)
                shift
                _require_cli_value "--data-device" "${1-}"
                DATA_VOLUME_DEVICE="$1"
                ;;
            --data-mount)
                shift
                _require_cli_value "--data-mount" "${1-}"
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

    if [[ "$USE_LATEST" == "true" && "$SOPS_VERSION_CLI_SET" == "true" ]]; then
        log_error "--use-latest cannot be combined with --sops-version; choose one SOPS version source."
        exit 1
    fi
    if [[ "$USE_LATEST" == "true" && "$_SOPS_VERSION_ENV_SET" == "true" ]]; then
        log_error "--use-latest cannot be combined with SOPS_VERSION from the environment; choose one SOPS version source."
        exit 1
    fi
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

    if [[ -z "$tag" ]] || ! _validate_sops_version_format "$tag"; then
        log_error "Could not resolve a valid release tag for ${repo}."
        log_error "Set SOPS_VERSION=vX.Y.Z via --sops-version or the environment to bypass."
        return 1
    fi

    echo "$tag"
}

validate_supported_host_preflight() {
    local result
    if ! result=$(_validate_supported_host_contract); then
        return 1
    fi
    SUPPORTED_HOST_CODENAME="${result%% *}"
    SUPPORTED_HOST_ARCH="${result##* }"
    if ! SUPPORTED_HOST_ARCHIVE_URL=$(_ubuntu_archive_url_for_arch "$SUPPORTED_HOST_ARCH"); then
        log_error "Unsupported CPU architecture for Ubuntu archive selection: ${SUPPORTED_HOST_ARCH}"
        return 1
    fi
    log_info "Supported host validated: Ubuntu ${SUPPORTED_UBUNTU_VERSION_ID} LTS ${SUPPORTED_UBUNTU_CODENAME} (${SUPPORTED_HOST_ARCH})"
}

require_supported_host_preflight() {
    if [[ -z "$SUPPORTED_HOST_CODENAME" || -z "$SUPPORTED_HOST_ARCH" || -z "$SUPPORTED_HOST_ARCHIVE_URL" ]]; then
        validate_supported_host_preflight
    fi
}

# Install Docker CE from the official apt repository with GPG key verification.
install_docker() {
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        log_info "setup" "Docker already installed: $(docker --version)"
        return 0
    fi

    require_supported_host_preflight || return 1
    local codename arch keyfile sources_file
    codename="$SUPPORTED_HOST_CODENAME"
    arch="$SUPPORTED_HOST_ARCH"
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

    if ! operation_package_run apt-get update; then
        log_error "setup" "apt-get update failed after adding Docker repo"
        return 1
    fi

    if ! operation_package_run apt-get install -y \
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

    local min_free_kb=$(( 2 * 1024 * 1024 ))   # 2 GiB in KiB
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

install_yq() {
    # Normal dependency setup is repository-owned and deterministic: install or
    # reuse exactly YQ_VERSION. The explicit --skip-deps path does not call this
    # function; it only verifies operator-owned compatibility.
    if _validate_yq_exact_contract; then
        log_info "Pinned Mike Farah yq ${YQ_VERSION} already installed: $(yq --version)"
        return 0
    fi

    local dpkg_arch asset expected actual yq_bin base_url
    dpkg_arch="${SUPPORTED_HOST_ARCH:-$(dpkg --print-architecture)}"
    if ! asset=$(_yq_release_asset_for_dpkg "$dpkg_arch"); then
        log_error "Unsupported CPU architecture for automatic yq binary install: ${dpkg_arch}"
        log_error "Supported yq install architectures: amd64, arm64"
        return 1
    fi
    if ! expected=$(_yq_release_sha256_for_dpkg "$dpkg_arch"); then
        log_error "Missing repository-controlled yq checksum for architecture: ${dpkg_arch}"
        return 1
    fi

    log_info "Installing Mike Farah yq ${YQ_VERSION} for ${dpkg_arch}..."
    base_url="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}"
    yq_bin="$TMP_WORKDIR/${asset}"

    wget -q "${base_url}/${asset}" -O "$yq_bin" || {
        log_error "Failed to download yq binary: ${base_url}/${asset}"
        return 1
    }

    actual=$(sha256sum "$yq_bin" | awk '{print $1}')
    if [[ "$expected" != "$actual" ]]; then
        log_error "yq checksum MISMATCH — refusing to install."
        log_error "  Expected: $expected"
        log_error "  Actual:   $actual"
        return 1
    fi

    log_success "yq checksum verified: $expected"
    install -m 755 "$yq_bin" "$YQ_INSTALL_PATH" || return 1
    hash -r
    if ! _validate_yq_exact_contract "$YQ_INSTALL_PATH"; then
        log_error "Installed yq does not satisfy exact ${YQ_VERSION} plus the required schema interface."
        return 1
    fi
    if ! _validate_yq_exact_contract; then
        log_error "Resolved yq on PATH does not satisfy exact ${YQ_VERSION} plus the required schema interface after install."
        log_error "Ensure ${YQ_INSTALL_PATH} appears before incompatible yq implementations in PATH."
        return 1
    fi
    log_success "Installed yq: $(yq --version)"
}

install_sops() {
    local sops_ver="${SOPS_VERSION:-$SOPS_DEFAULT_VERSION}"
    if [[ "$USE_LATEST" == "true" ]]; then
        log_info "SOPS --use-latest requested — resolving latest release from GitHub..."
        sops_ver=$(resolve_github_latest "getsops/sops") || return 1
    elif [[ -n "$sops_ver" ]]; then
        log_info "Using SOPS version: ${sops_ver}"
    else
        log_error "Internal error: SOPS version is empty; expected pinned default ${SOPS_DEFAULT_VERSION}."
        return 1
    fi

    if ! _validate_sops_version_format "$sops_ver"; then
        log_error "SOPS_VERSION '${sops_ver}' does not match expected format vX.Y.Z — aborting."
        return 1
    fi

    local installed_sops_ver=""
    if installed_sops_ver=$(_sops_resolved_version 2>/dev/null); then
        if [[ "$installed_sops_ver" == "$sops_ver" ]]; then
            log_info "SOPS ${installed_sops_ver} already installed and matches selected version."
            return 0
        fi
        log_warn "Installed SOPS ${installed_sops_ver} does not match selected ${sops_ver}; replacing it."
    else
        log_info "No usable SOPS binary matching the repository contract was found; installing ${sops_ver}."
    fi

    local dpkg_arch arch
    dpkg_arch="${SUPPORTED_HOST_ARCH:-$(dpkg --print-architecture)}"
    if ! arch=$(_sops_release_arch_for_dpkg "$dpkg_arch"); then
        log_error "Unsupported CPU architecture for automatic SOPS binary install: ${dpkg_arch}"
        log_error "Supported automatic SOPS install architectures: amd64, arm64"
        log_error "Install sops from a supported release artifact, then re-run setup."
        return 1
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
    expected=$(awk -v file="$sops_filename" '$2 == file {print $1; exit}' "$sops_checksums")
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
    hash -r

    local final_sops_ver
    if ! final_sops_ver=$(_sops_resolved_version); then
        log_error "Installed SOPS binary does not report a usable version after install."
        return 1
    fi
    if [[ "$final_sops_ver" != "$sops_ver" ]]; then
        log_error "Resolved SOPS version after install is ${final_sops_ver}, expected ${sops_ver}."
        log_error "Ensure /usr/local/bin appears before older SOPS binaries in PATH."
        return 1
    fi
    log_success "Installed SOPS: ${final_sops_ver}"
}

# Install the required system packages, Docker, and SOPS.
# NOTE: CrowdSec is intentionally NOT installed here. It is an optional
# post-install step that requires Cloudflare secrets to be injected first.
# Run it after completing the main setup:
#   sudo ./utilities/setup-crowdsec.sh
install_dependencies() {
    if [[ "$SKIP_DEPS" == "true" ]]; then return 0; fi
    if [[ "$DRY_RUN" == "true" ]]; then log_info "[DRY RUN] Would install dependencies"; return 0; fi
    require_supported_host_preflight || return 1

    log_info "Installing system dependencies..."

    if ! grep -qE '^deb[[:space:]].*universe' \
            /etc/apt/sources.list \
            /etc/apt/sources.list.d/*.list 2>/dev/null && \
       ! grep -qE '^Components:.*\buniverse\b' \
            /etc/apt/sources.list.d/*.sources 2>/dev/null; then
        log_info "Enabling Ubuntu 'universe' repository (required for python3-argon2 and python3-yaml)..."
        if command -v add-apt-repository >/dev/null 2>&1; then
            operation_package_run add-apt-repository -y universe || {
                log_warn "add-apt-repository failed — adding universe source manually"
                echo "deb ${SUPPORTED_HOST_ARCHIVE_URL} ${SUPPORTED_HOST_CODENAME} universe" \
                    > /etc/apt/sources.list.d/ubuntu-universe.list
                operation_package_run apt-get update -qq || return 1
            }
        else
            echo "deb ${SUPPORTED_HOST_ARCHIVE_URL} ${SUPPORTED_HOST_CODENAME} universe" \
                > /etc/apt/sources.list.d/ubuntu-universe.list
            operation_package_run apt-get update -qq || return 1
        fi
        log_success "Universe repository enabled"
    fi

    local basic_packages=("age" "make" "nano" "rclone" "sqlite3" "jq" "ufw" "curl" "wget" "unzip" "git" "gpg" "coreutils" "haveged" "dnsutils" "rsync" "python3" "python3-argon2" "python3-yaml" "apache2-utils" "cron" "openssl" "tar" "zstd")

    log_info "Refreshing apt package index..."
    operation_package_run apt-get update -qq || return 1

    declare -A pkg_to_cmd=(
        [age]=age
        [make]=make
        [nano]=nano
        [rclone]=rclone
        [sqlite3]=sqlite3
        [jq]=jq
        [ufw]=ufw
        [curl]=curl
        [wget]=wget
        [unzip]=unzip
        [git]=git
        [gpg]=gpg
        [coreutils]=sha256sum
        [haveged]=haveged
        [dnsutils]=dig
        [rsync]=rsync
        [python3]=python3
        [python3-argon2]=""
        [python3-yaml]=""
        [apache2-utils]=htpasswd
        [cron]=cron
        [openssl]=openssl
        [tar]=tar
        [zstd]=zstd
    )

    local missing_packages=()
    for pkg in "${basic_packages[@]}"; do
        local cmd="${pkg_to_cmd[$pkg]:-}"
        if [[ -n "$cmd" ]]; then
            ! command -v "$cmd" >/dev/null 2>&1 && missing_packages+=("$pkg")
        else
            ! dpkg -s "$pkg" >/dev/null 2>&1 && missing_packages+=("$pkg")
        fi
    done

    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        log_info "Installing missing packages: ${missing_packages[*]}"
        operation_package_run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}" || return 1
    fi

    if ! systemctl is-active --quiet haveged; then
        systemctl enable haveged 2>/dev/null || true
        systemctl start haveged || log_warn "Failed to start haveged"
    fi

    if ! command -v docker >/dev/null 2>&1; then
        install_docker || return 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        operation_package_run env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin || return 1
    fi

    install_yq || return 1
    install_sops || return 1
    return 0
}

# Confirm that all required commands and Python modules are present.
verify_dependencies() {
    hash -r
    local required_commands=("age" "sops" "docker" "jq" "yq" "sqlite3" "ufw" "curl" "python3" "htpasswd" "zstd")
    if ! command -v ufw >/dev/null 2>&1; then
        log_error "Missing required command: ufw"
        log_info  "Install hint: sudo apt-get update && sudo apt-get install -y ufw"
        return 1
    fi

    require_commands "${required_commands[@]}" || return 1
    if ! _validate_sops_contract; then
        log_error "Resolved sops command does not satisfy the required repository SOPS interface."
        return 1
    fi
    if ! _validate_yq_contract; then
        log_error "Resolved yq does not satisfy the required Mike Farah v4 schema interface."
        return 1
    fi
    python3 -c "from argon2 import PasswordHasher" 2>/dev/null || return 1
    python3 -c "import yaml" 2>/dev/null || {
        log_error "python3-yaml (PyYAML) is not installed — required for secrets parsing"
        return 1
    }
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

    operation_package_run apt-get autoremove -y || true
    return 0
}

main() {
    _parse_args "$@"

    require_root "$@"
    validate_supported_host_preflight || exit 1
    if [[ "$DRY_RUN" != "true" ]]; then
        operation_acquire --id setup --label "Setup" || exit $?
        _setup_system_cleanup() {
            local exit_rc=$?
            operation_release "$exit_rc"
            rm -rf "${TMP_WORKDIR:-}" 2>/dev/null || true
            exit "$exit_rc"
        }
        trap _setup_system_cleanup EXIT
        trap 'operation_release 130; rm -rf "${TMP_WORKDIR:-}" 2>/dev/null || true; exit 130' INT
        trap 'operation_release 143; rm -rf "${TMP_WORKDIR:-}" 2>/dev/null || true; exit 143' TERM
        operation_set_phase "1" "System setup"
    fi

    [[ "$AUTO_MODE" == "true" ]] && log_info "Auto mode enabled"
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
