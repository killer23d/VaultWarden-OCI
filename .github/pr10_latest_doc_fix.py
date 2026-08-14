from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old!r}")
    p.write_text(text.replace(old, new, 1))


replace_once(
    "utilities/setup-env.sh",
    "    Creates or updates .env and docker-compose.yml from project templates.\n"
    "    Safe to re-run (idempotent) — existing files are not overwritten unless\n"
    "    --force is passed. Called automatically by setup.sh during phase 3.\n",
    "    Creates or updates .env and docker-compose.yml from project templates.\n"
    "    Safe to re-run (idempotent): matching .env and valid Compose are left\n"
    "    unchanged. Changed domain/email/storage/version intent regenerates .env;\n"
    "    --force forces .env and Compose regeneration. Called by setup.sh phase 3.\n",
)
replace_once(
    "utilities/setup-env.sh",
    "    --force               Overwrite existing .env/docker-compose.yml\n",
    "    --force               Force regeneration of .env and docker-compose.yml\n",
)
replace_once(
    "tests/suites/foundation/case-runner-contracts.bash",
    "grep -Fq \"as 'latest' in .env. This persists across later pulls until\" utilities/setup-env.sh \\\n    || fail 'setup-env help must disclose persistent mutable .env tags'\n",
    "grep -Fq \"as 'latest' in .env. This persists across later pulls until\" utilities/setup-env.sh \\\n    || fail 'setup-env help must disclose persistent mutable .env tags'\n"
    "! grep -Fq 'existing files are not overwritten unless' utilities/setup-env.sh \\\n    || fail 'setup-env help must not deny idempotent regeneration when requested intent changes'\n",
)
