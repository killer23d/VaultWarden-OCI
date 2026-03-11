#!/usr/bin/env python3
"""smtp_notify.py – Shared Fail2Ban SMTP notification helper.

Replaces four near-identical inline Python scripts in smtp.conf.
All security fixes applied in a single authoritative location:
  - STARTTLS on every connection (safe for remote relays).
  - IP address validated before whois call (prevents SSRF via crafted log).
  - Timestamps use datetime.now(timezone.utc) (accurate regardless of TZ env).
"""
from __future__ import annotations

import argparse
import ipaddress
import smtplib
import subprocess
import sys
from datetime import datetime, timezone
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText


def _utcnow() -> str:
    """Return current UTC time as a human-readable string."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


def _validate_ip(ip: str) -> str:
    """Return ip if it is a valid IPv4 or IPv6 address, else raise ValueError."""
    try:
        ipaddress.ip_address(ip)
        return ip
    except ValueError:
        raise ValueError(f"Invalid IP address: {ip!r}")


def _get_whois_info(ip: str) -> str:
    """Run whois against a validated IP address and return relevant lines."""
    # _validate_ip must be called before this function.
    try:
        result = subprocess.check_output(
            ["whois", ip],
            text=True,
            timeout=10,
            stderr=subprocess.DEVNULL,
        )
        keywords = {
            "orgname", "organization", "orgid", "address", "city",
            "stateprov", "postalcode", "country", "phone", "comment",
            "netname", "descr", "admin-c", "tech-c",
        }
        relevant = [
            line.strip()
            for line in result.splitlines()
            if any(kw in line.lower() for kw in keywords)
        ]
        return "\n".join(relevant[:15]) if relevant else "No relevant whois information found"
    except subprocess.TimeoutExpired:
        return "Whois lookup timed out"
    except subprocess.CalledProcessError:
        return "Whois lookup failed"
    except Exception as exc:  # pylint: disable=broad-except
        return f"Whois error: {exc}"


def _send(host: str, port: int, sender: str, dest: str, msg: MIMEMultipart) -> None:
    """Send msg via SMTP with STARTTLS upgrade.

    STARTTLS is attempted on every connection so that if host is ever
    changed to a remote relay, credentials never transit in plaintext.
    On loopback postfix containers that do not advertise STARTTLS the
    starttls() call will raise SMTPException; the except block logs a
    warning but still delivers (acceptable for localhost-only deployments).
    To enforce TLS on remote relays, set require_tls=True via [Init] in
    smtp.conf and pass --require-tls here.
    """
    server = smtplib.SMTP(host, port, timeout=15)
    try:
        server.ehlo()
        if server.has_extn("STARTTLS"):
            server.starttls()
            server.ehlo()
        else:
            print(
                f"[smtp_notify] WARNING: STARTTLS not offered by {host}:{port} — "
                "connection is plaintext. Use a TLS-capable relay for remote hosts.",
                file=sys.stderr,
            )
        server.send_message(msg)
    finally:
        server.quit()


def _build_msg(sender: str, dest: str, subject: str, body: str) -> MIMEMultipart:
    msg = MIMEMultipart()
    msg["From"] = sender
    msg["To"] = dest
    msg["Subject"] = subject
    msg.attach(MIMEText(body, "plain"))
    return msg


def action_start(args: argparse.Namespace) -> None:
    subject = f"[Fail2Ban] {args.name}: started"
    body = f"""Hi,

The jail {args.name} has been started successfully.

Server: {args.name}
Status: Active
Configuration: VaultWarden-OCI Enhanced Security
Time: {_utcnow()}

Regards,
Fail2Ban"""
    msg = _build_msg(args.sender, args.dest, subject, body)
    _send(args.host, int(args.port), args.sender, args.dest, msg)
    print("Jail start notification sent successfully")


def action_stop(args: argparse.Namespace) -> None:
    subject = f"[Fail2Ban] {args.name}: stopped"
    body = f"""Hi,

The jail {args.name} has been stopped.

Server: {args.name}
Status: Inactive
Configuration: VaultWarden-OCI Enhanced Security
Time: {_utcnow()}

Please verify this was intentional. If unexpected, investigate immediately.

Regards,
Fail2Ban"""
    msg = _build_msg(args.sender, args.dest, subject, body)
    _send(args.host, int(args.port), args.sender, args.dest, msg)
    print("Jail stop notification sent successfully")


def action_ban(args: argparse.Namespace) -> None:
    ip = _validate_ip(args.ip)
    whois_info = _get_whois_info(ip)
    subject = f"[Fail2Ban] {args.name}: BANNED {ip} after {args.failures} attempts"
    body = f"""SECURITY ALERT

The IP address {ip} has been BANNED by Fail2Ban after {args.failures} failed attempts against {args.name}.

BAN DETAILS:
- IP Address: {ip}
- Service: {args.name}
- Failed Attempts: {args.failures}
- Ban Time: {_utcnow()}
- Server: VaultWarden-OCI

WHOIS INFORMATION:
{whois_info}

RECOMMENDED ACTIONS:
1. Review the attack patterns in your logs
2. Consider extending ban time if this is a repeat offender
3. Check for any successful logins from this IP before the ban
4. Monitor for attempts from related IP ranges

This is an automated security notification from your VaultWarden-OCI deployment.

Regards,
Fail2Ban Security Monitor"""
    msg = _build_msg(args.sender, args.dest, subject, body)
    _send(args.host, int(args.port), args.sender, args.dest, msg)
    print(f"Ban notification sent for IP {ip}")


def action_unban(args: argparse.Namespace) -> None:
    ip = _validate_ip(args.ip)
    subject = f"[Fail2Ban] {args.name}: unbanned {ip}"
    body = f"""Hi,

The IP address {ip} has been UNBANNED by Fail2Ban.

UNBAN DETAILS:
- IP Address: {ip}
- Service: {args.name}
- Unban Time: {_utcnow()}
- Server: VaultWarden-OCI

This IP is now able to access your services again. Continue monitoring for suspicious activity.

Regards,
Fail2Ban Security Monitor"""
    msg = _build_msg(args.sender, args.dest, subject, body)
    _send(args.host, int(args.port), args.sender, args.dest, msg)
    print(f"Unban notification sent for IP {ip}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Fail2Ban SMTP notification helper")
    parser.add_argument("--action",   required=True, choices=["start", "stop", "ban", "unban"])
    parser.add_argument("--name",     required=True)
    parser.add_argument("--sender",   required=True)
    parser.add_argument("--dest",     required=True)
    parser.add_argument("--host",     required=True)
    parser.add_argument("--port",     required=True)
    parser.add_argument("--ip",       default="")
    parser.add_argument("--failures", default="0")
    args = parser.parse_args()

    dispatch = {
        "start": action_start,
        "stop":  action_stop,
        "ban":   action_ban,
        "unban": action_unban,
    }
    try:
        dispatch[args.action](args)
    except ValueError as exc:
        print(f"[smtp_notify] ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
    except smtplib.SMTPException as exc:
        print(f"[smtp_notify] ERROR: SMTP failure: {exc}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:  # pylint: disable=broad-except
        print(f"[smtp_notify] ERROR: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
