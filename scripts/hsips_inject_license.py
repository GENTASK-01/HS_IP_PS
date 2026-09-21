#!/usr/bin/env python3
"""
HS_IP_PS License Injector

Injects license runtime module into protected source_work.
Writes only inside the supplied source_work folder.
"""

import argparse
import re
import sys
import uuid
from pathlib import Path

MQL_EXTENSIONS = {".mq5", ".mqh"}

EVENTS = [
    "OnInit",
    "OnDeinit",
    "OnTick",
    "OnTimer",
    "OnTrade",
    "OnTradeTransaction",
    "OnTester",
    "OnChartEvent",
]


def transform_code_outside_strings(text: str, code_transformer):
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


def make_event_renamer():
    patterns = {
        name: re.compile(r"\b" + name + r"\b")
        for name in EVENTS
    }

    def transform(chunk: str) -> str:
        lines = chunk.splitlines(keepends=True)
        out_lines = []

        for line in lines:
            stripped = line.strip()

            if stripped.startswith("#"):
                out_lines.append(line)
                continue

            new_line = line
            for name, pattern in patterns.items():
                new_line = pattern.sub(f"HSIPS_USER_{name}", new_line)

            out_lines.append(new_line)

        return "".join(out_lines)

    return transform


def rename_event_handlers(text: str) -> str:
    transformer = make_event_renamer()
    return transform_code_outside_strings(text, transformer)


def format_c_byte_array(data: bytes) -> str:
    if not data:
        return "0"

    return ",".join(f"0x{b:02X}" for b in data)


def split_secret(secret: bytes):
    if len(secret) != 32:
        raise ValueError("Product secret must be exactly 32 bytes.")

    import secrets

    a = secrets.token_bytes(32)
    b = secrets.token_bytes(32)
    c = secrets.token_bytes(32)

    d = bytes(
        secret[i] ^ a[i] ^ b[i] ^ c[i]
        for i in range(32)
    )

    return a, b, c, d


def render_license_template(
    template_text: str,
    product_code: str,
    product_version: str,
    product_uuid_text: str,
    secret: bytes
):
    product_uuid = uuid.UUID(product_uuid_text)
    uuid_bytes = product_uuid.bytes

    a, b, c, d = split_secret(secret)

    rendered = template_text
    rendered = rendered.replace("__PRODUCT_CODE__", product_code)
    rendered = rendered.replace("__PRODUCT_VERSION__", product_version)
    rendered = rendered.replace("__PRODUCT_UUID_BYTES__", format_c_byte_array(uuid_bytes))
    rendered = rendered.replace("__SECRET_A__", format_c_byte_array(a))
    rendered = rendered.replace("__SECRET_B__", format_c_byte_array(b))
    rendered = rendered.replace("__SECRET_C__", format_c_byte_array(c))
    rendered = rendered.replace("__SECRET_D__", format_c_byte_array(d))

    return rendered


def insert_include(text: str, include_name: str = "HSIPS_LICENSE.mqh") -> str:
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


def detect_user_events(source_root: Path) -> dict:
    found = {name: False for name in EVENTS}
    pattern_map = {
        name: re.compile(r"\bHSIPS_USER_" + name + r"\s*\(")
        for name in EVENTS
    }

    for path in source_root.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in MQL_EXTENSIONS:
            continue

        text = path.read_text(encoding="utf-8", errors="replace")

        for name, pattern in pattern_map.items():
            if pattern.search(text):
                found[name] = True

    return found


