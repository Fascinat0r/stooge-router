from __future__ import annotations

import json
from pathlib import Path

from requests import RequestException

from download_vpn_subscription import download_subscription
from generate_singbox_config import generate_config
from normalize_vless_subscription import normalize_subscription, save_normalized_subscription
from pydantic import ValidationError
from settings import get_settings
from upload_to_minio import upload_file_to_minio


def run_pipeline() -> dict[str, object]:
    settings = get_settings()

    download_result = download_subscription(
        settings.vpn_subscription_url,
        settings.data_dir,
        settings.subscription_user_agent,
    )
    normalized = normalize_subscription(download_result)
    normalized_path = save_normalized_subscription(normalized, settings.data_dir)
    generated = generate_config(
        normalized,
        settings.data_dir / "singbox_config.json",
        settings.singbox_clash_api_secret,
        settings.singbox_check_bin,
    )
    uploaded = upload_file_to_minio(
        file_path=Path(generated.output_file),
        endpoint=settings.minio_endpoint,
        access_key=settings.minio_access_key,
        secret_key=settings.minio_secret_key,
        bucket=settings.minio_bucket,
        object_name=settings.minio_object_name,
        secure=settings.minio_secure,
        content_type=settings.minio_content_type,
        region=settings.minio_region,
    )

    return {
        "download": download_result.model_dump(mode="json"),
        "normalized": {
            "status": "ok",
            "output_file": str(normalized_path),
            "node_count": len(normalized.nodes),
        },
        "generated_config": generated.model_dump(mode="json"),
        "uploaded_to_minio": uploaded.model_dump(mode="json"),
    }


def main() -> int:
    try:
        result = run_pipeline()
    except RequestException as exc:
        print(f"Failed during download step: {exc}")
        return 1
    except (ValidationError, ValueError, RuntimeError, json.JSONDecodeError, FileNotFoundError) as exc:
        print(f"Pipeline failed: {exc}")
        return 1

    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
