# Developer test suites

The supported entry point is `./tests/run-tests.sh <suite>`.

`tests/` keeps only the public runner, this guide, and the architecture contract at its top level. Internal regression cases are grouped by responsibility under `tests/suites/`:

```text
tests/
├── README.md
├── run-tests.sh
├── test-architecture.sh
└── suites/
    ├── foundation/
    ├── security/
    ├── operations/
    └── data-protection/
```

Run cases through `run-tests.sh`; internal `case-*.bash` files are not standalone developer commands. The runner validates that every permanent case is registered exactly once and that no case files drift back into the test root.

## Suites

| Suite | Responsibility |
| --- | --- |
| `foundation` | Architecture, test-runner, configuration, permissions, storage/setup, and systemd contracts |
| `security` | Security/privilege, secrets, and email contracts |
| `operations` | Operation guards, lifecycle, operator UI, CrowdSec, and uninstall contracts |
| `data-protection` | Backup and restore/recovery contracts |
| `all` | All four suites in dependency order |

Examples:

```bash
./tests/run-tests.sh foundation
./tests/run-tests.sh data-protection
./tests/run-tests.sh all
./tests/run-tests.sh list
```

Add a regression to the closest suite directory and register it in the matching array in `run-tests.sh`. Extend an existing case when it shares the same fixture and responsibility; do not create another top-level `test-*.sh` command.

`ecase-runner-contracts.bash` exercises the real runner against isolated temporary fixtures. It covers command grammar, inventory validation, list output, failure propagation, timeout capability detection, ordinary exit `124` handling, and actual timeout diagnostics without modifying the repository's real `tests/` tree.

## Per-case timeout behavior

`TEST_CASE_TIMEOUT_SECONDS` defaults to `120` and must be a positive integer. Override it for a focused developer case that legitimately needs a different ceiling:

```bash
TEST_CASE_TIMEOUT_SECONDS=300 ./tests/run-tests.sh foundation
```

The deadline is enforced only when the runner detects a GNU coreutils-compatible `timeout` command with the required `--kill-after` and `--verbose` options. Ubuntu 24.04 CI provides GNU `timeout`; Homebrew users can receive the same behavior through `gtimeout` when GNU coreutils is installed.

When no supported timeout command is available, cases run without a per-case deadline and the suite output states that timeout enforcement is unavailable. The workflow's separate job-level timeout still bounds CI.

GitHub Actions executes the four suites independently so failures identify the affected domain without exposing every narrow case as a separate CI surface. Each suite log is retained as a short-lived workflow artifact for diagnosis.
