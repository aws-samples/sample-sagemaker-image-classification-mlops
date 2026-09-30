# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""The auto-deploy Lambda sends the endpoint's canary policy with UpdateEndpoint."""

import json
from datetime import UTC, datetime
from types import SimpleNamespace

import boto3
import pytest
from botocore.stub import ANY, Stubber
from conftest import load_module

handler = load_module("modules/terraform-aws-auto-deployment/auto_deploy_handler.py", "auto_deploy")

ACCOUNT = "111122223333"
GROUP = "example-group"
ENDPOINT = "example-endpoint"
PACKAGE_ARN = f"arn:aws:sagemaker:us-east-1:{ACCOUNT}:model-package/{GROUP}/4"
NOW = datetime(2026, 9, 30, tzinfo=UTC)
CONTEXT = SimpleNamespace(
    invoked_function_arn=f"arn:aws:lambda:us-east-1:{ACCOUNT}:function:example-auto-deploy"
)
ALARMS = [{"AlarmName": "example-endpoint-error-rate"}, {"AlarmName": "example-endpoint-latency"}]

# The shape the endpoint module's deployment_config_json output produces.
CANARY_CONFIG = {
    "BlueGreenUpdatePolicy": {
        "TrafficRoutingConfiguration": {
            "Type": "CANARY",
            "WaitIntervalInSeconds": 300,
            "CanarySize": {"Type": "CAPACITY_PERCENT", "Value": 10},
        },
        "TerminationWaitInSeconds": 120,
        "MaximumExecutionTimeoutInSeconds": 3600,
    },
    "AutoRollbackConfiguration": {"Alarms": ALARMS},
}


@pytest.fixture
def env(monkeypatch):
    for key, value in {
        "ENDPOINT_NAME": ENDPOINT,
        "PROJECT_NAME": "example",
        "MODEL_PACKAGE_GROUP_NAME": GROUP,
        "SAGEMAKER_ROLE": f"arn:aws:iam::{ACCOUNT}:role/example-sagemaker",
        "MONITORING_BUCKET": "example-monitoring",
        "INSTANCE_TYPE": "ml.m5.xlarge",
        "INITIAL_INSTANCE_COUNT": "2",
        "DEPLOYMENT_CONFIG": json.dumps(CANARY_CONFIG),
    }.items():
        monkeypatch.setenv(key, value)
    for key in ("SERVING_IMAGE_URI", "MODEL_ARTIFACTS_BUCKET", "USE_SERVERLESS_INFERENCE"):
        monkeypatch.delenv(key, raising=False)
    return monkeypatch


@pytest.fixture
def stub(monkeypatch):
    sm = boto3.client("sagemaker", region_name="us-east-1")
    monkeypatch.setattr(handler, "sm", sm)
    with Stubber(sm) as stubber:
        yield stubber
        stubber.assert_no_pending_responses()


def _event():
    return {
        "detail-type": "SageMaker Model Package State Change",
        "detail": {"ModelPackageArn": PACKAGE_ARN, "ModelApprovalStatus": "Approved"},
    }


def _expect_deploy(stub, deployment_config):
    stub.add_response(
        "describe_endpoint",
        {
            "EndpointName": ENDPOINT,
            "EndpointArn": f"arn:aws:sagemaker:us-east-1:{ACCOUNT}:endpoint/{ENDPOINT}",
            "EndpointConfigName": "example-config-old",
            "EndpointStatus": "InService",
            "CreationTime": NOW,
            "LastModifiedTime": NOW,
        },
        {"EndpointName": ENDPOINT},
    )
    stub.add_response(
        "create_model", {"ModelArn": f"arn:aws:sagemaker:us-east-1:{ACCOUNT}:model/m"}
    )
    stub.add_response(
        "create_endpoint_config",
        {"EndpointConfigArn": f"arn:aws:sagemaker:us-east-1:{ACCOUNT}:endpoint-config/c"},
    )
    stub.add_response(
        "update_endpoint",
        {"EndpointArn": f"arn:aws:sagemaker:us-east-1:{ACCOUNT}:endpoint/{ENDPOINT}"},
        {
            "EndpointName": ENDPOINT,
            "EndpointConfigName": ANY,
            "DeploymentConfig": deployment_config,
        },
    )


