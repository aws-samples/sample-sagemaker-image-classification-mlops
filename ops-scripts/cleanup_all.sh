#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Removes the resources that pipeline runs and Lambda functions create outside
# Terraform (endpoint configs, models, model packages, job log groups, bucket
# contents), then optionally runs `terraform destroy` on the stacks in
# dependency order: cicd, inference, training.
#
# The Terraform state bucket is never emptied or deleted. Destroy
# stack-backend-setup yourself as the very last step, once every other stack
# is gone.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

PROJECT_NAME="medical-image-classification"
PROFILE=""
REGION=""
STATE_BUCKET=""
RUN_DESTROY=false
ASSUME_YES=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --project NAME        Project name prefix used by the stacks (default: ${PROJECT_NAME})
  --profile NAME        AWS CLI profile to use (default: the current AWS_PROFILE)
  --region REGION       AWS region (default: the profile or AWS_REGION setting)
  --state-bucket NAME   Terraform state bucket to protect. Default: read from
                        stack-*/backend.hcl or the stack-backend-setup output.
  --destroy             After cleanup, run terraform destroy in stack-cicd,
                        stack-inference and stack-training (in that order).
  --yes                 Skip the confirmation prompt (and pass -auto-approve
                        to terraform destroy).
  -h, --help            Show this help.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --project) PROJECT_NAME="${2:?--project needs a value}"; shift 2 ;;
        --profile) PROFILE="${2:?--profile needs a value}"; shift 2 ;;
        --region) REGION="${2:?--region needs a value}"; shift 2 ;;
        --state-bucket) STATE_BUCKET="${2:?--state-bucket needs a value}"; shift 2 ;;
        --destroy) RUN_DESTROY=true; shift ;;
        --yes) ASSUME_YES=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if ! [[ "$PROJECT_NAME" =~ ^[a-z0-9-]+$ ]]; then
    echo "ERROR: --project must be lowercase letters, digits and hyphens" >&2
    exit 2
fi

# Terraform and the AWS CLI both honour these.
if [ -n "$PROFILE" ]; then
    export AWS_PROFILE="$PROFILE"
fi
if [ -n "$REGION" ]; then
    export AWS_REGION="$REGION"
    export AWS_DEFAULT_REGION="$REGION"
fi

# ---------------------------------------------------------------------------
# Identify the state bucket so it can be excluded
# ---------------------------------------------------------------------------

if [ -z "$STATE_BUCKET" ]; then
    for hcl in "$REPO_ROOT"/stack-training/backend.hcl "$REPO_ROOT"/stack-inference/backend.hcl "$REPO_ROOT"/stack-cicd/backend.hcl; do
        if [ -f "$hcl" ]; then
            STATE_BUCKET="$(sed -n 's/^[[:space:]]*bucket[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$hcl" | head -n 1)"
            [ -n "$STATE_BUCKET" ] && break
        fi
    done
fi
if [ -z "$STATE_BUCKET" ] && command -v terraform >/dev/null 2>&1; then
    STATE_BUCKET="$(terraform -chdir="$REPO_ROOT/stack-backend-setup" output -raw state_bucket_id 2>/dev/null || true)"
fi

is_state_bucket() {
    local bucket="$1"
    [ -n "$STATE_BUCKET" ] && [ "$bucket" = "$STATE_BUCKET" ] && return 0
    # Safety net in case the state bucket name could not be resolved.
    case "$bucket" in
        *tfstate*|*terraform-state*) return 0 ;;
    esac
    return 1
}

# ---------------------------------------------------------------------------
# Confirm the target account before touching anything
# ---------------------------------------------------------------------------

IDENTITY="$(aws sts get-caller-identity --query '[Account, Arn]' --output text)"
ACCOUNT_ID="$(echo "$IDENTITY" | cut -f1)"
CALLER_ARN="$(echo "$IDENTITY" | cut -f2)"
EFFECTIVE_REGION="$(aws configure get region 2>/dev/null || true)"
EFFECTIVE_REGION="${AWS_REGION:-${EFFECTIVE_REGION:-us-east-1}}"

