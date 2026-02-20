#!/usr/bin/env python3
"""
Claude Code Proxy — GLM-5 Router (v3)

Routes Claude Code requests by model tier:
- Opus → Anthropic (OAuth passthrough)
- Sonnet/Haiku → Z.AI GLM-5 (via Anthropic-compatible endpoint)

Key design: Claude Code keeps native model names (claude-sonnet-4-6, etc.)
for correct capability detection. The proxy rewrites to glm-5 only when
forwarding to Z.AI. For Anthropic fallbacks (web_search, vision), no
rewrite is needed — the model name is already valid.

Features:
- Circuit breaker: auto-bypass Z.AI after repeated failures
- Startup validation: checks API keys and provider URLs
- Automatic fallback for unsupported features (web_search, vision, forced_tool_choice)
"""

from fastapi import FastAPI, Request, Response
from fastapi.responses import StreamingResponse, JSONResponse
from starlette.background import BackgroundTask
from contextlib import asynccontextmanager
import httpx
import os
import json
import logging
import asyncio
import random
import uuid
import time

# ANSI colors
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
RESET = "\033[0m"

# Configure logging
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s | %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("proxy")


def log_ok(rid: str, msg: str):
    logger.info(f"{GREEN}[{rid}] {msg}{RESET}")

def log_route(rid: str, msg: str):
    logger.info(f"{CYAN}[{rid}] {msg}{RESET}")

def log_warn(rid: str, msg: str):
    logger.warning(f"{YELLOW}[{rid}] {msg}{RESET}")

def log_err(rid: str, msg: str):
    logger.error(f"{RED}[{rid}] {msg}{RESET}")

# Load .env
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass


@asynccontextmanager
async def lifespan(app: FastAPI):
    timeout_config = httpx.Timeout(
        connect=float(os.getenv("CONNECT_TIMEOUT", "10")),
        read=float(os.getenv("READ_TIMEOUT", "300")),
        write=float(os.getenv("WRITE_TIMEOUT", "30")),
        pool=float(os.getenv("POOL_TIMEOUT", "5")),
    )
    limits = httpx.Limits(
        max_connections=int(os.getenv("MAX_CONNECTIONS", "100")),
        max_keepalive_connections=int(os.getenv("MAX_KEEPALIVE_CONNECTIONS", "20")),
        keepalive_expiry=float(os.getenv("KEEPALIVE_EXPIRY", "30.0")),
    )
    app.state.http_client = httpx.AsyncClient(timeout=timeout_config, limits=limits)
    logger.info("HTTP client ready")
    yield
    await app.state.http_client.aclose()


app = FastAPI(title="Claude Code Proxy — GLM-5 Router", lifespan=lifespan)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
HAIKU_API_KEY = os.getenv("HAIKU_PROVIDER_API_KEY")
HAIKU_BASE_URL = os.getenv("HAIKU_PROVIDER_BASE_URL")
SONNET_API_KEY = os.getenv("SONNET_PROVIDER_API_KEY")
SONNET_BASE_URL = os.getenv("SONNET_PROVIDER_BASE_URL")
OPUS_API_KEY = os.getenv("OPUS_PROVIDER_API_KEY")
OPUS_BASE_URL = os.getenv("OPUS_PROVIDER_BASE_URL")

ANTHROPIC_BASE_URL = "https://api.anthropic.com"
PORT = int(os.getenv("PORT", "8082"))

# The model name to send to Z.AI (replaces Claude model names)
ZAI_TARGET_MODEL = os.getenv("ZAI_TARGET_MODEL", "glm-5")

MAX_RETRIES = int(os.getenv("MAX_RETRIES", "3"))
BASE_RETRY_DELAY = float(os.getenv("BASE_RETRY_DELAY", "1.0"))
MAX_RETRY_DELAY = float(os.getenv("MAX_RETRY_DELAY", "60.0"))

