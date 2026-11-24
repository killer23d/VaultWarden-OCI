# UX development and acceptance

This is the dedicated development record for the administrator UX work. It is
an audit and staged proposal, not a new product major version, release approval,
or permission to deploy. The administrator's master contract governs this work;
[project boundaries](PROJECT-BOUNDARY.md), [durable decisions](DECISIONS.md),
[development](DEVELOPMENT.md), [host acceptance](HOST-ACCEPTANCE.md), and the
[test strategy](../reports/TEST-STRATEGY.md) remain the implementation authorities.

## UX-00 stage receipt

| Field | Recorded evidence |
| --- | --- |
| Stage / scope | UX-00: baseline, architecture and complete operator-surface audit; documentation only. |
| Exact accepted base | `03c3437b2191b052534718d94e2ce96f129c62aa` |
| Accepted source tree | `dd1eb35b5eb0ce1f37fb9cc9d730cf8183519b01`; local Git and independent remote Git-data read agree. |
| Branch controls | Development integration `v3` and the [preserved baseline branch](https://github.com/killer23d/VaultWarden-OCI/tree/v2) both selected the accepted base at entry. Default branch is `main`. Only `ux/00-baseline-audit` may be written; its PR targets `v3`. |
| Development branch | `ux/00-baseline-audit`, created from the exact accepted base. |
| Implementation head | `89e661ae6e495c654768601b2993f3c354679799` (reviewed audit content). This receipt is a later documentation-only child; its final exact head is recorded independently in the PR and handover. |
| PR | [#443](https://github.com/killer23d/VaultWarden-OCI/pull/443), `ux/00-baseline-audit` into `v3`; administrator review and merge authorization pending. |
| Changed files | `docs/UX-DEVELOPMENT.md` only. No executable, unit, dependency pin, workflow or other production-file change. |
| Architectural decision | Retain existing owners; entrypoint integrity precedes truthful read models, menu revision and guided extensions. No new runtime layer. |
| Focused tests | 156 existing operator/recovery/handoff/systemd tests PASS; 40 public leaf help routes and 4 top-level/version routes PASS; parser inventory and 7 isolated audit assertions PASS. |
| Regression tests | All 588 existing unit/bounded integration tests PASS; compile, Bash syntax, existing CLI-help and documentation audit PASS; existing historical and current-predecessor isolated transaction checks PASS. Exact commands and limits below. |
| CI | Audited implementation head: [push 45451023299](https://github.com/killer23d/VaultWarden-OCI/actions/runs/45451023299) and [PR 45451108239](https://github.com/killer23d/VaultWarden-OCI/actions/runs/45451108239), each completed successfully with all nine jobs independently verified. The receipt commit must pass its own exact-head checks, recorded in the PR/handover. |
| Live acceptance | NOT RUN. No host identified or authorized for this stage. A documentation-only audit does not need a new live mutation/installed-entrypoint gate; no executable or presentation entrypoint changes. Existing host evidence is reviewed history only. |
| Limitations | Known source findings remain unfixed. Local runner is Debian 13 x86_64/Python 3.12.14 (dashboard shells use /usr/bin/python3 3.13.5), not native Ubuntu/OCI. Dependency/OS integrations run in existing CI; rc.16 live acceptance and the historical limits below remain separate. |
| Verdict | PASS for scoped UX-00 audit implementation and recorded baseline validation. Final receipt-head CI is mandatory before merge review; missing evidence means HOLD. No merge authorization has been given. |
| Next action | Verify the final receipt head and CI, then request administrator review and exact-head squash-merge authorization. Stop here; do not merge or begin UX-01. |

The final reviewed PR head and eventual accepted squash-merge SHA must be
independently supplied in the PR/handover. The next stage must verify that merge
and resulting tree before branching. A commit must never claim to contain its
own SHA. No tag, release, production change or subsequent stage is authorized.

## UX-01 stage receipt (candidate; HOLD)

| Field | Recorded evidence |
| --- | --- |
| Scope | Authoritative operational evidence and local deployment-readiness assessment. No lifecycle or scheduling mutation; no dashboard menu redesign. |
| Accepted base | `6e89d2feac53a9cc7ac69af07b8b10471b0d117d` — [UX-00 acceptance and equivalent squash integration](https://github.com/killer23d/VaultWarden-OCI/pull/443#issuecomment-7139887051). |
| Base tree | `379debac850371238288963e1f1acf5bf6fb8d56` independently matches exact reviewed UX-00 head; single parent is original baseline. |
| Branch | `ux/01-status-readiness`, independently verified at the accepted base before edits. |
| Changed owners | Existing recovery, update status/guard, edge, operations, CLI and dashboard presentation; storage/config validation, notification and Worker evidence owners; operations manual, README and focused tests. |
| Decisions | Preserve status schema 1 and exit contracts; additive operational evidence, separate readiness schema 1. Project prerelease identity changes to `0.1.0-rc.17` solely to satisfy immutable release identity; all upstream component and image pins unchanged. No tag, publication, new installed module, mutation owner, dependency or service. No provider probe on periodic health. |
| Prior implementation head | `8ca122795aab4c1fabf24e288db4eeda158e58a1`; 12 new focused tests and all 600 tests passed in [Ubuntu 26.04 CI](https://github.com/killer23d/VaultWarden-OCI/actions/runs/45455248409/job/138662818750), but [quality-unit](https://github.com/killer23d/VaultWarden-OCI/actions/runs/45455248409/job/138662818230) failed the same-version immutable-release check. Prior result FAIL, not accepted. |
| Remediation implementation | `ee81c8d860847aacd1d96016dfe00a1e89dc973c`: distinct prerelease identity; require all foundations for OPERATIONAL, distinguish boot persistence and execution, verify exact local rclone remote without provider polling, withhold untrusted state on invalid storage, exercise negative readiness/guard/HTTPS cases. This subsequent receipt/test commit does not change installed release content. |
| Focused and regression tests | Local full checkout NOT RUN (GitHub DNS resolution unavailable). First remediation executed 607 tests: one failure in the existing host preflight's exact version grammar; other 606 passed. The existing isolated current-predecessor success and coherent rollback checks passed. Final exact-head validation is mandatory. |
| CI | First remediation [45456495348](https://github.com/killer23d/VaultWarden-OCI/actions/runs/45456495348) passed the immutable identity/update transition but failed `test_current_release_manifest_needs_exact_reviewed_pin` because preflight accepts the established `-rc.N` suffix. Corrected candidate uses rc.17 without modifying the preflight or CI. Exact final-head CI conclusions must be recorded independently in PR. |
| Live acceptance | NOT RUN; disposable native OCI ARM64 host, exact installed source and permitted scope not authorized. Required installed-entrypoint and read-only readiness verification remain HOLD. |
| Limitations | Receipts describe historical verification, not current remote presence, off-host custody or a successful fresh restore. No independent mailbox/public network/provider proof. |
| PR / head | [#444](https://github.com/killer23d/VaultWarden-OCI/pull/444); exact receipt head recorded independently in the PR and handover, not self-referentially in this commit. |
| Verdict | HOLD pending mandatory validation. No merge or next stage authorized. |

### Independent UX-01 review follow-up

The prior exact reviewed candidate `86423a222ebe04e2003c27603b67821dfe87d4ab`
passed all 20 focused tests and all 608 regression tests in quality CI, including
the installed-entrypoint staging checks and current supported predecessor
success and coherent rollback instruments. Its
[push CI 45456776188](https://github.com/killer23d/VaultWarden-OCI/actions/runs/45456776188)
and [PR CI 45456787463](https://github.com/killer23d/VaultWarden-OCI/actions/runs/45456787463)
completed successfully; independently verified all nine job conclusions in
each, including native Ubuntu 26.04 ARM64 and security/Caddy/crypto integrations.

Independent source review found that captured non-TTY status still consumed
persistent history on an unverified mount, notification success could be
inherited across provider changes, incomplete update evidence could look fresh,
unknown doctor aggregate could pass readiness, and optional CrowdSec boot
failure was not reflected in the outcome. The follow-up changes the existing
owners and adds focused regressions. No new runtime dependency, unit or upstream
pin; candidate project identity remains the unaccepted rc.17. No earlier
installed copy may be overwritten or treated as the new source. Exact final
head, focused and complete regression tests, and both CI run references must
be independently recorded in PR #444. Local complete checkout still NOT RUN
(GitHub DNS unavailable). Native OCI ARM64 exact installed-candidate witness
NOT RUN and requires explicit host, source and scope. **HOLD** until final
mandatory evidence is verified. No merge or subsequent stage authorized.

The review also closes the UX-00 F3 bytecode finding where it directly affects
the changed status presentation. Both existing dashboard launchers invoke the
same Python module with bytecode writes suppressed. Expanded immutable-tree
tests invoke the installed dashboard help and the source wrapper without
inherited bytecode suppression. No menu, dispatch, release-selection or
lifecycle redesign belongs to this change. Final installed native ARM64
witness must check the actual dashboard invocation as well as CLI readiness.

## 1. Fixed snapshot and complete repository structure

All source line references in this record refer to
[the accepted snapshot](https://github.com/killer23d/VaultWarden-OCI/tree/03c3437b2191b052534718d94e2ce96f129c62aa),
not a moving branch. Relative source links are navigation aids; use that snapshot
when reproducing line references. The baseline contains **165 tracked files**.
UX-00 adds this one record. The complete tracked-path inventory is in the appendix.

| Location | Baseline count | Responsibility |
| --- | ---: | --- |
| Root files | 10 | `AGENTS.md`, `README.md`, `LICENSE`, `.gitattributes`, `.gitignore`, `setup.sh`, `dashboard.sh`, `vwctl`, `versions.toml`, `email-providers.toml`. |
| `.github/` | 3 | One permanent CI workflow, bounded external-command retry helper, PR checklist. |
| `docs/` | 13 | Product/decision/development boundaries; install/configuration/operations/recovery/security/troubleshooting/token manuals; OCI administration; current and historical acceptance. |
| `reports/` | 1 | Existing three-layer validation policy. |
| `vaultwarden_oci/` | 40 | 39 standard-library-first Python modules including package initializer, plus installed dashboard shell. |
| `systemd/` | 13 | One target, eight service definitions including the notification template, four timers. |
| `tests/` | 85 | 69 `test_*.py` modules, 12 isolated integration/acceptance scripts, and four host-acceptance files (README plus three instruments). |

### Authoritative implementation owners

| Concern | Existing files / ownership |
| --- | --- |
| Public entrypoint and parsing | `vwctl`, `cli.py`, `operator_entrypoint.py`, `update_cli.py`; the latter routes to the correct specialized parser before storage/guard checks. |
| Human presentation and read models | `dashboard.py`, `dashboard.sh`, `operations.py`, `operator_output.py`, `operator_cosmetics.py`; presentation does not own transactions. |
| Setup and immutable installation | `setup.py`, `setup_frontend.py`, `install.py`; thin root `setup.sh`; no copied acceptance harness. |
| Dedicated volume | `storage.py`; device selection, root-family refusal, mount/UUID/marker proof and boot guards. |
| Configuration, runtime and Admin policy | `runtime.py`, `runtime_health.py`, `operator_settings.py`, `admin.py`; config rendering, lifecycle, bounded health settle, existing Admin-policy reconciliation and credential derivation. |
| Secret custody | `secrets.py`; one SOPS document and distinct operational/offline Age identities. |
| Backup, offsite, restore and kit | `recovery.py`, `offsite.py`, `recovery_ux.py`, `sevenzip_secure.py`; existing crypto/artifact/remote/consent owners. |
| Network and security | `edge.py`, `dns_publication.py`, `cloudflare_route_mode.py`, `crowdsec_worker_policy.py`, `crowdsec_boot.py`, `crowdsec_stop.py`; separate origin, host INPUT, DNS and invocation-bound Worker authority. |
| Notifications | `notification.py`, immutable `email-providers.toml`; closed provider catalog and bounded eligible SMTP fallback. |
| Updates and rollback | `update.py`, `update_appliance.py`, `update_candidate.py`, `update_controller_handoff.py`, `update_guard.py`, `update_recovery.py`, `update_status.py`, `update_unit_migration.py`, `update_versions.py`, `predecessor_transition.py`; exact candidates, durable guard, bounded handoff and coherent recovery. |
| Shared durability / package | `durability.py`, `__init__.py`; existing atomic publication primitives, not a new transaction framework. |

Python filenames in this table are under `vaultwarden_oci/`. Installed content is
defined by [install.py](../vaultwarden_oci/install.py):108–109,240–291:
`vwctl`, both immutable TOML manifests, the package and canonical `systemd/`.
Root `setup.sh` and `dashboard.sh` are checkout entrypoints; the installed dashboard
is `current/vaultwarden_oci/dashboard.sh`. Canonical installed launcher is
`/usr/local/bin/vwctl`. The source layout produces 56 immutable release files.

### Production administrator surfaces

The supported surfaces are first-run `setup.sh`, day-2 terminal `dashboard.sh`,
installed `vwctl`, the documented systemd target/services/timers, and the existing
administrator manuals. Vaultwarden's Web Vault and `/admin` remain upstream
application interfaces behind the existing Caddy protection; they are not an
appliance web dashboard or an additional persistent configuration authority.
Root's `rclone config` is the documented offsite-provider prerequisite, not a
second appliance backup owner. Recovery-kit email and notification tests are
explicit outbound actions; the local sanitized support archive is a separate
diagnostic artifact. Provider dashboards remain external administrative surfaces.

## 2. Public command, argument, mode and owner inventory

`vwctl:8-34` disables bytecode before imports, dispatches the bounded controller handoff, invokes `operator_entrypoint.main`, then runs handoff post-command processing. `operator_entrypoint.py:354-382` streams Compose build/start execution only for start/restart, wraps cosmetic output, delegates to `update_cli`, handles core `KeyboardInterrupt` (130 on safe cleanup; 1 if cleanup fails), then applies legacy Admin reconciliation and optional restart guidance. `update_cli.py:668-713` owns extended-command routing, storage/guard gates and help before those gates.

Do not inventory only `cli._parser()`. Production restore/recovery/kit are routed to **`recovery_ux._parser`**; update and host-upgrade use `update_cli` parsers; `install` uses `install._build_parser`. Base `cli.py:416-427,651-687` contains lower-level restore/prune grammar/dispatch that is shadowed by the supported `vwctl` route. Its apparent required identity/no-confirm grammar is not the public installed restore contract.

Forty externally callable leaf-command paths are listed below (including the low-level `install` administrative interface). No global `--json` or global `--yes` exists. All parser levels support `-h`/`--help`; no arguments and top-level help print normal help plus appended recovery/update/host-maintenance sections. `vwctl --version` prints project version; `versions` prints project/components/architecture/exact selected image refs. Normal operation paths are intended to run through installed `sudo vwctl`.

`[]` denotes optional input; alternatives in parentheses are mutually exclusive. Every row also accepts its parser's help flag. Unless specified otherwise, success=0; handled operational/permission/validation failure=1; parser usage failure=2. Cancellation exceptions are documented separately rather than implied as success.

| Public command and full public arguments | Interaction, output and mutation boundary | Existing authoritative owner / baseline source |
| --- | --- | --- |
| `config validate --file PATH` | Read supplied TOML; human PASS/FAIL, deterministic non-TTY | `cli.validate_config`; `runtime.parse_config`; `cli.py:396-400,546-559` |
| `config edit` | Validated temp candidate via VISUAL then EDITOR then nano; no explicit TTY requirement for editor itself; invalid/editor-failed candidate not committed; interactive post-edit restart/legacy reconciliation only with input+output TTY | `runtime.edit_config`, `runtime.py:401-447`; `operator_entrypoint.py:230-351` |
| `versions` | Read source-selected exact manifest and architecture image refs; human label/value lines; no JSON option | `cli._versions`; `update_cli._versions_command`, `cli.py:485-497`, `update_cli.py:627-643` |
| `start` | Explicit lifecycle action, storage and recovery guard gates, runtime health/security, lock; output progress; may build/start; no options/prompt | `runtime.lifecycle`; `cli.py:578-592`; `update_cli.py:695-712`; `operator_entrypoint.py:354-382` |
| `stop` | Explicit lifecycle stop, no outer dedicated-storage gate (allows safety stop); no options/prompt | `runtime.lifecycle`; `cli.py:578-592`; `update_cli.py:14,695-713` |
| `restart` | Explicit lifecycle action with same start safety gates; no options/prompt | `runtime.lifecycle`; same refs as start |
| `status [--json]` | TTY human dashboard; captured text stable base CLI; JSON aggregate schema 1; different exit calculations documented below | `operations.status_payload/status_command`, `runtime.status`, `operator_cosmetics.status`; `cli.py:593-617`, `operations.py:271-319`, `operator_cosmetics.py:53-109` |
| `logs [vaultwarden\|caddy] [--tail N]` | Default both containers, default tail=200, allowed 1..10000; raw Docker logs never color wrapped; invalid tail=2, any container retrieval error=1 | `runtime.logs`; `cli.py:408-410,631-643`; `runtime.py:960-968` |
| `doctor [--json]` | Read diagnostics; schema 1 `{overall,checks:[{id,status,message}]}`; actual installed wrapper inserts storage.dedicated; any FAIL=1, WARN/SKIP can be 0 | `cli.doctor_checks/doctor_payload`; `update_cli._doctor_command`; `cli.py:25-52,301-388`, `update_cli.py:15-22,604-624` |
| `backup [--remote REMOTE:folder]` | Noninteractive; one encrypted local snapshot then configured or one-invocation remote publish/readback; saved retention applied after successful verified backup; one-time override does not persist destination or prune that alternate remote | `offsite.backup` -> `recovery.create_recovery/apply_retention`; `cli.py:644-650`; `offsite.py:114-164`; `recovery.py:516,1257` |
| `restore [--file PATH\|--from-remote REMOTE:object] [--identity PATH] [--start] [--confirm RESTORE]` | No source opens TTY local/recursive-remote picker. Explicit source plus omitted identity opens TTY shared identity chooser. Non-TTY requires source, identity, literal confirmation. `--identity` or `--confirm` without source refused. Verified-source/impact display precedes mutation; TTY final consent follows preflight, while headless consent is supplied through the explicit flag. Default leaves services stopped; --start requests restart/health gate. Cancel=0 with explicit cancelled text | `recovery_ux.guided_restore`, `_offline_identity_for_command`, `_restore_approved`, `restore_remote_once`; final mutation `recovery.restore_recovery`; `recovery_ux.py:630-804,1131-1146,1185-1239`; `recovery.py:1042` |
| `recovery list [--remote REMOTE:folder]` | Local inventory plus explicit or configured remote; recursive remote subfolders; human table; no identity needed; no JSON; inspect history labels, not current decryptability claim | `recovery_ux.list_local/list_remote_points/print_inventory`; `recovery_ux.py:143-240,1250-1259` |
| `recovery verify (--file PATH\|--from-remote REMOTE:object) [--identity PATH]` | Required source; identity chooser if TTY omission, explicit identity required non-TTY; non-destructive application inspection but writes verification metadata and remote temporary download; no JSON; chooser cancel=0 | `recovery_ux.verify_local/verify_remote`; `recovery_ux.py:262-317,1152-1160,1260-1280` |
| `recovery offsite configure [--remote REMOTE:folder]` | When --remote is omitted, TTY lists existing root rclone remotes and asks for the folder. TTY requires literal ENABLE even with an explicit remote. Explicit remote required headless and constitutes selection; probes/prepares destination before atomic saved config commit; no separate scheduler | `offsite.configure`, `runtime.set_backup_remote`; `offsite.py:53-98`; `runtime.py:350-398` |
| `recovery offsite status` | Configured destination/retention/root rclone readiness; local-only is informational success, configured unusable destination is failure | `offsite.status`; `offsite.py:21-40`; `recovery_ux.py:1241-1249` |
| `recovery offsite disable [--confirm]` | TTY literal DISABLE when --confirm is absent; headless --confirm required; only saved destination removed, archives retained; declined prompt=0 | `offsite.disable`; `offsite.py:101-111` |
| `recovery prune --remote REMOTE:folder --keep-last N [--confirm]` | Explicit separate remote deletion plan; without confirm prints keep/delete only; confirmed invokes deletion; N must be at least 1; no age argument (saved age retention is config-owned) | `recovery.prune_remote`; `recovery_ux.py:1168-1171,1281-1293`; `recovery.py:1303` |
| `recovery-kit export [--offline-identity PATH] [--no-email]` | Credential ZIP, not .vwrec. TTY passphrase always required; omitted identity needs input+output TTY chooser. Explicit identity does not permit headless passphrase. Independent passphrase confirmation, AES-256/full-member verification, optional SMTP consent after verification; no JSON. Cancel identity chooser=0 | `recovery_ux.export_recovery_kit` + existing SOPS/7zip/SMTP owners; `recovery_ux.py:887-914,1023-1124,1173-1181,1295-1317` |
| `edge refresh` | Explicit external CIDR fetch/local fail-closed origin-policy update; no options or guided consent | `edge.refresh_origin_policy`; `cli.py:429-431,688-700`; `edge.py:457` |
| `dns status` | Current external public IPv4 and Cloudflare existing A record/proxy status; 0 only in-sync, 1 drift/operational failure; no JSON | `dns_publication.status`; `cli.py:433-438,701-711` |
| `dns update [--dry-run]` | Explicit one-existing-proxied-A-record update/readback; dry-run reports PLAN when change is needed or PASS if already current, with 0; no general DNS ownership and no implicit confirmation prompt | `dns_publication.update`; `cli.py:433-438,701-756` |
| `crowdsec setup` | Explicit package/config/security setup; no options/prompt; reports next invocation/Fail Open step | `edge.setup_crowdsec`; `cli.py:440-442,760-764`; `edge.py:992` |
| `crowdsec remediation-start [--auto-fail-open]` | Explicit single Worker invocation; opt-in experimental API field only when flag supplied; without flag next step human/API Fail Open; boot-disabled policy unchanged | `edge.start_remediation`, `cloudflare_route_mode.ensure_fail_open`; `cli.py:443-447,765-779`; `edge.py:1289` |
| `crowdsec ensure-fail-open` | Explicit experimental mutation/readback for exact currently managed Route/current invocation; no restart | `cloudflare_route_mode.ensure_fail_open`; `cli.py:448-451,780-789` |
| `crowdsec remediation-stop` | Explicit Worker stop, independently verifies process absence and Route cleanup before normalizing only expected upstream SIGTERM failure | `crowdsec_stop.stop`; `cli.py:452-455,790-799` |
| `crowdsec confirm-fail-open` | Operator records reviewed human Fail Open confirmation for current invocation; no automatic current provider-state proof claimed | `edge.confirm_fail_open`; `cli.py:457,811-814`; `edge.py:1331` |
| `crowdsec status` | Human CrowdSec doctor subset; any crowdsec.* FAIL=1 | `edge.doctor_checks`; `cli.py:458,821-826` |
| `crowdsec decisions` | Raw cscli decision stdout/stderr; 0/1 from owner result; outer storage gate exempt | `edge.crowdsec_decisions`; `cli.py:459,827-833`; `update_cli.py:709-710` |
| `crowdsec unban IP` | Explicit removal for one validated IP; no additional confirm; outer storage gate exempt | `edge.crowdsec_unban`; `cli.py:460-461,834-840`; `edge.py:1107` |
| `secrets validate` | SOPS custody/decryption/required fields/admin pairing; no secret output; human 0/1 | `secrets.validate_encrypted`; `cli.py:465-468,560-575` |
| `secrets edit` | Existing validated encrypted SOPS editing owner, independent from config; optional TTY post-edit reconciliation/restart | `secrets.edit_encrypted`; `cli.py:560-575`; `operator_entrypoint.py:230-351` |
| `notification test [--smtp]` | Sends one test via configured closed HTTPS provider or explicit direct SMTP; transport-labeled human result; no TTY required, no JSON | `operator_cosmetics.notification_test` -> existing `notification` transport owner; `operator_entrypoint.py:116-119`; `operator_cosmetics.py:198-241`; base fallback `cli.py:500-531` |
| `timers [--json]` | Target and four timer/trigger/auxiliary health; overall PASS=0 else1; JSON schema1; TTY cosmetic rendering keeps same authority | `operations.automation_snapshot/timers_command`; `operator_cosmetics.timers`; `operations.py:95-207`; `operator_cosmetics.py:112-139` |
| `support-bundle [--output PATH]` | Root-owned sanitized bounded tar.gz; default protected /run support dir; refuses overwrite; omits journal when exact secret redaction cannot be established | `operations.support_bundle`; `cli.py:477-478,621-628`; `operations.py:384-450` |
| `update check [--use-latest] [--json]` | Candidate discovery/freeze/preparation, no activation; normal no-stable-release is success with no candidate; use-latest without stable project release fails; public check does not persist timer history | `update_appliance.candidate_source/prepare_plan`; `update_cli.py:48-68,414-480` |
| `update apply [--use-latest] [--yes] [--rollback-identity PATH] [--json]` | Exact plan, recovery then immutable activation/health; TTY yes/no or --yes; JSON applying available plan requires --yes. No candidate/already active succeeds without mutation. rollback identity explicitly authorizes coherent post-start rollback; failed apply remains nonzero even if rollback succeeds | `update_appliance.apply_prepared`; `update_cli.py:445-534,280-367`; `update_appliance.py:685` |
| `update rollback --recovery-artifact PATH --recovery-sha256 HEX --previous-release NAME --candidate-release NAME --identity PATH [--yes] [--json]` | All identity/evidence flags required; explicit consent/--yes, JSON requires --yes; exact artifact/previous/current candidate coherence; successful rollback=0, cancellation=2 | `update_appliance.reconstruct_failure/coherent_rollback`; `update_cli.py:69-83,370-411`; `update_appliance.py:880` |
| `host-upgrade check [--json]` | **Mutates apt indexes** (`apt-get update`) then simulates conservative upgrade; root+mutation lock; do not classify read-only because its verb is check | `update_appliance.host_upgrade_check`; `update_cli.py:87-95,537-557`; `update_appliance.py:1199-1211` |
| `host-upgrade apply [--yes] [--json]` | Separate root host-package mutation, verified application recovery first, conservative apt upgrade; never reboots and .vwrec cannot undo packages/kernel; TTY confirm or --yes; cancellation=2 | `update_appliance.host_upgrade_apply`; `update_cli.py:558-601`; `update_appliance.py:1214-1229` |
| `install --source PATH [--use-latest]` | Low-level immutable-layout administration, not normal blank-host UX; required source, storage/guard gate; no auto confirmation prompt; inspect and retain but do not promote hidden bypass flags | `install.main/install_layout`; `install.py:493-540`; `update_cli.py:691-700` |

### Service and development forms

- `notify --event EVENT`: hidden service entrypoint; event regex `^[A-Za-z0-9_.@:-]{1,160}$`; invalid=2, provider absent=0 SKIP before secret/delivery, delivery failed=1; `cli.py:55,480-481,841-869`, `operator_cosmetics.py:244-283`. `systemd/vaultwarden-oci-notify@.service` delegates here.
- `dns update --timer`: hidden timer path; controlled transient retries/debounce, transient below threshold=0 WARN, lock contention=0 SKIP, structural/threshold failure=1; `cli.py:438,712-756` and `dns_publication.py`. Independent DNS service pulled in by health service. Do not expose --timer as a human choice.
- `update check --timer [--json]`: hidden persisted-check/notification form; `record_check` only reached by --timer paths; `update_cli.py:61,430-437,471-479,519-529`; `update_appliance.py:1157-1192`.
- `crowdsec boot-reconcile`: hidden opt-in oneshot boot service; owner `crowdsec_boot.reconcile`; `cli.py:456,800-810`, `systemd/vaultwarden-oci-crowdsec-boot.service`. Existing boot unit disabled by default; no automatic permission inferred.
- `crowdsec prepare-remediation` / `consume-start-token`: hidden package-service preparation/token consumption; `cli.py:462-463,815-820`; owner `edge`.
- `__update-candidate {prepare,activate} --versions PATH --render-root PATH` and `__update-candidate stop`: private exact candidate subprocess interface, no normal help (`update_candidate.py:400-430`, `update_cli.py:670-673`).
- `update {check,apply} --source PATH`: hidden source fixture/development form, not arbitrary public release version picker (`update_cli.py:53`).
- `install --root PATH --skip-host-check --skip-systemd-reload`: hidden isolated testing/development controls (`install.py:497-499`), not production safety bypass directions.

### Setup grammar and custody modes

Canonical frontend `setup.sh` requires root before dispatch, resolves its own checkout, unsets `PYTHONPATH`, invokes `/usr/bin/python3 -B -E -m vaultwarden_oci.setup_frontend` (`setup.sh:1-14`). This entrypoint already suppresses bytecode. `setup_frontend` uses `setup._parser()` for custody and latest decisions rather than independently inspecting argv (`setup_frontend.py:67-108`).

Complete installation syntax:

`setup.sh install --domain DOMAIN --url HTTPS_URL --email EMAIL [--data-device DEVICE] [--data-mount /var/lib/vaultwarden-oci] [--offline-recipient age1...] [--accept-existing-filesystem] [--confirm-format] [--auto] [--use-latest] [--dry-run]`

- Domain, URL and email required. Mount has a parser option but any noncanonical mount is rejected; one storage authority remains (`setup.py:207-227,374-380`).
- Explicit data-device required with --auto or non-TTY; interactive non-auto may display storage inventory/select candidate. `q` returns handled SetupError/1. `--auto` never guesses a disk.
- Blank-device formatting and reuse of existing filesystem remain separate affirmative controls under `storage.provision`; flags above must not become implicit because a new guide selected the device.
- Terminal stdin plus no explicit offline recipient allows transient root-only offline identity generation (including --auto). Fully headless path cannot generate custody; existing public recipient required before storage mutation. Explicit recipient remains authoritative in split, equals and argparse-supported abbreviations. --dry-run never generates identity (`setup_frontend.py:83-90`; `setup.py:396-407`).
- --auto does not imply --use-latest. A successfully parsed --use-latest request always displays the latest warning; manual non-auto stdin-TTY has yes/no confirmation (decline/EOF=2). Auto/non-TTY explicit flag proceeds with warning (`setup_frontend.py:93-108,213-215`).
- Dry-run validates host/device/recipient then returns 0 and no filesystem/package/config/secret/systemd mutation; do not infer installed state (`setup.py:392-406`).
- Setup returns 1 on handled owner failure. Successful install without generated-custody flow returns 0 plus next actions. Generated-custody success requires external-credential completion, complete ZIP verification, SMTP handoff or explicit SAVED acknowledgement, then exact transient key cleanup; handoff failures retain/report a completed protected identity if still present; failed generation/recipient derivation instead cleans its incomplete workspace (`setup_frontend.py:208-291`).
- Frontend also retains `setup.sh recovery-kit export [--offline-identity PATH] [--no-email]`, delegated to same recovery_ux parser/owner (`setup_frontend.py:211-212`); this is not a second kit implementation.

### Machine output, exits and compatibility

1. **Human/captured/JSON status are different interfaces.** Captured/non-TTY `status` is base CLI and returns0 for runtime running/stopped unless notification state is failure or any result from `edge.doctor_checks` is FAIL; otherwise1 (`cli.py:593-617`). TTY `status` uses dashboard renderer and `_status_exit_code` checking runtime running/stopped, notification failure and the **edge-only** aggregate (`operator_entrypoint.py:107-115`; `operator_cosmetics.py:53-109`). JSON status returns1 for doctor overall FAIL or automation overall FAIL; it does not directly use runtime overall for exit (`operations.py:271-319`). Thus inactive automation can render FAIL yet human status return0; JSON1 accurately represents unavailable automation, not necessarily runtime failure. A CrowdSec-only FAIL can also yield TTY0 vs captured1/JSON1 because the cosmetic boundary omits `crowdsec.checks`. Audit-only characterization below confirms this. Do not silently normalize these exit codes during presentation work; preserve machine/systemd contracts and explicitly scope any later corrective contract change.
2. `doctor [--json]` aggregate fails only if a check FAILs; WARN and SKIP remain nonfailing. Installed routing registers 27 stable IDs (26 base IDs plus storage.dedicated). Preserve IDs/status vocabulary/schema1 and storage ordering. Source `cli.py:25-52,382-388`, `update_cli.py:15-22,604-624`.
3. JSON surfaces: status, doctor, timers, update check/apply/rollback, host-upgrade check/apply. No recovery/backup/DNS/notification/support/versions JSON flags exist. JSON disables color and cosmetic guidance; logs are never recolored (`operator_entrypoint.py:88-105,152-155`). `NO_COLOR` and non-TTY behavior remain respected by existing UI classes.
4. **Update apply JSON may emit multiple JSON objects**: plan stdout first, then applied result stdout, or error stderr. Do not promise one whole JSON document (`update_cli.py:466-516`). Rollback and host-upgrade emit result objects; guard/storage/operational errors emit schema1 error objects to stderr. Post-state failure returns1 even when coherent rollback succeeds, with explicit rollback_attempted/rollback_succeeded booleans (`update_cli.py:256-367`).
5. Cancellation baseline is inconsistent but deliberate behavior must be inventoried: restore, verify, kit chooser and offsite prompts return0 with cancelled text; update/rollback/host-upgrade denied prompt or required --yes absence=2; setup latest cancellation=2; setup storage cancellation=1. Parser errors also2; core KeyboardInterrupt caught by operator_entrypoint=130 (cleanup failed=1). These values cannot alone prove execution completed. See exact command owners above. Recovery crypto/metadata should not be recorded as verified upon cancelled restore.
6. Help routes execute before storage and recovery-required gates (`update_cli.py:674-693`) and must remain usable on broken hosts. Low-level install exists but top-level help's appended sections do not advertise it. Most unknown arguments hit argparse=2; doctor installed path hand-parses `--json` in `_doctor_command` rather than parsing all args, so do not overstate universally strict parser behavior.
7. Read-only sounding operations are not all mutation-free: host-upgrade check refreshes apt indexes; recovery verify records verification history; offsite configure may create remote directory; update timer check persists state and can send mail; support bundle writes an archive. New guide prerequisites/consent must accurately describe those boundaries.
8. Guard is checked for start/restart/restore/install/update apply/host-upgrade apply; no current aggregate status/doctor guard field exists. Do not duplicate guard loader or clear guard from the UI (`update_cli.py:128-171,445-455,558-561,695-696`).
9. `operations` already includes independent DNS service in health timer auxiliary diagnostics and counts its genuine failure (`operations.py:24-26,125-162`; `tests/test_operations.py:114`). A plan must not claim DNS service diagnostics are wholly absent. Separate readable DNS state and boot-rearm detail may still be missing from dashboard; boot service is not in the four timer list.
10. A normal public manual update check does not refresh persisted dashboard history because recording is --timer-only. Existing snapshot has check age/stale fields, but inspection/freshness presentation must not turn stale last-known data into current protection (`update_status.py:10,22-45`, `update_cli.py:430-437,471-479`).

### Stable installed doctor IDs

Source: `cli.py:25-52` plus installed wrapper insertion `update_cli.py:15-22`.

`host.os`, `host.architecture`, `config.toml`, `versions.toml`, `runtime.docker`, `runtime.compose`, `runtime.paths`, `storage.dedicated`, `secrets.custody`, `secrets.decrypt`, `notification.catalog`, `notification.provider`, `notification.api_secret`, `notification.smtp_fallback`, `notification.last_delivery`, `edge.caddy.trusted_proxy`, `edge.admin.protection`, `edge.caddy.health`, `edge.cloudflare.cidrs`, `edge.cloudflare.iptables`, `crowdsec.engine`, `crowdsec.hub`, `crowdsec.firewall`, `crowdsec.cloudflare`, `recovery.local`, `recovery.offsite`, `recovery.rclone`.

## 3. Existing dashboard compared with supported CLI

Entrypoints: repository `dashboard.sh` (lines 4–8), installed `vaultwarden_oci/dashboard.sh` (4–8), both execute `/usr/bin/python3 -P -m vaultwarden_oci.dashboard` using release-relative `PYTHONPATH`, with `PYTHONHOME` unset and user site disabled. `main()` supports only `-h`/`--help`; unknown args exit 2; non-root exit 1; q/e, EOF, Ctrl-C exit 0 (`dashboard.py:396–438`). There is no TTY-required check beyond root; non-TTY EOF is handled as normal exit. Dashboard has no independent mutation owner; subprocesses call `vwctl`. Main menu has nine categories and number/letter shortcuts (382–417).

| Current menu | Exact current actions | Source |
|---|---|---|
| Stack | `start`; `stop` after dashboard y/N; `restart`; `status` | `dashboard.py:260–266` |
| Diagnostics | `doctor`; `logs vaultwarden --tail 200`; `logs caddy --tail 200`; direct bounded `journalctl`; `support-bundle` | `dashboard.py:269–276`, `212–233` |
| Backup & Recovery | `backup`; one-time `backup --remote <typed REMOTE:path>`; `recovery list`; `recovery verify --file <typed path>`; `recovery verify --from-remote <typed object>`; guided `restore`; `recovery offsite configure`; `recovery offsite status`; `recovery offsite disable --confirm` after dashboard y/N | `dashboard.py:279–299` |
| Security | `doctor`; `crowdsec status`; `crowdsec decisions`; `crowdsec unban <typed IP>`; `dns status`; `dns update --dry-run`; `dns update` after y/N; `edge refresh`; `crowdsec remediation-start`; manual `crowdsec confirm-fail-open` after explanation and y/N | `dashboard.py:302–339` |
| Config & Secrets | `config edit`; `config validate --file /etc/vaultwarden-oci/config.toml`; `secrets edit`; `secrets validate` | `dashboard.py:342–348` |
| Recovery Kit | `recovery-kit export`; same with `--no-email` | `dashboard.py:351–357` |
| Email & Notifications | `notification test`; `notification test --smtp` | `dashboard.py:360–364` |
| Updates & Host | `update check`; `update apply`; both with explicit `--use-latest`; `host-upgrade check`; `host-upgrade apply` | `dashboard.py:367–375` |
| Automation | `timers` only, no mutation | `dashboard.py:378–379` |

All current menu command routes still exist. There is no source-grounded case for deleting an entry because its CLI command was removed. Manual Fail Open confirmation is still a supported fallback, not an obsolete action. No private systemd or updater subcommand should be promoted to a general menu merely for parity.

### Missing discoverability / presentation revision candidates

- `versions` has no dashboard action, although update header exposes only project version. Expose exact versions in diagnostics, not every component pin on the home view.
- `crowdsec setup`, supported controlled `crowdsec remediation-stop`, opt-in `crowdsec ensure-fail-open` and `remediation-start --auto-fail-open` are absent. Map to `edge.py`, `crowdsec_stop.py`, `cloudflare_route_mode.py`; distinguish API readback from manual attestation and explain the undocumented provider field. Preserve explicit consent.
- `update rollback` has no guided dashboard entry; any entry must use the existing recorded failed-update owner and exact artifact/previous/candidate binding, not generic rollback or clear-guard controls.
- `recovery prune --remote --keep-last [--confirm]` is absent. Keep destructive pruning in an advanced, explicit preview/confirmation workflow; do not make it routine housekeeping or duplicate retention logic.
- `recovery list --remote` is absent as an inventory shortcut (remote guided restore already exists). `restore --start` is not offered by the current dashboard, which calls plain `restore`; preserved default is stopped after restore, not an implicit restart. Explicit CLI file/identity/confirm options need not all become menu fields.
- Supported automation activation and opt-in Worker boot service are documented systemd operations, not dashboard actions; absence is a UX opportunity, not permission to create a scheduler or auto-enable services. Owner remains systemd. `crowdsec boot-reconcile` is an internal service command, not the toggle.
- Notification provider selection/configuration is available through existing config/secrets edits, not a special guided screen. Do not create a new provider catalog.
- Recovery verification requires typed local/remote paths in its menu actions despite an existing recovery picker. Reuse `recovery_ux` where needed rather than reproducing key/ZIP handling.
- Top-level "Rclone", security engine/hub/firewall/worker breakdown, "Stack", and raw systemd phrases expose implementation details to the junior administrator. Keep these available in drill-down; home view should prioritize availability, recovery freshness/policy, security blockers and next action.
- "Cloud mirror"/"saved offsite mirror" labels are unconditional even in local-only mode; "Disable scheduled offsite" also affects manual backups because one saved remote controls both. Clarify policy scope.
- `--use-latest` is a supported expert override, but equal prominence next to the recommended stable update path is unnecessary. Keep accessible with existing freeze/warning/confirmation semantics.
- "Doctor" and "Security doctor" execute the same complete diagnostic command. Label purpose/context rather than implying separate health algorithms.
- Support-bundle creation writes a local sanitized artifact; notification tests send real mail; host-upgrade check refreshes apt indexes. Guided explanations should state those effects rather than call all of them read-only.

## 4. Confirmed source findings

These are baseline findings, not fixes. Tests that characterize a defect do not
prove it has been corrected. No actual installed release switch, live guard
injection or provider operation was performed in this audit.

### F1 — Release-local command bypasses installed launcher: CONFIRMED

`dashboard.py:11–12,46–52` resolves one release root at import and always executes
that release's `vwctl`. The canonical launcher is `/usr/local/bin/vwctl`
(`install.py:33–45`); the bounded update-controller handoff may temporarily route
only update commands to an exact staged target (`update_controller_handoff.py:267–419`).
Calling the selected release directly bypasses that launcher. An isolated mock
confirmed the dashboard's dispatched path. The implemented historical handoff is
specifically bounded to dev.16 → dev.17; no active rc.16 handoff was observed.

Future change: correct installed-context dispatch in the existing entrypoint,
preserving source-checkout use and hostile PATH/PYTHONPATH defenses. Existing
handoff/source-checkout tests remain authoritative; no second update dispatcher.

### F2 — Dashboard retains old code after selection changes: CONFIRMED SOURCE RISK

The fixed path above and long-lived loops (`dashboard.py:244–257,418–431`) survive
an update or restore. `_status()` refreshes data through that same executable;
it does not reload imported presentation code. Source-local version loading
(`update_status.py:31–37`) can also show the old identity. There is no selection
comparison or re-exec. This is source-grounded risk, not a live switch result.
Later fixtures must cover selection change, handoff and failed update together;
changing only the subprocess path does not refresh the dashboard module.

### F3 — Dashboard can write immutable-release bytecode: CONFIRMED AND REPRODUCED

Both dashboard shells use `/usr/bin/python3 -P` without `-B` or bytecode
suppression (each shell:4–8). `vwctl:8–15` suppresses its own imports only.
Installed 0555/0444 modes (`install.py:253–262`) do not prevent root writes.
In an isolated writable copy of the installed file set, with inherited bytecode
suppression/cache-prefix removed, dashboard `--help` exited 0 and created two
files: `__init__.cpython-313.pyc` and `dashboard.cpython-313.pyc` under `__pycache__`.
The dashboard shell used native `/usr/bin/python3` 3.13.5; the test driver used
Python 3.12.14. No appliance tree was touched.

Expand existing `test_immutable_vwctl_bytecode.py` and `test_dashboard_install.py`
coverage in the authorized entrypoint stage. Current dashboard installation/help
coverage does not assert before/after tree integrity.

### F4 — Command return code becomes an invented outcome: CONFIRMED

`dashboard.py:199–209` prints successful completion for every exit 0 and failure
for every nonzero exit. Existing restore/key/verify/kit cancellation returns 0
(`recovery_ux.py:714–804,1196–1310`); offsite configure/disable can also decline
without error (`offsite.py:53–111`). Update/rollback cancellation instead returns
2 (`update_cli.py:382–387,492–497`). An isolated mock of a zero subprocess result reproduced the success footer;
the cited owner paths establish that cancellation can return that same code. Existing owner cancellation tests protect no-live-mutation,
not this dashboard footer.

Preserve those CLI codes and owner messages. The smallest initial correction
should stop asserting mutation completion from exit status alone. Any richer
outcome presentation must use existing owner context, not regex-parse prose or
introduce a workflow state engine.

### F5 — Historical offsite receipt looks like current protection: CONFIRMED GAP

`recovery.status_rows():1331–1347` labels a stored verification timestamp as
verified; `operations.py:237–245` adds age/staleness; `dashboard.py:107–114,162`
displays that receipt without saved-policy/destination matching. A recent record
can therefore remain green after offsite disable or destination change. The
isolated receipt-rendering probe confirmed this missing context.

Other owners already tell the truth: `recovery.doctor_checks():1358–1382` labels
disabled publishing/prior success as historical, and `offsite.status():21–40`
shows saved policy. Reuse those authorities. Distinguish local-only, configured
but unverified, latest successful publication, historical, stale and unknown;
retain history and avoid remote probes on every redraw. Receipt age is not
independent proof of current custody or disaster recoverability.

### F6 — Stale update history outranks the stale warning: CONFIRMED AND REPRODUCED

`update_status.py:10,22–45` marks persisted checks stale after 48 hours.
`dashboard.py:183–194` prioritizes error/available/availability-reason before that
flag. A 199900-second-old no-stable-release reason rendered without a stale label
in the isolated probe, even though its age was shown. Old candidate availability
has the same precedence problem.

Manual `update check` does not refresh this persisted timer history; recording
is restricted to `--timer` (`update_cli.py:430–437,471–479,519–529`). Label the
evidence source and freshness truthfully. Do not silently add persistence to a
public check merely to change presentation. Current setup guidance also claims
manual checking seeds the snapshot (`setup_frontend.py:204`), which disagrees with
this persistence boundary. Existing fresh-state tests do not cover stale-reason
precedence.

### F7 — Recovery-required guard is not surfaced in the read model: CONFIRMED

`update_guard.py:10,83–120` owns the protected guard; `update_cli.py:128–171`
supplies fail-closed refusal and exact recovery guidance. Start/restart/restore/
install/update apply/host-upgrade apply are gated. Current operations status,
doctor and dashboard do not expose this state (`operations.py:271–319`,
`cli.py:370–379`, `update_cli.py:604–624`, `dashboard.py:146–196`). Blocking exists;
the missing part is explaining it before an attempted mutation.

A future read-only view must reuse the guard loader and preserve permission/
corrupt-state errors as blocked or unknown. Never offer UI guard clearing or
arbitrary old-code selection. Keep guard, interruption and coherent-rollback
tests intact.

### F8 — DNS and CrowdSec boot diagnostics: PARTLY CONFIRMED

Dashboard and support-bundle journal allowlists omit both
`vaultwarden-oci-dns.service` and `vaultwarden-oci-crowdsec-boot.service`
(`dashboard.py:212–233`, `operations.py:356–375`). The home view lacks distinct
DNS and boot-rearm outcomes. However, DNS **already is** a health-timer auxiliary:
`operations.py:24–25,125–158` propagates its actual failure, and the Security menu
already offers DNS status/dry-run/update. Do not describe DNS diagnostics as
wholly absent or propose another scheduler.

The opt-in boot unit is a one-shot, not a fifth required timer. Its intentional
disabled state must not become a failure. Preserve boot-disabled package Worker,
`Restart=no`, no automatic retry and fresh invocation/Fail Open proof. Relevant
tests include DNS publication, operations automation and CrowdSec boot/stop.

### F9 — Status modes differ; one discrepancy needs separate review: CONFIRMED

| Mode | Existing exit calculation | Source |
| --- | --- | --- |
| Exact TTY `status` | 0 for running/stopped runtime, no notification failure and no FAIL in `edge.checks`; aggregate doctor/automation does not determine exit. | `operator_entrypoint.py:107–115`; `operator_cosmetics.py:53–76,104–109` |
| Captured/non-TTY `status` | 0 for running/stopped runtime unless notification or any `edge.doctor_checks()` result fails; that function also includes CrowdSec. | `cli.py:593–617` |
| `status --json` | 1 if aggregate doctor or automation is FAIL, otherwise 0; this is not a general Boolean of every displayed field. | `operations.py:316–319` |

Tests explicitly preserve the human versus aggregate doctor/automation difference
(`test_operator_cosmetics.py:33–48`, `test_operations.py:200–211`). Separately,
the TTY function omits `crowdsec.checks`: a mocked CrowdSec-only failure produced
TTY=0, captured=1, JSON=1. That is a **potential defect confirmed by audit**, not
an approved intentional exception or previously covered regression contract.
No status exit was changed here. The health service uses captured plain status
(`systemd/vaultwarden-oci-health.service:13`), so substituting aggregate JSON
would alter its failure boundary. Preserve visible genuine FAILs and explicitly
scope any later exit correction.

## 5. Existing guided workflows and reusable presentation

| Existing presentation/guided responsibility | Current owner / reusable entrypoint | Preservation and extension boundary |
|---|---|---|
| Dashboard home/status, menu, bounded command screens | `dashboard.py:16–34` Style; `_menu`, `_confirm`, `_command_screen`, `draw_header`, `draw_status` | Keep presentation only; improve truthfulness/routing and outcomes without moving mutation code here |
| Shared operator label coloring / NO_COLOR / no non-TTY ANSI | `operator_output.py:23–63` and `operator_entrypoint.py:88–104` | JSON and raw application logs remain unmodified; no-output parsing state machine |
| Human status and timers | `operator_cosmetics.py:53–139`, operations authoritative snapshot | Preserve known exit boundaries and target-owned activation; keep detailed failures available |
| First-run choices, setup latest warning, generated offline custody, config/secrets completion, off-host handoff | `setup.py:43–53`, `207–227`, `374–425`; `setup_frontend.py:67–123`, `134–205`, `208–278` | Same authoritative setup parser; generated key volatile/root-only; explicit recipient preserved; headless recipient required before mutation |
| Secure offline key chooser (hidden paste, path, local recovery kit, explicit encrypted kit path), cleanup | `recovery_ux.py:546–651` | Reuse exactly for guided recovery/verification/kit export; never argv/env secret passphrases or persistent offline key |
| Recovery inventory, local/remote validation, exact artifact final consent | `recovery_ux.py:143–240`, `262–349`, `654–804` | Verify before live mutation; cancellation no recording/live changes; explicit non-TTY `--identity` and `--confirm RESTORE` remain |
| Offsite setup/disable and policy notices | `offsite.py:21–111`; `recovery_ux.py:689–711` | Config saved remote owns every scheduled/manual backup; one-time override remains per invocation; retention remains existing owner |
| AES-256 recovery kit complete verification / optional SMTP | `recovery_ux.py:887–1124` and shared chooser | Separate from .vwrec; passphrase never argv/env/file/email; truthful local-kit versus email acceptance; no off-host custody proof invented |
| Validated config/secrets edit, legacy Admin reconciliation, restart offer | `runtime.py:411–448`, `secrets.py`; `operator_entrypoint.py:207–351` | One TOML plus encrypted SOPS; deferred/restart-failed outcomes distinct; secrets value redaction |
| Lifecycle progress and interrupt cleanup | `operator_entrypoint.py:18–85`, `354–382` with runtime lifecycle owner | Cleanup only if compose lifecycle actually started; exit 130 on safe interruption; no blanket stop from read-only interrupted UI |
| Stable/latest update explanation, explicit apply, failed-update recovery, separate Ubuntu packages | `update_cli.py:25–45`, `212–253`, `280–400`, `445–601`; underlying `update_appliance.py` / `update_recovery.py` | Reuse prepared transaction/rollback owners; pre-update recovery; exact pins; no blind downgrade; host changes outside application rollback |
| First-start/doctor/automation next actions | `operator_entrypoint.py:125–205` | Guidance does not enable automation itself or suppress genuine errors |
| Notification test/context | `operator_cosmetics.py:149–283`, `notification.py` | Closed catalog and bounded fallback; real delivery acceptance versus independently received mail distinguished |

Color-label helper duplication exists across `setup.UI`, `recovery_ux.UI`, and `update_cli.UI`, with `dashboard.Style` and `operator_output.ColorizingWriter` serving different formatting needs. A very small shared label/color helper is justified only when a later concrete change removes real duplication. This does not justify a workflow framework, general repair system, or new state owner.

## 6. Safety boundaries and command-owner mapping

The complete command table above identifies dispatch owners. These cross-cutting
boundaries determine what a future guide may orchestrate and what must remain in
the existing implementation.

| Boundary | Existing authoritative behavior / baseline source | Regression evidence |
| --- | --- | --- |
| Setup / config / custody | `setup_frontend.py:208–291` delegates installer and kit owners; `setup.py:390–411` refuses missing headless custody before provisioning. One config TOML/SOPS document; operational and offline identities remain distinct. | Setup-auto/storage/templates/SOPS tests; G1 scoped host evidence. |
| Dedicated storage | `storage.py:72–91,130–167,227–263` rejects boot family, verifies mount/UUID/marker/root separation and requires explicit format/adopt; no root fallback. | Storage/setup and both host-instrument test suites. |
| Immutable files / mutation lock | `install.py:108–109,204–291,387–424` owns installed file identity/modes and lock inode. `cli.py:240–257` owns nonblocking flock. UI must not add a competing lock or patch installed files. | Install, immutable-entrypoint, handoff/source-identity and lock tests. |
| systemd lifecycle / schedule | Thirteen canonical units; target activates four timers. Lifecycle has protected RuntimeDirectory, installed start/stop and bounded startup. Backup runs through the real unit sandbox with root rclone configuration access. | Systemd-runtime, operations and target tests; G5 service/timer evidence. |
| Independent DNS / local health | Health pulls in a separate DNS service; DNS `update --timer` has its own failure notification. `dns_publication.py:315–367,405–431` updates only one existing proxied A record, independently reads back, and debounces only transient errors. | DNS and automation tests; G5 no-change DNS/native health timer. |
| Origin / CrowdSec / Worker | `edge.py:880–1097,1393+` separates Docker origin filtering from nftables host INPUT. Worker policy/Route owners bind local decisions and Fail Open to the current invocation. `crowdsec_boot.py:23–74` adds only the explicit one-shot rearm; controlled stop proves process/Route cleanup. | Edge/firewall/Worker/route/boot tests plus package and packet integrations. |
| Recovery / publication | `recovery.py:673–715` refuses collisions, uses non-destructive publication and independently reads back ciphertext. `1042–1123` decrypts, verifies offline SOPS/manifest/SQLite/targets and stages before lock/stop/promotion. Publication never uses sync; configured positive age retention runs afterward, while explicit CLI pruning retains its own plan/confirmation. | Recovery, offsite, UX and real temporary crypto integrations; G3/G4 scoped host evidence. |
| Recovery kit / notification | `recovery_ux.py:887–1124` owns separate AES ZIP and passphrase/custody/email sequence. `notification.py:831–878` uses the closed provider catalog and eligible bounded SMTP fallback. Direct SMTP alone does not enable operational alerts. | Kit/prompt/SMTP-owner, notification/security/support-redaction tests and ZIP integration. |
| Update / guard / coherent rollback | `update_appliance.py:685–877` durably verifies recovery and guards before pointer/unit changes; possible mutation or interruption quarantines rather than blindly downgrading. `880–1048` recovers exact prior data/release, proves health then clears guard. `update_cli.py:668–708` protects public mutation routing. | Update guard, durability, failure, interruption, rollback/crash-safety suites and isolated predecessor transactions. |
| Host maintenance | `update_appliance.py:1199–1229` keeps explicit host package work separate. The narrow historical dependency transition is forward-only host state outside `.vwrec` rollback; no general upgrade/reboot is implied. | Host workflow and forward-only host rollback tests. |

## 7. Acceptance history and current dependency baseline

[HOST-ACCEPTANCE.md](HOST-ACCEPTANCE.md):27–161 is the active rc.15 reconciliation.
This audit read those committed operator reports and evidence references; it did
not access VM9 or private receipts. Keep original wrapper HOLDs/FAILs intact and
recognize later reconciliation only for its stated scope.

| Gate | Accepted scope | Limits preserved |
| --- | --- | --- |
| G1 | Ubuntu 26.04 ARM64 blank dedicated-disk install, 56 exact installed files/modes/owners, distinct SOPS recipients, volatile offline-key cleanup, verified five-member AES ZIP and matching emailed ciphertext. | Initial heredoc false-success and hostname-expectation HOLD remain historical. G1 alone did not prove off-host decryption. Source: lines 43,52. |
| G2 | Healthy runtime/Caddy/Admin TLS and invocation-bound Worker/Fail Open; genuine Cloudflare HTTPS; direct public TCP22/80 denial; private non-Cloudflare HTTPS denial corroborated by Docker DROP delta +6; independent direct SMTP mailbox receipt. | Public probe's earlier counter gap remains; later private counters are correlated, not per-source attribution. OCI effective policy API inventory NOT RUN. Source: lines 44–47,54–64. |
| G3 | Isolated encrypted Box publication/readback, local encrypted-kit identity, actual remote restore of exact original user/cipher, newer cipher absent, SQLite/SOPS/runtime/security reconciliation. | Collision and interrupted-prompt receipts preserved. Nonzero status reflected intentionally inactive automation. Later manual item smoke scoped separately. Source: lines 81–99. |
| G4 | 294 native ARM64 focused tests, 56 immutable files, missing-identity/confirmation/wrong-key/corrupt-archive refusals, native cancellation and unchanged live safety evidence. | Actual live failed-update quarantine/coherent rollback NOT RUN; wrapper HOLDs preserved. Source: lines 101–128. |
| G5AB/CR | Unit/source/storage proof, lifecycle convergence without container recreation, actual backup/maintenance/update-check/health and independent DNS services, target-owned four-timer activation, fresh check state and safe scheduling isolation. | G5C wrapper HOLD preserved; service execution is distinct from natural interval firing. Source: lines 130–138. |
| G5D/F | Operator independently decrypted emailed kit; genuine health-timer dispatch and separate DNS; saved isolated Box remote through actual backup service with independent readback; Web Vault/original-item/newer-item absence and both Admin layers manually confirmed. | Off-host/browser evidence is operator-reported; full backup/maintenance/update-check intervals and broader clients/Admin mutations were not exercised. Source: lines 140–161. |

G5 independently compared integrated `fc7d00c43ad9601d6bc4feda9089cef8d8b95ef6`
with installed `162289365800ffe814517fbed920b5066cba4c33` across release content and
entrypoints: unchanged rc.15, Vaultwarden 1.37.4, Caddy 2.11.7. Earlier rc.11/12/13
then-current limitations remain historical records; they must not overwrite later
scoped rc.15 evidence or be silently relabelled current PASS.

### Pin refresh

Baseline `03c3437b2191b052534718d94e2ce96f129c62aa` integrated only the reviewed
manifest change from [PR #442](https://github.com/killer23d/VaultWarden-OCI/pull/442),
head `981c403a41ff1ab465e136d4fe1e54558b2eca67`. Its closing comment records the
authorized alternate squash; native GitHub `merged=false` does not mean its exact
tree was unintegrated. The temporary [registry discovery](https://github.com/killer23d/VaultWarden-OCI/actions/runs/45324571754)
and [pin-refresh CI](https://github.com/killer23d/VaultWarden-OCI/actions/runs/45324659297)
are historical references, not fresh live acceptance. This audit independently
read the PR, final manifest and baseline CI metadata.

| Preserved manifest field | Value at UX-00 base |
| --- | --- |
| Project | `0.1.0-rc.16` |
| Vaultwarden / Caddy | `1.37.5` / `2.11.9` |
| Addons | Cloudflare DNS `v0.2.4`; trusted-proxy commit `f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5`; combine ranges `v0.0.1`; rate limit `v0.1.0`. |
| Images | All six architecture-specific Vaultwarden/Caddy-builder/Caddy-runtime digests unchanged; exact values in [versions.toml](../versions.toml). |
| Manifest blob | `15117bc56ff4bc5603d5c94379b8c9e4f0bf0af3` |
| Manifest SHA-256 | `437f9f846f298457fabe55b891bdeb6f295a7e3207e5df04d3c067ee1d74537c` |

No further upstream lookup/refresh or pin change was performed. rc.16 needs its
own applicable native ARM64 changed-image/custom-Caddy/runtime/HTTPS/Admin/data/
recovery evidence before release acceptance. UX-00 cannot transfer rc.15 host
results to these new bytes.

### Explicit remaining coverage limits

- VM9 live failed-update quarantine/coherent rollback: **NOT RUN**. Separate VM8
  supported upgrade/reboot evidence and isolated failure tests do not replace it.
- OCI effective security-list/NSG API policy inventory: **NOT RUN**, a deployment
  administrator gate. Do not infer all provider/public protection from local policy.
- VM9 optional HTTPS notification and fallback: **NOT RUN**; direct SMTP receipt
  passed but does not by itself enable operational failure notifications.
- Natural backup/maintenance/update-check intervals: **not observed on VM9**;
  actual service execution and target activation passed; natural health firing passed.
- G5 host-package apply/reboot: **NOT RUN**; reboot-required remained true.
  VM9 boot rearm remained disabled; any production rearm needs explicit choice
  and fresh invocation/Fail Open verification.
- Broader Admin mutations, native clients and exhaustive item workflows:
  **NOT RUN**; G5F browser smoke has only its recorded scope.
- AMD64 live host: **NOT RUN**, and not required for this UX contract. Native OCI
  ARM64 remains the production live gate.
- rc.16 live acceptance, release publication and production deployment remain
  separate. VM9 was deliberately left local-only, zero-retention, with target/
  four timers disabled and app/lifecycle/Worker running; this is not a configured
  production site. No further unchanged-rc.15 acceptance replay is justified here.

## 8. Proposed UX architecture and stage dependencies

### Architecture

Keep the existing terminal dashboard and setup frontend as thin presentations of
the authoritative CLI and its owners. Use `operations` for bounded read-only
aggregation of existing state; existing owners supply policy and evidence. Use
systemd for lifecycle and scheduling. A dashboard redraw must not create a
backup, contact a remote merely to look healthy, refresh apt, apply an update,
send mail, alter a Route or clear a recovery guard.

The home view should answer: is the vault available; is a current recovery policy
configured and what was actually verified; is protection blocked; does an update
or host maintenance need attention; and what should the administrator do next?
Present failures, age, policy and evidence scope before optional technical detail.
Keep detailed doctor IDs, exact versions, service results and logs accessible.
Show successful completion, cancellation, blocked operation, failure and incomplete
verification separately. Initially remove unsupported completion assertions;
do not reinterpret exit codes or parse prose into a second workflow engine.

Every guide should explain purpose, prerequisites, impact, explicit consent,
owner-reported progress, verification and next action. Reuse the existing key
chooser, restore picker, validated editors, update plan and kit handoff. A small
shared color/choice helper is justified only by concrete duplication. There is
no need for a new daemon, database, workflow engine, repair engine or dependency.

### Proposed sequence (planning only)

The labels below organize dependencies; they are not permission to execute any
later stage. Each stage must pass its mandatory evidence, receive explicit review
and exact-head squash-merge authorization, merge only into `v3`, and have the
resulting tree independently verified before the next branch is created.

| Stage | Bounded scope and authoritative owner | Acceptance required before advancing |
| --- | --- | --- |
| UX-00 | This inventory, architecture, baseline and CI audit. | Complete inventory; all existing checks on exact review head; pins/runtime/preserved branch unchanged; authorized merge and tree verification. |
| UX-01 | Installed dashboard launcher routing, selected-release/session refresh and bytecode safety; existing dashboard/entrypoint/install/handoff paths. | Synthetic selected-release/handoff fixtures; source and installed help; no changed immutable bytes after invocation including root-equivalent writes; interrupted/failed update routing preserved; explicitly scoped native OCI ARM64 installed-entrypoint acceptance. |
| UX-02 | Truthful status/evidence: saved offsite policy versus historical receipt, stale update history, recovery-required guard, DNS and optional boot-rearm detail; existing owners plus operations/dashboard. | Missing/malformed/stale/permission-denied states; no hidden genuine FAIL; no unauthorised remote/mutation on redraw; existing JSON fields, doctor IDs, CLI exits and systemd health contract preserved. Any additive schema change explicitly reviewed. |
| UX-03 | Outcome-first home/menu structure and honest command completion; dashboard and existing presentation helpers. | Complete command mapping; advanced commands discoverable; no deleted public CLI; cancellation/failure/blocked/incomplete displayed truthfully; TTY/NO_COLOR/EOF/Ctrl-C behavior; actual terminal readability check on approved immutable ARM64 install. |
| UX-04 | First-run/setup and configuration guidance; setup frontend, validated config/secrets editors and existing restart/reconciliation owners. | Terminal normal/auto/headless/explicit-recipient parser forms; blank-host Age bootstrap before custody/storage; no unsafe private-key retention; validation before config commit; restart deferred/failure distinct. New blank-host live custody only under separate scope. |
| UX-05 | Guided recovery, saved/one-time offsite policy, retention and kit custody; recovery_ux/offsite/recovery. | Wrong key/corruption/cancel before stop; exact remote object and readback; no historical-object modification; preview plus explicit prune consent; .vwrec/kit distinction; independent custody claim only with evidence. Actual disposable recovery if changed flows require it. |
| UX-06 | Guided application update, guarded recovery and separate host maintenance; update_cli/update_appliance/update_recovery. | Exact launcher/selected-source identity; pre-update verified recovery; truthful no-candidate and stale-check states; cancellation/interruption/quarantine/coherent rollback; no automatic apply or reboot. Real supported transition on a separately authorized disposable host when needed. |
| UX-07 | Guided protection, notification and automation readiness; edge/DNS/Worker/notification owners and systemd. | Explicit DNS/Route/unban/mail/schedule consent; current invocation and independent Fail Open readback; INPUT-only and origin ownership intact; optional boot rearm distinguished from required timers; manual service execution distinguished from native timer dispatch. |
| UX-08 | Administrator manuals and complete junior-admin journey acceptance; existing manuals and current host-acceptance instruments. | Full exact-head CI; command/help/menu parity; end-to-end approved native OCI ARM64 run with immutable proof and grouped checksum-pinned one-shots; mandatory unavailable evidence HOLD; no AMD64 live-host requirement. Separate release/deployment decisions remain separate. |

**Before the first runtime change:** choose a distinct project release identity
consistent with immutable-content validation. Keep upstream component/addon/image
pins fixed; a dependency refresh needs its own authorization. Review the CI
predecessor comparison against the latest accepted development-stage source
without replacing the intentionally fixed historical transition. Do not invent
arbitrary public update hops or reuse an immutable version for different bytes.

### Preserved contracts

- `vwctl` owns mutations; systemd owns lifecycle/scheduling. Preserve nonblocking
  mutation locks and exact error handling; no second frontend transaction lock.
- One `/etc/vaultwarden-oci/config.toml`, one encrypted SOPS document, one exact
  source version manifest; no parallel configuration or credential authority.
- Production application data remains on verified dedicated storage; preserve
  owner-specific gates and prohibit boot/root fallback. Config/secrets editing
  writes their protected /etc authority without the application-data outer gate.
- Operational Age identity stays separate from offline identity; offline private
  material is transient/protected only during supported flows. Preserve `.vwrec`
  and independent AES-256 recovery ZIP; verification precedes live promotion.
- Cloudflare-only origin filtering, trusted-proxy trust, CrowdSec host INPUT-only
  enforcement, bounded DNS ownership and invocation-bound Worker policy/Fail Open
  proof remain separate. Optional boot reconciliation never enables the package
  Worker unit or adds automatic retry.
- Immutable releases, update-controller handoff, durable recovery guards and
  coherent data-plus-code rollback remain authoritative. No generic repair or
  clear-guard shortcut; Ubuntu package state is outside application rollback.
- Preserve public arguments, supported parser forms, 27 doctor IDs, JSON schema
  and stream shape, non-TTY behavior, raw logs, exit semantics and NO_COLOR.
  A desired contract correction needs explicit later scope, not a cosmetic edit.
- Preserve explicit destructive/externally visible consent; safe defaults never
  grant mutation permission. No unattended application update, automatic package
  upgrade, automatic reboot, web dashboard or extra long-running service.
- Do not label local receipt history as current remote protection, an API instant
  as continuous provider proof, a local ZIP as independently held custody, or a
  source test as successful disaster recovery.

## 9. Validation matrix and baseline evidence

### Existing permanent CI

There is one workflow. Its `push` and `pull_request` events are unfiltered
([ci.yml](../.github/workflows/ci.yml):3–8), so every existing job already runs
for PRs targeting `v3`. **No trigger or CI change is required for UX-00.**
The workflow, retry behavior, permissions and existing baseline coverage remain
byte-identical. All nine jobs below are required by this stage's review even
where an architecture is best-effort coverage rather than the live production gate.

| Job | Runner | Existing checks and scope | Source |
| --- | --- | --- | --- |
| `quality-unit` | Ubuntu 24.04 x64 / Python 3.12 | compileall; shell parse; permanent historical compatibility/Worker/forward-host rollback/controller handoff; current predecessor update when distinct release; complete `test_*.py` discovery; CLI help; naming/complexity/documentation-links audit | ci.yml:11–199 |
| `admin-image-integration` | Ubuntu 24.04 x64 | pull exact Vaultwarden image and real admin credential boundary (`tests/acceptance_admin_hash.py`) | ci.yml:202–222 |
| `ubuntu-26-04-compatibility` | Ubuntu 26.04 x64 / native Python 3.14 | assert OS/arch; compileall + complete unit suite; Ubuntu package availability and Docker Resolute repository; systemd 259 unit verification; OS-sensitive lsblk/findmnt/wipefs/blkid/coreutils command forms | ci.yml:224–267 |
| `ubuntu-26-04-security-integration` | Ubuntu 26.04 x64 | real CrowdSec package containment; real Docker origin packet path | ci.yml:269–277 |
| `ubuntu-26-04-arm64-compatibility` | Ubuntu 26.04 ARM64 / native Python 3.14 | assert OS/arch; install, storage/setup, update workflow, immutable-bytecode tests; fail-closed origin startup tests; both reusable host source-instrument tests; Docker repository advertises ARM64 | ci.yml:279–308 |
| `caddy-config-integration` | Ubuntu 24.04 x64 | exact pinned builder/runtime image pulls; real custom Caddy build/config validation | ci.yml:310–334 |
| `crowdsec-package-integration` | Ubuntu 24.04 x64 | real package sequencing/containment | ci.yml:336–342 |
| `recovery-crypto-integration` | Ubuntu 24.04 x64 | Ubuntu Age/rclone/7zip plus checksum-pinned SOPS 3.13.3; real temporary Age/SOPS/rclone recovery and AES-256 ZIP integrations | ci.yml:344–360 |
| `edge-packet-integration` | Ubuntu 24.04 x64 | real Docker IPv4/IPv6 origin packet paths | ci.yml:362–368 |

The current predecessor selector in `ci.yml:60–90` is tied to the preserved branch,
not automatically to the PR's accepted development base. This is harmless for
UX-00's unchanged runtime, but must be reviewed in a later version-bearing stage.
The immutable-content list at line 72 omits root shell entrypoints because those
are not installed release files. They still need shell/CLI/source-entrypoint tests
when changed. The naming audit at lines 108–152 remains unchanged; provenance
links identify historical branches without adding product-generation labels to
normal product surfaces.

### Tests actually performed

Baseline tests ran on the exact accepted source before creating this documentation,
using Debian 13 x86_64 and Python 3.12.14. The complete suite and documentation
checks were also repeated after final receipt assembly; see the final handover. Temporary installed-layout and mocked-transaction
fixtures never touched an appliance. Negative tests intentionally print some FAIL
messages; aggregate unittest results, not those expected messages, determine PASS.

| Check | Result and reproducible command/scope |
| --- | --- |
| Complete existing suite | PASS: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py' -v`; **588 tests**, 4.013 seconds, `OK`, no skipped tests. |
| Focused operator surfaces | PASS: **156 tests**, 1.488 seconds, using `PYTHONPATH=.:tests PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v` with modules listed below. |
| Compile | PASS: existing `python3 -m compileall -q vaultwarden_oci tests`; `PYTHONPYCACHEPREFIX` directed compilation caches outside the checkout. |
| Bash parse | PASS: `bash -n setup.sh dashboard.sh vaultwarden_oci/dashboard.sh tests/acceptance_edge_packet.sh .github/scripts/retry-command.sh`. |
| Existing quality helpers | PASS: exact unchanged CLI-help and release-neutral path/content/complexity/documentation-link shell bodies extracted from `quality-unit`; Bash executed with `-e -o pipefail`. |
| Historical transaction integration | PASS: exact existing CI step using the immutable dev.16/dev.17 source pair, isolated temp roots and simulated host effects; Worker rearm/confirmation, forward-only host safety, failed update, coherent rollback/retry and controller handoff. |
| Current-predecessor transaction baseline | PASS: same CI step on the unmodified baseline exercised isolated rc.15 to rc.16 failed forward transition, candidate-owned coherent rollback, and successful transition. This is **simulated transaction evidence**, not VM9 live rollback or rc.16 native image acceptance. A documentation-only PR correctly skips a distinct current release transition because its version/bytes are unchanged. |
| Public parser/help | PASS: authoritative parser enumeration; **40/40** public leaf help paths and **4/4** no-arg/top-help/version/versions checks, exit 0 and no ANSI. |
| Audit-only reproductions | PASS: **7 assertions** across isolated probes: fixed dashboard dispatch, two dashboard bytecode writes, cancelled-zero success footer, stale update precedence, historical offsite summary, human/JSON exit difference, and CrowdSec-only TTY/captured/JSON difference. These characterize existing defects/contracts; they are not fixes. |
| Baseline remote CI | PASS: [v3 push 45448152610](https://github.com/killer23d/VaultWarden-OCI/actions/runs/45448152610), exact base SHA, completed/success, all nine job conclusions independently inspected. [Preserved-baseline push 45345293271](https://github.com/killer23d/VaultWarden-OCI/actions/runs/45345293271) also reports completed/success at that SHA. |
| UX-00 audit implementation CI | PASS: implementation `89e661ae6e495c654768601b2993f3c354679799`, [push 45451023299](https://github.com/killer23d/VaultWarden-OCI/actions/runs/45451023299) and [PR 45451108239](https://github.com/killer23d/VaultWarden-OCI/actions/runs/45451108239), each nine successful jobs. Quality log independently confirms 588 tests and the correct same-version transition skip. |
| Final receipt verification | Documentation/source review, complete 165-path inventory comparison, unchanged runtime/pin/workflow objects, and documentation-link/diff checks PASS. This evidence-only receipt commit still requires its own exact-head CI, to be supplied independently in PR #443 and the final handover before authorization. |

Focused modules:

```text
test_dashboard_install
test_operator_entrypoint
test_operator_cosmetics
test_operator_output
test_operations
test_operations_automation_target
test_operations_help_routing
test_operations_notification
test_operations_support_redaction
test_immutable_vwctl_bytecode
test_update_controller_handoff
test_recovery_ux
test_recovery_kit_prompt
test_offsite
test_systemd_runtime_contract
```

The isolated dashboard shell uses `/usr/bin/python3` (Python 3.13.5 here), so its
temporary bytecode filenames are `cpython-313`; the main unittest runner is Python
3.12.14. Environment suppression was removed only in that temporary-copy probe.
No new permanent test framework or test file was introduced.

### NOT RUN and applicability

- Local native Ubuntu 24.04/26.04 and ARM64 execution: **NOT RUN**; this checkout
  runner is Debian x86_64. Native OS/architecture automated checks come from CI.
- Local Docker/custom-Caddy/exact-Admin/packet/CrowdSec-package and real
  Age/SOPS/7zip integrations: **NOT RUN**; the required local Docker/crypto/package
  environment is absent. All corresponding exact PR-head CI jobs must pass.
- Any OCI host access, installed appliance integrity inspection, live provider
  operation, mail delivery, backup/restore, update/rollback, apt apply or reboot:
  **NOT RUN** in UX-00. None is necessary for this documentation-only change.
- rc.16 native OCI ARM64 dependency/runtime acceptance, stable publication and
  production deployment remain **NOT RUN / separately gated**. Historical rc.15
  evidence is not transferred to new image bytes. AMD64 live-host work is not
  required by this contract.
- The findings' behavior fixes, new guides and subsequent-stage live exercises
  are **NOT RUN** and not implemented. Any applicable mandatory validation still
  missing in a later stage yields HOLD, never an inferred PASS.

### Subsequent change-family regression matrix

| Change family | Focused and compatibility verification | Live boundary when applicable |
| --- | --- | --- |
| Installed dashboard entrypoint and launcher selection | installed release tree/modes/hash unchanged by launch; safe source-vs-installed routing; update handoff preserved; selection change followed by fresh presentation process; no root bytecode; CLI help/non-TTY/JSON unaffected | expressly identified disposable native ARM64 installed immutable source; prove entrypoint does not mutate release bytes; no actual update without separate scope |
| Truthful status/outcome model | fresh/stale/missing/malformed state; independent runtime/doctor/automation; guard; DNS and optional boot unit; stale offsite receipt vs current policy/destination; success/cancel/failure/blocked/incomplete | read-only ARM64 snapshot after candidate install if executable/presentation entrypoints change; no synthetic guard or failure on historical populated host |
| Guided lifecycle/configuration/setup | use existing parser/edit/restart/lock owners; TTY/NO_COLOR; safe defaults; EOF/Ctrl-C; permissions; validation before mutation; explicit recipient/headless custody preserved | approved blank host for setup; approved scoped restart/config change on disposable host; existing first-run acceptance not automatically transferred |
| Guided backup/offsite/retention/recovery | saved-vs-one-time destination; independent readback; no overwrite; explicit delete plan; wrong key/corruption/cancel before stop; exact restored data postcheck; identity cleanup | uniquely isolated remote with no historical writes; approved disposable vault fixture, actual readback and restore only if specifically authorized; do not assert off-host custody from a local ZIP |
| Guided security/notification/schedules | all defaults and opt-ins preserved; no implicit DNS/Route/unban/send/target enablement; current invocation proof; SMTP vs optional HTTPS provider; systemd remains scheduler | external changes require explicit host/source/scope and consent; native timer dispatch separated from manual service run; never enable package Worker unit |
| Guided update/rollback/maintenance | current source/pointer and launcher; guard; new release identity with unchanged upstream pins unless separately authorized; source prevalidation/recovery; cancellation and interruption; coherent rollback; host/app separation | real supported predecessor transition only on separately approved disposable target; unavailable failed-update live transition is HOLD for that gate, not manufactured evidence |
| Final end-to-end UX acceptance | full suite + all nine CI jobs on exact reviewed head; docs/help/menu parity; no false protection claims; supported noninteractive/systemd contracts | grouped checksum-pinned one-shots on explicitly identified native OCI ARM64 disposable host, installed source, permitted mutations; unavailable mandatory evidence HOLD; no AMD64 live request |

## 10. Review and stop gate

Review the exact PR diff and head, all nine CI jobs, this source mapping and the
bounded evidence statement. Verify that the only change is this documentation,
that the manifest/workflow/runtime trees equal the accepted base, that remote
`v3` and the preserved branch remain at their accepted SHA, and that the default
branch remains `main`. A successful audit is not approval to fix its findings.

After all applicable evidence passes, request administrator authorization to
squash-merge the **exact reviewed head** into `v3`. Repository settings currently
disable GitHub's native squash option; do not change settings or choose another
merge mode silently. If an alternate squash integration is needed, its exact
reviewed head, parent and resulting tree require explicit authorization at that
point. No merge action belongs to UX-00's current authorized work.

After a separately authorized merge, independently verify the resulting `v3`
tree, supply its accepted SHA at handover, and verify it again before a next-stage
branch. Never modify the preserved baseline/default branch, publish a release,
create a release tag, deploy, or automatically begin UX-01.

## Appendix: complete baseline tracked-path inventory

Generated from `git ls-tree -r --name-only` at the accepted SHA. This is the
165-file source inventory, not a list of installed production files. The sole
new stage record is `docs/UX-DEVELOPMENT.md`.

```text
.gitattributes
.github/pull_request_template.md
.github/scripts/retry-command.sh
.github/workflows/ci.yml
.gitignore
AGENTS.md
LICENSE
README.md
dashboard.sh
docs/CLOUDFLARE-TOKENS.md
docs/CONFIGURATION.md
docs/DECISIONS.md
docs/DEVELOPMENT.md
docs/HISTORICAL-INFRASTRUCTURE-ACCEPTANCE.md
docs/HOST-ACCEPTANCE.md
docs/INSTALL.md
docs/OCI-CLOUD-SHELL-AND-PRIVATE-SSH.md
docs/OPERATIONS.md
docs/PROJECT-BOUNDARY.md
docs/RECOVERY.md
docs/SECURITY.md
docs/TROUBLESHOOTING.md
email-providers.toml
reports/TEST-STRATEGY.md
setup.sh
systemd/vaultwarden-oci-backup.service
systemd/vaultwarden-oci-backup.timer
systemd/vaultwarden-oci-crowdsec-boot.service
systemd/vaultwarden-oci-dns.service
systemd/vaultwarden-oci-health.service
systemd/vaultwarden-oci-health.timer
systemd/vaultwarden-oci-maintenance.service
systemd/vaultwarden-oci-maintenance.timer
systemd/vaultwarden-oci-notify@.service
systemd/vaultwarden-oci-update-check.service
systemd/vaultwarden-oci-update-check.timer
systemd/vaultwarden-oci.service
systemd/vaultwarden-oci.target
tests/acceptance_admin_hash.py
tests/acceptance_caddy_config.py
tests/acceptance_crowdsec_firewall_package.py
tests/acceptance_edge_packet.sh
tests/acceptance_forward_only_host_rollback.py
tests/acceptance_predecessor_controller_handoff.py
tests/acceptance_predecessor_worker_health.py
tests/acceptance_previous_crowdsec_transition.py
tests/acceptance_previous_update.py
tests/acceptance_previous_update_success.py
tests/acceptance_recovery_crypto.py
tests/acceptance_recovery_kit.py
tests/host-acceptance/README.md
tests/host-acceptance/https_readiness.py
tests/host-acceptance/production-new-host-preflight.py
tests/host-acceptance/production-readiness-inventory.py
tests/test_admin_credentials.py
tests/test_backup_health_settle.py
tests/test_caddy_edge_admin.py
tests/test_cloudflare_api_policy.py
tests/test_cloudflare_route_mode.py
tests/test_crowdsec_boot_stop.py
tests/test_crowdsec_package_setup.py
tests/test_crowdsec_worker_policy.py
tests/test_dashboard_install.py
tests/test_dns_publication.py
tests/test_edge.py
tests/test_edge_blockers.py
tests/test_edge_origin_startup_contract.py
tests/test_edge_scope.py
tests/test_firewall_live_validation.py
tests/test_first_release_update_check.py
tests/test_first_run_crowdsec_guidance.py
tests/test_https_readiness.py
tests/test_immutable_vwctl_bytecode.py
tests/test_install.py
tests/test_notification.py
tests/test_notification_security.py
tests/test_offsite.py
tests/test_operations.py
tests/test_operations_automation_target.py
tests/test_operations_help_routing.py
tests/test_operations_notification.py
tests/test_operations_support_redaction.py
tests/test_operator_config_catalog.py
tests/test_operator_cosmetics.py
tests/test_operator_entrypoint.py
tests/test_operator_output.py
tests/test_predecessor_recovery_boundary.py
tests/test_predecessor_transition.py
tests/test_production_new_host_preflight.py
tests/test_production_readiness_inventory.py
tests/test_recovery.py
tests/test_recovery_kit_explicit_path.py
tests/test_recovery_kit_prompt.py
tests/test_recovery_smtp_owner.py
tests/test_recovery_ux.py
tests/test_release_surface.py
tests/test_runtime.py
tests/test_runtime_prestart_paths.py
tests/test_setup_auto_offline.py
tests/test_setup_first_run_templates.py
tests/test_setup_frontend_color.py
tests/test_setup_sops_atomic.py
tests/test_setup_storage.py
tests/test_systemd_runtime_contract.py
tests/test_update_appliance.py
tests/test_update_appliance_rollback.py
tests/test_update_caddy_identity.py
tests/test_update_candidate_validation.py
tests/test_update_component_downgrade.py
tests/test_update_controller_handoff.py
tests/test_update_controller_source_checkout.py
tests/test_update_durability.py
tests/test_update_failclosed.py
tests/test_update_guard_publication.py
tests/test_update_health_settle.py
tests/test_update_interrupt_safety.py
tests/test_update_latest_source_identity.py
tests/test_update_legacy_handoff_rekey.py
tests/test_update_rollback_crash_safety.py
tests/test_update_safety_regressions.py
tests/test_update_transition.py
tests/test_update_workflow.py
tests/test_vwctl.py
vaultwarden_oci/__init__.py
vaultwarden_oci/admin.py
vaultwarden_oci/cli.py
vaultwarden_oci/cloudflare_route_mode.py
vaultwarden_oci/crowdsec_boot.py
vaultwarden_oci/crowdsec_stop.py
vaultwarden_oci/crowdsec_worker_policy.py
vaultwarden_oci/dashboard.py
vaultwarden_oci/dashboard.sh
vaultwarden_oci/dns_publication.py
vaultwarden_oci/durability.py
vaultwarden_oci/edge.py
vaultwarden_oci/install.py
vaultwarden_oci/notification.py
vaultwarden_oci/offsite.py
vaultwarden_oci/operations.py
vaultwarden_oci/operator_cosmetics.py
vaultwarden_oci/operator_entrypoint.py
vaultwarden_oci/operator_output.py
vaultwarden_oci/operator_settings.py
vaultwarden_oci/predecessor_transition.py
vaultwarden_oci/recovery.py
vaultwarden_oci/recovery_ux.py
vaultwarden_oci/runtime.py
vaultwarden_oci/runtime_health.py
vaultwarden_oci/secrets.py
vaultwarden_oci/setup.py
vaultwarden_oci/setup_frontend.py
vaultwarden_oci/sevenzip_secure.py
vaultwarden_oci/storage.py
vaultwarden_oci/update.py
vaultwarden_oci/update_appliance.py
vaultwarden_oci/update_candidate.py
vaultwarden_oci/update_cli.py
vaultwarden_oci/update_controller_handoff.py
vaultwarden_oci/update_guard.py
vaultwarden_oci/update_recovery.py
vaultwarden_oci/update_status.py
vaultwarden_oci/update_unit_migration.py
vaultwarden_oci/update_versions.py
versions.toml
vwctl
```
