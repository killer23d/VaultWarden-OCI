# Post-PR #230 Final Production Readiness Audit

## Executive Summary

YELLOW - targeted fixes are required before this branch should be treated as production-ready or before final production-host acceptance is meaningful.

This correction pass did not restart the full repository audit. It started from the existing final report, refreshed `delta`, confirmed that no production code changed after the original audit baseline, then re-inspected the specific missed-scope items requested for the Noble-only support decision.

The supported production host contract is now:

> Supported on Ubuntu 24.04 LTS Noble, on amd64 and arm64, on a provider-neutral Ubuntu host meeting the documented networking and storage prerequisites.

Cloudflare remains mandatory as the edge/DNS/proxy/WAF provider. Ubuntu 22.04 is no longer a supported production target for this report. The current `AGENTS.md` operating-system matrix is stale and must be corrected in the bounded follow-up PR; this report intentionally does not edit it.

The corrected audit found four medium-severity blockers and one low-severity documentation/support-contract drift item:

| ID | Severity | Summary |
| --- | --- | --- |
| F-01 | Medium | The canonical readiness runner fails because the prompt-format scan recursively scans prose and reports, not just operator prompt surfaces. |
| F-02 | Medium | Noble-only host setup is not fail-closed: unsupported or unresolved hosts can still enter Docker/universe apt repository rendering. |
| F-03 | Medium | Required production dependency outputs are not reproducible: unpinned `xcaddy` modules and default-latest SOPS can change without a repository commit. |
| F-04 | Medium | The production schema dependency contract is split across apt `python-yq`, CI Mike Farah `yq`, and unowned PyYAML installation. |
| F-05 | Low | Active operator guidance still contains stale OS/provider support-contract wording. |

No critical or high-severity defects were found. The final static verdict is still YELLOW because F-01 through F-04 block a truthful readiness/support claim before host acceptance.

## Final Static Ship Recommendation

Do not ship current `delta` as production-ready yet. Make one bounded follow-up PR that closes the Noble host dependency and readiness-gate contract:

- fail closed on Ubuntu host detection before apt repository mutation;
- make required dependency versions and implementations deterministic enough for production acceptance;
- align production and CI for `yq`, SOPS, PyYAML, and Caddy module checks;
- narrow the prompt-format scan to real operator prompt surfaces;
- update active support-contract docs for Noble-only, amd64/arm64, provider-neutral host, and Cloudflare-first edge wording.

After that PR, rerun the canonical local validation suite and perform production-host acceptance on Noble amd64 and Noble arm64.

| Area | Static recommendation | Reason |
| --- | --- | --- |
| Security and secrets | Yellow | SOPS/Age structure remains coherent, but the yq/PyYAML dependency contract is not owned consistently. |
| Backup, restore, recovery | Green with host validation required | Code distinguishes emergency passphrase, emergency recipient, and offline SOPS/Age recovery; the report acceptance checklist was corrected. |
| Operation guard and interruption | Green | No new shared-lock or interruption defect was found. |
| Storage, migration, uninstall | Green/Yellow | Storage and uninstall logic remain strong; Noble host setup and dependency install still need closure. |
| Systemd and automation | Green with host validation required | Static evidence is good; real Noble service/timer validation remains mandatory. |
| Operator CLI, Make, dashboard | Yellow | CLI contracts are strong, but the canonical readiness runner is blocked by an overbroad prompt scan. |
| Tests and CI | Yellow | PR #230 exact head passed CI; later guidance/report commits did not have Actions runs, and local canonical validation currently stops in `test-operator-ui.sh`. |
| Documentation/generated reference | Yellow | Generated reference is not the blocker; active OS/provider support wording needs a bounded update. |
| Host portability | Yellow | Noble amd64/arm64 shape is plausible, but OS fail-closed behavior and dependency contracts block a final support claim. |

## Audit Baseline

- Repository: `https://github.com/killer23d/VaultWarden-OCI`
- Branch audited: `delta`
- Current report-correction HEAD: `bd8a5e773db7d3f97bc9c364918e6ca8b560c815`
- Current HEAD subject: `Add final production readiness audit`
- Original executable audit HEAD recorded by the previous report: `2837fc1cddb7dda4ce6e156e4e95c5355d506f3a`
- Original executable audit HEAD subject: `Update AGENTS.md`
- PR #230 merge commit: `2d151534c441cf857f6a8fa49f6c685f7d10b451`
- PR #230 final head SHA: `096e25f8e60dd286217e5b5270f6a8e6241bfb3b`
- Report correction date: 2026-07-07.

Baseline refresh performed:

```text
git fetch origin delta
git checkout delta
git pull --ff-only origin delta
git status --short
git branch --show-current
git rev-parse HEAD
git log --oneline --decorate -20
```

Result:

- `git status --short`: clean before report edits.
- `git branch --show-current`: `delta`.
- `git rev-parse HEAD`: `bd8a5e773db7d3f97bc9c364918e6ca8b560c815`.
- `git diff --name-status 2837fc1cddb7dda4ce6e156e4e95c5355d506f3a..HEAD`: only `reports/post-pr230-final-production-readiness-audit.md` was added.
- `git diff --stat 2837fc1cddb7dda4ce6e156e4e95c5355d506f3a..HEAD`: one report file, 740 inserted lines.
- `git log --oneline --decorate 2837fc1cddb7dda4ce6e156e4e95c5355d506f3a..HEAD`: only `bd8a5e7 Add final production readiness audit`.

Production code changed since original audit: no.

Exact report-correction baseline:

```text
current report-correction HEAD: bd8a5e773db7d3f97bc9c364918e6ca8b560c815
original executable audit HEAD: 2837fc1cddb7dda4ce6e156e4e95c5355d506f3a
production code changed since original audit: no
report-correction scope: report-only update to reports/post-pr230-final-production-readiness-audit.md
```

The diff from the PR #230 merge commit to the original audit HEAD changed only `AGENTS.md`. Therefore PR #230 executable-head CI evidence and later audited/report HEAD evidence must be kept separate.

## Architecture and Production Contracts Reconstructed from Current Code

The current repository remains a small-team, root-operated Vaultwarden appliance rather than a generic deployment framework.

The corrected normal production path is:

- Ubuntu 24.04 LTS Noble only.
- amd64 or arm64.
- Provider-neutral Ubuntu host execution.
- Cloudflare DNS/proxy/WAF and Caddy DNS-01 through Cloudflare.
- Vaultwarden, custom Caddy, Postfix sidecar, CrowdSec, SOPS/Age, rclone/offsite backup, and systemd timers/services.
- Root-operated lifecycle with operator-authored repo files and root-owned runtime state under `/var/lib/vaultwarden`, `/etc/vaultwarden`, and `/run/vaultwarden-oci`.
- Shared operation guard for mutating workflows.
- Storage modes are boot-volume state or an explicitly configured attached block/data volume with stable operator-supplied paths.

The corrected Noble-only host detection contract is:

```text
read /etc/os-release
require ID=ubuntu
require VERSION_ID=24.04 and/or codename noble
continue only after that succeeds
```

Any non-Ubuntu host, unresolved host, or unsupported Ubuntu release must fail clearly before writing apt repositories or performing meaningful host mutation.

## Scope and Method

This was a focused correction and missed-scope pass on the existing report. It was report-only work.

Performed:

- Refreshed `delta` to `origin/delta`.
- Read the existing report in full.
- Compared the original audit baseline to current `delta`.
- Re-inspected the requested dependency contracts for yq, PyYAML, and SOPS.
- Re-inspected Noble-only host release handling.
- Re-inspected emergency backup acceptance wording against implementation.
- Re-inspected active OS/provider support-contract documentation drift.
- Re-evaluated F-01 through F-04.
- Completed direct execution of the two test suites that the canonical runner does not reach.
- Added PR #230 exact-head GitHub Actions evidence.

Not performed:

- No production code fixes.
- No test fixes.
- No documentation edits outside this report.
- No branch, commit, push, or pull request.
- No real setup, restore, recovery, migration, sudo production workflow, production secret use, production Docker stack operation, storage formatting, systemd install/remove, rclone sync, or host firewall mutation.

## Validation Performed

| Validation | Result | Notes |
| --- | --- | --- |
| `git fetch origin delta` | Pass | Required network approval; `origin/delta` advanced to `bd8a5e7`. |
| `git checkout delta` | Pass | Worktree was clean before checkout. |
| `git pull --ff-only origin delta` | Pass | Required network approval; fast-forwarded local `delta`. |
| Baseline diff from `2837fc1...` to current HEAD | Pass | Only the report file was added; no production code changed. |
| PR #230 exact-head CI lookup | Pass | Run `28847717269`, workflow `Doc Drift Check`, event `pull_request`, head `096e25f8...`, conclusion `success`. |
| PR #230 jobs | Pass | `doc-drift`, `shellcheck`, and `functional-tests` all concluded `success`. |
| Runs for `2837fc1...` | None | `gh run list --commit 2837fc1...` returned no runs. |
| Runs for current `bd8a5e7...` | None | `gh run list --commit bd8a5e7...` returned no runs. |
| Official Noble package metadata | Pass | Ubuntu Noble `yq` package is `3.1.0-3`, architecture `all`, Homepage `https://github.com/kislyuk/yq`, depends on `python3-yaml`; same package paragraph observed for amd64 and arm64 metadata. |
| Disposable python-yq compatibility check | Mixed | `yq 3.1.0` ran current core schema filters successfully, but a direct call without raw output emits quoted Cloudflare conditional keys. |
| `PATH=/opt/homebrew/bin:$PATH /opt/homebrew/bin/bash tests/run-tests.sh all` | Fail | Stopped in `tests/test-operator-ui.sh` prompt-format scan before `tests/test-crowdsec.sh` and `tests/test-uninstall.sh`. |
| Direct `tests/test-crowdsec.sh` | Pass | `CrowdSec configuration tests passed.` |
| Direct `tests/test-uninstall.sh` | Pass with Bash 5 PATH | Initial invocation allowed a child `bash` to resolve to macOS Bash 3.2; rerun as `PATH=/opt/homebrew/bin:$PATH /opt/homebrew/bin/bash tests/test-uninstall.sh` passed. |

Canonical runner precision:

```text
tests/run-tests.sh order:
...
tests/test-restore-recovery.sh
tests/test-operator-ui.sh
tests/test-crowdsec.sh
tests/test-uninstall.sh
```

The canonical runner stopped in `tests/test-operator-ui.sh`; it did not execute CrowdSec or uninstall as part of that canonical run. Direct suite execution after the stop point:

```text
tests/test-crowdsec.sh: PASS
tests/test-uninstall.sh: PASS with Bash 5 PATH
```

The current prompt scan failure listed matches in both `AGENTS.md` and the old audit report itself under `reports/`, confirming that the root cause is the scan scope, not only a missing workflow path filter.

Package evidence source:

- `https://archive.ubuntu.com/ubuntu/dists/noble/universe/binary-amd64/Packages.xz`
- `https://ports.ubuntu.com/ubuntu-ports/dists/noble/universe/binary-arm64/Packages.xz`
- `https://packages.ubuntu.com/noble/python3-yaml`

## Environment and Runtime Validation Limits

This correction pass ran from a local Codex workspace, not from a fresh Ubuntu 24.04 production host.

Useful evidence gathered:

- current repository code;
- GitHub Actions metadata through `gh`;
- official Ubuntu Noble package metadata;
- disposable python-yq compatibility check;
- local Bash test execution with Bash 5.

Still not proven by this pass:

- real Noble apt behavior on clean amd64 and arm64 hosts;
- Docker CE repository behavior after fail-closed OS detection;
- custom Caddy image build success on both architectures;
- systemd service/timer behavior across reboot;
- UFW/nftables behavior on real Ubuntu kernels;
- CrowdSec package and bouncer behavior on real hosts;
- real backup, restore, emergency restore, storage migration, key rotation, and failure notification drills.

## Supported Host Matrix Assessment

| Supported host | Static confidence | Known blocker | Production-host validation required |
| --- | --- | --- | --- |
| Ubuntu 24.04 Noble amd64 | Medium | F-01, F-02, F-03, F-04 | Full production-host acceptance after targeted fixes. |
| Ubuntu 24.04 Noble arm64 | Medium-low | F-01, F-02, F-03, F-04 | Focused arm64 acceptance for architecture-sensitive dependencies plus at least one real backup/restore path. |

Ubuntu 22.04 is not part of the supported production matrix for this corrected report.

The static review supports the intended shape of Noble amd64 and Noble arm64, but not an unconditional production support claim yet. The blockers are dependency contract and readiness-gate issues, not evidence that the project should expand or preserve another OS target.

## Ubuntu 24.04 Noble Support Assessment

The old F-02 framing was obsolete. The defect is no longer that Jammy might receive a Noble repository. The corrected question is whether unsupported or unresolved hosts can be silently treated as Noble and enter production setup.

Current code does not satisfy the Noble-only fail-closed contract:

- `install_docker` reads `VERSION_CODENAME` from `/etc/os-release` but does not verify `ID=ubuntu`.
- `install_docker` does not verify `VERSION_ID=24.04` or codename `noble`.
- The Docker repository renderer can write a Docker Ubuntu source for whatever codename was present.
- The universe fallback uses `lsb_release -cs` and falls back to `noble` if that command is absent or fails.
- `ID`, `VERSION_ID`, `UBUNTU_CODENAME`, and unsupported Ubuntu versions are not coherently validated before apt repository mutation.

This is still a Medium blocker because a provider-neutral appliance should fail clearly before mutating apt state on non-Ubuntu, unsupported Ubuntu, or unresolved hosts.

The smallest correct fix direction is a local release-detection helper in `utilities/setup-system.sh` that reads `/etc/os-release`, accepts only Ubuntu 24.04/Noble, and is used by both Docker repository setup and universe repository fallback before apt writes occur.

## amd64 / arm64 Portability Assessment

Positive static signals:

- `docker-compose.yml.example` contains no `platform: linux/amd64` pin in the supported path.
- Existing architecture helpers explicitly map SOPS artifacts for `amd64` and `arm64`.
- Cloudflare Worker bouncer mapping in `utilities/setup-crowdsec.sh` has explicit amd64/x86_64 and arm64/aarch64 handling.
- Official Noble package metadata shows the apt `yq` package is architecture `all`, with the same package paragraph for amd64 and arm64 indexes.

Blocking static signals:

- F-03: Caddy plugin module resolution and SOPS default installation are not reproducible.
- F-04: production setup and CI use different yq implementations, and PyYAML is not explicitly owned.