BUCKETS=()
while IFS= read -r bucket; do
    [ -z "$bucket" ] && continue
    if is_state_bucket "$bucket"; then
        continue
    fi
    BUCKETS+=("$bucket")
done < <(aws s3api list-buckets \
    --query "Buckets[?starts_with(Name, '${PROJECT_NAME}-')].Name" \
    --output text | tr '\t' '\n')

echo "Account:        $ACCOUNT_ID"
echo "Caller:         $CALLER_ARN"
echo "Region:         $EFFECTIVE_REGION"
echo "Project prefix: ${PROJECT_NAME}-"
echo "State bucket:   ${STATE_BUCKET:-<not found; names containing tfstate or terraform-state are skipped>} (never touched)"
echo ""
echo "This deletes SageMaker endpoint configs, models and model packages named ${PROJECT_NAME}-*,"
echo "the ${PROJECT_NAME} job log groups, and ALL objects and versions in these buckets:"
if [ "${#BUCKETS[@]}" -eq 0 ]; then
    echo "  (none)"
else
    printf '  %s\n' "${BUCKETS[@]}"
fi
if [ "$RUN_DESTROY" = true ]; then
    echo ""
    echo "It then runs terraform destroy in stack-cicd, stack-inference and stack-training."
fi
echo ""

if [ "$ASSUME_YES" != true ]; then
    read -r -p "Type the project name (${PROJECT_NAME}) to continue: " reply
    if [ "$reply" != "$PROJECT_NAME" ]; then
        echo "Aborted."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Cleanup functions
# ---------------------------------------------------------------------------

empty_bucket() {
    local bucket="$1"
    local batch count
    echo "Emptying bucket: $bucket"
    # Delete object versions and delete markers in batches of up to 1000
    # (the DeleteObjects limit). Each pass lists the first page again, so no
    # pagination token is needed.
    while :; do
        # shellcheck disable=SC2016 # backticks are JMESPath literals, not shell expansion
        count="$(aws s3api list-object-versions --bucket "$bucket" --max-keys 1000 --no-paginate \
            --query 'length([Versions || `[]`, DeleteMarkers || `[]`][])' --output text)"
        [ "$count" = "0" ] && break
        # shellcheck disable=SC2016 # backticks are JMESPath literals, not shell expansion
        batch="$(aws s3api list-object-versions --bucket "$bucket" --max-keys 1000 --no-paginate \
            --query '{Objects: [Versions || `[]`, DeleteMarkers || `[]`][].{Key: Key, VersionId: VersionId}, Quiet: `true`}' \
            --output json)"
        aws s3api delete-objects --bucket "$bucket" --delete "$batch" >/dev/null
    done
}

delete_endpoint_resources() {
    local name
    echo "Deleting SageMaker endpoint ${PROJECT_NAME}-endpoint (if present)"
    aws sagemaker delete-endpoint --endpoint-name "${PROJECT_NAME}-endpoint" >/dev/null 2>&1 || true

    # The AWS CLI follows pagination tokens for list calls automatically.
    aws sagemaker list-endpoint-configs --name-contains "$PROJECT_NAME" \
        --query "EndpointConfigs[?starts_with(EndpointConfigName, '${PROJECT_NAME}-')].EndpointConfigName" \
        --output text | tr '\t' '\n' | while IFS= read -r name; do
        [ -z "$name" ] && continue
        echo "Deleting endpoint config: $name"
        aws sagemaker delete-endpoint-config --endpoint-config-name "$name" || true
    done

    aws sagemaker list-models --name-contains "$PROJECT_NAME" \
        --query "Models[?starts_with(ModelName, '${PROJECT_NAME}-')].ModelName" \
        --output text | tr '\t' '\n' | while IFS= read -r name; do
        [ -z "$name" ] && continue
        echo "Deleting model: $name"
        aws sagemaker delete-model --model-name "$name" || true
    done
}

