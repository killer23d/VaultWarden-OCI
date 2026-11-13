#!/usr/bin/env python3
"""P8V-B grouped stopped-host observation; NO installation or one-shot replay.

Reads protected predecessor attestations and current host. Runs only bounded,
source-only unit tests as ubuntu; never executes a real firewall refresh.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import ipaddress
import json
import os
import platform
import re
import shlex
import stat
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True
os.umask(0o077)
ROOT = Path(__file__).resolve().parents[2]
BRANCH = 'audit/rc13-p8v-hold-diagnostics-20261113'
HOST = 'vaultwarden-oci-7-vnic'
RELEASE = Path('/opt/vaultwarden-oci/releases/0.1.0-rc.12')
CURRENT = Path('/opt/vaultwarden-oci/current')
STATE = Path('/var/lib/vaultwarden-oci')
ACCEPT = Path('/home/ubuntu/vwoci-acceptance')
CHECKPOINT = ACCEPT / 'p8p-one-shot-reboot-checkpoint.json'
P8S_SUMMARY = ACCEPT / 'p8s-a-readonly-20261105T214536Z-3811/summary.txt'
CHAIN = 'VWOCI-CF-HTTPS'
BRIDGE = 'vwoci0'
UNITS = (
    'vaultwarden-oci.target', 'vaultwarden-oci.service',
    'vaultwarden-oci-health.service', 'vaultwarden-oci-health.timer',
    'vaultwarden-oci-dns.service', 'vaultwarden-oci-backup.service',
    'vaultwarden-oci-backup.timer', 'vaultwarden-oci-maintenance.service',
    'vaultwarden-oci-maintenance.timer', 'vaultwarden-oci-update-check.service',
    'vaultwarden-oci-update-check.timer', 'vaultwarden-oci-notify@.service',
)
SHA = re.compile(r'[a-f0-9]{40}\Z')


class HostGap(ValueError):
    """Sanitized read-only reason, never emit exception/provider details."""


def require(ok, reason):
    if not ok:
        raise HostGap(reason)


def command(args, seconds=20):
    try:
        p = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=seconds, check=False,
                           env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1', GIT_OPTIONAL_LOCKS='0'))
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise HostGap('readonly-command-unavailable') from exc
    require(p.returncode == 0 and len(p.stdout) <= 1048576, 'readonly-command-failed')
    return p.stdout.decode('utf-8', 'replace')


def pinned(commit):
    if not SHA.fullmatch(commit) or ROOT.is_symlink() or not (ROOT / '.git').is_dir():
        return False
    observed = []
    for args in (('rev-parse', 'HEAD'),
                 ('symbolic-ref', '--quiet', '--short', 'HEAD'),
                 ('status', '--porcelain', '--untracked-files=all')):
        try:
            p = subprocess.run(['git', *args], cwd=ROOT, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               timeout=20, check=False,
                               env=dict(os.environ, GIT_OPTIONAL_LOCKS='0', GIT_PAGER='cat'))
        except (OSError, subprocess.TimeoutExpired):
            return False
        if p.returncode or len(p.stdout) > 8192:
            return False
        observed.append(p.stdout.decode('utf-8', 'replace').strip())
    return observed == [commit, BRANCH, '']


def host_identity():
    require(os.geteuid() == 0 and os.getenv('SUDO_USER') == 'ubuntu'
            and platform.node().split('.')[0] == HOST
            and platform.machine() in ('aarch64', 'arm64')
            and sys.version_info[:2] == (3, 14), 'host-identity-or-privilege')
    props = dict(row.split('=', 1) for row in Path('/etc/os-release').read_text().splitlines()
                 if '=' in row)
    require(props.get('ID','').strip('"') == 'ubuntu'
            and props.get('VERSION_ID','').strip('"') == '26.04', 'host-os-version')


def trusted_read(path, maximum=65536):
    st = path.lstat()
    require(stat.S_ISREG(st.st_mode) and not path.is_symlink()
            and st.st_uid == 0 and stat.S_IMODE(st.st_mode) == 0o600
            and 0 < st.st_size <= maximum, 'protected-evidence-metadata')
    fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    with os.fdopen(fd, 'rb') as inp:
        return inp.read(maximum + 1)


def file_sha(path):
    st = path.lstat()
    require(stat.S_ISREG(st.st_mode) and not path.is_symlink(), 'historical-file-type-changed')
    fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    digest = hashlib.sha256()
    with os.fdopen(fd, 'rb') as stream:
        while True:
            data = stream.read(1024 * 1024)
            if not data:
                break
            digest.update(data)
    return digest.hexdigest()


def prior_continuity():
    try:
        c = json.loads(trusted_read(CHECKPOINT, maximum=16384))
        summary = trusted_read(P8S_SUMMARY).decode('utf-8')
    except (OSError, ValueError, UnicodeError) as exc:
        raise HostGap('historical-evidence-unavailable') from exc
    require(c.get('schema') == 1 and c.get('release') == '0.1.0-rc.12'
            and c.get('host') == HOST and c.get('phase') in ('requested', 'verified')
            and isinstance(c.get('hashes'), dict)
            and len(c['hashes']) >= 7, 'historical-checkpoint-incomplete')
    require('P8S-A stopped-only' in summary and
            'Original dedicated ext4' in summary and
            'DOCKER-USER' in summary, 'accepted-p8s-summary-drift')
    relevant = 0
    for name, old in c['hashes'].items():
        require(isinstance(name, str) and isinstance(old, str)
                and re.fullmatch(r'[a-f0-9]{64}', old), 'historical-hash-schema')
        # The old source-checkout entry is a historical source witness only;
        # compare preserved appliance state and the accepted evidence instead.
        if name.startswith(('/etc/vaultwarden-oci/', '/var/lib/vaultwarden-oci/',
                            '/home/ubuntu/vwoci-acceptance/')):
            relevant += 1
            require(file_sha(Path(name)) == old, 'protected-data-or-checkpoint-drift')
    require(relevant >= 7, 'historical-coverage-insufficient')


def release_identity():
    require(CURRENT.is_symlink() and CURRENT.resolve(strict=True) == RELEASE
            and RELEASE.is_dir(), 'installed-release-not-immutable-rc12')
    import tomllib
    with (RELEASE / 'versions.toml').open('rb') as stream:
        versions = tomllib.load(stream)
    require(versions.get('vaultwarden_oci', {}).get('version') == '0.1.0-rc.12',
            'installed-versions-mismatch')
    with (ROOT / 'versions.toml').open('rb') as stream:
        candidate = tomllib.load(stream)
    require(candidate.get('vaultwarden_oci', {}).get('version') == '0.1.0-rc.13',
            'source-candidate-not-rc13')


def storage_identity():
    state = STATE.stat()
    boot = Path('/').stat()
    require(state.st_dev != boot.st_dev, 'dedicated-state-mounted-on-root')
    src = command(['findmnt', '-n', '-o', 'FSTYPE', '--target', str(STATE)]).strip()
    require(src == 'ext4', 'dedicated-state-not-ext4')
    for path in (Path('/etc/vaultwarden-oci/config.toml'),
                 Path('/etc/vaultwarden-oci/secrets.sops.yaml'),
                 Path('/etc/vaultwarden-oci/age-key.txt')):
        st = path.lstat()
        require(stat.S_ISREG(st.st_mode) and not path.is_symlink()
                and st.st_uid == 0 and stat.S_IMODE(st.st_mode) == 0o600,
                'secrets-or-config-custody-drift')


def product_units_dormant():
    """Read-only systemd inspection; template units require a separate query."""
    for unit in UNITS:
        if unit.endswith('@.service'):
            files = command(['systemctl', 'list-unit-files', '--all',
                             '--no-legend', '--plain', unit])
            records = [line.split() for line in files.splitlines() if line.strip()]
            require(records == [[unit, 'static']], 'notify-template-inventory-unrecognized')
            instances = command(['systemctl', 'list-units', '--all',
                                 '--no-legend', '--plain', '--full',
                                 'vaultwarden-oci-notify@*.service'])
            require(not instances.strip(), 'notify-instance-currently-loaded')
            continue
        state = command(['systemctl', 'show', '--no-pager', unit,
                         '-p', 'LoadState', '-p', 'ActiveState', '-p', 'UnitFileState'])
        values = dict(line.split('=', 1) for line in state.splitlines() if '=' in line)
        require(values.get('LoadState') == 'loaded', 'product-unit-not-loaded')
        require(values.get('ActiveState') == 'inactive'
                and values.get('UnitFileState') not in
                ('enabled', 'enabled-runtime', 'linked', 'linked-runtime'),
                'product-service-or-timer-not-dormant')


def listeners_closed():
    """Only TCP listeners are inspected; malformed ss output cannot imply PASS."""
    sockets = command(['ss', '-H', '-lnt'])
    for row in sockets.splitlines():
        parts = row.split()
        require(len(parts) >= 4, 'listener-output-unrecognized')
        tail = re.search(r':([0-9]{1,5})$', parts[3])
        require(tail is not None, 'listener-port-unrecognized')
        require(int(tail.group(1)) not in (80, 443, 2375, 2376),
                'live-application-listener')


def containers_absent():
    require(not command(['docker', 'ps', '-a', '--format', '{{.ID}}'],
                        seconds=30).strip(), 'unexpected-existing-docker-container')


def services_stopped():
    """Compatibility wrapper; the P8V report evaluates each independently."""
    product_units_dormant()
    listeners_closed()
    containers_absent()

def parse_filter(listing: str, chain: str):
    rules = []
    for line in listing.splitlines():
        values = shlex.split(line)
        if len(values) >= 3 and values[:2] == ['-A', chain]:
            rules.append(values[2:])
    return rules


def check_filter(hook: str, policy: str, networks: tuple[str, ...]) -> bool:
    """Strict matching, but cannot replace real external Docker packet proof."""
    user = parse_filter(hook, 'DOCKER-USER')
    allowed = parse_filter(policy, CHAIN)
    def jump(rule):
        return ('-p' in rule and rule[rule.index('-p') + 1] == 'tcp'
                and '-m' in rule and 'conntrack' in rule
                and '-o' in rule and rule[rule.index('-o') + 1] == BRIDGE
                and '--ctdir' in rule and rule[rule.index('--ctdir') + 1] == 'ORIGINAL'
                and '--ctorigdstport' in rule and rule[rule.index('--ctorigdstport') + 1] == '443'
                and '-j' in rule and rule[rule.index('-j') + 1] == CHAIN
                and '--comment' in rule and rule[rule.index('--comment') + 1]
                == 'vaultwarden-oci:cloudflare-https')
    if len(user) != 1 or not jump(user[0]):
        return False
    expect = [['-s', network, '-j', 'RETURN'] for network in networks]
    expect.append(['-j', 'DROP'])
    return allowed == expect


def origin_structure():
    # Inspect the immutable installed rc.12 owner, not the rc.13 checkout.
    if str(RELEASE) not in sys.path:
        sys.path.insert(0, str(RELEASE))
    from vaultwarden_oci import edge
    cache = Path('/var/lib/vaultwarden-oci/state/cloudflare-ranges.json')
    try:
        policy = edge.load_lkg(cache)
        status = 'PASS'
    except edge.EdgeError:
        # The recovered host is stopped. Stale LKG must never be accepted for
        # a later start, but must not trigger a refresh during read-only P8V.
        try:
            policy = edge.load_lkg(cache, now=int(cache.stat().st_mtime))
        except (edge.EdgeError, OSError):
            raise HostGap('cloudflare-lkg-unavailable-or-invalid')
        status = 'PENDING'
    families = (("iptables", policy.ipv4), ("ip6tables", policy.ipv6))
    for binary, ranges in families:
        hook = command([binary, '-w', '-S', 'DOCKER-USER'])
        chain = command([binary, '-w', '-S', CHAIN])
        require(check_filter(hook, chain, tuple(str(x) for x in ranges)),
                'installed-origin-firewall-structure-drift')
    return status


def docker_bridge():
    names = command(['docker', 'network', 'ls', '--format', '{{.Name}}'], seconds=30)
    if 'vaultwarden-oci-backend' not in names.splitlines():
        raise HostGap('bridge-not-instantiated-on-stopped-host')
    raw = command(['docker', 'network', 'inspect', 'vaultwarden-oci-backend'], seconds=30)
    try:
        payload = json.loads(raw)
        cfg = payload[0]
        require(isinstance(payload, list) and len(payload) == 1
                and cfg.get('Driver') == 'bridge'
                and cfg.get('Options', {}).get('com.docker.network.bridge.name') == BRIDGE
                and cfg.get('EnableIPv6') is True, 'docker-bridge-ownership-drift')
    except (IndexError, TypeError, ValueError, AttributeError) as exc:
        raise HostGap('docker-bridge-schema-incomplete') from exc


def source_tests():
    patterns = ('test_cloudflare_api_policy.py', 'test_edge.py', 'test_runtime.py',
                'test_production_p8v_oci_layered.py', 'test_production_p8v_host_layered.py')
    counts = []
    for name in patterns:
        args = ['sudo', '-n', '-u', 'ubuntu', '/usr/bin/python3', '-B',
                '-m', 'unittest', 'discover', '-s', 'tests', '-p', name]
        try:
            p = subprocess.run(args, cwd=ROOT, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               timeout=240, check=False,
                               env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1', PYTHONPATH=str(ROOT)))
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise HostGap('bounded-source-tests-unavailable') from exc
        result = re.search(rb'Ran ([0-9]+) tests?', p.stderr)
        require(p.returncode == 0 and result is not None and b'OK' in p.stderr
                and int(result.group(1)) > 0, 'bounded-source-regression-failed')
        counts.append(int(result.group(1)))
    return sum(counts)


def save(rows, commit, outcome, count):
    st = ACCEPT.lstat()
    require(stat.S_ISDIR(st.st_mode) and stat.S_IMODE(st.st_mode) == 0o700
            and st.st_uid in (0, 1000), 'evidence-directory-unsafe')
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    folder = ACCEPT / f'p8v-host-readonly-{stamp}-{os.getpid()}'
    folder.mkdir(mode=0o700)
    name = folder / 'summary.json'
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as stream:
        json.dump({'commit': commit, 'status': outcome, 'utc': stamp,
                   'sanitized_rows': rows, 'source_test_count': count}, stream, indent=2)
        stream.write('\n')
    return name


def main(argv=None):
    import argparse
    p = argparse.ArgumentParser(description='P8V-B source-pinned stopped-host witness')
    p.add_argument('--expected-sha', required=True)
    args = p.parse_args(argv)
    if not pinned(args.expected_sha):
        print('P8V HOST: BLOCKED/2 - reviewed clean source pin missing')
        return 2
    rows = []
    tasks = [('identity', host_identity), ('installed-rc12-vs-source-rc13', release_identity),
             ('immutable-recovery-continuity', prior_continuity),
             ('dedicated-ext4-and-encrypted-custody', storage_identity),
             ('product-units-and-timers-dormant', product_units_dormant),
             ('network-listeners-closed', listeners_closed),
             ('docker-container-inventory-empty', containers_absent),
             ('installed-iptables-ip6tables-structure', origin_structure),
             ('docker-bridge-owner', docker_bridge),
             ('candidate-source-only-tests', source_tests)]
    count = 0
    critical = {
        'host-identity-or-privilege', 'host-os-version',
        'installed-release-not-immutable-rc12', 'installed-versions-mismatch',
        'source-candidate-not-rc13', 'protected-data-or-checkpoint-drift',
        'dedicated-state-mounted-on-root', 'dedicated-state-not-ext4',
        'secrets-or-config-custody-drift', 'product-service-or-timer-not-dormant',
        'live-application-listener', 'unexpected-existing-docker-container',
        'installed-origin-firewall-structure-drift', 'bounded-source-regression-failed',
        'docker-bridge-ownership-drift', 'notify-instance-currently-loaded',
    }
    for label, fn in tasks:
        try:
            result = fn()
            if label == 'candidate-source-only-tests':
                count = result
            if result == 'PENDING':
                rows.append(('PENDING', label + '-stale-lkg-does-not-authorize-start'))
            else:
                rows.append(('PASS', label))
        except HostGap as exc:
            # HostGap is always a finite, source-authored diagnostic. Never
            # forward subprocess stderr, secrets, filesystem content or IDs.
            reason = str(exc)
            if not re.fullmatch(r'[a-z][a-z0-9-]{1,96}', reason):
                reason = 'readonly-check-unclassified'
            status = 'BLOCKED' if reason in critical else 'PENDING'
            rows.append((status, label + '-' + reason))
        except Exception:
            rows.append(('PENDING', label + '-read-failed'))
    rows.extend([('PENDING', 'direct-origin-packet-path-not-observed'),
                 ('PENDING', 'canary-dns-worker-data-and-backup-isolation-unverified'),
                 ('NOT RUN', 'no-release-install-firewall-refresh-service-start-or-reboot')])
    outcome = 'BLOCKED' if any(s == 'BLOCKED' for s, _ in rows) else 'HOLD'
    try:
        path = save(rows, args.expected_sha, outcome, count)
    except Exception:
        print('P8V HOST: HOLD/1 - protected report creation failed')
        return 1
    print('P8V HOST: ' + ('BLOCKED/2' if outcome == 'BLOCKED' else 'HOLD/1')
          + ' - stopped-host evidence only, not installed rc13')
    for status, reason in rows:
        print(f'{status}: {reason}')
    print('Bounded source tests passed:', count)
    print('Owner-private evidence:', path)
    print('No host mutation, live canary, packet denial or production GO was attempted.')
    return 2 if outcome == 'BLOCKED' else 1


if __name__ == '__main__':
    raise SystemExit(main())