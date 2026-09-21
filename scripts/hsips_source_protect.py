#!/usr/bin/env python3
"""
HS_IP_PS Source Protection Engine

Functions:
- Strip comments.
- Sanitize metadata properties.
- Obfuscate prefixed identifiers.
- Encrypt selected string literals.
- Generate protected string include files.
- Write audit report.

This script writes only inside the supplied source_work folder and audit folder.
"""

import argparse
import hashlib
import json
import re
import secrets
import sys
from datetime import datetime, timezone
from pathlib import Path

MQL_EXTENSIONS = {".mq5", ".mqh"}

STRING_LITERAL_PATTERN = re.compile(r'"(?:\\.|[^"\\])*"')

SENSITIVE_STRING_PATTERNS = re.compile(
    r"(?i)(password|passwd|secret|token|license|licence|key|salt|hash|"
    r"login|account|server|broker|auth|credential|private|secure|"
    r"http|https|ftp|api|crypt|expire|trial|activation|signature)"
)


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def strip_comments(text: str) -> str:
    """Remove // and /* */ comments while preserving string and char literals."""

    out = []
    i = 0
    n = len(text)
    state = "code"

    while i < n:
        if state == "code":
            if text.startswith("//", i):
                state = "line_comment"
                i += 2
                continue

            if text.startswith("/*", i):
                state = "block_comment"
                i += 2
                continue

            ch = text[i]

            if ch == '"':
                state = "string"
                out.append(ch)
                i += 1
                continue

            if ch == "'":
                state = "char"
                out.append(ch)
                i += 1
                continue

            out.append(ch)
            i += 1
            continue

        if state == "line_comment":
            ch = text[i]
            if ch == "\n":
                state = "code"
                out.append("\n")
            else:
                out.append(" ")
            i += 1
            continue

        if state == "block_comment":
            if text.startswith("*/", i):
                state = "code"
                out.append("  ")
                i += 2
                continue

            ch = text[i]
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue

        if state == "string":
            ch = text[i]
            out.append(ch)

            if ch == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue

            if ch == '"':
                state = "code"

            i += 1
            continue

        if state == "char":
            ch = text[i]
            out.append(ch)

            if ch == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue

            if ch == "'":
                state = "code"

            i += 1
            continue

    return "".join(out)


