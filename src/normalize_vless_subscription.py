from __future__ import annotations

import base64
import binascii
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

from download_vpn_subscription import METADATA_FILENAME
from models import DownloadMetadata, DownloadResult, NormalizedNode, NormalizedSubscription, SubscriptionMeta
from pydantic import ValidationError
from settings import get_settings


NORMALIZED_FILENAME = "subscription_normalized.json"
TAG_SEPARATOR = " \u00a7 "
KNOWN_VLESS_QUERY_KEYS = {
    "flow",
    "security",
    "sni",
    "fp",
    "alpn",
    "pbk",
    "sid",
    "type",
    "serviceName",
    "service_name",
    "path",
    "host",
    "method",
    "headerType",
    "authority",
    "mode",
    "encryption",
}


def decode_b64_text(value: str) -> str:
    text = "".join(value.strip().split())
    padding = len(text) % 4
    if padding:
        text += "=" * (4 - padding)
    return base64.b64decode(text).decode("utf-8")


def decode_profile_title(value: str | None) -> str | None:
    if not value:
        return None
    if value.startswith("base64:"):
        try:
            return decode_b64_text(value[len("base64:") :])
        except (binascii.Error, UnicodeDecodeError, ValueError):
            return value
    return value


def first(query: dict[str, list[str]], key: str, default: str = "") -> str:
    values = query.get(key)
    if not values:
        return default
    return values[0]


def non_empty(value: str | None) -> str | None:
    if value is None:
        return None
    stripped = value.strip()
    return stripped or None


def parse_vless_uri(uri: str, index: int | None = None) -> tuple[NormalizedNode, list[str]]:
    value = uri.strip()
    parsed = urlsplit(value)

    if parsed.scheme.lower() != "vless":
        raise ValueError(f"Unsupported scheme: {parsed.scheme}")
    if not parsed.hostname:
        raise ValueError("VLESS URI does not contain hostname")
    if parsed.port is None:
        raise ValueError("VLESS URI does not contain port")

    uuid_value = unquote(parsed.username or "").strip()
    if not uuid_value:
        raise ValueError("VLESS URI does not contain UUID")

    query = parse_qs(parsed.query, keep_blank_values=True)
    unknown_keys = sorted(set(query) - KNOWN_VLESS_QUERY_KEYS)
    tag = unquote(parsed.fragment) if parsed.fragment else f"node-{index or 0}"
    node = NormalizedNode(
        type="vless",
        tag=f"{tag}{TAG_SEPARATOR}{index}" if index is not None else tag,
        server=parsed.hostname,
        server_port=parsed.port,
        uuid=uuid_value,
        raw_uri=value,
    )

    flow = non_empty(first(query, "flow"))
    if flow:
        node.flow = flow

    security = first(query, "security")
    sni = non_empty(first(query, "sni"))
    fp = non_empty(first(query, "fp"))
    alpn = non_empty(first(query, "alpn"))
    pbk = non_empty(first(query, "pbk"))
    sid = non_empty(first(query, "sid"))

    is_reality = security == "reality" or bool(pbk) or bool(sid)

    if security in {"tls", "reality"} or sni or fp or pbk or sid or alpn:
        tls: dict[str, object] = {"enabled": True}

        if sni:
            tls["server_name"] = sni
        if is_reality:
            tls["utls"] = {
                "enabled": True,
                "fingerprint": "firefox",
            }
        elif fp:
            tls["utls"] = {
                "enabled": True,
                "fingerprint": fp,
            }
        if alpn:
            tls["alpn"] = [part.strip() for part in alpn.split(",") if part.strip()]
        if is_reality:
            reality: dict[str, object] = {"enabled": True}
            if pbk:
                reality["public_key"] = pbk
            if sid:
                reality["short_id"] = sid
            tls["reality"] = reality
        if "reality" in tls and "utls" not in tls:
            raise ValueError("Reality VLESS URI requires tls.utls but it was not generated")

        node.tls = tls

    transport_type = first(query, "type", "tcp").lower()
    if transport_type == "grpc":
        transport: dict[str, object] = {"type": "grpc"}
        service_name = non_empty(first(query, "serviceName")) or non_empty(first(query, "service_name"))
        if service_name:
            transport["service_name"] = service_name
        node.transport = transport
    elif transport_type == "ws":
        transport = {"type": "ws"}
        path = non_empty(first(query, "path"))
        host = non_empty(first(query, "host"))
        if path:
            transport["path"] = path
        if host:
            transport["headers"] = {"Host": host}
        node.transport = transport
    elif transport_type == "http":
        transport = {"type": "http"}
        path = non_empty(first(query, "path"))
        host = non_empty(first(query, "host"))
        method = non_empty(first(query, "method"))
        if path:
            transport["path"] = path
        if method:
            transport["method"] = method
        if host:
            transport["host"] = [part.strip() for part in host.split(",") if part.strip()]
        node.transport = transport

    return node, unknown_keys


