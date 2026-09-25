# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""The auto-deploy Lambda writes the drift baseline that compute_drift reads."""

import json

import boto3
import pytest
from botocore.stub import Stubber
from conftest import load_module
from moto import mock_aws

handler = load_module("modules/terraform-aws-auto-deployment/auto_deploy_handler.py", "auto_deploy")
drift = load_module("scripts/drift/compute_drift.py", "compute_drift_for_baseline")

ARN = "arn:aws:sagemaker:us-east-1:111122223333:model-package/example-group/3"
ARTIFACTS = "example-model-artifacts"
MONITORING = "example-monitoring"
KEY = handler.DEFAULT_DRIFT_BASELINE_KEY


@pytest.fixture
def clients(monkeypatch):
    with mock_aws():
        s3 = boto3.client("s3", region_name="us-east-1")
        for bucket in (ARTIFACTS, MONITORING):
            s3.create_bucket(Bucket=bucket)
        sm = boto3.client("sagemaker", region_name="us-east-1")
        stub = Stubber(sm)
        monkeypatch.setattr(handler, "s3", s3)
        monkeypatch.setattr(handler, "sm", sm)
        with stub:
            yield s3, stub


def _describe(stub, model_data_url):
    stub.add_response(
        "describe_model_package",
        {
            "ModelPackageName": "example-group",
            "ModelPackageArn": ARN,
            "CreationTime": "2026-09-25T00:00:00Z",
            "ModelPackageStatus": "Completed",
            "ModelPackageStatusDetails": {"ValidationStatuses": []},
            "InferenceSpecification": {
                "Containers": [{"Image": "example", "ModelDataUrl": model_data_url}],
                "SupportedContentTypes": ["application/json"],
                "SupportedResponseMIMETypes": ["application/json"],
            },
        },
        {"ModelPackageName": ARN},
    )


def test_writes_scores_the_drift_job_can_read(clients):
    s3, stub = clients
    scores = [0.1, 0.4, 0.9, 0.95]
    s3.put_object(
        Bucket=ARTIFACTS,
        Key="ensemble/exec-1/predictions.json",
        Body=json.dumps({"scores": scores, "labels": [0, 0, 1, 1]}),
    )
    _describe(stub, f"s3://{ARTIFACTS}/ensemble/exec-1/model.tar.gz")

    uri = handler.publish_drift_baseline(ARN, MONITORING)

    assert uri == f"s3://{MONITORING}/{KEY}"
    doc = json.loads(s3.get_object(Bucket=MONITORING, Key=KEY)["Body"].read())
    assert doc["scores"] == scores
    assert doc["model_package_arn"] == ARN
    # The drift job's own loader accepts what the Lambda wrote.
    assert drift._load_baseline(s3, MONITORING, KEY) == scores


def test_package_without_predictions_leaves_baseline_alone(clients):
    s3, stub = clients
    s3.put_object(Bucket=MONITORING, Key=KEY, Body=json.dumps({"scores": [0.5]}))
    _describe(stub, f"s3://{ARTIFACTS}/baseline/model.tar.gz")

    assert handler.publish_drift_baseline(ARN, MONITORING) is None
    doc = json.loads(s3.get_object(Bucket=MONITORING, Key=KEY)["Body"].read())
    assert doc == {"scores": [0.5]}


def test_errors_never_raise(clients):
    _, stub = clients
    stub.add_client_error("describe_model_package", service_error_code="ValidationException")

    assert handler.publish_drift_baseline(ARN, MONITORING) is None


def test_no_monitoring_bucket_is_a_no_op():
    assert handler.publish_drift_baseline(ARN, "") is None
