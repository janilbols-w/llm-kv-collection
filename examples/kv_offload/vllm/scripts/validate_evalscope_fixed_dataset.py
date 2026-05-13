#!/usr/bin/env python3
"""Validate fixed dataset files generated for evalscope perf.

Exit code:
- 0: valid
- 1: invalid
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def validate_dataset(mode: str, file_path: Path, expected_size: int) -> tuple[bool, str]:
    if not file_path.exists():
        return False, "missing"

    raw = file_path.read_bytes()
    if b"\x00" in raw or b"\r" in raw:
        return False, "contains_control_bytes"

    lines = file_path.read_text(encoding="utf-8", errors="replace").splitlines()
    if len(lines) != expected_size:
        return False, f"line_count_mismatch:{len(lines)}"

    if mode == "single":
        if any((not ln.strip()) for ln in lines):
            return False, "contains_empty_prompt"
        return True, "ok"

    for ln in lines:
        ln = ln.strip()
        if not ln:
            return False, "contains_empty_line"
        try:
            obj = json.loads(ln)
        except Exception:
            return False, "invalid_json_line"
        if not isinstance(obj, list) or not obj:
            return False, "invalid_multi_turn_record"

    return True, "ok"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Validate evalscope fixed dataset file")
    parser.add_argument("--mode", choices=["single", "multi"], required=True)
    parser.add_argument("--file", required=True, help="Path to dataset file")
    parser.add_argument("--expected-size", type=int, required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    ok, reason = validate_dataset(args.mode, Path(args.file), args.expected_size)
    print(reason)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