def parse_subscription_lines(text: str, meta: SubscriptionMeta) -> list[NormalizedNode]:
    nodes: list[NormalizedNode] = []
    node_index = 0

    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.strip()
        if not line:
            continue

        parsed = urlsplit(line)
        scheme = parsed.scheme.lower()
        if not scheme:
            continue
        if scheme != "vless":
            meta.unsupported_schemes[scheme] = meta.unsupported_schemes.get(scheme, 0) + 1
            continue

        try:
            node, unknown_keys = parse_vless_uri(line, index=node_index)
            if unknown_keys:
                meta.parse_errors.append(
                    f"line {line_number}: unsupported VLESS params: {', '.join(unknown_keys)}"
                )
                continue
            nodes.append(node)
            node_index += 1
        except ValueError as exc:
            meta.parse_errors.append(f"line {line_number}: {exc}")

    return nodes


def normalize_subscription(download_result: DownloadResult) -> NormalizedSubscription:
    source_text: str | None = None
    if download_result.detected_format == "base64_text":
        source_text = download_result.decoded_text
    elif download_result.detected_format == "plain_text_or_yaml" and "vless://" in download_result.raw_text:
        source_text = download_result.raw_text

    if not source_text:
        raise ValueError(
            f"Normalization supports only VLESS text subscriptions; got detected_format={download_result.detected_format}"
        )

    interval_raw = download_result.headers.get("profile_update_interval")
    interval_value: int | str | None = interval_raw
    if interval_raw and interval_raw.isdigit():
        interval_value = int(interval_raw)

    meta = SubscriptionMeta(
        profile_title=decode_profile_title(download_result.headers.get("profile_title")),
        profile_update_interval=interval_value,
        subscription_userinfo=download_result.headers.get("subscription_userinfo"),
        support_url=download_result.headers.get("support_url"),
    )
    nodes = parse_subscription_lines(source_text, meta)

    if meta.unsupported_schemes:
        parts = [f"{scheme}={count}" for scheme, count in sorted(meta.unsupported_schemes.items())]
        raise ValueError(f"Unsupported URI schemes in subscription: {', '.join(parts)}")
    if meta.parse_errors:
        raise ValueError("Failed to parse VLESS URIs: " + "; ".join(meta.parse_errors))
    if not nodes:
        raise ValueError("No VLESS URIs found in subscription payload")

    return NormalizedSubscription(meta=meta, nodes=nodes)


def save_normalized_subscription(subscription: NormalizedSubscription, out_dir: Path) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / NORMALIZED_FILENAME
    path.write_text(subscription.model_dump_json(indent=2), encoding="utf-8")
    return path


def main() -> int:
    settings = get_settings()
    metadata_path = settings.data_dir / METADATA_FILENAME
    if not metadata_path.exists():
        print(f"Download metadata file not found: {metadata_path}")
        return 1

    try:
        metadata = DownloadMetadata.model_validate_json(metadata_path.read_text(encoding="utf-8"))
        raw_text = ""
        decoded_text = None
        if metadata.raw_text_file:
            raw_text = Path(metadata.raw_text_file).read_text(encoding="utf-8")
        if metadata.decoded_text_file:
            decoded_text = Path(metadata.decoded_text_file).read_text(encoding="utf-8")
        download_result = DownloadResult(
            requested_url=metadata.requested_url,
            final_url=metadata.final_url,
            status_code=metadata.status_code,
            headers=metadata.headers,
            detected_format=metadata.detected_format,
            raw_text=raw_text,
            decoded_text=decoded_text,
            saved_files=metadata.saved_files,
        )
        subscription = normalize_subscription(download_result)
        output_path = save_normalized_subscription(subscription, settings.data_dir)
    except (ValidationError, ValueError, FileNotFoundError) as exc:
        print(f"Failed to normalize subscription: {exc}")
        return 1

    print(f"Normalized subscription saved to: {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
