# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "bucket_name" {
  description = "Name of the S3 bucket for frontend hosting"
  type        = string
}

################################################################################
# Template
################################################################################

variable "html_template_path" {
  description = "Path to the HTML template file"
  type        = string
}

variable "template_vars" {
  description = "Variables to inject into the HTML template and asset_templates"
  type        = map(string)
  default     = {}
}

variable "asset_templates" {
  description = "Other files of the site: object key (app.js, app.css) to template path, rendered with template_vars. Keys ending in .css are served as text/css, the rest as text/javascript."
  type        = map(string)
  default     = {}
}

variable "connect_src" {
  description = "URLs the page may call with fetch, for the Content-Security-Policy connect-src directive (for example the API's predict URL). Empty allows none."
  type        = list(string)
  default     = []
}

################################################################################
# Tags
################################################################################

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

################################################################################
# S3 Options
################################################################################

variable "force_destroy" {
  description = "Allow bucket to be destroyed even if it contains objects"
  type        = bool
  default     = false
}

################################################################################
# Encryption
################################################################################

variable "kms_key_arn" {
  description = "KMS key ARN for the bucket's SSE-KMS encryption. Its key policy must let cloudfront.amazonaws.com decrypt for this distribution (origin access control). Null = SSE-S3."
  type        = string
  default     = null
}

variable "access_log_bucket" {
  description = "Name of the bucket that receives this bucket's S3 server access logs (under <bucket name>/) and the distribution's standard logs v2 (under cloudfront/). Its policy must let delivery.logs.amazonaws.com put objects under cloudfront/. Null = no access logging."
  type        = string
  default     = null
}
