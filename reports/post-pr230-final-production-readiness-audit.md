# Post-PR #230 Final Production Readiness Audit

## Executive Summary

YELLOW - targeted fixes are required before this branch should be treated as production-ready or before a final production-host acceptance run is considered meaningful.

The current `delta` branch is materially stronger than the historical audit baseline. The post-PR #230 code has consolidated the permanent shell test suite, tightened CLI parsing, improved storage/migration mode precedence, preserved operation-lock semantics, made recovery commit boundaries explicit, and kept generated command reference output deterministic.

However, this final static audit found three medium-severity blockers and one low-severity documentation drift item:

| ID | Severity | Summary |
| --- | --- | --- |
| F-01 | Medium | The canonical `bash tests/run-tests.sh all` suite fails on current `delta` because the operator prompt-format scan treats `Jammy/Noble` in `AGENTS.md` as a `y/N` prompt. |
| F-02 | Medium | The Ubuntu `universe` fallback can silently default an unresolved host codename to `noble`, which violates the Jammy/Noble support contract. |
| F-03 | Medium | The Caddy base image is pinned, but the `xcaddy --with` plugin modules are unpinned, so production rebuilds are not reproducible. |
| F-04 | Low | The quick runbook still presents "OCI Security List" as the universal first-time firewall step, despite the provider-neutral support contract. |

No critical or high-severity defects were found in the static review. Security/secrets, backup/restore/recovery structure, operation guard behavior, storage safety, uninstall reset coverage, systemd hardening checks, and command-reference determinism are all in substantially better shape than in the earlier reports.

## Final Static Ship Recommendation

Do not ship the current `delta` HEAD as "production-ready" yet. Fix F-01 through F-03 first, rerun the full local validation suite, and then perform production-host acceptance on the supported host matrix. F-04 should be fixed before publishing operator-facing docs, but it does not by itself block a technical acceptance drill.

| Area | Static recommendation | Reason |
| --- | --- | --- |
| Security and secrets | Green | SOPS/Age model, transient Docker secret files, container hardening, and secret docs are coherent in static review. |
| Backup, restore, recovery | Green with host validation required | Recovery commit boundary and failure messaging are now explicit; real restore/recover drills remain mandatory. |
| Operation guard and interruption | Green | Shared lock release and package-manager child detection reflect the post-PR fixes. |
| Storage, migration, uninstall | Green/Yellow | Storage and uninstall logic look sound, but F-02 affects first-run host setup portability. |
| Systemd and automation | Green with host validation required | Static tests pass; actual timers/services still need Ubuntu validation. |
| Operator CLI, Make, dashboard | Green/Yellow | CLI contract work is strong, but the operator UI test suite currently fails due F-01. |
| Tests and CI | Yellow | Local canonical suite fails; GitHub Actions has no run for audited HEAD. |
| Documentation/generated reference | Yellow | Command reference is deterministic; provider-neutral quick-runbook wording needs correction. |
| Host portability | Yellow | Published image manifests support amd64/arm64, but Ubuntu codename fallback and unpinned Caddy plugins block a final portability claim. |

## Audit Baseline

- Repository: `https://github.com/killer23d/VaultWarden-OCI`
- Branch audited: `delta`
- Audited HEAD: `2837fc1cddb7dda4ce6e156e4e95c5355d506f3a`
- HEAD subject: `Update AGENTS.md`
- PR #230 merge commit present in history: `2d15153 Merge pull request #230 from killer23d/codex/cli-contract-consistency`
- Local branch state was fast-forwarded from `origin/delta` before audit validation.
- Baseline worktree was clean before validation; transient validation artifacts were cleaned before this report was written.
- Current audit date: 2026-07-07.

Audited after reading `AGENTS.md` in full and reading the existing reports under `reports/`, including the production-readiness review, the Sonnet second-pass review, the operator UI scans, the post-PR224 contract audit, and the post-PR226 production-simplicity audit.

## Recent Change Pressure Map

The diff from the historical pre-PR227 neighborhood through current `HEAD` is large enough that a final integration audit was warranted even though the individual changes are mostly focused.

| Pressure area | Representative changed paths | Production risk pressure |
| --- | --- | --- |
| CLI contract normalization | `setup.sh`, `startup.sh`, `restore.sh`, `recover.sh`, `utilities/*.sh`, `docs/COMMAND-REFERENCE.md` | Callers, generated docs, and help/version behavior must stay aligned. |
| Storage and migration parsing | `utilities/setup-storage.sh`, `lib/migrate.sh`, `tests/test-storage-setup.sh`, `docs/VOLUME-MIGRATION.md` | Mode precedence, destructive gates, and volume ownership checks are safety-critical. |
| Recovery behavior | `recover.sh`, `utilities/restore-run.sh`, `tests/test-restore-recovery.sh` | Recovery must distinguish rollback-safe failures from post-commit health failures. |
| Operation guard behavior | `lib/operations.sh`, `utilities/operations-status.sh`, lifecycle/backup/restore tests | Lock inheritance, child detection, and operator conflict messages must remain coherent. |
| Test consolidation | `tests/run-tests.sh`, consolidated `tests/test-*.sh`, `.github/workflows/doc-drift.yml` | Historical follow-up tests were merged into the permanent suite; CI must call the right suite. |
| Make/dashboard/operator UI | `Makefile`, `dashboard.sh`, `tests/test-operator-ui.sh`, docs | Normal operations must remain discoverable without stale wrappers or misleading success output. |
| Uninstall and test reset | `utilities/uninstall-vaultwarden.sh`, `tests/test-uninstall.sh`, `RUNBOOK.md` | Destructive removal and test reset must remain explicitly gated and complete. |
| Documentation boundary | `AGENTS.md`, `README.md`, `RUNBOOK.md`, `docs/*` | Provider-neutral, amd64/arm64, Jammy/Noble, and junior-admin claims must match executable behavior. |

