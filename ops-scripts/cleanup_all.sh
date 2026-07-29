#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Cleanup script for non-Terraform managed resources
# Deletes only data, versions, and resources created outside Terraform

set -e

echo "🧹 Cleaning up non-Terraform resources..."

# Function to empty S3 bucket contents (keep bucket, delete data)
empty_bucket_contents() {
    local bucket=$1
    if [ -n "$bucket" ] && aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
        echo "🗑️ Emptying contents of bucket: $bucket"

        # Delete all objects (uploaded data)
        aws s3 rm "s3://$bucket" --recursive 2>/dev/null || true

        # Delete all versions (versioned data)
        aws s3api list-object-versions --bucket "$bucket" --query 'Versions[].{Key:Key,VersionId:VersionId}' --output text 2>/dev/null | \
        while read key version; do
            if [ -n "$key" ] && [ -n "$version" ]; then
                aws s3api delete-object --bucket "$bucket" --key "$key" --version-id "$version" 2>/dev/null || true
            fi
        done

        # Delete all delete markers
        aws s3api list-object-versions --bucket "$bucket" --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' --output text 2>/dev/null | \
        while read key version; do
            if [ -n "$key" ] && [ -n "$version" ]; then
                aws s3api delete-object --bucket "$bucket" --key "$key" --version-id "$version" 2>/dev/null || true
            fi
        done

        echo "✅ Bucket $bucket contents emptied"
    fi
}

# Function to delete CloudWatch custom metrics (created by Lambda functions)
cleanup_custom_metrics() {
    echo "🗑️ Cleaning up custom CloudWatch metrics..."

    # Note: CloudWatch metrics cannot be deleted directly
    # They expire automatically after 15 months
    # We can only stop sending new metrics

    echo "✅ Custom metrics will expire automatically (AWS managed)"
}

# Function to delete training job logs (created during pipeline runs)
cleanup_training_logs() {
    echo "🗑️ Cleaning up training job logs..."

    # Delete SageMaker training job logs
    aws logs describe-log-groups --log-group-name-prefix "/aws/sagemaker/TrainingJobs/medical-image-classification" --query 'logGroups[].logGroupName' --output text 2>/dev/null | \
    tr '\t' '\n' | \
    while read group; do
        if [ -n "$group" ]; then
            echo "Deleting log group: $group"
            aws logs delete-log-group --log-group-name "$group" 2>/dev/null || true
        fi
    done

    # Delete processing job logs
    aws logs describe-log-groups --log-group-name-prefix "/aws/sagemaker/ProcessingJobs/medical-image-classification" --query 'logGroups[].logGroupName' --output text 2>/dev/null | \
    tr '\t' '\n' | \
    while read group; do
        if [ -n "$group" ]; then
            echo "Deleting log group: $group"
            aws logs delete-log-group --log-group-name "$group" 2>/dev/null || true
        fi
    done

    echo "✅ Training logs cleaned up"
}



# Function to delete SageMaker resources created by Lambda (not Terraform)
cleanup_sagemaker_resources() {
    echo "🗑️ Cleaning up SageMaker resources created by Lambda..."

    # Delete endpoints (created by auto-deployment Lambda)
    for endpoint in "medical-image-classification-endpoint"; do
        echo "Deleting endpoint: $endpoint"
        aws sagemaker delete-endpoint --endpoint-name "$endpoint" 2>/dev/null || true
    done

    # Delete endpoint configs (created by auto-deployment Lambda)
    aws sagemaker list-endpoint-configs --name-contains "medical-image-classification" --query 'EndpointConfigs[].EndpointConfigName' --output text 2>/dev/null | \
    tr '\t' '\n' | \
    while read config; do
        if [ -n "$config" ]; then
            echo "Deleting endpoint config: $config"
            aws sagemaker delete-endpoint-config --endpoint-config-name "$config" 2>/dev/null || true
        fi
    done

    # Delete models (created by auto-deployment Lambda)
    aws sagemaker list-models --name-contains "medical-image-classification" --query 'Models[].ModelName' --output text 2>/dev/null | \
    tr '\t' '\n' | \
    while read model; do
        if [ -n "$model" ]; then
            echo "Deleting model: $model"
            aws sagemaker delete-model --model-name "$model" 2>/dev/null || true
        fi
    done

    echo "✅ SageMaker resources cleaned up"
}

# Function to delete all model packages
delete_model_packages() {
    local group_name="medical-image-classification-model-package-group"
    local account_id
    account_id=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
    local region="${AWS_REGION:-us-east-1}"

    if [ -z "$account_id" ]; then
        echo "⚠️  Could not determine AWS account ID, skipping version-based fallback"
    fi

    echo "🗑️ Deleting all model packages in group: $group_name"

    # Method 1: Delete by listing ARNs (preferred - works regardless of numbering)
    aws sagemaker list-model-packages --model-package-group-name "$group_name" --query 'ModelPackageSummaryList[].ModelPackageArn' --output text 2>/dev/null | \
    tr '\t' '\n' | \
    while read arn; do
        if [ -n "$arn" ]; then
            echo "   Deleting: $arn"
            aws sagemaker delete-model-package --model-package-name "$arn" 2>/dev/null || true
        fi
    done

    # Method 2: Delete by version numbers (fallback - uses caller's account ID)
    if [ -n "$account_id" ]; then
        echo "   Deleting by version numbers (1-30) in $region..."
        for i in {1..30}; do
            aws sagemaker delete-model-package \
                --model-package-name "arn:aws:sagemaker:$region:$account_id:model-package/$group_name/$i" \
                2>/dev/null || true
        done
    fi

    echo "✅ All model packages deleted"
}



# Delete SageMaker resources created by Lambda functions
cleanup_sagemaker_resources

# Delete model packages (created by pipeline runs, not Terraform)
delete_model_packages

# Clean up training logs (created during pipeline execution)
cleanup_training_logs

# Clean up custom metrics (created by Lambda functions)
cleanup_custom_metrics

# Empty S3 bucket contents (data uploaded by scripts, not buckets themselves)
echo "🗑️ Emptying S3 bucket contents..."

# Get bucket names dynamically using S3 API query (robust against aws s3 ls output changes)
for bucket in $(aws s3api list-buckets --query "Buckets[?starts_with(Name, 'medical-image-classification')].Name" --output text 2>/dev/null | tr '\t' '\n'); do
    empty_bucket_contents "$bucket"
done

echo "🎉 Non-Terraform resource cleanup finished!"
echo ""
echo "Cleaned up:"
echo "- SageMaker endpoints, configs, models (created by auto-deployment Lambda)"
echo "- S3 bucket contents (uploaded data, processed files, model artifacts, versions)"
echo "- SageMaker model packages (created by pipeline runs)"
echo "- Training/Processing job logs (created during pipeline execution)"
echo "- Custom CloudWatch metrics (will expire automatically)"
echo ""
echo "Resources NOT deleted (managed by Terraform):"
echo "- S3 buckets themselves"
echo "- IAM roles and policies"
echo "- SageMaker pipelines"
echo "- Lambda functions"
echo "- API Gateway"
echo "- CloudWatch dashboards and alarms"
echo ""
echo "Now run 'terraform destroy' in each directory:"
echo "1. cd stack-training && terraform destroy"
echo "2. cd stack-inference && terraform destroy"
echo "3. cd stack-cicd && terraform destroy"
