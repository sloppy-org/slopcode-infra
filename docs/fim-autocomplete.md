# FIM autocomplete endpoint

Inline completion (fill-in-the-middle) runs on its own low-latency endpoint,
separate from the chat/agent model. It needs a Coder model: only the
Qwen-Coder line ships the infill tokens (`<|fim_prefix|>`, `<|fim_suffix|>`,
`<|fim_middle|>`). General chat models (Qwen3.5/3.6, Gemma) carry none, so the
chat server alone cannot drive real autocomplete.

## Who serves what

- **faepmac1** (M3 Ultra, 256 GB) serves both roles at once: chat as `qwen`,
  plus a dedicated `fim` endpoint. The `fim` / `qwenfim` alias resolves to
  `qwen3-coder-next` (80B-A3B Q4, the `qwen3-coder-next-q4` spec in
  `scripts/llamacpp_models.py`). Big unified memory holds the 80B FIM model and
  the chat model together.
- **A 32 GB host** (laptop, 16 GB-class GPU box) cannot fit the 80B beside a
  chat model. Use a small dense Coder for FIM: Qwen2.5-Coder 7B Q4_K_M
  (~4.7 GB), or 1.5B/3B when memory is tight. It is not in the blessed
  registry; fetch it directly:

  ```
  hf download Qwen/Qwen2.5-Coder-7B-Instruct-GGUF --include '*Q4_K_M*.gguf'
  ```

## 32 GB side-by-side

One 32 GB box, two endpoints:

- chat/agent: Qwen3.6 35B-A3B on `:8080`, the `qwen` profile from
  `serve_switch.sh`. Serve IQ4_XS (`qwen3.6-35b-a3b-iq4_xs`) to keep headroom.
- FIM: Qwen2.5-Coder 7B on a second port, e.g. `:8084`.

Budget: 35B-A3B IQ4_XS (~18 GB) plus Coder 7B Q4 (~4.7 GB) plus both KV caches
and buffers sits near the 32 GB edge. The 35B-A3B is hybrid-attention, so its KV
is small; the FIM window is tiny. IQ4 on the chat model buys the room. Hold chat
context at 16-32K.

FIM fires on every keystroke, so the small slot wants a small model. Avoid a
large dense Coder such as Codestral 22B on a laptop: every token activates all
weights, which is too slow for inline completion. Prefer a small dense Coder or
a low-active-param MoE.

## Client wiring

Point the editor at two endpoints: chat at the chat server, autocomplete at the
FIM server. Leave the autocomplete model unset so the FIM endpoint serves
whatever it loaded, or name the alias (`fim` on faepmac1).