MAX_CONCURRENT_REQUESTS = int(os.getenv("MAX_CONCURRENT_REQUESTS", "5"))
haiku_semaphore = asyncio.Semaphore(MAX_CONCURRENT_REQUESTS)
sonnet_semaphore = asyncio.Semaphore(MAX_CONCURRENT_REQUESTS)
opus_semaphore = asyncio.Semaphore(MAX_CONCURRENT_REQUESTS)


# ---------------------------------------------------------------------------
# Startup validation
# ---------------------------------------------------------------------------
def validate_config():
    """Validate provider configuration at startup."""
    warnings = []
    tiers = [
        ("Haiku", HAIKU_BASE_URL, HAIKU_API_KEY),
        ("Sonnet", SONNET_BASE_URL, SONNET_API_KEY),
        ("Opus", OPUS_BASE_URL, OPUS_API_KEY),
    ]
    for name, base_url, api_key in tiers:
        if base_url and not api_key:
            warnings.append(f"{name}: base URL set but API key is missing")
        if api_key and not base_url:
            warnings.append(f"{name}: API key set but base URL is missing")

    if not any(url for _, url, _ in tiers):
        logger.info("All tiers → Anthropic OAuth (no Z.AI providers configured)")

    for w in warnings:
        logger.warning(f"{YELLOW}Config: {w}{RESET}")

    return len(warnings) == 0


# ---------------------------------------------------------------------------
# Circuit breaker — auto-bypass Z.AI after repeated failures
# ---------------------------------------------------------------------------
class CircuitBreaker:
    """
    Tracks failures per provider. After `threshold` consecutive failures,
    opens the circuit for `recovery_time` seconds, routing to Anthropic instead.
    """

    def __init__(
        self,
        threshold: int = int(os.getenv("CIRCUIT_BREAKER_THRESHOLD", "5")),
        recovery_time: float = float(os.getenv("CIRCUIT_BREAKER_RECOVERY", "120")),
    ):
        self.threshold = threshold
        self.recovery_time = recovery_time
        self._failures: dict[str, int] = {}
        self._opened_at: dict[str, float] = {}

    def is_open(self, tier: str) -> bool:
        """Check if circuit is open (provider should be bypassed)."""
        if tier not in self._opened_at:
            return False
        elapsed = time.time() - self._opened_at[tier]
        if elapsed >= self.recovery_time:
            # Recovery period elapsed — close circuit (half-open → test)
            self._failures[tier] = 0
            del self._opened_at[tier]
            logger.info(f"{GREEN}Circuit closed for {tier} — retrying Z.AI{RESET}")
            return False
        return True

    def record_failure(self, tier: str):
        """Record a failure. Opens circuit if threshold reached."""
        self._failures[tier] = self._failures.get(tier, 0) + 1
        if self._failures[tier] >= self.threshold and tier not in self._opened_at:
            self._opened_at[tier] = time.time()
            logger.warning(
                f"{YELLOW}Circuit OPEN for {tier} — "
                f"bypassing Z.AI for {self.recovery_time}s after "
                f"{self._failures[tier]} failures{RESET}"
            )

    def record_success(self, tier: str):
        """Record a success. Resets failure count."""
        if tier in self._failures:
            self._failures[tier] = 0
        if tier in self._opened_at:
            del self._opened_at[tier]

    def status(self) -> dict:
        """Return circuit status for health endpoint."""
        result = {}
        for tier in ("haiku", "sonnet", "opus"):
            if self.is_open(tier):
                remaining = self.recovery_time - (time.time() - self._opened_at[tier])
                result[tier] = f"OPEN (bypass for {remaining:.0f}s more)"
            else:
                failures = self._failures.get(tier, 0)
                result[tier] = f"CLOSED ({failures}/{self.threshold} failures)"
        return result


circuit_breaker = CircuitBreaker()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def short_id() -> str:
    return uuid.uuid4().hex[:8]


