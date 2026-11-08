# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# KICS: private static-asset bucket read only through CloudFront OAC; server access logging is the separate aws_s3_bucket_logging resource (access_log_bucket)
# kics-scan ignore-line
resource "aws_s3_bucket" "frontend" {
  bucket        = var.bucket_name
  force_destroy = var.force_destroy
  tags          = var.tags
}

resource "aws_s3_bucket_ownership_controls" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Block all public access - the bucket is private; CloudFront OAC is the
# only allowed reader.
resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning - lets us roll back a bad frontend deploy without rebuilding.
resource "aws_s3_bucket_versioning" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  versioning_configuration {
    status = "Enabled"
  }
}

# KMS encryption. Null = SSE-S3 (AES256); the stack passes the project CMK,
# which CloudFront reads through origin access control.
resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = var.kms_key_arn
      sse_algorithm     = var.kms_key_arn != null ? "aws:kms" : "AES256"
    }
    bucket_key_enabled = true
  }
}

# Lifecycle - expire non-current versions after 30 days + abort stale
# multiparts. Keeps the bucket from silently accumulating cost.
resource "aws_s3_bucket_lifecycle_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  rule {
    id     = "frontend-housekeeping"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  depends_on = [aws_s3_bucket_versioning.frontend]
}

resource "aws_s3_bucket_logging" "frontend" {
  count = var.access_log_bucket != null ? 1 : 0

  bucket        = aws_s3_bucket.frontend.id
  target_bucket = var.access_log_bucket
  target_prefix = "${aws_s3_bucket.frontend.id}/"
}

################################################################################
# CloudFront
################################################################################

# CloudFront Origin Access Control
resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.bucket_name}-oac"
  description                       = "OAC for frontend S3 bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

locals {
  # Exactly what the page loads: its own stylesheet and script, images the
  # visitor picks (blob: URLs), and fetch calls to connect_src only. The page
  # has no inline script, style element or style attribute.
  content_security_policy = join("; ", [
    "default-src 'none'",
    "script-src 'self'",
    "style-src 'self'",
    "img-src blob:",
    "connect-src ${length(var.connect_src) > 0 ? join(" ", var.connect_src) : "'none'"}",
    "base-uri 'none'",
    "form-action 'none'",
    "frame-ancestors 'self'",
  ])
}

# The headers of the AWS managed SecurityHeadersPolicy
# (67f7725c-6f97-4210-82d7-5512b31e9d03), with a stricter HSTS header
# (includeSubDomains, preload, override) and a Content-Security-Policy.
resource "aws_cloudfront_response_headers_policy" "security_headers" {
  name    = "${var.bucket_name}-security-headers"
  comment = "Security headers for the ${var.bucket_name} frontend"

  security_headers_config {
    content_security_policy {
      content_security_policy = local.content_security_policy
      override                = true
    }
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "SAMEORIGIN"
      override     = false
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = false
    }
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      preload                    = true
      override                   = true
    }
    xss_protection {
      protection = true
      mode_block = true
      override   = false
    }
  }
}

# S3 bucket policy: CloudFront access only, SSL-only transport
resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontServicePrincipal"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.frontend.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.frontend.arn
          }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.frontend.arn,
          "${aws_s3_bucket.frontend.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

