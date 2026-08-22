## V2 pull request checklist

- [ ] Change is within the V2 beta contract and does not add V1 compatibility, dashboard/TUI, Postfix/queue, arbitrary provider endpoints, or speculative plugin/framework architecture.
- [ ] `python3 -m compileall -q vaultwarden_oci tests/v2` passes.
- [ ] `python3 -m unittest discover -s tests/v2 -p 'test_*.py' -v` passes.
- [ ] Changed Bash glue passes `bash -n`.
- [ ] `vwctl --help` remains the command reference; workflow docs/tests were updated for command behavior changes.
- [ ] Provider metadata changes were checked against current official provider documentation and kept in `email-providers.toml` unless a genuinely new transport capability required Python.
- [ ] Immutable release-content changes include a new `[vaultwarden_oci].version` in `versions.toml`.
- [ ] Secret handling, stable doctor IDs/JSON, recovery format, Cloudflare fail-closed behavior, and systemd ownership were reviewed where relevant.
- [ ] Disposable Ubuntu 24.04 host acceptance was run for available `amd64`/`arm64` environments, or exact NOT RUN items are recorded in the PR/release evidence.
