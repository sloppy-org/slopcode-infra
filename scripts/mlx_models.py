#!/usr/bin/env python3
"""MLX model registry for the Apple-silicon exclusive-big-model host.

llama.cpp cannot yet run the newest sparse-MoE flagships well on Metal, so a
Mac dedicated to one large model serves it through `mlx_lm.server` instead.
This registry is the MLX analogue of `llamacpp_models.py`: one default alias
plus a short optional list, each resolved from the Hugging Face hub cache.

Default:
    minimax-m3-mixed -> pipenetwork/MiniMax-M3-MLX-mixed-3_6bit (~178 GiB)

The mixed-3/6-bit build (experts at 3-bit, attention/router/embeddings higher)
is the best quality-per-GiB MiniMax M3 variant and leaves room for a 128K KV
cache plus runtime overhead under the 248 GiB wired limit. The plain 4-bit
build (~240 GiB) does not.

Alternate:
    deepseek-v4-flash -> Deviad/DeepSeek-V4-Flash-MLX-Q4Q8 (~173 GiB)

Only one model is active at a time; `mlx_switch.sh` flips between them and
re-stamps the slopgate agent identity. `prefetch` only touches the default;
optional aliases are downloaded explicitly.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field, asdict
from pathlib import Path


def hub_cache_root() -> Path:
    explicit = os.environ.get("HF_HUB_CACHE", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    home = os.environ.get("HF_HOME", "").strip()
    if home:
        return Path(home).expanduser() / "hub"
    return Path.home() / ".cache" / "huggingface" / "hub"


HUB_CACHE_ROOT = hub_cache_root()


@dataclass(frozen=True)
class MlxSpec:
    alias: str
    repo_id: str
    quant: str
    canonical: str
    aliases: tuple[str, ...]
    sampler: dict[str, float]
    max_context: int = 131072
    default: bool = False

    @property
    def snapshot_glob(self) -> str:
        # hf hub stores repos as models--<org>--<name>/snapshots/<rev>/
        return "models--" + self.repo_id.replace("/", "--")


# MiniMax recommends temp 1.0 / top_p 0.95 / top_k 40 for M3.
MINIMAX_SAMPLER = {"temp": 1.0, "top_p": 0.95, "top_k": 40, "min_p": 0.0}
# DeepSeek V4-Flash follows the DeepSeek precise-coding dials.
DEEPSEEK_SAMPLER = {"temp": 0.6, "top_p": 0.95, "top_k": 20, "min_p": 0.0}

DEFAULT_SPEC = MlxSpec(
    alias="minimax-m3-mixed",
    repo_id="pipenetwork/MiniMax-M3-MLX-mixed-3_6bit",
    quant="MLX-mixed-3_6bit",
    canonical="minimaxai/minimax-m3@128k",
    aliases=("minimax", "minimax-m3", "m3", "minimax-m3@128k"),
    sampler=MINIMAX_SAMPLER,
    default=True,
)

OPTIONAL_SPECS: tuple[MlxSpec, ...] = (
    MlxSpec(
        alias="minimax-m3-4bit",
        repo_id="pipenetwork/MiniMax-M3-MLX-4bit",
        quant="MLX-4bit",
        canonical="minimaxai/minimax-m3@128k",
        aliases=("minimax", "minimax-m3", "m3", "minimax-m3@128k"),
        sampler=MINIMAX_SAMPLER,
    ),
    MlxSpec(
        alias="deepseek-v4-flash",
        repo_id="Deviad/DeepSeek-V4-Flash-MLX-Q4Q8",
        quant="MLX-Q4Q8",
        canonical="deepseek-ai/deepseek-v4-flash@128k",
        aliases=("deepseek", "deepseek-v4-flash", "v4-flash", "deepseek-v4-flash@128k"),
        sampler=DEEPSEEK_SAMPLER,
    ),
)

MODEL_SPECS: tuple[MlxSpec, ...] = (DEFAULT_SPEC, *OPTIONAL_SPECS)
MODEL_BY_ALIAS = {m.alias: m for m in MODEL_SPECS}


def snapshot_dir(spec: MlxSpec) -> Path | None:
    """Return the resolved snapshot directory if the repo is in the hub cache.

    mlx_lm.server accepts the repo id directly and resolves the cache itself,
    but the launcher and switch need an on-disk presence check, so resolve the
    newest complete snapshot here.
    """
    base = HUB_CACHE_ROOT / spec.snapshot_glob / "snapshots"
    if not base.is_dir():
        return None
    snaps = [p for p in base.iterdir() if p.is_dir()]
    if not snaps:
        return None
    # Newest by mtime; a snapshot with a config.json is a real, usable revision.
    snaps.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    for snap in snaps:
        if (snap / "config.json").exists():
            return snap
    return None


def present(spec: MlxSpec) -> bool:
    return snapshot_dir(spec) is not None


def snapshot_size_bytes(snap: Path) -> int:
    total = 0
    for root, _dirs, files in os.walk(snap):
        for name in files:
            try:
                total += (Path(root) / name).stat().st_size
            except OSError:
                pass
    return total


def record(spec: MlxSpec) -> dict:
    snap = snapshot_dir(spec)
    return {
        "alias": spec.alias,
        "repo_id": spec.repo_id,
        "quant": spec.quant,
        "canonical": spec.canonical,
        "aliases": list(spec.aliases),
        "sampler": dict(spec.sampler),
        "max_context": spec.max_context,
        "default": spec.default,
        "present": snap is not None,
        # mlx_lm.server --model: pass the repo id; it resolves the cache.
        "model_arg": spec.repo_id,
        "snapshot_dir": str(snap) if snap else "",
    }


def find_hf_cli() -> str:
    path = shutil.which("hf") or shutil.which("huggingface-cli")
    if not path:
        raise RuntimeError(
            'missing hf CLI; install with: uv tool install --with hf_transfer huggingface_hub'
        )
    return path


def positive_int_env(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    value = int(raw)
    if value < 1:
        raise ValueError(f"{name} must be >= 1, got {value}")
    return value


def download(spec: MlxSpec) -> int:
    if present(spec):
        print(f"{spec.alias}: already present at {snapshot_dir(spec)}")
        return 0
    cli = find_hf_cli()
    command = [cli, "download", spec.repo_id]
    env = dict(os.environ)
    env.setdefault("HF_HUB_ENABLE_HF_TRANSFER", "1")
    print(f"downloading {spec.alias} from {spec.repo_id} (this is large)")
    attempts = positive_int_env("MLX_PREFETCH_ATTEMPTS", 4)
    base_delay = positive_int_env("MLX_PREFETCH_RETRY_DELAY", 15)
    exit_code = 1
    for attempt in range(1, attempts + 1):
        completed = subprocess.run(command, text=True, env=env)
        exit_code = completed.returncode
        if exit_code == 0 and present(spec):
            return 0
        if attempt == attempts:
            return exit_code
        delay = base_delay * (2 ** (attempt - 1))
        print(
            f"{spec.alias}: download attempt {attempt}/{attempts} exited {exit_code}; "
            f"retrying in {delay}s",
            file=sys.stderr,
        )
        time.sleep(delay)
    return exit_code


def spec_or_die(alias: str | None) -> MlxSpec:
    name = alias or DEFAULT_SPEC.alias
    if name not in MODEL_BY_ALIAS:
        print(f"unknown alias: {name}", file=sys.stderr)
        raise SystemExit(2)
    return MODEL_BY_ALIAS[name]


def cmd_inventory(args: argparse.Namespace) -> int:
    records = [record(m) for m in MODEL_SPECS]
    if args.json:
        print(json.dumps(records, indent=2))
        return 0
    for r in records:
        status = "present" if r["present"] else "missing"
        tag = " [default]" if r["default"] else ""
        print(f"{r['alias']}{tag}: {status} ({r['quant']})")
        print(f"  repo: {r['repo_id']}")
        if r["snapshot_dir"]:
            print(f"  path: {r['snapshot_dir']}")
    return 0


def cmd_prefetch(args: argparse.Namespace) -> int:
    return download(spec_or_die(args.alias) if args.alias else DEFAULT_SPEC)


def cmd_resolve(args: argparse.Namespace) -> int:
    rec = record(spec_or_die(args.alias))
    if args.json:
        print(json.dumps(rec, indent=2))
    else:
        # The model arg the launcher hands to mlx_lm.server --model.
        print(rec["model_arg"])
    return 0 if rec["present"] else 1


def cmd_agent_env(args: argparse.Namespace) -> int:
    """Emit the slopgate agent identity for an alias as shell KEY=VALUE lines.

    Consumed by install_mac_mlx_launchagent.sh and mlx_switch.sh so the agent
    advertises the right canonical/aliases/quant without duplicating the table.
    """
    spec = spec_or_die(args.alias)
    pairs = {
        "MLX_MODEL_ALIAS": spec.alias,
        "MLX_MODEL_ARG": spec.repo_id,
        "SLOPGATE_MODEL_ALIAS": spec.aliases[0],
        "SLOPGATE_CANONICAL_MODEL": spec.canonical,
        "SLOPGATE_MODEL_ALIASES": ",".join(spec.aliases),
        "SLOPGATE_QUANT": spec.quant,
        "SLOPGATE_MAX_CONTEXT": str(spec.max_context),
        "SLOPGATE_UPSTREAM_MODEL": spec.repo_id,
    }
    for key, value in pairs.items():
        print(f"{key}={value}")
    return 0


def cmd_sampler(args: argparse.Namespace) -> int:
    """Emit sampler defaults as mlx_lm.server flags for an alias."""
    spec = spec_or_die(args.alias)
    flags: list[str] = []
    for key in ("temp", "top_p", "top_k", "min_p"):
        if key in spec.sampler:
            val = spec.sampler[key]
            if key in ("top_k",):
                val = int(val)
            flags.extend([f"--{key.replace('_', '-')}", str(val)])
    print(" ".join(flags))
    return 0


def cmd_default_alias(_args: argparse.Namespace) -> int:
    print(DEFAULT_SPEC.alias)
    return 0


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="command", required=True)

    inv = sub.add_parser("inventory", help="list known MLX models and presence")
    inv.add_argument("--json", action="store_true")
    inv.set_defaults(func=cmd_inventory)

    pf = sub.add_parser("prefetch", help="download the default model (or a named alias)")
    pf.add_argument("alias", nargs="?")
    pf.set_defaults(func=cmd_prefetch)

    rs = sub.add_parser("resolve", help="print the mlx_lm --model arg for an alias")
    rs.add_argument("alias", nargs="?")
    rs.add_argument("--json", action="store_true")
    rs.set_defaults(func=cmd_resolve)

    ae = sub.add_parser("agent-env", help="emit slopgate agent identity KEY=VALUE lines")
    ae.add_argument("alias", nargs="?")
    ae.set_defaults(func=cmd_agent_env)

    sm = sub.add_parser("sampler", help="emit mlx_lm.server sampler flags for an alias")
    sm.add_argument("alias", nargs="?")
    sm.set_defaults(func=cmd_sampler)

    da = sub.add_parser("default-alias", help="print the blessed default alias")
    da.set_defaults(func=cmd_default_alias)

    return p.parse_args()


def main() -> int:
    args = parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
