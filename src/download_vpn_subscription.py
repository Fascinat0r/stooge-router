from __future__ import annotations

import base64
import binascii
import json
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

import requests
from requests import RequestException

from models import DownloadMetadata, DownloadResult
from settings import get_settings


RAW_BIN_FILENAME = "raw_response.bin"
RAW_TEXT_FILENAME = "raw_response.txt"
JSON_FILENAME = "subscription.json"
DECODED_FILENAME = "subscription_decoded.txt"
PLAIN_FILENAME = "subscription_plain.txt"
METADATA_FILENAME = "download_metadata.json"

SUBSCRIPTION_HEADERS = {
    "content-type": "content_type",
    "content-disposition": "content_disposition",
    "profile-title": "profile_title",
    "profile-update-interval": "profile_update_interval",
    "subscription-userinfo": "subscription_userinfo",
    "support-url": "support_url",
}


def strip_fragment(url: str) -> str:
    parts = urlsplit(url)
    return urlunsplit((parts.scheme, parts.netloc, parts.path, parts.query, ""))


def maybe_b64_decode(text: str) -> str | None:
    value = "".join(text.strip().split())
    if not value:
        return None

    padding = len(value) % 4
    if padding:
        value += "=" * (4 - padding)

    try:
        raw = base64.b64decode(value, validate=False)
        decoded = raw.decode("utf-8", errors="strict")
    except (binascii.Error, UnicodeDecodeError, ValueError):
        return None

    markers = (
        "vmess://",
        "vless://",
        "trojan://",
        "ss://",
        "ssr://",
        "tuic://",
        "hysteria://",
        "hy2://",
        "{",
        "outbounds",
        "proxies",
    )
    if any(marker in decoded for marker in markers):
        return decoded

    return None


def extract_subscription_headers(response: requests.Response) -> dict[str, str | None]:
    return {
        normalized_name: response.headers.get(header_name)
        for header_name, normalized_name in SUBSCRIPTION_HEADERS.items()
    }


def write_metadata(result: DownloadResult, out_dir: Path) -> Path:
    metadata_path = out_dir / METADATA_FILENAME
    raw_text_file = next((path for path in result.saved_files if path.endswith(RAW_TEXT_FILENAME)), None)
    decoded_text_file = next((path for path in result.saved_files if path.endswith(DECODED_FILENAME)), None)
    metadata = DownloadMetadata(
        requested_url=result.requested_url,
        final_url=result.final_url,
        status_code=result.status_code,
        headers=result.headers,
        detected_format=result.detected_format,
        raw_text_file=raw_text_file,
        decoded_text_file=decoded_text_file,
        saved_files=result.saved_files,
    )
    metadata_path.write_text(metadata.model_dump_json(indent=2), encoding="utf-8")
    return metadata_path


def download_subscription(
    url: str,
    out_dir: Path,
    user_agent: str,
    timeout: int = 30,
) -> DownloadResult:
    clean_url = strip_fragment(url)
    out_dir.mkdir(parents=True, exist_ok=True)

    headers = {
        "User-Agent": user_agent,
        "Accept": "*/*",
    }

    with requests.Session() as session:
        response = session.get(clean_url, headers=headers, timeout=timeout, allow_redirects=True)
        response.raise_for_status()

    raw_bytes = response.content
    raw_text = response.text

    raw_bin_path = out_dir / RAW_BIN_FILENAME
    raw_text_path = out_dir / RAW_TEXT_FILENAME
    raw_bin_path.write_bytes(raw_bytes)
    raw_text_path.write_text(raw_text, encoding="utf-8", errors="replace")

    saved_files = [str(raw_bin_path), str(raw_text_path)]
    headers_map = extract_subscription_headers(response)

    try:
        payload = response.json()
        json_path = out_dir / JSON_FILENAME
        json_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        saved_files.append(str(json_path))
        result = DownloadResult(
            requested_url=clean_url,
            final_url=response.url,
            status_code=response.status_code,
            headers=headers_map,
            detected_format="json",
            raw_text=raw_text,
            decoded_text=None,
            saved_files=saved_files,
        )
    except json.JSONDecodeError:
        decoded = maybe_b64_decode(raw_text)
        if decoded is not None:
            decoded_path = out_dir / DECODED_FILENAME
            decoded_path.write_text(decoded, encoding="utf-8")
            saved_files.append(str(decoded_path))
            result = DownloadResult(
                requested_url=clean_url,
                final_url=response.url,
                status_code=response.status_code,
                headers=headers_map,
                detected_format="base64_text",
                raw_text=raw_text,
                decoded_text=decoded,
                saved_files=saved_files,
            )
        else:
            plain_path = out_dir / PLAIN_FILENAME
            plain_path.write_text(raw_text, encoding="utf-8", errors="replace")
            saved_files.append(str(plain_path))
            result = DownloadResult(
                requested_url=clean_url,
                final_url=response.url,
                status_code=response.status_code,
                headers=headers_map,
                detected_format="plain_text_or_yaml",
                raw_text=raw_text,
                decoded_text=None,
                saved_files=saved_files,
            )

    metadata_path = out_dir / METADATA_FILENAME
    result.saved_files.append(str(metadata_path))
    write_metadata(result, out_dir)
    return result


def main() -> int:
    settings = get_settings()

    try:
        result = download_subscription(
            settings.vpn_subscription_url,
            settings.data_dir,
            settings.subscription_user_agent,
        )
    except RequestException as exc:
        print(f"Failed to download subscription: {exc}")
        return 1

    print(result.model_dump_json(indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
