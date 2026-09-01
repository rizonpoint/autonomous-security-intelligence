import hmac
from functools import lru_cache
from typing import Annotated, Any

from fastapi import Depends, Header, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from .config import get_settings
from .store import StoreError, SupabaseStore


bearer = HTTPBearer(auto_error=False)


@lru_cache
def get_store() -> SupabaseStore:
    return SupabaseStore.from_settings(get_settings())


def as_http_error(exc: StoreError) -> HTTPException:
    return HTTPException(status_code=exc.status_code, detail=exc.detail)


async def current_agent(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)],
    store: Annotated[SupabaseStore, Depends(get_store)],
) -> dict[str, Any]:
    if not credentials or credentials.scheme.lower() != "bearer":
        raise HTTPException(status_code=401, detail="agent bearer credential required")
    try:
        return await store.authenticate_agent(credentials.credentials)
    except StoreError as exc:
        raise as_http_error(exc) from exc


async def require_admin(
    x_admin_token: Annotated[str | None, Header(alias="X-Admin-Token")] = None,
) -> None:
    expected = get_settings().control_plane_admin_token.get_secret_value()
    if not x_admin_token or not hmac.compare_digest(x_admin_token, expected):
        raise HTTPException(status_code=401, detail="valid admin token required")


Agent = Annotated[dict[str, Any], Depends(current_agent)]
Store = Annotated[SupabaseStore, Depends(get_store)]
Admin = Annotated[None, Depends(require_admin)]

