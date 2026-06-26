#!/usr/bin/env python3
"""Download public Git LFS pointer files in-place.

This is used for source asset packs where a public repository was cloned
without `git-lfs` installed. It talks to the repository LFS batch endpoint and
replaces pointer files with their real bytes.
"""

from __future__ import annotations

import argparse
import json
import re
import urllib.request
from pathlib import Path


POINTER_RE = re.compile(
    r"^version https://git-lfs.github.com/spec/v1\n"
    r"oid sha256:([0-9a-f]{64})\n"
    r"size ([0-9]+)\n?$"
)


def _pointer(path: Path) -> tuple[str, int] | None:
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return None
    match = POINTER_RE.match(text)
    if not match:
        return None
    return match.group(1), int(match.group(2))


def _batch(repo_lfs_url: str, objects: list[dict[str, object]]) -> dict[str, str]:
    body = json.dumps(
        {
            "operation": "download",
            "transfers": ["basic"],
            "objects": objects,
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        repo_lfs_url.rstrip("/") + "/objects/batch",
        data=body,
        headers={
            "Accept": "application/vnd.git-lfs+json",
            "Content-Type": "application/vnd.git-lfs+json",
        },
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    downloads: dict[str, str] = {}
    for item in data.get("objects", []):
        oid = item.get("oid")
        href = (item.get("actions") or {}).get("download", {}).get("href")
        if oid and href:
            downloads[str(oid)] = str(href)
    return downloads


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument(
        "--repo-lfs-url",
        required=True,
        help="Example: https://github.com/owner/repo.git/info/lfs",
    )
    parser.add_argument("--only", action="append", default=[], help="Relative path prefix to include")
    args = parser.parse_args()

    root = args.root.resolve()
    prefixes = [p.strip("/") for p in args.only]
    entries: list[tuple[Path, str, int]] = []
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(root).as_posix()
        if prefixes and not any(rel.startswith(prefix) for prefix in prefixes):
            continue
        pointer = _pointer(path)
        if pointer:
            entries.append((path, pointer[0], pointer[1]))

    if not entries:
        print("no git-lfs pointers found")
        return 0

    for start in range(0, len(entries), 100):
        chunk = entries[start : start + 100]
        downloads = _batch(
            args.repo_lfs_url,
            [{"oid": oid, "size": size} for _, oid, size in chunk],
        )
        for path, oid, expected_size in chunk:
            url = downloads.get(oid)
            if not url:
                raise SystemExit(f"missing download URL for {path}")
            with urllib.request.urlopen(url, timeout=120) as resp:
                data = resp.read()
            if len(data) != expected_size:
                raise SystemExit(
                    f"size mismatch for {path}: got {len(data)}, expected {expected_size}"
                )
            path.write_bytes(data)
            print(f"downloaded {path.relative_to(root)}")

    print(f"downloaded {len(entries)} git-lfs files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
