# VaultWarden-OCI V2 Test Strategy

Date: 2026-08-18

## Objective

V2 tests exist to protect the small number of behaviors that can compromise security, availability, recoverability or operator truthfulness.

They are **not** intended to model the entire implementation, preserve V1 source structure, maximize assertion count or prove third-party software internals.

The test system must itself remain easy to maintain.

---

# 1. Test budget

Use three layers only:

1. **unit tests** — deterministic Python logic;
2. **small integration tests** — filesystem/subprocess/Compose/security boundaries;
3. **real-host acceptance** — disposable Ubuntu 24.04 release-gate scenarios.

Do not create a fourth test framework or a custom logical inventory.

Development dependencies may be:

- `pytest`;
- `ruff`;
- ShellCheck for remaining shell.

Start with no pytest plugins.

## Size guardrails

These are design-review guardrails, not CI quotas:

- by beta, test code should aim to remain well below the size of production code; roughly **<=35% of first-party implementation LOC** is a useful warning threshold, not a target to game;
- a single test module approaching roughly 400 lines should trigger a design review: is the production interface too complicated, are tests coupled to implementation, or should the scenario be release acceptance instead?;
- adding a production feature should not automatically require an equal-sized mock implementation in tests.

No code-coverage percentage gate is required. Coverage can be inspected as a development aid later, but percentage targets often reward low-value tests.

---

# 2. What must be tested

## 2.1 Configuration and versions

Test:

- valid config loads;
- missing/invalid required fields fail clearly;
- dangerous/unsupported values fail closed;
- `amd64` and `arm64` mappings resolve correctly;
- unsupported CPU/OS values do not fall back silently;
- production uses exact version pins;
- `--use-latest` resolver returns exact resolved values and is clearly marked non-production;
- malformed upstream/latest responses fail instead of inventing a version.

Do not test Python `tomllib` itself.

## 2.2 Command execution

Test the project wrapper around subprocesses:

- argument arrays are passed without shell interpolation;
- non-zero exit is preserved/normalized truthfully;
- timeout behavior is clear where used;
- secret values are not included in diagnostic exception text;
- command-not-found/prerequisite failures are understandable.

Do not mock every Docker/systemd command in every caller. Test the wrapper once, then test callers using a few representative process results.

## 2.3 Concurrency

Test:

- one mutating command can hold the global lock;
- a second mutating command receives the intended contention result;
- read-only diagnostics do not require the mutation lock;
- child process execution does not keep the lock alive after the controlling process exits.

Do not recreate V1's process/FD identity framework unless a real defect proves it necessary.

## 2.4 Secrets

Test security properties:

- encrypted secret structure validation;
- required secret detection;
- secret materialization uses the expected directory/file modes;
- plaintext secret material is removed on normal cleanup;
- generated command/env/log representations do not contain sentinel secret values;
- SOPS/Age failure prevents startup/rotation success;
- offline recovery private material is not copied into persistent host state.

Use sentinel values and inspect process arguments/output where relevant.

Do not test SOPS cryptography itself.

## 2.5 Runtime/Compose

Test:

- committed/default config renders valid Compose;
- required services are Vaultwarden + Caddy for beta;
- expected security options are present;
- Caddy publishes only the intended production port(s);
- secret mounts point at transient secret files;
- direct SMTP config reaches Vaultwarden;
- no mandatory Postfix service appears.

Prefer parsing/rendering behavior or `docker compose config`; avoid dozens of grep assertions against YAML text.

## 2.6 Firewall/Cloudflare

Test project-owned behavior only:

- Cloudflare IPv4/IPv6 lists parse and validate;
- empty/malformed lists fail closed;
- last-known-good cache expiry is enforced;
- intended project-owned iptables rule/restore input is generated deterministically;
- failure to establish the supported ingress policy prevents public Caddy startup/continuation as designed.

Real-host acceptance proves the packet path.

Do not unit-test iptables, Docker NAT or Cloudflare infrastructure.

## 2.7 CrowdSec

Test:

- project-owned acquisition/profile/config rendering;
- required credential validation;
- diagnostic interpretation of representative upstream command states;
- failed upstream installation/configuration is reported truthfully.

Do not recreate the upstream CrowdSec installer in mocks.

## 2.8 Diagnostics

`vwctl doctor` is a stable product API and deserves focused tests.

Test:

- stable check IDs;
- `PASS/WARN/FAIL/SKIP` classification;
- overall exit policy;
- JSON schema/shape for implemented checks;
- representative error parsing;
- no secrets in output.

Do **not** freeze exact human-readable sentences. Human text should remain editable without rewriting large tests.

## 2.9 Backup and restore

This is the highest-value test area.

Test behavior capable of causing data loss:

