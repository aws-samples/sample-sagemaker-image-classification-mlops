# frontend-hosting

Static website hosting on S3 with CloudFront distribution and Origin Access Control.

## What It Does

1. Creates a private, versioned, encrypted S3 bucket (public access blocked, lifecycle rule for old versions and stale multipart uploads)
2. Creates a CloudFront Origin Access Control (OAC) for S3 access
3. Creates a CloudFront distribution with `index.html` as the default root object, HTTPS redirect, a managed cache policy and custom error responses
4. Creates an S3 bucket policy that allows reads only from this distribution through OAC
5. Renders an HTML template with injected variables (in this sample the API URL and API key) and uploads it to S3

The distribution uses the default `*.cloudfront.net` certificate and has no WAF web ACL; it serves only static files.

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
| [aws_cloudfront_distribution.frontend](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_distribution) | resource |
| [aws_cloudfront_origin_access_control.frontend](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_origin_access_control) | resource |
| [aws_s3_bucket.frontend](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.frontend](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_policy.frontend](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.frontend](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.frontend](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.frontend](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_s3_object.index_html](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_object) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| bucket\_name | Name of the S3 bucket for frontend hosting | `string` | n/a | yes |
| html\_template\_path | Path to the HTML template file | `string` | n/a | yes |
| access\_log\_bucket\_domain | S3 bucket **regional domain name** (e.g. `my-log-bucket.s3.us-east-1.amazonaws.com`) that receives CloudFront access logs. Leave empty to disable access logging. The bucket must have `aws_s3_bucket_ownership_controls` set to `BucketOwnerPreferred` or the log-delivery writes will fail. | `string` | `""` | no |
| force\_destroy | Allow bucket to be destroyed even if it contains objects | `bool` | `false` | no |
| kms\_key\_arn | KMS CMK ARN used for S3 bucket encryption. Null = AES-256 (AWS-managed). CloudFront doesn't read through SSE-KMS objects so this only matters for direct S3 reads, which we block via public-access-block + OAC. | `string` | `null` | no |
| tags | Tags to apply to resources | `map(string)` | `{}` | no |
| template\_vars | Variables to inject into the HTML template | `map(string)` | `{}` | no |

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
|-- main.tf          # S3 bucket, CloudFront OAC, distribution, bucket policy, HTML upload
|-- outputs.tf       # S3 bucket name/URL, CloudFront URL/ID/domain
`-- variables.tf     # Bucket name, HTML template path, template vars, tags, force_destroy
```
