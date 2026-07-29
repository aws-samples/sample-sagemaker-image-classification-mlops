# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

resource "aws_ecr_repository" "this" {
  name                 = var.repository_name
  image_tag_mutability = "MUTABLE" # we want `latest` to move
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  tags = var.tags
}

# Keep only the last 10 image versions
resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      },
    ]
  })
}

################################################################################
# CodeBuild project that builds & pushes the patched image
################################################################################

resource "aws_iam_role" "codebuild" {
  name = "${var.project_name}-patched-image-build-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        Service = "codebuild.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "codebuild" {
  name = "${var.project_name}-patched-image-build-policy"
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        # Public DLC pull + our private repo push
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:DescribeImages",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
          "kms:Encrypt",
        ]
        Resource = var.kms_key_arn
      },
      # SBOM upload - only granted when caller supplies an sbom_bucket_arn.
      # We use a conditional empty list so the policy doesn't reference a
      # wildcard resource when the feature is disabled.
      {
        Effect   = "Allow"
        Action   = var.sbom_bucket_arn != "" ? ["s3:PutObject", "s3:PutObjectAcl"] : []
        Resource = var.sbom_bucket_arn != "" ? ["${var.sbom_bucket_arn}/sboms/*"] : []
      },
    ]
  })
}

resource "aws_codebuild_project" "this" {
  name         = "${var.project_name}-patched-image-build"
  description  = "Rebuilds the inference image with the latest OS + Python patches"
  service_role = aws_iam_role.codebuild.arn

  # Encrypt the build output/cache with the project CMK.
  encryption_key = var.kms_key_arn

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_MEDIUM"
    image           = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # required for docker build

    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.aws_region
    }
    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = var.aws_account_id
    }
    environment_variable {
      name  = "SOURCE_REGISTRY"
      value = var.source_registry
    }
    environment_variable {
      name  = "SOURCE_REPO"
      value = var.source_repository
    }
    environment_variable {
      name  = "SOURCE_TAG"
      value = var.source_tag
    }
    environment_variable {
      name  = "TARGET_REPO"
      value = aws_ecr_repository.this.repository_url
    }
    environment_variable {
      name  = "SBOM_BUCKET"
      value = var.sbom_bucket
    }
  }

  source {
    type      = "NO_SOURCE"
    buildspec = local.buildspec
  }

  logs_config {
    cloudwatch_logs {
      status      = "ENABLED"
      group_name  = "/aws/codebuild/${var.project_name}-patched-image-build"
      stream_name = "build"
    }
  }

  tags = var.tags
}