delete_model_packages() {
    local group arn
    aws sagemaker list-model-package-groups --name-contains "$PROJECT_NAME" \
        --query "ModelPackageGroupSummaryList[?starts_with(ModelPackageGroupName, '${PROJECT_NAME}-')].ModelPackageGroupName" \
        --output text | tr '\t' '\n' | while IFS= read -r group; do
        [ -z "$group" ] && continue
        echo "Deleting model packages in group: $group"
        aws sagemaker list-model-packages --model-package-group-name "$group" \
            --query 'ModelPackageSummaryList[].ModelPackageArn' --output text | tr '\t' '\n' | \
        while IFS= read -r arn; do
            [ -z "$arn" ] && continue
            aws sagemaker delete-model-package --model-package-name "$arn" || true
        done
    done
}

delete_job_log_groups() {
    local prefix group
    for prefix in "/aws/sagemaker/TrainingJobs/${PROJECT_NAME}" "/aws/sagemaker/ProcessingJobs/${PROJECT_NAME}"; do
        aws logs describe-log-groups --log-group-name-prefix "$prefix" \
            --query 'logGroups[].logGroupName' --output text | tr '\t' '\n' | \
        while IFS= read -r group; do
            [ -z "$group" ] && continue
            echo "Deleting log group: $group"
            aws logs delete-log-group --log-group-name "$group" || true
        done
    done
}

destroy_stack() {
    local stack="$1"
    local dir="$REPO_ROOT/$stack"
    local approve=()
    [ "$ASSUME_YES" = true ] && approve=(-auto-approve)

    if [ ! -f "$dir/backend.hcl" ]; then
        echo "Skipping $stack: $dir/backend.hcl not found (run 'make backend-config')"
        return 0
    fi
    echo ""
    echo "=== terraform destroy: $stack ==="
    terraform -chdir="$dir" init -input=false -backend-config=backend.hcl >/dev/null
    if [ -z "$(terraform -chdir="$dir" state list 2>/dev/null)" ]; then
        echo "Skipping $stack: state is empty"
        return 0
    fi
    terraform -chdir="$dir" destroy -input=false ${approve[@]+"${approve[@]}"}
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

delete_endpoint_resources
delete_model_packages
delete_job_log_groups
for bucket in ${BUCKETS[@]+"${BUCKETS[@]}"}; do
    empty_bucket "$bucket"
done

echo ""
echo "Out-of-band resources removed. Custom CloudWatch metrics cannot be deleted; they expire on their own."

if [ "$RUN_DESTROY" = true ]; then
    # Inputs the training and inference stacks read from the bootstrap stack.
    export TF_VAR_state_bucket_name="$STATE_BUCKET"
    STATE_REGION="$(terraform -chdir="$REPO_ROOT/stack-backend-setup" output -raw state_bucket_region 2>/dev/null || true)"
    if [ -n "$STATE_REGION" ]; then
        export TF_VAR_state_bucket_region="$STATE_REGION"
    fi
    BOUNDARY_ARN="$(terraform -chdir="$REPO_ROOT/stack-backend-setup" output -raw workload_boundary_arn 2>/dev/null || true)"
    if [ -n "$BOUNDARY_ARN" ]; then
        export TF_VAR_permissions_boundary_arn="$BOUNDARY_ARN"
    fi

    # Reverse dependency order: stack-inference reads stack-training state.
    destroy_stack stack-cicd
    destroy_stack stack-inference
    destroy_stack stack-training
    echo ""
    echo "Done. The state bucket was left untouched. When nothing else uses it,"
    echo "empty it (it keeps state versions) and run:"
    echo "  cd stack-backend-setup && terraform destroy"
else
    echo ""
    echo "Next, destroy the stacks in this order (or rerun with --destroy):"
    echo "  1. stack-cicd"
    echo "  2. stack-inference"
    echo "  3. stack-training"
    echo "  4. stack-backend-setup (last; it holds the remote state)"
fi
