# Changelog

All notable changes to VaultWarden-OCI will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to semantic versioning where applicable.

## [Unreleased]

### Added
- Added slow-check timing warnings to smoke-test TLS, HTTP endpoint, and secrets decryption checks.
- Added dashboard warnings when materialized Docker secrets still contain `CHANGE_ME` placeholders.
- Added startup warning summaries after otherwise successful starts.
- Added restore dependency install hints for missing `age`, `sops`, `sqlite3`, `zstd`, and `tar` tooling.
- Added restore interactive backup listing before the selection prompt.
- Added release-notes next-step hint after setup installation.
- Added this changelog to track user-facing changes.

### Changed
- Standardised dashboard timestamp timezone handling on the project `TZ` setting.
- Improved the Makefile `.env` missing error with a direct setup command.
- Improved email validation for multi-label subdomains and stricter domain labels.
- Routed maintenance subcommand help requests directly to each subcommand.
- Grouped destructive Makefile targets under destructive-operation help sections.
- Preserved dry-run behaviour around startup image pulls.
- Improved root rerun hints so scripts include forwarded arguments.
- Returned dashboard log tailing to the menu after Ctrl+C.
- Standardised help output across operational scripts for command-reference generation.

### Fixed
- Avoided help-menu truncation issues by keeping generated help text concise for `utilities/write-command-reference.sh`.
- Ensured modified shell scripts pass Bash syntax checks.
