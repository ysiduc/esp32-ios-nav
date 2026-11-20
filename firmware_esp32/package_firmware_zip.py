#!/usr/bin/env python3
"""
Package compiled ESP32-S3 PlatformIO firmware.bin into a verified OTA .zip bundle
for the "Hoa hướng dương" iOS and Android mobile apps.

Usage:
  python3 firmware_esp32/package_firmware_zip.py [--bin path/to/firmware.bin] [--version 2.0.0] [--notes "..."] [--out path/to/output.zip]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

ESP_IMAGE_MAGIC = 0xE9
ESP32_S3_CHIP_ID = 9
MAX_OTA_SLOT_BYTES = 0x330000  # 3,342,336 bytes (default_8MB.csv app0/app1)


def detect_fw_version(main_cpp: Path) -> str:
    if not main_cpp.exists():
        return "2.0.0"
    content = main_cpp.read_text(encoding="utf-8", errors="ignore")
    m = re.search(r'#define\s+FW_VERSION\s+"([^"]+)"', content)
    return m.group(1).strip() if m else "2.0.0"


def main() -> int:
    repo_fw_dir = Path(__file__).resolve().parent
    default_bin = repo_fw_dir / ".pio" / "build" / "esp32-s3" / "firmware.bin"
    default_version = detect_fw_version(repo_fw_dir / "src" / "main.cpp")

    parser = argparse.ArgumentParser(description="Create OTA firmware .zip for ESP32-S3")
    parser.add_argument("--bin", type=Path, default=default_bin, help="Path to firmware.bin")
    parser.add_argument("--version", default=default_version, help="Firmware version label")
    parser.add_argument("--notes", default="Cập nhật firmware Hoa hướng dương ESP32-S3", help="Release notes")
    parser.add_argument("--out", type=Path, default=None, help="Output .zip path")
    args = parser.parse_args()

    bin_path: Path = args.bin
    if not bin_path.is_file():
        print(f"ERROR: firmware binary not found at {bin_path}", file=sys.stderr)
        print("Run `pio run -e esp32-s3` inside firmware_esp32 first.", file=sys.stderr)
        return 1

    data = bin_path.read_bytes()
    if len(data) < 65536 or len(data) > MAX_OTA_SLOT_BYTES:
        print(f"ERROR: invalid firmware size ({len(data)} bytes)", file=sys.stderr)
        return 1
    if data[0] != ESP_IMAGE_MAGIC:
        print(f"ERROR: invalid ESP image magic 0x{data[0]:02x} (expected 0xE9)", file=sys.stderr)
        return 1
    chip_id = int.from_bytes(data[12:14], "little")
    if chip_id != ESP32_S3_CHIP_ID:
        print(f"ERROR: unexpected chip_id {chip_id} (expected {ESP32_S3_CHIP_ID} for ESP32-S3)", file=sys.stderr)
        return 1

    md5_hex = hashlib.md5(data).hexdigest()
    safe_ver = re.sub(r"[^0-9A-Za-z._-]+", "_", args.version.strip()) or "2.0.0"
    out_path: Path = args.out or (repo_fw_dir / "dist" / f"hoa_huong_duong_v{safe_ver}.zip")
    out_path.parent.mkdir(parents=True, exist_ok=True)

    manifest = {
        "name": "Hoa hướng dương",
        "board": "esp32-s3",
        "version": args.version.strip(),
        "file": "firmware.bin",
        "size": len(data),
        "md5": md5_hex,
        "built_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "notes": args.notes.strip(),
    }

    with zipfile.ZipFile(out_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        zf.writestr("manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
        zf.writestr("firmware.bin", data)

    print(f"Created OTA package: {out_path}")
    print(f"  Version : {manifest['version']}")
    print(f"  Size    : {len(data):,} bytes ({len(data)/1024:.1f} KB)")
    print(f"  ZIP size: {out_path.stat().st_size:,} bytes ({out_path.stat().st_size/1024:.1f} KB)")
    print(f"  MD5     : {md5_hex}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