## Architecture and Production Contracts Reconstructed from Current Code

The current repository implements a small-team, root-operated Vaultwarden appliance rather than a generic deployment framework. The normal production path is:

- Ubuntu 22.04 Jammy or Ubuntu 24.04 Noble.
- amd64 or arm64.
- Cloudflare DNS/proxy/WAF and Caddy DNS-01 through Cloudflare.
- Vaultwarden, custom Caddy, Postfix sidecar, CrowdSec, SOPS/Age, rclone/offsite backup, and systemd timers/services.
- Root-operated lifecycle with operator-authored repo files and root-owned runtime state under `/var/lib/vaultwarden`, `/etc/vaultwarden`, and `/run/vaultwarden-oci`.
- Shared operation guard for mutating workflows.
- Provider-neutral host execution: no OCI CLI, OCI metadata, OCI APIs, provider IAM, or provider-specific device path should be required.
- Storage modes are boot-volume state or an explicitly configured attached block/data volume with stable operator-supplied paths.
- Documentation can include provider examples, but universal prerequisites should be phrased generically.

These contracts are explicit in `AGENTS.md` and are mostly reflected in the current shell code. The gaps are in release/codename failure handling, custom Caddy reproducibility, and a quick-runbook wording path.

## Scope and Method

This was a static, report-only audit. No tracked project file was modified except this report.

Performed:

- Read current repository guidance and historical audit reports.
- Reviewed post-PR #230 integration surfaces across setup, storage, migration, restore/recover, backup, operations, systemd, Make/dashboard, tests, docs, generated reference, and compose.
- Ran required local validations where safe.
- Inspected container image manifests without pulling or running production containers.
- Checked GitHub Actions visibility for the audited branch/commit.
- Avoided real setup, restore, recovery, migration, sudo production workflows, production secrets, and destructive host operations.

Not performed:

- No real Ubuntu host setup.
- No real Docker image build.
- No real Caddy plugin compilation.
- No real Vaultwarden, Caddy, Postfix, CrowdSec, rclone, Cloudflare, or SMTP live integration.
- No real block-volume formatting, mounting, migration, restore, or recovery.
- No production secrets were used.

## Validation Performed

| Validation | Result | Notes |
| --- | --- | --- |
| `git fetch origin delta` and `git pull --ff-only origin delta` | Pass | Local branch was current with `origin/delta` at `2837fc1cddb7dda4ce6e156e4e95c5355d506f3a`. |
| PR #230 merge present | Pass | `git log --grep='#230' --all` found `2d15153`. |
| `git diff --check` | Pass | No whitespace/error output. |
| `find . -type f -name '*.sh' ... bash -n` | Pass | All shell scripts parsed. |
| `find . -type f -name '*.sh' ... shellcheck -x --severity=warning` | Pass | No warning-or-higher ShellCheck output. |
| `docker compose --env-file .env.example -f docker-compose.yml.example config --quiet` | Pass | Example compose renders. |
| `bash tests/run-tests.sh all` | Fail | Fails in `tests/test-operator-ui.sh` because `AGENTS.md:130` contains `Jammy/Noble`, which matches the raw `y/N` substring scan. See F-01. |
| Command reference generation determinism | Pass | `DOCKER_PROJECT_LABEL=ci bash utilities/write-command-reference.sh` produced no diff on first or second run; hash remained `47a90f5a06481d610359992c4cfbe15d14abf7f0ef9700a9a7a913078829811e`. |
| Image manifest inspection | Pass for base images | `vaultwarden:1.36.0`, `busybox:1.36.1`, `boky/postfix:5.1.0`, `caddy:2.11.4-builder`, and `caddy:2.11.4-alpine` expose amd64 and arm64 variants. This does not prove the unpinned Caddy plugin build chain; see F-03. |
| GitHub Actions branch status | Informational | Recent visible branch runs were for older commits. `gh run list --commit 2837fc1cddb7dda4ce6e156e4e95c5355d506f3a` returned no runs. |

Observed local tool versions:

- Docker: `Docker version 29.6.1`
- ShellCheck: `0.11.0`
- `yq`: `v4.53.3`
- `sops`: `3.13.2`
- `age`: `v1.3.1`
- `gh`: `2.96.0`

The failing test output included:

```text
AGENTS.md:130:Repository, package, and dependency installation paths must be checked for Jammy/Noble differences.
FAIL: active content contains shorthand confirmation prompt: y/N
FAIL tests/test-operator-ui.sh (exit 1)
```

Image manifest platform summaries:

| Image tag | Manifest platforms observed |
| --- | --- |
| `ghcr.io/dani-garcia/vaultwarden:1.36.0` | `amd64`, `arm/v6`, `arm/v7`, `arm64` |
| `busybox:1.36.1` | `386`, `amd64`, `arm/v5`, `arm/v6`, `arm/v7`, `arm64/v8`, `ppc64le`, `riscv64`, `s390x` |
| `boky/postfix:5.1.0` | `386`, `amd64`, `arm/v7`, `arm64`, `ppc64le`, `s390x` |
| `caddy:2.11.4-builder` | `amd64`, `arm/v6`, `arm/v7`, `arm64/v8`, `ppc64le`, `riscv64`, `s390x` |
| `caddy:2.11.4-alpine` | `amd64`, `arm/v6`, `arm/v7`, `arm64/v8`, `ppc64le`, `riscv64`, `s390x` |

