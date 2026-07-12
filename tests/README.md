# Developer test suites

The supported entry point is `./tests/run-tests.sh <suite>`.

Most permanent regression bodies are named `case-*.bash` because they are internal implementation cases, not operator commands. `test-architecture.sh` remains the single top-level interface-contract test because it validates the repository runner itself. Do not add other top-level `test-*.sh` scripts. Add a case to the closest suite in `run-tests.sh`, or extend an existing case when it shares the same fixture and responsibility.

## Suites

| Suite | Responsibility |
| --- | --- |
| `foundation` | Architecture, configuration, permissions, storage/setup, and systemd contracts |
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

The runner validates that every internal `case-*.bash` file is registered exactly once and rejects new unregistered top-level test commands. GitHub Actions executes the four suites independently so a failure identifies the affected domain without turning each narrow case into a separate CI surface. Each suite log is retained as a short-lived workflow artifact for diagnosis.