Arm64 support cannot be claimed solely from static `case arm64)` mappings and image manifest expectations. It needs at least one real Noble arm64 host drill that covers architecture-sensitive packages, downloaded binaries, custom Caddy build, CrowdSec/bouncers, systemd startup, basic health, and one real backup/restore path.

## Cloud-Provider Neutrality Assessment

No executable dependency on OCI CLI, OCI APIs, OCI instance principals, OCI metadata endpoints, provider IAM, or provider-specific block-device paths was found in the focused pass.

Provider-neutrality remains structurally plausible:

- storage uses operator-supplied or stable paths rather than requiring OCI device names;
- Cloudflare is correctly treated as mandatory edge infrastructure, not as a cloud provider;
- host firewall automation is local to the Ubuntu host.

The remaining provider-neutrality issue is documentation/support-contract drift, not a runtime provider API dependency. See F-05.

## Repository-Wide Entry Point Inventory

| Entry point category | Representative paths | Corrected static assessment |
| --- | --- | --- |
| Root setup | `setup.sh`, `utilities/setup-system.sh`, `utilities/setup-env.sh`, `utilities/setup-secrets.sh`, `utilities/setup-firewall.sh`, `utilities/setup-storage.sh` | F-02, F-03, and F-04 block final setup confidence. |
| Lifecycle | `startup.sh`, `Makefile`, `utilities/safe-restart.sh`, `utilities/maintenance-health.sh` | Structure remains sound; startup later validates PyYAML but setup does not own it. |
| Backup | `backup.sh`, `utilities/backup-run.sh`, `lib/backup-utils.sh` | Emergency protection modes are coherent; report acceptance wording corrected. |
| Restore/recovery | `restore.sh`, `recover.sh`, `utilities/restore-run.sh` | Offline SOPS/Age recovery is separate from emergency backup passphrase/recipient handling. |
| Secrets/key management | `edit-secrets.sh`, `utilities/secrets-*.sh`, `utilities/key-rotate.sh`, `lib/secrets.sh`, `lib/schema.sh` | yq/PyYAML contract needs closure. |
| Storage/migration | `utilities/setup-storage.sh`, `lib/storage.sh`, `lib/migrate.sh` | Migration acceptance must cover both boot-to-block and block-to-boot. |
| Systemd | `utilities/setup-systemd.sh`, `systemd/*.service`, `systemd/*.timer` | Host validation still required. |
| CrowdSec/firewall | `utilities/setup-crowdsec.sh`, `utilities/setup-firewall.sh`, `utilities/maintenance-update-firewall.sh` | Static mapping is promising; direct CrowdSec tests pass. |
| Operator UI/docs | `Makefile`, `dashboard.sh`, `RUNBOOK.md`, `docs/*`, `docs/COMMAND-REFERENCE.md` | F-01 and F-05 remain. |

## Cross-PR Integration Review

PR #230 exact-head evidence:

- PR: `https://github.com/killer23d/VaultWarden-OCI/pull/230`
- Final PR head: `096e25f8e60dd286217e5b5270f6a8e6241bfb3b`
- Merge commit: `2d151534c441cf857f6a8fa49f6c685f7d10b451`
- GitHub Actions run: `https://github.com/killer23d/VaultWarden-OCI/actions/runs/28847717269`
- Workflow: `Doc Drift Check`
- Event: `pull_request`
- Run conclusion: `success`
- Job conclusions: `doc-drift=success`, `shellcheck=success`, `functional-tests=success`

Regression boundary:

```text
PR #230 exact executable head
  -> required CI passed

later AGENTS-only guidance commit
  -> no Actions run for 2837fc1...

later report-only commit
  -> no Actions run for bd8a5e7...

local canonical runner today
  -> stops in operator prompt scan because it scans prose/report content
```

This means PR #230's executable head had successful CI, while the current report-correction baseline has local readiness-gate failure caused by later prose/report content and overbroad scan scope.

## Findings

### F-01 - Canonical readiness runner fails because prompt-format scan recursively scans prose and reports

Severity: Medium

Confidence: High

Area: Tests, CI, operator UI regression coverage

Affected files:

- `tests/test-operator-ui.sh:357-401`
- `.github/workflows/doc-drift.yml:3-18`
- `.github/workflows/doc-drift.yml:174-194`
- `AGENTS.md`
- `reports/post-pr230-final-production-readiness-audit.md`

Affected supported entry point(s):

- `bash tests/run-tests.sh all`
- GitHub Actions `functional-tests` job when triggered
- Any final readiness gate that treats the canonical runner as mandatory

Execution path:

1. `bash tests/run-tests.sh all`
2. `tests/test-operator-ui.sh`
3. `check_confirmation_prompt_format`
4. Recursive fixed-string scan from repository root
5. Scan includes durable guidance and historical/current audit prose
6. Prose matches a shorthand yes/no token or a substring that looks like one
7. Test exits 1 before reaching CrowdSec and uninstall suites

Expected contract:

The prompt-format test should reject actual runtime/operator confirmation prompts that use shorthand defaults, while allowing prose, historical audit text, support-matrix text, fixtures, and report discussion that cannot present a runtime prompt.

Current behavior:

The scan traverses the full repository root, excluding only `.git` and binary/image/PDF suffixes. It scans `AGENTS.md`, `reports/`, historical prose, and other content that cannot be runtime confirmation prompts.

Evidence:

- `tests/test-operator-ui.sh:363-370` builds fixed-string shorthand prompt patterns.
- `tests/test-operator-ui.sh:374-384` scans `"$ROOT"` recursively.
- `tests/test-operator-ui.sh:392-395` fails on any match.
- The local runner failed today in `tests/test-operator-ui.sh` and printed matches from both `AGENTS.md` and the existing report under `reports/`.
- `tests/run-tests.sh:39-41` places `tests/test-crowdsec.sh` and `tests/test-uninstall.sh` after `tests/test-operator-ui.sh`.
- `.github/workflows/doc-drift.yml:3-18` omits both `AGENTS.md` and `reports/**` from the pull-request path filter.

Realistic trigger:

Any future guidance, report, or non-operator prose containing a false-positive substring can block the canonical local runner. Because the workflow path filter omits some scanned paths, such a change can also miss CI.

Production/operator impact:

This is not a production runtime defect. It does not directly break a running Vaultwarden host. It is a canonical readiness-gate defect: a branch that cannot pass its own permanent runner should not be labeled production-ready.

Cross-component interaction:

PR #230 consolidated tests under `tests/run-tests.sh all`. Later guidance/report-only content can break that runner because the operator prompt scan reaches beyond operator prompt surfaces.

Why current tests/CI missed it:

The test exposes the issue locally, but its scan scope is too broad and the workflow path filter does not include all scanned prose paths.

Minimal fix direction:

Narrow the scan to actual operator-facing shell scripts and intentionally rendered operator documentation where prompts are shown. Add explicit allow/reject fixtures: allow the old support-matrix slash phrase as prose, and reject a real "Continue?" prompt using a shorthand default. Include any intentionally scanned prose paths in CI path filters.

Focused regression recommendation:

Add one test fixture for allowed prose and one for a rejected runtime prompt. Rerun `bash tests/run-tests.sh all` and confirm the runner reaches and passes CrowdSec and uninstall in canonical order.

Scope-pressure note:

Do not add a new test framework. This is a narrow scan-target and fixture correction.

### F-02 - Noble-only host setup is not fail-closed before apt repository rendering

