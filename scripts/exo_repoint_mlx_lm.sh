#!/usr/bin/env bash
# Point a node's exo at the GLM-5.2 long-context fix.
#
# exo pins mlx-lm to rltakashige/mlx-lm (branch leo/deepseek-v4), whose
# glm_moe_dsa.py is a stub: it runs GLM-5.2 as plain DeepSeek-V3.2 with no GLM
# DSA indexer sharing. The sparse-attention indexer is then wrong past ~2K
# tokens and decode degrades to random tokens, so short prompts stay clean but
# long context (agentic coding) is gibberish. The fix is pcuenca's open PR
# ml-explore/mlx-lm#1410 (DSA cross-layer indexer sharing), ported onto the exo
# base in krystophny/mlx-lm @ glm-5.2-dsa-indexer.
#
# Run on every node. Recreating the GLM instance afterwards is enough to load
# it (runners re-import from disk); no exo restart or Local Network re-grant.
#
# Env:
#   EXO_DIR   exo clone (default ~/exo)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

EXO_DIR="${EXO_DIR:-${HOME}/code/exo}"
FORK_URL="https://github.com/krystophny/mlx-lm"
FORK_BRANCH="glm-5.2-dsa-indexer"
UV="${HOME}/.local/bin/uv"

[[ -d "${EXO_DIR}/.venv" ]] || die "exo venv not found at ${EXO_DIR}/.venv"

# Persist the pin (so a future uv sync keeps the fix), then install from the fork.
if grep -q 'rltakashige/mlx-lm' "${EXO_DIR}/pyproject.toml" 2>/dev/null; then
  sed -i.rlt.bak \
    "s#git = \"https://github.com/rltakashige/mlx-lm\", branch = \"leo/deepseek-v4\"#git = \"${FORK_URL}\", branch = \"${FORK_BRANCH}\"#" \
    "${EXO_DIR}/pyproject.toml"
  echo "repointed pyproject -> ${FORK_URL}@${FORK_BRANCH}"
fi

( cd "${EXO_DIR}" && env -u VIRTUAL_ENV "${UV}" pip install --force-reinstall --no-deps \
    "mlx-lm @ git+${FORK_URL}@${FORK_BRANCH}" )

"${EXO_DIR}/.venv/bin/python" -c \
  "import mlx_lm.models.glm_moe_dsa as g; assert hasattr(g, 'GlmMoeDsaAttention'); print('GLM-5.2 DSA indexer fix active')"
