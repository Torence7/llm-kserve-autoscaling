#!/usr/bin/env bash
set -euo pipefail
cat <<'EOF' > /tmp/iris-input.json
{"instances":[[6.8,2.8,4.8,1.4],[6.0,3.4,4.5,1.6]]}
EOF

curl -s -H "Content-Type: application/json" \
  http://localhost:8080/v1/models/sklearn-iris:predict \
  -d @/tmp/iris-input.json
echo