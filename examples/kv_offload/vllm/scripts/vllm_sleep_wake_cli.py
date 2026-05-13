#!/usr/bin/env python3
"""CLI for vLLM sleep mode endpoints.

Supports:
- POST /sleep
- POST /wake_up
- GET  /is_sleeping

Example:
    python vllm_sleep_wake_cli.py sleep --level 2 --mode wait
    python vllm_sleep_wake_cli.py wake --tag weights --tag kv_cache
    python vllm_sleep_wake_cli.py status
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Dict, List, Optional


def _parse_kv_pair(item: str) -> tuple[str, str]:
    if "=" not in item:
        raise argparse.ArgumentTypeError(
            f"Invalid --query format: '{item}', expected key=value"
        )
    key, value = item.split("=", 1)
    key = key.strip()
    value = value.strip()
    if not key:
        raise argparse.ArgumentTypeError(
            f"Invalid --query format: '{item}', key cannot be empty"
        )
    return key, value


def _merge_query_params(
    base: Dict[str, List[str]],
    extras: Optional[List[tuple[str, str]]] = None,
) -> Dict[str, List[str]]:
    merged = {k: list(v) for k, v in base.items()}
    if extras:
        for key, value in extras:
            merged.setdefault(key, []).append(value)
    return merged


def _build_url(base_url: str, path: str, params: Dict[str, List[str]]) -> str:
    base_url = base_url.rstrip("/")
    query = urllib.parse.urlencode(params, doseq=True)
    if query:
        return f"{base_url}{path}?{query}"
    return f"{base_url}{path}"


def _request(
    method: str,
    url: str,
    timeout: float,
) -> tuple[int, str]:
    req = urllib.request.Request(url=url, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            return resp.status, body
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        return e.code, body


def _print_response(status_code: int, body: str, raw: bool) -> None:
    if raw:
        print(body)
        return

    print(f"HTTP {status_code}")
    if not body:
        return

    try:
        parsed = json.loads(body)
    except json.JSONDecodeError:
        print(body)
        return

    print(json.dumps(parsed, ensure_ascii=True, indent=2, sort_keys=True))


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="CLI for vLLM sleep/wake/status endpoints.",
    )
    parser.add_argument(
        "--base-url",
        default="http://127.0.0.1:12358",
        help="vLLM server base URL (default: http://127.0.0.1:12358)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=30.0,
        help="HTTP timeout in seconds (default: 30)",
    )
    parser.add_argument(
        "--raw",
        action="store_true",
        help="Print raw response body only",
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    sleep_parser = subparsers.add_parser("sleep", help="Call POST /sleep")
    sleep_parser.add_argument(
        "--level",
        type=int,
        choices=[1, 2],
        default=1,
        help="Sleep level (1 or 2, default: 1)",
    )
    sleep_parser.add_argument(
        "--mode",
        default="abort",
        help="Sleep mode query param (default: abort)",
    )
    sleep_parser.add_argument(
        "--query",
        type=_parse_kv_pair,
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help="Extra query param(s), can be repeated",
    )

    wake_parser = subparsers.add_parser("wake", help="Call POST /wake_up")
    wake_parser.add_argument(
        "--tag",
        action="append",
        default=[],
        choices=["weights", "kv_cache"],
        help="Wake-up tag, can be repeated (weights/kv_cache)",
    )
    wake_parser.add_argument(
        "--query",
        type=_parse_kv_pair,
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help="Extra query param(s), can be repeated",
    )

    status_parser = subparsers.add_parser("status", help="Call GET /is_sleeping")
    status_parser.add_argument(
        "--query",
        type=_parse_kv_pair,
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help="Extra query param(s), can be repeated",
    )

    return parser


def main() -> int:
    parser = _build_parser()
    args = parser.parse_args()

    if args.command == "sleep":
        params = _merge_query_params(
            base={"level": [str(args.level)], "mode": [args.mode]},
            extras=args.query,
        )
        url = _build_url(args.base_url, "/sleep", params)
        status_code, body = _request("POST", url, args.timeout)

    elif args.command == "wake":
        base: Dict[str, List[str]] = {}
        if args.tag:
            base["tags"] = args.tag
        params = _merge_query_params(base=base, extras=args.query)
        url = _build_url(args.base_url, "/wake_up", params)
        status_code, body = _request("POST", url, args.timeout)

    elif args.command == "status":
        params = _merge_query_params(base={}, extras=args.query)
        url = _build_url(args.base_url, "/is_sleeping", params)
        status_code, body = _request("GET", url, args.timeout)

    else:
        parser.error(f"Unsupported command: {args.command}")
        return 2

    _print_response(status_code, body, raw=args.raw)

    if 200 <= status_code < 300:
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
