# IQ4_XS rollout — per-host quant under a single alias

The 35B-A3B chat model is served under one routing alias (`qwen`, plus
`35b`, `35b@180k`, `Q4`) at `-c 180000` total context across the cluster.
Different hosts run different quants:

| Host class                  | Default quant | Why                                   |
| --------------------------- | ------------- | ------------------------------------- |
| macOS leader (Metal)        | `UD-Q4_K_XL`  | Metal handles the heavier quant cleanly |
| Linux workstation (CUDA)    | `UD-IQ4_XS`   | Smaller weights + more KV headroom    |
| macOS follower / CPU-MoE    | `UD-IQ4_XS`   | Cheaper per slot under partial offload |

Slopgate's per-peer `quant` field carries the label so the dashboard shows
which peer runs which; `canonical_model` stays family-level
(`unsloth/qwen3.6:35b-a3b@180k`) so the divergence check does not flag the
split as drift. Routing is by alias, balancer picks per request, session
affinity (`x-session-affinity` header) keeps multi-turn conversations on the
peer that already has the KV cache.

## Order of operations

The slopgate binary needs the new `--quant` flag before any agent restarts,
so build slopgate everywhere first.

1. **Build slopgate** on every host that runs the balancer or an agent:

   ```sh
   cd ~/code/sloppy/slopgate && git pull && cd go && go build ./cmd/slopgate
   ```

2. **Pull this repo** on every host:

   ```sh
   cd ~/infra/slopcode-infra && git pull
   ```

3. **Update env files** on each host. The new and changed keys in
   `~/.config/slopgate/leader.env` or `~/.config/slopgate/follower.env`:

   ```sh
   SLOPGATE_LOCAL_MAX_CONTEXT=180000          # was 262144
   SLOPGATE_LOCAL_CANONICAL_MODEL=unsloth/qwen3.6:35b-a3b@180k
   SLOPGATE_LOCAL_MODEL_ALIASES=35b,35b@180k,Q4
   SLOPGATE_LOCAL_QUANT=UD-Q4_K_XL            # set UD-IQ4_XS on hosts running that quant
   ```

   Companion 27B/122B agents on the leader pick up the new defaults
   automatically.

4. **Fetch the IQ4_XS weights** on every host that should serve that quant:

   ```sh
   ~/infra/slopcode-infra/scripts/fetch_iq4_xs.sh
   ```

   The script picks a sensible target by default (a dedicated storage mount
   when present, otherwise the standard llama.cpp cache root). Override with
   `IQ4_XS_TARGET=/path`. The XL weights stay where they are.

5. **Re-install services** so the new flags land in the unit / plist files:

   ```sh
   bash ~/infra/slopcode-infra/scripts/install_slopgate_leader.sh   # leader
   bash ~/infra/slopcode-infra/scripts/install_slopgate_follower.sh # followers
   ```

   The installers write the units and restart the services.

6. **Verify** on the leader:

   ```sh
   curl -fsS http://127.0.0.1:8085/api/v1/agents \
     | jq '.[] | {agent_name, model_alias, canonical_model, quant, max_context}'
   curl -fsS 'http://127.0.0.1:8085/api/v1/explain?model=qwen&prompt_tokens=120&output_tokens=60'
   ```

   Both quants should appear under `model_alias: "qwen"` with distinct
   `quant` values and `max_context: 180000`. The dashboard at
   `http://<leader>:8085/` should not show a config-mismatch badge.

## Rollback

Revert the env files to the prior `q4kxl@256k` canonical + 262144 context,
re-run the installers. The slopgate binary remains backwards compatible:
the `--quant` flag is optional and the new `quant` field on StatusUpdate is
`omitempty`.
