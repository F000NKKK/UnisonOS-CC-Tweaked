#!/usr/bin/env python3
"""Compute SHA256 of every file referenced in manifest.json's role lists,
embed them into manifest.json under a top-level 'checksums' map.

Run after editing files / before commit. The os_updater on each device
fetches the manifest, hashes its local copies, and only re-downloads
files whose hash differs (or is missing). Whole-OS reinstalls become
delta-only updates.

Usage:
    python tools/build-manifest.py
    python tools/build-manifest.py --check    # exit non-zero if stale
"""
from __future__ import annotations
import argparse, hashlib, json, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "manifest.json"


def sha256_file(p: pathlib.Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def collect_files(manifest: dict) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for role, files in (manifest.get("roles") or {}).items():
        for rel in files or []:
            if rel in seen:
                continue
            seen.add(rel)
            out.append(rel)
    return out


def compute_checksums(manifest: dict) -> dict[str, str]:
    csums: dict[str, str] = {}
    for rel in collect_files(manifest):
        p = ROOT / rel
        if not p.is_file():
            print(f"WARN: missing {rel}", file=sys.stderr)
            continue
        csums[rel] = sha256_file(p)
    return csums


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="exit non-zero if checksums are out of date")
    args = ap.parse_args()

    manifest = json.loads(MANIFEST.read_text())
    new = compute_checksums(manifest)
    old = manifest.get("checksums") or {}

    if args.check:
        if old != new:
            diff = sum(1 for k in new if old.get(k) != new[k])
            extra = sum(1 for k in old if k not in new)
            print(f"manifest checksums stale: {diff} changed/added, "
                  f"{extra} removed", file=sys.stderr)
            return 1
        print("manifest checksums up to date.")
        return 0

    manifest["checksums"] = new
    MANIFEST.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"wrote checksums for {len(new)} files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
