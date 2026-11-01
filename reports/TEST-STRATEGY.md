# VaultWarden-OCI test strategy

Status: current supporting validation policy. The durable product authority remains `docs/PROJECT-BOUNDARY.md` and `docs/DECISIONS.md`.

## Objective

Tests protect security, availability, recoverability, and operator truthfulness. Testing is not a parallel implementation of the appliance.

## Three layers

### Focused unit tests

Use for deterministic project logic: TOML/config/catalog/version parsing, architecture mapping, CIDR/staleness policy, response/fallback classification, manifest/checksum/retention decisions, exact version resolution, redaction, and stable status/doctor shape.

### Small integration tests

Use real temporary files/process boundaries when they are the risk: permissions/flock, SOPS/Age orchestration, Compose/Caddy rendering, rclone invocation and recovery artifacts, AES-256 recovery-kit verification, systemd unit content, and Docker packet-policy behavior. Prefer real temporary artifacts over large mocked state machines.

### Disposable real-host release acceptance

Keep the established full-system Ubuntu 24.04 disposable-host baseline and test both `amd64` and `arm64` where available: storage/root-disk refusal, real stack/dashboard, origin/CrowdSec, backup/rclone/restore, recovery-kit handoff, update/rollback, timers, host upgrades/reboot and notifications. Ubuntu 26.04 also has explicit native Python 3.14 x64/Arm64 CI and OS-sensitive checks. **Actual Ubuntu 26.04 ARM64 OCI acceptance was completed on October 30–31, 2026**, with frozen rc.11 recovery/operations/reboot and corrected rc.12 SOPS install continuation/real ZIP path verification recorded in [the agent handoff](../docs/ACCEPTANCE-HANDOFF.md). Do not infer a clean uninterrupted rc.12 first pass, complete live rc.12 operation, AMD64 real-host acceptance, or production cutover from that evidence.

Unavailable host/provider/architecture coverage is `NOT RUN`, never inferred from mocks or another architecture.

## Permanent CI

Keep PR CI proportional: compile/shell parsing, focused unit suite, and the small integration jobs already owned by the repository. Do not make destructive cloud/full-host acceptance an ordinary PR controller.

Deterministic quality/unit jobs must not depend on external container registries. Exact-image, custom-image, and packet-path checks live in clearly named integration jobs. External image fetches use bounded retries with short backoff, but an unavailable registry still fails the owning integration job; CI must never silently convert missing external evidence into PASS. Ubuntu-version compatibility jobs keep native runtime/unit/systemd checks separate from registry-dependent security integration so a red check names the failed boundary truthfully.

One behavior should normally have one best permanent test level. Avoid exact private source-string/order assertions, extracted private shell-function harnesses, prose freezing, custom test runners, coverage-percentage gates, or broad matrices without a concrete risk.

## High-risk focus

Recovery deserves the strongest attention: consistent SQLite snapshot, manifest/checksum rejection, wrong-key failure before mutation, non-destructive rclone publication, independent remote verification, staging before promotion, and pruning separate from publication.

SOPS/Age tests cover project custody/invocation/permissions/leakage responsibilities, not the cryptographic algorithms themselves.

Notification tests cover the closed provider catalog, HTTPS/TLS/auth safety, bounded retry/fallback, redaction, and stable diagnostics. Canonical fields are exactly `from_email`, `from_name`, `from_header`, `to_email`, `subject`, `text`. Current CyberPersons policy: HTTP `503 service_unavailable` is status-only transient/retry/fallback eligible; HTTP `429 rate_limit_exceeded` and `500 send_failed` are not transient by status alone.

Cloudflare/CrowdSec unit tests cover project parsing/policy; actual origin packets and external remediation belong to integration/real-host acceptance as appropriate. Caddy client-IP trust, host origin filtering, and CrowdSec Cloudflare remediation are distinct controls.

`vwctl doctor` tests stable check IDs, PASS/WARN/FAIL/SKIP classification, JSON shape/exit behavior, and secret-free output rather than exact human prose.

## Required validation statement

Every PR/release report states behavior changed, exact tests run, tests not run and why, real-host/provider/architecture evidence, any new test/support file and its ownership reason, and out-of-scope follow-ups. Never convert unavailable destructive/external evidence into `PASS`.
