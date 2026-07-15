# CrowdSec Security-Event Notifications

VaultWarden-OCI supports three explicit CrowdSec notification modes:

```text
CROWDSEC_NOTIFICATION_MODE=off
CROWDSEC_NOTIFICATION_MODE=smtp
CROWDSEC_NOTIFICATION_MODE=auto
```

The feature remains disabled by default. It is intended for the project's normal small-team deployment and does not add a notification database, persistent queue, or always-running application daemon.

## Delivery modes

### `off`

No project-managed CrowdSec email notification profile is active.

### `smtp`

CrowdSec uses its bundled email notification plugin and submits to the existing loopback-only Postfix relay:

```text
CrowdSec email plugin
        -> 127.0.0.1:587
        -> Postfix sidecar
        -> authenticated/TLS upstream SMTP relay
```

This is the established SMTP-only behavior.

### `auto`

CrowdSec uses its bundled HTTP notification plugin over a private Unix socket. A socket-activated local adapter then calls the repository's existing `send_email()` implementation:

```text
CrowdSec HTTP plugin
        -> /run/vaultwarden-crowdsec-notify.sock
        -> VaultWarden-OCI adapter
        -> lib/email.sh send_email() with EMAIL_MODE=auto
             1. configured HTTP email API
             2. Postfix sidecar
             3. direct authenticated upstream SMTP
```

The adapter contains no provider-specific API implementation. MailerSend, SendGrid, Mailgun, Postmark, Resend, CyberPersons, Postfix submission, SOPS secret lookup, and direct SMTP fallback remain owned by `lib/email.sh`.

The final fallback is the repository's existing direct upstream SMTP path. It is not a separately installed host MTA.

## Configure auto mode

Configure the normal email route first:

```bash
sudo make edit-env
```

Set at least:

```text
CROWDSEC_NOTIFICATION_MODE=auto
EMAIL_PROVIDER=mailersend
ADMIN_EMAIL=admin@example.com
SMTP_FROM=noreply@example.com
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USERNAME=your-smtp-username
```

Set both existing SOPS secrets so API-first delivery and SMTP fallback are usable:

```bash
sudo ./edit-secrets.sh rotate email_api_token
sudo ./edit-secrets.sh rotate smtp_password
```

Install the current root-owned runtime libraries, then reconcile CrowdSec:

```bash
sudo ./setup.sh systemd install
sudo ./utilities/crowdsec-notifications.sh reconcile
```

The reconciler refuses auto mode when the installed `/opt/vaultwarden-scripts/lib` email runtime is missing or differs from the repository. Re-run the systemd installer after a pull that changes managed scripts or libraries.

## Switch modes or disable

Edit `CROWDSEC_NOTIFICATION_MODE`, then reconcile:

```bash
sudo make edit-env
sudo ./utilities/crowdsec-notifications.sh reconcile
```

Mode transitions activate the replacement path before removing the previous path. A failed transition may temporarily leave both paths active, but it does not intentionally remove the last working security-event notification route.

The legacy `CROWDSEC_EMAIL_NOTIFICATIONS` value is retained only for compatibility with `utilities/setup-crowdsec.sh`; the notification reconciler owns that value.

## Status and testing

```bash
sudo ./utilities/crowdsec-notifications.sh status
sudo ./utilities/crowdsec-notifications.sh test
```

In `auto` mode, the test posts a synthetic alert through the Unix socket and exercises the existing API/Postfix/direct-SMTP chain. In `smtp` mode, it uses `cscli notifications test vaultwarden_email`.

A successful command means the selected delivery path accepted the message. Confirm mailbox receipt and inspect the relevant service logs when it does not arrive:

```bash
sudo journalctl -u crowdsec -n 100 --no-pager
sudo journalctl -u 'vaultwarden-crowdsec-notify@*' -n 100 --no-pager
sudo docker compose logs --tail=100 postfix
```

## Failure and retry behavior

CrowdSec 1.7's HTTP notifier reports transport errors to the notification broker, but ordinary non-2xx HTTP responses do not trigger broker retries. Therefore, when every existing email route fails, the local adapter closes the accepted socket without an HTTP response. CrowdSec sees a transport failure and applies the plugin's configured `max_retry` behavior.

The adapter also writes a bounded private failure marker at:

```text
${PROJECT_STATE_DIR}/.vw-health-alert/CROWDSEC_NOTIFY_FAILED
```

A later successful delivery removes that marker.

The adapter is synchronous and socket-activated. This keeps the implementation small, but it is not a durable notification queue. CrowdSec and Postfix retry behavior remain the available reliability layers.

## Security boundary

- No TCP listener is added.
- The Unix socket is accessible only to root and CrowdSec's notification-plugin group on the supported Ubuntu installation.
- CrowdSec's YAML contains no SMTP password or email API token.
- The adapter runs as root because the existing email helper reads root-owned SOPS material.
- The systemd service uses a restricted filesystem view, no additional capabilities, and only Unix/IPv4/IPv6 socket families.
- Request size, request-line size, and header-line size are bounded before JSON processing.

## Remove the auto adapter

To remove only the auto adapter files and managed auto profile:

```bash
sudo ./utilities/crowdsec-notifications.sh uninstall
```

This does not remove CrowdSec, Postfix, the shared email implementation, or SMTP-only notification support.