Severity: Medium

Confidence: High

Area: Host setup, Noble support contract, dependency installation

Affected files:

- `utilities/setup-system.sh:214-216`
- `utilities/setup-system.sh:377-405`
- `tests/test-architecture.sh:35-48`
- `AGENTS.md` operating-system matrix and Ubuntu portability text

Affected supported entry point(s):

- `sudo ./setup.sh install --domain <fqdn> --email <admin-email> --auto`
- Direct use of `sudo ./utilities/setup-system.sh`
- First-run dependency installation on a new host

Execution path:

1. First-run setup enters `install_dependencies`.
2. Docker setup reads `VERSION_CODENAME` from `/etc/os-release` without checking `ID` or `VERSION_ID`.
3. Universe setup falls back to `lsb_release -cs`.
4. If `lsb_release` fails, the fallback emits `noble`.
5. Apt repository files can be written before a clear supported-host decision.

Expected contract:

For the corrected support policy, setup must read `/etc/os-release`, require Ubuntu, require Ubuntu 24.04/Noble, and fail clearly on anything else before writing apt repositories or performing meaningful host mutation.

Current behavior:

`install_docker` uses only `VERSION_CODENAME`. The universe fallback uses `lsb_release` and a literal Noble fallback. There is no shared helper that validates `ID=ubuntu`, `VERSION_ID=24.04`, `VERSION_CODENAME=noble`, or `UBUNTU_CODENAME=noble` coherently.

Evidence:

- `utilities/setup-system.sh:215` renders Docker codename from `VERSION_CODENAME`.
- `utilities/setup-system.sh:389` and `utilities/setup-system.sh:399` fall back to `noble` when `lsb_release -cs` fails.
- `utilities/setup-system.sh:391-392` and `utilities/setup-system.sh:401-402` write the resulting codename into an apt source.
- `tests/test-architecture.sh:35-48` covers archive URL and SOPS architecture helpers but not `/etc/os-release` fixture behavior or unsupported-host failure.

Realistic trigger:

A non-Ubuntu host with Ubuntu-like fields, an unsupported Ubuntu release, a minimal host without `lsb_release`, or a broken release-detection environment can enter repository rendering instead of failing first.

Production/operator impact:

Wrong or unsupported apt repository state can break setup or leave a confusing partially mutated host. This blocks a truthful Noble-only production support claim.

Cross-component interaction:

Host release detection feeds Docker repository setup, universe repository setup, apt package availability, yq/PyYAML installation, SOPS prerequisites, Docker Compose installation, and CrowdSec later in the setup path.

Why current tests/CI missed it:

There are no `/etc/os-release` fixtures for supported Noble, non-Ubuntu, unsupported Ubuntu, missing codename, or absent `lsb_release`. CI does not run setup on a disposable Noble host.

Minimal fix direction:

Add a small local helper in `utilities/setup-system.sh` that reads `/etc/os-release`, validates Ubuntu 24.04/Noble, and returns the canonical codename. Use it for Docker and universe repository setup. Fail closed on unsupported/unresolved values.

Focused regression recommendation:

Add fixture tests for Noble, unsupported Ubuntu, non-Ubuntu, missing codename, and `lsb_release` absence. Assert that only Noble succeeds and that repository rendering never defaults silently.

Scope-pressure note:

Do not add a generic OS abstraction or expand the support matrix. Enforce the Noble-only appliance contract.

### F-03 - Required production dependency outputs are not fully reproducible

Severity: Medium

Confidence: High

Area: Dependency reproducibility, custom Caddy build, SOPS installation, supply-chain control

Affected files:

- `caddy/Dockerfile:13-23`
- `docker-compose.yml.example:206-214`
- `.env.example:53-58`
- `setup.sh:7-14`
- `utilities/setup-system.sh:180-205`
- `utilities/setup-system.sh:466-525`
- `.github/workflows/doc-drift.yml:105-127`

Affected supported entry point(s):

- `docker compose build caddy`
- `sudo make up` or startup/update flows that build custom Caddy
- First-run setup on hosts without SOPS
- Restore/recovery/secrets flows that depend on SOPS behavior

Execution path:

1. Compose builds the custom Caddy service from `caddy/Dockerfile`.
2. Dockerfile pins `CADDY_VERSION=2.11.4`.
3. `xcaddy build` uses unversioned module specs.
4. Separately, `setup.sh` defaults `SOPS_VERSION` to blank.
5. `utilities/setup-system.sh` resolves a blank SOPS version through GitHub `releases/latest`.
6. Same repository commit can install/build different required production outputs on a later date.

Expected contract:

Required production dependency outputs should be reproducible enough that the same repository commit does not silently produce a different Caddy binary or SOPS version later. Integrity checks are necessary but not sufficient for reproducibility.

Current behavior:

Caddy base image is pinned, but four `xcaddy --with` modules are unpinned. SOPS binary downloads are checksum-verified, but the default version is resolved at install time unless the operator overrides `SOPS_VERSION`.

Evidence:

- `caddy/Dockerfile:13` pins the base Caddy version.
- `caddy/Dockerfile:17-21` uses unversioned Caddy module specs.
- `docker-compose.yml.example:210-214` says `xcaddy` builds must be pinned, but the Dockerfile module graph floats.
- `setup.sh:7-14` documents blank `SOPS_VERSION` as resolving latest at runtime.
- `utilities/setup-system.sh:484-485` resolves latest from `getsops/sops` when blank.
- `utilities/setup-system.sh:490-525` verifies the downloaded binary against the current upstream checksum file, which protects integrity for the chosen release but does not pin which release is chosen.
- `.github/workflows/doc-drift.yml:105-127` checks selected unpinned references but scans `setup.sh` for the latest-release endpoint, not the `utilities/setup-system.sh` resolver that actually calls it.

Realistic trigger:

A production host rebuilds Caddy or installs SOPS after upstream module or SOPS releases change. The repository commit is unchanged, but the built/installed binary differs from what was audited.

Production/operator impact:

Setup or update can fail, or produce an unreviewed dependency behavior change. This weakens both recovery-sensitive dependency confidence and amd64/arm64 support claims.

Cross-component interaction:

Caddy is the TLS/reverse-proxy front door. SOPS is on the secrets, restore, recovery, key rotation, and backup path. Both are required for the normal appliance.

Why current tests/CI missed it:

CI renders compose and performs static shell checks, but does not build the custom Caddy image. The unpinned-version check omits `caddy/Dockerfile` and misses the actual SOPS latest-release resolver.

Minimal fix direction:

Pin each existing Caddy module to a known tag or commit. Set a pinned repository default for SOPS while retaining an explicit `SOPS_VERSION` override. Keep checksum verification. Add narrow static checks for both invariants.

Focused regression recommendation:

Add a test that rejects unversioned `xcaddy --with github.com/...` specs. Extend the unpinned-release check to the actual SOPS resolver path. In production acceptance, build Caddy on Noble amd64 and Noble arm64 and confirm expected modules are present.

Scope-pressure note:

Do not add a dependency manager, plugin registry, or broad build framework. Pin the few required artifacts and test those invariants.

### F-04 - Production schema dependency contract is split across apt yq, CI yq, and unowned PyYAML

Severity: Medium

Confidence: Medium-high

Area: Dependency installation contract, schema/secrets tooling, CI coverage

Affected files:

