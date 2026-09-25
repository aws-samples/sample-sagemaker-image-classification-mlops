# ops-scripts

Operational helpers you run from your workstation: building the Lambda layer, fetching the dataset, testing the API, checking monitoring and cleaning up. The layer build is also called by `stack-inference` at apply time when the zip is missing; nothing else here is invoked by SageMaker, Lambda or CI/CD.

## What is in here

| Script | Purpose |
| --- | --- |
| `build_lambda_layer.sh` | Build the Pillow and NumPy layer zip for the inference Lambda (`make layer`) |
| `data_download_breakhis.sh` | Download BreakHis (about 4 GB) into `breast_benign/` and `breast_malignant/`, keeping the file names the patient split and fairness gate read |
| `test_api.py` | Send base64 images to `POST /predict` with the `x-api-key` header and compare predictions with the folder labels (needs `requests` and `Pillow`) |
| `ops_generate_endpoint_traffic.py` | Send labelled images straight to the endpoint to seed data capture for the drift job |
| `verify_monitoring.sh` | Check that the CloudWatch alarms, SNS topics and EventBridge rules exist |
| `cleanup_all.sh` | **Destructive.** Delete the endpoint, endpoint configs, models, model packages and job log groups, and empty the project buckets (never the state bucket). With `--destroy` it then runs `terraform destroy` in stack-cicd, stack-inference and stack-training (`make destroy`) |

## Typical usage

```bash
# Build the Lambda layer
./ops-scripts/build_lambda_layer.sh

# Fetch BreakHis, then upload it (the marker starts the pipeline)
./ops-scripts/data_download_breakhis.sh data/breakhis
./scripts/data_uploader.sh data/breakhis

# Call the deployed API (URL and key default to the terraform outputs)
python3 ops-scripts/test_api.py \
  --api-url "$(terraform -chdir=stack-inference output -raw api_gateway_url)" \
  --api-key "$(terraform -chdir=stack-inference output -raw api_key_value)" \
  --image-path data/breakhis/breast_benign/<file>.png

# Seed data capture for the drift job
python3 ops-scripts/ops_generate_endpoint_traffic.py --profile <profile> \
  --endpoint medical-image-classification-endpoint --requests 200

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
