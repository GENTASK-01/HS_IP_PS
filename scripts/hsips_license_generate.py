#!/usr/bin/env python3
"""
HS_IP_PS Offline License Generator

Creates encrypted .lic files for the HS_IP_PS runtime license module.

Encryption = XOR keystream built on the custom HSIPS_Hash256 (identical to the
MQL5 template's HSIPS_StreamXor). No external AES, no OpenSSL dependency.
Uses only the Python standard library.
"""

import argparse
import json
import os
import secrets
import struct
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

MASK = (1 << 64) - 1


def rotl64(value: int, shift: int) -> int:
    if shift <= 0:
        return value & MASK
    if shift >= 64:
        return value & MASK
    return ((value << shift) | (value >> (64 - shift))) & MASK


def hsips_hash256(data: bytes) -> bytes:
    """MUST stay byte-identical to the MQL5 template's HSIPS_Hash256."""
    l0 = 0x9E3779B97F4A7C15
    l1 = 0xC2B2AE3D27D4EB4F
    l2 = 0x165667B19E3779F9
    l3 = 0x27D4EB2F165667C5

    p0 = 0x100000001B3
    p1 = 0xC2B2AE3D27D4EB4F
    p2 = 0x9E3779B97F4A7C15
    p3 = 0x84222325CBF29CE7

    for b in data:
        l0 = ((l0 ^ b) * p0) & MASK
        l1 = ((l1 ^ ((b + 0x9E) & 0xFF)) * p1) & MASK
        l2 = ((l2 ^ ((b + 0xC2) & 0xFF)) * p2) & MASK
        l3 = ((l3 ^ ((b + 0x7F) & 0xFF)) * p3) & MASK

        t = (l0 + l1 + l2 + l3) & MASK

        l0 = (l0 ^ rotl64(t, 13)) & MASK
        l1 = (l1 ^ rotl64(t, 29)) & MASK
        l2 = (l2 ^ rotl64(t, 41)) & MASK
        l3 = (l3 ^ rotl64(t, 53)) & MASK

    for _ in range(64):
        x = (l0 + l1) & MASK
        y = (l2 + l3) & MASK

        l0 = (rotl64((l0 ^ x) & MASK, 17) + y) & MASK
        l1 = (rotl64((l1 ^ y) & MASK, 23) + x) & MASK
        l2 = (rotl64((l2 ^ x) & MASK, 31) + y) & MASK
        l3 = (rotl64((l3 ^ y) & MASK, 37) + x) & MASK

    out = bytearray()
    for value in (l0, l1, l2, l3):
        out += struct.pack("<Q", value)
    return bytes(out)


def hsips_stream_xor(key: bytes, data: bytes) -> bytes:
    """Symmetric XOR keystream cipher. MUST match MQL5 HSIPS_StreamXor."""
    out = bytearray()
    blk = 0
    while blk * 16 < len(data):
        counter = struct.pack("<I", blk)
        h = hsips_hash256(key + counter)  # 32 bytes
        base = blk * 16
        for k in range(16):
            if base + k >= len(data):
                break
            out.append(data[base + k] ^ h[k])
        blk += 1
    return bytes(out)


def derive_key(secret: bytes, product_uuid_bytes: bytes, login: int, server: str) -> bytes:
    server_bytes = server.encode("utf-8")
    buffer = b"".join([
        secret,
        product_uuid_bytes,
        struct.pack("<Q", login),
        server_bytes
    ])
    return hsips_hash256(buffer)


def write_fixed_string(payload: bytearray, offset: int, size: int, text: str) -> None:
    text_bytes = text.encode("utf-8")
    if len(text_bytes) > size:
        text_bytes = text_bytes[:size]
    payload[offset:offset + len(text_bytes)] = text_bytes


