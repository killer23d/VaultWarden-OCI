# P8T security-list impact — 2026-11-05

Authoritative Cloud Shell P8T at pinned commit 17005ed37493e0c79fb93381f3e87279e4c15932 passed 39/39 focused tests and returned BLOCKED/2. At least one subnet security list attached to the disposable instance allows 0.0.0.0/0 TCP 80 and 443. VNIC identity and current Cloudflare dual-stack CIDRs passed; IPv6 listing and friendly display-name crosscheck were pending. This is an OCI allow-rule policy issue, not proof of a listening application.

Until exact offending list, all attached subnets, VNICs sharing the affected subnet, and VCN default-list status are reviewed, do not change shared rules or start product services. OCI subnet security lists and NSGs are additive. The next step is a single scoped read-only impact audit, then a separately authorized targeted OCI network correction. No app, original P8P/P8R marker, firewall, DNS, Worker, Box, or IAM mutation was performed. Production/live GO remains NO.
