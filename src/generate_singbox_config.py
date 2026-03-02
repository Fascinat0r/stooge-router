from __future__ import annotations

import ipaddress
import json
import shutil
import subprocess
from pathlib import Path

from models import GenerationResult, NormalizedNode, NormalizedSubscription, SingboxCheckResult
from pydantic import ValidationError
from settings import LEGACY_SINGBOX_PROFILE, get_settings


INPUT_FILENAME = "subscription_normalized.json"
OUTPUT_FILENAME = "singbox_config.json"
TARGET_SINGBOX_PROFILE = LEGACY_SINGBOX_PROFILE
# This generator intentionally targets the current legacy-compatible router layout.


def is_ip_address(value: str | None) -> bool:
    if not value:
        return False
    try:
        ipaddress.ip_address(value)
    except ValueError:
        return False
    return True


def collect_dns_domains(nodes: list[NormalizedNode]) -> list[str]:
    domains: list[str] = []
    seen: set[str] = set()

    for node in nodes:
        server = node.server
        if server and not is_ip_address(server) and server not in seen:
            seen.add(server)
            domains.append(server)

    return domains


def to_singbox_outbound(node: NormalizedNode) -> dict[str, object]:
    allowed = ("type", "tag", "server", "server_port", "uuid", "flow", "tls", "transport")
    source = node.model_dump(exclude_none=True)
    outbound = {key: source[key] for key in allowed if key in source}
    if outbound.get("type") == "vless" and "packet_encoding" not in outbound:
        outbound["packet_encoding"] = "xudp"
    return outbound


def build_config(subscription: NormalizedSubscription, clash_secret: str) -> tuple[dict[str, object], int]:
    if not subscription.nodes:
        raise ValueError("Normalized payload does not contain any nodes")

    outbound_nodes = [to_singbox_outbound(node) for node in subscription.nodes]
    node_tags = [node.tag for node in subscription.nodes]

    dns_rules: list[dict[str, object]] = []
    dns_domains = collect_dns_domains(subscription.nodes)
    if dns_domains:
        dns_rules.append(
            {
                "domain": dns_domains,
                "server": "dns-direct",
            }
        )

    config = {
        "log": {
            "level": "error",
            "timestamp": True,
        },
        "dns": {
            "servers": [
                {
                    "tag": "dns-remote",
                    "address": "udp://1.1.1.1",
                    "address_resolver": "dns-direct",
                    "detour": "direct",
                },
                {
                    "tag": "dns-direct",
                    "address": "local",
                    "detour": "direct",
                },
            ],
            "rules": dns_rules,
            "final": "dns-remote",
        },
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun-in",
                "interface_name": "tun0",
                "domain_strategy": "ipv4_only",
                "address": ["172.16.250.1/30"],
                "auto_route": False,
                "strict_route": False,
                "sniff": True,
                "sniff_override_destination": True,
            },
            {
                "type": "direct",
                "tag": "dns-in",
                "listen": "127.0.0.1",
                "listen_port": 16450,
            },
        ],
        "outbounds": [
            {
                "type": "selector",
                "tag": "select",
                "outbounds": ["auto", *node_tags],
                "default": "auto",
            },
            {
                "type": "urltest",
                "tag": "auto",
                "outbounds": node_tags,
                "url": "http://connectivitycheck.gstatic.com/generate_204",
                "interval": "10m",
                "tolerance": 50,
            },
            *outbound_nodes,
            {
                "type": "dns",
                "tag": "dns-out",
            },
            {
                "type": "direct",
                "tag": "direct",
            },
        ],
        "route": {
            "auto_detect_interface": True,
            "rules": [
                {
                    "inbound": ["tun-in"],
                    "port": 53,
                    "action": "hijack-dns",
                },
                {
                    "inbound": "dns-in",
                    "outbound": "dns-out",
                },
                {
                    "port": 53,
                    "outbound": "dns-out",
                },
                {
                    "inbound": ["tun-in"],
                    "outbound": "select",
                },
            ],
            "final": "direct",
        },
        "experimental": {
            "cache_file": {
                "enabled": True,
                "path": "clash.db",
            },
            "clash_api": {
                "external_controller": "127.0.0.1:16756",
                "secret": clash_secret,
            },
        },
    }
    return config, len(outbound_nodes)


def validate_json_syntax(path: Path) -> None:
    raw = path.read_text(encoding="utf-8")
    json.loads(raw)


def resolve_singbox_bin(configured_bin: str | None) -> str | None:
    if configured_bin:
        return configured_bin
    return shutil.which("sing-box")


def run_singbox_check(path: Path, configured_bin: str | None) -> SingboxCheckResult:
    singbox_bin = resolve_singbox_bin(configured_bin)
    if singbox_bin is None:
        return SingboxCheckResult(
            available=False,
            checked=False,
            message="sing-box binary not configured/found; only JSON syntax was checked",
        )

    result = subprocess.run(
        [singbox_bin, "check", "-c", str(path)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        stderr = result.stderr.strip() or result.stdout.strip() or "unknown sing-box validation error"
        raise RuntimeError(f"sing-box check failed for {path}: {stderr}")

    return SingboxCheckResult(
        available=True,
        checked=True,
        message="sing-box check passed",
    )


def generate_config(
    subscription: NormalizedSubscription,
    output_path: Path,
    clash_secret: str,
    singbox_check_bin: str | None = None,
) -> GenerationResult:
    config, node_count = build_config(subscription, clash_secret)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(config, ensure_ascii=False, indent=2), encoding="utf-8")

    validate_json_syntax(output_path)
    singbox_check = run_singbox_check(output_path, singbox_check_bin)

    return GenerationResult(
        output_file=str(output_path),
        node_count=node_count,
        json_syntax_valid=True,
        target_profile=TARGET_SINGBOX_PROFILE,
        singbox_check=singbox_check,
    )


def main() -> int:
    settings = get_settings()
    input_path = settings.data_dir / INPUT_FILENAME
    output_path = settings.data_dir / OUTPUT_FILENAME

    if not input_path.exists():
        print(f"Normalized subscription file not found: {input_path}")
        return 1

    try:
        subscription = NormalizedSubscription.model_validate_json(input_path.read_text(encoding="utf-8"))
        result = generate_config(
            subscription,
            output_path,
            settings.singbox_clash_api_secret,
            settings.singbox_check_bin,
        )
    except (ValidationError, ValueError, RuntimeError, json.JSONDecodeError, FileNotFoundError) as exc:
        print(f"Failed to generate sing-box config: {exc}")
        return 1

    print(result.model_dump_json(indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
