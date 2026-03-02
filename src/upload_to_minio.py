from __future__ import annotations

from pathlib import Path

from minio import Minio
from minio.error import S3Error

from models import MinioUploadResult


def build_minio_client(
    endpoint: str,
    access_key: str,
    secret_key: str,
    secure: bool,
    region: str | None,
) -> Minio:
    kwargs: dict[str, object] = {
        "endpoint": endpoint,
        "access_key": access_key,
        "secret_key": secret_key,
        "secure": secure,
    }
    if region:
        kwargs["region"] = region
    return Minio(**kwargs)


def verify_uploaded_object(client: Minio, bucket: str, object_name: str, local_size: int) -> tuple[int, str | None]:
    stat = client.stat_object(bucket, object_name)
    remote_size = stat.size
    if remote_size != local_size:
        raise ValueError(
            f"Uploaded object size mismatch for bucket={bucket}, object={object_name}: "
            f"local={local_size}, remote={remote_size}"
        )
    return remote_size, getattr(stat, "etag", None)


def upload_file_to_minio(
    file_path: Path,
    endpoint: str,
    access_key: str,
    secret_key: str,
    bucket: str,
    object_name: str,
    secure: bool,
    content_type: str,
    region: str | None = None,
) -> MinioUploadResult:
    if not file_path.exists():
        raise FileNotFoundError(f"Local config file not found: {file_path}")
    if not file_path.is_file():
        raise ValueError(f"Local config path is not a file: {file_path}")

    try:
        local_size = file_path.stat().st_size
    except OSError as exc:
        raise RuntimeError(f"Failed to inspect local file {file_path}: {exc}") from exc

    client = build_minio_client(endpoint, access_key, secret_key, secure, region)

    try:
        if not client.bucket_exists(bucket):
            raise RuntimeError(
                f"MinIO upload failed for endpoint={endpoint}, bucket={bucket}, object={object_name}: bucket does not exist"
            )
    except S3Error as exc:
        raise RuntimeError(
            f"MinIO upload failed for endpoint={endpoint}, bucket={bucket}, object={object_name}: {exc}"
        ) from exc

    try:
        upload_result = client.fput_object(
            bucket_name=bucket,
            object_name=object_name,
            file_path=str(file_path),
            content_type=content_type,
        )
    except S3Error as exc:
        raise RuntimeError(
            f"MinIO upload failed for endpoint={endpoint}, bucket={bucket}, object={object_name}: {exc}"
        ) from exc

    try:
        remote_size, etag = verify_uploaded_object(client, bucket, object_name, local_size)
    except S3Error as exc:
        raise RuntimeError(
            f"MinIO verification failed for endpoint={endpoint}, bucket={bucket}, object={object_name}: {exc}"
        ) from exc
    except ValueError as exc:
        raise ValueError(
            f"{exc} (endpoint={endpoint}, bucket={bucket}, object={object_name})"
        ) from exc

    if etag is None:
        etag = getattr(upload_result, "etag", None)

    return MinioUploadResult(
        status="ok",
        endpoint=endpoint,
        bucket=bucket,
        object_name=object_name,
        size=remote_size,
        etag=etag,
    )
