#!/usr/bin/env bash
# Load the GLM-5.2 mixed 3/6-bit model as a 2-node tensor-parallel instance on
# a running local exo (github.com/exo-explore/exo). Idempotent: clears any
# existing instance for the model, then creates a fresh Tensor / MLX-Ring
# placement and waits for the runners to load. Run on the exo leader after exo
# is up on both nodes.
#
# Prereqs (host-local, not in this repo):
#   - exo running on both Macs through the LaunchAgent using the Homebrew
#     python3.13 binary with the persisted macOS Local Network grant; API on
#     :52415.
#   - The model present on every node, symlinked into exo's expected path:
#       ~/.exo/models/pipenetwork--GLM-5.2-MLX-mixed-3_6bit -> <model dir>
#     exo resolves models as EXO_DEFAULT_MODELS_DIR/<id with "/" -> "--">, so a
#     flat pipenetwork/GLM-5.2-MLX-mixed-3_6bit download must be linked there.
#
# Env:
#   EXO_API        exo API base (default http://127.0.0.1:52415)
#   GLM_MODEL_ID   model id (default pipenetwork/GLM-5.2-MLX-mixed-3_6bit)
#   GLM_SHARDING   Tensor (default) or Pipeline
set -euo pipefail

API="${EXO_API:-http://127.0.0.1:52415}"
MODEL="${GLM_MODEL_ID:-pipenetwork/GLM-5.2-MLX-mixed-3_6bit}"
SHARDING="${GLM_SHARDING:-Tensor}"

command -v curl >/dev/null || { echo "curl required" >&2; exit 1; }

echo "exo: ${API}  model: ${MODEL}  sharding: ${SHARDING}"

nodes=$(curl -s -m6 "${API}/state" | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("topology",{}).get("nodes",[])))')
echo "cluster nodes: ${nodes}"
[ "${nodes}" -ge 2 ] || { echo "need >=2 nodes for GLM tensor-parallel" >&2; exit 1; }

# clear any existing instances, register the model
curl -s -m6 "${API}/state" | python3 -c 'import sys,json;[print(i) for i in json.load(sys.stdin).get("instances",{})]' \
  | while read -r id; do [ -n "${id}" ] && curl -s -X DELETE "${API}/instance/${id}" >/dev/null; done
curl -s -m10 -X POST "${API}/models/add" -H 'content-type: application/json' -d "{\"model_id\":\"${MODEL}\"}" >/dev/null

# pick the Tensor / MLX-Ring placement and create it. Pipeline and JACCL/RDMA
# are not the default path for GLM-5.2 on the current 2x256 GB cluster.
PREV=$(curl -s -m20 "${API}/instance/previews?model_id=${MODEL}")
echo "${PREV}" | python3 -c "
import sys,json
pv=json.load(sys.stdin); pv=pv.get('previews',pv) if isinstance(pv,dict) else pv
pick=next((p for p in pv if p.get('sharding')=='${SHARDING}' and p.get('instance_meta')=='MlxRing' and not p.get('error')), None)
assert pick, 'no usable ${SHARDING}/MlxRing placement (check memory/nodes)'
json.dump({'instance':pick['instance']}, open('/tmp/exo_glm_inst.json','w'))
print('placement ok; mem/node:', list((pick.get('memory_delta_by_node') or {}).values()))
"
curl -s -m30 -X POST "${API}/instance" -H 'content-type: application/json' -d @/tmp/exo_glm_inst.json >/dev/null
echo "instance created; waiting for runners to load (first request loads ~half the weights per node)..."

# wait for ready (await caps at 300s)
curl -s -m310 "${API}/instance/await?model_id=${MODEL}&timeout_seconds=300" 2>/dev/null | grep -oE '"type":"[a-z_]+"' | tail -1
echo "done. Test: curl ${API}/v1/chat/completions -d '{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'"
