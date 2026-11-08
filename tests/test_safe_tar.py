# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Model archives are extracted without path traversal or links."""

import io
import tarfile

import pytest
from mlops_common.safe_tar import find_model_file, safe_extract_member


def _archive(path, members):
    with tarfile.open(path, "w:gz") as tar:
        for info, data in members:
            tar.addfile(info, io.BytesIO(data) if data is not None else None)


def _file(name, data=b"weights"):
    info = tarfile.TarInfo(name)
    info.size = len(data)
    return info, data


def test_model_file_is_found_inside_the_archive(tmp_path):
    _archive(tmp_path / "model.tar.gz", [_file("vgg16_model.h5")])
    found = find_model_file(str(tmp_path))
    assert found == str((tmp_path / "vgg16_model.h5").resolve())
    assert (tmp_path / "vgg16_model.h5").read_bytes() == b"weights"


@pytest.mark.parametrize("name", ["../escape.h5", "/abs/escape.h5"])
def test_traversal_is_rejected(tmp_path, name):
    archive = tmp_path / "a.tar.gz"
    _archive(archive, [_file(name)])
    with tarfile.open(archive) as tar, pytest.raises(ValueError, match="Unsafe"):
        safe_extract_member(tar, tar.getmembers()[0], str(tmp_path / "out"))


def test_links_are_rejected(tmp_path):
    link = tarfile.TarInfo("model.h5")
    link.type = tarfile.SYMTYPE
    link.linkname = "/etc/passwd"
    archive = tmp_path / "a.tar.gz"
    _archive(archive, [(link, None)])
    with tarfile.open(archive) as tar, pytest.raises(ValueError, match="Link"):
        safe_extract_member(tar, tar.getmembers()[0], str(tmp_path / "out"))
