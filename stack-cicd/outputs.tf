# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "codepipeline_name" {
  description = "Name of the CodePipeline"
  value       = aws_codepipeline.pipeline.name
}

output "codepipeline_arn" {
  description = "ARN of the CodePipeline"
  value       = aws_codepipeline.pipeline.arn
}

################################################################################
# Artifacts
################################################################################

output "artifacts_bucket" {
  description = "S3 bucket for pipeline artifacts"
  value       = module.s3_codepipeline_artifacts.bucket_id
}

################################################################################
# CodeBuild
################################################################################

output "codebuild_projects" {
  description = "CodeBuild project names"
  value = {
    training_deploy  = module.codebuild_training_deploy.project_name
    script_upload    = module.codebuild_script_upload.project_name
    inference_deploy = module.codebuild_inference_deploy.project_name
  }
}

################################################################################
# GitHub
################################################################################

output "github_connection_arn" {
  description = "ARN of the AWS CodeConnections connection to GitHub"
  value       = aws_codestarconnections_connection.github.arn
}

output "github_connection_status" {
  description = "Status of the AWS CodeConnections connection to GitHub (PENDING until the handshake is completed in the console)"
  value       = aws_codestarconnections_connection.github.connection_status
}
