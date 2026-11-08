# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import json
from datetime import UTC, datetime

import boto3
from botocore.stub import Stubber
from conftest import load_module

refresher = load_module("stack-inference/lambda/endpoint_refresher.py", "endpoint_refresher")

ENDPOINT = "image-classification-endpoint"
NOW = datetime(2026, 9, 25, tzinfo=UTC)
SOURCE = {
    "EndpointConfigName": f"{ENDPOINT}-refresh-100",
    "EndpointConfigArn": "arn:aws:sagemaker:us-east-1:111122223333:endpoint-config/x",
    "CreationTime": NOW,
    "ProductionVariants": [
        {
            "VariantName": "primary",
            "ModelName": "model-a",
            "InitialInstanceCount": 1,
            "InstanceType": "ml.m5.xlarge",
            "InitialVariantWeight": 1.0,
            "ContainerStartupHealthCheckTimeoutInSeconds": 600,
        }
    ],
    "DataCaptureConfig": {
        "EnableCapture": True,
        "InitialSamplingPercentage": 20,
        "DestinationS3Uri": "s3://monitoring-bucket/data-capture",
        "CaptureOptions": [{"CaptureMode": "Output"}],
    },
    "KmsKeyId": "alias/example-volume-key",
    "EnableNetworkIsolation": True,
    "ExecutionRoleArn": "arn:aws:iam::111122223333:role/example",
    "ResponseMetadata": {"HTTPStatusCode": 200},
}


def test_clone_copies_everything_but_identity():
    request = refresher.clone_config_request(SOURCE, "new-name")
    assert request["EndpointConfigName"] == "new-name"
    for dropped in ("EndpointConfigArn", "CreationTime", "ResponseMetadata"):
        assert dropped not in request
    for kept in (
        "ProductionVariants",
        "DataCaptureConfig",
        "KmsKeyId",
        "EnableNetworkIsolation",
        "ExecutionRoleArn",
    ):
        assert request[kept] == SOURCE[kept]


def test_handler_rolls_endpoint_and_deletes_only_old_refresh_configs(monkeypatch):
    monkeypatch.setenv("ENDPOINT_NAME", ENDPOINT)
    monkeypatch.delenv("DEPLOYMENT_CONFIG", raising=False)
    monkeypatch.delenv("PATCHED_IMAGE_REPOSITORY", raising=False)
    monkeypatch.setattr(refresher.time, "time", lambda: 200)
    sm = boto3.client("sagemaker")
    current = SOURCE["EndpointConfigName"]
    new = f"{ENDPOINT[:40]}-refresh-200"
    old = f"{ENDPOINT[:40]}-refresh-50"
    with Stubber(sm) as stub:
        stub.add_response(
            "describe_endpoint",
            {
                "EndpointName": ENDPOINT,
                "EndpointArn": "arn:aws:sagemaker:us-east-1:111122223333:endpoint/x",
                "EndpointConfigName": current,
                "EndpointStatus": "InService",
                "CreationTime": NOW,
                "LastModifiedTime": NOW,
            },
            {"EndpointName": ENDPOINT},
        )
        stub.add_response(
            "describe_endpoint_config",
            {k: v for k, v in SOURCE.items() if k != "ResponseMetadata"},
            {"EndpointConfigName": current},
        )
        stub.add_response(
            "create_endpoint_config",
            {"EndpointConfigArn": "arn:aws:sagemaker:us-east-1:111122223333:endpoint-config/n"},
            refresher.clone_config_request(
                {k: v for k, v in SOURCE.items() if k != "ResponseMetadata"}, new
            ),
        )
        stub.add_response(
            "update_endpoint",
            {"EndpointArn": "arn:aws:sagemaker:us-east-1:111122223333:endpoint/x"},
            {"EndpointName": ENDPOINT, "EndpointConfigName": new, "RetainDeploymentConfig": True},
        )
        configs = [
            {"EndpointConfigName": n, "EndpointConfigArn": f"arn:x:{n}", "CreationTime": NOW}
            for n in (old, current, new, f"{ENDPOINT}-terraform-managed")
        ]
        stub.add_response(
            "list_endpoint_configs",
            {"EndpointConfigs": configs},
            {"NameContains": f"{ENDPOINT[:40]}-refresh-"},
        )
        stub.add_response("delete_endpoint_config", {}, {"EndpointConfigName": old})

        result = refresher.handler({}, None, sm=sm)
        stub.assert_no_pending_responses()

    assert result == {
        "refreshed": True,
        "new_config": new,
        "deleted_configs": [old],
        "created_models": [],
        "deleted_models": [],
    }


def test_handler_skips_when_not_in_service(monkeypatch):
    monkeypatch.setenv("ENDPOINT_NAME", ENDPOINT)
    sm = boto3.client("sagemaker")
    with Stubber(sm) as stub:
        stub.add_response(
            "describe_endpoint",
            {
                "EndpointName": ENDPOINT,
                "EndpointArn": "arn:aws:sagemaker:us-east-1:111122223333:endpoint/x",
                "EndpointConfigName": "c",
                "EndpointStatus": "Updating",
                "CreationTime": NOW,
                "LastModifiedTime": NOW,
            },
        )
        assert refresher.handler({}, None, sm=sm)["skipped"] is True