## Environment and Runtime Validation Limits

This audit ran from a local Codex workspace, not from a fresh Ubuntu production host. Static shell tests and compose rendering are valuable, but they cannot prove:

- Apt repository behavior on Jammy and Noble.
- Docker CE repository behavior on amd64 and arm64.
- Caddy custom image build success across architectures.
- systemd unit behavior across reboots.
- UFW/nftables/iptables behavior on real Ubuntu kernels.
- CrowdSec package/bouncer behavior on real hosts.
- rclone remote behavior and failure email delivery.
- Real backup/restore/recover correctness with production-sized data.
- Real block-volume formatting, mount ordering, and migration interruption behavior.

Because this repo is a production appliance, final acceptance must include real host drills after F-01 through F-03 are fixed.

## Supported Host Matrix Assessment

| Supported host | Static confidence at this HEAD | Blocking concern | Required acceptance validation |
| --- | --- | --- | --- |
| Ubuntu 22.04 Jammy amd64 | Medium | F-01, F-02, F-03 | Fresh setup, Docker apt repo, universe enablement, custom Caddy build, systemd install, backup/restore/recover drill. |
| Ubuntu 22.04 Jammy arm64 | Medium-low | F-01, F-02, F-03 | Same as above, plus arm64 Caddy custom build and CrowdSec bouncer validation. |
| Ubuntu 24.04 Noble amd64 | Medium | F-01, F-03 | Fresh setup, custom Caddy build, systemd install, backup/restore/recover drill. |
| Ubuntu 24.04 Noble arm64 | Medium-low | F-01, F-03 | Same as above, plus arm64 Caddy custom build and CrowdSec bouncer validation. |

The static review supports the shape of the matrix but not a final green claim. Published base image manifests support amd64 and arm64, but the full stack is only as reproducible as the custom build and host setup paths.

## Ubuntu 22.04 / 24.04 Portability Assessment

The repo explicitly defines Jammy and Noble as the supported Ubuntu path. Most setup code follows host-derived values, but the `universe` fallback in `utilities/setup-system.sh` still uses `lsb_release -cs || echo "noble"` and writes an apt source from that value. That can configure the wrong repository on a minimal Jammy host where `lsb_release` is unavailable or broken.

This is the only Ubuntu-release portability blocker found in static review, but it is significant because it sits on first-run dependency installation. The correct contract is fail-closed release detection from `/etc/os-release` with explicit support for only Ubuntu 22.04/Jammy and 24.04/Noble.

## amd64 / arm64 Portability Assessment

Positive static signals:

- `docker-compose.yml.example` contains no `platform:` pin that would force amd64 on arm64.
- Published base image manifests for Vaultwarden, BusyBox, Postfix, and Caddy include amd64 and arm64 variants.
- SOPS artifact selection in `utilities/setup-system.sh` returns `amd64` and `arm64` directly and fails for unsupported release architectures.
- Cloudflare Worker bouncer tarball mapping in `utilities/setup-crowdsec.sh` supports `amd64`/`x86_64` and `arm64`/`aarch64`, and skips tarball fallback rather than silently downloading the wrong architecture.

Blocking static signal:

- The custom Caddy Dockerfile pins `CADDY_VERSION=2.11.4`, but the `xcaddy --with` module specs are unversioned. The base image is multi-arch; the custom module build graph is not pinned or proven for amd64/arm64. See F-03.

## Cloud-Provider Neutrality Assessment

No executable dependency on OCI CLI, OCI APIs, OCI instance principals, OCI metadata endpoints, OCI security-list APIs, AWS metadata, Azure metadata, Google metadata, or provider IAM was found in the production scripts.

Provider-neutral positives:

- Storage code uses operator-supplied/stable paths and does not require `/dev/oracleoci/...`.
- The main deployment guide uses provider-neutral firewall wording and demotes OCI Security Lists to an explicit note.
- The firewall script has a conditional cleanup for an OCI-style host `FORWARD REJECT` rule, but it only checks/removes a local iptables rule if present. It does not call OCI APIs or make OCI a runtime prerequisite.
- `maintenance-update-dns.sh` uses `https://checkip.amazonaws.com` as a public IP echo endpoint, not AWS metadata or IAM.

Provider-neutral drift:

- `RUNBOOK.md` line 12 says "Configure OCI Security List" as a universal first-time setup step. See F-04.

## Repository-Wide Entry Point Inventory

| Entry point category | Representative paths | Static assessment |
| --- | --- | --- |
| Root setup | `setup.sh`, `utilities/setup-system.sh`, `utilities/setup-env.sh`, `utilities/setup-secrets.sh`, `utilities/setup-firewall.sh`, `utilities/setup-storage.sh` | Coherent overall; F-02 blocks release-portable dependency setup. |
| Lifecycle | `startup.sh`, `Makefile`, `utilities/safe-restart.sh`, `utilities/maintenance-health.sh` | Operation guard integration and health semantics look sound in static review. |
| Backup | `backup.sh`, `utilities/backup-run.sh`, `lib/backup-utils.sh` | Three-tier model and metadata handling are coherent; real restore validation still required. |
| Restore/recovery | `restore.sh`, `recover.sh`, `utilities/restore-run.sh` | Recovery commit boundary and post-commit failure messaging are explicit. |
| Secrets/key management | `edit-secrets.sh`, `utilities/secrets-*.sh`, `utilities/key-rotate.sh`, `lib/secrets.sh`, `lib/crypto.sh` | Static structure is strong; no production secrets used. |
| Storage/migration | `utilities/setup-storage.sh`, `lib/storage.sh`, `lib/migrate.sh` | Parser and safety tests are consolidated and pass before the later operator UI failure. |
| Systemd | `utilities/setup-systemd.sh`, `systemd/*.service`, `systemd/*.timer` | Static hardening checks and tests pass; real systemd validation remains mandatory. |
| CrowdSec/firewall | `utilities/setup-crowdsec.sh`, `utilities/setup-firewall.sh`, `utilities/maintenance-update-firewall.sh`, `crowdsec/*` | Architecture mapping is fail-closed; live package/bouncer/firewall behavior requires host testing. |
| Operator UI/docs | `Makefile`, `dashboard.sh`, `RUNBOOK.md`, `docs/*`, `docs/COMMAND-REFERENCE.md` | Command reference deterministic; F-01 and F-04 affect final confidence. |

