#!/usr/bin/env bash
# Idempotently ensure the GLM-5.2 instance is placed once both exo nodes are up.
# Safe to run repeatedly (LaunchAgent StartInterval): exits without touching a
# healthy cluster, places the instance only when 2 nodes are present and none
# exists yet. Run on the exo leader (faepmac1).
#
# Env:
#   EXO_API        exo API base (default http://127.0.0.1:52415)
#   GLM_MODEL_ID   model id (default mlx-community/GLM-5.2-mxfp4)
set -euo pipefail

API="${EXO_API:-http://127.0.0.1:52415}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

state="$(curl -s -m6 "${API}/state" 2>/dev/null)" || exit 0
[ -n "${state}" ] || exit 0

read -r nodes instances <<<"$(printf '%s' "${state}" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print(len(d.get("topology", {}).get("nodes", [])), len(d.get("instances", {})))
' 2>/dev/null || echo "0 0")"

# Wait for both nodes to discover each other; do nothing while alone.
[ "${nodes:-0}" -ge 2 ] || { echo "exo-glm autoload: ${nodes} node(s), waiting"; exit 0; }
# Leave a healthy instance alone.
[ "${instances:-0}" -ge 1 ] && { echo "exo-glm autoload: instance already up"; exit 0; }

echo "exo-glm autoload: 2 nodes, no instance -> placing GLM"
exec "${SCRIPT_DIR}/exo_glm_instance.sh"
