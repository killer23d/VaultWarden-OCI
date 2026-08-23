"""Central freezing of exact component versions and image references."""
from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import tomllib
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Mapping

from . import cli, install

DEVELOPMENT_ENV = "VWOCI_DEVELOPMENT"
RESOLVED_STATE = Path("/var/lib/vaultwarden-oci/state/resolved-versions.json")
_IMAGE_NAMES = ("vaultwarden", "caddy_builder", "caddy_runtime")
_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
_RELEASE_URLS = {
    "vaultwarden": "https://api.github.com/repos/dani-garcia/vaultwarden/releases/latest",
    "caddy": "https://api.github.com/repos/caddyserver/caddy/releases/latest",
    "caddy_dns_cloudflare": "https://api.github.com/repos/caddy-dns/cloudflare/releases/latest",
}
_TAG_URLS = {
    "caddy_combine_ip_ranges": "https://api.github.com/repos/fvbommel/caddy-combine-ip-ranges/tags?per_page=1",
    "caddy_ratelimit": "https://api.github.com/repos/mholt/caddy-ratelimit/tags?per_page=1",
}
_COMMIT_URLS = {
    "caddy_cloudflare_ip": "https://api.github.com/repos/WeidiDeng/caddy-cloudflare-ip/commits?per_page=1",
}
_MANIFEST_ACCEPT = ", ".join(
    (
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
    )
)


class UpdateError(RuntimeError):
    """Raised when a version/update boundary cannot be proven safe."""


@dataclass(frozen=True)
class ImagePin:
    name: str
    repository: str
    tag: str
    digest: str

    @property
    def reference(self) -> str:
        return f"{self.repository}:{self.tag}@{self.digest}"

    @property
    def tag_reference(self) -> str:
        return f"{self.repository}:{self.tag}"


@dataclass(frozen=True)
class FrozenVersions:
    source: str
    architecture: str
    project_version: str
    vaultwarden: str
    caddy: str
    caddy_dns_cloudflare: str
    vaultwarden_image: ImagePin
    caddy_builder_image: ImagePin
    caddy_runtime_image: ImagePin
    caddy_cloudflare_ip: str = ""
    caddy_combine_ip_ranges: str = ""
    caddy_ratelimit: str = ""

    @property
    def caddy_image(self) -> str:
        return f"vaultwarden-oci/caddy:{self.caddy}-edge"

    def as_dict(self) -> dict[str, object]:
        images = {}
        for pin in (self.vaultwarden_image, self.caddy_builder_image, self.caddy_runtime_image):
            images[pin.name] = {
                "repository": pin.repository,
                "tag": pin.tag,
                "digest": pin.digest,
                "reference": pin.reference,
            }
        return {
            "schema_version": 1,
            "source": self.source,
            "architecture": self.architecture,
            "project_version": self.project_version,
            "components": {
                "vaultwarden": self.vaultwarden,
                "caddy": self.caddy,
                "caddy_dns_cloudflare": self.caddy_dns_cloudflare,
                "caddy_cloudflare_ip": self.caddy_cloudflare_ip,
                "caddy_combine_ip_ranges": self.caddy_combine_ip_ranges,
                "caddy_ratelimit": self.caddy_ratelimit,
            },
            "images": images,
        }


JsonGetter = Callable[[str, Mapping[str, str] | None], object]


