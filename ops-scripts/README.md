# ops-scripts

Operational helpers you run from your workstation: building the AWS Lambda layer, testing the API, seeding the endpoint, checking monitoring and cleaning up. The layer build is also called by `stack-inference` at apply time when the zip is missing; nothing else here is invoked by Amazon SageMaker AI, Lambda or CI/CD. The sample ships no dataset and no download script: bring your own labeled images (see [Datasets and model weights](../README.md#datasets-and-model-weights)).

## What is in here

| Script | Purpose |
| --- | --- |
| `build_lambda_layer.sh` | Build the Pillow and NumPy layer zip for the inference Lambda (`make layer`) |
| `test_api.py` | Send base64 images to the Amazon API Gateway `POST /predict` route with the `x-api-key` header (URL and key from `--api-url`/`--api-key` or the `API_URL`/`API_KEY` environment variables) and compare predictions with the folder labels (needs `requests` and `Pillow`) |
| `ops_generate_endpoint_traffic.py` | Send labelled images from `--data-path` (a dataset root with one folder per class) straight to the endpoint to seed data capture for the drift job, once. For hourly synthetic traffic on a test deployment, use `test_traffic_enabled` in `stack-inference` instead ([Test traffic](../stack-inference/README.md#test-traffic)) |
| `verify_monitoring.sh` | Check that the Amazon CloudWatch alarms, Amazon SNS topics and Amazon EventBridge rules exist |
| `cleanup_all.sh` | **Destructive.** Stop running pipeline executions, delete the endpoint, endpoint configs, models, model packages and job log groups, and empty the project Amazon S3 buckets (never the state bucket). With `--destroy` it then runs `terraform destroy` in stack-cicd, stack-inference and stack-training (`make destroy`); without it, it is the pre-destroy step for running `terraform destroy` in each stack yourself |

## Typical usage

```bash
# Build the Lambda layer
./ops-scripts/build_lambda_layer.sh

# Upload your own labeled images, one folder per class, to s3://<raw-data-bucket>/images/
# (the marker it writes starts the pipeline)
./scripts/data_uploader.sh data/my-images

# Call the deployed API (pass --api-url and --api-key, or set API_URL and API_KEY)
export API_URL="$(terraform -chdir=stack-inference output -raw api_gateway_url)"
export API_KEY="$(terraform -chdir=stack-inference output -raw api_key_value)"
python3 ops-scripts/test_api.py --image-path data/my-images/<class>/<file>.png

# Seed data capture for the drift job (labelled images, one folder per class)
python3 ops-scripts/ops_generate_endpoint_traffic.py --profile <profile> \
  --data-path data/my-images --endpoint image-classification-endpoint --requests 200

# Check monitoring after a deploy
./ops-scripts/verify_monitoring.sh

# Clean up and destroy (asks you to type the project name)
./ops-scripts/cleanup_all.sh --profile <profile> --destroy
```

Run `./ops-scripts/cleanup_all.sh --help` for `--project`, `--region`, `--state-bucket` and `--yes`.

## Naming convention

- Shell: `snake_case.sh` (for example `build_lambda_layer.sh`)
- Python: `snake_case.py` (for example `test_api.py`)
- Verb-first for action scripts: `build_*`, `cleanup_*`, `verify_*`, `test_*`