- SQLite snapshot failure prevents publication;
- backup is not successful until integrity/encryption verification succeeds;
- incomplete candidate is not selected as latest valid recovery point;
- manifest/checksum mismatch fails;
- unsafe archive paths fail;
- decrypt failure fails before live mutation;
- target storage/capacity failure occurs before service stop;
- restore stages rather than extracting directly into live state;
- promotion/permission failures return non-zero and preserve useful diagnosis;
- successful restore followed by requested startup requires health success;
- retention preserves a valid recovery point until a newer verified point exists.

Use real temporary SQLite databases/files/tar archives where cheap. This provides stronger evidence with less mock code than source-pattern testing.

Do not test V1 archive formats or migration paths.

## 2.10 systemd

Test:

- rendered units use expected installed `vwctl` paths;
- required hardening/directives are generated by the owning template/model;
- `systemd-analyze verify` passes where available;
- timer commands match the supported `vwctl` grammar.

Real-host acceptance proves enabling/execution.

Avoid a large parallel test schema of every systemd directive.

---

# 3. What should not be permanent tests

Do not add permanent tests whose primary purpose is to assert:

- exact source-code strings;
- function ordering in a source file;
- that an implementation uses a specifically named private helper;
- old V1 aliases are absent/present;
- a particular internal module decomposition;
- exact prose in docs/errors;
- internal behavior of Python stdlib, Docker, systemd, SOPS, Age, Caddy, Cloudflare or CrowdSec;
- every issue/PR fix as a new standalone case when an existing behavioral test already protects the invariant.

Static/source assertions are acceptable only when **source structure is the actual contract**, for example a generated file must exactly match its canonical source. Even then, first ask whether the generated duplicate can be deleted.

---

# 4. Mocking policy

Mocks should terminate at stable external boundaries.

Good boundaries:

- HTTP response from an upstream release/CIDR endpoint;
- `docker`, `systemctl`, `iptables-restore`, `sops`, `age`, `rclone`, `cscli` subprocess results;
- SMTP server interaction;
- filesystem ownership/mode inspection.

Bad pattern:

- extracting a private production function with `awk`;
- rebuilding half of a shell script as a test harness;
- mocking multiple layers of internal helpers to prove implementation order;
- duplicating a state machine in test code.

If a function cannot be tested without reproducing its implementation, redesign the production boundary before expanding the test harness.

---

# 5. CI model

## Pull-request CI

Keep normal PR CI fast and boring:

```text
ruff check
pytest
shellcheck <remaining shell files>
docker compose config --quiet
```

Add a small static check for formatting/syntax as appropriate.

A practical goal is that normal PR validation completes in roughly a couple of minutes on hosted runners when upstream network availability is not required. This is an aspiration, not a security tradeoff.

PR CI should not perform destructive real-host recovery or reach production Cloudflare resources.

## Scheduled/release validation

Use an on-demand or release-candidate workflow/environment for real Ubuntu hosts.

Target scenarios:

1. clean Ubuntu 24.04 install;
2. configure + start + `doctor`;
3. validate Cloudflare/CrowdSec ingress on a dedicated test hostname;
4. create verified backup;
5. destroy/reset disposable V2 state;
6. restore to fresh state/host;
7. run `doctor` and application login/API smoke hook;
8. apply a staged V2 update;
9. verify timers;
10. uninstall/reinstall where useful.

Run on amd64 and arm64 where infrastructure permits. OCI A1 Flex is a natural arm64 acceptance target but the test must not encode OCI-specific runtime behavior.

The acceptance script should be intentionally small. External orchestration may recreate/discard the VM instead of teaching the application a complex destructive acceptance state machine.

---

# 6. Regression-test rule

When a defect is fixed, ask in order:

1. Is the defect already covered by a behavioral test that failed? Fix the code; do not add another test.
2. Is there a missing reusable security/data invariant? Add one focused test at that invariant boundary.
3. Is the bug only reproducible on a real host/integration path? Add it to release acceptance rather than building a large mock universe.
4. Is the test only able to assert the exact previous source implementation? Prefer a design improvement or do not make it permanent.

A PR is not incomplete merely because it did not add a test file. It is incomplete when a meaningful unprotected V2 invariant was changed without appropriate validation.

---

# 7. Diagnostics are part of the testing strategy

V2 should invest in diagnostics rather than trying to simulate every production state in unit tests.

A stable `vwctl doctor --json` output lets:

- operators diagnose real systems;
- release acceptance assert real state;
- support reports include trustworthy facts;
- tests validate check classification without understanding internal implementation.

This is a better long-term investment than a test harness that mocks every possible host condition.

---

# 8. Definition of a healthy V2 test suite

The V2 test suite is healthy when:

- a maintainer can understand its structure quickly;
- most tests call public or intentionally testable module boundaries;
- test failures describe the violated behavior rather than a stale source string;
- implementation refactors that preserve behavior usually do not require broad test rewrites;
- backup/restore/security boundaries receive more attention than display formatting or wrapper aliases;
- the full PR suite is cheap enough that developers run it routinely;
- destructive real-host evidence exists, but is not implemented as another permanent application framework.