def build_wrappers(found: dict) -> str:
    parts = []

    parts.append("")
    parts.append("// ==========================================================")
    parts.append("// HS_IP_PS license wrappers")
    parts.append("// Generated automatically. Do not edit.")
    parts.append("// ==========================================================")
    parts.append("")

    if found.get("OnInit"):
        parts.append("int OnInit()")
        parts.append("{")
        parts.append("   HSIPS_LICENSE_Init();")
        parts.append("")
        parts.append("   if(!HSIPS_LICENSE_IsValid())")
        parts.append("      return INIT_FAILED;")
        parts.append("")
        parts.append("   return HSIPS_USER_OnInit();")
        parts.append("}")
    else:
        parts.append("int OnInit()")
        parts.append("{")
        parts.append("   HSIPS_LICENSE_Init();")
        parts.append("")
        parts.append("   if(!HSIPS_LICENSE_IsValid())")
        parts.append("      return INIT_FAILED;")
        parts.append("")
        parts.append("   return INIT_SUCCEEDED;")
        parts.append("}")

    parts.append("")

    if found.get("OnDeinit"):
        parts.append("void OnDeinit(const int reason)")
        parts.append("{")
        parts.append("   HSIPS_USER_OnDeinit(reason);")
        parts.append("}")
        parts.append("")

    if found.get("OnTick"):
        parts.append("void OnTick()")
        parts.append("{")
        parts.append("   if(!HSIPS_LICENSE_AllowTick())")
        parts.append("      return;")
        parts.append("")
        parts.append("   HSIPS_USER_OnTick();")
        parts.append("}")
        parts.append("")

    if found.get("OnTimer"):
        parts.append("void OnTimer()")
        parts.append("{")
        parts.append("   if(!HSIPS_LICENSE_AllowTick())")
        parts.append("      return;")
        parts.append("")
        parts.append("   HSIPS_USER_OnTimer();")
        parts.append("}")
        parts.append("")

    if found.get("OnTrade"):
        parts.append("void OnTrade()")
        parts.append("{")
        parts.append("   if(!HSIPS_LICENSE_AllowTick())")
        parts.append("      return;")
        parts.append("")
        parts.append("   HSIPS_USER_OnTrade();")
        parts.append("}")
        parts.append("")

    if found.get("OnTradeTransaction"):
        parts.append("void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)")
        parts.append("{")
        parts.append("   if(!HSIPS_LICENSE_AllowTick())")
        parts.append("      return;")
        parts.append("")
        parts.append("   HSIPS_USER_OnTradeTransaction(trans, request, result);")
        parts.append("}")
        parts.append("")

    if found.get("OnTester"):
        parts.append("double OnTester()")
        parts.append("{")
        parts.append("   if(!HSIPS_LICENSE_IsValid())")
        parts.append("      return 0.0;")
        parts.append("")
        parts.append("   return HSIPS_USER_OnTester();")
        parts.append("}")
        parts.append("")

    if found.get("OnChartEvent"):
        parts.append("void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)")
        parts.append("{")
        parts.append("   if(!HSIPS_LICENSE_IsValid())")
        parts.append("      return;")
        parts.append("")
        parts.append("   HSIPS_USER_OnChartEvent(id, lparam, dparam, sparam);")
        parts.append("}")
        parts.append("")

    return "\n".join(parts) + "\n"


def main():
    parser = argparse.ArgumentParser(description="HS_IP_PS license injector")
    parser.add_argument("--source-root", required=True)
    parser.add_argument("--entry", required=True)
    parser.add_argument("--product-code", required=True)
    parser.add_argument("--product-version", required=True)
    parser.add_argument("--product-uuid", required=True)
    parser.add_argument("--secret-file", required=True)
    parser.add_argument("--template", required=True)
    args = parser.parse_args()

    source_root = Path(args.source_root)
    entry_path = source_root / args.entry
    secret_path = Path(args.secret_file)
    template_path = Path(args.template)

    if not source_root.exists():
        print(f"ERROR: source root not found: {source_root}")
        return 1

    if not entry_path.exists():
        print(f"ERROR: entry file not found: {entry_path}")
        return 1

    if not secret_path.exists():
        print(f"ERROR: secret file not found: {secret_path}")
        return 1

    if not template_path.exists():
        print(f"ERROR: template not found: {template_path}")
        return 1

    secret = secret_path.read_bytes()

    if len(secret) != 32:
        print("ERROR: product secret must be exactly 32 bytes.")
        return 1

    template_text = template_path.read_text(encoding="utf-8")

    rendered_license = render_license_template(
        template_text,
        args.product_code,
        args.product_version,
        args.product_uuid,
        secret
    )

    files = [
        p for p in source_root.rglob("*")
        if p.is_file() and p.suffix.lower() in MQL_EXTENSIONS
    ]

    files.sort()

    # Rename event handlers in existing source files.
    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        text = rename_event_handlers(text)
        path.write_text(text, encoding="utf-8", newline="")

    # Write license module after renaming so wrappers/events remain clean.
    license_path = source_root / "HSIPS_LICENSE.mqh"
    license_path.write_text(rendered_license, encoding="utf-8", newline="")

    # Detect renamed user events.
    found = detect_user_events(source_root)

    # Inject include and wrappers into entry file.
    entry_text = entry_path.read_text(encoding="utf-8", errors="replace")
    entry_text = insert_include(entry_text, "HSIPS_LICENSE.mqh")
    entry_text += build_wrappers(found)
    entry_path.write_text(entry_text, encoding="utf-8", newline="")

    print("HS_IP_PS license injection completed.")
    print(f"Entry file       : {entry_path}")
    print(f"License module   : {license_path}")
    print(f"OnInit wrapped   : {found.get('OnInit')}")
    print(f"OnTick wrapped   : {found.get('OnTick')}")
    print(f"OnTimer wrapped  : {found.get('OnTimer')}")
    print(f"OnTrade wrapped  : {found.get('OnTrade')}")
    print(f"OnTester wrapped : {found.get('OnTester')}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
