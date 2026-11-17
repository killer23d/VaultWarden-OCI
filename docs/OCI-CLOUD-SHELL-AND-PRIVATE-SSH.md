# OCI Cloud Shell access and private-only SSH

This is an **administrator setup and day-2 access guide for OCI deployments** of VaultWarden-OCI, not a script for reapplying past security changes. The appliance is also supported outside OCI. Follow [Install](INSTALL.md), [Security](SECURITY.md), and [Operations](OPERATIONS.md) for the product. For the original accepted disposable-subnet remediation, see [P8T SSH closeout](P8T-PRIVATE-SSH-REMEDIATION-CLOSEOUT.md).

**Default intent:** make SSH (TCP22) reachable **only through the approved private management path**; do not expose TCP22 to `0.0.0.0/0`, `::/0`, or public administrator addresses. The application uses Cloudflare-proxied HTTPS; public OCI TCP443 is **transport only** and never proves Cloudflare-only access until the separate fail-closed host `DOCKER-USER` policy and external packet-path tests pass. No public HTTP TCP80. Preserve legitimate path-MTU ICMP and the approved egress policy. Do **not** maintain Cloudflare CIDR allowlists manually in OCI.

## 1. Choose the correct Cloud Shell network

The **Cloud Shell network selection** is separate from whether the **VM's subnet** is public or private. A VM may still have a public IPv4 for HTTPS while its SSH port is unreachable from the internet.

| Cloud Shell network | Use it for | What not to assume |
| --- | --- | --- |
| **Public Network** | GitHub access, cloning exact reviewed code, public downloads when allowed by tenancy policy | This is **not** permission or a route to SSH over the VM's public IP |
| **OCI Service Network** | Authenticated OCI CLI/Console-supported provider GET/readback and VCN/VNIC/security-list inspection in the correct session region | It may not reach GitHub or other public internet endpoints |
| **Private Network Access (PNA)** | Authenticated SSH to the instance's **private IPv4** through an approved VCN/subnet, using an existing SSH identity | Public GitHub egress and OCI service API egress may be absent; switch modes rather than opening ports or changing IAM just to make diagnostics pass |

In the Cloud Shell terminal, select the mode from the **Network** dropdown. For Private Network Access, select the **preapproved** private-network definition, correct region/VCN and reachable subnet. New Cloud Shell sessions may need the private definition selected again. Access to the selected subnet requires a private route and effective SSH security rules. In a non-home region Cloud Shell storage may be ephemeral; don't assume an SSH key or accepted evidence file persisted in a different session region. The OCI CLI's target region is not automatically changed just because the active Console region changes.

Our operator verified that **GitHub timed out in Service Network** but cloned successfully in Public Network; authenticated SSH worked from PNA; OCI provider reads worked in Service Network. These are observed environment conditions, not a promise that every tenancy has the same egress routes.

See [Oracle Cloud Shell networking](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/cloudshellintro_topic-Cloud_Shell_Networking.htm) and [Cloud Shell session and region behavior](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/cloudshellintro.htm).

## 2. Preflight before closing public SSH

**Do not change an existing subnet until an authorized administrator has approved that exact scope and rollback plan.** New deployments should use a dedicated management-compatible network policy before application startup.

1. Identify the intended instance by **provider instance ID**, then every attached VNIC, its subnet/VCN, all subnet security lists, and every attached VNIC NSG. Names are mutable labels; never choose a target by friendly name alone. Inventory other consumers of the same subnet or shared security lists.
2. Identify the VM's **private IPv4**, the approved **private SSH source CIDR** (the accepted disposable exercise used its VM subnet CIDR), and the Cloud Shell PNA route. The source CIDR must actually cover the PNA source. Inventory IPv6 separately; null fields or zero-byte CLI output **do not** establish that IPv6 is absent.
3. Obtain and protect the existing admin key in the approved location, with user-only file permissions. Independently verify the VM SSH **host key fingerprint** against a known trusted record; do not automatically accept a changed fingerprint. Cloud Shell does not require or grant guest `sudo`; use the `ubuntu` user to log in and only use `sudo -n` on the VM when authorized.
4. **Before** changing any OCI policy, use **Private Network Access** to prove you can authenticate to the instance over its **private** IPv4, reach the expected hostname/account, and establish the actual source/destination recorded in `SSH_CONNECTION`. Do not paste addresses, private keys or host-key trust material in tickets/PRs.
5. Prepare an **owner-private rollback record**, an independently accessible OCI Console/serial-console recovery method, and a short approved maintenance/lockout window. The record belongs under a mode-0600 operator-controlled path, never GitHub or a shared log. If any identity, subnet-sharing or recovery prerequisite is unknown, **HOLD**.

After confirming key custody, a **template** connection (substitute your own independently verified values) is:

```bash
chmod 600 "$HOME/APPROVED_PRIVATE_KEY"
ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -i "$HOME/APPROVED_PRIVATE_KEY" ubuntu@PRIVATE_VM_IPV4
```

Run this **only in Cloud Shell PNA**, not against the VM's public IPv4. `StrictHostKeyChecking=yes` requires the correct fingerprint to be present in trusted `known_hosts` already. A host-key mismatch is **HOLD**, not permission to bypass verification. From the VM, `hostname -s` and `printf '%s\n' "$SSH_CONNECTION"` can help check private-peer provenance **locally**; do not publish their raw values.

## 3. Authorized OCI security-list setup (planned procedure, not a current apply)

OCI subnet security lists and VNIC NSGs are **additive**: any attached allow rule may expose a port. Removing an allow from just one list is insufficient if another list or NSG still permits it. Prefer an isolated subnet/policy boundary rather than editing a shared default.

