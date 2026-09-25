# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

from botocore.stub import ANY, Stubber
from conftest import load_module

baseline = load_module("stack-cicd/scripts/create_baseline_model.py", "create_baseline_model")


def test_baseline_registers_pending_with_placeholder_marker():
    with Stubber(baseline.sagemaker_client) as stub:
        stub.add_response(
            "create_model_package",
            {"ModelPackageArn": "arn:aws:sagemaker:us-east-1:111122223333:model-package/g/1"},
            {
                "ModelPackageGroupName": "group",
                "ModelPackageDescription": ANY,
                "ModelApprovalStatus": "PendingManualApproval",
                "CustomerMetadataProperties": {
                    "ModelRole": "placeholder-baseline",
                    "ClinicalUse": "none",
                },
                "InferenceSpecification": ANY,
            },
        )
        arn = baseline.register_baseline_model("s3://b/k.tar.gz", "group", "image:tag")
    assert arn.endswith("/1")


def test_existing_pending_package_skips_creation():
    with Stubber(baseline.sagemaker_client) as stub:
        stub.add_response("list_model_packages", {"ModelPackageSummaryList": []})
        stub.add_response(
            "list_model_packages",
            {
                "ModelPackageSummaryList": [
                    {
                        "ModelPackageArn": "arn:aws:sagemaker:us-east-1:111122223333:model-package/g/1",
                        "ModelPackageName": "g",
                        "CreationTime": "2026-09-25T00:00:00Z",
                        "ModelPackageStatus": "Completed",
                        "ModelApprovalStatus": "PendingManualApproval",
                    }
                ]
            },
        )
        found = baseline.existing_model_package("group")
    assert found["ModelApprovalStatus"] == "PendingManualApproval"
