# OCI Cloud Shell access and private-only SSH

This is an **administrator setup and day-2 access guide for OCI deployments** of VaultWarden-OCI, not a script for reapplying past security changes. The appliance is also supported outside OCI. Follow [Install](INSTALL.md), [Security](SECURITY.md), and [Operations](OPERATIONS.md) for the product. For the original accepted disposable-subnet remediation, see [historical network/SSH acceptance](HISTORICAL-INFRASTRUCTURE-ACCEPTANCE.md).

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

## 2. Build a new OCI site before appliance setup

Use this section for a **new** site and then continue to the private-SSH
preflight and [Install](INSTALL.md). These are OCI Console preparation
steps, **not** an automated migration of this project's non-production
acceptance VCN/VM. The host can have a public IPv4 for Cloudflare HTTPS
while all administrator SSH remains reachable **only by private IPv4**.

| Resource | New-site choice | Do not do |
| --- | --- | --- |
| Compartment, region, VCN | Choose an authorized compartment/region and non-overlapping private CIDR; record the VCN and subnet identities privately | Copy a past acceptance target's OCIDs or route table without review |
| Subnet and routing | Dedicated public IPv4 subnet for the HTTPS origin, with its own reviewed route table and an enabled internet gateway; route `0.0.0.0/0` to that gateway when public IPv4 egress/ingress is required | Assume a public IP or internet gateway alone enables correct routing |
| Ingress policy | A dedicated security list and, if needed, **explicitly reviewed** NSGs; confirm their additive union | Reuse a permissive shared default list, or assume an NSG can deny a security-list allow |
| Compute | Supported Ubuntu 24.04 or 26.04, `arm64` or `amd64`; one primary private IPv4 and optional public IPv4 for Cloudflare-proxied HTTPS | Expose guest TCP22 publicly merely because the subnet is public |
| Persistent data | Separate attached OCI Block Volume/dedicated filesystem; verify the actual guest device before any format | Use boot/root volume as application state or copy old recovered data into a fresh-site test |
| Management and recovery | Cloud Shell Private Network Access, a trusted guest SSH key/host key, and separately verified serial/Console fallback | Remove the only working SSH path or depend on a shared-default-list rollback that reopens TCP22 |

1. **VCN and subnet.** In OCI Console select the intended compartment, then
   **Networking → Virtual Cloud Networks**. Either create a VCN manually
   (VCN, internet gateway, route table and subnet) or use the **VCN with
   Internet Connectivity** wizard, then *review and replace the wizard's
   default ingress policy before relying on it*. Create a dedicated subnet
   and route table for this appliance. A public subnet plus internet
   gateway, route, actual public IP and effective security allows are all
   required for public HTTPS transport. Do not provision unnecessary
   public IPv6; where IPv4-only is intended, verify assignments and routes
   separately rather than inferring them from absent CLI output.
2. **Ingress rules.** Before installing/starting Vaultwarden, create the
   dedicated list under **VCN → Security Lists**, assign it to the
   intended subnet, and enumerate every attached VNIC's NSGs. Apply only
   approved rules, with their *real* destination-port ranges:

   | Direction | Protocol / destination | Source / scope |
   | --- | --- | --- |
   | Ingress | TCP22 | Only the independently confirmed **private** Cloud Shell PNA/management source CIDR that can reach the VM's private IPv4 |
   | Ingress | TCP80 | **No public allow** |
   | Ingress | TCP443 | Public IPv4 transport only after the host fail-closed Cloudflare-origin filter is verified; a network allow alone is never a GO |
   | Ingress | ICMP | Retain required Path MTU/error signaling under the reviewed provider policy |
   | Ingress | IPv6 | No public SSH/HTTP or unintended direct origin; verify real subnet/VNIC IPv6 allocation even for an IPv4-only site |
   | Egress | Required outbound destinations | Deliberately permit tested Ubuntu packages, GitHub/source retrieval, Cloudflare/DNS, SMTP and the selected backup service; review least-privilege policy |

   OCI security lists and NSGs are **additive**, not deny-list overrides.
   Keep Docker IPv4 **and** IPv6 origin filtering in the appliance even if
   OCI assigns no public IPv6. Do not maintain a static Cloudflare CIDR
   list in OCI: the appliance's `DOCKER-USER` policy owns the validated
   Cloudflare ranges. When starting from an existing subnet, follow the
   change-controlled procedure below instead of replacing attachments
   before private SSH and rollback are proven.
3. **Compute and dedicated data disk.** Use **Compute → Instances →
   Create instance** with the supported Ubuntu image/architecture and
   the intended subnet. Associate a public IPv4 only if this VM is the
   actual Cloudflare HTTPS origin. Provision a **new separate** OCI Block
   Volume and attach it under the instance's **Attached block volumes**.
   Paravirtualized attachment is normally visible to the guest after
   attachment; an iSCSI attachment has additional connect steps. On Ubuntu,
   inspect `lsblk`, `findmnt` and the device's stable identifiers,
   then let the supported appliance installer handle the separately
   consented filesystem provisioning. Do **not** format or mount the boot
   disk as application storage; a recovered test disk is not blank.
4. **Create the private administrator path.** In Cloud Shell select the
   correct Console region, open **Network → Private Network Definition →
   Create**, and select the intended VCN and reachable management subnet.
   Make the definition active. Confirm available addresses and the
   permitted **private source CIDR** that the VM will actually see; if
   your PNA endpoint is on a different subnet, do not assume the VM
   subnet's own CIDR is the correct SSH source. Required IAM permissions
   must be approved by the tenancy administrator; never broaden IAM to
   make a test go green. Verify the SSH host key independently and
   authenticate to the **private IPv4** before considering the ingress
   rule review complete. Prove Console/serial recovery access too.