locals {
  # The Dockerfile is materialised by a single shell command in the build
  # phase. Writing it as one heredoc preserves its lines; if we used one
  # YAML list entry per Dockerfile line, CodeBuild would execute each line
  # as an independent shell command.
  dockerfile_heredoc = <<-EOT
    cat > Dockerfile <<'DOCKER_EOF'
    ARG SOURCE_IMAGE
    FROM $${SOURCE_IMAGE}
    USER root
    # Apply all available OS-level security patches
    RUN apt-get update \
        && DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade \
        && apt-get -y autoremove \
        && apt-get clean \
        && rm -rf /var/lib/apt/lists/*
    # Upgrade core Python packaging tooling (ignore PEP 668 "externally managed"
    # restrictions - we are patching inside a container, not on a host system).
    RUN python3 -m pip install --break-system-packages --no-cache-dir --upgrade pip setuptools wheel || true
    # Upgrade every outdated third-party package except the TF stack itself
    # (TF is pinned by the DLC and should be left alone to preserve inference
    # behaviour). This runs best-effort - a dependency that refuses to upgrade
    # is not a show-stopper.
    RUN python3 -m pip list --outdated --format=json 2>/dev/null \
        | python3 -c "import json,sys,subprocess; pkgs=[p['name'] for p in json.load(sys.stdin) if p['name'] not in ('tensorflow','tensorflow-cpu','tensorflow-gpu','tensorflow-io-gcs-filesystem','tensorflow-metadata','tensorflow-serving-api')]; subprocess.run(['python3','-m','pip','install','--break-system-packages','--no-cache-dir','--upgrade']+pkgs, check=False) if pkgs else None" \
        || true
    DOCKER_EOF
  EOT

  buildspec = yamlencode({
    version = 0.2
    phases = {
      pre_build = {
        commands = [
          "echo Logging in to source and target ECR registries...",
          "aws ecr get-login-password --region $${AWS_DEFAULT_REGION} | docker login --username AWS --password-stdin $${SOURCE_REGISTRY}",
          "aws ecr get-login-password --region $${AWS_DEFAULT_REGION} | docker login --username AWS --password-stdin $${AWS_ACCOUNT_ID}.dkr.ecr.$${AWS_DEFAULT_REGION}.amazonaws.com",
          "SOURCE_IMAGE=$${SOURCE_REGISTRY}/$${SOURCE_REPO}:$${SOURCE_TAG}",
          "DATE_TAG=$(date -u +%Y%m%d-%H%M)",
          "echo Source image: $${SOURCE_IMAGE}",
          "echo Target:       $${TARGET_REPO}:$${DATE_TAG}",
        ]
      }
      build = {
        commands = [
          # Materialise Dockerfile from a single heredoc command
          local.dockerfile_heredoc,
          "cat Dockerfile",
          "SOURCE_IMAGE=$${SOURCE_REGISTRY}/$${SOURCE_REPO}:$${SOURCE_TAG}",
          "DATE_TAG=$(date -u +%Y%m%d-%H%M)",
          "docker build --build-arg SOURCE_IMAGE=$${SOURCE_IMAGE} -t $${TARGET_REPO}:$${DATE_TAG} -t $${TARGET_REPO}:latest .",
          "docker push $${TARGET_REPO}:$${DATE_TAG}",
          "docker push $${TARGET_REPO}:latest",
          "echo Pushed $${TARGET_REPO}:$${DATE_TAG}",
          "echo Pushed $${TARGET_REPO}:latest",
          # SBOM generation - only runs when SBOM_BUCKET is populated.
          # Syft emits CycloneDX JSON which Security Hub / Dependency Track /
          # most SCA tools can ingest directly. The image must already be
          # built (we scan the freshly-pushed image tag, not the source DLC).
          #
          # CodeBuild runs each list element as its OWN shell invocation, so a
          # multi-line `if/then/fi` split across elements is a syntax error
          # ("unexpected end of file"). Keep the whole conditional in ONE
          # element joined with ; and &&.
          "if [ -n \"$${SBOM_BUCKET}\" ]; then echo 'Installing Syft...'; curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin && echo \"Generating SBOM for $${TARGET_REPO}:$${DATE_TAG}...\" && syft $${TARGET_REPO}:$${DATE_TAG} -o cyclonedx-json=sbom-$${DATE_TAG}.cdx.json && aws s3 cp sbom-$${DATE_TAG}.cdx.json s3://$${SBOM_BUCKET}/sboms/$${DATE_TAG}.cdx.json && echo \"SBOM uploaded to s3://$${SBOM_BUCKET}/sboms/$${DATE_TAG}.cdx.json\"; else echo 'SBOM_BUCKET not set - skipping SBOM generation.'; fi",
        ]
      }
    }
  })
}

################################################################################
# Monthly schedule - rebuilds the image so patches keep accumulating
################################################################################

resource "aws_cloudwatch_event_rule" "monthly_rebuild" {
  name                = "${var.project_name}-patched-image-monthly-rebuild"
  description         = "Rebuilds the patched inference image monthly to pick up new OS and pip patches"
  schedule_expression = "cron(0 5 1 * ? *)" # 05:00 UTC on the 1st of each month

  tags = var.tags
}

resource "aws_iam_role" "events_codebuild" {
  name = "${var.project_name}-events-codebuild-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "events.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "events_codebuild" {
  name = "${var.project_name}-events-codebuild-policy"
  role = aws_iam_role.events_codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "codebuild:StartBuild"
      Resource = aws_codebuild_project.this.arn
    }]
  })
}

resource "aws_cloudwatch_event_target" "monthly_rebuild" {
  rule      = aws_cloudwatch_event_rule.monthly_rebuild.name
  target_id = "codebuild"
  arn       = aws_codebuild_project.this.arn
  role_arn  = aws_iam_role.events_codebuild.arn
}

################################################################################
# First-build bootstrap (no manual step)
################################################################################
#
# The auto-deploy Lambda deploys models using this patched image's `:latest`
# tag, so the image must exist before the first model approval. The monthly
# schedule alone would leave a fresh deployment with an empty repository. This
# triggers ONE build at apply time and waits for it to finish, so a clean
# `terraform apply` yields a usable image with no manual `start-build`.
# Uses local-exec (AWS CLI) rather than CDK; gated by build_image_on_create.
resource "null_resource" "build_on_create" {
  count = var.build_image_on_create ? 1 : 0

  # Re-run the bootstrap build whenever the image recipe changes, not just on
  # first create. Keying only on the (stable) project name would mean buildspec
  # or Dockerfile edits never trigger a rebuild and a stale `:latest` keeps
  # serving. source_tag is included so a new base DLC tag also rebuilds.
  triggers = {
    project    = aws_codebuild_project.this.name
    buildspec  = sha1(local.buildspec)
    dockerfile = sha1(local.dockerfile_heredoc)
    source_tag = var.source_tag
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      echo "Starting first patched-image build: ${aws_codebuild_project.this.name}"
      BID=$(aws codebuild start-build --project-name ${aws_codebuild_project.this.name} --region ${var.aws_region} --query 'build.id' --output text)
      echo "Build id: $BID - waiting for completion..."
      for i in $(seq 1 60); do
        ST=$(aws codebuild batch-get-builds --ids "$BID" --region ${var.aws_region} --query 'builds[0].buildStatus' --output text)
        if [ "$ST" = "SUCCEEDED" ]; then echo "Patched image built."; exit 0; fi
        if [ "$ST" = "FAILED" ] || [ "$ST" = "FAULT" ] || [ "$ST" = "STOPPED" ] || [ "$ST" = "TIMED_OUT" ]; then echo "Build $ST"; exit 1; fi
        sleep 20
      done
      echo "Timed out waiting for build"; exit 1
    EOT
  }

  depends_on = [aws_codebuild_project.this, aws_iam_role_policy.codebuild]
}
