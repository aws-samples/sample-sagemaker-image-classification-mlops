# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import base64
import json
import logging
import os

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ImageNet channel statistics. Normalization is /255 then per-channel
# (x - mean) / std. These MUST match scripts/training/_common.py so production
# inference applies the exact transform training used (no training-serving skew).
IMAGENET_MEAN = [0.485, 0.456, 0.406]
IMAGENET_STD = [0.229, 0.224, 0.225]


def proper_image_preprocess(base64_image):
    """
    Image preprocessing with PIL and numpy. Mirrors the training transform:
    resize to 224x224, scale to 0-1, then align to ImageNet mean/std.
    """
    try:
        import io

        import numpy as np
        from PIL import Image

        # Decode base64 strictly so malformed input fails cleanly here rather
        # than deep in PIL.
        try:
            image_data = base64.b64decode(base64_image, validate=True)
        except (ValueError, TypeError) as exc:
            raise ValueError("Invalid base64 image encoding") from exc

        # Decompression-bomb guard: cap the total pixel count PIL will
        # materialize so a small payload can't expand to GBs of RAM and OOM the
        # function. 25 MP is far above any real histopathology tile.
        Image.MAX_IMAGE_PIXELS = 25_000_000

        # Open + verify it is a real, supported image before doing any work.
        img = Image.open(io.BytesIO(image_data))
        if img.format not in ("JPEG", "PNG", "BMP"):
            raise ValueError(f"Unsupported image format: {img.format}")
        # Reject absurd dimensions up front (defense in depth alongside the
        # pixel cap above, which raises DecompressionBombError on its own).
        if img.width > 12000 or img.height > 12000:
            raise ValueError(f"Image dimensions too large: {img.width}x{img.height}")

        # Convert to RGB and resize to 224x224 (same as training)
        img = img.convert("RGB").resize((224, 224))

        # Scale to 0-1, then apply ImageNet mean/std (same as training)
        img_array = np.array(img).astype(np.float32) / 255.0
        img_array = (img_array - np.array(IMAGENET_MEAN, dtype=np.float32)) / np.array(
            IMAGENET_STD, dtype=np.float32
        )

        return img_array.tolist()

    except Exception as e:
        logger.error(f"Image preprocessing error: {e!s}")
        raise ValueError(f"Failed to process image: {e!s}") from e


def bedrock_explain(base64_image, prediction, confidence):
    """Route a low-confidence prediction to a Bedrock foundation model for
    natural-language reasoning (Part 3 hybrid inference).

    Returns the FM reasoning text, or None on any failure (the primary
    prediction is always returned regardless). Uses the Nova InvokeModel
    messages-v1 schema with a base64 image part. Docs:
    https://docs.aws.amazon.com/nova/latest/userguide/modalities-image-examples.html
    """
    try:
        model_id = os.environ.get("BEDROCK_MODEL_ID", "us.amazon.nova-pro-v1:0")
        bedrock = boto3.client("bedrock-runtime")
        native_request = {
            "schemaVersion": "messages-v1",
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {"image": {"format": "png", "source": {"bytes": base64_image}}},
                        {
                            "text": (
                                "You are assisting a radiologist. A custom classifier predicted "
                                f"'{prediction}' with {confidence:.0%} confidence, which is below the "
                                "confidence threshold. Describe the visual findings in this "
                                "histopathology image and whether they appear benign or malignant. "
                                "Be concise and note this is decision support, not a diagnosis."
                            )
                        },
                    ],
                }
            ],
            "inferenceConfig": {"maxTokens": 300, "temperature": 0.2, "topP": 0.9},
        }
        # Apply the Bedrock guardrail to the FM output when configured (Part 4):
        # filters unsafe content and anonymizes PII in the generated reasoning.
        invoke_kwargs = {"modelId": model_id, "body": json.dumps(native_request)}
        guardrail_id = os.environ.get("BEDROCK_GUARDRAIL_ID", "")
        guardrail_version = os.environ.get("BEDROCK_GUARDRAIL_VERSION", "")
        if guardrail_id and guardrail_version:
            invoke_kwargs["guardrailIdentifier"] = guardrail_id
            invoke_kwargs["guardrailVersion"] = guardrail_version
        response = bedrock.invoke_model(**invoke_kwargs)
        body = json.loads(response["body"].read())
        return body["output"]["message"]["content"][0]["text"]
    except Exception as e:
        logger.warning(f"Bedrock hybrid reasoning failed (returning primary prediction): {e!s}")
        return None