def escape_mql_string(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def sanitize_properties(text: str, product_name: str) -> str:
    """Remove or neutralize metadata that may reveal developer identity."""

    safe_product = escape_mql_string(product_name or "Protected EA")

    lines = text.splitlines(keepends=True)
    out = []

    for line in lines:
        stripped = line.strip()

        if re.match(r"^#property\s+author\b", stripped, re.IGNORECASE):
            continue

        if re.match(r"^#property\s+link\b", stripped, re.IGNORECASE):
            continue

        if re.match(r"^#property\s+copyright\b", stripped, re.IGNORECASE):
            out.append(f'#property copyright "{safe_product}"\n')
            continue

        if re.match(r"^#property\s+description\b", stripped, re.IGNORECASE):
            continue

        out.append(line)

    return "".join(out)


def parse_string_literal(literal: str) -> str:
    """Parse a simple MQL5/C-like string literal."""

    if len(literal) < 2 or literal[0] != '"' or literal[-1] != '"':
        raise ValueError("Invalid string literal")

    body = literal[1:-1]
    out = []
    i = 0

    while i < len(body):
        ch = body[i]

        if ch == "\\" and i + 1 < len(body):
            nxt = body[i + 1]

            mapping = {
                "n": "\n",
                "t": "\t",
                "r": "\r",
                "\\": "\\",
                '"': '"',
                "'": "'",
                "0": "\0",
            }

            if nxt in mapping:
                out.append(mapping[nxt])
                i += 2
                continue

            if nxt == "x" and i + 3 < len(body):
                hex_text = body[i + 2:i + 4]
                try:
                    out.append(chr(int(hex_text, 16)))
                    i += 4
                    continue
                except ValueError:
                    pass

            out.append(nxt)
            i += 2
            continue

        out.append(ch)
        i += 1

    return "".join(out)


def is_sensitive_string(value: str) -> bool:
    if not value:
        return False

    if len(value.strip()) < 3:
        return False

    if SENSITIVE_STRING_PATTERNS.search(value):
        return True

    if len(value) >= 24 and re.search(r"[A-Za-z0-9_\-]{8,}", value):
        return True

    return False


def transform_code_outside_strings(text: str, code_transformer):
    """Apply code_transformer only to code outside string and char literals."""

    out = []
    buf = []
    i = 0
    n = len(text)
    state = "code"

    def flush():
        if buf:
            out.append(code_transformer("".join(buf)))
            buf.clear()

    while i < n:
        ch = text[i]

        if state == "code":
            if ch == '"':
                flush()
                state = "string"
                out.append(ch)
                i += 1
                continue

            if ch == "'":
                flush()
                state = "char"
                out.append(ch)
                i += 1
                continue

            buf.append(ch)
            i += 1
            continue

        if state == "string":
            out.append(ch)

            if ch == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue

            if ch == '"':
                state = "code"

            i += 1
            continue

        if state == "char":
            out.append(ch)

            if ch == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue

            if ch == "'":
                state = "code"

            i += 1
            continue

    flush()
    return "".join(out)


def make_identifier_transformer(prefix: str, identifier_map: dict, counter: list):
    pattern = re.compile(r"\b" + re.escape(prefix) + r"[A-Za-z0-9_]+\b")

    def repl(match):
        original = match.group(0)

        if original in identifier_map:
            return identifier_map[original]

        new_name = f"hx{counter[0]:05x}"
        counter[0] += 1
        identifier_map[original] = new_name
        return new_name

    def transform(chunk: str) -> str:
        lines = chunk.splitlines(keepends=True)
        out_lines = []

        for line in lines:
            stripped = line.strip()

            if stripped.startswith("#"):
                out_lines.append(line)
            else:
                out_lines.append(pattern.sub(repl, line))

        return "".join(out_lines)

    return transform


def obfuscate_prefixed_identifiers(text: str, prefix: str, identifier_map: dict, counter: list) -> str:
    if not prefix:
        return text

    transformer = make_identifier_transformer(prefix, identifier_map, counter)
    return transform_code_outside_strings(text, transformer)


def encrypt_strings_in_text(text: str, string_table: dict, key: list, mode: str) -> tuple:
    if mode == "none":
        return text, 0

    matches = list(STRING_LITERAL_PATTERN.finditer(text))
    if not matches:
        return text, 0

    # Adjacent string literals (only whitespace between them — comments are
    # already stripped by the pipeline) are C-style concatenation and MUST be
    # kept intact: replacing either side individually breaks compilation
    # (function call adjacent to a literal with no operator). Skip both sides.
    skip = set()
    for i in range(len(matches) - 1):
        gap = text[matches[i].end():matches[i + 1].start()]
        if gap.strip() == "":
            skip.add(i)
            skip.add(i + 1)

    # Map each match to its source line so preprocessor lines and
    # input/sinput/extern declarations stay untouched.
    from bisect import bisect_right
    line_starts = [m.start() for m in re.finditer(r"(?m)^", text)]

    lines_text = text.splitlines(keepends=True)
    line_skip = []
    for ln in lines_text:
        s = ln.strip()
        line_skip.append(
            s.startswith("#") or
            bool(re.search(r"\b(input|sinput|extern)\b", ln, re.IGNORECASE))
        )

    chunks = []
    last = 0
    total = 0

    for i, m in enumerate(matches):
        chunks.append(text[last:m.start()])

        literal = m.group(0)

        do_skip = i in skip
        if not do_skip:
            li = bisect_right(line_starts, m.start()) - 1
            if 0 <= li < len(line_skip) and line_skip[li]:
                do_skip = True

        if do_skip:
            chunks.append(literal)
            last = m.end()
            continue

        try:
            value = parse_string_literal(literal)
        except Exception:
            value = None

        if not value:
            chunks.append(literal)
        elif mode == "sensitive_only" and not is_sensitive_string(value):
            chunks.append(literal)
        else:
            if value not in string_table:
                string_table[value] = len(string_table) + 1
            string_id = string_table[value]
            chunks.append(f"HSIPS_STR({string_id})")
            total += 1

        last = m.end()

    chunks.append(text[last:])
    return "".join(chunks), total


def insert_include_if_missing(text: str, include_name: str = "HSIPS_STRINGS.mqh") -> str:
    include_line = f'#include "{include_name}"\n'

    if include_line.strip() in text:
        return text

    lines = text.splitlines(keepends=True)
    insert_at = 0

    for idx, line in enumerate(lines):
        stripped = line.strip()

        if stripped.startswith("#property"):
            insert_at = idx + 1
        elif stripped and not stripped.startswith("#"):
            break

    lines.insert(insert_at, include_line)
    return "".join(lines)


def generate_key_arrays(length: int = 16):
    key_a = []
    key_b = []
    key = []

    for _ in range(length):
        a = secrets.randbelow(0x10000)
        b = secrets.randbelow(0x10000)
        k = (a ^ b) & 0xFFFF

        key_a.append(a)
        key_b.append(b)
        key.append(k)

    return key_a, key_b, key


def string_to_encrypted_ushort_array(value: str, key: list) -> list:
    raw = value.encode("utf-16-le")
    values = []

    for i in range(0, len(raw), 2):
        chunk = raw[i:i + 2]
        if len(chunk) < 2:
            chunk = chunk + b"\x00"

        original = int.from_bytes(chunk, "little")
        encrypted = original ^ key[(i // 2) % len(key)]
        values.append(encrypted & 0xFFFF)

    return values


def format_ushort_array(values: list, columns: int = 12) -> str:
    if not values:
        return "0"

    rows = []
    for i in range(0, len(values), columns):
        chunk = values[i:i + columns]
        rows.append(",".join(str(v) for v in chunk))

    return ",\n    ".join(rows)


def generate_strings_include(string_table: dict, key_a: list, key_b: list) -> str:
    lines = []

    lines.append("#ifndef HSIPS_STRINGS_MQH")
    lines.append("#define HSIPS_STRINGS_MQH")
    lines.append("")
    lines.append("// Generated by HS_IP_PS. Do not edit.")
    lines.append("// This file is generated into source_work only.")
    lines.append("")

    lines.append("const ushort HSIPS_KA[] =")
    lines.append("{")
    lines.append("    " + format_ushort_array(key_a))
    lines.append("};")
    lines.append("")

    lines.append("const ushort HSIPS_KB[] =")
    lines.append("{")
    lines.append("    " + format_ushort_array(key_b))
    lines.append("};")
    lines.append("")

    lines.append("ushort HSIPS_Key(const int pos)")
    lines.append("{")
    lines.append("   const int key_size = ArraySize(HSIPS_KA);")
    lines.append("   const int idx = pos % key_size;")
    lines.append("   return (ushort)(HSIPS_KA[idx] ^ HSIPS_KB[idx]);")
    lines.append("}")
    lines.append("")

    lines.append("string HSIPS_DecryptPayload(const ushort &data[])")
    lines.append("{")
    lines.append("   const int total = ArraySize(data);")
    lines.append("   ushort temp[];")
    lines.append("   ArrayResize(temp, total);")
    lines.append("")
    lines.append("   for(int i = 0; i < total; i++)")
    lines.append("   {")
    lines.append("      temp[i] = (ushort)(data[i] ^ HSIPS_Key(i));")
    lines.append("   }")
    lines.append("")
    lines.append("   return ShortArrayToString(temp);")
    lines.append("}")
    lines.append("")

    for value, string_id in sorted(string_table.items(), key=lambda item: item[1]):
        encrypted = string_to_encrypted_ushort_array(value, [a ^ b for a, b in zip(key_a, key_b)])
        array_name = f"HSIPS_S{string_id:04d}"

        lines.append(f"const ushort {array_name}[] =")
        lines.append("{")
        lines.append("    " + format_ushort_array(encrypted))
        lines.append("};")
        lines.append("")

    lines.append("string HSIPS_STR(const int id)")
    lines.append("{")
    lines.append("   switch(id)")
    lines.append("   {")

    for value, string_id in sorted(string_table.items(), key=lambda item: item[1]):
        array_name = f"HSIPS_S{string_id:04d}"
        lines.append(f"      case {string_id}: return HSIPS_DecryptPayload({array_name});")

    lines.append("      default: return \"\";")
    lines.append("   }")
    lines.append("}")
    lines.append("")
    lines.append("#endif")
    lines.append("")

    return "\n".join(lines)


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8-sig")
    except UnicodeDecodeError:
        return path.read_text(encoding="utf-16", errors="replace")


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="")


def main():
    parser = argparse.ArgumentParser(description="HS_IP_PS source protection engine")
    parser.add_argument("--source-root", required=True)
    parser.add_argument("--entry", required=True)
    parser.add_argument("--product-code", required=True)
    parser.add_argument("--product-name", default="Protected EA")
    parser.add_argument("--prefix", default="")
    parser.add_argument("--string-mode", choices=["none", "sensitive_only", "all"], default="none")
    parser.add_argument("--audit-dir", required=True)
    args = parser.parse_args()

    source_root = Path(args.source_root)
    audit_dir = Path(args.audit_dir)

    if not source_root.exists():
        print(f"ERROR: source root not found: {source_root}")
        return 1

    entry_path = source_root / args.entry
    if not entry_path.exists():
        print(f"ERROR: entry file not found: {entry_path}")
        return 1

    if args.prefix:
        if not re.match(r"^[A-Z][A-Z0-9]{1,11}_$", args.prefix):
            print("ERROR: prefix must be 3-12 chars, start with A-Z, use A-Z0-9, and end with underscore.")
            return 1

    key_a, key_b, key = generate_key_arrays(16)

    identifier_map = {}
    identifier_counter = [1]
    string_table = {}

    files = [p for p in source_root.rglob("*") if p.is_file() and p.suffix.lower() in MQL_EXTENSIONS]
    files.sort()

    file_reports = []
    include_dirs = set()

    for path in files:
        original_text = read_text(path)
        original_hash = sha256_text(original_text)

        text = strip_comments(original_text)
        text = sanitize_properties(text, args.product_name)

        if args.prefix:
            text = obfuscate_prefixed_identifiers(text, args.prefix, identifier_map, identifier_counter)

        text, string_count = encrypt_strings_in_text(text, string_table, key, args.string_mode)

        used_strings = string_count > 0

        if used_strings:
            text = insert_include_if_missing(text)
            include_dirs.add(path.parent)

        write_text(path, text)

        file_reports.append({
            "path": str(path.relative_to(source_root)),
            "original_sha256": original_hash,
            "protected_sha256": sha256_text(text),
            "strings_encrypted": string_count,
            "identifier_renames_applied": bool(args.prefix)
        })

    if string_table:
        include_text = generate_strings_include(string_table, key_a, key_b)

        for directory in include_dirs:
            include_path = directory / "HSIPS_STRINGS.mqh"
            write_text(include_path, include_text)

    audit_dir.mkdir(parents=True, exist_ok=True)

    string_audit = {}
    for value, string_id in string_table.items():
        string_audit[str(string_id)] = {
            "sha256": sha256_text(value),
            "length": len(value)
        }

    report = {
        "schema_version": 1,
        "product_code": args.product_code,
        "generated_utc": utc_now(),
        "source_root": str(source_root),
        "entry_file": args.entry,
        "prefix_mode": bool(args.prefix),
        "prefix": args.prefix,
        "string_mode": args.string_mode,
        "identifier_count": len(identifier_map),
        "string_count": len(string_table),
        "files": file_reports,
        "identifier_map": identifier_map,
        "string_map": string_audit,
        "key_sha256": sha256_text(json.dumps(key, separators=(",", ":")))
    }

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    report_path = audit_dir / f"source_protection_{args.product_code}_{timestamp}.json"
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print("HS_IP_PS source protection completed.")
    print(f"Files processed        : {len(file_reports)}")
    print(f"Identifiers obfuscated : {len(identifier_map)}")
    print(f"Strings encrypted      : {len(string_table)}")
    print(f"Report                 : {report_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
