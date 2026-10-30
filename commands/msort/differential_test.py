#!/usr/bin/env python3
"""Seeded differential compatibility test for two msort executables."""

from __future__ import annotations

import argparse
import random
import subprocess
from pathlib import Path


KEYS = (
    "key=1",
    "key=1r",
    "key=2n",
    "key=2nr",
    "key=1@2n",
    "key=1/3",
    "key=NF",
    "key=NF-1r",
    "key=1/NF",
    "key=1n@3r",
)

LARGE_KEYS = (
    "key=1",
    "key=1r",
    "key=2n",
    "key=2nr",
    "key=1@2n",
    "key=2n@1r",
)


def run(binary: Path, arguments: list[str], data: bytes) -> tuple[int, bytes, bytes]:
    result = subprocess.run(
        [str(binary), *arguments], input=data, capture_output=True, check=False
    )
    return result.returncode, result.stdout, result.stderr


def make_case(rng: random.Random) -> tuple[list[str], bytes]:
    key = rng.choice(KEYS)
    option_mode = rng.randrange(8)
    options: list[str] = []
    if option_mode == 0 and "n" not in key and "N" not in key:
        options = ["-e"]
    elif option_mode == 1 and "n" not in key and "N" not in key:
        options = ["-e", "-s@"]

    rows: list[bytes] = []
    for row_index in range(rng.randrange(0, 121)):
        field_count = rng.randrange(4, 8)
        fields: list[str] = []
        for field_index in range(field_count):
            value = rng.randrange(-50_000, 50_001)
            if field_index % 2 == 0 and rng.randrange(4) == 0:
                field = f"{value / 10.0:.1f}"
            else:
                field = str(value)
            if options == ["-e"] and field_index == 0:
                field = f"v_{abs(value) % 97:02d}"
            elif options == ["-e", "-s@"] and field_index == 0:
                field = f"v@{abs(value) % 97:02d}"
            fields.append(field)
        separator = rng.choice((" ", "  ", "\t", " \t"))
        prefix = rng.choice(("", " ", "\t"))
        suffix = rng.choice(("", " ", "\t"))
        rows.append((prefix + separator.join(fields) + suffix).encode())

    data = b"\n".join(rows)
    if rows:
        data += b"\n"
    return [*options, key, "-"], data


def make_large_case(key: str, rows: int) -> tuple[list[str], bytes]:
    """Exercise the >=4096-row radix path, including long shared prefixes."""
    prefixes = ("abcdefgh", "bbcdefgh", "cbcdefgh", "dbcdefgh")
    output: list[bytes] = []
    for index in range(rows):
        shuffled = (index * 48271 + 12345) % rows
        prefix = prefixes[(shuffled * 17) % len(prefixes)]
        text_key = f"{prefix}{(shuffled * 97) % 1009:04d}"
        number = (shuffled * 69621 + 17) % 1_000_003 - 500_001
        if index % 997 == 0:
            numeric_key = "-0" if index % 1994 == 0 else "+0"
        elif index % 31 == 0:
            numeric_key = f"{number / 10.0:.1f}"
        else:
            numeric_key = str(number)
        output.append(f"{text_key} {numeric_key} payload_{index:06d}\n".encode())
    return [key, "-"], b"".join(output)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--cases", type=int, default=1000)
    parser.add_argument("--seed", type=int, default=20261030)
    parser.add_argument(
        "--large-rows",
        type=int,
        default=8192,
        help="rows in each radix-path case; 0 disables the six large cases",
    )
    parser.add_argument(
        "--valid-only",
        action="store_true",
        help="skip fixed error/edge cases when the reference has an older error contract",
    )
    args = parser.parse_args()
    if args.cases < 0 or args.large_rows < 0:
        parser.error("cases and large-rows must be non-negative")

    rng = random.Random(args.seed)
    fixed = (
        (["key=2n", "-"], b"a nope\n"),
        (["key=7", "-"], b"1 2 3\n"),
        (["key=abc", "-"], b"1 2 3\n"),
        (["key=1", "-"], b"missing-final-newline"),
        (["-p0", "key=1", "-"], b"1 2 3\n"),
        (["key=1", "-"], b""),
    )

    checked = 0
    if not args.valid_only:
        for arguments, data in fixed:
            expected = run(args.reference, list(arguments), data)
            actual = run(args.candidate, list(arguments), data)
            if actual != expected:
                raise SystemExit(
                    f"fixed case mismatch: args={arguments!r} data={data!r}\n"
                    f"reference={expected!r}\ncandidate={actual!r}"
                )
            checked += 1

    for case_index in range(args.cases):
        arguments, data = make_case(rng)
        expected = run(args.reference, arguments, data)
        actual = run(args.candidate, arguments, data)
        if actual != expected:
            raise SystemExit(
                f"random case {case_index} mismatch: args={arguments!r} data={data!r}\n"
                f"reference={expected!r}\ncandidate={actual!r}"
            )
        checked += 1

    if args.large_rows:
        for key in LARGE_KEYS:
            arguments, data = make_large_case(key, args.large_rows)
            expected = run(args.reference, arguments, data)
            actual = run(args.candidate, arguments, data)
            if actual != expected:
                raise SystemExit(
                    f"large radix case mismatch: args={arguments!r} rows={args.large_rows}\n"
                    f"reference={(expected[0], len(expected[1]), expected[2])!r}\n"
                    f"candidate={(actual[0], len(actual[1]), actual[2])!r}"
                )
            checked += 1

    print(f"PASS: {checked} exact differential cases (seed={args.seed})")


if __name__ == "__main__":
    main()
