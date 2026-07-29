#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

set -e
OUT_DIR=${1:-/tmp/training_data}
mkdir -p "$OUT_DIR"

# Config via env (no account-specific values baked in):
#   AWS_REGION    - region the pipeline ran in (default us-east-1)
#   PIPELINE_NAME - SageMaker pipeline name
#   EXECUTIONS    - space-separated pipeline execution IDs to gather
# Account ID is resolved from the caller's own identity, so this works in any
# account without editing the script. Set AWS_PROFILE in your environment.
REGION=${AWS_REGION:-us-east-1}
PIPELINE_NAME=${PIPELINE_NAME:-medical-image-classification-pipeline}
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
read -r -a EXECUTIONS <<< "${EXECUTIONS:-}"

if [ ${#EXECUTIONS[@]} -eq 0 ]; then
  echo "Set EXECUTIONS to a space-separated list of pipeline execution IDs, e.g.:"
  echo "  EXECUTIONS=\"abc123 def456\" $0 $OUT_DIR"
  exit 1
fi

for exec in "${EXECUTIONS[@]}"; do
  echo "Gathering data for pipeline execution: $exec"
  exec_arn="arn:aws:sagemaker:${REGION}:${ACCOUNT_ID}:pipeline/${PIPELINE_NAME}/execution/${exec}"

  # Get all training job ARNs for this execution
  job_arns=$(aws sagemaker list-pipeline-execution-steps \
    --pipeline-execution-arn "$exec_arn" \
    --region "$REGION" \
    --query 'PipelineExecutionSteps[?contains(StepName,`Train`)].Metadata.TrainingJob.Arn' \
    --output text 2>/dev/null)

  # Get pipeline-level step timings
  aws sagemaker list-pipeline-execution-steps \
    --pipeline-execution-arn "$exec_arn" \
    --region "$REGION" \
    --query 'PipelineExecutionSteps[].{Step:StepName,Status:StepStatus,Start:StartTime,End:EndTime}' \
    --output json > "$OUT_DIR/${exec}_steps.json"

  for arn in $job_arns; do
    job_name=$(basename "$arn")
    aws sagemaker describe-training-job \
      --training-job-name "$job_name" \
      --region "$REGION" \
      --output json 2>/dev/null > "$OUT_DIR/${exec}_${job_name}.json"
  done
done

echo "Done. Files written to $OUT_DIR"
ls -la "$OUT_DIR"
