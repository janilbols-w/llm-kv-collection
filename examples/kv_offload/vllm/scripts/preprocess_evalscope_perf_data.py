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

try:
    from evalscope.perf.plugin.datasets.utils import tokenize_chat_messages  # type: ignore[reportMissingImports]
except Exception:  # pragma: no cover - fallback for environments without evalscope package in PYTHONPATH
    tokenize_chat_messages = None

try:
    from evalscope.perf.plugin.datasets.utils import gen_prompt_decode_to_target_len  # type: ignore[reportMissingImports]
except Exception:  # pragma: no cover
    gen_prompt_decode_to_target_len = None


ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789 "


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


def _count_tokens(tokenizer, text: str, apply_chat_template: bool) -> int:
    if not apply_chat_template:
        return len(tokenizer.encode(text, add_special_tokens=False))

    messages = [{"role": "user", "content": text}]
    if tokenize_chat_messages is not None:
        return len(tokenize_chat_messages(tokenizer, messages))

    encoded = tokenizer.apply_chat_template(messages, tokenize=True, add_generation_prompt=True)
    if isinstance(encoded, list):
        if encoded and isinstance(encoded[0], list):
            return len(encoded[0])
        return len(encoded)
    if hasattr(encoded, "input_ids"):
        ids = encoded.input_ids
        ids = ids.tolist() if hasattr(ids, "tolist") else list(ids)
        if ids and isinstance(ids[0], list):
            return len(ids[0])
        return len(ids)
    raise RuntimeError("Unexpected tokenizer.apply_chat_template return type")


