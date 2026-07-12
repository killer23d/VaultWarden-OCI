# Developer test suites

The supported entry point is `./tests/run-tests.sh <suite>`.

The permanent regression bodies are named `case-*.bash` because they are internal implementation cases, not operator commands. Do not add new top-level `test-*.sh` scripts. Add a case to the closest suite in `run-tests.sh`, or extend an existing case when it shares the same fixture and responsibility.

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

The runner validates that every `case-*.bash` file is registered exactly once. GitHub Actions executes the four suites independently so a failure identifies the affected domain without turning each narrow case into a separate CI surface.