## Cross-PR Integration Review

Historical concerns that appear closed in the current code:

- Operation global lock release no longer explicitly unlocks the inherited global FD. `operation_release` closes the descriptor and lets the kernel release the flock after the last inherited descriptor closes.
- Package-manager child detection includes `add-apt-repository` and `apt-add-repository`.
- Recovery now sets `RECOVERY_COMMITTED=true` only after promoted identity/config validation and file mode normalization.
- Recovery startup/health failures after commit are reported as committed-but-unhealthy states, not rolled-back successes.
- `maintenance-db-maint.sh` places success messages inside the positive health branch and warns when the restarted service does not become healthy.
- Storage setup/migration parsing now has explicit tests proving CLI arguments win over loaded environment defaults.
- Permanent tests are consolidated under `tests/run-tests.sh all`; stale PR-named top-level tests have been removed.
- Command-reference generation is deterministic in this workspace.
- Postfix no longer claims a read-only root filesystem; the compose file documents that upstream `boky/postfix` mutates `/scripts` and keeps other hardening controls.

Cross-component risks that remain:

- A docs-only `AGENTS.md` update can break the canonical local test suite while bypassing current workflow path filters. See F-01.
- First-run host setup still has release fallback behavior that conflicts with the newly explicit Jammy/Noble contract. See F-02.
- The Caddy pinning docs and compose comments imply reproducibility that the Dockerfile does not fully implement. See F-03.

## Findings

### F-01 - Canonical test runner fails because prompt-format scan treats `Jammy/Noble` as `y/N`

Severity: Medium

Confidence: High

Area: Tests, CI, operator UI regression coverage

Affected files:

- `tests/test-operator-ui.sh:357-401`
- `AGENTS.md:130`
- `tests/run-tests.sh:26-42`
- `.github/workflows/doc-drift.yml:3-18`
- `.github/workflows/doc-drift.yml:174-194`

Affected supported entry point(s):

- `bash tests/run-tests.sh all`
- GitHub Actions `functional-tests` job when triggered
- Any final production-readiness gate that requires the canonical test runner

Execution path:

1. `bash tests/run-tests.sh all`
2. `tests/test-operator-ui.sh`
3. `check_confirmation_prompt_format`
4. Raw fixed-string recursive grep for `y/N`
5. Match on `AGENTS.md:130` text `Jammy/Noble`
6. Test exits 1

Contract expected:

The permanent test suite should reject actual shorthand confirmation prompts while allowing unrelated words or support-matrix terms. A docs-only change should not create a false prompt failure, and CI should cover files that the test intentionally scans.

Current behavior:

Current `delta` HEAD fails the canonical required validation command. The failure is not caused by macOS, Docker, ShellCheck, or missing test dependencies. It is caused by the repository's own raw substring scan matching `y/N` inside `Jammy/Noble`.

Evidence:

- `tests/test-operator-ui.sh:363-370` builds fixed-string patterns including `y/N`.
- `tests/test-operator-ui.sh:374-384` scans the full repository root.
- `tests/test-operator-ui.sh:392-395` treats any match as failure.
- `AGENTS.md:130` contains `Repository, package, and dependency installation paths must be checked for Jammy/Noble differences.`
- `tests/run-tests.sh:39` includes `tests/test-operator-ui.sh` in the canonical suite.
- `.github/workflows/doc-drift.yml:192-194` calls `./tests/run-tests.sh all`.
- `.github/workflows/doc-drift.yml:3-18` does not include `AGENTS.md` in the pull-request path filter.
- `gh run list --commit 2837fc1cddb7dda4ce6e156e4e95c5355d506f3a` returned no workflow runs.

Realistic trigger:

Any future support-matrix documentation using `Jammy/Noble`, or any other word containing one of the raw substrings, can fail the full suite even when no shorthand confirmation prompt exists. Conversely, an AGENTS-only change can bypass GitHub Actions but leave the canonical suite broken on `delta`.

Production/operator impact:

This does not directly break a production host, but it blocks the final validation gate and undermines confidence in the consolidated test suite. A branch that cannot pass its own permanent runner should not be labeled production-ready.

Cross-PR or cross-component interaction:

PR #230 and nearby work consolidated tests and made `tests/run-tests.sh all` the canonical entry point. The later `AGENTS.md` update introduced a support-matrix phrase that the broad operator prompt scan treats as a failure. The workflow path filter then allowed the final commit to have no validating Actions run.

Why existing tests/CI did not prevent or expose it:

The test itself exposes the issue locally, but CI did not run for the audited `AGENTS.md`-only HEAD because the pull-request path filter omits `AGENTS.md`. The test also lacks a fixture proving that allowed support-matrix text such as `Jammy/Noble` is not a prompt.

Minimal fix direction:

