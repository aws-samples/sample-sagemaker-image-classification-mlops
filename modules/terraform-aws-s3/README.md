# s3-bucket

Reusable S3 bucket with server-side encryption, optional versioning, public access blocking, and EventBridge notifications.

## What It Does

1. Creates an S3 bucket with configurable force-destroy behavior
2. Configures server-side encryption using KMS with an S3 Bucket Key (if a key is provided) or AES256 by default
3. Sets Object Ownership to BucketOwnerEnforced (ACLs disabled) by default
4. Optionally enables bucket versioning
5. Optionally blocks all public access (enabled by default)
6. Optionally enables EventBridge notifications for S3 events

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
| [aws_s3_bucket.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_logging.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_logging) | resource |
| [aws_s3_bucket_notification.eventbridge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_notification) | resource |
| [aws_s3_bucket_ownership_controls.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.ssl_only](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| bucket\_name | Name of the S3 bucket | `string` | n/a | yes |
| abort\_incomplete\_multipart\_days | Days after which incomplete multipart uploads are aborted. Applied as a baseline lifecycle rule on every bucket (stale multiparts don't show up in the console and silently accumulate cost). | `number` | `7` | no |
| block\_public\_access | Block all public access to the bucket | `bool` | `true` | no |
| enable\_eventbridge | Enable EventBridge notifications for S3 events | `bool` | `false` | no |
| enable\_ssl\_enforcement | Attach a bucket policy that denies all non-TLS (HTTP) access via the aws:SecureTransport condition. Default true. Set false when the caller manages the full bucket policy itself (e.g. the CloudTrail logs bucket has its own policy resource) to avoid two aws\_s3\_bucket\_policy resources fighting over the same bucket. | `bool` | `true` | no |
| enable\_versioning | Enable versioning on the bucket | `bool` | `false` | no |
| force\_destroy | Allow bucket to be destroyed even if it contains objects | `bool` | `false` | no |
| kms\_key\_arn | ARN of the KMS key for SSE-KMS encryption (optional). When set, an S3 Bucket Key is enabled. Null uses SSE-S3 (AES256). | `string` | `null` | no |
| lifecycle\_rules | Optional lifecycle rules for the bucket. Each rule may specify any of:<br/>- noncurrent\_version\_days: expire non-current object versions after N days (versioned buckets only)<br/>- expiration\_days: expire current objects after N days<br/>- abort\_incomplete\_multipart\_days: abort stale multipart uploads after N days<br/>- prefix: apply rule only to objects under this key prefix<br/>For versioned buckets we strongly recommend at least<br/>noncurrent\_version\_days, otherwise old versions accumulate forever. | <pre>list(object({<br/>    id                              = string<br/>    status                          = optional(string, "Enabled")<br/>    prefix                          = optional(string)<br/>    noncurrent_version_days         = optional(number)<br/>    expiration_days                 = optional(number)<br/>    abort_incomplete_multipart_days = optional(number)<br/>  }))</pre> | `[]` | no |
| logging\_target\_bucket | Name of a separate S3 bucket that receives server-access logs for this bucket. Null = no logging. The target bucket must grant PutObject to the log-delivery principal. | `string` | `null` | no |
| logging\_target\_prefix | Object-key prefix under logging\_target\_bucket for this bucket's logs. Null = <source-bucket-name>/ (easy grouping when many buckets log to one destination). | `string` | `null` | no |
| object\_ownership | S3 Object Ownership setting. BucketOwnerEnforced (default) disables ACLs. Use BucketOwnerPreferred only for a bucket that must accept ACL-based writes, such as CloudFront standard logs. | `string` | `"BucketOwnerEnforced"` | no |
| tags | Tags to apply to the bucket | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| bucket\_arn | The ARN of the bucket |
| bucket\_domain\_name | The bucket domain name |
| bucket\_id | The name of the bucket |
| bucket\_regional\_domain\_name | The bucket region-specific domain name |
<!-- END_TF_DOCS -->

## File Structure

```
modules/terraform-aws-s3/
|-- main.tf          # S3 bucket, encryption, object ownership, versioning, public access block, EventBridge
|-- outputs.tf       # Bucket ID, ARN, domain name, regional domain name
|-- README.md        # Module documentation
`-- variables.tf     # Bucket name, encryption, ownership, versioning, public access, EventBridge, tags
```
