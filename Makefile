$(python3 -c "
import base64
with open('/tmp/vw/Makefile.final','rb') as f:
    print(base64.b64encode(f.read()).decode())
")