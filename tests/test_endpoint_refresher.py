# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import json
from datetime import UTC, datetime

import boto3
from botocore.stub import Stubber
from conftest import load_module

refresher = load_module("stack-inference/lambda/endpoint_refresher.py", "endpoint_refresher")

ENDPOINT = "medical-image-classification-endpoint"
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

    assert result == {"refreshed": True, "new_config": new, "deleted_configs": [old]}


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
