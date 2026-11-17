# P8V canary hostname isolation HOLD — 2026-11-17

**Release status: HOLD.** This is a sanitized, operator-reported observation
about a *proposed* rc.13 canary test hostname, not authorization to change
Cloudflare, OCI, the original VM or the stopped rc.12 appliance.

## Operator response

| Check | Operator response | Meaning for canary acceptance |
| --- | --- | --- |
| Test FQDN | ACCEPT: vwoci-rc13-canary.lazymocha.com | Candidate selected by operator, not isolated or authorized for use |
| Zone ownership | CONFIRMED | Operator-reported; independent account/zone attestation still pending |
| Exact DNS record | PRESENT | Existing record must be positively identified and reviewed for ownership/target; **do not overwrite** |
| DNS wildcard | PRESENT | Wildcard coverage may affect the proposed canary; conflict-free DNS **not proven** |
| Worker Route overlap | PRESENT | Explicit route overlap reported; **canary isolation BLOCKED** pending route mapping |
| Worker Custom Domain overlap | PRESENT | Explicit Custom Domain overlap reported; **canary isolation BLOCKED** pending mapping |
| Production config unchanged | YES | Operator reports no production configuration change during investigation |
| Independent reviewer | AVAILABLE | Reviewer can be scheduled; independent attestation has **not** yet been received |

**Verdict:** the existing proposed hostname fails the no-overlap pre-canary
design gate by operator report. This is a **canary-scope BLOCKED/2 condition**,
not proof of a production security incident and not an assessment of whether
the current Cloudflare configuration is correctly intended for existing
services. Treat the DNS record and wildcard as conflicts requiring
attribution, not as permission to delete or change them.

Do **not** set the private P8V-C attestation's
`dns_no_wildcards`, `worker_routes_no_overlap`, or
`worker_custom_domains_no_overlap` flags to true on these observations.
After independent review, confirmed overlap should be recorded as false,
which the verifier already classifies BLOCKED. The reviewer being
*available* is not proof that an independent review occurred.

## Next safe decision

The operator and independent reviewer must choose a genuinely isolated
test name or produce independently witnessed mapping showing that a
separately approved test hostname cannot be intercepted by existing
wildcard DNS records, proxied records, Worker Routes, Custom Domains,
or the production hostname/original VM. Inspect Cloudflare Dashboard
read-only. The previous Worker Routes HTTP403 must **not** be handled by
expanding the operational API token. Do not edit or remove any production
DNS records or Worker routes merely to clear a gate.

A selected DNS name is only one dependency. The isolated blank test
dataset/database, dedicated storage, test-only backup credentials and
remote, console rollback/quarantine and independent external packet-path
proof remain PENDING / NOT RUN as separately documented.

## Historical evidence and Git integration boundary

- 2026-11-17 P8V-A scoped OCI read-only batch: 16 PASS, 12 PENDING,
  0 BLOCKED, 1 NOT RUN; provider transport HOLD/1.
- 2026-11-17 P8V-C source-only batch: 9 PASS, 30 PENDING,
  0 BLOCKED, 1 NOT RUN; HOLD/1.
- 2026-11-17 P8V-D public DNS proposal: 1 PASS, 7 PENDING,
  0 BLOCKED, 1 NOT RUN; HOLD/1, resolvers unavailable/incomplete.
- The newly reported real Dashboard overlaps are later operator evidence
  and **must not** retroactively relabel the P8V-D DNS scanner's output.
- Original P8T strict OCI-only Cloudflare-source TCP443 remains historical
  BLOCKED/2; P8V OCI public TCP443 is transport-only, never external origin
  packet-path proof.
- The currently installed appliance remains immutable rc.12; rc.13 is
  source only. Merging source/documentation to the v2 development branch
  must never activate a service, alter Cloudflare/OCI policies, refresh
  host firewall, touch recovered data, contact historical
  bw-backup:bw-backup, reboot or constitute a production GO.

This record may be integrated into v2 as development documentation even
though the live canary remains BLOCKED/HOLD. It is not an approval to
deploy or an independent reviewer sign-off.
