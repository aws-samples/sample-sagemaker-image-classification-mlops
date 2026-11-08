# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

locals {
  # Account id of the DLC registry host, e.g. 763104351884.dkr.ecr.<region>.amazonaws.com.
  source_registry_account = split(".", var.source_registry)[0]
  source_repository_arn   = "arn:${data.aws_partition.current.partition}:ecr:${var.aws_region}:${local.source_registry_account}:repository/${var.source_repository}"
  build_log_group         = "/aws/codebuild/${var.project_name}-patched-image-build"

  # Public checksum of the syft 1.56.0 linux_amd64 release tarball, from the
  # release's checksums.txt.
  syft_sha256 = coalesce(var.syft_linux_amd64_sha256, "1c2493cfcf52d3367d6cb25780d9190c111c2219c34c820574c43e8bae15c528") # pragma: allowlist secret - public release checksum, not a secret
}

data "aws_partition" "current" {}

# Created before the first build, so CodeBuild never creates it without a CMK
# or a retention period.
resource "aws_cloudwatch_log_group" "build" {
  name              = local.build_log_group
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

# Every build pushes a new dated tag and consumers pin the digest, so tags never
# need to move.
resource "aws_ecr_repository" "this" {
  name                 = var.repository_name
  image_tag_mutability = "IMMUTABLE"
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
  name                 = "${var.project_name}-patched-image-build-role"
  description          = "Service role for the ${var.project_name} CodeBuild project that rebuilds the patched inference image"
  permissions_boundary = var.permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        Service = "codebuild.amazonaws.com"
      }
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.aws_account_id }
        ArnLike      = { "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:codebuild:${var.aws_region}:${var.aws_account_id}:project/${var.project_name}-patched-image-build" }
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
    Statement = concat([
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = [
          aws_cloudwatch_log_group.build.arn,
          "${aws_cloudwatch_log_group.build.arn}:*",
        ]
      },
      {
        # GetAuthorizationToken has no resource-level scoping.
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "PullSourceImage"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = local.source_repository_arn
      },
      {
        Sid    = "PushPatchedImage"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:DescribeImages",
        ]
        Resource = aws_ecr_repository.this.arn
      },
      {
        # scan-gate.sh: start a basic scan, read the findings, delete an image
        # that fails the gate.
        Sid    = "ScanGate"
        Effect = "Allow"
        Action = [
          "ecr:StartImageScan",
          "ecr:DescribeImageScanFindings",
          "ecr:BatchDeleteImage",
        ]
        Resource = aws_ecr_repository.this.arn
      },
      {
        # With Amazon Inspector enhanced scanning, DescribeImageScanFindings
        # returns Inspector findings, which needs ListFindings; it supports
        # only "*".
        Sid      = "ReadEnhancedScanFindings"
        Effect   = "Allow"
        Action   = ["inspector2:ListFindings"]
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
      ], var.sbom_bucket_arn != "" ? [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${var.sbom_bucket_arn}/sboms/*"
      },
    ] : [])
  })
}

resource "aws_codebuild_project" "this" {
  #checkov:skip=CKV_AWS_316:docker build of the patched image needs privileged mode (SECURITY.md Known limitations)
  name         = "${var.project_name}-patched-image-build"
  description  = "Rebuilds the inference image with the latest OS + Python patches"
  service_role = aws_iam_role.codebuild.arn

  # Encrypt the build output/cache with the project CMK.
  encryption_key = var.kms_key_arn

  # The build, push and scan gate (up to 20 minutes waiting for the scan)
  # must finish inside this limit, or the pushed image stays unchecked.
  build_timeout = 120

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_MEDIUM"
    image           = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # docker build needs the Docker daemon

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
      name  = "TARGET_REPO_NAME"
      value = aws_ecr_repository.this.name
    }
    environment_variable {
      name  = "SCAN_BLOCK_SEVERITY"
      value = var.scan_block_severity
    }
    environment_variable {
      name  = "SBOM_BUCKET"
      value = var.sbom_bucket
    }
    environment_variable {
      name  = "SYFT_VERSION"
      value = var.syft_version
    }
    environment_variable {
      name  = "SYFT_SHA256"
      value = local.syft_sha256
    }
  }

  source {
    type      = "NO_SOURCE"
    buildspec = local.buildspec
  }

  logs_config {
    cloudwatch_logs {
      status      = "ENABLED"
      group_name  = aws_cloudwatch_log_group.build.name
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
    # Apply all available OS-level security patches: dnf on the Amazon Linux
    # 2023 DLCs, apt on the Ubuntu ones.
    RUN if command -v dnf >/dev/null 2>&1; then \
            dnf -y upgrade --refresh && dnf clean all && rm -rf /var/cache/dnf; \
        else \
            apt-get update \
            && DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade \
            && apt-get -y autoremove \
            && apt-get clean \
            && rm -rf /var/lib/apt/lists/*; \
        fi
    # Upgrade core Python packaging tooling (ignore PEP 668 "externally managed"
    # restrictions - we are patching inside a container, not on a host system).
    RUN python3 -m pip install --break-system-packages --no-cache-dir --upgrade pip setuptools wheel || true
    # Upgrade every outdated third-party package except the TF stack itself
    # (TF is pinned by the DLC and should be left alone to preserve inference
    # behaviour). falcon stays at the DLC's version too: the DLC's Python
    # service still sets res.body, which falcon 4 removed. This runs
    # best-effort - a dependency that refuses to upgrade is not a show-stopper.
    RUN python3 -m pip list --outdated --format=json 2>/dev/null \
        | python3 -c "import json,sys,subprocess; pkgs=[p['name'] for p in json.load(sys.stdin) if p['name'] not in ('tensorflow','tensorflow-cpu','tensorflow-gpu','tensorflow-io-gcs-filesystem','tensorflow-metadata','tensorflow-serving-api','falcon')]; subprocess.run(['python3','-m','pip','install','--break-system-packages','--no-cache-dir','--upgrade']+pkgs, check=False) if pkgs else None" \
        || true
    DOCKER_EOF
  EOT

  # The scan gate runs as one command, written from the module's own file.
  scan_gate_heredoc = join("\n", [
    "cat > scan-gate.sh <<'GATE_EOF'",
    trimspace(file("${path.module}/scan-gate.sh")),
    "GATE_EOF",
  ])

  buildspec = yamlencode({
    version = 0.2
    phases = {
      pre_build = {
        commands = [
          "echo Logging in to source and target ECR registries...",
          "aws ecr get-login-password --region $${AWS_DEFAULT_REGION} | docker login --username AWS --password-stdin $${SOURCE_REGISTRY}",
          "aws ecr get-login-password --region $${AWS_DEFAULT_REGION} | docker login --username AWS --password-stdin $${AWS_ACCOUNT_ID}.dkr.ecr.$${AWS_DEFAULT_REGION}.amazonaws.com",
          "SOURCE_IMAGE=$${SOURCE_REGISTRY}/$${SOURCE_REPO}:$${SOURCE_TAG}",
          "DATE_TAG=$(date -u +%Y%m%d-%H%M%S)",
          "echo Source image: $${SOURCE_IMAGE}",
          "echo Target:       $${TARGET_REPO}:$${DATE_TAG}",
        ]
      }
      build = {
        commands = [
          # Materialise Dockerfile from a single heredoc command
          local.dockerfile_heredoc,
          "cat Dockerfile",
          # The repository is IMMUTABLE: each build pushes one new dated tag.
          "docker build --build-arg SOURCE_IMAGE=$${SOURCE_IMAGE} -t $${TARGET_REPO}:$${DATE_TAG} .",
          "docker push $${TARGET_REPO}:$${DATE_TAG}",
          "echo Pushed $${TARGET_REPO}:$${DATE_TAG}",
          # An image with a finding at or above scan_block_severity is deleted
          # here and fails the build, before anything can pin its digest.
          local.scan_gate_heredoc,
          "bash scan-gate.sh",
          # SBOM generation - only runs when SBOM_BUCKET is populated.
          # Syft emits CycloneDX JSON which Security Hub / Dependency Track /
          # most SCA tools can ingest directly. The image must already be
          # built (we scan the freshly-pushed image tag, not the source DLC).
          # The Syft release tarball must match both the pinned SHA-256 and
          # the release's checksums.txt before it is installed.
          #
          # CodeBuild runs each list element as its OWN shell invocation, so a
          # multi-line `if/then/fi` split across elements is a syntax error
          # ("unexpected end of file"). Keep the whole conditional in ONE
          # element joined with ; and &&.
          "if [ -n \"$${SBOM_BUCKET}\" ]; then SYFT_TGZ=syft_$${SYFT_VERSION}_linux_amd64.tar.gz && curl -sSfLO https://github.com/anchore/syft/releases/download/v$${SYFT_VERSION}/$${SYFT_TGZ} && curl -sSfLO https://github.com/anchore/syft/releases/download/v$${SYFT_VERSION}/syft_$${SYFT_VERSION}_checksums.txt && echo \"$${SYFT_SHA256}  $${SYFT_TGZ}\" | sha256sum -c - && grep \" $${SYFT_TGZ}$\" syft_$${SYFT_VERSION}_checksums.txt | sha256sum -c - && tar -xzf $${SYFT_TGZ} -C /usr/local/bin syft && syft $${TARGET_REPO}:$${DATE_TAG} -o cyclonedx-json=sbom-$${DATE_TAG}.cdx.json && aws s3 cp sbom-$${DATE_TAG}.cdx.json s3://$${SBOM_BUCKET}/sboms/$${DATE_TAG}.cdx.json && echo \"SBOM uploaded to s3://$${SBOM_BUCKET}/sboms/$${DATE_TAG}.cdx.json\"; else echo 'SBOM_BUCKET not set - skipping SBOM generation.'; fi",
        ]
      }
    }
  })
}

################################################################################
# Rebuild schedule - weekly by default, so a container patch reaches the
# endpoint at the next weekly refresh instead of waiting up to a month
################################################################################

resource "aws_cloudwatch_event_rule" "monthly_rebuild" {
  name                = "${var.project_name}-patched-image-rebuild"
  description         = "Rebuilds the patched inference image to pick up new OS and pip patches"
  schedule_expression = var.rebuild_schedule_expression

  tags = var.tags
}

resource "aws_iam_role" "events_codebuild" {
  name                 = "${var.project_name}-events-codebuild-role"
  description          = "Lets the ${var.project_name} EventBridge schedule start the patched inference image build"
  permissions_boundary = var.permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "events.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEqualsIfExists = { "aws:SourceAccount" = var.aws_account_id }
        ArnLikeIfExists      = { "aws:SourceArn" = aws_cloudwatch_event_rule.monthly_rebuild.arn }
      }
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

# A failed build (the scan gate rejected the image, or the build broke) leaves
# the endpoint on the last image that passed.
resource "aws_cloudwatch_metric_alarm" "build_failed" {
  alarm_name          = "${var.project_name}-patched-image-build-failed"
  alarm_description   = "The patched inference image build failed, for example because the scan gate rejected the image. The endpoint keeps its current image."
  namespace           = "AWS/CodeBuild"
  metric_name         = "FailedBuilds"
  dimensions          = { ProjectName = aws_codebuild_project.this.name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_actions

  tags = var.tags
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
# The endpoint and the auto-deploy Lambda pin the newest image by digest, so
# an image must exist before the first apply finishes. The rebuild schedule
# alone would leave a fresh deployment with an empty repository. This triggers
# ONE build at apply time and waits for it (AWS CLI via local-exec); gated by
# build_image_on_create.
resource "null_resource" "build_on_create" {
  count = var.build_image_on_create ? 1 : 0

  # Rebuild whenever the recipe or the base DLC tag changes.
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
      for i in $(seq 1 180); do
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

################################################################################
# Newest pushed image, pinned by digest
################################################################################

# Read after the bootstrap build so the first apply sees the image it just
# built. A scheduled rebuild pushes a new digest; the next apply picks it up,
# and the stack's weekly endpoint refresher repins to it without an apply.
data "aws_ecr_image" "newest" {
  repository_name = aws_ecr_repository.this.name
  most_recent     = true

  depends_on = [null_resource.build_on_create]
}
