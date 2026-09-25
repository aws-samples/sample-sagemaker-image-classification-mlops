#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Upload the pipeline and monitoring scripts to the scripts bucket. Run from
# the scripts/ directory. Every step mounts s3://<bucket>/<step>/ as its code
# directory, so the shared mlops_common package is uploaded into each step's
# prefix and bundled into each training tarball.

set -euo pipefail

cd "$(dirname "$0")"

if [ -z "${SCRIPTS_BUCKET:-}" ]; then
    SCRIPTS_BUCKET=$(cd ../stack-training && terraform output -raw scripts_bucket 2>/dev/null || true)
fi
if [ -z "$SCRIPTS_BUCKET" ]; then
    echo "ERROR: could not determine the scripts bucket."
    echo "Set SCRIPTS_BUCKET, or run where 'terraform output' works in stack-training."
    exit 1
fi
echo "Target bucket: ${SCRIPTS_BUCKET}"

put() {
    aws s3 cp "$1" "s3://${SCRIPTS_BUCKET}/$2" --only-show-errors
    echo "  uploaded $2"
}

# Upload mlops_common into one step prefix.
put_common() {
    aws s3 cp mlops_common "s3://${SCRIPTS_BUCKET}/$1/mlops_common/" --recursive \
        --exclude "__pycache__/*" --exclude "*.pyc" --only-show-errors
    echo "  uploaded $1/mlops_common/"
}

echo "Uploading step scripts"
put utils/cloudwatch_metrics.py utils/cloudwatch_metrics.py
# run_validation.sh and run_preprocessing.sh are the steps' entrypoints; each
# installs its requirements.txt before running the script.
put validation/data_validator.py validation/data_validator.py
put validation/run_validation.sh validation/run_validation.sh
put validation/requirements.txt validation/requirements.txt

put preprocessing/data_preprocessor.py preprocessing/data_preprocessor.py
put preprocessing/run_preprocessing.sh preprocessing/run_preprocessing.sh
put preprocessing/requirements.txt preprocessing/requirements.txt
put_common preprocessing

put evaluation/model_evaluator.py evaluation/model_evaluator.py
put evaluation/report_generator.py evaluation/report_generator.py
put evaluation/requirements.txt evaluation/requirements.txt
put_common evaluation

# inference.py is packaged into the ensemble model.tar.gz by ensemble_creator.
put ensemble/ensemble_creator.py ensemble/ensemble_creator.py
put ensemble/requirements.txt ensemble/requirements.txt
put ensemble/inference.py ensemble/inference.py
put_common ensemble

put drift/compute_drift.py drift/compute_drift.py
put_common drift

put bias/compute_bias.py bias/compute_bias.py
put bias/run_bias_check.sh bias/run_bias_check.sh
put bias/requirements.txt bias/requirements.txt
put_common bias

put fairness/compute_fairness.py fairness/compute_fairness.py
put fairness/run_fairness.sh fairness/run_fairness.sh
put fairness/requirements.txt fairness/requirements.txt
put_common fairness

echo "Building training tarballs"
# Shared modules bundled with every trainer: the architecture script, the
# common training loop, config, metrics, spot checkpoint helpers and
# mlops_common (image transform, seeds).
COMMON_MODULES=(_common.py training_metrics.py training_config.py spot_checkpoint.py)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R mlops_common "$STAGE/"
find "$STAGE" -name "__pycache__" -type d -prune -exec rm -rf {} +
rm -f training/*.tar.gz
for trainer in vgg16_trainer densenet121_trainer efficientnet_trainer; do
    tar -czf "training/${trainer}.tar.gz" -C training "${trainer}.py" "${COMMON_MODULES[@]}" \
        -C "$STAGE" mlops_common
    put "training/${trainer}.tar.gz" "training/${trainer}.tar.gz"
done

echo "Verifying uploads"
REQUIRED=(
    utils/cloudwatch_metrics.py
    validation/data_validator.py
    validation/run_validation.sh
    validation/requirements.txt
    preprocessing/data_preprocessor.py
    preprocessing/run_preprocessing.sh
    preprocessing/requirements.txt
    preprocessing/mlops_common/preprocess.py
    evaluation/model_evaluator.py
    evaluation/report_generator.py
    evaluation/requirements.txt
    evaluation/mlops_common/gates.py
    ensemble/ensemble_creator.py
    ensemble/inference.py
    ensemble/requirements.txt
    ensemble/mlops_common/gates.py
    drift/compute_drift.py
    drift/mlops_common/capture.py
    bias/compute_bias.py
    bias/run_bias_check.sh
    bias/requirements.txt
    bias/mlops_common/fairness.py
    fairness/compute_fairness.py
    fairness/run_fairness.sh
    fairness/requirements.txt
    fairness/mlops_common/fairness.py
    training/vgg16_trainer.tar.gz
    training/densenet121_trainer.tar.gz
    training/efficientnet_trainer.tar.gz
)
MISSING=0
for key in "${REQUIRED[@]}"; do
    if ! aws s3 ls "s3://${SCRIPTS_BUCKET}/${key}" >/dev/null 2>&1; then
        echo "  MISSING ${key}"
        MISSING=$((MISSING + 1))
    fi
done
if [ "$MISSING" -ne 0 ]; then
    echo "ERROR: ${MISSING} required object(s) missing"
    exit 1
fi
echo "All scripts uploaded."
