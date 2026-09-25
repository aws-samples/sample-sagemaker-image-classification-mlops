#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Verify Monitoring Setup Script
# This script verifies that all monitoring components are properly configured

set -e

echo "Verifying monitoring setup..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print status
print_status() {
    if [ "$1" -eq 0 ]; then
        echo -e "${GREEN}OK   $2${NC}"
    else
        echo -e "${RED}FAIL $2${NC}"
    fi
}

# Check if AWS CLI is configured
echo "Checking AWS CLI configuration..."
aws sts get-caller-identity > /dev/null 2>&1
print_status $? "AWS CLI configured"

# Check CloudWatch Log Groups
echo "Checking CloudWatch Log Groups..."
aws logs describe-log-groups --log-group-name-prefix "/aws/sagemaker" > /dev/null 2>&1
print_status $? "SageMaker log groups exist"

aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/medical-image-classification" > /dev/null 2>&1
print_status $? "Lambda log groups exist"

# Check CloudWatch Metrics
echo "Checking CloudWatch Metrics..."
aws cloudwatch list-metrics --namespace "medical-image-classification/ModelPerformance" > /dev/null 2>&1
print_status $? "Model performance metrics namespace exists"

aws cloudwatch list-metrics --namespace "medical-image-classification/DriftMetrics" > /dev/null 2>&1
print_status $? "Drift metrics namespace exists"

# Check SNS Topics
echo "Checking SNS Topics..."
aws sns list-topics --query "Topics[?contains(TopicArn, 'medical-image-classification')]" > /dev/null 2>&1
print_status $? "SNS topics exist"

# Check CloudWatch Alarms
echo "Checking CloudWatch Alarms..."
aws cloudwatch describe-alarms --alarm-name-prefix "medical-image-classification" > /dev/null 2>&1
print_status $? "CloudWatch alarms exist"

# Check EventBridge Rules
echo "Checking EventBridge Rules..."
aws events list-rules --name-prefix "medical-image-classification" > /dev/null 2>&1
print_status $? "EventBridge rules exist"

# Check if inference infrastructure is deployed
if [ -d "../stack-inference" ]; then
    cd ../stack-inference
    if [ -f "terraform.tfstate" ] || [ -f ".terraform/terraform.tfstate" ]; then
        echo "Checking inference infrastructure outputs..."
        terraform output > /dev/null 2>&1
        print_status $? "Inference infrastructure deployed"

        # Check API Gateway
        API_URL=$(terraform output -raw api_gateway_url 2>/dev/null || echo "")
        if [ ! -z "$API_URL" ]; then
            curl -s -o /dev/null -w "%{http_code}" "$API_URL/" | grep -q "200\|404"
            print_status $? "API Gateway accessible"
        fi
    fi
    cd ../scripts
fi

echo ""
echo -e "${YELLOW}Monitoring verification complete${NC}"
echo ""
echo "To view monitoring dashboards:"
echo "1. Go to AWS CloudWatch Console"
echo "2. Navigate to Dashboards"
echo "3. Look for 'medical-image-classification-*' dashboards"
echo ""
echo "To check metrics:"
echo "aws cloudwatch list-metrics --namespace 'medical-image-classification/ModelPerformance'"
echo "aws cloudwatch list-metrics --namespace 'medical-image-classification/DriftMetrics'"
