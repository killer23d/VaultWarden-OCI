#!/usr/bin/env python3
"""Read-only P0 preflight for a NEW Ubuntu 26.04 ARM64 recovery/acceptance host.

No provision, install, mount, mkfs, restoration, DNS, rclone, service, apt,
Docker or other appliance mutation. Only private evidence in operator home.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import platform
import pwd
import re
import stat
import subprocess
import sys
import tomllib
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True
os.umask(0o077)

SOURCE = Path(__file__).resolve().parents[2]
PERSISTENT = tuple(map(Path, (
    '/opt/vaultwarden-oci',
    '/etc/vaultwarden-oci',
    '/var/lib/vaultwarden-oci',
    '/run/vaultwarden-oci',
)))
UNITS = ('vaultwarden-oci.target', 'vaultwarden-oci.service',
         'vaultwarden-oci-health.timer', 'vaultwarden-oci-backup.timer',
         'vaultwarden-oci-maintenance.timer', 'vaultwarden-oci-update-check.timer')


def read_command(argv: list[str], *, timeout: int = 20) -> tuple[int | None, str]:
    """Read-only command with stderr suppressed to avoid copying secrets."""
    try:
        run = subprocess.run(argv, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             text=True, timeout=timeout, check=False, cwd='/')
        return run.returncode, run.stdout
    except (OSError, subprocess.TimeoutExpired):
        return None, ''


def disk_classification(fs: str, mounted: bool, signatures: set[str] | None) -> str:
    if mounted:
        return 'MOUNTED_REVIEW'
    if signatures is None:
        return 'UNPROVEN_SIGNATURES'
    if not signatures and not fs:
        return 'BLANK_REVIEW'
    if fs in {'ext4', 'xfs'} and signatures <= {fs}:
        return 'EXISTING_FS_REVIEW'
    return 'UNKNOWN_SIGNATURES_REVIEW'


def safe_alias(device: str) -> str | None:
    """List only stable device aliases; do not treat one as approved storage."""
    try:
        real = Path(device).resolve(strict=True)
        names = []
        for item in Path('/dev/disk/by-id').iterdir():
            if not item.is_symlink():
                continue
            try:
                if item.resolve(strict=True) == real:
                    names.append(item)
            except OSError:
                pass
    except OSError:
        return None
    usable = sorted(str(item) for item in names if item.name.startswith(
        ('scsi-', 'wwn-', 'nvme-', 'virtio-')))
    return usable[0] if usable else None


def evidence_dir() -> Path:
    operator = os.environ.get('SUDO_USER', '')
    if not operator or operator == 'root':
        raise ValueError('requires sudo from a named non-root operator')
    identity = pwd.getpwnam(operator)
    home = Path(identity.pw_dir)
    if not home.is_dir() or home.is_symlink():
        raise ValueError('unsafe operator home')
    base = home / 'vwoci-acceptance'
    if base.is_symlink():
        raise ValueError('evidence base is a symlink')
    if not base.exists():
        base.mkdir(mode=0o700)
        os.chown(base, identity.pw_uid, identity.pw_gid)
    info = base.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != identity.pw_uid
            or stat.S_IMODE(info.st_mode) & 0o077):
        raise ValueError('evidence base is not privately owned')
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    folder = base / f'production-newhost-p0-{stamp}-{os.getpid()}'
    folder.mkdir(mode=0o700)
    return folder


def main() -> int:
    if len(sys.argv) != 1:
        print('BLOCKED: preflight accepts no command arguments', file=sys.stderr)
        return 2
    if os.geteuid() != 0:
        print('BLOCKED: run via sudo -n as a non-root operator', file=sys.stderr)
        return 2
    try:
        folder = evidence_dir()
    except (OSError, KeyError, ValueError) as exc:
        print('BLOCKED: cannot create private evidence (' + type(exc).__name__ + ')', file=sys.stderr)
        return 2

    rows: list[tuple[str, str]] = []
    private: dict[str, Any] = {}
    blocked = False

    def record(status: str, text: str) -> None:
        nonlocal blocked
        if status == 'BLOCKED':
            blocked = True
        rows.append((status, text))

    def finish() -> int:
        result = 'BLOCKED' if blocked else 'PENDING'
        record(result, 'No installation or recovery authorization granted by this preflight')
        summary = 'Gate P0 - NEW HOST read-only preflight\n' + '\n'.join(
            f'{status:<8} {label}' for status, label in rows
        ) + '\n'
        (folder / 'summary.txt').write_text(summary, encoding='utf-8')
        (folder / 'diagnostics.json').write_text(json.dumps(private, indent=2, sort_keys=True) + '\n', encoding='utf-8')
        print(summary, end='')
        print('Private evidence:', folder)
        print('Paste the summary only; do not paste protected configuration or credentials.')
        return 2 if blocked else 0

    os_release: dict[str, str] = {}
    try:
        for line in Path('/etc/os-release').read_text(encoding='utf-8').splitlines():
            if '=' in line and not line.startswith('#'):
                k, v = line.split('=', 1)
                os_release[k] = v.strip('"')
    except OSError:
        pass

    arch = platform.machine()
    ver = os_release.get('VERSION_ID', '?')
    name = os_release.get('VERSION_CODENAME', '?')
    is_supported = (os_release.get('ID') == 'ubuntu' and ver == '26.04'
                    and name == 'resolute' and arch in ('aarch64', 'arm64')
                    and sys.version_info[:2] == (3, 14))
    record('PASS' if is_supported else 'BLOCKED',
           f'OS Ubuntu={ver}/{name}, architecture={arch}, Python={platform.python_version()}')
    record('PASS', 'Host=' + platform.node().split('.')[0] +
           ' UTC=' + dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
    private['kernel'] = platform.release()

    try:
        with (SOURCE / 'versions.toml').open('rb') as stream:
            version = tomllib.load(stream)['vaultwarden_oci']['version']
        if version != '0.1.0-rc.12':
            raise ValueError('unexpected release manifest')
    except (OSError, ValueError, KeyError, TypeError, tomllib.TOMLDecodeError):
        record('BLOCKED', 'Review checkout: release manifest is not the expected rc.12')
    else:
        record('PASS', 'Reviewed source manifest is 0.1.0-rc.12 (checkout SHA pinned by caller)')

    installed = [str(p) for p in PERSISTENT if p.exists() or p.is_symlink()]
    live = []
    for unit in UNITS:
        rc, out = read_command(['systemctl', 'show', unit,
                                '--no-pager', '--property=ActiveState,UnitFileState'])
        settings = dict(line.split('=', 1) for line in out.splitlines() if '=' in line)
        if rc is None:
            record('BLOCKED', 'Cannot inspect systemd state safely')
            break
        if settings.get('ActiveState') in {'active', 'activating', 'reloading'} or settings.get('UnitFileState') in {'enabled', 'enabled-runtime'}:
            live.append(unit)
    if installed or live:
        record('BLOCKED', 'Existing or partial appliance detected; use installed-host triage, DO NOT run a fresh installer')
        private['existing_appliance_paths'] = installed
        private['active_or_enabled_units'] = live
    else:
        record('PASS', 'No existing appliance paths or active/enabled appliance units')

    # Use the same root/boot ancestry owner as the installer. No guessing
    # that /dev/sda, /dev/vdb, or the largest disk is the data disk.
    try:
        sys.path.insert(0, str(SOURCE))
        from vaultwarden_oci import storage
        root = storage.root_source()
        candidates = storage.inventory()
    except Exception as exc:
        record('BLOCKED', 'Cannot prove root-disk ancestry or enumerate non-boot candidates (' + type(exc).__name__ + ')')
        return finish()

    record('PASS', f'Root filesystem device={root}; root-related candidates excluded')
    private['root'] = root
    private['devices'] = []
    plausible = 0
    for entry in candidates:
        path = str(entry['path'])
        fstype = str(entry['fstype'])
        mountpoints = entry['mountpoints']
        rc, out = read_command(['wipefs', '--noheadings', '--output', 'TYPE', path])
        signatures = set(out.split()) if rc == 0 else None
        category = disk_classification(fstype, bool(mountpoints), signatures)
        alias = safe_alias(path)
        size = int(entry['size'])
        if category in {'BLANK_REVIEW', 'EXISTING_FS_REVIEW'} and alias:
            plausible += 1
        record('PENDING', f'Device={path} size_GiB={size // 1073741824} fs={fstype or "none"} '
               f'category={category} stable_by_id={alias or "missing"}')
        private['devices'].append({'path': path, 'bytes': size, 'fs': fstype,
                                    'mounted': bool(mountpoints),
                                    'category': category, 'stable_by_id': alias,
                                    'signature_types': sorted(signatures) if signatures is not None else None})
    record('PASS' if plausible else 'BLOCKED',
           f'Plausible non-boot data-volume entries={plausible}; none are approved without OCI Console identity match')

    dependency_bins = ('git', 'python3', 'sops', 'age-keygen', 'rclone', 'docker')
    installed_bins = {tool: read_command(['sh', '-c', 'command -v "$1" >/dev/null 2>&1', '_', tool])[0] == 0
                      for tool in dependency_bins}
    private['tool_presence'] = installed_bins
    record('PASS', 'Dependencies inventoried only: ' +
           ', '.join(f'{tool}={"yes" if present else "no"}' for tool, present in installed_bins.items()))
    record('PENDING', 'Operator must independently confirm OCI volume attachment, by-id, size, absence of existing data and approval')
    record('PENDING', 'Original recovery-kit ZIP and passphrase, matching offline Age identity, and remote .vwrec must be verified')
    record('PENDING', 'Root rclone remote must be configured separately before a remote restore')
    record('NOT RUN', 'Installer dry-run, format, mount, rc.12 install, remote download, SOPS restore, Cloudflare, email, timers, reboot')
    return finish()


if __name__ == '__main__':
    raise SystemExit(main())