def test_update_request_sends_the_deployment_config(monkeypatch):
    config = {
        "BlueGreenUpdatePolicy": {
            "TrafficRoutingConfiguration": {
                "Type": "CANARY",
                "WaitIntervalInSeconds": 300,
                "CanarySize": {"Type": "CAPACITY_PERCENT", "Value": 10},
            },
            "TerminationWaitInSeconds": 120,
            "MaximumExecutionTimeoutInSeconds": 3600,
        },
        "AutoRollbackConfiguration": {"Alarms": [{"AlarmName": "example-endpoint-error-rate"}]},
    }
    monkeypatch.setenv("DEPLOYMENT_CONFIG", json.dumps(config))
    assert refresher.update_endpoint_request(ENDPOINT, "new") == {
        "EndpointName": ENDPOINT,
        "EndpointConfigName": "new",
        "DeploymentConfig": config,
    }


def test_update_request_retains_last_config_without_env(monkeypatch):
    monkeypatch.delenv("DEPLOYMENT_CONFIG", raising=False)
    assert refresher.update_endpoint_request(ENDPOINT, "new")["RetainDeploymentConfig"] is True


def test_clone_raises_instance_count_to_running_fleet():
    request = refresher.clone_config_request(SOURCE, "new-name", {"primary": 2})
    assert request["ProductionVariants"][0]["InitialInstanceCount"] == 2
    assert SOURCE["ProductionVariants"][0]["InitialInstanceCount"] == 1


def test_clone_never_lowers_instance_count():
    request = refresher.clone_config_request(SOURCE, "new-name", {"primary": 0, "other": 5})
    assert request["ProductionVariants"][0]["InitialInstanceCount"] == 1


REPO = "image-classification-inference-patched"
REPO_URL = f"111122223333.dkr.ecr.us-east-1.amazonaws.com/{REPO}"
OLD_IMAGE = f"{REPO_URL}@sha256:{'a' * 64}"
NEW_IMAGE = f"{REPO_URL}@sha256:{'b' * 64}"
MODEL = {
    "ModelName": "model-a",
    "ModelArn": "arn:aws:sagemaker:us-east-1:111122223333:model/model-a",
    "CreationTime": NOW,
    "ExecutionRoleArn": "arn:aws:iam::111122223333:role/example",
    "PrimaryContainer": {
        "Image": OLD_IMAGE,
        "ModelDataUrl": "s3://model-artifacts/model.tar.gz",
        "Environment": {"SAGEMAKER_PROGRAM": "inference.py"},
    },
    "EnableNetworkIsolation": True,
}


def _ecr_with_images(stub):
    stub.add_response(
        "describe_images",
        {
            "imageDetails": [
                {
                    "imageDigest": "sha256:" + "a" * 64,
                    "imagePushedAt": datetime(2026, 10, 1, tzinfo=UTC),
                },
                {
                    "imageDigest": "sha256:" + "b" * 64,
                    "imagePushedAt": datetime(2026, 10, 29, tzinfo=UTC),
                },
            ]
        },
        {"repositoryName": REPO, "filter": {"tagStatus": "TAGGED"}},
    )


def test_newest_image_uri_picks_the_latest_push():
    ecr = boto3.client("ecr", region_name="us-east-1")
    with Stubber(ecr) as stub:
        _ecr_with_images(stub)
        assert refresher.newest_image_uri(ecr, REPO, REPO_URL) == NEW_IMAGE


def test_repin_copies_the_model_with_the_newest_image(monkeypatch):
    monkeypatch.setenv("PATCHED_IMAGE_REPOSITORY", REPO)
    monkeypatch.setenv("PATCHED_IMAGE_REPOSITORY_URL", REPO_URL)
    sm = boto3.client("sagemaker", region_name="us-east-1")
    ecr = boto3.client("ecr", region_name="us-east-1")
    source = {k: v for k, v in SOURCE.items() if k != "ResponseMetadata"}
    name = f"{ENDPOINT[:40]}-image-300-0"
    with Stubber(sm) as sm_stub, Stubber(ecr) as ecr_stub:
        _ecr_with_images(ecr_stub)
        sm_stub.add_response("describe_model", MODEL, {"ModelName": "model-a"})
        expected = refresher.repin_model_request(MODEL, NEW_IMAGE, name)
        sm_stub.add_response(
            "create_model",
            {"ModelArn": "arn:aws:sagemaker:us-east-1:111122223333:model/new"},
            expected,
        )
        repinned, created = refresher.repin_to_newest_image(sm, ecr, source, ENDPOINT, 300)

    assert created == [name]
    assert repinned["ProductionVariants"][0]["ModelName"] == name
    assert expected["PrimaryContainer"]["Image"] == NEW_IMAGE
    assert expected["PrimaryContainer"]["ModelDataUrl"] == MODEL["PrimaryContainer"]["ModelDataUrl"]
    assert expected["EnableNetworkIsolation"] is True
    assert len(name) <= 63


def test_repin_keeps_a_model_already_on_the_newest_image(monkeypatch):
    monkeypatch.setenv("PATCHED_IMAGE_REPOSITORY", REPO)
    monkeypatch.setenv("PATCHED_IMAGE_REPOSITORY_URL", REPO_URL)
    sm = boto3.client("sagemaker", region_name="us-east-1")
    ecr = boto3.client("ecr", region_name="us-east-1")
    source = {k: v for k, v in SOURCE.items() if k != "ResponseMetadata"}
    current = {**MODEL, "PrimaryContainer": {**MODEL["PrimaryContainer"], "Image": NEW_IMAGE}}
    with Stubber(sm) as sm_stub, Stubber(ecr) as ecr_stub:
        _ecr_with_images(ecr_stub)
        sm_stub.add_response("describe_model", current, {"ModelName": "model-a"})
        repinned, created = refresher.repin_to_newest_image(sm, ecr, source, ENDPOINT, 300)

    assert created == []
    assert repinned is source