def build_payload(args, product_uuid_bytes: bytes):
    payload = bytearray(256)

    payload[0:4] = b"PL1\x00"
    payload[4:8] = struct.pack("<I", 1)

    license_id = uuid.uuid4().bytes
    payload[8:24] = license_id

    payload[24:40] = product_uuid_bytes

    issued_unix = args.issued_unix
    if issued_unix <= 0:
        issued_unix = int(datetime.now(timezone.utc).timestamp())

    payload[40:48] = struct.pack("<Q", issued_unix)
    payload[48:56] = struct.pack("<Q", args.expiry_unix)
    payload[56:64] = struct.pack("<Q", args.login)
    payload[64:68] = struct.pack("<I", args.max_accounts)
    payload[68:72] = struct.pack("<I", args.flags)

    write_fixed_string(payload, 72, 64, args.server)
    write_fixed_string(payload, 136, 64, args.broker)

    nonce = secrets.token_bytes(16)
    payload[200:216] = nonce

    checksum = hsips_hash256(bytes(payload[:216]))
    payload[216:248] = checksum

    return bytes(payload), license_id, issued_unix


def ensure_within_root(root: Path, path: Path) -> None:
    try:
        path.resolve().relative_to(root.resolve())
    except ValueError:
        raise ValueError(f"HS_IP_PS path guard blocked path outside root: {path}")


def main():
    parser = argparse.ArgumentParser(description="HS_IP_PS offline license generator")

    parser.add_argument("--product-code", required=True)
    parser.add_argument("--product-uuid", required=True)
    parser.add_argument("--secret-file", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--login", required=True, type=int)
    parser.add_argument("--server", required=True)
    parser.add_argument("--broker", default="")
    parser.add_argument("--flags", required=True, type=int)
    parser.add_argument("--expiry-unix", required=True, type=int)
    parser.add_argument("--issued-unix", default=0, type=int)
    parser.add_argument("--max-accounts", default=1, type=int)
    parser.add_argument("--output", required=True)
    parser.add_argument("--log-dir", required=True)

    args = parser.parse_args()

    root = Path(args.root)
    secret_path = Path(args.secret_file)
    output_path = Path(args.output)
    log_dir = Path(args.log_dir)

    try:
        ensure_within_root(root, secret_path)
        ensure_within_root(root, output_path)
        ensure_within_root(root, log_dir)
    except Exception as ex:
        print(f"ERROR: {ex}")
        return 1

    if not secret_path.exists():
        print(f"ERROR: secret file not found: {secret_path}")
        return 1

    secret = secret_path.read_bytes()

    if len(secret) != 32:
        print("ERROR: product secret must be exactly 32 bytes.")
        return 1

    try:
        product_uuid = uuid.UUID(args.product_uuid)
    except Exception:
        print("ERROR: product-uuid is not a valid UUID.")
        return 1

    product_uuid_bytes = product_uuid.bytes

    payload, license_id, issued_unix = build_payload(args, product_uuid_bytes)

    key = derive_key(secret, product_uuid_bytes, args.login, args.server)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)

    encrypted = hsips_stream_xor(key, payload)

    license_bytes = b"".join([
        b"HSPL",
        struct.pack("<I", 1),
        encrypted
    ])

    output_path.write_bytes(license_bytes)

    log_record = {
        "schema_version": 1,
        "generated_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "product_code": args.product_code,
        "product_uuid": str(product_uuid),
        "license_id": license_id.hex(),
        "login": args.login,
        "server": args.server,
        "broker": args.broker,
        "flags": args.flags,
        "issued_unix": issued_unix,
        "expiry_unix": args.expiry_unix,
        "max_accounts": args.max_accounts,
        "output_file": str(output_path)
    }

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_path = log_dir / f"license_generation_{args.product_code}_{timestamp}.json"

    log_path.write_text(json.dumps(log_record, indent=2), encoding="utf-8")

    print("HS_IP_PS license generated successfully.")
    print(f"License file : {output_path}")
    print(f"License ID   : {license_id.hex()}")
    print(f"Login        : {args.login}")
    print(f"Server       : {args.server}")
    print(f"Expiry Unix  : {args.expiry_unix}")
    print(f"Flags        : {args.flags}")
    print(f"Log file     : {log_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
