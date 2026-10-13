import hashlib
import json
import os
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

dynamodb = boto3.resource("dynamodb", endpoint_url=os.environ.get("AWS_ENDPOINT_URL"))
s3 = boto3.client("s3", endpoint_url=os.environ.get("AWS_ENDPOINT_URL"))

TABLE_NAME = os.environ["DYNAMODB_TABLE"]
BUCKET_NAME = os.environ["S3_BUCKET"]


def _event_id(raw_body: str) -> str:
    # Deterministic id: same payload -> same id, so a redelivered SQS message
    # (at-least-once delivery) never creates a duplicate record.
    return hashlib.sha256(raw_body.encode("utf-8")).hexdigest()


def _persist(raw_body: str) -> None:
    event_id = _event_id(raw_body)
    now = datetime.now(timezone.utc)

    # Archive the raw payload FIRST. S3 PutObject is idempotent by key, so a
    # redelivery just overwrites the same object harmlessly. Doing S3 before the
    # DynamoDB conditional put guarantees the raw copy always exists: if we did
    # DynamoDB first and S3 failed, the retry would hit the conditional check,
    # short-circuit, and the payload would never be archived.
    key = f"raw/{now:%Y/%m/%d}/{event_id}.json"
    s3.put_object(
        Bucket=BUCKET_NAME,
        Key=key,
        Body=raw_body.encode("utf-8"),
        ContentType="application/json",
    )

    # Structured record, idempotent: same payload -> same event_id, and the
    # conditional put makes a redelivered message a no-op instead of a duplicate.
    table = dynamodb.Table(TABLE_NAME)
    try:
        table.put_item(
            Item={
                "event_id": event_id,
                "raw_payload": raw_body,
                "received_at": now.isoformat(),
            },
            ConditionExpression="attribute_not_exists(event_id)",
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            # Already processed: idempotent no-op, not an error.
            return
        raise


def handler(event, context):
    # Report per-message failures so only the failed ones are retried/DLQ'd,
    # not the whole batch (see ReportBatchItemFailures in the event source
    # mapping below).
    batch_item_failures = []

    for record in event.get("Records", []):
        try:
            body = record["body"]
            json.loads(body)  # validate it is a JSON payload before persisting
            _persist(body)
        except Exception:
            batch_item_failures.append({"itemIdentifier": record["messageId"]})

    return {"batchItemFailures": batch_item_failures}
