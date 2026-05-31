#!/usr/bin/env python3
"""Manage the blessed llama.cpp models for this repo.

Default offline model:
    qwen3.6-35b-a3b-mtp-q4 -> unsloth/Qwen3.6-35B-A3B-MTP-GGUF (UD-Q4_K_XL)

The MTP variant ships the multi-token prediction head Qwen3.6 was trained
with; llama.cpp >= b9180 can drive it via `--spec-type draft-mtp` for a
1.4-2.2x decode speedup at ~1 GB extra resident memory. MTP is the right
default on hosts with the headroom (the Mac Studio cluster leader, MTP-
capable followers). Hosts where the MTP head would eat the VRAM safety
margin (Linux/CUDA tight-VRAM followers, Windows-arc, the USB bundle)
should stay on the non-MTP `qwen3.6-35b-a3b-q4` / `qwen3.6-35b-a3b-iq4_xs`
aliases.

Optional aliases live in OPTIONAL_SPECS below. They are never downloaded
automatically; `prefetch` only touches the default.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

def cache_root() -> Path:
    explicit = os.environ.get("LLAMACPP_CACHE_ROOT", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Caches" / "llama.cpp"
    return Path.home() / ".cache" / "llama.cpp"

CACHE_ROOT = cache_root()

@dataclass(frozen=True)
class ModelSpec:
    alias: str
    repo_id: str
    include: tuple[str, ...]
    mmproj_include: tuple[str, ...] = ()
    default: bool = False

    @property
    def cache_dir(self) -> Path:
        return CACHE_ROOT / self.repo_id.replace("/", "_")

DEFAULT_SPEC = ModelSpec(
    alias="qwen3.6-35b-a3b-mtp-q4",
    repo_id="unsloth/Qwen3.6-35B-A3B-MTP-GGUF",
    include=("*UD-Q4_K_XL*.gguf",),
    mmproj_include=("mmproj-BF16.gguf", "mmproj-F16.gguf"),
    default=True,
)

OPTIONAL_SPECS: tuple[ModelSpec, ...] = (
    ModelSpec(
        alias="qwen3.6-35b-a3b-mtp-iq4_xs",
        repo_id="unsloth/Qwen3.6-35B-A3B-MTP-GGUF",
        include=("*UD-IQ4_XS*.gguf",),
        mmproj_include=("mmproj-BF16.gguf", "mmproj-F16.gguf"),
    ),
    ModelSpec(
        alias="qwen3.6-35b-a3b-q4",
        repo_id="unsloth/Qwen3.6-35B-A3B-GGUF",
        include=("*UD-Q4_K_XL*.gguf",),
        mmproj_include=("mmproj-BF16.gguf", "mmproj-F16.gguf"),
    ),
    ModelSpec(
        alias="qwen3.6-35b-a3b-iq4_xs",
        repo_id="unsloth/Qwen3.6-35B-A3B-GGUF",
        include=("*UD-IQ4_XS*.gguf",),
        mmproj_include=("mmproj-BF16.gguf", "mmproj-F16.gguf"),
    ),
    ModelSpec(
        alias="qwen3.6-27b-mtp-q4",
        repo_id="unsloth/Qwen3.6-27B-MTP-GGUF",
        include=("*UD-Q4_K_XL*.gguf", "*Q4_K_M*.gguf"),
        mmproj_include=("mmproj-BF16.gguf", "mmproj-F16.gguf"),
    ),
    ModelSpec(
        alias="qwen3.6-27b-q4",
        repo_id="bartowski/Qwen_Qwen3.6-27B-GGUF",
        include=("*Q4_K_M*.gguf",),
        mmproj_include=("mmproj-*bf16.gguf", "mmproj-*BF16.gguf", "mmproj-*f16.gguf", "mmproj-*F16.gguf"),
    ),
    ModelSpec(
        alias="qwen3.5-122b-a10b-mtp-ud-q4",
        repo_id="unsloth/Qwen3.5-122B-A10B-MTP-GGUF",
        include=("UD-Q4_K_XL/*.gguf", "*UD-Q4_K_XL*.gguf"),
        mmproj_include=("mmproj-BF16.gguf", "mmproj-F16.gguf"),
    ),
    ModelSpec(
        alias="qwen3-coder-next-q4",
        repo_id="Qwen/Qwen3-Coder-Next-GGUF",
        include=("Qwen3-Coder-Next-Q4_K_M/*.gguf", "*Qwen3-Coder-Next-Q4_K_M*.gguf"),
    ),
    ModelSpec(
        alias="qwen3-coder-next-q5",
        repo_id="Qwen/Qwen3-Coder-Next-GGUF",
        include=("Qwen3-Coder-Next-Q5_K_M/*.gguf", "*Qwen3-Coder-Next-Q5_K_M*.gguf"),
    ),
    # Small dense Coder models for the FIM/autocomplete endpoint on memory-tight
    # hosts (the 32 GB laptop side-by-side). The Coder line ships the infill
    # tokens (<|fim_prefix|> etc.) the chat models lack. 3B Q4_K_M (~2 GB
    # wired) is the default FIM model beside a 35B-A3B chat model; 7B/1.5B
    # trade quality for memory. See docs/fim-autocomplete.md.
    ModelSpec(
        alias="qwen2.5-coder-3b-q4",
        repo_id="Qwen/Qwen2.5-Coder-3B-Instruct-GGUF",
        include=("*q4_k_m*.gguf", "*Q4_K_M*.gguf"),
    ),
    ModelSpec(
        alias="qwen2.5-coder-7b-q4",
        repo_id="Qwen/Qwen2.5-Coder-7B-Instruct-GGUF",
        include=("*q4_k_m*.gguf", "*Q4_K_M*.gguf"),
    ),
    ModelSpec(
        alias="qwen2.5-coder-1.5b-q4",
        repo_id="Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF",
        include=("*q4_k_m*.gguf", "*Q4_K_M*.gguf"),
    ),
    ModelSpec(
        alias="qwen3.6-35b-a3b-bartowski-q4",
        repo_id="bartowski/Qwen_Qwen3.6-35B-A3B-GGUF",
        include=("*Q4_K_M*.gguf",),
        mmproj_include=("mmproj-*f16.gguf", "mmproj-*F16.gguf"),
    ),
    ModelSpec("qwen3.6-35b-a3b-q8", "unsloth/Qwen3.6-35B-A3B-GGUF", ("*Q8_0*.gguf",)),
    ModelSpec("qwen3.5-35b-a3b-q4", "unsloth/Qwen3.5-35B-A3B-GGUF", ("*Q4_K_M*.gguf",)),
    ModelSpec("qwen3.5-9b-q4", "bartowski/Qwen_Qwen3.5-9B-GGUF", ("*Q4_K_M*.gguf",)),
    ModelSpec("qwen3.5-4b-q4", "bartowski/Qwen_Qwen3.5-4B-GGUF", ("*Q4_K_M*.gguf",)),
    ModelSpec("qwen3.5-2b-q4", "bartowski/Qwen_Qwen3.5-2B-GGUF", ("*Q4_K_M*.gguf",)),
    ModelSpec("qwen3.5-122b-a10b-q8", "lmstudio-community/Qwen3.5-122B-A10B-GGUF", ("*Q8_0*.gguf",)),
    ModelSpec(
        "qwen3.5-122b-a10b-ud-q4",
        "unsloth/Qwen3.5-122B-A10B-GGUF",
        ("UD-Q4_K_XL/*.gguf", "*UD-Q4_K_XL*.gguf"),
        mmproj_include=("mmproj-BF16.gguf", "mmproj-F16.gguf"),
    ),
    ModelSpec("minimax-m2.5-q4", "AesSedai/MiniMax-M2.5-GGUF", ("*Q4_K_M*.gguf",)),
    ModelSpec("minimax-m2.7-q4", "bartowski/MiniMaxAI_MiniMax-M2.7-GGUF", ("*Q4_K_M*.gguf",)),
    ModelSpec(
        "minimax-m2.7-ud-q4",
        "unsloth/MiniMax-M2.7-GGUF",
        ("UD-Q4_K_M/*.gguf", "*UD-Q4_K_M*.gguf"),
    ),
    ModelSpec(
        "step-3.5-flash-q4ks",
        "stepfun-ai/Step-3.5-Flash-GGUF-Q4_K_S",
        ("step3p5_flash_Q4_K_S-*.gguf", "*Q4_K_S*.gguf"),
    ),
    ModelSpec(
        "deepseek-v4-flash-q4kexp",
        "antirez/deepseek-v4-gguf",
        ("*Q4KExperts*chat-v2.gguf",),
    ),
    ModelSpec(
        "gemma-4-31b-it-q4",
        "unsloth/gemma-4-31B-it-GGUF",
        ("gemma-4-31B-it-Q4_K_M.gguf", "*Q4_K_M*.gguf"),
    ),
    ModelSpec(
        "gemma-4-26b-a4b-it-ud-q4",
        "unsloth/gemma-4-26B-A4B-it-GGUF",
        ("gemma-4-26B-A4B-it-UD-Q4_K_M.gguf", "*UD-Q4_K_M*.gguf"),
    ),
    ModelSpec(
        "mistral-medium-3.5-q4",
        "bartowski/mistralai_Mistral-Medium-3.5-128B-GGUF",
        ("*Q4_K_M*.gguf",),
    ),
    ModelSpec(
        "mistral-medium-3.5-ud-q4",
        "unsloth/Mistral-Medium-3.5-128B-GGUF",
        ("UD-Q4_K_XL/*.gguf", "*UD-Q4_K_XL*.gguf"),
    ),
    ModelSpec(
        "qwen3.5-122b-a10b-ud-q4",
        "unsloth/Qwen3.5-122B-A10B-GGUF",
        ("UD-Q4_K_XL/*.gguf", "*UD-Q4_K_XL*.gguf"),
    ),
    ModelSpec(
        "qwen3.5-397b-a17b-ud-q4",
        "unsloth/Qwen3.5-397B-A17B-GGUF",
        ("UD-Q4_K_M/*.gguf", "*UD-Q4_K_M*.gguf"),
    ),
    ModelSpec(
        "gpt-oss-120b-q4km",
        "bartowski/openai_gpt-oss-120b-GGUF",
        ("*Q4_K_M*.gguf",),
    ),
    ModelSpec("kimi-k2.6", "ubergarm/Kimi-K2.6-GGUF", ("*Q4_X*.gguf",)),
    ModelSpec("mimo-v2.5", "bartowski/MiMo-V2.5-GGUF", ("*Q4_K_M*.gguf",)),
    ModelSpec("mimo-v2.5-pro", "AesSedai/MiMo-V2.5-Pro-GGUF", ("*IQ3_S*.gguf",)),
    ModelSpec(
        "glm-4.7",
        "unsloth/GLM-4.7-GGUF",
        ("UD-Q2_K_XL/*.gguf", "*UD-Q2_K_XL*.gguf"),
    ),
    ModelSpec(
        "glm-4.7-flash",
        "unsloth/GLM-4.7-Flash-GGUF",
        ("*UD-Q4_K_XL*.gguf",),
    ),
    ModelSpec(
        "glm-5.1",
        "unsloth/GLM-5.1-GGUF",
        ("UD-Q3_K_XL/*.gguf", "*UD-Q3_K_XL*.gguf"),
    ),
    ModelSpec(
        "mistral-large-3-675b",
        "bartowski/mistralai_Mistral-Large-3-675B-Instruct-2512-GGUF",
        ("*Q4_K_M*.gguf",),
    ),
    ModelSpec(
        "qwen3-235b-a22b-2507",
        "bartowski/Qwen_Qwen3-235B-A22B-Instruct-2507-GGUF",
        ("*Q4_K_M*.gguf",),
    ),
    ModelSpec(
        "mistral-small-4-119b",
        "bartowski/mistralai_Mistral-Small-4-119B-2603-GGUF",
        ("*Q5_K_M*.gguf",),
    ),
    ModelSpec(
        "devstral-2-123b",
        "bartowski/mistralai_Devstral-2-123B-Instruct-2512-GGUF",
        ("*Q5_K_M*.gguf",),
    ),
    ModelSpec(
        "trinity-large-preview",
        "bartowski/arcee-ai_Trinity-Large-Preview-GGUF",
        ("*Q4_K_M*.gguf",),
    ),
    ModelSpec(
        "trinity-large-thinking",
        "bartowski/arcee-ai_Trinity-Large-Thinking-GGUF",
        ("*Q4_K_M*.gguf",),
    ),
    ModelSpec(
        "nemotron-120b-a12b",
        "unsloth/NVIDIA-Nemotron-3-Super-120B-A12B-GGUF",
        ("*Q4_K_M*.gguf",),
    ),
)

MODEL_SPECS: tuple[ModelSpec, ...] = (DEFAULT_SPEC, *OPTIONAL_SPECS)
MODEL_BY_ALIAS = {m.alias: m for m in MODEL_SPECS}

def find_cli() -> str:
    for candidate in ("hf", "huggingface-cli"):
        path = shutil.which(candidate)
        if path:
            return path
    raise RuntimeError('missing hf or huggingface-cli in PATH; install with: uv tool install "huggingface_hub[cli]"')


def positive_int_env(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    value = int(raw)
    if value < 1:
        raise ValueError(f"{name} must be >= 1, got {value}")
    return value

def matching_files(model: ModelSpec) -> list[Path]:
    return matching_paths(model, model.include)

def matching_mmproj_files(model: ModelSpec) -> list[Path]:
    return matching_paths(model, model.mmproj_include)

def matching_paths(model: ModelSpec, patterns: tuple[str, ...]) -> list[Path]:
    files: list[Path] = []
    if not patterns:
        return files
    if model.cache_dir.exists():
        for path in sorted(model.cache_dir.rglob("*.gguf")):
            rel = path.relative_to(model.cache_dir).as_posix()
            if any(fnmatch.fnmatch(rel, p) or fnmatch.fnmatch(path.name, p) for p in patterns):
                files.append(path)
    flat_prefix = model.repo_id.replace("/", "_") + "_"
    for path in sorted(CACHE_ROOT.glob(f"{flat_prefix}*.gguf")):
        if any(fnmatch.fnmatch(path.name, f"{flat_prefix}{p}") or fnmatch.fnmatch(path.name, p) for p in patterns):
            files.append(path)
    return files

def record(model: ModelSpec) -> dict:
    files = matching_files(model)
    mmproj_files = matching_mmproj_files(model)
    return {
        "alias": model.alias,
        "repo_id": model.repo_id,
        "default": model.default,
        "cache_dir": str(model.cache_dir),
        "present": bool(files),
        "files": [str(p) for p in files],
        "mmproj_present": bool(mmproj_files),
        "mmproj_files": [str(p) for p in mmproj_files],
        "size_bytes": sum(p.stat().st_size for p in (*files, *mmproj_files)),
        "primary_path": str(files[0]) if files else "",
        "mmproj_path": str(mmproj_files[0]) if mmproj_files else "",
    }

def cmd_inventory(args: argparse.Namespace) -> int:
    records = [record(m) for m in MODEL_SPECS]
    if args.json:
        print(json.dumps(records, indent=2))
        return 0
    for r in records:
        gib = r["size_bytes"] / (1024 ** 3)
        status = "present" if r["present"] else "missing"
        tag = " [default]" if r["default"] else ""
        print(f"{r['alias']}{tag}: {status} ({gib:.1f} GiB)")
        print(f"  repo: {r['repo_id']}")
        if r["primary_path"]:
            print(f"  path: {r['primary_path']}")
    return 0

def download(model: ModelSpec) -> int:
    files = matching_files(model)
    mmproj_files = matching_mmproj_files(model)
    if files and (not model.mmproj_include or mmproj_files):
        print(f"{model.alias}: already present at {files[0]}")
        if mmproj_files:
            print(f"{model.alias}: mmproj present at {mmproj_files[0]}")
        return 0
    cli = find_cli()
    command = [cli, "download", model.repo_id, "--local-dir", str(model.cache_dir)]
    for pattern in (*model.include, *model.mmproj_include):
        command.extend(["--include", pattern])
    print(f"downloading {model.alias} from {model.repo_id}")
    attempts = positive_int_env("LLAMACPP_PREFETCH_ATTEMPTS", 4)
    base_delay = positive_int_env("LLAMACPP_PREFETCH_RETRY_DELAY", 15)
    exit_code = 1
    for attempt in range(1, attempts + 1):
        completed = subprocess.run(command, text=True)
        exit_code = completed.returncode
        files = matching_files(model)
        mmproj_files = matching_mmproj_files(model)
        if exit_code == 0 and files and (not model.mmproj_include or mmproj_files):
            return 0
        if attempt == attempts:
            return exit_code
        delay = base_delay * (2 ** (attempt - 1))
        print(
            f"{model.alias}: download attempt {attempt}/{attempts} ended with exit code {exit_code}; "
            f"retrying in {delay}s",
            file=sys.stderr,
        )
        time.sleep(delay)
    return exit_code

def cmd_prefetch(args: argparse.Namespace) -> int:
    if args.alias:
        if args.alias not in MODEL_BY_ALIAS:
            print(f"unknown alias: {args.alias}", file=sys.stderr)
            return 2
        return download(MODEL_BY_ALIAS[args.alias])
    return download(DEFAULT_SPEC)

def cmd_resolve(args: argparse.Namespace) -> int:
    alias = args.alias or DEFAULT_SPEC.alias
    if alias not in MODEL_BY_ALIAS:
        print(f"unknown alias: {alias}", file=sys.stderr)
        return 2
    rec = record(MODEL_BY_ALIAS[alias])
    if args.json:
        print(json.dumps(rec, indent=2))
    else:
        print(rec["primary_path"])
    return 0 if rec["present"] else 1

def cmd_resolve_mmproj(args: argparse.Namespace) -> int:
    alias = args.alias or DEFAULT_SPEC.alias
    if alias not in MODEL_BY_ALIAS:
        print(f"unknown alias: {alias}", file=sys.stderr)
        return 2
    rec = record(MODEL_BY_ALIAS[alias])
    if args.json:
        print(json.dumps(rec, indent=2))
    else:
        print(rec["mmproj_path"])
    return 0 if rec["mmproj_present"] else 1

def cmd_default_alias(_args: argparse.Namespace) -> int:
    print(DEFAULT_SPEC.alias)
    return 0

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="command", required=True)

    inv = sub.add_parser("inventory", help="list known models and their presence on disk")
    inv.add_argument("--json", action="store_true")
    inv.set_defaults(func=cmd_inventory)

    pf = sub.add_parser("prefetch", help="download the default model (or a named optional alias)")
    pf.add_argument("alias", nargs="?")
    pf.set_defaults(func=cmd_prefetch)

    rs = sub.add_parser("resolve", help="print the on-disk path for an alias")
    rs.add_argument("alias", nargs="?")
    rs.add_argument("--json", action="store_true")
    rs.set_defaults(func=cmd_resolve)

    rm = sub.add_parser("resolve-mmproj", help="print the on-disk multimodal projector path for an alias")
    rm.add_argument("alias", nargs="?")
    rm.add_argument("--json", action="store_true")
    rm.set_defaults(func=cmd_resolve_mmproj)

    da = sub.add_parser("default-alias", help="print the blessed default alias")
    da.set_defaults(func=cmd_default_alias)

    return p.parse_args()

def main() -> int:
    args = parse_args()
    return args.func(args)

if __name__ == "__main__":
    raise SystemExit(main())
