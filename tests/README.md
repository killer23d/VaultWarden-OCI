# Developer test suites

The supported entry point is `./tests/run-tests.sh <suite>`.

```text
tests/
├── README.md
├── run-tests.sh
├── test-architecture.sh
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

Permanent `case-*.bash` files live under the closest responsibility directory and are registered exactly once in `run-tests.sh`. The runner executes each case directly at its registered path and writes temporary compatibility or timeout state only under the system temporary directory; it does not create files or symlinks in the checkout.

Nested cases source `tests/lib/test-root.bash`, which derives the repository root from the helper's stable location. Case bodies use `VW_TEST_REPO_ROOT` instead of assuming they are one directory below the repository root.

`tests/lib/assertions.bash` contains the small set of file, equality, absence, and wait assertions reused across cases. `tests/lib/command-mocks.bash` creates executable mocks and isolated command paths so command-presence tests do not depend on host packages. Domain-specific fixture behavior remains in its owning case.

## Suites

| Suite | Responsibility |
| --- | --- |
| `foundation` | Architecture, runner contracts, configuration, permissions, storage/setup, and systemd contracts |
| `security` | Security/privilege, secrets, and email contracts |
| `operations` | Operation guards, lock-descriptor hygiene, lifecycle, operator UI, CrowdSec, and uninstall contracts |
| `data-protection` | Backup and restore/recovery contracts |
| `all` | All four suites in dependency order |

```bash
./tests/run-tests.sh foundation
./tests/run-tests.sh security
./tests/run-tests.sh operations
./tests/run-tests.sh data-protection
./tests/run-tests.sh all
./tests/run-tests.sh list
./tests/run-tests.sh list-files
```

`list` prints the suite-grouped execution inventory. `list-files` prints each registered physical file exactly once, one path per line, for scripts that need a stable file inventory without parsing the human-readable suite listing.

Add a regression to an existing case when it shares the same fixture and responsibility. Create another case when a separate failure or timeout boundary is useful, or combining it would mix unrelated fixtures. Do not add another top-level `test-*.sh` command.

`case-runner-contracts.bash` tests command grammar, hierarchical fixture mapping, inventory validation, checkout isolation, failure propagation, and timeout diagnostics. `case-lock-fd-hygiene.bash` keeps focused structural coverage that logging and CrowdSec helpers no longer carry obsolete lock-descriptor lifecycle logic; the real Linux owner-death and arbitrary-child behavior runs in `case-operations.bash`.

Fixture mode is internal to the runner-contract tests. `VAULTWARDEN_TEST_RUNNER_TESTS_DIR` substitutes an isolated test root while preserving each registered path relative to `tests/`, including its `suites/<suite>/` hierarchy. This permits identical basenames in different suites without collisions and never writes to the repository's real `tests/` tree.

## Per-case timeout and timing behavior

`TEST_CASE_TIMEOUT_SECONDS` defaults to `120` and applies independently to each registered runner entry. Override it when a focused developer run legitimately needs a different ceiling:

```bash
TEST_CASE_TIMEOUT_SECONDS=300 ./tests/run-tests.sh foundation
```

The deadline is enforced only when the runner detects a GNU coreutils-compatible `timeout` command with the required `--kill-after` and `--verbose` options. Ubuntu CI provides GNU `timeout`; Homebrew users can use `gtimeout` from GNU coreutils. Without a supported command, cases run without a per-case deadline and the suite output states that limitation. The workflow's job timeout remains a separate outer bound.

The runner reports elapsed time for every passed, failed, or timed-out case. These timings are informational and use Bash's built-in `EPOCHREALTIME`; they do not change timeout selection or introduce another dependency.

GitHub Actions executes the four public suites independently and retains each suite log as a short-lived diagnostic artifact.
