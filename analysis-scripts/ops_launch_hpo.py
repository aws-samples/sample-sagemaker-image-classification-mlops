#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import argparse
import json
import os
import time

import boto3


def main() -> int:
    parser = argparse.ArgumentParser(description="Launch SageMaker HPO job")
    parser.add_argument("--region", default=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
    parser.add_argument("--project", default="medical-image-classification")
    parser.add_argument(
        "--model",
        default="densenet121",
        help="Which trainer to tune (densenet121 / efficientnet / vgg16)",
    )
    parser.add_argument("--instance-type", default="ml.p3.2xlarge")
    parser.add_argument(
        "--max-jobs", type=int, default=6, help="Total HPO trials (each trains one model)"
    )
    parser.add_argument("--max-parallel", type=int, default=2, help="Trials running in parallel")
    parser.add_argument("--max-runtime-sec", type=int, default=3600)
    args = parser.parse_args()

    sm = boto3.client("sagemaker", region_name=args.region)
    sts = boto3.client("sts", region_name=args.region)
    account_id = sts.get_caller_identity()["Account"]

    timestamp = time.strftime("%m%d-%H%M")
    # HPO job names must be ≤32 chars
    short_project = args.project.replace("medical-image-classification", "mic")
    short_model = args.model[:8]
    tuning_job_name = f"{short_project}-{short_model}-{timestamp}"[:32]

    # Discover resources
    scripts_bucket = f"{args.project}-dev-scripts-51e179c7"
    processed_bucket = f"{args.project}-dev-processed-data-51e179c7"
    model_bucket = f"{args.project}-dev-model-artifacts-51e179c7"
    execution_role_arn = f"arn:aws:iam::{account_id}:role/{args.project}-sagemaker-execution-role"

    # DLC training image - the floating tag (no -v1.X suffix) auto-picks up
    # AWS-published patch versions, matching what the production pipeline uses
    # (see terraform/training/variables.tf sagemaker_images.tensorflow_gpu_tag).
    # Override via env: DLC_ACCOUNT_ID / DLC_REGION / TRAINING_IMAGE_TAG.
    dlc_account_id = os.environ.get("DLC_ACCOUNT_ID", "763104351884")
    dlc_region = os.environ.get("DLC_REGION", args.region)
    training_tag = os.environ.get(
        "TRAINING_IMAGE_TAG",
        "2.19.0-gpu-py312-cu125-ubuntu22.04-sagemaker",
    )
    training_image = (
        f"{dlc_account_id}.dkr.ecr.{dlc_region}.amazonaws.com/tensorflow-training:{training_tag}"
    )

    tar_name = {
        "densenet121": "densenet121_trainer.tar.gz",
        "efficientnet": "efficientnet_trainer.tar.gz",
        "vgg16": "vgg16_trainer.tar.gz",
    }[args.model]

    script_name = {
        "densenet121": "densenet121_trainer.py",
        "efficientnet": "efficientnet_trainer.py",
        "vgg16": "vgg16_trainer.py",
    }[args.model]

    response = sm.create_hyper_parameter_tuning_job(
        HyperParameterTuningJobName=tuning_job_name,
        HyperParameterTuningJobConfig={
            "Strategy": "Bayesian",
            "HyperParameterTuningJobObjective": {
                "Type": "Maximize",
                "MetricName": "validation_accuracy",
            },
            "ResourceLimits": {
                "MaxNumberOfTrainingJobs": args.max_jobs,
                "MaxParallelTrainingJobs": args.max_parallel,
            },
            "ParameterRanges": {
                "ContinuousParameterRanges": [
                    {
                        "Name": "TRAINING_LEARNING_RATE",
                        "MinValue": "0.00005",
                        "MaxValue": "0.005",
                        "ScalingType": "Logarithmic",
                    },
                ],
                "IntegerParameterRanges": [
                    {
                        "Name": "TRAINING_BATCH_SIZE",
                        "MinValue": "16",
                        "MaxValue": "64",
                        "ScalingType": "Linear",
                    },
                ],
                "CategoricalParameterRanges": [
                    {
                        "Name": "TRAINING_EPOCHS",
                        "Values": ["10", "15"],
                    },
                ],
            },
            "TrainingJobEarlyStoppingType": "Auto",
        },
        TrainingJobDefinition={
            "StaticHyperParameters": {
                "sagemaker_program": json.dumps(script_name),
                "sagemaker_submit_directory": json.dumps(
                    f"s3://{scripts_bucket}/training/{tar_name}"
                ),
            },
            "AlgorithmSpecification": {
                "TrainingImage": training_image,
                "TrainingInputMode": "File",
                "MetricDefinitions": [
                    {"Name": "validation_accuracy", "Regex": "val_accuracy:\\s*([0-9.]+)"},
                    {"Name": "validation_loss", "Regex": "val_loss:\\s*([0-9.]+)"},
                    {"Name": "train_accuracy", "Regex": "accuracy:\\s*([0-9.]+)"},
                ],
            },
            "RoleArn": execution_role_arn,
            "InputDataConfig": [
                {
                    "ChannelName": "train",
                    "DataSource": {
                        "S3DataSource": {
                            "S3DataType": "S3Prefix",
                            "S3Uri": f"s3://{processed_bucket}/processed_data/train/",
                            "S3DataDistributionType": "FullyReplicated",
                        },
                    },
                    "ContentType": "application/x-image",
                    "CompressionType": "None",
                },
                {
                    "ChannelName": "validation",
                    "DataSource": {
                        "S3DataSource": {
                            "S3DataType": "S3Prefix",
                            "S3Uri": f"s3://{processed_bucket}/processed_data/val/",
                            "S3DataDistributionType": "FullyReplicated",
                        },
                    },
                    "ContentType": "application/x-image",
                    "CompressionType": "None",
                },
            ],
            "OutputDataConfig": {
                "S3OutputPath": f"s3://{model_bucket}/hpo-results/",
            },
            "ResourceConfig": {
                "InstanceType": args.instance_type,
                "InstanceCount": 1,
                "VolumeSizeInGB": 100,
            },
            "StoppingCondition": {
                "MaxRuntimeInSeconds": args.max_runtime_sec,
            },
        },
    )

    print("✓ HPO job launched")
    print(f"  Name: {tuning_job_name}")
    print(f"  ARN:  {response['HyperParameterTuningJobArn']}")
    print("  Strategy:     Bayesian")
    print(f"  Max trials:   {args.max_jobs}")
    print(f"  Max parallel: {args.max_parallel}")
    print(
        f"  Console:      https://{args.region}.console.aws.amazon.com/"
        f"sagemaker/home?region={args.region}#/hyper-tuning-jobs/{tuning_job_name}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