def start_human_review(request_id, image_s3_uri, prediction, confidence):
    """Start an Amazon A2I human loop for a low-confidence prediction (Part 4).

    The radiologist's decision is written to the flow definition's S3 output and
    becomes ground truth for the next retraining cycle. No-op (returns None) if
    FLOW_DEFINITION_ARN is unset. Best-effort: never blocks the prediction.
    """
    flow_arn = os.environ.get("FLOW_DEFINITION_ARN", "")
    if not flow_arn:
        return None
    try:
        a2i = boto3.client("sagemaker-a2i-runtime")
        a2i.start_human_loop(
            HumanLoopName=f"review-{request_id}",
            FlowDefinitionArn=flow_arn,
            HumanLoopInput={
                "InputContent": json.dumps(
                    {
                        "image_s3_uri": image_s3_uri,
                        "prediction": prediction,
                        "confidence": round(confidence, 4),
                    }
                )
            },
        )
        return f"review-{request_id}"
    except Exception as e:
        logger.warning(f"Failed to start human review loop: {e!s}")
        return None


def save_prediction_data(s3_client, bucket, prediction_data, image_data, request_id):
    """Save prediction data for monitoring and persist the full input image.

    Keys everything under the request_id so a human reviewer (A2I) can fetch the
    exact image that produced a given prediction. Returns the S3 URI of the
    persisted image (or None on failure / no bucket) so the caller can hand it
    to start_human_review.
    """
    if not bucket:
        return None
    try:
        import base64 as _b64
        from datetime import datetime

        timestamp = datetime.now()
        date_prefix = timestamp.strftime("%Y/%m/%d")
        base_key = f"predictions/{date_prefix}/{request_id}"
        image_key = f"{base_key}/input.png"
        record_key = f"{base_key}/prediction.json"

        # Persist the FULL image as a viewable object (not a 1KB base64 prefix),
        # so the A2I reviewer can actually see what was classified.
        if image_data:
            try:
                s3_client.put_object(
                    Bucket=bucket,
                    Key=image_key,
                    Body=_b64.b64decode(image_data),
                    ContentType="image/png",
                )
            except Exception as img_exc:
                logger.warning(f"Failed to persist input image: {img_exc}")

        monitoring_data = {
            "request_id": request_id,
            "timestamp": timestamp.isoformat(),
            "prediction": prediction_data["prediction"],
            "confidence": prediction_data["confidence"],
            "probabilities": prediction_data["probabilities"],
            # Simple feature for drift
            "input_features": [prediction_data["confidence"]],
            "image_size": len(image_data) if image_data else 0,
            "image_s3_uri": f"s3://{bucket}/{image_key}" if image_data else None,
        }

        s3_client.put_object(
            Bucket=bucket,
            Key=record_key,
            Body=json.dumps(monitoring_data),
            ContentType="application/json",
        )

        logger.info(f"Saved prediction data to {record_key}")
        return f"s3://{bucket}/{image_key}" if image_data else None

    except Exception as e:
        logger.warning(f"Failed to save prediction data: {e!s}")
        return None


def _cors_headers():
    return {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "Content-Type",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    }


def fetch_prediction_result(s3_client, bucket, request_id):
    """Look up a stored prediction by request id for GET /results/{id}.

    save_prediction_data writes to predictions/<YYYY>/<MM>/<DD>/<id>/prediction.json.
    The caller supplies only the id, so the date is unknown - list on the id's
    own prefix across a small window of recent days rather than scanning the
    whole predictions/ tree.
    """
    from datetime import datetime, timedelta

    if not bucket:
        return None
    today = datetime.utcnow()
    for days_ago in range(3):
        day = today - timedelta(days=days_ago)
        key = f"predictions/{day.strftime('%Y/%m/%d')}/{request_id}/prediction.json"
        try:
            obj = s3_client.get_object(Bucket=bucket, Key=key)
            return json.loads(obj["Body"].read())
        except ClientError as e:
            if e.response["Error"]["Code"] not in ("NoSuchKey", "404"):
                raise
    return None


