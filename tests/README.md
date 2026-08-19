# Developer test suites

The supported entry point is `./tests/run-tests.sh <suite>`.

```text
tests/
├── README.md
├── run-tests.sh
├── lib/
│   ├── assertions.bash
│   ├── command-mocks.bash
│   └── test-root.bash
└── suites/
    ├── foundation/
    ├── security/
    ├── operations/
    └── data-protection/
```

Permanent executable cases live under `tests/suites/**/case-*.bash`. `tests/run-tests.sh` is the only permanent inventory and exposes **32 logical records backed by 25 physical case files**. A record has four fields:

```text
logical-id|physical-path|mode|timeout-seconds
```

Logical IDs are globally unique. Each `(physical-path, mode)` pair is also globally unique; the same physical path may be reused only with a different mode.

One physical case may back multiple logical records when a mode preserves a useful independent failure/timeout boundary. The runner passes every record's mode through `VW_TEST_CASE_MODE`, validates the complete inventory before listing or executing it, and never creates wrapper files or symlinks in the checkout.

Nested cases source `tests/lib/test-root.bash`, which derives the repository root from the helper's stable location. Case bodies use `VW_TEST_REPO_ROOT` instead of relying on their directory depth. `tests/lib/assertions.bash` and `tests/lib/command-mocks.bash` remain small shared helpers; domain-specific fixtures stay in their owning case.

## Suites

| Suite | Logical cases | Responsibility |
| --- | ---: | --- |
| `foundation` | 11 | Architecture, runner/repository contracts, configuration, permissions, storage/setup, and systemd |
| `security` | 4 | Security/privilege, secrets/sensitive cleanup, and email |
| `operations` | 14 | Operation guards, health alerts/locking, lifecycle/startup, operator UI, CrowdSec, host acceptance, and uninstall |
| `data-protection` | 3 | Backup and independently timed restore core/tail recovery coverage |
| `all` | 32 | All four suites in dependency order |

```bash
./tests/run-tests.sh foundation
./tests/run-tests.sh security
./tests/run-tests.sh operations
./tests/run-tests.sh data-protection
./tests/run-tests.sh all
./tests/run-tests.sh list
./tests/run-tests.sh list-files
```

`list` is the logical execution inventory and prints `logical-id|physical-path|mode|timeout-seconds`. `list-files` is the unique physical case inventory and prints one registered `case-*.bash` path per line in deterministic order. One physical case may expose multiple logical modes while appearing only once in `list-files`. Add coverage to the closest existing domain case when it shares setup and responsibility. Use another logical mode when that physical case can own the coverage cleanly but needs independent identity, diagnostics, or timeout isolation. Create another physical `case-*.bash` file when the coverage needs distinct setup/fixtures or a focused boundary that would make a shared owner harder to navigate. Do not add top-level `test-*.sh` files or a second inventory.

The consolidated multi-mode owners are:

- `case-runner-contracts.bash`: `core`, `repository-interface`, `all`;
- `case-health-alerts.bash`: `core`, `locking`, `all`;
- `case-config-env.bash`: `core`, `ci-dev-setup`, `all`;
- `case-storage-setup.bash`: `core`, `host-architecture`, `all`;
- `case-secrets.bash`: `core`, `sensitive-cleanup`, `all`;
- `case-lifecycle.bash`: `core`, `startup-hardening`, `all`;
- `case-restore-recovery.bash`: `core`, `tail`, `all`.

Direct execution defaults to `all`; an unknown `VW_TEST_CASE_MODE` exits `2` before the case body runs.

## Fixture and timeout behavior

Fixture mode is internal to runner-contract tests. `VAULTWARDEN_TEST_RUNNER_TESTS_DIR` rewrites only each record's physical path into an isolated tests tree; logical ID, mode, and stored timeout remain unchanged. `VAULTWARDEN_TEST_RUNNER_EXTRA_FOUNDATION_RECORD` injects one complete record only in fixture mode. Runner-contract fixtures use `list-files` as the physical inventory and create each unique physical path once even when several logical records share it.

Each logical record stores its own timeout. `TEST_CASE_TIMEOUT_SECONDS` optionally overrides that value for focused developer runs:

```bash
TEST_CASE_TIMEOUT_SECONDS=300 ./tests/run-tests.sh foundation
```

The deadline is enforced only when a GNU coreutils-compatible `timeout`/`gtimeout` supports the required options. Without one, cases still run and the suite reports that per-logical-case deadlines are unavailable. A test that exits `124` on its own remains a normal failure; timeout reporting is based on GNU timeout's signal diagnostic. Each logical PASS, FAIL, or TIMEOUT result includes elapsed duration in seconds.

GitHub Actions continues to execute the four public suites independently and retains each suite log as a short-lived diagnostic artifact.
