from pathlib import Path

p = Path('.github/codex_apply_edge.py')
s = p.read_text(encoding='utf-8')

# Only expand exact TOML lines with a real newline; do not corrupt Python strings containing escaped \n.
s = s.replace(
'''    needle = 'caddy_dns_cloudflare = "v0.2.4"'\n    if needle in text and 'caddy_cloudflare_ip = "f53b62' not in text:\n        target.write_text(text.replace(needle, PINS), encoding="utf-8")\n''',
'''    needle = 'caddy_dns_cloudflare = "v0.2.4"\\n'\n    if needle in text and 'caddy_cloudflare_ip = "f53b62' not in text:\n        target.write_text(text.replace(needle, PINS + "\\n"), encoding="utf-8")\n''')

# Preserve existing positional FrozenVersions constructors by appending new pins as defaulted fields.
s = s.replace(
'''edit(\n    "vaultwarden_oci/update_versions.py",\n    '    caddy_dns_cloudflare: str\\n    vaultwarden_image: ImagePin\\n',\n    '    caddy_dns_cloudflare: str\\n    caddy_cloudflare_ip: str\\n    caddy_combine_ip_ranges: str\\n    caddy_ratelimit: str\\n    vaultwarden_image: ImagePin\\n',\n)\n''',
'''edit(\n    "vaultwarden_oci/update_versions.py",\n    '    caddy_runtime_image: ImagePin\\n',\n    '    caddy_runtime_image: ImagePin\\n    caddy_cloudflare_ip: str = ""\\n    caddy_combine_ip_ranges: str = ""\\n    caddy_ratelimit: str = ""\\n',\n)\n''')
s = s.replace(
'''edit(\n    "vaultwarden_oci/update_versions.py",\n    '        plugin,\\n        ImagePin("vaultwarden",',\n    '        plugin,\\n        trusted_proxy,\\n        combine_ranges,\\n        rate_limit,\\n        ImagePin("vaultwarden",',\n)\n''',
'''edit(\n    "vaultwarden_oci/update_versions.py",\n    '        ImagePin("caddy_runtime", "caddy", f"{caddy}-alpine", digests["caddy_runtime"]),\\n    )',\n    '        ImagePin("caddy_runtime", "caddy", f"{caddy}-alpine", digests["caddy_runtime"]),\\n        caddy_cloudflare_ip=trusted_proxy,\\n        caddy_combine_ip_ranges=combine_ranges,\\n        caddy_ratelimit=rate_limit,\\n    )',\n)\n''')

# Target cleanup specifically; materialization must not treat derived hashes as source values.
s = s.replace(
'''edit(\n    "vaultwarden_oci/secrets.py",\n    '    for key in REQUIRED + OPTIONAL:\\n',\n    '    for key in REQUIRED + OPTIONAL + DERIVED:\\n',\n    count=1,\n)\n''',
'''edit(\n    "vaultwarden_oci/secrets.py",\n    'def cleanup(paths: SecretPaths = SecretPaths()) -> None:\\n    errors = []\\n    for key in REQUIRED + OPTIONAL:\\n',\n    'def cleanup(paths: SecretPaths = SecretPaths()) -> None:\\n    errors = []\\n    for key in REQUIRED + OPTIONAL + DERIVED:\\n',\n)\n''')

# The install test intentionally builds a manifest missing image digests; include the new component pins so it still reaches that boundary.
anchor = '''# versions manifest authority\n'''
extra = '''# Keep the one escaped-string install fixture valid through component validation.\nedit(\n    "tests/v2/test_install.py",\n    '\\'caddy_dns_cloudflare = "v0.2.4"\\\\n\\',',\n    '\\'caddy_dns_cloudflare = "v0.2.4"\\\\n\\'\\n                \\'caddy_cloudflare_ip = "f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5"\\\\n\\'\\n                \\'caddy_combine_ip_ranges = "v0.0.1"\\\\n\\'\\n                \\'caddy_ratelimit = "v0.1.0"\\\\n\\',',\n)\n\n'''
s = s.replace(anchor, extra + anchor)

p.write_text(s, encoding='utf-8')
print('patch helper corrected')
