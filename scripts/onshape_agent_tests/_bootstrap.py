import os
import sys
import subprocess
from pathlib import Path


def ensure_onshape_agent_on_path() -> None:
    repo_root = Path(__file__).resolve().parents[2]
    agent_dir = repo_root / "BetterSiri" / "Sources" / "Resources" / "OnShapeAgent"
    sys.path.insert(0, str(agent_dir))


def ensure_onshape_oauth_env() -> None:
    # Prefer the same OAuth token file location used by the app.
    token_file = Path.home() / "Library" / "Application Support" / "BetterSiri" / "OnShape" / "oauth_token.json"
    os.environ.setdefault("ONSHAPE_OAUTH_TOKEN_FILE", str(token_file))

    def defaults_read(key: str) -> str:
        try:
            p = subprocess.run(
                ["/usr/bin/defaults", "read", "com.bettersiri.app", key],
                check=False,
                capture_output=True,
                text=True,
            )
            if p.returncode != 0:
                return ""
            return (p.stdout or "").strip()
        except Exception:
            return ""

    # Pull app-configured values into env for the python MCP.
    os.environ.setdefault("ONSHAPE_OAUTH_CLIENT_ID", defaults_read("onshape_oauthClientId"))
    os.environ.setdefault("ONSHAPE_OAUTH_CLIENT_SECRET", defaults_read("onshape_oauthClientSecret"))
    os.environ.setdefault("ONSHAPE_OAUTH_BASE_URL", defaults_read("onshape_oauthBaseUrl") or "https://oauth.onshape.com")
    os.environ.setdefault("ONSHAPE_ACCESS_KEY", defaults_read("onshape_apiKey"))
    os.environ.setdefault("ONSHAPE_SECRET_KEY", defaults_read("onshape_secretKey"))

    # Default auth selection:
    # - Prefer signature auth when keys are present (more robust for unattended runs).
    # - Otherwise, fall back to OAuth token file.
    if (os.environ.get("ONSHAPE_ACCESS_KEY") or "").strip() and (os.environ.get("ONSHAPE_SECRET_KEY") or "").strip():
        os.environ.setdefault("ONSHAPE_AUTH_MODE", "signature")
    else:
        os.environ.setdefault("ONSHAPE_AUTH_MODE", "oauth")

    # Base URL will be overridden by onshape_set_context(base_url=...), but set a sane default.
    os.environ.setdefault("ONSHAPE_BASE_URL", defaults_read("onshape_baseUrl") or "https://cteinccsd.onshape.com/api")
    os.environ.setdefault("ONSHAPE_API_VERSION", defaults_read("onshape_apiVersion") or "v13")