Make the prompt-format scan context-aware. For example, scan only operator-facing scripts/docs that can actually present prompts, or use a regex that matches real prompt syntax such as bracketed/default prompt contexts rather than arbitrary substrings inside words. If the test intentionally scans `AGENTS.md`, include `AGENTS.md` in the workflow path filter.

Focused regression recommendation:

Add a focused test fixture or inline check that allows `Jammy/Noble` and rejects an actual prompt such as `Continue? [y/N]`. Then rerun `bash tests/run-tests.sh all` and confirm the suite passes on current content.

Scope-pressure note:

Do not replace the shell test suite or add a test framework for this. This is a narrow scan/fixture correction.

### F-02 - Ubuntu `universe` fallback silently defaults unresolved codename to `noble`

Severity: Medium

Confidence: High

Area: Host setup, Ubuntu 22.04/24.04 portability, dependency installation

Affected files:

- `utilities/setup-system.sh:214-216`
- `utilities/setup-system.sh:377-405`
- `tests/test-architecture.sh:35-48`
- `AGENTS.md:95-105`

Affected supported entry point(s):

- `sudo ./setup.sh install --domain <fqdn> --email <admin-email> --auto`
- Direct use of `sudo ./utilities/setup-system.sh`
- First-run setup on minimal Jammy/Noble hosts

Execution path:

1. First-run dependency installation enters `install_dependencies`.
2. `universe` is not already present.
3. `add-apt-repository` is absent or fails.
4. Fallback runs `codename=$(lsb_release -cs 2>/dev/null || echo "noble")`.
5. The script writes `deb ${archive_url} ${codename} universe` to `/etc/apt/sources.list.d/ubuntu-universe.list`.
6. `apt-get update` runs against the potentially wrong Ubuntu release.

Contract expected:

Host setup must support both Ubuntu 22.04 Jammy and Ubuntu 24.04 Noble, must not silently assume one release, and must fail clearly when release detection is unavailable or unsupported.

Current behavior:

The fallback path can configure a Noble universe source when the actual host is Jammy or when the host release is unresolved. `install_docker` uses `/etc/os-release` for Docker codename, but the universe fallback uses `lsb_release` and defaults to `noble`.

Evidence:

- `AGENTS.md:97-104` states the normal path must work on Jammy and Noble and must not silently assume one release.
- `utilities/setup-system.sh:214-216` reads Docker codename from `/etc/os-release`.
- `utilities/setup-system.sh:389` and `utilities/setup-system.sh:399` default unresolved `lsb_release -cs` to `noble`.
- `utilities/setup-system.sh:391-392` and `utilities/setup-system.sh:401-402` write the resulting codename into an apt source.
- `tests/test-architecture.sh:35-48` covers archive URL and SOPS artifact arch helpers, but not Jammy/Noble release detection or the `lsb_release` fallback.

Realistic trigger:

A minimal Ubuntu 22.04 host lacks `lsb_release`, has a broken `lsb_release`, or hits the manual fallback after `add-apt-repository` fails. The script then writes a Noble repository on a Jammy system.

Production/operator impact:

Wrong-release apt sources can break setup, mix repositories, or create a host state that is difficult for a junior operator to diagnose. This directly blocks a truthful Jammy/Noble production support claim.

Cross-PR or cross-component interaction:

The final `AGENTS.md` update made the Jammy/Noble portability contract more explicit, while the setup fallback still carries a Noble default. The test suite added architecture checks but did not add release fixture coverage.

Why existing tests/CI did not prevent or expose it:

The current tests exercise architecture mapping but not supported Ubuntu release detection. There is no fixture for `/etc/os-release`, no fixture for absent `lsb_release`, and no assertion that unsupported or unresolved releases fail closed.

Minimal fix direction:

Add a small local helper in `utilities/setup-system.sh` that reads `/etc/os-release`, verifies `ID=ubuntu`, accepts only `VERSION_ID=22.04`/`VERSION_CODENAME=jammy` or `VERSION_ID=24.04`/`VERSION_CODENAME=noble`, and fails closed when unresolved. Use that helper for Docker repository setup and universe fallback. Avoid a broad OS abstraction.

Focused regression recommendation:

Add tests with fixture data for Jammy, Noble, missing codename, unsupported Ubuntu release, and absent `lsb_release`. Assert that Jammy renders Jammy, Noble renders Noble, and unresolved/unsupported releases fail rather than defaulting.

Scope-pressure note:

Do not expand the support matrix. The fix should enforce the existing narrow Ubuntu contract.

### F-03 - Caddy base image is pinned, but `xcaddy` plugin modules are unpinned

Severity: Medium

Confidence: High

Area: Container build reproducibility, amd64/arm64 portability, supply-chain control

Affected files:

- `caddy/Dockerfile:13-23`
- `docker-compose.yml.example:206-214`
- `.env.example:53-58`
- `.github/workflows/doc-drift.yml:105-127`

Affected supported entry point(s):

- `docker compose build caddy`
- `sudo make up` or startup flows on hosts where the custom Caddy image must be built
- Update/rebuild procedures that rebuild Caddy from the Dockerfile

Execution path:

1. Compose builds service `caddy` from `./caddy/Dockerfile`.
2. Dockerfile pins `ARG CADDY_VERSION=2.11.4`.
3. Builder image is `caddy:${CADDY_VERSION}-builder`.
4. `xcaddy build` runs with four `--with github.com/...` module specs that have no `@version` or commit.
5. Future builds can resolve different module versions without any repository change.

Contract expected:

A production appliance should produce reproducible custom Caddy builds. The pinned Caddy base image and the module graph should be versioned together, and the amd64/arm64 support claim should apply to the actual custom binary build, not only the upstream base images.

Current behavior:

