#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}🚀 SageMaker Pipeline Scripts Upload${NC}"

# Get bucket name from terraform output or environment variable
echo -e "${BLUE}🔍 Getting scripts bucket name...${NC}"

if [ -n "$SCRIPTS_BUCKET" ]; then
    echo -e "${BLUE}📦 Using environment variable: $SCRIPTS_BUCKET${NC}"
else
    SCRIPTS_BUCKET=$(cd ../stack-training && terraform output -raw scripts_bucket 2>/dev/null)
    if [ -z "$SCRIPTS_BUCKET" ]; then
        echo -e "${RED}❌ Error: Could not get scripts bucket name${NC}"
        echo -e "${YELLOW}💡 Set SCRIPTS_BUCKET environment variable or run from local with terraform${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}📦 Target bucket: ${SCRIPTS_BUCKET}${NC}"

# Upload utils scripts
echo -e "${BLUE}📤 Uploading utils scripts...${NC}"
aws s3 cp utils/cloudwatch_metrics.py s3://$SCRIPTS_BUCKET/utils/
echo -e "${GREEN}✅ Uploaded cloudwatch_metrics.py${NC}"

# Upload validation scripts
echo -e "${BLUE}📤 Uploading validation scripts...${NC}"
aws s3 cp validation/data_validator.py s3://$SCRIPTS_BUCKET/validation/
echo -e "${GREEN}✅ Uploaded data_validator.py${NC}"

# Upload preprocessing scripts
echo -e "${BLUE}📤 Uploading preprocessing scripts...${NC}"
aws s3 cp preprocessing/data_preprocessor.py s3://$SCRIPTS_BUCKET/preprocessing/
echo -e "${GREEN}✅ Uploaded data_preprocessor.py${NC}"

# Create and upload training scripts (tar.gz files)
echo -e "${BLUE}📦 Creating training tar.gz files...${NC}"
cd training

# Remove old tar.gz files
rm -f *.tar.gz

# Shared modules bundled with every trainer (architecture-specific script +
# common training loop + config + metrics + spot checkpoint helpers).
COMMON_MODULES="_common.py training_metrics.py training_config.py spot_checkpoint.py"

tar -czf vgg16_trainer.tar.gz vgg16_trainer.py $COMMON_MODULES
echo -e "${GREEN}✅ Created vgg16_trainer.tar.gz${NC}"

tar -czf densenet121_trainer.tar.gz densenet121_trainer.py $COMMON_MODULES
echo -e "${GREEN}✅ Created densenet121_trainer.tar.gz${NC}"

tar -czf efficientnet_trainer.tar.gz efficientnet_trainer.py $COMMON_MODULES
echo -e "${GREEN}✅ Created efficientnet_trainer.tar.gz${NC}"

cd ..

# Upload training tar.gz files
echo -e "${BLUE}📤 Uploading training scripts...${NC}"
for training_file in training/*.tar.gz; do
    if [ -f "$training_file" ]; then
        filename=$(basename "$training_file")
        aws s3 cp "$training_file" s3://$SCRIPTS_BUCKET/training/
        echo -e "${GREEN}✅ Uploaded $filename${NC}"
    fi
done

# Upload evaluation scripts
echo -e "${BLUE}📤 Uploading evaluation scripts...${NC}"
aws s3 cp evaluation/model_evaluator.py s3://$SCRIPTS_BUCKET/evaluation/
aws s3 cp evaluation/report_generator.py s3://$SCRIPTS_BUCKET/evaluation/
aws s3 cp evaluation/requirements.txt s3://$SCRIPTS_BUCKET/evaluation/
echo -e "${GREEN}✅ Uploaded evaluation scripts (including report_generator.py)${NC}"

# Upload ensemble scripts (includes inference.py used by SageMaker endpoint)
echo -e "${BLUE}📤 Uploading ensemble scripts...${NC}"
aws s3 cp ensemble/ensemble_creator.py s3://$SCRIPTS_BUCKET/ensemble/
aws s3 cp ensemble/requirements.txt s3://$SCRIPTS_BUCKET/ensemble/
aws s3 cp ensemble/inference.py s3://$SCRIPTS_BUCKET/ensemble/
echo -e "${GREEN}✅ Uploaded ensemble scripts (including inference.py)${NC}"

# Upload drift scripts (Part 3 scheduled drift Processing job)
echo -e "${BLUE}📤 Uploading drift scripts...${NC}"
aws s3 cp drift/compute_drift.py s3://$SCRIPTS_BUCKET/drift/
echo -e "${GREEN}✅ Uploaded drift scripts${NC}"

# Upload bias scripts (Part 4 in-pipeline fairness gate - Fairlearn)
echo -e "${BLUE}📤 Uploading bias scripts...${NC}"
aws s3 cp bias/compute_bias.py s3://$SCRIPTS_BUCKET/bias/
aws s3 cp bias/run_bias_check.sh s3://$SCRIPTS_BUCKET/bias/
aws s3 cp bias/requirements.txt s3://$SCRIPTS_BUCKET/bias/
echo -e "${GREEN}✅ Uploaded bias scripts${NC}"

# Upload fairness scripts (Part 4 scheduled fairness monitoring job)
echo -e "${BLUE}📤 Uploading fairness scripts...${NC}"
aws s3 cp fairness/compute_fairness.py s3://$SCRIPTS_BUCKET/fairness/
aws s3 cp fairness/run_fairness.sh s3://$SCRIPTS_BUCKET/fairness/
aws s3 cp fairness/requirements.txt s3://$SCRIPTS_BUCKET/fairness/
echo -e "${GREEN}✅ Uploaded fairness scripts${NC}"

# Verify uploads
echo -e "${BLUE}🔍 Verifying uploads...${NC}"

REQUIRED_SCRIPTS=(
    "utils/cloudwatch_metrics.py"
    "validation/data_validator.py"
    "preprocessing/data_preprocessor.py"
    "evaluation/model_evaluator.py"
    "evaluation/report_generator.py"
    "evaluation/requirements.txt"
    "ensemble/ensemble_creator.py"
    "ensemble/inference.py"
    "ensemble/requirements.txt"
    "drift/compute_drift.py"
    "bias/compute_bias.py"
    "bias/run_bias_check.sh"
    "bias/requirements.txt"
    "fairness/compute_fairness.py"
    "fairness/run_fairness.sh"
    "fairness/requirements.txt"
)

MISSING_SCRIPTS=()

for script in "${REQUIRED_SCRIPTS[@]}"; do
    if aws s3 ls s3://$SCRIPTS_BUCKET/$script >/dev/null 2>&1; then
        echo -e "${GREEN}✅ $script${NC}"
    else
        echo -e "${RED}❌ $script${NC}"
        MISSING_SCRIPTS+=("$script")
    fi
done



# Check training scripts
TRAINING_SCRIPTS=(
    "training/vgg16_trainer.tar.gz"
    "training/densenet121_trainer.tar.gz"
    "training/efficientnet_trainer.tar.gz"
)

for script in "${TRAINING_SCRIPTS[@]}"; do
    if aws s3 ls s3://$SCRIPTS_BUCKET/$script >/dev/null 2>&1; then
        echo -e "${GREEN}✅ $script${NC}"
    else
        echo -e "${YELLOW}⚠️  $script${NC}"
    fi
done

if [ ${#MISSING_SCRIPTS[@]} -eq 0 ]; then
    echo -e "${GREEN}🎉 All scripts uploaded successfully!${NC}"
    echo -e "${BLUE}📋 Bucket contents:${NC}"
    aws s3 ls s3://$SCRIPTS_BUCKET/ --recursive --human-readable
else
    echo -e "${RED}❌ Missing ${#MISSING_SCRIPTS[@]} scripts${NC}"
    exit 1
fi

echo -e "${GREEN}✨ Upload completed!${NC}"
