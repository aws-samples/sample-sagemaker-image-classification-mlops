# frontend-hosting

Static website hosting on Amazon S3 with an Amazon CloudFront distribution and Origin Access Control.

## What It Does

1. Creates a private, versioned, encrypted S3 bucket (public access blocked, lifecycle rule for old versions and stale multipart uploads)
2. Creates a CloudFront Origin Access Control (OAC) for S3 access
3. Creates a CloudFront distribution with `index.html` as the default root object, HTTPS redirect, a managed cache policy and custom error responses
4. Creates an S3 bucket policy that allows reads only from this distribution through OAC
5. Renders the page (`html_template_path`) and its other files (`asset_templates`, here `app.js` and `app.css`) with injected variables (in this sample the API URL and API key) and uploads them with `Cache-Control: no-cache`
6. Adds security response headers: HSTS, nosniff, frame options, referrer policy and a Content-Security-Policy that allows only the site's own script and stylesheet, `blob:` images and fetch calls to `connect_src`. The page has no inline script, style element or style attribute.
7. When `access_log_bucket` is set, sends the distribution's access logs there under `cloudfront/` with CloudFront standard logging (v2). Its CloudWatch Logs delivery source, destination and delivery are created in us-east-1. The bucket policy must let `delivery.logs.amazonaws.com` put objects under `cloudfront/` (condition `s3:x-amz-acl = bucket-owner-full-control`, `aws:SourceAccount`, `aws:SourceArn` of the delivery source); this delivery works with S3 Object Ownership BucketOwnerEnforced.

The distribution uses the default `*.cloudfront.net` certificate, with which the minimum viewer TLS version cannot be set (CloudFront uses the TLSv1 security policy), and has no AWS WAF web ACL; it serves only static files.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.15 |
| aws | ~> 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_log_delivery.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_delivery) | resource |
| [aws_cloudwatch_log_delivery_destination.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_delivery_destination) | resource |
| [aws_cloudwatch_log_delivery_source.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_delivery_source) | resource |
| [aws_cloudfront_distribution.frontend](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_distribution) | resource |
| [aws_cloudfront_origin_access_control.frontend](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_origin_access_control) | resource |
| [aws_cloudfront_response_headers_policy.security_headers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_response_headers_policy) | resource |
| [aws_s3_bucket.frontend](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.frontend](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_logging.frontend](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_logging) | resource |
| [aws_s3_bucket_ownership_controls.frontend](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.frontend](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.frontend](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.frontend](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.frontend](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_s3_object.site](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_object) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| bucket\_name | Name of the S3 bucket for frontend hosting | `string` | n/a | yes |
| html\_template\_path | Path to the HTML template file | `string` | n/a | yes |
| access\_log\_bucket | Name of the bucket that receives this bucket's S3 server access logs (under <bucket name>/) and the distribution's standard logs v2 (under cloudfront/). Its policy must let delivery.logs.amazonaws.com put objects under cloudfront/. Null = no access logging. | `string` | `null` | no |
| asset\_templates | Other files of the site: object key (app.js, app.css) to template path, rendered with template\_vars. Keys ending in .css are served as text/css, the rest as text/javascript. | `map(string)` | `{}` | no |
| connect\_src | URLs the page may call with fetch, for the Content-Security-Policy connect-src directive (for example the API's predict URL). Empty allows none. | `list(string)` | `[]` | no |
| force\_destroy | Allow bucket to be destroyed even if it contains objects | `bool` | `false` | no |
| kms\_key\_arn | KMS key ARN for the bucket's SSE-KMS encryption. Its key policy must let cloudfront.amazonaws.com decrypt for this distribution (origin access control). Null = SSE-S3. | `string` | `null` | no |
| tags | Tags to apply to resources | `map(string)` | `{}` | no |
| template\_vars | Variables to inject into the HTML template and asset\_templates | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| cloudfront\_distribution\_id | CloudFront distribution ID |
| cloudfront\_domain\_name | CloudFront distribution domain name |
| cloudfront\_url | CloudFront distribution URL |
| s3\_bucket\_name | Name of the S3 bucket |
<!-- END_TF_DOCS -->

## File Structure

```
modules/terraform-aws-frontend-hosting/
|-- main.tf          # S3 bucket, CloudFront OAC, distribution, headers policy, access logs, site upload
|-- outputs.tf       # S3 bucket name/URL, CloudFront URL/ID/domain
`-- variables.tf     # Bucket name, templates, template vars, connect_src, logging, tags, force_destroy
```
