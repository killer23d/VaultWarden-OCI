## Checklist

- [ ] All changed shell scripts pass `bash -n` and `shellcheck -S warning`
- [ ] If any `make <target>` behavior changed, `docs/SCRIPTS.md` and `docs/OPERATIONS.md` are updated
- [ ] If any `--flag` was added or removed, all docs referencing that script are updated
- [ ] If backup include/exclude logic changed, backup documentation is verified
- [ ] `CHANGELOG.md` entry added under `[Unreleased]`
- [ ] If systemd units changed, hardening directives are present (PrivateTmp, ProtectSystem, ProtectHome)