def _detect_tier(model_name: str) -> str | None:
    """Detect model tier from Claude Code's model name via substring matching."""
    m = model_name.lower()
    if "opus" in m:
        return "opus"
    elif "sonnet" in m:
        return "sonnet"
    elif "haiku" in m:
        return "haiku"
    # Also catch direct glm-5 requests (legacy config)
    elif m.startswith("glm"):
        return "sonnet"  # treat GLM models as sonnet tier
    return None


def get_provider_config(model_name: str):
    """
    Route by model tier (substring detection).
    Returns (api_key, base_url, provider_label, semaphore) or None for Anthropic passthrough.
    """
    tier = _detect_tier(model_name)

    if tier == "opus":
        if OPUS_BASE_URL:
            return (OPUS_API_KEY, OPUS_BASE_URL, "Opus→Z.AI", opus_semaphore)
        return None  # Opus → Anthropic OAuth

    elif tier == "sonnet":
        if SONNET_BASE_URL:
            return (SONNET_API_KEY, SONNET_BASE_URL, "Sonnet→Z.AI", sonnet_semaphore)
        return None

    elif tier == "haiku":
        if HAIKU_BASE_URL:
            return (HAIKU_API_KEY, HAIKU_BASE_URL, "Haiku→Z.AI", haiku_semaphore)
        return None

    # Unknown model → passthrough to Anthropic
    return None


def calculate_retry_delay(attempt: int) -> float:
    max_delay = min(MAX_RETRY_DELAY, BASE_RETRY_DELAY * (2 ** attempt))
    return random.uniform(0, max_delay)


def strip_encoding_headers(headers) -> dict:
    """Remove encoding headers that cause ZlibError (httpx already decompresses)."""
    return {
        k: v for k, v in headers.items()
        if k.lower() not in ("content-encoding", "transfer-encoding", "content-length")
    }


# ---------------------------------------------------------------------------
# Incompatibility detection (triggers Anthropic fallback)
# ---------------------------------------------------------------------------
def _has_web_search(data: dict) -> bool:
    for tool in data.get("tools", []):
        if isinstance(tool, dict) and str(tool.get("type", "")).startswith("web_search"):
            return True
    return False


def _has_image_content(data: dict) -> bool:
    for msg in data.get("messages", []):
        if not isinstance(msg, dict):
            continue
        content = msg.get("content")
        if isinstance(content, list):
            for block in content:
                if not isinstance(block, dict):
                    continue
                btype = block.get("type", "")
                if btype in ("image", "image_url"):
                    return True
                source = block.get("source", {})
                if isinstance(source, dict) and source.get("type") in ("base64", "url"):
                    return True
    return False


def _has_forced_tool_choice(data: dict) -> bool:
    """Check if request uses forced tool_choice (not 'auto') — Z.AI only supports 'auto'."""
    tc = data.get("tool_choice")
    if isinstance(tc, dict):
        return tc.get("type", "") not in ("auto", "")
    if isinstance(tc, str):
        return tc not in ("auto", "")
    return False


# ---------------------------------------------------------------------------
# Z.AI request sanitization
# ---------------------------------------------------------------------------
def sanitize_for_zai(data: dict, rid: str) -> dict:
    """Strip/convert Anthropic-specific parameters for Z.AI compatibility."""
    removed = []

    # Remove unsupported top-level parameters
    for key in ["metadata", "prompt_caching", "service_tier", "context_management", "output_config"]:
        if key in data:
            data.pop(key)
            removed.append(key)

    # Thinking: strip budget_tokens (Z.AI supports thinking.type but not budget)
    if "thinking" in data and isinstance(data["thinking"], dict):
        if "budget_tokens" in data["thinking"]:
            data["thinking"].pop("budget_tokens")
            removed.append("thinking.budget_tokens")

    # Remove extended_thinking (Anthropic-only legacy)
    if "extended_thinking" in data:
        data.pop("extended_thinking")
        removed.append("extended_thinking")

    # Strip web_search tools (handled by bypass, but double-safe)
    if "tools" in data and isinstance(data["tools"], list):
        original_count = len(data["tools"])
        data["tools"] = [
            t for t in data["tools"]
            if not (isinstance(t, dict) and str(t.get("type", "")).startswith("web_search"))
        ]
        stripped = original_count - len(data["tools"])
        if stripped:
            removed.append(f"web_search(x{stripped})")
        if not data["tools"]:
            data.pop("tools")
            removed.append("tools(empty)")
            if "tool_choice" in data:
                data.pop("tool_choice")
                removed.append("tool_choice")
        elif isinstance(data.get("tool_choice"), dict):
            if data["tool_choice"].get("name") == "web_search":
                data.pop("tool_choice")
                removed.append("tool_choice(web_search)")

    # Strip cache_control everywhere (Z.AI has automatic caching)
    cache_cleaned = _strip_cache_control(data)
    if cache_cleaned:
        removed.append(f"cache_control(x{cache_cleaned})")

    if removed:
        logger.debug(f"[{rid}] Sanitized: {', '.join(removed)}")

    return data