def test_update_request_sends_explicit_config_without_retain():
    request = handler.update_endpoint_request(ENDPOINT, "cfg", CANARY_CONFIG)
    assert request == {
        "EndpointName": ENDPOINT,
        "EndpointConfigName": "cfg",
        "DeploymentConfig": CANARY_CONFIG,
    }


def test_update_request_retains_last_config_when_none_is_set(env):
    env.delenv("DEPLOYMENT_CONFIG")
    config = handler.deployment_config_from_env()
    assert config is None
    assert handler.update_endpoint_request(ENDPOINT, "cfg", config) == {
        "EndpointName": ENDPOINT,
        "EndpointConfigName": "cfg",
        "RetainDeploymentConfig": True,
    }


@pytest.mark.parametrize(
    "mutate, message",
    [
        (
            lambda c: c["BlueGreenUpdatePolicy"]["TrafficRoutingConfiguration"].update(Type="X"),
            "unknown",
        ),
        (
            lambda c: c["BlueGreenUpdatePolicy"]["TrafficRoutingConfiguration"].pop("CanarySize"),
            "CanarySize",
        ),
        (lambda c: c["AutoRollbackConfiguration"].update(Alarms=[]), "alarms"),
    ],
)
def test_bad_config_is_rejected_before_anything_is_created(env, stub, mutate, message):
    config = json.loads(json.dumps(CANARY_CONFIG))
    mutate(config)
    env.setenv("DEPLOYMENT_CONFIG", json.dumps(config))
    # No stubbed responses: the handler must fail before any SageMaker call.
    with pytest.raises(ValueError, match=message):
        handler.lambda_handler(_event(), CONTEXT)


def test_approval_rolls_out_with_canary_and_two_instances(env, stub):
    _expect_deploy(stub, CANARY_CONFIG)
    result = handler.lambda_handler(_event(), CONTEXT)
    assert result["statusCode"] == 200


def test_endpoint_config_uses_the_configured_instance_count(env, monkeypatch):
    calls = {}

    class FakeSageMaker:
        def create_model(self, **kwargs):
            calls["model"] = kwargs

        def create_endpoint_config(self, **kwargs):
            calls["config"] = kwargs

    monkeypatch.setattr(handler, "sm", FakeSageMaker())
    handler._create_model_and_config(PACKAGE_ARN, "example", "bucket", "ml.m5.xlarge", 100)
    variant = calls["config"]["ProductionVariants"][0]
    assert variant["InitialInstanceCount"] == 2
    assert variant["VariantName"] == "AllTraffic"


def test_serverless_endpoint_shifts_all_at_once(env, stub):
    env.setenv("USE_SERVERLESS_INFERENCE", "true")
    expected = {
        "BlueGreenUpdatePolicy": {
            "TrafficRoutingConfiguration": {"Type": "ALL_AT_ONCE", "WaitIntervalInSeconds": 300},
            "TerminationWaitInSeconds": 120,
            "MaximumExecutionTimeoutInSeconds": 3600,
        },
        "AutoRollbackConfiguration": {"Alarms": ALARMS},
    }
    _expect_deploy(stub, expected)
    assert handler.lambda_handler(_event(), CONTEXT)["statusCode"] == 200


def test_failed_update_cleans_up_model_and_config(env, stub):
    stub.add_response(
        "describe_endpoint",
        {
            "EndpointName": ENDPOINT,
            "EndpointArn": f"arn:aws:sagemaker:us-east-1:{ACCOUNT}:endpoint/{ENDPOINT}",
            "EndpointConfigName": "old",
            "EndpointStatus": "InService",
            "CreationTime": NOW,
            "LastModifiedTime": NOW,
        },
    )
    stub.add_response("create_model", {"ModelArn": "arn:aws:sagemaker:us-east-1:1:model/m"})
    stub.add_response(
        "create_endpoint_config", {"EndpointConfigArn": "arn:aws:sagemaker:us-east-1:1:ec/c"}
    )
    stub.add_client_error("update_endpoint", "ValidationException", "canary too large")
    stub.add_response("delete_endpoint_config", {})
    stub.add_response("delete_model", {})
    with pytest.raises(Exception, match="canary too large"):
        handler.lambda_handler(_event(), CONTEXT)
