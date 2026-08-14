from pathlib import Path

p = Path('setup.sh')
text = p.read_text()
old = '    if [[ "$AUTO_MODE" != "true" ]] && [[ -t 0 ]]; then\n'
new = ('    local _crowdsec_setup_cmd="sudo ./utilities/setup-crowdsec.sh"\n'
       '    [[ "$USE_LATEST" == "true" ]] && _crowdsec_setup_cmd+=" --use-latest"\n\n'
       '    if [[ "$AUTO_MODE" != "true" ]] && [[ -t 0 ]]; then\n')
if text.count(old) != 1:
    raise SystemExit(f'expected one CrowdSec prompt block, found {text.count(old)}')
text = text.replace(old, new, 1)
old_cmd = '        log_info "  sudo ./utilities/setup-crowdsec.sh"'
if text.count(old_cmd) != 2:
    raise SystemExit(f'expected two CrowdSec command lines, found {text.count(old_cmd)}')
text = text.replace(old_cmd, '        log_info "  ${_crowdsec_setup_cmd}"')
p.write_text(text)
print('Carried --use-latest into CrowdSec continuation guidance.')
