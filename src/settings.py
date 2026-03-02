from functools import lru_cache
from pathlib import Path

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


LEGACY_SINGBOX_PROFILE = "legacy_router"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    vpn_subscription_url: str = Field(validation_alias="VPN_SUBSCRIPTION_URL")
    data_dir: Path = Field(default=Path("./data"), validation_alias="DATA_DIR")
    subscription_user_agent: str = Field(
        default="HiddifyNext/2.5.7 (Windows; Python script)",
        validation_alias="SUBSCRIPTION_USER_AGENT",
    )
    singbox_clash_api_secret: str = Field(
        default="CHANGE_ME",
        validation_alias="SINGBOX_CLASH_API_SECRET",
    )
    singbox_check_bin: str | None = Field(
        default=None,
        validation_alias="SINGBOX_CHECK_BIN",
    )
    minio_endpoint: str = Field(validation_alias="MINIO_ENDPOINT")
    minio_access_key: str = Field(validation_alias="MINIO_ACCESS_KEY")
    minio_secret_key: str = Field(validation_alias="MINIO_SECRET_KEY")
    minio_bucket: str = Field(validation_alias="MINIO_BUCKET")
    minio_secure: bool = Field(default=True, validation_alias="MINIO_SECURE")
    minio_object_name: str = Field(validation_alias="MINIO_OBJECT_NAME")
    minio_content_type: str = Field(default="application/json", validation_alias="MINIO_CONTENT_TYPE")
    minio_region: str | None = Field(default=None, validation_alias="MINIO_REGION")

@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