The base Caddy image is pinned, but the plugin modules float at whatever module versions resolve at build time. The compose comment says `xcaddy builds must be pinned`, but the Dockerfile only pins the base Caddy version.

Evidence:

- `caddy/Dockerfile:13` pins `ARG CADDY_VERSION=2.11.4`.
- `caddy/Dockerfile:15` uses `caddy:${CADDY_VERSION}-builder`.
- `caddy/Dockerfile:17-21` uses unversioned `--with github.com/caddy-dns/cloudflare`, `github.com/WeidiDeng/caddy-cloudflare-ip`, `github.com/fvbommel/caddy-combine-ip-ranges`, and `github.com/mholt/caddy-ratelimit`.
- `docker-compose.yml.example:210-214` says the version is pinned and `xcaddy builds must be pinned`.
- `.env.example:53-58` pins image tags including `CADDY_VERSION=2.11.4`.
- `.github/workflows/doc-drift.yml:105-127` checks some unpinned shell references but does not reject unversioned `xcaddy --with` module specs.
- Manifest inspection showed `caddy:2.11.4-builder` and `caddy:2.11.4-alpine` support amd64 and arm64/v8, but that does not pin or build the plugin graph.

Realistic trigger:

A production host rebuilds Caddy days or weeks after the audit. A plugin module changes, removes compatibility, changes transitive dependencies, or fails on arm64. The repository commit is unchanged, but the resulting Caddy binary differs from the audited behavior or fails to build.

Production/operator impact:

Setup or update can fail during Caddy build, or can produce an unreviewed Caddy binary. This weakens both reproducibility and the amd64/arm64 support claim for the actual reverse-proxy component.

Cross-PR or cross-component interaction:

Recent work improved version pinning and command reference determinism. The Caddy Dockerfile still has a floating module graph, while docs/comments imply that the custom build is pinned. CI does not build the image or statically reject unversioned module specs.

Why existing tests/CI did not prevent or expose it:

The unpinned-version CI check scans shell scripts and selected `.env.example` CrowdSec values, but not `caddy/Dockerfile`. The local compose config check renders YAML only; it does not build Caddy. Manifest inspection proves base-image availability, not custom plugin build reproducibility.

Minimal fix direction:

Pin each `xcaddy --with` module to a tag or commit known to work with Caddy `2.11.4`, document the update procedure, and add a lightweight static CI/test guard that rejects unversioned `--with github.com/...` module specs.

Focused regression recommendation:

Add a test that parses `caddy/Dockerfile` and fails if any `xcaddy --with github.com/...` argument lacks `@<version-or-commit>`. For production acceptance, build the Caddy image on amd64 and arm64 and run `caddy list-modules` or equivalent to confirm expected modules are present.

Scope-pressure note:

Do not add a plugin registry, dependency dashboard, or generic build orchestration. Pin the four existing modules and test the narrow invariant.

### F-04 - Quick runbook presents OCI Security List as universal first-time prerequisite

Severity: Low

Confidence: High

Area: Documentation, cloud-provider neutrality, junior-operator guidance

Affected files:

- `RUNBOOK.md:10-13`
- `docs/DEPLOYMENT.md:18-27`
- `AGENTS.md:240-298`

Affected supported entry point(s):

- Human first-time setup from `RUNBOOK.md`
- Provider-neutral support claim

Execution path:

1. Operator opens the quick runbook for first-time setup.
2. Step 1 says `Configure OCI Security List (ports 80, 443, and 22)`.
3. A non-OCI operator sees an OCI-specific prerequisite presented as universal.

Contract expected:

Universal docs should say provider firewall/security group/network firewall, with OCI details clearly marked as provider-specific notes or examples.

Current behavior:

The deployment guide uses the correct generic wording and an OCI note, but the quick runbook still states an OCI Security List as the first universal setup step.

Evidence:

- `AGENTS.md:240-254` states that the project name is historical and supported hosts include OCI, AWS, Azure, Google Cloud, other VMs, private virtualization, and physical Ubuntu.
- `AGENTS.md:273-298` allows provider-specific examples only when clearly identified as notes.
- `docs/DEPLOYMENT.md:18-27` uses "provider firewall/security group/router" and then has an explicit OCI note.
- `RUNBOOK.md:10-13` says "Configure OCI Security List" without qualifying it as an OCI-specific example.

Realistic trigger:

A junior operator on AWS, Azure, GCP, a private VM, or a physical Ubuntu host starts with `RUNBOOK.md` and assumes OCI is required or that the runbook does not apply.

Production/operator impact:

This is unlikely to break code, but it weakens the support boundary and onboarding clarity.

Cross-PR or cross-component interaction:

The final repository instructions strengthened provider-neutrality language. Most docs already comply, but the quick runbook was not fully aligned.

Why existing tests/CI did not prevent or expose it:

There is no documentation lint for universal OCI-specific phrasing. Existing tests include acceptable OCI examples in provider notes and CrowdSec comments, but not a runbook wording rule.

Minimal fix direction:

Change the first runbook step to "Configure your provider firewall/security group/network firewall for ports 80, 443, and restricted SSH 22" and optionally add an OCI note beneath it.

Focused regression recommendation:

No broad doc linter is necessary. A narrow grep-style test could reject `Configure OCI Security List` in universal quick-start sections if this drift recurs.

Scope-pressure note:

Do not add cloud-provider adapters or provider-specific automation. This is a wording fix.

## Test Consolidation Coverage Assessment

The consolidation into `tests/run-tests.sh all` is directionally strong. The runner inventories 15 permanent suites:

