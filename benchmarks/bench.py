#!/usr/bin/env python3
"""Cross-engine single-stream benchmark for OpenAI-compatible servers.

Measures TTFT, prefill tok/s, and decode tok/s on a representative prompt.
Used to compare MLX (mlx-lm / vMLX / Rapid-MLX) and GGUF (llama.cpp) backends
serving the same model class on the exclusive-big-model Mac.

Method: one warmup run (warms MLX kernel compilation for this prompt-length
bucket), then a measured run with a DIFFERENT prompt of the same length so the
prompt cache misses and prefill is real, not cached. Token counts come from the
server's streamed usage block.

Usage:
    bench.py BASE_URL MODEL [WORDS] [MAX_TOKENS] [LABEL]

Append a row to results.tsv when LABEL is given.
"""
import sys, os, time, json, urllib.request

BASE = sys.argv[1].rstrip("/")
MODEL = sys.argv[2]
WORDS = int(sys.argv[3]) if len(sys.argv) > 3 else 3000
MAX_TOKENS = int(sys.argv[4]) if len(sys.argv) > 4 else 256
LABEL = sys.argv[5] if len(sys.argv) > 5 else ""

# Two distinct filler texts: same approximate length (warms the same kernel
# shape) but no shared prefix (so the measured run's prompt cache misses).
WARM = "alpha beta gamma delta epsilon zeta eta theta iota kappa. " * (WORDS // 10)
MEAS = "The quick brown fox jumps over the lazy dog near. " * (WORDS // 9)


def run(text):
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": f"Read:\n{text}\nWrite a long analysis."}],
        "max_tokens": MAX_TOKENS, "temperature": 0.0, "stream": True,
        "stream_options": {"include_usage": True},
    }).encode()
    req = urllib.request.Request(BASE + "/v1/chat/completions", data=body,
                                 headers={"content-type": "application/json"})
    t0 = time.time()
    ttft = None
    seen = 0
    prompt_tok = comp_tok = 0
    for line in urllib.request.urlopen(req, timeout=1800):
        s = line.decode(errors="ignore").strip()
        if not s.startswith("data:"):
            continue
        d = s[5:].strip()
        if d == "[DONE]":
            break
        try:
            o = json.loads(d)
        except Exception:
            continue
        u = o.get("usage")
        if u:
            prompt_tok = u.get("prompt_tokens", prompt_tok)
            comp_tok = u.get("completion_tokens", comp_tok)
        ch = (o.get("choices") or [{}])[0]
        piece = ch.get("delta", {}).get("content") or ch.get("text")
        if piece:
            if ttft is None:
                ttft = time.time() - t0
            seen += 1
    total = time.time() - t0
    return ttft, seen, comp_tok or seen, prompt_tok, total


print(f"[{LABEL or MODEL}] warmup...", flush=True)
run(WARM)
print("measured (distinct prompt, cold cache)...", flush=True)
ttft, seen, comp, prompt_tok, total = run(MEAS)
gen_time = total - (ttft or 0)
decode = (comp - 1) / gen_time if (ttft and comp > 1 and gen_time > 0) else 0.0
prefill = prompt_tok / ttft if (ttft and prompt_tok) else 0.0
print(f"\nRESULT [{LABEL}]")
print(f"  prompt_tokens : {prompt_tok}")
print(f"  TTFT          : {ttft*1000:.0f} ms")
print(f"  prefill       : {prefill:.0f} tok/s")
print(f"  decode        : {decode:.1f} tok/s")
print(f"  output_tokens : {comp}  total {total:.1f}s")

if LABEL:
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results.tsv")
    new = not os.path.exists(out)
    with open(out, "a") as f:
        if new:
            f.write("label\tmodel\tprompt_tokens\tttft_ms\tprefill_tps\tdecode_tps\n")
        f.write(f"{LABEL}\t{MODEL}\t{prompt_tok}\t{ttft*1000:.0f}\t{prefill:.0f}\t{decode:.1f}\n")
    print(f"  appended -> {out}")