def lambda_handler(event, context):
    """
    Handle inference API requests with simplified image preprocessing
    """
    try:
        logger.info(f"Received event: {json.dumps(event)}")

        # GET /results/{id} - retrieve a previously stored prediction. Routed
        # here by the same API Gateway integration as POST /predict, so it must
        # be dispatched before any body parsing (a GET has no body).
        path_params = event.get("pathParameters") or {}
        http_method = (event.get("httpMethod") or "").upper()
        if http_method == "GET" or path_params.get("id"):
            request_id = path_params.get("id")
            if not request_id:
                return {
                    "statusCode": 400,
                    "headers": _cors_headers(),
                    "body": json.dumps({"error": "Missing result id"}),
                }
            result = fetch_prediction_result(
                boto3.client("s3"), os.environ.get("INFERENCE_BUCKET"), request_id
            )
            if result is None:
                return {
                    "statusCode": 404,
                    "headers": _cors_headers(),
                    "body": json.dumps({"error": "Result not found", "request_id": request_id}),
                }
            return {"statusCode": 200, "headers": _cors_headers(), "body": json.dumps(result)}

        # Get environment variables
        endpoint_name = os.environ.get("ENDPOINT_NAME")

        if not endpoint_name:
            return {
                "statusCode": 500,
                "headers": {
                    "Content-Type": "application/json",
                    "Access-Control-Allow-Origin": "*",
                    "Access-Control-Allow-Headers": "Content-Type",
                    "Access-Control-Allow-Methods": "POST, OPTIONS",
                },
                "body": json.dumps({"error": "Endpoint name not configured"}),
            }

        # Parse request body
        if isinstance(event.get("body"), str):
            body = json.loads(event["body"])
        else:
            # `or {}` not a get() default: API Gateway sends the key with an
            # explicit null for body-less requests, so the default never fires
            # and body.get() below would raise AttributeError on None.
            body = event.get("body") or {}

        image_data = body.get("image")
        image_len = len(image_data) if image_data else 0
        logger.info(f"Image data length: {image_len}")

        if not image_data:
            return {
                "statusCode": 400,
                "headers": {
                    "Content-Type": "application/json",
                    "Access-Control-Allow-Origin": "*",
                    "Access-Control-Allow-Headers": "Content-Type",
                    "Access-Control-Allow-Methods": "POST, OPTIONS",
                },
                "body": json.dumps({"error": "Missing image data"}),
            }

        # Hard size check BEFORE invoking SageMaker. Without this, a client
        # can POST a 10 MB base64 blob, force Lambda into a higher memory
        # tier, and run up a SageMaker invocation bill. Default MAX_IMAGE_BYTES
        # is 5 MB (set in Terraform); returns 413 Payload Too Large on breach.
        max_bytes = int(os.environ.get("MAX_IMAGE_BYTES", "5242880"))
        if image_len > max_bytes:
            logger.warning(f"Rejecting oversized image: {image_len} bytes > {max_bytes} bytes")
            return {
                "statusCode": 413,
                "headers": {
                    "Content-Type": "application/json",
                    "Access-Control-Allow-Origin": "*",
                    "Access-Control-Allow-Headers": "Content-Type",
                    "Access-Control-Allow-Methods": "POST, OPTIONS",
                },
                "body": json.dumps(
                    {
                        "error": "Payload too large",
                        "max_bytes": max_bytes,
                        "received_bytes": image_len,
                    }
                ),
            }

        # Initialize SageMaker runtime
        sagemaker_runtime = boto3.client("sagemaker-runtime")

        try:
            # Skip status check during blue-green deployment - let SageMaker handle routing

            # Preprocess the image using proper PIL/numpy approach
            processed_image = proper_image_preprocess(image_data)

            # SageMaker TF-serving payload: a batch of one already-normalized
            # image (ImageNet mean/std applied in proper_image_preprocess).
            payload = {"instances": [processed_image]}
            logger.info(
                f"Sending payload with shape: {len(processed_image)}x{len(processed_image[0])}x{len(processed_image[0][0])}"
            )

            response = sagemaker_runtime.invoke_endpoint(
                EndpointName=endpoint_name, ContentType="application/json", Body=json.dumps(payload)
            )

            # Parse prediction result
            response_body = response["Body"].read().decode()
            logger.info(f"SageMaker response: {response_body}")
            result = json.loads(response_body)
            logger.info(f"Parsed result: {result}")
            logger.info(
                f"Result type: {type(result)}, Keys: {result.keys() if isinstance(result, dict) else 'Not a dict'}"
            )

            # Handle ensemble model response format
            if isinstance(result, list) and len(result) > 0:
                # Ensemble format: [{"predicted_class": "benign", "confidence": 0.85, "probabilities": {...}}]
                prediction_obj = result[0]
                if isinstance(prediction_obj, dict):
                    if "probabilities" in prediction_obj:
                        # Use malignant probability from ensemble response
                        score = prediction_obj["probabilities"].get("malignant", 0.5)
                    elif "confidence" in prediction_obj and "predicted_class" in prediction_obj:
                        # Convert confidence to malignant probability
                        if prediction_obj["predicted_class"] == "malignant":
                            score = prediction_obj["confidence"]
                        else:
                            score = 1.0 - prediction_obj["confidence"]
                    else:
                        score = 0.5
                else:
                    # Fallback for numeric response
                    score = float(prediction_obj)
            elif "predictions" in result:
                # Ensemble serving format (scripts/ensemble/inference.py):
                # {"predictions": <malignant-prob>, "threshold_used": X}.
                # predictions may be [score] or [[score]] depending on shape.
                pred = result["predictions"]
                while isinstance(pred, list) and len(pred) > 0:
                    pred = pred[0]
                score = float(pred)
            else:
                logger.error(f"Unknown response format: {result}")
                score = 0.5

            # Use the clinically-tuned threshold the ensemble computed. It is
            # returned at the top level for the dict response and inside the
            # first element for the list response. Honoring it matters for a
            # recall-optimized model: forcing 0.5 raises the false-negative
            # (missed-malignant) rate the quality gate is designed to minimize.
            optimal_threshold = 0.5
            try:
                if isinstance(result, dict):
                    optimal_threshold = float(result.get("threshold_used", 0.5))
                elif isinstance(result, list) and len(result) > 0 and isinstance(result[0], dict):
                    optimal_threshold = float(result[0].get("threshold_used", 0.5))
            except (KeyError, TypeError, IndexError, ValueError):
                # Response shape may vary if the ensemble format evolves;
                # the default 0.5 threshold is a safe fallback.
                pass

            prediction = "malignant" if score > optimal_threshold else "benign"
            # Confidence is P(predicted class): the malignant probability for a
            # malignant call, its complement for benign. (For threshold != 0.5
            # this is the class probability, not distance-from-boundary.)
            confidence = float(score) if prediction == "malignant" else float(1 - score)

            # Per-request id ties this prediction to its monitoring record and
            # any explainability artifact, so a clinician/auditor can trace it.
            request_id = context.aws_request_id if context else "local"

            # Format response
            formatted_result = {
                "request_id": request_id,
                "prediction": prediction,
                "confidence": confidence,
                "probabilities": {"benign": float(1 - score), "malignant": float(score)},
                "model_info": "Image analysis using ensemble model",
                "processing_note": "Using proper PIL/numpy preprocessing - matches training pipeline",
            }

            # Explainability (Part 4): Grad-CAM/SHAP for the served ensemble runs
            # as an asynchronous SageMaker job (the served SavedModel hides the
            # conv layers Grad-CAM needs, and the API Lambda has no TF runtime),
            # so the synchronous response returns a pointer to where that
            # artifact is written rather than computing it inline. EXPLAIN_BUCKET
            # is set when async explainability is enabled.
            explain_bucket = os.environ.get("EXPLAIN_BUCKET", "")
            if explain_bucket:
                formatted_result["explainability"] = {
                    "heatmap_s3_uri": f"s3://{explain_bucket}/explainability/{request_id}/gradcam.png",
                    "status": "async-pending",
                    "method": "grad-cam+shap",
                }

            # Hybrid inference: when the custom model is not confident, ask a
            # Bedrock foundation model for additional reasoning. Off unless
            # ENABLE_BEDROCK_HYBRID is set (see Terraform var). The primary
            # prediction is always returned; Bedrock only adds explanation.
            bedrock_threshold = float(os.environ.get("BEDROCK_CONFIDENCE_THRESHOLD", "0.70"))
            is_low_confidence = confidence < bedrock_threshold
            if (
                os.environ.get("ENABLE_BEDROCK_HYBRID", "false").lower() == "true"
                and is_low_confidence
            ):
                reasoning = bedrock_explain(image_data, prediction, confidence)
                if reasoning:
                    formatted_result["reasoning"] = reasoning
                    formatted_result["routing"] = "low-confidence-bedrock"
                else:
                    formatted_result["routing"] = "low-confidence-bedrock-unavailable"
            else:
                formatted_result["routing"] = "high-confidence-custom"

            # Save prediction data for monitoring and persist the full input
            # image first, so the human-review queue can point at the REAL
            # image key (not a placeholder).
            s3_client = boto3.client("s3")
            image_s3_uri = save_prediction_data(
                s3_client,
                os.environ.get("INFERENCE_BUCKET"),
                formatted_result,
                image_data,
                request_id,
            )

            # Human-in-the-loop: a low-confidence case also goes to a radiologist
            # review queue (Part 4), with the persisted image URI so the reviewer
            # sees exactly what was classified. Best-effort.
            if is_low_confidence and os.environ.get("FLOW_DEFINITION_ARN"):
                review_id = start_human_review(
                    request_id,
                    image_s3_uri or f"s3://{os.environ.get('INFERENCE_BUCKET', '')}/predictions",
                    prediction,
                    confidence,
                )
                if review_id:
                    formatted_result["human_review"] = review_id

            # Log comprehensive metrics
            cloudwatch = boto3.client("cloudwatch")

            # Determine confidence level
            high_confidence = 1 if confidence > 0.8 else 0
            low_confidence = 1 if confidence < 0.6 else 0

            metrics_data = [
                {"MetricName": "PredictionSuccess", "Value": 1, "Unit": "Count"},
                {"MetricName": "PredictionConfidence", "Value": confidence, "Unit": "None"},
                {"MetricName": "TotalPredictions", "Value": 1, "Unit": "Count"},
                {
                    "MetricName": "BenignPredictions"
                    if prediction == "benign"
                    else "MalignantPredictions",
                    "Value": 1,
                    "Unit": "Count",
                },
                {
                    "MetricName": "HighConfidencePredictions",
                    "Value": high_confidence,
                    "Unit": "Count",
                },
                {
                    "MetricName": "LowConfidencePredictions",
                    "Value": low_confidence,
                    "Unit": "Count",
                },
            ]

            cloudwatch.put_metric_data(
                Namespace=f"{os.environ.get('PROJECT_NAME', 'medical-image-classification')}/ModelPerformance",
                MetricData=metrics_data,
            )

            return {
                "statusCode": 200,
                "headers": {
                    "Content-Type": "application/json",
                    "Access-Control-Allow-Origin": "*",
                    "Access-Control-Allow-Headers": "Content-Type",
                    "Access-Control-Allow-Methods": "POST, OPTIONS",
                },
                "body": json.dumps(formatted_result),
            }

        except ClientError as e:
            error_code = e.response["Error"]["Code"]

            if error_code == "ValidationException" and "does not exist" in str(e):
                # Endpoint doesn't exist yet
                return {
                    "statusCode": 503,
                    "headers": {
                        "Content-Type": "application/json",
                        "Access-Control-Allow-Origin": "*",
                        "Access-Control-Allow-Headers": "Content-Type",
                        "Access-Control-Allow-Methods": "POST, OPTIONS",
                    },
                    "body": json.dumps(
                        {
                            "message": "Model is still training. Please try again later.",
                            "status": "training_in_progress",
                            "retry_after": 300,
                        }
                    ),
                }
            else:
                raise

    except Exception as e:
        # Log the full error server-side; never return raw exception text to the
        # client (it can leak ARNs, bucket/endpoint names, or input fragments -
        # an info-disclosure risk on a medical API).
        logger.error(f"Inference error: {e!s}")
        req_id = context.aws_request_id if context else "unknown"

        # A shape-mismatch ModelError during the cold-start window (endpoint
        # still serving the 30-feature baseline model, not the image ensemble)
        # is transient - surface the friendly "training in progress" 503 rather
        # than a confusing 500.
        if "different ndims" in str(e) or "ModelError" in type(e).__name__:
            return {
                "statusCode": 503,
                "headers": {
                    "Content-Type": "application/json",
                    "Access-Control-Allow-Origin": "*",
                    "Access-Control-Allow-Headers": "Content-Type",
                    "Access-Control-Allow-Methods": "POST, OPTIONS",
                },
                "body": json.dumps(
                    {
                        "message": "Model is still initializing. Please try again later.",
                        "status": "training_in_progress",
                        "retry_after": 300,
                        "request_id": req_id,
                    }
                ),
            }

        # Log error metrics
        try:
            cloudwatch = boto3.client("cloudwatch")
            cloudwatch.put_metric_data(
                Namespace=f"{os.environ.get('PROJECT_NAME', 'medical-image-classification')}/ModelPerformance",
                MetricData=[{"MetricName": "PredictionError", "Value": 1, "Unit": "Count"}],
            )
        except Exception as metric_exc:
            # CloudWatch emission is best-effort during error handling -
            # if it fails too, we've already logged the original error above
            # and don't want to mask it with a metric-emission traceback.
            logger.warning(f"Failed to publish error metric: {metric_exc}")

        return {
            "statusCode": 500,
            "headers": {
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Headers": "Content-Type",
                "Access-Control-Allow-Methods": "POST, OPTIONS",
            },
            # Generic message only; full detail is in CloudWatch logs keyed by
            # request_id.
            "body": json.dumps({"error": "Internal server error", "request_id": req_id}),
        }
