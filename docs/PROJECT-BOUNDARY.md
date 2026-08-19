# VaultWarden-OCI V2 product boundary

VaultWarden-OCI V2 is a greenfield, fresh-install Vaultwarden appliance for a small team of roughly 10 users and a junior administrator. V1 remains a security/behavior reference, not a compatibility target.

## Supported beta production path

- Ubuntu 24.04 LTS Noble only.
- amd64 and arm64 are the tested architectures.
- Runtime behavior is cloud-provider neutral; OCI A1 Flex is a reference deployment only.
- Cloudflare-proxied production ingress with Caddy.
- Docker bridge networking with one project-owned iptables origin packet-filter path that permits published Caddy HTTPS only from validated Cloudflare ranges, uses bounded last-known-good state, and fails closed when no safe policy is available.
- CrowdSec is retained for proxied web-client remediation through one current supported Cloudflare remediation component. A CrowdSec host firewall bouncer is not a beta requirement.
- Python 3.12 standard-library-first project logic, with Bash limited to minimal bootstrap/host/container glue where materially simpler.
- One public operator CLI: `vwctl`.
- One installed operator-editable non-secret config authority: `/etc/vaultwarden-oci/config.toml`.
- One source-controlled version authority: `versions.toml`.
- SOPS + Age for one structured encrypted secrets document, one root-only operational Age identity, separate offline recovery material/recipient, and volatile decrypted runtime secrets only.
- Vaultwarden application mail uses direct authenticated SMTP.
- Operational notifications use one operator-selected canonical built-in HTTPS provider: `mailersend`, `sendgrid`, `mailgun`, `postmark`, `resend`, or `cyberpersons`. `cyberpanel` is accepted only as an alias of the same `cyberpersons` definition.
- Operational provider transport metadata lives in one source-controlled non-secret `email-providers.toml` shipped with the immutable application release. It is release metadata, not a second operator-editable config authority, and it never contains credentials.
- Provider templates use exactly these canonical message fields: `from_email`, `from_name`, `from_header`, `to_email`, `subject`, `text`.
- The common operational API credential is the SOPS secret `email_api_token` unless a current provider requirement demonstrably needs another documented secret. Mailgun may additionally require declared non-secret region/domain options.
- Operator configuration may select a supported provider/alias and declared non-secret options; it may not define arbitrary provider endpoints, authentication modes, headers, payload templates, success rules, or retry rules.
- Authenticated SMTP fallback is used only after a small bounded API retry and only for failures clearly transient by network semantics or current provider documentation. There is no blanket rule that all HTTP `5xx` responses are transient.
- CyberPersons baseline for Phase 6 re-verification: `429` and `503` are currently transient/retryable; HTTP `500 send_failed` is not transient by status alone and must not be silently masked by SMTP fallback.
- rclone is first-class for offsite recovery publication and retrieval.
- One encrypted V2 recovery format plus separate offline recovery material.
- systemd is the lifecycle/scheduling authority.
- Production versions are exact pins. `--use-latest` is development/testing-only and resolves once to exact recorded values for that run.

## Explicit non-goals for beta

V2 does not preserve V1 project-state, archive/backup-format, migration, command-alias, runtime-layout, dashboard, Postfix/local-MTA, queue/spool/dead-letter, multiple backup-tier, or test-runner compatibility.

V2 also does not provide a second firewall backend, non-Cloudflare production ingress path, a CrowdSec host firewall bouncer requirement, Kubernetes/Swarm/HA abstraction, generic cloud/storage/secrets/notification provider framework, dynamic notification plugins, arbitrary operator-defined HTTP scripting, Python entry-point discovery, a provider SDK, ORM, daemon, event bus, workflow engine, database-backed operation state, generic transaction framework, or distributed lock.

Operational notification provider IDs outside the six canonical built-ins and the `cyberpanel` alias are rejected. The alias does not create a seventh transport definition.

## Security and recovery shape

The Cloudflare origin policy and CrowdSec remediation are distinct controls: the project-owned Docker/iptables path restricts origin Caddy ingress to validated Cloudflare source ranges, while CrowdSec web-client decisions are remediated through Cloudflare. Do not treat the origin allowlist as a second CrowdSec decision plane or require a CrowdSec host firewall bouncer for beta.

Normal recovery publication is:

```text
create recovery point
-> verify locally
-> rclone copy/copyto-style publication
-> verify remote recovery point
-> report success
```

Pruning/deletion is a separate explicit operation. Normal publication must not use destructive `rclone sync` semantics.

Restore supports the V2 recovery format only. V1 archive readers and a public `db`/`full`/`emergency` tier model are not product requirements.

## Operator surface

The beta operator experience centers on `vwctl`, especially `vwctl status`, `vwctl doctor`, and logs. There is no dashboard/TUI requirement for beta.

## Decision details

`docs/V2-DECISIONS.md` records the durable Phase 0 decisions behind this boundary. `reports/V2-CODEX-PROMPTS.md` remains the authoritative phase execution contract.
