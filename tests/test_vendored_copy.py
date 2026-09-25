# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

from conftest import ROOT


def test_lambda_copy_of_mlops_common_is_identical():
    src = ROOT / "scripts" / "mlops_common"
    dst = ROOT / "stack-inference" / "lambda" / "mlops_common"
    src_files = sorted(p.name for p in src.glob("*.py"))
    dst_files = sorted(p.name for p in dst.glob("*.py"))
    assert src_files == dst_files, "run scripts/sync_mlops_common.sh"
    for name in src_files:
        assert (src / name).read_bytes() == (dst / name).read_bytes(), (
            f"{name} differs; run scripts/sync_mlops_common.sh"
        )