- `tests/test-architecture.sh`
- `tests/test-security-privileges.sh`
- `tests/test-permissions.sh`
- `tests/test-config-env.sh`
- `tests/test-secrets.sh`
- `tests/test-operations.sh`
- `tests/test-lifecycle.sh`
- `tests/test-systemd.sh`
- `tests/test-email.sh`
- `tests/test-storage-setup.sh`
- `tests/test-backup.sh`
- `tests/test-restore-recovery.sh`
- `tests/test-operator-ui.sh`
- `tests/test-crowdsec.sh`
- `tests/test-uninstall.sh`

The runner also rejects duplicate inventory entries and unlisted top-level `test-*.sh` files. This is a good permanent-test contract.

Coverage strengths:

- Architecture helper tests cover amd64/arm64 SOPS and CrowdSec bouncer mappings.
- Storage setup tests cover parse order, CLI precedence over loaded env, destructive gates, and metadata/help behavior.
- Restore/recovery tests cover many historical restore safety contracts.
- Operation tests cover shared guard behavior.
- Systemd tests cover hardening and runtime path contracts.
- Uninstall tests now cover firewall/test-reset cleanup paths.
- Operator UI tests cover help/version and confirmation prompt conventions.

Coverage gaps:

- F-01: prompt-format scan has no allowed-text fixture and scans too broadly.
- F-02: no supported Ubuntu release detection fixtures.
- F-03: no Dockerfile check for unpinned `xcaddy --with` modules and no CI image build.
- CI path filters omit `AGENTS.md` despite tests scanning it.

## Security and Secrets Assessment

Static result: Green, with normal production-host validation still required.

Positive signals:

- Persistent secrets are SOPS/Age encrypted.
- Runtime Docker secret source files live under `/run/vaultwarden-oci/secrets` and are recreated by startup.
- Compose uses Docker secret files for sensitive values.
- Vaultwarden and Caddy drop all capabilities except required narrow grants; both use `no-new-privileges`.
- Vaultwarden and Caddy use `read_only: true`.
- Postfix intentionally does not use `read_only: true` because the upstream image mutates `/scripts`, and the compose file documents the tradeoff while retaining tmpfs and capability limits.
- Emergency/recovery key material paths are documented and tested statically.

Limits:

- No real SOPS/Age production secret rotation was performed.
- No real Cloudflare, SMTP, or rclone secrets were injected.
- No live container runtime inspection was performed.

## Backup / Restore / Recovery Assessment

Static result: Green, with required live drills.

The backup model remains a deliberate three-tier design: database rollback, full disaster recovery, and clone-grade emergency capsule. The recovery path now has a clearer transaction boundary:

- `recover.sh` validates promoted identity/config before setting `RECOVERY_COMMITTED=true`.
- Startup failures after commit are reported as committed recovery artifacts with failed startup, not as rollback-safe failures.
- Health failures after commit explicitly tell the operator not to treat the service as healthy.
- Signal handling exits through cleanup rather than accidentally continuing.

No new static restore/recovery defect was found. Real acceptance still needs actual db restore, full restore, emergency restore, and offline Age key recovery drills.

## Operation Guard and Interruption Assessment

Static result: Green.

Positive signals:

- Shared operation lock state is centralized in `lib/operations.sh`.
- `operation_release` closes the global lock descriptor instead of explicitly unlocking it, preserving inherited-lock semantics for nested mutating children.
- Package-manager child detection includes `apt`, `apt-get`, `dpkg`, `unattended-upgrade`, `add-apt-repository`, and command-line checks.
- Operation status and conflict messaging remain operator-facing and descriptive.
- Interruption-sensitive workflows are covered by the consolidated tests.

No new operation guard or interruption finding was identified.

## Storage / Migration / Uninstall Assessment

Static result: Green for storage/migration/uninstall logic, Yellow for first-run host setup portability because of F-02.

Positive signals:

- Storage setup validates the configured state path before creating data directories.
- Separate volume mode aligns `PROJECT_STATE_DIR` with the mounted data volume.
- Existing tests prove canonical and compatibility CLI grammar, migration mode precedence, and environment-load behavior.
- Storage guidance prefers stable operator-supplied paths such as `/dev/disk/by-id/...`.
- Uninstall/test-reset coverage is now consolidated and broad.

Remaining host-level concern:

- The `universe` repository fallback can still configure the wrong Ubuntu release. That is setup-system portability, not a storage migration logic defect, but it affects first-run production readiness.

## Systemd and Automation Assessment

Static result: Green with host validation required.

Positive signals:

- Static systemd hardening tests passed as part of the runner before the later operator UI failure.
- Units use explicit read/write paths and runtime directories where needed.
- Root-required units are documented as root-required.
- Service-user detection in `utilities/setup-systemd.sh` prefers explicit `SERVICE_USER`, then `SUDO_USER`, then a real non-root account, avoiding a hard-coded `ubuntu`/`opc` production dependency.
- Failure notification services are explicitly root-operated.

Limits:

- No `systemctl enable`, `systemctl start`, timer run, reboot, or `systemd-analyze verify` acceptance was performed on a real Ubuntu host.
- GitHub Actions did not validate the audited HEAD.

## Operator CLI / Make / Dashboard Assessment

Static result: Green/Yellow.

Positive signals:

- CLI help/version contracts are now inventoried in permanent tests.
- Removed developer Make wrappers are guarded against stale references.
- Command reference generation is deterministic.
- `maintenance-db-maint.sh` no longer prints completion success after health failure.
- Dashboard and Make targets are narrower than the earlier historical reports and align better with root-operated production flows.

Yellow reason:

- The operator UI test suite currently fails because the prompt-format scan is too broad. This is a test false positive, but it blocks the canonical gate.