- `utilities/setup-system.sh:408-450`
- `utilities/setup-system.sh:530-543`
- `startup.sh:313-317`
- `lib/schema.sh:7-10`
- `lib/schema.sh:49-53`
- `lib/secrets.sh:313-340`
- `.github/workflows/doc-drift.yml:30-52`
- `.github/workflows/doc-drift.yml:181-190`
- `tests/test-secrets.sh`

Affected supported entry point(s):

- `sudo ./setup.sh install`
- `sudo ./startup.sh` / `sudo make up`
- `sudo ./utilities/setup-secrets.sh`
- `sudo ./utilities/secrets-edit.sh`
- `sudo ./utilities/secrets-rotate.sh`
- `sudo ./backup.sh run`
- generated command-reference workflow and local tests

Execution path:

1. Normal Noble setup installs apt package `yq`.
2. Official Noble metadata shows that package is kislyuk/python-yq `3.1.0-3`, architecture `all`, depending on `python3-yaml`.
3. `lib/schema.sh` says Mike Farah `yq` v4+ is required and tells operators it is installed by apt.
4. CI deliberately avoids apt `yq` and installs Mike Farah `yq v4.53.3`.
5. Setup verifies only that `yq` exists, not implementation or interface.
6. Setup does not explicitly install `python3-yaml` and does not verify `python3 -c "import yaml"`.
7. Startup later hard-fails if PyYAML is unavailable.

Expected contract:

Production setup, dependency validation, schema consumers, tests, and CI should agree on the required yq implementation and Python YAML module ownership. If a specific yq implementation is required, setup should install/validate it. If apt python-yq is intended, CI and comments should test that implementation and all direct calls should use compatible flags.

Current behavior:

Production and CI intentionally use different yq implementations. The current core schema helper filters are jq-style and passed a disposable python-yq `3.1.0` compatibility check, but the declared contract and CI are Mike Farah. A direct conditional Cloudflare-key query in `lib/secrets.sh` omits raw output; python-yq emits quoted strings for that query. That function currently has no active callers, so this is not being reported as an immediate startup failure, but it demonstrates real implementation divergence.

PyYAML is currently installed on a fresh Noble apt path only incidentally through apt `yq`. If production moves to a standalone Mike Farah yq binary, or if a host already has a non-apt `yq`, setup can declare dependencies ready while startup later fails on missing PyYAML.

Evidence:

- Official Noble amd64 and arm64 metadata: `Package: yq`, `Version: 3.1.0-3`, `Homepage: https://github.com/kislyuk/yq`, `Depends: ... python3-yaml ...`.
- `lib/schema.sh:9-10` declares yq v4+ and says apt installs it.
- `lib/schema.sh:49-53` only checks command existence and prints a Mike Farah requirement.
- `.github/workflows/doc-drift.yml:35-37` states apt `yq` is python-yq and CI must install Mike Farah.
- `.github/workflows/doc-drift.yml:45-51` pins and installs Mike Farah `yq v4.53.3`.
- `utilities/setup-system.sh:408` lists `yq` but not `python3-yaml`.
- `utilities/setup-system.sh:533-543` verifies commands plus `python3-argon2`, not PyYAML or yq interface/version.
- `startup.sh:313-317` later requires `python3 -c "import yaml"`.
- Disposable python-yq `3.1.0` check: core schema filters succeeded; the Cloudflare conditional-key query without raw output emitted quoted keys.

Realistic trigger:

A fresh Noble host installs apt python-yq while CI tests Mike Farah. A future schema expression that uses Mike Farah-only syntax can pass CI and fail production. Conversely, switching production to the declared Mike Farah binary without explicitly installing PyYAML can make startup fail after setup reports dependencies ready.

Production/operator impact:

Secrets setup, secret editing, secret rotation, backup HMAC extraction, startup secret export, and command-reference generation all depend on the schema/secrets stack. A wrong accepted implementation can block setup/startup or produce misleading validation behavior.

Cross-component interaction:

Candidate A and Candidate B are coupled: apt `yq` currently masks the missing PyYAML ownership because it depends on `python3-yaml`. Fixing the yq implementation without adding PyYAML ownership can uncover the startup failure.

Why current tests/CI missed it:

CI installs Mike Farah yq directly, so it does not exercise the Noble apt yq implementation. Tests do not assert yq implementation/version or `python3 -c "import yaml"` as part of setup dependency verification. The direct python-yq divergence is not covered by `tests/test-secrets.sh`.

Minimal fix direction:

Choose one production contract and enforce it. Given the current comments and CI, the narrow path is to install a pinned Mike Farah yq v4 binary with explicit amd64/arm64 mapping and checksum verification, validate the required yq interface/version, explicitly install `python3-yaml`, and verify `python3 -c "import yaml"` in setup. If the project intentionally chooses apt python-yq instead, update CI/comments and add compatibility tests for that implementation.

Focused regression recommendation:

Add setup-system tests for yq implementation validation and PyYAML validation. Add a schema/secrets test that runs the Cloudflare conditional-key extraction under the selected yq implementation and proves unquoted key names are used.

Scope-pressure note:

Do not add a dependency framework. Own the few commands/modules this appliance requires.

### F-05 - Active operator guidance still contains stale OS/provider support-contract wording

Severity: Low

Confidence: High

Area: Documentation/support-contract drift, provider-neutral operator guidance

Affected files:

- `AGENTS.md`
- `docs/DISASTER-RECOVERY.md:29`
- `docs/RECOVERY-CARD.md:12-15`
- `utilities/restore-run.sh:1655`
- `RUNBOOK.md:12`

Affected supported entry point(s):

- Human first-time setup and recovery guidance
- Generated or runtime operator hints derived from current scripts
- Durable repository instructions for future work

Execution path:

1. Operator or future agent reads active guidance.
2. Guidance still advertises the older two-release support contract or presents OCI-specific console/security-list wording as universal.
3. The corrected Noble-only provider-neutral support claim becomes inconsistent across active materials.

Expected contract:

Active guidance should consistently say Ubuntu 24.04 LTS Noble, amd64 or arm64, provider-neutral Ubuntu host, Cloudflare-first mandatory edge.

Current behavior:

`docs/DEPLOYMENT.md` is now aligned with Ubuntu 24.04 and generic provider firewall wording. Other active guidance remains stale:

- `AGENTS.md` still advertises the older two-release OS matrix and portability expectations.
- `docs/DISASTER-RECOVERY.md:29` says a fresh or replacement Ubuntu 22.04/24.04 host.
- `docs/RECOVERY-CARD.md:12-15` references OCI console access and says Ubuntu 22.04 or later is supported.
- `utilities/restore-run.sh:1655` emits an install hint for Ubuntu 22.04/24.04.
- `RUNBOOK.md:12` presents "Configure OCI Security List" as the universal first setup step.

Historical reports under `reports/` are not part of this finding and do not need rewriting for the support-policy change.

Realistic trigger:

A junior operator follows the recovery card or runbook and either provisions an unsupported host or assumes OCI-specific setup is required on every provider.

Production/operator impact:

This is unlikely to break executable code by itself, but it weakens the support boundary and can mislead setup/recovery actions.

Cross-component interaction:

The docs drift affects the same support claim that F-02 must enforce in setup. Documentation and code should converge in the same follow-up PR so future audits do not have split contracts.

Why current tests/CI missed it:

No focused documentation check enforces Noble-only support wording or provider-neutral first-time setup phrasing. The existing stale-term checks do not cover these support-contract strings.

