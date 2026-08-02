#!/usr/bin/env bash
set -euxo pipefail

sudo apt-get update
sudo apt-get install -y age apache2-utils 7zip python3-argon2 python3-bcrypt python3-yaml

curl -fsSL \
    https://github.com/mikefarah/yq/releases/download/v4.53.3/yq_linux_amd64 \
    -o /tmp/yq
echo 'fa52a4e758c63d38299163fbdd1edfb4c4963247918bf9c1c5d31d84789eded4  /tmp/yq' \
    | sha256sum --check --status
sudo install -m 755 /tmp/yq /usr/local/bin/yq

curl -fsSL \
    https://github.com/getsops/sops/releases/download/v3.13.2/sops-v3.13.2.linux.amd64 \
    -o /tmp/sops
echo '154dfe4cd70554bdd82b98e4cd4acf191d43d01ead6f00a73477aa44c4ac42ef  /tmp/sops' \
    | sha256sum --check --status
sudo install -m 755 /tmp/sops /usr/local/bin/sops

python3 .github/regular-health-transform.py

expected=$'systemd/vaultwarden-health.service\ntests/suites/operations/case-health-alerts.bash\nutilities/maintenance-health.sh'
actual="$(git diff --name-only | sort)"
if [[ "$actual" != "$expected" ]]; then
    printf 'Unexpected transformed file set:\n%s\n' "$actual" >&2
    exit 1
fi

grep -Fq '_health_readonly_lock_path()' utilities/maintenance-health.sh
! grep -Fq '_health_readonly_lock_target()' utilities/maintenance-health.sh
! grep -Fq 'VW_HEALTH_LOCK_TARGET' utilities/maintenance-health.sh
grep -Fq 'VW_HEALTH_LOCK_FILE' utilities/maintenance-health.sh
grep -Fq 'ln -T --' utilities/maintenance-health.sh
grep -Fq 'ln -P -T --' utilities/maintenance-health.sh

git diff --check
bash -n utilities/maintenance-health.sh
bash -n tests/suites/operations/case-health-alerts.bash
shellcheck -x --severity=warning \
    utilities/maintenance-health.sh \
    tests/suites/operations/case-health-alerts.bash

./tests/run-tests.sh operations

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git add -- \
    systemd/vaultwarden-health.service \
    tests/suites/operations/case-health-alerts.bash \
    utilities/maintenance-health.sh
git commit -m 'Restore regular health lock contract'
git push origin HEAD:refactor/single-lock-ownership
