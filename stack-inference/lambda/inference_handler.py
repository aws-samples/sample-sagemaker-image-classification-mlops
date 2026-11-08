# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Inference API: POST /predict and GET /results/{id}.

Logs carry only the method, path, request id and payload size. The image and
the model response never go to Amazon CloudWatch.
"""

import base64
import binascii
import io
import json
import logging
import os
import re
import warnings
from datetime import UTC, datetime

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from mlops_common.preprocess import preprocess
from mlops_common.scores import extract_score, extract_threshold
from PIL import Image

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Decompression-bomb guard: a small payload must not expand to GBs of RAM.
# Pillow warns above MAX_IMAGE_PIXELS and raises at twice that; decode_image
# turns the warning into an error, so 25 MP is the hard cap.
Image.MAX_IMAGE_PIXELS = 25_000_000
MAX_IMAGE_EDGE = 12000

# Pillow format -> (content type, file extension, Bedrock Nova format).
IMAGE_FORMATS = {
    "JPEG": ("image/jpeg", "jpg", "jpeg"),
    "PNG": ("image/png", "png", "png"),
}
DEFAULT_CLASS_NAMES = ("negative", "positive")

# Explanation methods the endpoint handler implements (scripts/ensemble/inference.py).
EXPLAIN_METHODS = ("gradcam", "region_shapley")

# Lambda request ids (and so result ids) are lowercase UUIDs.
_RESULT_ID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def _response(status_code, body):
    """API Gateway proxy response. CORS headers only for a configured origin."""
    headers = {"Content-Type": "application/json"}
    origin = os.environ.get("ALLOWED_ORIGIN", "")
    if origin:
        headers.update(
            {
                "Access-Control-Allow-Origin": origin,
                "Access-Control-Allow-Headers": "Content-Type",
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Vary": "Origin",
            }
        )
    return {"statusCode": status_code, "headers": headers, "body": json.dumps(body)}


def _metric_namespace():
    return f"{os.environ.get('PROJECT_NAME', 'image-classification')}/ModelPerformance"


def _emit_error_metric(reason):
    """Best effort: a metric failure must not mask the original error."""
    try:
        boto3.client("cloudwatch").put_metric_data(
            Namespace=_metric_namespace(),
            MetricData=[{"MetricName": "PredictionError", "Value": 1, "Unit": "Count"}],
        )
    except (ClientError, BotoCoreError) as exc:
        logger.warning("Failed to publish PredictionError (%s): %s", reason, type(exc).__name__)


def class_names(result):
    """(negative, positive) class names: from the endpoint response, else CLASS_NAMES, else a default."""
    names = result.get("class_names") if isinstance(result, dict) else None
    if not (isinstance(names, list) and len(names) == 2 and all(isinstance(n, str) for n in names)):
        names = [n.strip() for n in os.environ.get("CLASS_NAMES", "").split(",") if n.strip()]
    return tuple(names) if len(names) == 2 else DEFAULT_CLASS_NAMES


def confidence_cutoff():
    """Single low-confidence cut-off for Bedrock routing, human review and metrics."""
    return float(os.environ.get("BEDROCK_CONFIDENCE_THRESHOLD", "0.70"))


def border_attention(gradcam, band_fraction):
    """Share of the Grad-CAM mass in the outer band of the image, or None.

    The grid covers the whole resized upload. A cell is in the band when its
    centre lies within ``band_fraction`` of any edge. A high share means the
    model looked at edges, borders, watermarks or padding rather than the
    subject, a shortcut that deserves a second look. None when there is no
    usable square grid or the map is all zero.
    """
    grid = gradcam.get("grid") if isinstance(gradcam, dict) else None
    if not isinstance(grid, list) or not grid:
        return None
    size = len(grid)
    total = border = 0.0
    try:
        for r, row in enumerate(grid):
            if not isinstance(row, list) or len(row) != size:
                return None
            for c, value in enumerate(row):
                weight = max(float(value), 0.0)
                total += weight
                y, x = (r + 0.5) / size, (c + 0.5) / size
                if min(x, y, 1.0 - x, 1.0 - y) < band_fraction:
                    border += weight
    except (TypeError, ValueError):
        return None
    return border / total if total > 0.0 else None


def decode_image(base64_image):
    """Base64 string to (raw bytes, RGB-convertible PIL image, Pillow format).

    The format and size are checked from the header before any pixel is
    decoded. Raises ValueError for anything that is not a JPEG or PNG of a
    sane size.
    """
    try:
        raw = base64.b64decode(base64_image, validate=True)
    except (binascii.Error, ValueError, TypeError) as exc:
        raise ValueError("Invalid base64 image encoding") from exc
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            img = Image.open(io.BytesIO(raw), formats=list(IMAGE_FORMATS))
            if img.format not in IMAGE_FORMATS:
                raise ValueError(f"Unsupported image format: {img.format}")
            if img.width > MAX_IMAGE_EDGE or img.height > MAX_IMAGE_EDGE:
                raise ValueError(f"Image dimensions too large: {img.width}x{img.height}")
            img.load()
    except (OSError, Image.DecompressionBombError, Image.DecompressionBombWarning) as exc:
        raise ValueError("Unreadable, unsupported or oversized image") from exc
    return raw, img, img.format


def bedrock_explain(base64_image, image_format, prediction, confidence):
    """Ask an Amazon Bedrock foundation model to describe a low-confidence image.

    Fails closed: without a guardrail (BEDROCK_GUARDRAIL_ID and
    BEDROCK_GUARDRAIL_VERSION) Bedrock is not called. Returns the text, or
    None; the primary prediction is returned either way. Nova InvokeModel
    messages-v1:
    https://docs.aws.amazon.com/nova/latest/userguide/modalities-image-examples.html
    """
    guardrail_id = os.environ.get("BEDROCK_GUARDRAIL_ID", "")
    guardrail_version = os.environ.get("BEDROCK_GUARDRAIL_VERSION", "")
    if not (guardrail_id and guardrail_version):
        logger.warning("Bedrock description skipped: no guardrail configured")
        return None
    nova_format = IMAGE_FORMATS[image_format][2]
    try:
        native_request = {
            "schemaVersion": "messages-v1",
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {"image": {"format": nova_format, "source": {"bytes": base64_image}}},
                        {
                            "text": (
                                "You are assisting a human reviewer. An image classifier "
                                f"predicted the class '{prediction}' with {confidence:.0%} "
                                "confidence, which is below the confidence threshold. Describe "
                                "the image and say whether it looks consistent with the "
                                "predicted class. Be concise; the reviewer makes the decision."
                            )
                        },
                    ],
                }
            ],
            "inferenceConfig": {"maxTokens": 300, "temperature": 0.2, "topP": 0.9},
        }
        # The guardrail filters unsafe content and anonymises PII in the output.
        response = boto3.client("bedrock-runtime").invoke_model(
            modelId=os.environ.get("BEDROCK_MODEL_ID", "us.amazon.nova-pro-v1:0"),
            body=json.dumps(native_request),
            guardrailIdentifier=guardrail_id,
            guardrailVersion=guardrail_version,
        )
        body = json.loads(response["body"].read())
        return body["output"]["message"]["content"][0]["text"]
    except (ClientError, BotoCoreError, KeyError, IndexError, TypeError, ValueError) as exc:
        logger.warning("Bedrock description unavailable: %s", type(exc).__name__)
        return None


def start_human_review(request_id, image_s3_uri, prediction, confidence):
    """Start an Amazon A2I human loop (no-op without FLOW_DEFINITION_ARN)."""
    flow_arn = os.environ.get("FLOW_DEFINITION_ARN", "")
    if not flow_arn:
        return None
    try:
        boto3.client("sagemaker-a2i-runtime").start_human_loop(
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
    except (ClientError, BotoCoreError) as exc:
        logger.warning("Failed to start human review loop: %s", type(exc).__name__)
        return None


def result_key(request_id):
    return f"predictions/{request_id}/prediction.json"


def save_prediction_data(s3_client, bucket, prediction_data, image_bytes, image_format, request_id):
    """Store the input image and the prediction record under the request id.

    Returns the image's S3 URI (or None) so a human review can point at it.
    The record, which GET /results/{id} returns, does not carry the URI.
    """
    if not bucket:
        return None
    content_type, extension, _ = IMAGE_FORMATS[image_format]
    image_key = f"predictions/{request_id}/input.{extension}"
    image_uri = None
    try:
        s3_client.put_object(
            Bucket=bucket, Key=image_key, Body=image_bytes, ContentType=content_type
        )
        image_uri = f"s3://{bucket}/{image_key}"
    except (ClientError, BotoCoreError) as exc:
        logger.warning("Failed to persist input image: %s", type(exc).__name__)

    record = {
        **prediction_data,
        "timestamp": datetime.now(UTC).isoformat(),
        "image_bytes": len(image_bytes),
        "image_content_type": content_type,
    }
    try:
        s3_client.put_object(
            Bucket=bucket,
            Key=result_key(request_id),
            Body=json.dumps(record),
            ContentType="application/json",
        )
    except (ClientError, BotoCoreError) as exc:
        logger.warning("Failed to save prediction record: %s", type(exc).__name__)
    return image_uri


def fetch_prediction_result(s3_client, bucket, request_id):
    """Stored prediction for GET /results/{id}, or None if absent."""
    if not bucket:
        return None
    try:
        obj = s3_client.get_object(Bucket=bucket, Key=result_key(request_id))
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("NoSuchKey", "404"):
            return None
        raise
    result = json.loads(obj["Body"].read())
    if isinstance(result, dict):
        result.pop("image_s3_uri", None)
    return result


def _handle_get_result(result_id):
    if not result_id or not _RESULT_ID.match(result_id):
        return _response(400, {"error": "Result id must be a request id (UUID)"})
    result = fetch_prediction_result(
        boto3.client("s3"), os.environ.get("INFERENCE_BUCKET"), result_id
    )
    if result is None:
        return _response(404, {"error": "Result not found", "request_id": result_id})
    return _response(200, result)


def _parse_body(event):
    body = event.get("body")
    if isinstance(body, str):
        if event.get("isBase64Encoded"):
            body = base64.b64decode(body).decode("utf8")
        return json.loads(body)
    # API Gateway sends an explicit null for body-less requests.
    return body or {}


def explain_request(value):
    """The endpoint's ``explain`` object for a request's ``explain`` field.

    Returns None when no explanation was asked for. ``true`` asks for every
    method; ``{"methods": [...]}`` for a subset. The evaluation cap and time
    budget come from the Lambda environment, never from the caller, because
    they set the endpoint compute each request may use. Raises ValueError for
    anything else.
    """
    if value is None or value is False:
        return None
    if value is True:
        methods = list(EXPLAIN_METHODS)
    elif isinstance(value, dict) and set(value) <= {"methods"}:
        methods = value.get("methods", list(EXPLAIN_METHODS))
        if (
            not isinstance(methods, list)
            or not methods
            or any(m not in EXPLAIN_METHODS for m in methods)
        ):
            raise ValueError(
                f"explain.methods must be a non-empty subset of {list(EXPLAIN_METHODS)}"
            )
    else:
        raise ValueError('explain must be true, false or {"methods": [...]}')
    return {
        "methods": methods,
        "max_evals": int(os.environ.get("EXPLAIN_MAX_EVALS", "32")),
        "time_budget_ms": int(os.environ.get("EXPLAIN_TIME_BUDGET_MS", "5000")),
    }


def _explanations_enabled():
    return os.environ.get("EXPLANATIONS_ENABLED", "false").lower() == "true"


def _handle_predict(event, request_id):
    endpoint_name = os.environ.get("ENDPOINT_NAME")
    if not endpoint_name:
        return _response(500, {"error": "Endpoint name not configured"})

    try:
        body = _parse_body(event)
    except (ValueError, UnicodeDecodeError):
        return _response(400, {"error": "Request body must be JSON"})
    image_data = body.get("image") if isinstance(body, dict) else None
    if not image_data or not isinstance(image_data, str):
        return _response(400, {"error": "Missing image data"})

    # Size check BEFORE any decoding or endpoint call: bounds Lambda memory and
    # SageMaker spend per request.
    max_bytes = int(os.environ.get("MAX_IMAGE_BYTES", "5242880"))
    if len(image_data) > max_bytes:
        return _response(
            413,
            {
                "error": "Payload too large",
                "max_bytes": max_bytes,
                "received_bytes": len(image_data),
            },
        )

    try:
        explain = explain_request(body.get("explain"))
    except ValueError as exc:
        return _response(400, {"error": "Invalid explain option", "detail": str(exc)})

    try:
        image_bytes, img, image_format = decode_image(image_data)
        model_input = preprocess(img)
    except ValueError as exc:
        return _response(400, {"error": "Invalid image", "detail": str(exc)})

    endpoint_request = {"instances": [model_input.tolist()]}
    if explain and _explanations_enabled():
        endpoint_request["explain"] = explain

    try:
        response = boto3.client("sagemaker-runtime").invoke_endpoint(
            EndpointName=endpoint_name,
            ContentType="application/json",
            Accept="application/json",
            Body=json.dumps(endpoint_request),
            # Recorded in data capture as eventMetadata.inferenceId, which the
            # fairness job joins with the confirmed labels you upload.
            InferenceId=request_id,
        )
    except ClientError as exc:
        code = exc.response["Error"]["Code"]
        if code == "ValidationException" and "does not exist" in str(exc):
            return _response(
                503,
                {
                    "message": "Model endpoint is not deployed yet. Please try again later.",
                    "status": "endpoint_unavailable",
                    "retry_after": 300,
                    "request_id": request_id,
                },
            )
        if code == "ModelError":
            _emit_error_metric("model_error")
            # The container rejected or failed this request; a retry will not help.
            return _response(
                502,
                {
                    "message": "The model could not process this image.",
                    "status": "model_error",
                    "request_id": request_id,
                },
            )
        raise

    try:
        result = json.loads(response["Body"].read().decode("utf8"))
    except (ValueError, UnicodeDecodeError):
        result = None
    score = extract_score(result) if result is not None else None
    threshold = extract_threshold(result) if result is not None else None
    if score is None or threshold is None:
        logger.error(
            "Unknown endpoint response format (request_id=%s, type=%s)",
            request_id,
            type(result).__name__,
        )
        _emit_error_metric("unknown_response_format")
        return _response(
            502, {"error": "Unexpected response from the model", "request_id": request_id}
        )

    negative, positive = class_names(result)
    is_positive = score >= threshold
    prediction = positive if is_positive else negative
    # P(predicted class): the positive-class probability for a positive call,
    # its complement for a negative one.
    confidence = score if is_positive else 1.0 - score
    is_low_confidence = confidence < confidence_cutoff()

    formatted_result = {
        "request_id": request_id,
        "prediction": prediction,
        "confidence": confidence,
        "probabilities": {negative: 1.0 - score, positive: score},
        "positive_class": positive,
        "threshold_used": threshold,
        "model_info": "Image analysis using ensemble model",
    }

    if explain:
        if not _explanations_enabled():
            formatted_result["explanations"] = {"status": "disabled"}
        elif isinstance(result, dict) and isinstance(result.get("explanations"), dict):
            formatted_result["explanations"] = result["explanations"]
        else:
            formatted_result["explanations"] = {
                "status": "unavailable",
                "reason": "the deployed model package does not return explanations",
            }
        # Flag a heatmap that sits on the image border (outer band, default
        # 10 percent of each side) instead of the subject.
        border_share = border_attention(
            formatted_result["explanations"].get("gradcam"),
            float(os.environ.get("GRADCAM_BORDER_BAND", "0.1")),
        )
        if border_share is not None:
            formatted_result["attention_on_border"] = border_share > float(
                os.environ.get("GRADCAM_BORDER_THRESHOLD", "0.5")
            )
            formatted_result["border_attention_fraction"] = round(border_share, 4)

    hybrid_enabled = os.environ.get("ENABLE_BEDROCK_HYBRID", "false").lower() == "true"
    if hybrid_enabled and is_low_confidence:
        reasoning = bedrock_explain(image_data, image_format, prediction, confidence)
        if reasoning:
            formatted_result["reasoning"] = reasoning
            formatted_result["routing"] = "low-confidence-bedrock"
        else:
            formatted_result["routing"] = "low-confidence-bedrock-unavailable"
    else:
        formatted_result["routing"] = (
            "low-confidence-custom" if is_low_confidence else "high-confidence-custom"
        )

    bucket = os.environ.get("INFERENCE_BUCKET")
    image_s3_uri = save_prediction_data(
        boto3.client("s3"), bucket, formatted_result, image_bytes, image_format, request_id
    )

    if is_low_confidence and os.environ.get("FLOW_DEFINITION_ARN"):
        review_id = start_human_review(
            request_id, image_s3_uri or f"s3://{bucket or ''}/predictions", prediction, confidence
        )
        if review_id:
            formatted_result["human_review"] = review_id

    boto3.client("cloudwatch").put_metric_data(
        Namespace=_metric_namespace(),
        MetricData=[
            {"MetricName": "PredictionSuccess", "Value": 1, "Unit": "Count"},
            {"MetricName": "PredictionConfidence", "Value": confidence, "Unit": "None"},
            {"MetricName": "TotalPredictions", "Value": 1, "Unit": "Count"},
            {
                "MetricName": "PositivePredictions" if is_positive else "NegativePredictions",
                "Value": 1,
                "Unit": "Count",
            },
            {
                "MetricName": "HighConfidencePredictions",
                "Value": 0 if is_low_confidence else 1,
                "Unit": "Count",
            },
            {
                "MetricName": "LowConfidencePredictions",
                "Value": 1 if is_low_confidence else 0,
                "Unit": "Count",
            },
        ],
    )
    return _response(200, formatted_result)


def lambda_handler(event, context):
    request_id = getattr(context, "aws_request_id", None) or "local"
    event = event or {}
    method = (event.get("httpMethod") or "").upper()
    body = event.get("body")
    logger.info(
        json.dumps(
            {
                "method": method,
                "path": event.get("resource") or event.get("path") or "",
                "request_id": request_id,
                "body_bytes": len(body) if isinstance(body, str) else 0,
            }
        )
    )
    try:
        path_params = event.get("pathParameters") or {}
        if method == "GET" or path_params.get("id"):
            return _handle_get_result(path_params.get("id"))
        return _handle_predict(event, request_id)
    except Exception as exc:
        # Top-level boundary of the function: return a generic 500 instead of
        # the Lambda error payload. Log the class only: exception text can
        # carry ARNs or input fragments.
        logger.error("Inference error (request_id=%s): %s", request_id, type(exc).__name__)
        _emit_error_metric("unhandled")
        return _response(500, {"error": "Internal server error", "request_id": request_id})
