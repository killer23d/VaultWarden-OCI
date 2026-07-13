# Developer test suites

The supported entry point is `./tests/run-tests.sh <suite>`.

Most permanent regression bodies are named `case-*.bash` because they are internal implementation cases, not operator commands. `test-architecture.sh` remains the single top-level interface-contract test because it validates the repository runner itself. Do not add other top-level `test-*.sh` scripts. Add a case to the closest suite in `run-tests.sh`, or extend an existing case when it shares the same fixture and responsibility.

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

`case-runner-contracts.bash` exercises the real runner against isolated temporary fixtures. It covers command grammar, inventory validation, list output, failure propagation, timeout capability detection, ordinary exit `124` handling, and actual timeout diagnostics without modifying the repository's real `tests/` directory.

## Per-case timeout behavior

`TEST_CASE_TIMEOUT_SECONDS` defaults to `120` and must be a positive integer. Override it for a run when a focused developer case legitimately needs a different ceiling:

```bash
TEST_CASE_TIMEOUT_SECONDS=300 ./tests/run-tests.sh foundation
```

The per-case deadline is enforced only when the runner detects a GNU coreutils-compatible `timeout` command with the required `--kill-after` and `--verbose` options. Ubuntu 24.04 CI provides GNU `timeout`, so CI retains the 120-second default ceiling. Homebrew users can receive the same behavior through `gtimeout` when GNU coreutils is installed.

The runner probes timeout capability before executing a suite. If neither supported `timeout` nor `gtimeout` is available, or a discovered command lacks the required syntax, cases run without a per-case deadline and the suite output states that timeout enforcement is unavailable. The workflow's separate job-level timeout still bounds CI, but developers should not infer a local per-case deadline from the configured seconds alone.

The runner validates that every internal `case-*.bash` file is registered exactly once and rejects new unregistered top-level test commands. GitHub Actions executes the four suites independently so a failure identifies the affected domain without turning each narrow case into a separate CI surface. Each suite log is retained as a short-lived workflow artifact for diagnosis.