def _build_text(prefix: str, target_length: int) -> str:
    """Build deterministic text with an exact character length."""
    if target_length <= len(prefix):
        return prefix[:target_length]
    remainder = target_length - len(prefix)
    payload = (ALPHABET * ((remainder // len(ALPHABET)) + 2))[:remainder]
    return prefix + payload


def _build_token_text_raw(
    tokenizer,
    prefix: str,
    target_tokens: int,
    allowed_tokens: list[int],
    sequence_index: int,
    seed: int,
) -> str:
    """Build deterministic text using evalscope-random-like token sequencing."""
    best_text = None
    best_gap = 10**9

    def _track_best(candidate: str):
        nonlocal best_text, best_gap
        cand_len = len(tokenizer.encode(candidate, add_special_tokens=False))
        gap = abs(cand_len - target_tokens)
        if gap < best_gap:
            best_gap = gap
            best_text = candidate

    prefix = _sanitize_single_line_text(prefix)
    prefix_ids = tokenizer.encode(prefix, add_special_tokens=False)

    if len(prefix_ids) > target_tokens:
        clipped = prefix_ids[:target_tokens]
        text = _sanitize_single_line_text(tokenizer.decode(clipped, skip_special_tokens=True))
        _track_best(text)
        if len(tokenizer.encode(text, add_special_tokens=False)) == target_tokens:
            return text
        prefix = prefix[: max(0, len(prefix) - (len(prefix_ids) - target_tokens))]
        prefix_ids = tokenizer.encode(prefix, add_special_tokens=False)

    remaining = target_tokens - len(prefix_ids)
    if remaining == 0:
        text = _sanitize_single_line_text(tokenizer.decode(prefix_ids, skip_special_tokens=True))
        _track_best(text)
        if len(tokenizer.encode(text, add_special_tokens=False)) == target_tokens:
            return text

    base = (seed + sequence_index) % len(allowed_tokens)
    inner_ids = [allowed_tokens[(base + j) % len(allowed_tokens)] for j in range(remaining)]
    token_sequence = prefix_ids + inner_ids

    if gen_prompt_decode_to_target_len is not None:
        prompt, _, _ = gen_prompt_decode_to_target_len(
            tokenizer=tokenizer,
            token_sequence=token_sequence,
            target_token_len=target_tokens,
            add_special_tokens=False,
            allowed_tokens=allowed_tokens,
        )
        prompt = _sanitize_single_line_text(prompt)
        _track_best(prompt)
        if len(tokenizer.encode(prompt, add_special_tokens=False)) == target_tokens:
            return prompt

    # Fallback without evalscope utility.
    for attempt in range(32):
        rng = random.Random(f"{prefix}|{target_tokens}|{seed}|{sequence_index}|{attempt}")
        ids = list(token_sequence)
        for i in range(len(prefix_ids), len(ids)):
            if i > len(prefix_ids):
                # keep high diversity and avoid long repeats
                prev_tid = ids[i - 1]
                cand = allowed_tokens[rng.randrange(0, len(allowed_tokens))]
                if cand == prev_tid and len(allowed_tokens) > 1:
                    cand = allowed_tokens[(cand + 17) % len(allowed_tokens)]
                ids[i] = cand
        text = _sanitize_single_line_text(tokenizer.decode(ids, skip_special_tokens=True))
        _track_best(text)
        if len(tokenizer.encode(text, add_special_tokens=False)) == target_tokens:
            return text

    if best_text is not None:
        return best_text
    raise RuntimeError(f"Unable to construct text for prefix '{prefix}'.")


def _build_token_text(
    tokenizer,
    prefix: str,
    target_tokens: int,
    apply_chat_template: bool,
    allowed_tokens: list[int],
    sequence_index: int,
    seed: int,
) -> str:
    """Build deterministic text whose measured token length matches target.

    If chat template is enabled, measured length includes template overhead,
    mirroring EvalScope's prompt length filter behavior.
    """
    desired_raw = max(1, target_tokens)
    best_text = None
    best_gap = 10**9

    for _ in range(20):
        text = _build_token_text_raw(
            tokenizer,
            prefix,
            desired_raw,
            allowed_tokens=allowed_tokens,
            sequence_index=sequence_index,
            seed=seed,
        )
        measured = _count_tokens(tokenizer, text, apply_chat_template=apply_chat_template)
        gap = abs(measured - target_tokens)
        if gap < best_gap:
            best_gap = gap
            best_text = text
        if measured == target_tokens:
            return text
        desired_raw = max(1, desired_raw + (target_tokens - measured))

    if best_text is not None:
        return best_text
    raise RuntimeError(f"Unable to construct target-length text for prefix '{prefix}'.")


def _generate_single_turn(
    output: Path,
    size: int,
    seed: int,
    prompt_length: int,
    tokenizer=None,
    apply_chat_template: bool = True,
    batch_size: int = 32,
    progress_every: int = 0,
    log_interval_seconds: int = 30,
) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as f:
        allowed_tokens = _get_allowed_tokens(tokenizer) if tokenizer is not None else None
        pending_lines: list[str] = []
        started_at = time.monotonic()
        last_log_at = started_at
        _log(
            "Start generating single-turn dataset: "
            f"size={size}, prompt_length={prompt_length}, "
            f"length_unit={'token' if tokenizer is not None else 'char'}, "
            f"batch_size={max(1, batch_size)}"
        )
        for index in range(size):
            if tokenizer is None:
                prompt = _build_text(f"case-{seed}-{index}-", prompt_length)
            else:
                prompt = _build_token_text(
                    tokenizer,
                    f"case-{seed}-{index}-",
                    prompt_length,
                    apply_chat_template=apply_chat_template,
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
    tokenizer=None,
    apply_chat_template: bool = True,
    batch_size: int = 32,
    progress_every: int = 0,
    log_interval_seconds: int = 30,
) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as f:
        allowed_tokens = _get_allowed_tokens(tokenizer) if tokenizer is not None else None
        pending_lines: list[str] = []
        started_at = time.monotonic()
        last_log_at = started_at
        _log(
            "Start generating multi-turn dataset: "
            f"size={size}, turns={turns}, turn_length={turn_length}, "
            f"length_unit={'token' if tokenizer is not None else 'char'}, "
            f"batch_size={max(1, batch_size)}"
        )
        for index in range(size):
            messages = []
            for turn_index in range(turns):
                if tokenizer is None:
                    content = _build_text(f"case-{seed}-{index}-{turn_index}-", turn_length)
                else:
                    content = _build_token_text(
                        tokenizer,
                        f"case-{seed}-{index}-{turn_index}-",
                        turn_length,
                        apply_chat_template=apply_chat_template,
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
        help="Character length of each single-turn prompt",
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
        help="Character length of each user turn in multi-turn mode",
    )
    parser.add_argument(
        "--tokenizer-path",
        default=None,
        help="Optional tokenizer path for token-based generation",
    )
    parser.add_argument(
        "--length-unit",
        choices=["char", "token"],
        default="token",
        help="Interpret prompt-length/turn-length as characters or tokens (default: token)",
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
    if hasattr(argparse, "BooleanOptionalAction"):
        parser.add_argument(
            "--apply-chat-template",
            action=argparse.BooleanOptionalAction,
            default=True,
            help="Whether token-length measurement includes chat template overhead (default: true)",
        )
    else:
        apply_group = parser.add_mutually_exclusive_group()
        apply_group.add_argument(
            "--apply-chat-template",
            dest="apply_chat_template",
            action="store_true",
            help="Enable chat-template-aware token measurement (default)",
        )
        apply_group.add_argument(
            "--no-apply-chat-template",
            dest="apply_chat_template",
            action="store_false",
            help="Disable chat-template-aware token measurement",
        )
        parser.set_defaults(apply_chat_template=True)
    parser.add_argument("--overwrite", action="store_true", help="Overwrite existing output file")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    _log(
        "Preprocess start: "
        f"mode={args.mode}, output={args.output}, size={args.size}, seed={args.seed}, "
        f"length_unit={args.length_unit}, tokenizer_path={args.tokenizer_path or 'none'}"
    )

    output = Path(args.output).expanduser()
    if output.exists() and not args.overwrite:
        raise SystemExit(f"Output file already exists: {output} (use --overwrite to replace it)")

    tokenizer = None
    if args.length_unit == "token":
        tokenizer = _load_tokenizer(args.tokenizer_path)
        if tokenizer is None:
            raise SystemExit("--length-unit token requires --tokenizer-path")

    if args.mode == "single":
        _generate_single_turn(
            output,
            args.size,
            args.seed,
            args.prompt_length,
            tokenizer=tokenizer,
            apply_chat_template=args.apply_chat_template,
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
            apply_chat_template=args.apply_chat_template,
            batch_size=args.batch_size,
            progress_every=args.progress_every,
            log_interval_seconds=args.log_interval_seconds,
        )

    _log(f"Wrote {args.size} {args.mode} sample(s) to {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())