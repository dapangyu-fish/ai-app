#!/usr/bin/env python3
"""Enrich hosted asset-pack manifests with image/sprite metadata.

Examples:
  python3 scripts/enrich_asset_pack_manifest.py \
    https://.../json-app-assets/asset-packs/kenney-new-platformer-pack/1.1/manifest.json \
    --output /tmp/manifest.json

  python3 scripts/enrich_asset_pack_manifest.py <manifest-url> --upload
"""

from __future__ import annotations

import argparse
import io
import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
BACKEND_DIR = REPO_ROOT / "backend"
sys.path.insert(0, str(BACKEND_DIR))

from asset_manifest_metadata import ASSET_PACK_MARKER, enrich_manifest  # noqa: E402


def fetch_bytes(url: str) -> bytes:
    headers = {"User-Agent": "ai-app-asset-manifest-enrich/1"}
    if url.split("?", 1)[0].lower().endswith(".png"):
        headers["Range"] = "bytes=0-31"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=12) as response:
        return response.read()


def object_location_from_manifest_url(manifest_url: str) -> tuple[str, str]:
    parsed = urllib.parse.urlsplit(manifest_url)
    marker = parsed.path.find(ASSET_PACK_MARKER)
    if marker < 0:
        raise ValueError(f"manifest URL is not under {ASSET_PACK_MARKER}: {manifest_url}")
    bucket = "json-app-assets"
    key = parsed.path[marker + len("/json-app-assets/") :].lstrip("/")
    return bucket, key


def upload_manifest(manifest_url: str, data: bytes) -> None:
    from minio import Minio
    from config import MINIO_ACCESS_KEY, MINIO_ENDPOINT, MINIO_SECRET_KEY, MINIO_SECURE

    bucket, key = object_location_from_manifest_url(manifest_url)
    client = Minio(
        MINIO_ENDPOINT,
        access_key=MINIO_ACCESS_KEY,
        secret_key=MINIO_SECRET_KEY,
        secure=MINIO_SECURE,
    )
    client.put_object(
        bucket,
        key,
        io.BytesIO(data),
        len(data),
        content_type="application/json",
    )
    print(f"uploaded {bucket}/{key} ({len(data)} bytes)")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", help="manifest URL or local path")
    parser.add_argument("--output", "-o", type=Path)
    parser.add_argument("--upload", action="store_true", help="upload back to MinIO using backend env")
    args = parser.parse_args(argv)

    if args.manifest.startswith(("http://", "https://")):
        manifest_url = args.manifest
        raw = fetch_bytes(args.manifest)
    else:
        manifest_url = ""
        raw = Path(args.manifest).read_bytes()

    manifest = json.loads(raw.decode("utf-8"))
    enriched = enrich_manifest(manifest, fetch_bytes)
    data = json.dumps(enriched, ensure_ascii=False, indent=2).encode("utf-8")

    if args.output:
        args.output.write_bytes(data)
        print(f"wrote {args.output} ({len(data)} bytes)")
    else:
        sys.stdout.buffer.write(data)

    if args.upload:
        if not manifest_url:
            raise SystemExit("--upload requires an http(s) manifest URL")
        upload_manifest(manifest_url, data)

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