def _strip_cache_control(data: dict) -> int:
    """Recursively strip cache_control from system, messages, tools."""
    count = 0

    system = data.get("system")
    if isinstance(system, list):
        for block in system:
            if isinstance(block, dict) and "cache_control" in block:
                block.pop("cache_control")
                count += 1
    elif isinstance(system, dict) and "cache_control" in system:
        system.pop("cache_control")
        count += 1

    for msg in data.get("messages", []):
        if not isinstance(msg, dict):
            continue
        if "cache_control" in msg:
            msg.pop("cache_control")
            count += 1
        if isinstance(msg.get("content"), list):
            for block in msg["content"]:
                if isinstance(block, dict) and "cache_control" in block:
                    block.pop("cache_control")
                    count += 1

    for tool in data.get("tools", []):
        if isinstance(tool, dict) and "cache_control" in tool:
            tool.pop("cache_control")
            count += 1

    return count


# ---------------------------------------------------------------------------
# Streaming wrapper
# ---------------------------------------------------------------------------
async def safe_stream_wrapper(stream, rid: str, label: str):
    try:
        async for chunk in stream:
            yield chunk
    except httpx.ReadTimeout:
        log_err(rid, f"Mid-stream timeout: {label}")
    except httpx.NetworkError as e:
        log_err(rid, f"Mid-stream network error: {label} - {e}")
    except Exception as e:
        log_err(rid, f"Mid-stream error: {label} - {type(e).__name__}: {e}")


# ---------------------------------------------------------------------------
# Main proxy endpoint
# ---------------------------------------------------------------------------
def _is_zai_server_error(response) -> bool:
    """Detect Z.AI internal server errors disguised as 400 (code 500 inside body)."""
    if response.status_code in (400, 500, 502, 503):
        try:
            body = response.text if hasattr(response, 'text') else response.content.decode(errors='replace')
            return '"code":"500"' in body or '"code": "500"' in body
        except Exception:
            pass
    return False


def _build_anthropic_headers(original_headers: dict) -> dict:
    """Build headers for Anthropic OAuth passthrough."""
    headers = {"Content-Type": "application/json"}
    if "authorization" in original_headers:
        headers["Authorization"] = original_headers["authorization"]
    for h in ["anthropic-version", "anthropic-beta", "x-api-key"]:
        if h in original_headers:
            headers[h] = original_headers[h]
    return headers


