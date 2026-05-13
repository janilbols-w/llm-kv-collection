#!/usr/bin/env python3
"""Generate deterministic input data for EvalScope perf benchmarks.

This script creates a local JSONL file that can be reused across repeated
benchmark runs so the request contents remain identical.

Supported output formats:
- single-turn: each JSONL line is a plain prompt string
- multi-turn: each JSONL line is a JSON array of OpenAI-style messages

Examples:
  python preprocess_evalscope_perf_data.py \
    --mode single \
    --output ./outputs/fixed_inputs/single.jsonl \
    --size 128 \
    --seed 42 \
    --prompt-length 512

  python preprocess_evalscope_perf_data.py \
    --mode multi-turn \
    --output ./outputs/fixed_inputs/multi.jsonl \
    --size 64 \
    --seed 42 \
    --turns 4 \
    --turn-length 256
"""

from __future__ import annotations

import argparse
import json
import random
import re
import time
from pathlib import Path

try:
    from modelscope import AutoTokenizer
except Exception:  # pragma: no cover - fallback for environments without modelscope
    AutoTokenizer = None


def _log(message: str) -> None:
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
    print(f"[{timestamp}] [INFO] {message}", flush=True)


def _should_log_progress(
    index: int,
    last_log_at: float,
    progress_every: int,
    log_interval_seconds: int,
) -> bool:
    if progress_every > 0 and ((index + 1) % progress_every == 0):
        return True
    if log_interval_seconds > 0 and (time.monotonic() - last_log_at) >= log_interval_seconds:
        return True
    return False


def _sanitize_single_line_text(text: str) -> str:
    """Normalize decoded prompts to one printable line.

    EvalScope's line-by-line custom dataset loader treats physical newlines as
    record separators, so generated prompts must not contain embedded line
    breaks or control characters.
    """
    sanitized_chars = []
    for ch in text:
        if ch in "\r\n\t\x0b\x0c":
            sanitized_chars.append(" ")
        elif ch.isprintable():
            sanitized_chars.append(ch)
        else:
            sanitized_chars.append(" ")
    sanitized = "".join(sanitized_chars)
    return re.sub(r"\s+", " ", sanitized).strip()


def _load_tokenizer(tokenizer_path: str | None):
    if not tokenizer_path:
        return None
    if AutoTokenizer is None:
        raise RuntimeError("modelscope is required for token-based preprocessing")
    _log(f"Loading tokenizer from {tokenizer_path}")
    return AutoTokenizer.from_pretrained(tokenizer_path, trust_remote_code=True)


def _get_byte_fallback_token_ids(tokenizer) -> set[int]:
    pattern = re.compile(r"^<0x[0-9A-Fa-f]{2}>$")
    byte_ids: set[int] = set()
    try:
        vocab = tokenizer.get_vocab()
        for token_str, token_id in vocab.items():
            if pattern.match(token_str):
                byte_ids.add(token_id)
    except Exception:
        for i in range(len(tokenizer)):
            try:
                tok = tokenizer.convert_ids_to_tokens(i)
                if tok and pattern.match(tok):
                    byte_ids.add(i)
            except Exception:
                continue
    return byte_ids


def _get_allowed_tokens(tokenizer) -> list[int]:
    _log("Scanning tokenizer vocab to build allowed token list")
    full_vocab_size = len(tokenizer)
    prohibited = set(getattr(tokenizer, "all_special_ids", []) or [])
    prohibited.update(_get_byte_fallback_token_ids(tokenizer))
    allowed = [tid for tid in range(full_vocab_size) if tid not in prohibited]
    if not allowed:
        raise RuntimeError("No allowed tokens available after filtering")
    _log(
        "Allowed token scan complete: "
        f"vocab={full_vocab_size}, prohibited={len(prohibited)}, allowed={len(allowed)}"
    )
    return allowed


def _build_token_text_fast(
    tokenizer,
    prefix: str,
    target_tokens: int,
    allowed_tokens: list[int],
    sequence_index: int,
    seed: int,
) -> str:
    """Fast path: generate token IDs once and decode once.

    This intentionally skips post-decode re-encode validation/correction to
    maximize speed for benchmark data generation.
    """
    prefix = _sanitize_single_line_text(prefix)
    prefix_ids = tokenizer.encode(prefix, add_special_tokens=False)

    if len(prefix_ids) >= target_tokens:
        token_sequence = prefix_ids[:target_tokens]
    else:
        remain = target_tokens - len(prefix_ids)
        rng = random.Random(f"{seed}|{sequence_index}|{target_tokens}|fast")
        sampled = [allowed_tokens[rng.randrange(0, len(allowed_tokens))] for _ in range(remain)]
        token_sequence = prefix_ids + sampled

    text = tokenizer.decode(token_sequence, skip_special_tokens=True)
    return _sanitize_single_line_text(text)


