from functools import lru_cache

from pydantic import Field, HttpUrl, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    supabase_url: HttpUrl
    supabase_service_role_key: SecretStr
    control_plane_admin_token: SecretStr = Field(min_length=32)
    control_plane_request_timeout_seconds: float = Field(default=15, gt=0, le=60)


@lru_cache
def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]

