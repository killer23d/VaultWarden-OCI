"""Cloudflare Worker decision-source policy and invocation proof.

The Worker is intentionally a narrow remediation path for locally generated
web decisions. Broad/community/list decisions belong to the host INPUT
firewall bouncer. This module keeps that Free-plan-friendly boundary explicit
without adding quota polling or a general policy framework.
"""
from __future__ import annotations

import ast
import hashlib
import json
import stat
from pathlib import Path
from typing import Sequence

from . import cli, edge

LOCAL_DECISION_SOURCES = ("cscli", "crowdsec")
_SCHEMA_VERSION = 1
_MANAGED_HEADER = "# Managed by VaultWarden-OCI.\n"


class WorkerPolicyError(RuntimeError):
    """Raised when the Worker source policy cannot be safely proven."""


def override_path(paths: edge.EdgePaths) -> Path:
    return Path(str(paths.remediation_config) + ".local")


def attestation_path(paths: edge.EdgePaths) -> Path:
    return paths.fail_open_confirmation.parent / "crowdsec-cloudflare-worker-policy.json"


def managed_override_text() -> str:
    return (
        _MANAGED_HEADER
        + "crowdsec_config:\n"
        + '  only_include_decisions_from: ["cscli", "crowdsec"]\n'
    )


def _regular_bytes(path: Path, label: str, *, missing_ok: bool = False) -> bytes | None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        if missing_ok:
            return None
        raise WorkerPolicyError(f"{label} is missing: {path}")
    except OSError as exc:
        raise WorkerPolicyError(f"cannot inspect {label} {path}: {exc}") from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise WorkerPolicyError(f"{label} is not a regular file: {path}")
    try:
        return path.read_bytes()
    except OSError as exc:
        raise WorkerPolicyError(f"cannot read {label} {path}: {exc}") from exc


def _parse_sources(raw: bytes, label: str) -> tuple[str, ...] | None:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise WorkerPolicyError(f"{label} is not UTF-8") from exc
    values: list[str] = []
    found = 0
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped.startswith("only_include_decisions_from:"):
            continue
        found += 1
        tail = stripped.split(":", 1)[1].strip()
        try:
            parsed = ast.literal_eval(tail)
        except (SyntaxError, ValueError) as exc:
            raise WorkerPolicyError(f"{label} has an invalid only_include_decisions_from value") from exc
        if not isinstance(parsed, list) or not all(isinstance(item, str) for item in parsed):
            raise WorkerPolicyError(f"{label} only_include_decisions_from must be a string list")
        values = list(parsed)
    if found == 0:
        return None
    if found != 1:
        raise WorkerPolicyError(f"{label} has duplicate only_include_decisions_from settings")
    if len(set(values)) != len(values):
        raise WorkerPolicyError(f"{label} has duplicate decision sources")
    return tuple(values)


def source_state(paths: edge.EdgePaths) -> tuple[tuple[str, ...], tuple[str, ...] | None, tuple[str, ...]]:
    base_raw = _regular_bytes(paths.remediation_config, "Cloudflare Worker base config")
    assert base_raw is not None
    base = _parse_sources(base_raw, "Cloudflare Worker base config")
    if base is None:
        raise WorkerPolicyError("Cloudflare Worker base config does not declare only_include_decisions_from")

    local_raw = _regular_bytes(override_path(paths), "Cloudflare Worker local override", missing_ok=True)
    local = None if local_raw is None else _parse_sources(local_raw, "Cloudflare Worker local override")
    if local_raw is not None and local is None:
        raise WorkerPolicyError("Cloudflare Worker local override does not declare only_include_decisions_from")
    effective = local if local is not None else base
    return base, local, effective


def _config_digest(paths: edge.EdgePaths) -> str:
    base = _regular_bytes(paths.remediation_config, "Cloudflare Worker base config")
    local = _regular_bytes(override_path(paths), "Cloudflare Worker local override", missing_ok=True)
    assert base is not None
    digest = hashlib.sha256()
    digest.update(base)
    digest.update(b"\0local\0")
    digest.update(local if local is not None else b"<absent>")
    return digest.hexdigest()


def _config_test(paths: edge.EdgePaths, runner: edge.Runner) -> bool:
    return runner([edge.BOUNCER_BINARY, "-c", str(paths.remediation_config), "-t"]).ok


def managed_override_present(paths: edge.EdgePaths) -> bool:
    raw = _regular_bytes(override_path(paths), "Cloudflare Worker local override", missing_ok=True)
    return raw == managed_override_text().encode("utf-8")