@app.post("/v1/messages")
async def proxy_messages(request: Request):
    rid = short_id()
    data = await request.json()
    original_model = data.get("model", "")
    is_streaming = data.get("stream", False)
    original_headers = dict(request.headers)
    stream_tag = "⇄" if is_streaming else "→"
    # Keep a clean copy for Anthropic fallback (before Z.AI sanitization)
    original_data = json.loads(json.dumps(data, default=str))

    provider_config = get_provider_config(original_model)
    is_zai_route = provider_config is not None

    # ── Anthropic fallback for incompatible features ──
    if provider_config:
        bypass_reason = None
        if _has_web_search(data):
            bypass_reason = "web_search"
        elif _has_image_content(data):
            bypass_reason = "vision/image"
        elif _has_forced_tool_choice(data):
            bypass_reason = "forced_tool_choice"

        if bypass_reason:
            provider_config = None  # → Anthropic OAuth
            is_zai_route = False
            log_route(rid, f"{original_model} {stream_tag} Anthropic ({bypass_reason} bypass)")

    # ── Circuit breaker: bypass Z.AI if too many recent failures ──
    tier = _detect_tier(original_model)
    if provider_config and tier and circuit_breaker.is_open(tier):
        provider_config = None
        is_zai_route = False
        log_warn(rid, f"{original_model} {stream_tag} Anthropic (circuit breaker open for {tier})")

    # ── Route to Z.AI ──
    if provider_config:
        api_key, base_url, provider_label, provider_semaphore = provider_config
        target_url = f"{base_url}/v1/messages"
        target_headers = {"Content-Type": "application/json"}

        if api_key:
            target_headers["Authorization"] = f"Bearer {api_key}"
            target_headers["x-api-key"] = api_key

        if "anthropic-version" in original_headers:
            target_headers["anthropic-version"] = original_headers["anthropic-version"]

        # Rewrite model name to GLM-5 for Z.AI
        data["model"] = ZAI_TARGET_MODEL
        # Sanitize Anthropic-specific parameters
        data = sanitize_for_zai(data, rid)

        log_route(rid, f"{original_model} {stream_tag} {provider_label} (model→{ZAI_TARGET_MODEL})")

    # ── Route to Anthropic (OAuth passthrough) ──
    else:
        provider_semaphore = None
        target_url = f"{ANTHROPIC_BASE_URL}/v1/messages"
        target_headers = _build_anthropic_headers(original_headers)

        auth_method = "OAuth" if "authorization" in original_headers else "API-Key"
        log_route(rid, f"{original_model} {stream_tag} Anthropic ({auth_method})")

    # ── Execute request with retries ──
    client = request.app.state.http_client
    sem = provider_semaphore if provider_semaphore else asyncio.Semaphore(9999)

    async with sem:
        for attempt in range(MAX_RETRIES):
            try:
                if is_streaming:
                    target_headers["Accept"] = "text/event-stream"
                    req = client.build_request("POST", target_url, json=data, headers=target_headers)

                    try:
                        response = await client.send(req, stream=True)
                    except (httpx.ReadTimeout, httpx.ConnectTimeout) as e:
                        err = "read-timeout" if isinstance(e, httpx.ReadTimeout) else "connect-timeout"
                        log_err(rid, f"Stream {err} (attempt {attempt+1}/{MAX_RETRIES})")
                        if attempt < MAX_RETRIES - 1:
                            await asyncio.sleep(calculate_retry_delay(attempt))
                            continue
                        return JSONResponse(status_code=504, content={"error": f"Gateway timeout: {err}"})

                    if response.status_code >= 400:
                        body = await response.aread()
                        await response.aclose()
                        body_str = body.decode(errors='replace')
                        log_err(rid, f"Stream error {response.status_code}: {body_str[:500]}")

                        # Z.AI server error → fallback to Anthropic
                        if is_zai_route and ('"code":"500"' in body_str or '"code": "500"' in body_str):
                            if tier:
                                circuit_breaker.record_failure(tier)
                            log_warn(rid, "Z.AI server error, falling back to Anthropic")
                            fallback_headers = _build_anthropic_headers(original_headers)
                            fallback_headers["Accept"] = "text/event-stream"
                            fb_req = client.build_request("POST", f"{ANTHROPIC_BASE_URL}/v1/messages", json=original_data, headers=fallback_headers)
                            fb_response = await client.send(fb_req, stream=True)
                            if fb_response.status_code < 400:
                                log_ok(rid, f"Anthropic fallback OK ({fb_response.status_code})")
                                return StreamingResponse(
                                    safe_stream_wrapper(fb_response.aiter_bytes(), rid, original_model),
                                    media_type="text/event-stream",
                                    background=BackgroundTask(fb_response.aclose),
                                )
                            else:
                                fb_body = await fb_response.aread()
                                await fb_response.aclose()
                                log_err(rid, f"Anthropic fallback also failed: {fb_response.status_code}")
                                return Response(content=fb_body, status_code=fb_response.status_code, headers=strip_encoding_headers(fb_response.headers))

                        return Response(content=body, status_code=response.status_code, headers=strip_encoding_headers(response.headers))

                    if is_zai_route and tier:
                        circuit_breaker.record_success(tier)
                    log_ok(rid, f"Stream started ({response.status_code})")
                    return StreamingResponse(
                        safe_stream_wrapper(response.aiter_bytes(), rid, original_model),
                        media_type="text/event-stream",
                        background=BackgroundTask(response.aclose),
                    )
                else:
                    response = await client.post(target_url, json=data, headers=target_headers)

                    if response.status_code == 429 and attempt < MAX_RETRIES - 1:
                        retry_after = response.headers.get("retry-after")
                        delay = float(retry_after) if retry_after else calculate_retry_delay(attempt)
                        log_warn(rid, f"429 rate limited, retrying in {delay:.1f}s")
                        await asyncio.sleep(delay)
                        continue

                    if response.status_code >= 400:
                        log_err(rid, f"HTTP {response.status_code}: {response.text[:500]}")

                        # Z.AI server error → fallback to Anthropic
                        if is_zai_route and _is_zai_server_error(response):
                            if tier:
                                circuit_breaker.record_failure(tier)
                            log_warn(rid, "Z.AI server error, falling back to Anthropic")
                            fallback_headers = _build_anthropic_headers(original_headers)
                            fb_response = await client.post(f"{ANTHROPIC_BASE_URL}/v1/messages", json=original_data, headers=fallback_headers)
                            if fb_response.status_code < 400:
                                log_ok(rid, f"Anthropic fallback OK ({fb_response.status_code})")
                            else:
                                log_err(rid, f"Anthropic fallback also failed: {fb_response.status_code}")
                            return Response(
                                content=fb_response.content,
                                status_code=fb_response.status_code,
                                headers=strip_encoding_headers(fb_response.headers),
                            )

                    if response.status_code < 400:
                        if is_zai_route and tier:
                            circuit_breaker.record_success(tier)
                        log_ok(rid, f"OK ({response.status_code})")
                    return Response(
                        content=response.content,
                        status_code=response.status_code,
                        headers=strip_encoding_headers(response.headers),
                    )

            except httpx.ReadTimeout:
                log_err(rid, f"Read timeout (attempt {attempt+1}/{MAX_RETRIES})")
                if is_zai_route and tier:
                    circuit_breaker.record_failure(tier)
                if attempt < MAX_RETRIES - 1:
                    await asyncio.sleep(calculate_retry_delay(attempt))
                    continue
                # Timeout on Z.AI → try Anthropic
                if is_zai_route:
                    log_warn(rid, "Z.AI timeout, falling back to Anthropic")
                    try:
                        fallback_headers = _build_anthropic_headers(original_headers)
                        fb_response = await client.post(f"{ANTHROPIC_BASE_URL}/v1/messages", json=original_data, headers=fallback_headers)
                        log_ok(rid, f"Anthropic fallback after timeout: {fb_response.status_code}")
                        return Response(content=fb_response.content, status_code=fb_response.status_code, headers=strip_encoding_headers(fb_response.headers))
                    except Exception as fb_err:
                        log_err(rid, f"Anthropic fallback also failed: {fb_err}")
                return JSONResponse(status_code=504, content={"error": "Gateway timeout"})

            except httpx.ConnectTimeout:
                log_err(rid, f"Connect timeout (attempt {attempt+1}/{MAX_RETRIES})")
                if attempt < MAX_RETRIES - 1:
                    await asyncio.sleep(calculate_retry_delay(attempt))
                    continue
                return JSONResponse(status_code=504, content={"error": "Gateway timeout"})

            except httpx.HTTPStatusError as e:
                log_err(rid, f"HTTP error: {e.response.status_code}")
                return Response(content=e.response.content, status_code=e.response.status_code, headers=strip_encoding_headers(e.response.headers))

            except Exception as e:
                log_err(rid, f"Unexpected: {type(e).__name__}: {e}")
                if attempt < MAX_RETRIES - 1:
                    await asyncio.sleep(calculate_retry_delay(attempt))
                    continue
                return JSONResponse(status_code=500, content={"error": f"Proxy error: {e}"})

        return JSONResponse(status_code=500, content={"error": "Max retries exceeded"})