Minimal fix direction:

Update only active support-contract guidance and generated/runtime hints that materially describe supported OS/provider prerequisites. Do not rewrite historical reports or broad documentation for style.

Focused regression recommendation:

Add a narrow doc/support-contract check for active docs if this drift recurs, or include this exact grep in the follow-up PR validation.

Scope-pressure note:

Do not add cloud-provider automation or expand OS support. This is a bounded wording and generated-hint cleanup.

## Test Consolidation Coverage Assessment

The permanent runner still inventories 15 suites:

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

Coverage strengths:

- The runner inventory is centralized.
- Earlier suites still pass before the current prompt-scan stop.
- Direct `test-crowdsec.sh` and `test-uninstall.sh` execution passed after the canonical stop point.
- Storage tests cover both migration parser directions and mode precedence.

Coverage gaps:

- F-01: prompt scan covers prose/report content rather than actual operator prompt surfaces.
- F-02: no supported-host release fixture tests.
- F-03: no Caddy module pin check, no SOPS default pin check, no Caddy build in CI.
- F-04: no production-vs-CI yq implementation check and no setup-owned PyYAML validation.
- F-05: no active support-contract wording check.

## Security and Secrets Assessment

Static result: Yellow until F-04 is fixed.

Positive signals:

- SOPS/Age remains the designed persistent-secret model.
- Runtime Docker secret source files remain transient under `/run/vaultwarden-oci/secrets`.
- Recovery kit and offline-recipient concepts remain separate from emergency backup passphrase handling.
- Emergency backup code refuses to encrypt key-material capsules only to the operational Age recipient.

Remaining blocker:

- The schema/secrets tooling dependency contract is inconsistent across production setup and CI. That is a dependency installation and coverage problem, not a finding that secrets are currently exposed.

## Backup / Restore / Recovery Assessment

Static result: Green with required live drills, plus corrected acceptance wording.

The implementation distinguishes:

- operational Age private key: the live server key used for SOPS and normal db/full backup encryption;
- offline SOPS/Age recovery private key: kept offline, used by `recover.sh` and SOPS recovery flows;
- offline Age public SOPS recipient: may be stored in SOPS policy/manifest;
- emergency backup passphrase: independent passphrase for passphrase-sealed emergency capsules;
- `EMERGENCY_BACKUP_AGE_RECIPIENT`: separate Age recipient used for recipient-sealed emergency capsules;
- private identity for `EMERGENCY_BACKUP_AGE_RECIPIENT`: the identity needed to decrypt such emergency capsules.

Corrected acceptance behavior:

- Emergency passphrase mode: create emergency backup, verify metadata says `age-passphrase`, decrypt with the operator-provided emergency backup passphrase.
- Emergency recipient mode: set `EMERGENCY_BACKUP_AGE_RECIPIENT`, create emergency backup, verify metadata says `age-recipient`, decrypt with the corresponding private identity through `EMERGENCY_BACKUP_AGE_IDENTITY_FILE` or restore path.
- Offline SOPS/Age recovery: validate SOPS recipient/recovery behavior through `recover.sh` disaster-recovery contract.

Only claim the offline recovery Age key decrypts the emergency capsule when that same recipient was intentionally configured as `EMERGENCY_BACKUP_AGE_RECIPIENT`.

## Operation Guard and Interruption Assessment

Static result: Green.

No new operation-guard finding was identified in this focused pass. Existing operation lock behavior, package-manager contention protection, and interruption-sensitive tests remain outside the corrected blockers.

## Storage / Migration / Uninstall Assessment

Static result: Green for storage/migration/uninstall logic; Yellow for final support claim until host dependency blockers are fixed.

Direct evidence added:

- `tests/test-uninstall.sh` passed under Bash 5 PATH after the canonical runner stopped before it.

Migration acceptance must explicitly cover:

- boot-to-block migration;
- interruption/resume where supported for boot-to-block;
- block-to-boot migration;
- final source/state validation after block-to-boot.

Validating only the golden boot-to-block path is not enough to claim all advertised migration behavior.

## Systemd and Automation Assessment

Static result: Green with host validation required.

No new static systemd defect was found. Real Noble amd64 and arm64 validation still must cover installed units/timers, reboot/startup, runtime secret recreation, expected contention behavior, and failure notification.

## Operator CLI / Make / Dashboard Assessment

Static result: Yellow because of F-01.

The operator CLI argument contracts ran before the prompt-scan failure and passed. Dashboard truthfulness, smoke readiness, drill truthfulness, and operator UI checks printed pass messages before the later prompt-format scan failed.

The corrected root cause is not that the operator UI behavior is bad; it is that the repository-wide grep treats prose/report content as active prompts.

## Documentation and Generated Reference Assessment

Static result: Yellow.

Important correction:

- `docs/DEPLOYMENT.md` now matches the revised Ubuntu 24.04 support contract and should not be treated as stale merely because older guidance once claimed Ubuntu 22.04 support.

Remaining active drift:

- F-05 covers stale OS support wording in active guidance and one runtime install hint.
- F-05 retains the old F-04 provider-neutral issue for the quick runbook's universal OCI Security List wording.

Generated command reference was not regenerated during this report-only pass.

## Production-Host Acceptance Validation Items

Run these after F-01 through F-04 are fixed. The supported matrix is Noble amd64 and Noble arm64 only.

### Noble amd64

Full production-host acceptance:

| # | Validation item | Success signal | Failure signal |
| --- | --- | --- | --- |
| 1 | Fresh Noble amd64 setup | `setup.sh install` completes only after validating Ubuntu 24.04/Noble; apt sources use Noble; compose renders. | Unsupported/unresolved host proceeds, wrong apt source, dependency install failure. |
| 2 | Dependency contract | yq implementation/version, PyYAML import, SOPS pinned version, Docker/Compose, and required commands validate before setup success. | Setup declares ready but startup or schema/secrets tools fail. |
| 3 | Custom Caddy build | `docker compose build caddy` succeeds and expected modules are present. | Unpinned module resolution failure or missing module. |
| 4 | systemd install and reboot | Units/timers enable, reboot recreates runtime secrets, health passes. | Missing runtime dirs, permission failure, unhealthy service after boot. |
| 5 | Operation contention | Concurrent mutating operations serialize or return expected conflict/skip result. | Overlap, stale metadata confusion, unsafe termination prompt. |
| 6 | Database backup and verify | DB backup completes, integrity metadata valid, verification passes. | Corrupt snapshot, metadata missing, verification skipped. |
| 7 | Full backup and inspect | Full archive contains expected state and excludes live/transient secrets. | Missing restore material or included decrypted runtime secrets. |
| 8 | Emergency passphrase backup | Passphrase-sealed emergency archive decrypts with the emergency backup passphrase. | Passphrase cannot decrypt or required files missing. |
| 9 | Emergency recipient backup, if configured | Recipient-sealed emergency archive decrypts with the private identity for `EMERGENCY_BACKUP_AGE_RECIPIENT`. | Wrong recipient, missing identity, or misleading acceptance claim. |
| 10 | Database restore | Restore completes, Vaultwarden starts, health passes, expected data present. | Incomplete restore presented as success. |
| 11 | Full restore on fresh VM | Fresh host recovers with documented key material and health passes. | Storage/config mismatch, missing Age key, unclear repair. |
| 12 | Offline SOPS/Age recovery | `recover.sh` validates the offline recipient/private key contract and reports committed unhealthy states clearly if startup/health fails. | Rollback after commit, ambiguous success, lost key/config material. |
| 13 | Key rotation and recovery kit | New recipients work, old paths are handled as documented, recovery kit is usable. | Ciphertext cannot be decrypted by intended recipient. |
| 14 | Boot-to-block migration | Migration succeeds; interruption/resume behavior works where supported. | State written to wrong storage or unsafe resume. |
| 15 | Block-to-boot migration | Focused reverse migration succeeds with final source/state validation. | Advertised direction works only one way. |
| 16 | Safe restart | Healthy restart passes; failure rolls back or reports exact manual action. | Service left down with success output. |
| 17 | CrowdSec and bouncers | Package/bouncer installs, local firewall path works, Cloudflare Workers bouncer communicates where enabled. | Wrong package/backend/bouncer behavior. |
| 18 | Failure notification | Expected message and recovery-kit attachment route succeeds. | Silent notification failure or malformed attachment. |
| 19 | Normal uninstall and test reset | Uninstall removes intended project state only; `--test-reset` clean reinstall succeeds. | Residual firewall/systemd/runtime state breaks reinstall or unrelated data touched. |