# CloudFront distribution
# KICS: static demo UI; the API it calls has WAF. Access logs use standard logging (v2), the log delivery resources below, which KICS does not read
# kics-scan ignore-line
resource "aws_cloudfront_distribution" "frontend" {
  #checkov:skip=CKV_AWS_86:Access logs use standard logging (v2), the aws_cloudwatch_log_delivery resources in this module
  #checkov:skip=CKV_AWS_174:The minimum viewer TLS version can be set only with a custom certificate, which needs a custom domain; the default *.cloudfront.net certificate keeps TLSv1 (SECURITY.md Known limitations)
  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "S3-${aws_s3_bucket.frontend.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3-${aws_s3_bucket.frontend.id}"
    compress               = true
    viewer_protocol_policy = "redirect-to-https"

    # CachingOptimized managed policy - supersedes the deprecated
    # forwarded_values block. No query strings, no cookies, gzip + brotli.
    # https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-cache-policies.html
    cache_policy_id            = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security_headers.id
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # KICS: default *.cloudfront.net certificate for the demo; set acm_certificate_arn for a custom domain, then TLSv1.2_2021 applies
  # kics-scan ignore-line
  viewer_certificate {
    # KICS: same reason as the block above
    # kics-scan ignore-line
    cloudfront_default_certificate = true
    # With the default *.cloudfront.net certificate the minimum viewer TLS
    # version cannot be set: CloudFront uses the TLSv1 security policy and
    # ignores this value. It takes effect only with a custom certificate
    # (acm_certificate_arn with ssl_support_method = "sni-only").
    minimum_protocol_version = "TLSv1.2_2021"
  }

  lifecycle {
    # With the default certificate CloudFront stores TLSv1 whatever is set,
    # so without this every plan shows a change that applies as a no-op.
    ignore_changes = [viewer_certificate[0].minimum_protocol_version]
  }

  tags = var.tags
}

################################################################################
# Access logs (CloudFront standard logging v2)
################################################################################

# CloudFront delivers standard logs (v2) through CloudWatch Logs log delivery.
# For a distribution the source, destination and delivery are created in
# us-east-1 whatever the Region of the bucket. The logs go to
# cloudfront/ in access_log_bucket; this delivery writes as the bucket owner,
# so it works with S3 Object Ownership BucketOwnerEnforced, and the bucket
# policy must let delivery.logs.amazonaws.com put objects under cloudfront/.
locals {
  # Delivery names take letters, digits, _ and - only, up to 60 characters.
  access_log_name = "${substr(replace(var.bucket_name, ".", "-"), 0, 50)}-cf-logs"
}

resource "aws_cloudwatch_log_delivery_source" "access_logs" {
  count = var.access_log_bucket != null ? 1 : 0

  region       = "us-east-1"
  name         = local.access_log_name
  log_type     = "ACCESS_LOGS"
  resource_arn = aws_cloudfront_distribution.frontend.arn
  tags         = var.tags
}

resource "aws_cloudwatch_log_delivery_destination" "access_logs" {
  count = var.access_log_bucket != null ? 1 : 0

  region        = "us-east-1"
  name          = local.access_log_name
  output_format = "w3c"
  tags          = var.tags

  delivery_destination_configuration {
    destination_resource_arn = "arn:aws:s3:::${var.access_log_bucket}/cloudfront"
  }
}

resource "aws_cloudwatch_log_delivery" "access_logs" {
  count = var.access_log_bucket != null ? 1 : 0

  region                   = "us-east-1"
  delivery_source_name     = aws_cloudwatch_log_delivery_source.access_logs[0].name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.access_logs[0].arn
  tags                     = var.tags
}

################################################################################
# Static Content
################################################################################

# The page, its stylesheet and its script, rendered with template_vars. With
# SSE-KMS the object ETag is not an MD5, so source_hash tracks the content.
# no-cache keeps CloudFront (minimum TTL 1 s) and browsers on the current
# copy after a deploy.
locals {
  site_files = merge(
    { "index.html" = { content = templatefile(var.html_template_path, var.template_vars), type = "text/html" } },
    { for key, path in var.asset_templates : key => {
      content = templatefile(path, var.template_vars)
      type    = endswith(key, ".css") ? "text/css" : "text/javascript"
    } },
  )
}

resource "aws_s3_object" "site" {
  for_each = local.site_files

  bucket        = aws_s3_bucket.frontend.id
  key           = each.key
  content       = each.value.content
  content_type  = each.value.type
  cache_control = "no-cache"
  source_hash   = md5(each.value.content)
}

moved {
  from = aws_s3_object.index_html
  to   = aws_s3_object.site["index.html"]
}