# ---------------------------------------------------------------------------
# Token counting — passthrough to Anthropic (Z.AI doesn't support it)
# ---------------------------------------------------------------------------
@app.post("/v1/messages/count_tokens")
async def proxy_count_tokens(request: Request):
    rid = short_id()
    data = await request.json()
    original_model = data.get("model", "")
    original_headers = dict(request.headers)

    # Always forward to Anthropic for token counting
    target_url = f"{ANTHROPIC_BASE_URL}/v1/messages/count_tokens"
    target_headers = {"Content-Type": "application/json"}

    if "authorization" in original_headers:
        target_headers["Authorization"] = original_headers["authorization"]

    for header in ["anthropic-version", "anthropic-beta", "x-api-key"]:
        if header in original_headers:
            target_headers[header] = original_headers[header]

    log_route(rid, f"count_tokens {original_model} → Anthropic")

    client = request.app.state.http_client
    try:
        response = await client.post(target_url, json=data, headers=target_headers)
        if response.status_code >= 400:
            log_err(rid, f"count_tokens HTTP {response.status_code}: {response.text[:300]}")
        return Response(
            content=response.content,
            status_code=response.status_code,
            headers=strip_encoding_headers(response.headers),
        )
    except Exception as e:
        log_err(rid, f"count_tokens error: {type(e).__name__}: {e}")
        return JSONResponse(status_code=500, content={"error": f"Proxy error: {e}"})


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------
@app.get("/health")
async def health_check():
    return {
        "status": "healthy",
        "target_model": ZAI_TARGET_MODEL,
        "routing": {
            "opus": "Z.AI" if OPUS_BASE_URL else "Anthropic (OAuth)",
            "sonnet": "Z.AI" if SONNET_BASE_URL else "Anthropic (OAuth)",
            "haiku": "Z.AI" if HAIKU_BASE_URL else "Anthropic (OAuth)",
        },
        "circuit_breaker": circuit_breaker.status(),
        "fallbacks": ["web_search → Anthropic", "vision/image → Anthropic"],
    }


# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    import uvicorn

    validate_config()

    print("=" * 60)
    print("  Claude Code Proxy — GLM-5 Router v3")
    print("=" * 60)
    print()
    print("Routing (by model name substring):")
    print(f"  *opus*   → {'Z.AI (' + ZAI_TARGET_MODEL + ')' if OPUS_BASE_URL else 'Anthropic (OAuth)'}")
    print(f"  *sonnet* → {'Z.AI (' + ZAI_TARGET_MODEL + ')' if SONNET_BASE_URL else 'Anthropic (OAuth)'}")
    print(f"  *haiku*  → {'Z.AI (' + ZAI_TARGET_MODEL + ')' if HAIKU_BASE_URL else 'Anthropic (OAuth)'}")
    print()
    print("Anthropic fallbacks:")
    print("  web_search  → Anthropic (native model name)")
    print("  vision      → Anthropic (native model name)")
    print()
    print(f"Port: {PORT} | Log: {LOG_LEVEL}")
    print("=" * 60)

    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="info")