5. **Cloudflare hostname and Worker route ownership.** Follow
   [Install](INSTALL.md#2-prepare-cloudflare-dns-and-tokens) for exactly
   one **existing Proxied IPv4 A record** for the Vaultwarden hostname
   and no explicit AAAA. Inspect wildcard DNS, Worker Routes and Custom
   Domains for *effective* matching, not simple presence: a **Worker
   Route** runs before an external origin; a **Worker Custom Domain**
   makes a Worker the origin and may need an explicit onward
   `fetch()` to reach Caddy. For this appliance, prove the intended
   Cloudflare → Caddy path, origin-only filtering and the CrowdSec
   Fail Open requirement; do not assume a Worker Custom Domain pointing
   to some other test service is compatible with the appliance's
   one-A-record DNS updater. Avoid copying reference/test recovery
   credentials or Box destinations to a new site.

**Verify before first start.** From Cloud Shell **OCI Service Network**,
review provider VNIC/subnet/NSG/security-list union and effective public
TCP22/80/443 plus IPv6 exposure. Switch to **PNA**, prove SSH via the
*private IPv4* and a trusted host-key fingerprint. Use **Public Network**
only for approved GitHub/source retrieval; it does not make public SSH
safe. On the guest, verify the separate disk and supported OS, then
continue to [Install](INSTALL.md). After setup and before exposing a
published service, prove current dual-stack host-origin policy and
independent direct-origin packet denial. If any check is unknown,
**HOLD** and use [Troubleshooting](TROUBLESHOOTING.md), not firewall
flushes or temporary public SSH.

Oracle references: [creating a VCN](https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/create_vcn.htm),
[creating an instance](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/launchinginstance.htm),
[attaching a block volume](https://docs.oracle.com/en-us/iaas/Content/Block/Tasks/attach-compute-volume-attachment.htm),
[security-list behavior](https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/securitylists.htm),
and [Cloud Shell networking](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/cloudshellintro_topic-Cloud_Shell_Networking.htm).

## 3. Preflight before closing public SSH

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

## 4. Authorized OCI security-list setup (planned procedure, not a current apply)

OCI subnet security lists and VNIC NSGs are **additive**: any attached allow rule may expose a port. Removing an allow from just one list is insufficient if another list or NSG still permits it. Prefer an isolated subnet/policy boundary rather than editing a shared default.

1. In OCI Console open **Networking → Virtual Cloud Networks → selected VCN → Security Lists**. Create/review a **dedicated security list for the intended subnet**, without altering the shared VCN default security list. For an existing subnet, inspect the current rules and duplicate only approved ones; do not blindly copy all defaults.
2. The approved intended **ingress** for this architecture is: **TCP22 from exactly the reviewed private management/subnet CIDR**, **no public TCP80**, and **public TCP443 only as HTTPS transport** (for example `0.0.0.0/0` TCP443) *if the later host Cloudflare-only enforcement/packet-path gates are explicitly satisfied*. Preserve required ICMP/MTU rules and independently approved egress. Do not silently add or remove IPv6 rules; validate actual IPv6 assignment and exposure. Never add broad SSH22 rules to any NSG.
3. Before attachment, independently compare the new list with the old one. Verify the only intentional SSH edit is its **source CIDR**; detect unexpected new protocols, destination port ranges, null TCP options (which may mean **all ports**), network list membership, changed egress or missing ICMP. Record an approved rollback that **does not normally re-open public SSH**.
4. With a **fresh successful private SSH witness** and explicit change authorization, open **VCN → Subnets → target subnet → Security Lists** (or the subnet's Edit/Resources view, depending on Console version). Attach **only** the reviewed dedicated list; remove the original shared default attachment **from this target subnet only**. Never delete/edit the shared default list for other subnets or modify an unrelated or recovered reference VM. Review and retain any other approved list only if the full **additive union** remains compliant.
5. Immediately perform a **separate authenticated provider readback** from Cloud Shell's **OCI Service Network**: check actual attached VNICs, subnet security-list IDs and NSGs, private TCP22 source, absent public TCP22/80 and unexpected ports, unchanged egress/MTU, and retained intentional TCP443. Then switch to **PNA**, repeat authenticated SSH over the **private IPv4**, and verify expected hostname/peer. Record both witnesses privately.
6. Treat `PASS` only as **configured OCI ingress + authenticated private SSH**, not as a proof that Docker-published HTTPS cannot bypass Cloudflare. Preserve the historical origin gate result and require independently accepted host firewall/packet-path tests before live canary or production.

Oracle documentation: [creating security lists](https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/creating-securitylist.htm), [changing subnet security-list attachments](https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/change-use-securitylist.htm), and [additive security-list behavior](https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/securitylists.htm).

## 5. Safe operator checks and troubleshooting

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

## 6. Historical evidence versus new-site setup

The disposable OCI network/SSH and Cloudflare read-only acceptance
outcomes are consolidated in [Historical infrastructure acceptance](HISTORICAL-INFRASTRUCTURE-ACCEPTANCE.md)
with their original pre-consolidation Git sources. The historical
strict OCI-only public HTTPS443 restriction and the later layered-origin
transport policy were different contracts; neither automatically proves
live product-origin packet denial.

New administrators must follow sections 1–5 for their **own** site:
verify VCN/subnet attachment, effective security lists/NSGs, private
SSH and console fallback, and then the **product-owned** fail-closed
Docker/Caddy origin policy. Do not replay old pinned OCI-host scripts
or treat the old recovered-data lab as a blank acceptance host.
