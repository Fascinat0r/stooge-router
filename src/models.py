from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


DetectedFormat = Literal["json", "base64_text", "plain_text_or_yaml"]


class DownloadResult(BaseModel):
    requested_url: str
    final_url: str
    status_code: int
    headers: dict[str, str | None] = Field(default_factory=dict)
    detected_format: DetectedFormat
    raw_text: str
    decoded_text: str | None = None
    saved_files: list[str] = Field(default_factory=list)


class DownloadMetadata(BaseModel):
    requested_url: str
    final_url: str
    status_code: int
    headers: dict[str, str | None] = Field(default_factory=dict)
    detected_format: DetectedFormat
    raw_text_file: str | None = None
    decoded_text_file: str | None = None
    saved_files: list[str] = Field(default_factory=list)


class SubscriptionMeta(BaseModel):
    profile_title: str | None = None
    profile_update_interval: int | str | None = None
    subscription_userinfo: str | None = None
    support_url: str | None = None
    unsupported_schemes: dict[str, int] = Field(default_factory=dict)
    parse_errors: list[str] = Field(default_factory=list)


class NormalizedNode(BaseModel):
    type: Literal["vless"]
    tag: str
    server: str
    server_port: int
    uuid: str
    flow: str | None = None
    tls: dict[str, object] | None = None
    transport: dict[str, object] | None = None
    raw_uri: str | None = None


class NormalizedSubscription(BaseModel):
    meta: SubscriptionMeta
    nodes: list[NormalizedNode] = Field(default_factory=list)


class SingboxCheckResult(BaseModel):
    available: bool
    checked: bool
    message: str


class GenerationResult(BaseModel):
    output_file: str
    node_count: int
    json_syntax_valid: bool
    target_profile: str
    singbox_check: SingboxCheckResult


class MinioUploadResult(BaseModel):
    status: Literal["ok"]
    endpoint: str
    bucket: str
    object_name: str
    size: int
    etag: str | None = None