### Noble arm64

At minimum, perform an arm64 acceptance drill that proves the architecture-sensitive support claim:

| # | Validation item | Success signal | Failure signal |
| --- | --- | --- | --- |
| 20 | Fresh Noble arm64 setup | Host passes Noble validation; architecture-sensitive dependencies install for arm64. | Wrong architecture artifact or unsupported package. |
| 21 | Arm64 stack smoke plus one backup/restore path | Correct yq/PyYAML/SOPS path, Docker image availability, Caddy build/modules, CrowdSec/bouncer install, Cloudflare Workers bouncer architecture path, systemd startup, health, one real backup/restore path, uninstall/clean reinstall sanity. | Static mappings exist but real arm64 build/runtime path fails. |

Do not require a full duplicate destructive disaster-recovery drill on both architectures unless it adds production value. Do not claim arm64 support based only on static mappings or image manifests.

## Rejected Missed-Item Candidates and Narrow Rejections

No candidate A/B/C item was rejected wholesale.

Rejected or narrowed subclaims:

- Lack of Ubuntu 22.04 support is not a defect under the revised product decision.
- Candidate A is not reported as "all current schema helpers fail under apt yq"; a disposable python-yq check showed the core schema filters currently work.
- Candidate A is still a finding because production, comments, validation, and CI disagree on the yq contract, and a direct no-raw-output query demonstrates implementation divergence.
- Candidate B is not reported as a guaranteed fresh-Noble failure today because apt yq currently depends on `python3-yaml`; it is reported as an ownership gap that becomes real when yq is preinstalled differently or fixed to the declared Mike Farah binary.
- The offline SOPS/Age recovery key does not generally decrypt a passphrase-sealed emergency capsule. That was a report acceptance error, not an executable defect.
- A full duplicate destructive DR drill on both amd64 and arm64 is not required by default; arm64 needs meaningful architecture-sensitive validation plus a real backup/restore path.

## Rejected Overengineering / Scope Pressure

The findings do not justify broad redesign.

- Do not add a new test framework for F-01; narrow the scan and add focused fixtures.
- Do not expand support to Debian, Ubuntu 22.04, other Ubuntu releases, or other distributions for F-02.
- Do not add a generic dependency manager for F-03/F-04; pin and validate the few required tools.
- Do not add a cloud-provider abstraction for F-05; correct active guidance and keep provider firewall setup as an operator prerequisite.
- Do not turn the appliance into a framework, orchestrator, or enterprise platform.

## Final Verdict

Current report-correction HEAD: `bd8a5e773db7d3f97bc9c364918e6ca8b560c815`

Original executable audit HEAD: `2837fc1cddb7dda4ce6e156e4e95c5355d506f3a`

Production code changed since original audit: no

Supported OS: Ubuntu 24.04 LTS Noble only

Supported architectures:

- amd64
- arm64

Cloud-provider model: provider-neutral host with mandatory Cloudflare-first edge

Static readiness: YELLOW

Blocking findings: 4 (`F-01`, `F-02`, `F-03`, `F-04`)

Non-blocking findings: 1 (`F-05`)

Report correctness items corrected:

- removed Ubuntu 22.04 from the supported production matrix;
- reframed F-02 for Noble-only fail-closed host detection;
- corrected F-01 root cause to overbroad scan scope including reports/prose;
- added yq/PyYAML dependency-contract evidence;
- added SOPS reproducibility evidence;
- corrected emergency backup acceptance behavior;
- added direct CrowdSec/uninstall test evidence after the canonical stop point;
- added PR #230 exact-head CI evidence;
- revised production-host acceptance for Noble amd64 and Noble arm64 only;
- made both migration directions explicit.

Production-host acceptance items: 21

Recommendation: create one bounded follow-up PR for Noble host dependency and readiness-contract closure, then rerun full validation and perform Noble amd64/arm64 host acceptance.

## Post-PR #235 Second-Pass Static Contract Addendum — 2026-07-09

### Addendum status

This section is a later second-pass static contract review of the current `delta` line after the three findings in `reports/post-pr233-cross-subsystem-contract-bug-audit.md` were addressed.

It does not reopen the original PR #230 F-01 through F-05 audit. Those findings remain historical evidence for the earlier executable baseline and must not be reimplemented merely because they remain documented above.

The second pass confirmed that the later CT-01, CT-02, and CT-03 contract findings are represented as closed in current code and focused regressions. No additional High or Critical production-reachable cross-subsystem contract bug was confirmed.

Two bounded follow-up items remain:

| ID | Severity | Confidence | Summary |
| --- | --- | --- | --- |
| SP-01 | Low | High | The generated state-dir drop-in contract applies a `[Service]` section to `.timer` units even though that section belongs to service units. |
| SP-02 | Low | High | Maintenance backup-retention dry-run returns before the canonical retention helper, so it cannot preview the exact archives and sidecars the real cleanup path would preserve or remove. |

Static closure status: YELLOW for these two bounded second-pass items only.

### SP-01 - State-dir drop-in generator emits a service-only section for timer units

Severity: Low

Confidence: High

Area: systemd installation, generated drop-in schema, static unit validation

Affected files:

- `utilities/setup-systemd.sh`
- `tests/test-systemd.sh`

Affected supported entry point(s):

- `sudo utilities/setup-systemd.sh install`
- Full `sudo ./setup.sh install` path when systemd units are installed
- Generated drop-ins under `/etc/systemd/system/vaultwarden-*.timer.d/10-state-dir.conf`

Execution path:

1. `setup-systemd.sh` builds `_VW_DROPIN_UNITS` with both managed `.service` and `.timer` names.
2. `_install_rwpaths_dropin` iterates the combined list.
3. For every item it renders one drop-in containing `[Unit] After=<mount-unit>` and `[Service] ReadWritePaths=<data-mount>`.
4. The same service-only section is therefore written for `.timer` units.
5. systemd ignores an inapplicable/unknown section for that unit type rather than treating it as the intended timer configuration contract.

Expected contract:

Generated drop-ins must use sections valid for the unit type consuming them.

- Managed service drop-ins may contain `[Unit]` ordering plus `[Service] ReadWritePaths=`.
- Managed timer drop-ins may contain the required `[Unit]` dependency/order contract, but must not receive a `[Service]` section.

