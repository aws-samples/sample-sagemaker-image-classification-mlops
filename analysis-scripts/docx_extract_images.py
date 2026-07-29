#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import re
from pathlib import Path

from docx import Document
from docx.oxml.ns import qn

BLOG_DIR = Path("blog_docs")


def find_part_docs() -> dict[int, Path]:
    """Map part number → docx path, scanning blog_docs/."""
    parts: dict[int, Path] = {}
    for docx in BLOG_DIR.glob("Part*.docx"):
        match = re.match(r"Part(\d+)", docx.name)
        if match:
            parts[int(match.group(1))] = docx
    return dict(sorted(parts.items()))


def extract_images(docx_path: Path, part_num: int, out_dir: Path) -> int:
    """Extract every inline image from docx_path into out_dir, naming them
    Part_<part_num>_figure_<idx>.<ext> in document order."""
    out_dir.mkdir(parents=True, exist_ok=True)

    # Clear any previous extraction so reruns are clean.
    for existing in out_dir.glob(f"Part_{part_num}_figure_*"):
        existing.unlink()

    doc = Document(str(docx_path))
    count = 0
    for idx, shape in enumerate(doc.inline_shapes, start=1):
        blip = shape._inline.graphic.graphicData.pic.blipFill.blip
        r_id = blip.get(qn("r:embed"))
        rel = doc.part.related_parts[r_id]

        # content_type is like "image/png" / "image/jpeg" / "image/x-emf"
        ext_map = {
            "image/png": "png",
            "image/jpeg": "jpg",
            "image/jpg": "jpg",
            "image/gif": "gif",
            "image/bmp": "bmp",
            "image/tiff": "tif",
            "image/x-emf": "emf",
            "image/x-wmf": "wmf",
            "image/svg+xml": "svg",
        }
        ext = ext_map.get(rel.content_type, rel.content_type.split("/")[-1])

        out_path = out_dir / f"Part_{part_num}_figure_{idx}.{ext}"
        out_path.write_bytes(rel.blob)
        count += 1
        print(f"  {out_path.name:40s} {len(rel.blob):>10,} bytes  ← {rel.partname}")

    return count


def main() -> int:
    if not BLOG_DIR.is_dir():
        print(f"ERROR: {BLOG_DIR} not found")
        return 1

    parts = find_part_docs()
    if not parts:
        print(f"ERROR: no Part<N>*.docx files under {BLOG_DIR}")
        return 1

    total = 0
    for part_num, docx_path in parts.items():
        out_dir = BLOG_DIR / f"part{part_num}"
        print(f"\n=== Part {part_num}: {docx_path.name} → {out_dir}/ ===")
        n = extract_images(docx_path, part_num, out_dir)
        print(f"  → {n} images extracted")
        total += n

    print(f"\nTotal images extracted: {total}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