## Documentation and Generated Reference Assessment

Static result: Yellow.

Positive signals:

- `docs/COMMAND-REFERENCE.md` regenerated deterministically with no diff on repeated generation.
- Most docs now describe provider firewall/security group behavior generically.
- Deployment guide uses an explicit OCI note instead of making OCI universal.
- Historical PR-specific test names and stale command references were consolidated.

Remaining issues:

- F-04: quick runbook first-time setup still says "Configure OCI Security List" as universal wording.
- CI path filters omit `AGENTS.md`, even though a test currently scans the full repo and failed on `AGENTS.md`.

## Production-Host Acceptance Validation Items

Run these after F-01 through F-03 are fixed. These are practical acceptance items for an OCI VM, but the wording and pass/fail signals should apply to any supported provider.

| # | Validation item | Success signal | Failure signal |
| --- | --- | --- | --- |
| 1 | Fresh Ubuntu 22.04 Jammy amd64 setup | `setup.sh install` completes, apt sources use Jammy, compose renders, services start. | Wrong-release apt source, dependency install failure, Docker repo mismatch. |
| 2 | Fresh Ubuntu 24.04 Noble amd64 setup | `setup.sh install` completes, apt sources use Noble, compose renders, services start. | Dependency install failure or unsupported release confusion. |
| 3 | At least one fresh arm64 setup, preferably Jammy and Noble | Same as amd64, on arm64. | Wrong architecture artifact, package unavailability, compose image failure. |
| 4 | Custom Caddy build on amd64 and arm64 | `docker compose build caddy` succeeds and expected modules are present. | `xcaddy` module resolution/build failure or missing module. |
| 5 | systemd install and reboot smoke | Timers/services enable, reboot recreates runtime secrets, health passes. | Missing runtime dirs, permission failure, unhealthy service after boot. |
| 6 | Operation guard contention drill | Concurrent mutating operations serialize or return expected conflict/skip result. | Overlap, stale metadata confusion, unsafe termination prompt. |
| 7 | Database backup and verify | DB backup completes, metadata valid, restore verification passes. | Corrupt snapshot, metadata missing, verification skipped. |
| 8 | Full backup and inspect | Full archive contains expected state and excludes live/transient secrets. | Missing required restore material or included decrypted runtime secrets. |
| 9 | Emergency backup decrypt drill | Offline key decrypts emergency capsule in a controlled drill. | Offline key cannot decrypt or required files missing. |
| 10 | Database restore drill | Restore completes, Vaultwarden starts, health passes, expected data present. | Incomplete restore presented as success or health failure hidden. |
| 11 | Full restore drill on fresh VM | Fresh host recovers with documented key material and health passes. | Storage/config mismatch, missing Age key, unclear post-restore repair. |
| 12 | `recover.sh` offline Age recovery drill | Committed recovery reaches startup/health or clearly reports committed unhealthy state. | Rollback after commit, ambiguous success, lost key/config material. |
| 13 | Age key rotation/recovery kit export | New recipients work, old paths are handled as documented, recovery kit is usable. | Ciphertext cannot be decrypted by intended recipient. |
| 14 | Block-volume setup/migration/resume drill | Stable device path, sentinel, fstab UUID, and mount ordering behave correctly. | Writes state to boot volume when mount missing or resumes unsafe state. |
| 15 | Safe restart and rollback drill | Restart failure rolls back or reports exact manual action; healthy restart passes. | Service left down with success output. |
| 16 | CrowdSec/firewall bouncer install | Package/bouncer installs on host arch, nftables/iptables path selected correctly, decisions flow. | Wrong arch, unsupported firewall backend, no LAPI/bouncer communication. |
| 17 | Failure email/recovery kit notification | Expected message and attachment route succeeds through configured mail path. | Silent notification failure or malformed attachment. |
| 18 | Normal uninstall and `--test-reset` clean reinstall | Uninstall removes intended project state only; reinstall succeeds from clean state. | Residual firewall/systemd/runtime state breaks reinstall or unrelated host data touched. |

## Rejected Overengineering / Scope Pressure

The findings do not justify broad redesign.

- Do not add a new test framework to fix F-01; make the scan precise and add a small fixture.
- Do not expand OS support to Debian or non-LTS Ubuntu to fix F-02; fail closed to the current Jammy/Noble contract.
- Do not add a generic plugin dependency manager for F-03; pin the four existing `xcaddy` modules and test the invariant.
- Do not add cloud-provider automation for F-04; correct the wording and keep provider firewall setup as an operator prerequisite.
- Do not convert the shell appliance into a framework, workflow engine, or orchestrator.

## Final Verdict

Final static verdict: YELLOW.

The branch is close, but it is not production-ready at the audited HEAD. The current canonical test runner fails, first-run Ubuntu release fallback can violate Jammy/Noble portability, and the custom Caddy build is not reproducible because plugin modules are unpinned. Fix F-01, F-02, and F-03 before claiming production readiness or starting final host acceptance. Fix F-04 before presenting the runbook as provider-neutral operator guidance.

After those fixes, rerun:

```bash
git diff --check
find . -type f -name '*.sh' | xargs bash -n
find . -type f -name '*.sh' | xargs shellcheck -x --severity=warning
bash tests/run-tests.sh all
docker compose --env-file .env.example -f docker-compose.yml.example config --quiet
DOCKER_PROJECT_LABEL=ci bash utilities/write-command-reference.sh
git diff --exit-code -- docs/COMMAND-REFERENCE.md
```

Then perform the production-host acceptance items above on the supported matrix before calling this ready for a real Vaultwarden deployment.