1. In OCI Console open **Networking → Virtual Cloud Networks → selected VCN → Security Lists**. Create/review a **dedicated security list for the intended subnet**, without altering the shared VCN default security list. For an existing subnet, inspect the current rules and duplicate only approved ones; do not blindly copy all defaults.
2. The approved intended **ingress** for this architecture is: **TCP22 from exactly the reviewed private management/subnet CIDR**, **no public TCP80**, and **public TCP443 only as HTTPS transport** (for example `0.0.0.0/0` TCP443) *if the later host Cloudflare-only enforcement/packet-path gates are explicitly satisfied*. Preserve required ICMP/MTU rules and independently approved egress. Do not silently add or remove IPv6 rules; validate actual IPv6 assignment and exposure. Never add broad SSH22 rules to any NSG.
3. Before attachment, independently compare the new list with the old one. Verify the only intentional SSH edit is its **source CIDR**; detect unexpected new protocols, destination port ranges, null TCP options (which may mean **all ports**), network list membership, changed egress or missing ICMP. Record an approved rollback that **does not normally re-open public SSH**.
4. With a **fresh successful private SSH witness** and explicit change authorization, open **VCN → Subnets → target subnet → Security Lists** (or the subnet's Edit/Resources view, depending on Console version). Attach **only** the reviewed dedicated list; remove the original shared default attachment **from this target subnet only**. Never delete/edit the shared default list for other subnets or modify the production/original VM. Review and retain any other approved list only if the full **additive union** remains compliant.
5. Immediately perform a **separate authenticated provider readback** from Cloud Shell's **OCI Service Network**: check actual attached VNICs, subnet security-list IDs and NSGs, private TCP22 source, absent public TCP22/80 and unexpected ports, unchanged egress/MTU, and retained intentional TCP443. Then switch to **PNA**, repeat authenticated SSH over the **private IPv4**, and verify expected hostname/peer. Record both witnesses privately.
6. Treat `PASS` only as **configured OCI ingress + authenticated private SSH**, not as a proof that Docker-published HTTPS cannot bypass Cloudflare. Preserve the historical origin gate result and require independently accepted host firewall/packet-path tests before live canary or production.

Oracle documentation: [creating security lists](https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/creating-securitylist.htm), [changing subnet security-list attachments](https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/change-use-securitylist.htm), and [additive security-list behavior](https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/securitylists.htm).

## 4. Safe operator checks and troubleshooting

| Observation | Next safe action |
| --- | --- |
| GitHub times out in Service Network | Switch **Cloud Shell** to Public Network for the clone; verify exact source SHA and clean checkout. Switch back to Service Network for OCI API reads. Do not alter VM ingress. |
| OCI API reads time out in PNA | Use OCI Service Network for provider GETs; PNA is intended for private SSH. Do not grant new permissions or widen network egress merely to silence an acceptance gate. |
| Private SSH times out | Check PNA definition/region/subnet, approved source CIDR, routes, every effective security-list/NSG rule, VM state, guest SSH/firewall and the intended **private** IPv4. Use read-only Console checks before any change. |
| SSH authenticates but host key/name differs | HOLD; independently confirm the pinned host key, actual instance ID, private peer and correct username before trusting the session. |
| You lose SSH after a policy change | **STOP** and use the preapproved console/serial access and rollback plan. Reattaching the old shared default list may **reopen public TCP22** and therefore needs a separate emergency risk decision, not an automated fallback. |
| IPv6 CLI outputs nothing | PENDING until independent provider assignment/route evidence; an explicit authenticated empty list and a missing/null prefix field are different observations. |
| OCI TCP443 is publicly allowed | It proves only OCI transport policy; confirm validated, fresh Cloudflare IPv4/IPv6 **host** `DOCKER-USER` filtering and independently witnessed external packet denial before activation. |

**Never** disable guest SSH to imitate an OCI rule, weaken the application firewall, run `iptables -F`, change other VCN users' default list, re-enable public SSH as a troubleshooting shortcut, repeat destructive recovery gates, expose private keys, or apply network changes without scoped approval.

## 5. Historical acceptance boundary (for new administrators)

The **disposable** Ubuntu 26.04 ARM64 test VM completed its narrowly authorized P8T network correction on 2026-11-13: dedicated subnet list as the sole attachment; public TCP22/80 absent from effective attached rules; private-subnet TCP22 and expected public TCP443 retained; original shared default list unchanged; no NSGs; private Cloud Shell SSH PASS and independent provider GET readback PASS. The original strict P8T OCI-only Cloudflare-source TCP443 result remains **BLOCKED/2**, not retroactively PASS.

On 2026-11-17, independently pinned **P8V read-only** provider acceptance reported **16 PASS / 12 PENDING / 0 BLOCKED** for the reviewed current network. Both independently signed VNIC/subnet IPv6 object listings were explicitly empty, while null/missing IPv6 prefix fields remained PENDING; the inspected route table had no IPv6 destination routes. The stopped-host checks preserved immutable rc.12/recovery/storage continuity and passed 52 bounded source tests; its Cloudflare last-known-good policy was **stale** and its stopped Docker bridge was not instantiated. See draft [P8V grouped evidence PR #421](https://github.com/killer23d/VaultWarden-OCI/pull/421) for the current handoff. No rc.13 installation, live canary, external packet-path proof, DNS/Worker/backup changes, or production GO resulted.

**Operational outcome:** the private SSH/network procedure is accepted **for the disposable test target**. New administrators must independently repeat appropriate setup/readback for any **new** target, not replay the old one-shot on this VM. Production remains **HOLD** until the separately authorized canary and packet-path gates complete.
