# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "repository_url" {
  description = "ECR repository URL for the patched image (push target)"
  value       = aws_ecr_repository.this.repository_url
}

output "repository_arn" {
  description = "ARN of the ECR repository"
  value       = aws_ecr_repository.this.arn
}

output "image_uri" {
  description = "Newest patched image pinned by digest (<repository_url>@sha256:...)"
  value       = "${aws_ecr_repository.this.repository_url}@${data.aws_ecr_image.newest.image_digest}"
}

output "image_tag" {
  description = "Dated tag of the newest patched image (YYYYMMDD-HHMMSS)"
  value       = try(data.aws_ecr_image.newest.image_tags[0], "")
}

################################################################################
# CodeBuild
################################################################################

output "codebuild_project_name" {
  description = "Name of the CodeBuild project that builds the patched image"
  value       = aws_codebuild_project.this.name
}

output "codebuild_project_arn" {
  description = "ARN of the CodeBuild project"
  value       = aws_codebuild_project.this.arn
}