def _generate_single_turn(
    output: Path,
    size: int,
    seed: int,
    prompt_length: int,
    tokenizer,
    batch_size: int = 32,
    progress_every: int = 0,
    log_interval_seconds: int = 30,
) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as f:
        allowed_tokens = _get_allowed_tokens(tokenizer)
        pending_lines: list[str] = []
        started_at = time.monotonic()
        last_log_at = started_at
        _log(
            "Start generating single-turn dataset: "
            f"size={size}, prompt_length={prompt_length}, "
            "length_unit=token, "
            f"batch_size={max(1, batch_size)}"
        )
        for index in range(size):
            prompt = _build_token_text_fast(
                tokenizer,
                f"case-{seed}-{index}-",
                prompt_length,
                allowed_tokens=allowed_tokens,
                sequence_index=index,
                seed=seed,
            )
            prompt = _sanitize_single_line_text(prompt)
            pending_lines.append(prompt + "\n")

            if len(pending_lines) >= max(1, batch_size):
                f.writelines(pending_lines)
                pending_lines.clear()

            if _should_log_progress(index, last_log_at, progress_every, log_interval_seconds):
                elapsed = time.monotonic() - started_at
                _log(
                    f"Generated {index + 1}/{size} single-turn samples "
                    f"({elapsed:.1f}s elapsed)"
                )
                last_log_at = time.monotonic()

        if pending_lines:
            f.writelines(pending_lines)

        elapsed = time.monotonic() - started_at
        _log(f"Finished single-turn generation in {elapsed:.1f}s")


def _generate_multi_turn(
    output: Path,
    size: int,
    seed: int,
    turns: int,
    turn_length: int,
    tokenizer,
    batch_size: int = 32,
    progress_every: int = 0,
    log_interval_seconds: int = 30,
) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as f:
        allowed_tokens = _get_allowed_tokens(tokenizer)
        pending_lines: list[str] = []
        started_at = time.monotonic()
        last_log_at = started_at
        _log(
            "Start generating multi-turn dataset: "
            f"size={size}, turns={turns}, turn_length={turn_length}, "
            "length_unit=token, "
            f"batch_size={max(1, batch_size)}"
        )
        for index in range(size):
            messages = []
            for turn_index in range(turns):
                content = _build_token_text_fast(
                    tokenizer,
                    f"case-{seed}-{index}-{turn_index}-",
                    turn_length,
                    allowed_tokens=allowed_tokens,
                    sequence_index=index * max(1, turns) + turn_index,
                    seed=seed,
                )
                messages.append(
                    {
                        "role": "user",
                        "content": content,
                    }
                )
                if turn_index < turns - 1:
                    messages.append(
                        {
                            "role": "assistant",
                            "content": f"ack-{seed}-{index}-{turn_index}",
                        }
                    )
            pending_lines.append(json.dumps(messages, ensure_ascii=True) + "\n")

            if len(pending_lines) >= max(1, batch_size):
                f.writelines(pending_lines)
                pending_lines.clear()

            if _should_log_progress(index, last_log_at, progress_every, log_interval_seconds):
                elapsed = time.monotonic() - started_at
                _log(
                    f"Generated {index + 1}/{size} multi-turn samples "
                    f"({elapsed:.1f}s elapsed)"
                )
                last_log_at = time.monotonic()

        if pending_lines:
            f.writelines(pending_lines)

        elapsed = time.monotonic() - started_at
        _log(f"Finished multi-turn generation in {elapsed:.1f}s")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Generate deterministic EvalScope perf data.")
    parser.add_argument("--mode", choices=["single", "multi-turn"], required=True)
    parser.add_argument("--output", required=True, help="Output JSONL path")
    parser.add_argument("--size", type=int, required=True, help="Number of samples or conversations")
    parser.add_argument("--seed", type=int, default=42, help="Seed used in sample IDs")
    parser.add_argument(
        "--prompt-length",
        type=int,
        default=512,
        help="Target token length of each single-turn prompt",
    )
    parser.add_argument(
        "--turns",
        type=int,
        default=4,
        help="Number of user turns per conversation in multi-turn mode",
    )
    parser.add_argument(
        "--turn-length",
        type=int,
        default=512,
        help="Target token length of each user turn in multi-turn mode",
    )
    parser.add_argument(
        "--tokenizer-path",
        required=True,
        help="Tokenizer path for token-based generation",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=32,
        help="How many generated records to buffer before each file write (default: 32)",
    )
    parser.add_argument(
        "--progress-every",
        type=int,
        default=0,
        help="Print progress every N records (0 disables progress logs)",
    )
    parser.add_argument(
        "--log-interval-seconds",
        type=int,
        default=30,
        help="Print a heartbeat log at least every N seconds during generation (default: 30)",
    )
    parser.add_argument("--overwrite", action="store_true", help="Overwrite existing output file")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    _log(
        "Preprocess start: "
        f"mode={args.mode}, output={args.output}, size={args.size}, seed={args.seed}, "
        f"length_unit=token, tokenizer_path={args.tokenizer_path}"
    )

    output = Path(args.output).expanduser()
    if output.exists() and not args.overwrite:
        raise SystemExit(f"Output file already exists: {output} (use --overwrite to replace it)")

    tokenizer = _load_tokenizer(args.tokenizer_path)
    if tokenizer is None:
        raise SystemExit("Failed to load tokenizer. Please check --tokenizer-path.")

    if args.mode == "single":
        _generate_single_turn(
            output,
            args.size,
            args.seed,
            args.prompt_length,
            tokenizer=tokenizer,
            batch_size=args.batch_size,
            progress_every=args.progress_every,
            log_interval_seconds=args.log_interval_seconds,
        )
    else:
        _generate_multi_turn(
            output,
            args.size,
            args.seed,
            args.turns,
            args.turn_length,
            tokenizer=tokenizer,
            batch_size=args.batch_size,
            progress_every=args.progress_every,
            log_interval_seconds=args.log_interval_seconds,
        )

    _log(f"Wrote {args.size} {args.mode} sample(s) to {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())