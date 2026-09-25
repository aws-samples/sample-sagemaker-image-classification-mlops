# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Extract model archives without path traversal."""

from __future__ import annotations

import os
import tarfile


def safe_extract_member(tar: tarfile.TarFile, member: tarfile.TarInfo, dest: str) -> str:
    """Extract one regular-file member inside dest; returns the extracted path.

    Rejects members that resolve outside dest (``../``, absolute paths), links
    and anything that is not a regular file (CVE-2007-4559).
    """
    dest_real = os.path.realpath(dest)
    target = os.path.realpath(os.path.join(dest, member.name))
    if not target.startswith(dest_real + os.sep):
        raise ValueError(f"Unsafe tar member path: {member.name}")
    if member.issym() or member.islnk():
        raise ValueError(f"Link member not allowed in archive: {member.name}")
    if not member.isreg():
        raise ValueError(f"Non-regular member not allowed in archive: {member.name}")
    tar.extract(member, dest)
    return target


def find_model_file(model_path: str, suffix: str = ".h5") -> str | None:
    """First ``*.h5`` under model_path, extracting it from model.tar.gz if needed."""
    for root, _dirs, files in os.walk(model_path):
        for name in files:
            if name.endswith(suffix):
                return os.path.join(root, name)
        if "model.tar.gz" in files:
            with tarfile.open(os.path.join(root, "model.tar.gz"), "r:gz") as tar:
                for member in tar.getmembers():
                    if member.name.endswith(suffix):
                        return safe_extract_member(tar, member, root)
    return None