Current behavior:

The generator uses one combined unit list and one shared drop-in body for both service and timer files.

Production/operator impact:

The matching service units also receive `ReadWritePaths`, so this review did not confirm a current data-volume write failure from SP-01 alone. The defect is a generated systemd schema/consumer mismatch and weakens static assurance of the installed unit tree.

Cross-component interaction:

The storage contract selects a separate `DATA_VOLUME_MOUNT`; `setup-systemd.sh` translates that storage state into per-unit drop-ins; systemd consumes those generated files. The producer currently emits a service section to a timer consumer.

Why current tests/CI missed it:

Existing systemd tests assert that the drop-in machinery exists and that runtime paths are represented, but they do not parse or semantically verify the full generated unit/drop-in tree with `systemd-analyze verify`.

Minimal fix direction:

Keep the existing small-project design. Split service and timer rendering locally or branch on the unit suffix while retaining the current canonical unit inventories.

- Services: render `[Unit] After=<mount-unit>` and `[Service] ReadWritePaths=<data-mount>`.
- Timers: render only the valid `[Unit]` ordering/dependency content required by the storage mount contract.

Do not introduce a generic systemd generation framework, unit registry, templating engine, or new abstraction layer.

Focused regression recommendation:

Extend `tests/test-systemd.sh` in the closest existing systemd suite.

At minimum:

1. Generate the service and timer state-dir drop-ins in a temporary fixture.
2. Assert a service drop-in contains `[Service]` and the expected `ReadWritePaths=` value.
3. Assert a timer drop-in does not contain `[Service]` or `ReadWritePaths=`.
4. Run `systemd-analyze verify` against the generated fixture where available and fail on generated section/directive warnings attributable to repository units/drop-ins.
5. Keep a structural fallback assertion for environments where `systemd-analyze` is unavailable; do not silently treat parser coverage as behavioral execution.

Scope-pressure note:

This is a local producer/consumer schema correction. Do not redesign systemd installation.

### SP-02 - Maintenance retention dry-run bypasses the canonical retention preview

Severity: Low

Confidence: High

Area: maintenance operator truthfulness, backup retention, dry-run semantics

Affected files:

- `lib/maintenance-utils.sh`
- `lib/backup-utils.sh`
- closest existing maintenance/backup regression coverage, preferably `tests/test-backup.sh` unless the repository's current ownership clearly places the behavior elsewhere

Affected supported entry point(s):

- Comprehensive maintenance dry-run paths that include backup cleanup
- Direct maintenance cleanup preview through the canonical maintenance runner

Execution path:

1. Maintenance enters `cleanup_backups`.
2. `cleanup_backups` checks `DRY_RUN=true`.
3. It prints only a generic `Would clean up old backups based on retention policy` message.
4. It returns before iterating backup types and before calling `cleanup_old_backups`.
5. The real cleanup path later calls the shared `cleanup_old_backups` helper.
6. That canonical helper already has non-mutating dry-run behavior that identifies stale deletion candidates, preserves the newest timestamped archive, preserves unparseable archive names, and reports orphaned sidecar cleanup.

Expected contract:

A maintenance dry-run should preview the same retention selection policy that the real maintenance cleanup path will execute, while making no filesystem or remote mutation.

Current behavior:

Maintenance dry-run bypasses the single source of truth and provides only a generic summary. The underlying retention helper has a more precise and tested preview, but maintenance does not reach it in dry-run mode.

Production/operator impact:

This is not a recovery-point deletion bug because the dry-run path returns before mutation and the real cleanup path uses the corrected canonical retention helper. The impact is operator truthfulness: a dry-run cannot show the exact archives and sidecars selected by the real retention policy.

Cross-component interaction:

`maintenance` owns orchestration and operator output; `lib/backup-utils.sh` owns retention selection and preservation. The dry-run wrapper currently bypasses the owning policy implementation.

Why current tests/CI missed it:

The retention helper itself has focused local/remote dry-run regression coverage. The missing contract is one layer above it: maintenance dry-run does not delegate to that helper.

Minimal fix direction:

Remove the early generic dry-run return from `cleanup_backups` and let the existing per-type loop call `cleanup_old_backups` with `DRY_RUN=true` inherited/exported as it does for the normal policy path.

Preserve these behaviors:

- no archive deletion in dry-run;
- no sidecar deletion in dry-run;
- newest parseable timestamped archive is not shown as a deletion candidate;
- unparseable legacy/manual archive names are preserved;
- exact stale archive and orphaned-sidecar candidates are reported by the canonical helper;
- a real helper error remains a real maintenance error.

Do not duplicate retention selection logic in maintenance.

Focused regression recommendation:

Add one focused regression through the maintenance cleanup wrapper, not only the helper directly.

Use a temporary backup tree containing:

- one stale older timestamped archive with sidecars;
- one newer timestamped archive that must be preserved;
- one unparseable manual/legacy archive that must be preserved;
- one orphaned sidecar.

Run the maintenance cleanup path with `DRY_RUN=true` and assert:

1. no fixture file is removed;
2. the stale older archive is reported as a planned deletion;
3. the newest archive is not reported as a deletion candidate;
4. the unparseable archive is not reported as a deletion candidate;
5. the orphaned sidecar is reported as planned cleanup;
6. the output comes from the canonical retention semantics rather than a generic early-return message.

Scope-pressure note:

This is a delegation/truthfulness correction. Keep `cleanup_old_backups` as the retention single source of truth.

### Second-pass bounded closure acceptance

The follow-up implementation should close SP-01 and SP-02 only.

Do not:

- restart the production-readiness audit;
- re-audit the repository broadly;
- reimplement historical F-01 through F-05 solely because they remain in this report;
- reopen CT-01, CT-02, or CT-03 unless current executable evidence shows a regression;
- introduce new frameworks, registries, generic generators, policy engines, or abstraction layers;
- perform unrelated formatting or documentation churn.

Required implementation result:

1. Timer state-dir drop-ins no longer contain `[Service]` or `ReadWritePaths=`.
2. Service state-dir drop-ins retain the mount ordering and required writable data-volume path.
3. Generated systemd unit/drop-in verification is added to the closest existing systemd regression suite, using `systemd-analyze verify` where available plus honest structural fallback coverage.
4. Maintenance backup-retention dry-run reaches the canonical `cleanup_old_backups` preview path.
5. Maintenance dry-run remains non-mutating and reports the same preservation/deletion selection policy as real cleanup.
6. Focused regressions live in the existing consolidated domain suites.
7. Existing operation guards, storage fail-closed behavior, backup retention preservation, and systemd start policy remain unchanged except where directly required for these two findings.

Static validation for the closure should include the repository's canonical checks:

```bash
git diff --check

find . \
  -path './.git' -prune -o \
  -type f -name '*.sh' -print0 \
  | xargs -0 -n 1 bash -n

find . \
  -path './.git' -prune -o \
  -type f -name '*.sh' -print0 \
  | xargs -0 shellcheck -x --severity=warning

./tests/run-tests.sh all

docker compose \
  --env-file .env.example \
  -f docker-compose.yml.example \
  config --quiet
```

In addition, the generated systemd fixture must receive focused `systemd-analyze verify` coverage where the analyzer is available.

Exact-head GitHub Actions must be green before merge. After this bounded static closure, stop producing another broad readiness report and move to the pinned-SHA production-host acceptance and go-live validation record.