def install_managed_override(paths: edge.EdgePaths) -> None:
    path = override_path(paths)
    existing = _regular_bytes(path, "Cloudflare Worker local override", missing_ok=True)
    expected = managed_override_text().encode("utf-8")
    if existing is not None and existing != expected:
        raise WorkerPolicyError(
            f"refusing to replace unexpected Cloudflare Worker local override {path}; resolve it explicitly"
        )
    try:
        edge._write_root_file(path, managed_override_text(), 0o600)
    except edge.EdgeError as exc:
        raise WorkerPolicyError(str(exc)) from exc


def clear_attestation(paths: edge.EdgePaths) -> None:
    path = attestation_path(paths)
    try:
        path.unlink(missing_ok=True)
    except OSError as exc:
        raise WorkerPolicyError(f"cannot clear Cloudflare Worker policy attestation {path}: {exc}") from exc


def _load_attestation(paths: edge.EdgePaths) -> dict[str, object] | None:
    raw = _regular_bytes(attestation_path(paths), "Cloudflare Worker policy attestation", missing_ok=True)
    if raw is None:
        return None
    try:
        payload = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def attestation_current(paths: edge.EdgePaths, runner: edge.Runner) -> bool:
    invocation = edge._service_invocation_id(runner)
    if invocation is None:
        return False
    payload = _load_attestation(paths)
    if payload is None:
        return False
    try:
        digest = _config_digest(paths)
    except WorkerPolicyError:
        return False
    return (
        payload.get("schema_version") == _SCHEMA_VERSION
        and payload.get("invocation_id") == invocation
        and payload.get("config_sha256") == digest
        and payload.get("sources") == list(LOCAL_DECISION_SOURCES)
    )


def config_local_only(paths: edge.EdgePaths, runner: edge.Runner) -> bool:
    if not _config_test(paths, runner):
        return False
    try:
        _, _, effective = source_state(paths)
    except WorkerPolicyError:
        return False
    return effective == LOCAL_DECISION_SOURCES


def runtime_policy_healthy(paths: edge.EdgePaths, runner: edge.Runner) -> bool:
    """Prove this active invocation started from the exact local-only policy."""
    if not edge._active(edge.BOUNCER_SERVICE, runner) or not config_local_only(paths, runner):
        return False
    try:
        base, local, _ = source_state(paths)
    except WorkerPolicyError:
        return False
    supported = (
        (base == LOCAL_DECISION_SOURCES and local in {None, LOCAL_DECISION_SOURCES})
        or (
            base == ()
            and local == LOCAL_DECISION_SOURCES
            and managed_override_present(paths)
        )
    )
    return supported and attestation_current(paths, runner)


def attest_current(paths: edge.EdgePaths, runner: edge.Runner) -> None:
    if not config_local_only(paths, runner):
        raise WorkerPolicyError("Cloudflare Worker merged config is not local-origin-only")
    invocation = edge._service_invocation_id(runner)
    if invocation is None:
        raise WorkerPolicyError("Cloudflare Worker is not active with a valid invocation")
    base, local, _ = source_state(paths)
    if base != LOCAL_DECISION_SOURCES and not (
        base == () and local == LOCAL_DECISION_SOURCES and managed_override_present(paths)
    ):
        raise WorkerPolicyError("Cloudflare Worker source policy is not a supported local-only configuration")
    payload = {
        "schema_version": _SCHEMA_VERSION,
        "invocation_id": invocation,
        "config_sha256": _config_digest(paths),
        "sources": list(LOCAL_DECISION_SOURCES),
    }
    try:
        edge._atomic_write(
            attestation_path(paths),
            json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n",
            0o600,
        )
    except OSError as exc:
        raise WorkerPolicyError(f"cannot persist Cloudflare Worker policy attestation: {exc}") from exc


def enforce_doctor_checks(
    checks: Sequence[cli.DoctorCheck],
    *,
    paths: edge.EdgePaths,
    runner: edge.Runner,
) -> list[cli.DoctorCheck]:
    """Make the existing crowdsec.cloudflare result include the source invariant."""
    policy_ok = runtime_policy_healthy(paths, runner)
    result: list[cli.DoctorCheck] = []
    found = False
    for check in checks:
        if check.check_id != "crowdsec.cloudflare":
            result.append(check)
            continue
        found = True
        if check.status == "PASS" and policy_ok:
            result.append(
                cli.DoctorCheck(
                    check.check_id,
                    "PASS",
                    "Cloudflare Worker bouncer is active, boot-disabled, Fail Open is confirmed for this invocation, and decision sources are exactly cscli/crowdsec",
                )
            )
        elif check.status == "PASS":
            result.append(
                cli.DoctorCheck(
                    check.check_id,
                    "FAIL",
                    "Cloudflare Worker is not proven to use exactly local cscli/crowdsec decision sources for its current invocation",
                )
            )
        else:
            result.append(check)
    if not found:
        raise WorkerPolicyError("CrowdSec doctor surface is missing crowdsec.cloudflare")
    return result