def _get_json(url: str, headers: Mapping[str, str] | None = None) -> object:
    request_headers = {"Accept": "application/vnd.github+json", "User-Agent": "vaultwarden-oci-v2"}
    if headers:
        request_headers.update(headers)
    request = urllib.request.Request(url, headers=request_headers, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            if response.status != 200:
                raise UpdateError(f"remote lookup returned HTTP {response.status}")
            raw = response.read(1024 * 1024 + 1)
    except (OSError, TimeoutError) as exc:
        raise UpdateError(f"remote lookup failed: {exc}") from exc
    if len(raw) > 1024 * 1024:
        raise UpdateError("remote lookup response was unexpectedly large")
    try:
        return json.loads(raw)
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise UpdateError("remote lookup returned invalid JSON") from exc


class RemoteLookup:
    """Small remote boundary for upstream refs and architecture image digests."""

    def __init__(self, get_json: JsonGetter = _get_json):
        self._get_json = get_json

    def latest_release(self, component: str) -> str:
        try:
            url = _RELEASE_URLS[component]
        except KeyError as exc:
            raise UpdateError(f"no latest-release boundary for {component}") from exc
        payload = self._get_json(url, None)
        tag = payload.get("tag_name") if isinstance(payload, dict) else None
        if not isinstance(tag, str) or not tag or tag.strip() != tag or any(c.isspace() for c in tag):
            raise UpdateError(f"latest release for {component} had an invalid tag")
        return tag

    def latest_ref(self, component: str) -> str:
        """Resolve one exact xcaddy addon ref once; never return a floating branch."""
        if component in _TAG_URLS:
            payload = self._get_json(_TAG_URLS[component], None)
            item = payload[0] if isinstance(payload, list) and payload else None
            value = item.get("name") if isinstance(item, dict) else None
        elif component in _COMMIT_URLS:
            payload = self._get_json(_COMMIT_URLS[component], None)
            item = payload[0] if isinstance(payload, list) and payload else None
            value = item.get("sha") if isinstance(item, dict) else None
        else:
            raise UpdateError(f"no latest-ref boundary for {component}")
        if not isinstance(value, str) or not value or value.strip() != value or any(c.isspace() for c in value):
            raise UpdateError(f"latest ref for {component} was invalid")
        if component in _COMMIT_URLS and not re.fullmatch(r"[0-9a-f]{40}", value):
            raise UpdateError(f"latest commit ref for {component} was not an exact SHA")
        return value

    def image_digest(self, repository: str, tag: str, architecture: str) -> str:
        arch = architecture_name(architecture)
        registry_repository = repository if "/" in repository else f"library/{repository}"
        scope = urllib.parse.quote(f"repository:{registry_repository}:pull", safe=":/")
        token_payload = self._get_json(
            "https://auth.docker.io/token?service=registry.docker.io&scope=" + scope,
            None,
        )
        token = token_payload.get("token") if isinstance(token_payload, dict) else None
        if not isinstance(token, str) or not token:
            raise UpdateError(f"registry token lookup failed for {repository}:{tag}")
        url = (
            f"https://registry-1.docker.io/v2/{registry_repository}/manifests/"
            + urllib.parse.quote(tag, safe="._-")
        )
        payload = self._get_json(
            url,
            {"Accept": _MANIFEST_ACCEPT, "Authorization": f"Bearer {token}"},
        )
        manifests = payload.get("manifests") if isinstance(payload, dict) else None
        if not isinstance(manifests, list):
            raise UpdateError(f"registry manifest list missing for {repository}:{tag}")
        matches = []
        for item in manifests:
            platform_data = item.get("platform") if isinstance(item, dict) else None
            digest = item.get("digest") if isinstance(item, dict) else None
            if (
                isinstance(platform_data, dict)
                and platform_data.get("os") == "linux"
                and platform_data.get("architecture") == arch
                and isinstance(digest, str)
                and _DIGEST.fullmatch(digest)
            ):
                matches.append(digest)
        if len(matches) != 1:
            raise UpdateError(
                f"expected one linux/{arch} image for {repository}:{tag}, found {len(matches)}"
            )
        return matches[0]


def architecture_name(machine: str | None = None) -> str:
    try:
        return cli.normalize_architecture(machine if machine is not None else platform.machine())
    except ValueError as exc:
        raise UpdateError(str(exc)) from exc


def _digest(value: object, label: str) -> str:
    if not isinstance(value, str) or not _DIGEST.fullmatch(value):
        raise UpdateError(f"{label} must be an exact sha256 image digest")
    return value


def _image_digests(
    path: Path,
    architecture: str,
    *,
    require_all_architectures: bool,
) -> dict[str, str]:
    try:
        with path.open("rb") as handle:
            data = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise UpdateError(f"cannot load image pins from {path}: {exc}") from exc
    raw = data.get("image_digests") if isinstance(data, dict) else None
    if not isinstance(raw, dict):
        raise UpdateError("versions.toml requires [image_digests.*] exact production pins")
    unknown = sorted(set(raw) - set(_IMAGE_NAMES))
    if unknown:
        raise UpdateError("unknown image digest pin(s): " + ", ".join(unknown))
    result = {}
    for name in _IMAGE_NAMES:
        table = raw.get(name)
        if not isinstance(table, dict):
            raise UpdateError(f"versions.toml requires [image_digests.{name}]")
        unknown_arch = sorted(set(table) - {"amd64", "arm64"})
        if unknown_arch:
            raise UpdateError(f"unknown architecture pin(s) for {name}: " + ", ".join(unknown_arch))
        required_arches = ("amd64", "arm64") if require_all_architectures else (architecture,)
        validated = {
            arch: _digest(table.get(arch), f"image_digests.{name}.{arch}")
            for arch in required_arches
        }
        result[name] = validated[architecture]
    return result


def _freeze(
    source: str,
    architecture: str,
    project: str,
    vaultwarden: str,
    caddy: str,
    plugin: str,
    trusted_proxy: str,
    combine_ranges: str,
    rate_limit: str,
    digests: Mapping[str, str],
) -> FrozenVersions:
    return FrozenVersions(
        source,
        architecture,
        project,
        vaultwarden,
        caddy,
        plugin,
        ImagePin("vaultwarden", "vaultwarden/server", vaultwarden, digests["vaultwarden"]),
        ImagePin("caddy_builder", "caddy", f"{caddy}-builder-alpine", digests["caddy_builder"]),
        ImagePin("caddy_runtime", "caddy", f"{caddy}-alpine", digests["caddy_runtime"]),
        caddy_cloudflare_ip=trusted_proxy,
        caddy_combine_ip_ranges=combine_ranges,
        caddy_ratelimit=rate_limit,
    )


def resolve_pinned_file(
    path: Path,
    *,
    machine: str | None = None,
    require_all_architectures: bool = False,
) -> FrozenVersions:
    """Resolve one exact versions manifest for the requested/current architecture."""
    path = path.resolve()
    try:
        manifest = cli.load_versions(path, require_components=True)
    except cli.VersionsError as exc:
        raise UpdateError(str(exc)) from exc
    arch = architecture_name(machine)
    return _freeze(
        "pinned",
        arch,
        manifest.version,
        manifest.vaultwarden,
        manifest.caddy,
        manifest.caddy_dns_cloudflare,
        manifest.caddy_cloudflare_ip,
        manifest.caddy_combine_ip_ranges,
        manifest.caddy_ratelimit,
        _image_digests(path, arch, require_all_architectures=require_all_architectures),
    )


def resolve_pinned(source_root: Path, *, machine: str | None = None) -> FrozenVersions:
    """Resolve source-controlled production pins and validate both supported architectures."""
    return resolve_pinned_file(
        source_root.resolve() / "versions.toml",
        machine=machine,
        require_all_architectures=True,
    )


def _require_development() -> None:
    if os.environ.get(DEVELOPMENT_ENV) != "1":
        raise UpdateError(
            f"--use-latest is development/testing-only; set {DEVELOPMENT_ENV}=1 explicitly"
        )


def require_development_target(root: Path) -> None:
    """Legacy development boundary retained for the low-level installer CLI."""
    _require_development()
    if root.resolve() == Path("/"):
        raise UpdateError(
            "--use-latest may not target the production root /; use an isolated --root for development/testing"
        )


def _latest_snapshot(
    source_root: Path,
    *,
    machine: str | None,
    lookup: RemoteLookup | None,
    include_all_addons: bool,
) -> FrozenVersions:
    source_root = source_root.resolve()
    try:
        base = cli.load_versions(source_root / "versions.toml", require_components=True)
    except cli.VersionsError as exc:
        raise UpdateError(str(exc)) from exc
    arch = architecture_name(machine)
    remote = lookup or RemoteLookup()
    vaultwarden = remote.latest_release("vaultwarden").removeprefix("v")
    caddy = remote.latest_release("caddy").removeprefix("v")
    plugin_tag = remote.latest_release("caddy_dns_cloudflare")
    plugin = plugin_tag if plugin_tag.startswith("v") else f"v{plugin_tag}"
    if include_all_addons:
        trusted_proxy = remote.latest_ref("caddy_cloudflare_ip")
        combine_ranges = remote.latest_ref("caddy_combine_ip_ranges")
        rate_limit = remote.latest_ref("caddy_ratelimit")
    else:
        trusted_proxy = base.caddy_cloudflare_ip
        combine_ranges = base.caddy_combine_ip_ranges
        rate_limit = base.caddy_ratelimit
    for value, label in (
        (vaultwarden, "vaultwarden"),
        (caddy, "caddy"),
        (plugin, "caddy_dns_cloudflare"),
        (trusted_proxy, "caddy_cloudflare_ip"),
        (combine_ranges, "caddy_combine_ip_ranges"),
        (rate_limit, "caddy_ratelimit"),
    ):
        try:
            cli._pin(value, label)
        except cli.VersionsError as exc:
            raise UpdateError(str(exc)) from exc
    digests = {
        "vaultwarden": remote.image_digest("vaultwarden/server", vaultwarden, arch),
        "caddy_builder": remote.image_digest("caddy", f"{caddy}-builder-alpine", arch),
        "caddy_runtime": remote.image_digest("caddy", f"{caddy}-alpine", arch),
    }
    exact = {
        "architecture": arch,
        "vaultwarden": vaultwarden,
        "caddy": caddy,
        "caddy_dns_cloudflare": plugin,
        "caddy_cloudflare_ip": trusted_proxy,
        "caddy_combine_ip_ranges": combine_ranges,
        "caddy_ratelimit": rate_limit,
        "digests": digests,
    }
    suffix = hashlib.sha256(
        json.dumps(exact, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()[:12]
    try:
        project = install.validate_release_name(f"{base.version}.latest.{suffix}")
    except install.InstallError as exc:
        raise UpdateError(str(exc)) from exc
    return _freeze(
        "latest", arch, project, vaultwarden, caddy, plugin,
        trusted_proxy, combine_ranges, rate_limit, digests,
    )


def resolve_latest(
    source_root: Path,
    *,
    machine: str | None = None,
    lookup: RemoteLookup | None = None,
) -> FrozenVersions:
    """Legacy development/test latest resolver retained for compatibility."""
    _require_development()
    return _latest_snapshot(
        source_root, machine=machine, lookup=lookup, include_all_addons=False
    )


def resolve_latest_supported(
    source_root: Path,
    *,
    machine: str | None = None,
    lookup: RemoteLookup | None = None,
) -> FrozenVersions:
    """Resolve every supported upstream boundary once for operator --use-latest."""
    return _latest_snapshot(
        source_root, machine=machine, lookup=lookup, include_all_addons=True
    )


def frozen_versions_toml(frozen: FrozenVersions) -> str:
    lines = [
        "schema_version = 1",
        "",
        "[vaultwarden_oci]",
        f'version = "{frozen.project_version}"',
        "",
        "[components]",
        f'vaultwarden = "{frozen.vaultwarden}"',
        f'caddy = "{frozen.caddy}"',
        f'caddy_dns_cloudflare = "{frozen.caddy_dns_cloudflare}"',
        f'caddy_cloudflare_ip = "{frozen.caddy_cloudflare_ip}"',
        f'caddy_combine_ip_ranges = "{frozen.caddy_combine_ip_ranges}"',
        f'caddy_ratelimit = "{frozen.caddy_ratelimit}"',
    ]
    for pin in (frozen.vaultwarden_image, frozen.caddy_builder_image, frozen.caddy_runtime_image):
        lines.extend(("", f"[image_digests.{pin.name}]", f'{frozen.architecture} = "{pin.digest}"'))
    return "\n".join(lines) + "\n"


def record_frozen(frozen: FrozenVersions, path: Path = RESOLVED_STATE) -> None:
    payload = frozen.as_dict()
    payload["recorded_at"] = (
        datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.parent / f".{path.name}.{os.getpid()}.tmp"
    try:
        fd = os.open(
            tmp,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        os.chmod(path, 0o600)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise
