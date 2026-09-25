# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# One-command deploy and confirmed destroy for the sample.
#
#   make deploy-all                 # bootstrap .. deploy-inference, in order
#   make destroy                    # cicd, inference, training (asks first)
#   make deploy-all PROFILE=dev     # use a named AWS CLI profile
#
# Each deploy target runs `terraform plan -out` and applies the saved plan.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

PROFILE ?=
ifneq ($(strip $(PROFILE)),)
export AWS_PROFILE := $(PROFILE)
endif

ROOT       := $(CURDIR)
BOOTSTRAP  := stack-backend-setup
STACKS     := stack-training stack-inference stack-cicd
ALL_STACKS := $(BOOTSTRAP) $(STACKS)
TF_INIT    := terraform init -input=false -backend-config=backend.hcl

# Inputs the training and inference stacks read from the bootstrap outputs.
BOOT_OUTPUT = terraform -chdir=$(ROOT)/$(BOOTSTRAP) output -raw
TF_ENV = TF_VAR_state_bucket_name="$$($(BOOT_OUTPUT) state_bucket_id)" \
	TF_VAR_state_bucket_region="$$($(BOOT_OUTPUT) state_bucket_region)" \
	TF_VAR_permissions_boundary_arn="$$($(BOOT_OUTPUT) workload_boundary_arn)"

# Newest Approved package in the model package group, the same query the
# inference buildspec runs. Prints nothing when no package is approved yet.
TRAIN_OUTPUT  = terraform -chdir=$(ROOT)/stack-training output -raw
TRAIN_REGION  = $${AWS_REGION:-$$($(BOOT_OUTPUT) state_bucket_region)}
LATEST_APPROVED = aws sagemaker list-model-packages --region "$(TRAIN_REGION)" \
	--model-package-group-name "$$($(TRAIN_OUTPUT) model_package_group_name)" \
	--model-approval-status Approved \
	--sort-by CreationTime --sort-order Descending --max-results 1 \
	--query 'ModelPackageSummaryList[0].ModelPackageArn' --output text | sed 's/^None$$//'

.PHONY: help bootstrap backend-config layer deploy-training upload-scripts \
	weights seed-baseline check-approved deploy-inference deploy-cicd deploy-all \
	destroy fmt validate lint test check-backend-config

help: ## Show the available targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-18s %s\n", $$1, $$2}'

bootstrap: ## Create the state bucket, KMS key and permissions boundary (local state)
	cd $(BOOTSTRAP) && terraform init -input=false
	cd $(BOOTSTRAP) && terraform plan -input=false -out=tfplan
	cd $(BOOTSTRAP) && terraform apply -input=false tfplan && rm -f tfplan

backend-config: ## Write backend.hcl in each stack from the bootstrap outputs
	@for stack in $(STACKS); do \
		$(BOOT_OUTPUT) backend_hcl > "$$stack/backend.hcl"; \
		echo "wrote $$stack/backend.hcl"; \
	done
	@echo "state bucket: $$($(BOOT_OUTPUT) state_bucket_id) (set state_bucket_name in stack-cicd/terraform.tfvars)"

check-backend-config:
	@for stack in $(STACKS); do \
		if [ ! -f "$$stack/backend.hcl" ]; then \
			echo "$$stack/backend.hcl is missing: run 'make backend-config'" >&2; exit 1; \
		fi; \
	done

layer: ## Build the Pillow and NumPy Lambda layer zip
	./ops-scripts/build_lambda_layer.sh

deploy-training: check-backend-config ## Plan and apply stack-training
	cd stack-training && $(TF_INIT)
	cd stack-training && $(TF_ENV) terraform plan -input=false -out=tfplan
	cd stack-training && $(TF_ENV) terraform apply -input=false tfplan && rm -f tfplan

upload-scripts: ## Upload the pipeline scripts to the scripts bucket
	cd scripts && SCRIPTS_BUCKET="$$(terraform -chdir=$(ROOT)/stack-training output -raw scripts_bucket)" ./script_uploader.sh

weights: ## Upload the ImageNet weights when network isolation is on (needs TensorFlow)
	@if [ "$$($(TRAIN_OUTPUT) network_isolation_enabled)" = "true" ]; then \
		python3 scripts/download_pretrained_weights.py "$$($(TRAIN_OUTPUT) scripts_bucket)"; \
	else \
		echo "network isolation is off: the trainers download the weights themselves"; \
	fi

seed-baseline: upload-scripts ## Upload scripts and register the baseline model
	MODEL_PACKAGE_GROUP_NAME="$$(terraform -chdir=stack-training output -raw model_package_group_name)" \
	MODEL_ARTIFACTS_BUCKET="$$(terraform -chdir=stack-training output -raw model_artifacts_bucket)" \
	AWS_REGION="$${AWS_REGION:-$$($(BOOT_OUTPUT) state_bucket_region)}" \
		python3 stack-cicd/scripts/create_baseline_model.py

check-approved: ## Fail with a hint when the model package group has no Approved package
	@if [ -z "$${TF_VAR_model_package_arn:-}" ] && [ -z "$$($(LATEST_APPROVED))" ]; then \
		echo "No Approved model package in $$($(TRAIN_OUTPUT) model_package_group_name)." >&2; \
		echo "Approve the baseline (README Quick start step 7), then run 'make deploy-inference'." >&2; \
		exit 1; \
	fi

deploy-inference: check-backend-config check-approved ## Plan and apply stack-inference on the newest Approved package (TF_VAR_model_package_arn overrides)
	@test -f stack-inference/lambda-layers/pillow-numpy-layer.zip || { echo "Lambda layer zip missing: run 'make layer'" >&2; exit 1; }
	cd stack-inference && $(TF_INIT)
	cd stack-inference && ARN="$${TF_VAR_model_package_arn:-$$($(LATEST_APPROVED))}" && \
		echo "Deploying model package $$ARN" && \
		$(TF_ENV) TF_VAR_model_package_arn="$$ARN" terraform plan -input=false -out=tfplan
	cd stack-inference && $(TF_ENV) terraform apply -input=false tfplan && rm -f tfplan

deploy-cicd: check-backend-config ## Plan and apply the optional stack-cicd
	cd stack-cicd && $(TF_INIT)
	cd stack-cicd && terraform plan -input=false -out=tfplan
	cd stack-cicd && terraform apply -input=false tfplan && rm -f tfplan

deploy-all: ## bootstrap, backend-config, layer, deploy-training, weights, seed-baseline, deploy-inference
	$(MAKE) bootstrap
	$(MAKE) backend-config
	$(MAKE) layer
	$(MAKE) deploy-training
	$(MAKE) weights
	$(MAKE) seed-baseline
	$(MAKE) deploy-inference

destroy: ## Clean up out-of-band resources, then destroy cicd, inference, training (asks first)
	./ops-scripts/cleanup_all.sh --destroy $(if $(strip $(PROFILE)),--profile $(PROFILE),)

fmt: ## Format Terraform and Python
	terraform fmt -recursive
	ruff format .

validate: ## terraform init -backend=false and validate on every stack
	@for stack in $(ALL_STACKS); do \
		echo "== $$stack"; \
		terraform -chdir="$$stack" init -backend=false -input=false >/dev/null; \
		terraform -chdir="$$stack" validate; \
	done

lint: ## fmt check, ruff, checkov
	terraform fmt -check -recursive
	ruff check .
	ruff format --check .
	checkov --config-file .checkov.yaml

test: ## Run pytest (no tests collected is not a failure)
	pytest || [ $$? -eq 5 ]
