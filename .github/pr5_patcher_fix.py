from pathlib import Path

path = Path('.github/pr5_recovery_patcher.py')
text = path.read_text()
old = '''    sops() {
      local args="$*"
      if [[ "$args" == *'required_key'* ]]; then
'''
new = '''    sops() {
      local joined="$*"
      if [[ "$joined" == *'required_key'* ]]; then
'''
if text.count(old) != 1:
    raise SystemExit('expected one SOPS mock header')
text = text.replace(old, new, 1)
old = '''      if [[ "$args" == *'optional_key'* ]]; then
'''
new = '''      if [[ "$joined" == *'optional_key'* ]]; then
'''
if text.count(old) != 1:
    raise SystemExit('expected one optional-key SOPS mock branch')
path.write_text(text.replace(old, new, 1))
