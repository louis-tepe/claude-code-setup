#!/usr/bin/env python3
"""
Claude Code Proxy — Multi-Provider Router (v5)

Routes Claude Code requests by model tier to configurable providers:
- Opus → Anthropic (OAuth passthrough)
- Sonnet → Provider (GLM-5.1, MiniMax-M2.7, etc.)
- Haiku → Provider (GLM-4.7, MiniMax-M2.7, etc.)

Key design: Claude Code keeps native model names (claude-sonnet-4-6, etc.)
for correct capability detection. The proxy rewrites to the provider model
only when forwarding. For Anthropic fallbacks (web_search, vision), no
rewrite is needed — the model name is already valid.

Features:
- Multi-provider: Z.AI GLM, MiniMax M2.7, or any Anthropic-compatible API
- Model-based pricing: automatic cost display from MODEL_PRICING table
- Circuit breaker: auto-bypass provider after repeated failures
- Automatic fallback for unsupported features (web_search, vision, documents)
"""

from fastapi import FastAPI, Request, Response
from fastapi.responses import StreamingResponse, JSONResponse
from starlette.background import BackgroundTask
from contextlib import asynccontextmanager
import httpx
import os
import sys
import json
import logging
import asyncio
import random
import uuid
import time

# Force unbuffered output so logs appear immediately in file
os.environ["PYTHONUNBUFFERED"] = "1"
sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)

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

# Suppress verbose httpx/httpcore logs (proxy logs already cover routing + status)
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)


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
    stats.start_persistence()
    yield
    await stats.stop_persistence()
    await app.state.http_client.aclose()


app = FastAPI(title="Claude Code Proxy — Multi-Provider Router", lifespan=lifespan)


# ---------------------------------------------------------------------------
# Request logging middleware — logs every incoming request
# ---------------------------------------------------------------------------
@app.middleware("http")
async def log_all_requests(request: Request, call_next):
    """Log every incoming request for visibility, including sub-agent calls."""
    method = request.method
    path = request.url.path
    client = request.client.host if request.client else "unknown"
    logger.debug(f"→ {method} {path} from {client}")
    response = await call_next(request)
    return response


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

# The model names to send to Z.AI per tier (replaces Claude model names)
PROVIDER_TARGET_MODEL = os.getenv("PROVIDER_TARGET_MODEL", "glm-5.1")  # default fallback
PROVIDER_SONNET_MODEL = os.getenv("PROVIDER_SONNET_MODEL", PROVIDER_TARGET_MODEL)
PROVIDER_HAIKU_MODEL = os.getenv("PROVIDER_HAIKU_MODEL", PROVIDER_TARGET_MODEL)
PROVIDER_OPUS_MODEL = os.getenv("PROVIDER_OPUS_MODEL", PROVIDER_TARGET_MODEL)


def _zai_model_for_tier(tier: str) -> str:
    """Return the Z.AI model name for a given tier."""
    return {"opus": PROVIDER_OPUS_MODEL, "sonnet": PROVIDER_SONNET_MODEL, "haiku": PROVIDER_HAIKU_MODEL}.get(tier, PROVIDER_TARGET_MODEL)

# Compatibility toggles — allow testing Z.AI support for these features
ALLOW_FORCED_TOOL_CHOICE = os.getenv("ALLOW_FORCED_TOOL_CHOICE", "").lower() in ("1", "true", "yes")
PROVIDER_PASS_CACHE_CONTROL = os.getenv("PROVIDER_PASS_CACHE_CONTROL", "").lower() in ("1", "true", "yes")

MAX_RETRIES = int(os.getenv("MAX_RETRIES", "3"))
BASE_RETRY_DELAY = float(os.getenv("BASE_RETRY_DELAY", "1.0"))
MAX_RETRY_DELAY = float(os.getenv("MAX_RETRY_DELAY", "60.0"))

# ---------------------------------------------------------------------------
# Pricing — model-based pricing table (USD per million tokens)
# ---------------------------------------------------------------------------
# Anthropic pricing — what Claude Code uses internally for cost display
ANTHROPIC_PRICING = {
    "sonnet": {"input": 3.00, "output": 15.00},
    "haiku":  {"input": 1.00, "output": 5.00},
}

# Provider model pricing — keyed by model name (lowercase), resolved per tier
# Source: https://docs.z.ai/guides/overview/pricing (Z.AI)
# Source: https://platform.minimax.io/docs/guides/pricing-paygo (MiniMax)
MODEL_PRICING: dict[str, dict[str, float]] = {
    # Z.AI GLM models (official pricing from docs.z.ai)
    "glm-5.1":        {"input": 1.40, "output": 4.40},
    "glm-5":          {"input": 1.00, "output": 3.20},
    "glm-5-turbo":    {"input": 1.20, "output": 4.00},
    "glm-4.7":        {"input": 0.60, "output": 2.20},
    "glm-4.7-flashx": {"input": 0.07, "output": 0.40},
    "glm-4.7-flash":  {"input": 0.00, "output": 0.00},  # free tier
    "glm-4.6":        {"input": 0.60, "output": 2.20},
    "glm-4.5":        {"input": 0.60, "output": 2.20},
    "glm-4.5-air":    {"input": 0.20, "output": 1.10},
    "glm-4.5-flash":  {"input": 0.00, "output": 0.00},  # free tier
    # MiniMax models (official pricing from platform.minimax.io)
    "minimax-m2.7":           {"input": 0.30, "output": 1.20},
    "minimax-m2.7-highspeed": {"input": 0.30, "output": 2.40},
    "minimax-m2.5":           {"input": 0.15, "output": 1.20},
    "minimax-m2.1":           {"input": 0.30, "output": 1.20},
}


def _model_pricing_for_tier(tier: str) -> dict[str, float] | None:
    """Get pricing for the model assigned to a tier. Returns None for non-provider tiers."""
    if tier not in ("sonnet", "haiku", "opus"):
        return None
    model = _zai_model_for_tier(tier).lower()
    return MODEL_PRICING.get(model)


def _scale_tokens(real_tokens: int, tier: str, direction: str) -> int:
    """Scale token count so Anthropic pricing × scaled = provider pricing × real."""
    if tier not in ANTHROPIC_PRICING or real_tokens == 0:
        return real_tokens
    model_price = _model_pricing_for_tier(tier)
    if not model_price:
        return real_tokens
    anthropic_price = ANTHROPIC_PRICING[tier][direction]
    provider_price = model_price[direction]
    return max(1, round(real_tokens * provider_price / anthropic_price))


MAX_CONCURRENT_REQUESTS = int(os.getenv("MAX_CONCURRENT_REQUESTS", "15"))
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
            logger.info(f"{GREEN}Circuit closed for {tier} — retrying provider{RESET}")
            return False
        return True

    def record_failure(self, tier: str):
        """Record a failure. Opens circuit if threshold reached."""
        self._failures[tier] = self._failures.get(tier, 0) + 1
        if self._failures[tier] >= self.threshold and tier not in self._opened_at:
            self._opened_at[tier] = time.time()
            logger.warning(
                f"{YELLOW}Circuit OPEN for {tier} — "
                f"bypassing provider for {self.recovery_time}s after "
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
# Request stats — in-memory tracking
# ---------------------------------------------------------------------------
STATS_FILE = os.getenv("STATS_FILE", "/tmp/claude-proxy-stats.json")
STATS_SAVE_INTERVAL = int(os.getenv("STATS_SAVE_INTERVAL", "60"))  # seconds


class ProxyStats:
    """Track request count, errors, latency, and token usage per tier.
    Persists cumulative stats to disk periodically and restores on startup."""

    def __init__(self):
        self._started_at = time.time()
        self._requests: dict[str, int] = {}
        self._errors: dict[str, int] = {}
        self._latencies: dict[str, list[float]] = {}
        self._input_tokens: dict[str, int] = {}
        self._output_tokens: dict[str, int] = {}
        self._fallbacks: int = 0
        self._lock = asyncio.Lock()
        self._save_task: asyncio.Task | None = None
        self._restore()

    def _restore(self):
        """Restore cumulative stats from disk on startup."""
        try:
            with open(STATS_FILE, "r") as f:
                saved = json.load(f)
            self._requests = saved.get("requests", {})
            self._errors = saved.get("errors", {})
            self._input_tokens = saved.get("input_tokens", {})
            self._output_tokens = saved.get("output_tokens", {})
            self._fallbacks = saved.get("fallbacks", 0)
            logger.info(f"Stats restored from {STATS_FILE}")
        except (FileNotFoundError, json.JSONDecodeError):
            pass

    def _save_sync(self):
        """Write cumulative stats to disk."""
        data = {
            "requests": self._requests,
            "errors": self._errors,
            "input_tokens": self._input_tokens,
            "output_tokens": self._output_tokens,
            "fallbacks": self._fallbacks,
        }
        try:
            with open(STATS_FILE, "w") as f:
                json.dump(data, f)
        except OSError as e:
            logger.warning(f"Failed to save stats: {e}")

    async def _periodic_save(self):
        """Background task: save stats every STATS_SAVE_INTERVAL seconds."""
        while True:
            await asyncio.sleep(STATS_SAVE_INTERVAL)
            async with self._lock:
                self._save_sync()

    def start_persistence(self):
        """Start the periodic save background task."""
        self._save_task = asyncio.create_task(self._periodic_save())

    async def stop_persistence(self):
        """Stop periodic save and do a final flush."""
        if self._save_task:
            self._save_task.cancel()
            try:
                await self._save_task
            except asyncio.CancelledError:
                pass
        async with self._lock:
            self._save_sync()
        logger.info(f"Stats saved to {STATS_FILE}")

    async def record(self, tier: str, latency: float, is_error: bool = False, is_fallback: bool = False):
        async with self._lock:
            self._requests[tier] = self._requests.get(tier, 0) + 1
            if is_error:
                self._errors[tier] = self._errors.get(tier, 0) + 1
            if is_fallback:
                self._fallbacks += 1
            # Keep last 100 latencies per tier (not persisted)
            if tier not in self._latencies:
                self._latencies[tier] = []
            self._latencies[tier].append(latency)
            if len(self._latencies[tier]) > 100:
                self._latencies[tier] = self._latencies[tier][-100:]

    async def record_tokens(self, tier: str, input_tokens: int, output_tokens: int):
        async with self._lock:
            self._input_tokens[tier] = self._input_tokens.get(tier, 0) + input_tokens
            self._output_tokens[tier] = self._output_tokens.get(tier, 0) + output_tokens

    def _fmt_tokens(self, n: int) -> str:
        if n >= 1_000_000:
            return f"{n / 1_000_000:.1f}M"
        if n >= 1_000:
            return f"{n / 1_000:.1f}k"
        return str(n)

    def summary(self) -> dict:
        uptime = time.time() - self._started_at
        hours = int(uptime // 3600)
        minutes = int((uptime % 3600) // 60)

        tiers = {}
        for tier in ("haiku", "sonnet", "opus", "anthropic"):
            req = self._requests.get(tier, 0)
            err = self._errors.get(tier, 0)
            lats = self._latencies.get(tier, [])
            avg_lat = sum(lats) / len(lats) if lats else 0
            inp = self._input_tokens.get(tier, 0)
            out = self._output_tokens.get(tier, 0)
            tiers[tier] = {
                "requests": req,
                "errors": err,
                "avg_latency_ms": round(avg_lat * 1000),
                "input_tokens": inp,
                "output_tokens": out,
                "total_tokens": self._fmt_tokens(inp + out),
            }

        total_inp = sum(self._input_tokens.values())
        total_out = sum(self._output_tokens.values())
        return {
            "uptime": f"{hours}h{minutes:02d}m",
            "total_requests": sum(self._requests.values()),
            "total_errors": sum(self._errors.values()),
            "fallbacks_to_anthropic": self._fallbacks,
            "total_tokens": {
                "input": total_inp,
                "output": total_out,
                "total": self._fmt_tokens(total_inp + total_out),
            },
            "per_tier": tiers,
        }


stats = ProxyStats()


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
    # Also catch direct glm-5/glm-5.1 requests (legacy config)
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
            return (OPUS_API_KEY, OPUS_BASE_URL, f"Opus→{PROVIDER_OPUS_MODEL}", opus_semaphore)
        return None  # Opus → Anthropic OAuth

    elif tier == "sonnet":
        if SONNET_BASE_URL:
            return (SONNET_API_KEY, SONNET_BASE_URL, f"Sonnet→{PROVIDER_SONNET_MODEL}", sonnet_semaphore)
        return None

    elif tier == "haiku":
        if HAIKU_BASE_URL:
            return (HAIKU_API_KEY, HAIKU_BASE_URL, f"Haiku→{PROVIDER_HAIKU_MODEL}", haiku_semaphore)
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
def _has_server_web_tools(data: dict) -> str | None:
    """Check for Anthropic server web tools (web_search, web_fetch). Returns bypass reason or None."""
    for tool in data.get("tools", []):
        if isinstance(tool, dict):
            tool_type = str(tool.get("type", ""))
            if tool_type.startswith("web_search"):
                return "web_search"
            if tool_type.startswith("web_fetch"):
                return "web_fetch"
    return None


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


def _has_document_content(data: dict) -> bool:
    """Check if any message contains document content blocks (PDF, etc.)."""
    for msg in data.get("messages", []):
        if not isinstance(msg, dict):
            continue
        content = msg.get("content")
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "document":
                    return True
    return False


def _has_forced_tool_choice(data: dict) -> bool:
    """Check if request uses non-auto tool_choice — Z.AI only supports 'auto'."""
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
    for key in ["metadata", "prompt_caching", "service_tier", "context_management",
                 "output_config", "inference_geo", "container", "citations",
                 "betas", "effort", "speed", "mcp_servers"]:
        if key in data:
            data.pop(key)
            removed.append(key)

    # Thinking: normalize for Z.AI compatibility
    # - Z.AI supports {type: "enabled"} but not {type: "adaptive"} (Opus/Sonnet 4.6+)
    # - Z.AI doesn't support budget_tokens
    if "thinking" in data and isinstance(data["thinking"], dict):
        thinking = data["thinking"]
        if thinking.get("type") == "adaptive":
            thinking["type"] = "enabled"
            removed.append("thinking.adaptive→enabled")
        if "budget_tokens" in thinking:
            thinking.pop("budget_tokens")
            removed.append("thinking.budget_tokens")
        if "effort" in thinking:
            thinking.pop("effort")
            removed.append("thinking.effort")

    # Remove extended_thinking (Anthropic-only legacy)
    if "extended_thinking" in data:
        data.pop("extended_thinking")
        removed.append("extended_thinking")

    # Strip Anthropic server tools and tool search tools (bypass handles most, double-safe)
    _server_tool_prefixes = ("web_search", "web_fetch", "tool_search_tool")
    if "tools" in data and isinstance(data["tools"], list):
        original_count = len(data["tools"])
        data["tools"] = [
            t for t in data["tools"]
            if not (isinstance(t, dict) and str(t.get("type", "")).startswith(_server_tool_prefixes))
        ]
        stripped = original_count - len(data["tools"])
        if stripped:
            removed.append(f"server_tools(x{stripped})")
        # Strip advanced tool-use fields unsupported by Z.AI
        tool_fields_stripped = 0
        for tool in data["tools"]:
            if isinstance(tool, dict):
                for key in ("defer_loading", "allowed_callers", "input_examples"):
                    if key in tool:
                        tool.pop(key)
                        tool_fields_stripped += 1
        if tool_fields_stripped:
            removed.append(f"tool_fields(x{tool_fields_stripped})")
        if not data["tools"]:
            data.pop("tools")
            removed.append("tools(empty)")
            if "tool_choice" in data:
                data.pop("tool_choice")
                removed.append("tool_choice")
        elif isinstance(data.get("tool_choice"), dict):
            tc_name = data["tool_choice"].get("name", "")
            if tc_name in ("web_search", "web_fetch"):
                data.pop("tool_choice")
                removed.append(f"tool_choice({tc_name})")

    # Strip Anthropic-specific blocks from message history
    # (thinking with signature, server tool blocks unknown to Z.AI, citations on text)
    blocks_stripped, citations_stripped = _strip_anthropic_blocks(data)
    if blocks_stripped:
        removed.append(f"anthropic_blocks(x{blocks_stripped})")
    if citations_stripped:
        removed.append(f"block_citations(x{citations_stripped})")

    # Strip cache_control unless passthrough is enabled
    if not PROVIDER_PASS_CACHE_CONTROL:
        cache_cleaned = _strip_cache_control(data)
        if cache_cleaned:
            removed.append(f"cache_control(x{cache_cleaned})")

    if removed:
        logger.info(f"[{rid}] Sanitized: {', '.join(removed)}")

    return data


# Anthropic-specific content block types to strip from message history
_ANTHROPIC_ONLY_BLOCKS = frozenset({
    "thinking", "redacted_thinking",                  # thinking signature breaks Z.AI
    "server_tool_use",                                 # Anthropic server-side tool call
    "web_search_tool_result", "web_fetch_tool_result", # server tool results
})


def _strip_anthropic_blocks(data: dict) -> tuple[int, int]:
    """Remove Anthropic-specific content blocks from assistant messages.

    Strips: thinking/redacted_thinking (signature breaks Z.AI),
    server_tool_use, web_search_tool_result, web_fetch_tool_result
    (Anthropic server-side tool blocks unknown to Z.AI).
    Also strips `citations` arrays from text blocks in history.

    Returns (blocks_removed, citations_removed).
    """
    blocks_removed = 0
    citations_removed = 0
    for msg in data.get("messages", []):
        if not isinstance(msg, dict) or msg.get("role") != "assistant":
            continue
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        original_len = len(content)
        new_content = []
        for block in content:
            if isinstance(block, dict) and block.get("type") in _ANTHROPIC_ONLY_BLOCKS:
                continue  # strip entire block
            # Strip citations from text blocks (Anthropic-only field)
            if isinstance(block, dict) and "citations" in block:
                block.pop("citations")
                citations_removed += 1
            new_content.append(block)
        msg["content"] = new_content
        blocks_removed += original_len - len(msg["content"])
        # If all blocks were stripped, keep at least an empty text block
        if not msg["content"]:
            msg["content"] = [{"type": "text", "text": ""}]
    return blocks_removed, citations_removed


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
def _estimate_input_tokens(data: dict) -> int:
    """Estimate input tokens from request body when provider doesn't return them.

    Uses ~4 characters per token as a rough approximation (standard for English).
    Returns 0 if estimation fails.
    """
    try:
        body_str = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
        return max(1, len(body_str) // 4)
    except (TypeError, ValueError):
        return 0


def _extract_tokens_from_response(content: bytes) -> tuple[int, int]:
    """Extract input/output tokens from a non-streaming Anthropic API response."""
    try:
        body = json.loads(content)
        usage = body.get("usage", {})
        return usage.get("input_tokens", 0), usage.get("output_tokens", 0)
    except (json.JSONDecodeError, AttributeError):
        return 0, 0


def _scale_response_usage(content: bytes, tier: str) -> bytes:
    """Rewrite usage tokens in a non-streaming response for correct cost display."""
    try:
        body = json.loads(content)
        usage = body.get("usage")
        if not isinstance(usage, dict):
            return content
        if "input_tokens" in usage:
            usage["input_tokens"] = _scale_tokens(usage["input_tokens"], tier, "input")
        if "output_tokens" in usage:
            usage["output_tokens"] = _scale_tokens(usage["output_tokens"], tier, "output")
        for cache_key in ("cache_creation_input_tokens", "cache_read_input_tokens"):
            if usage.get(cache_key, 0):
                usage[cache_key] = _scale_tokens(usage[cache_key], tier, "input")
        return json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode()
    except (json.JSONDecodeError, AttributeError):
        return content


async def safe_stream_wrapper(
    stream, rid: str, label: str,
    stats_tier: str | None = None,
    price_tier: str | None = None,
    start_time: float | None = None,
    fallback_input_tokens: int = 0,
):
    """Yield SSE events, extracting token stats and optionally scaling usage for pricing.

    Args:
        stats_tier: tier name for token accounting (real tokens)
        price_tier: tier name for price scaling (rewrites usage in events)
        start_time: request start timestamp for duration logging
        fallback_input_tokens: estimated input tokens from request body,
            used when the provider doesn't return input_tokens (e.g. Z.AI)
    """
    buffer = b""
    input_tokens = 0
    output_tokens = 0
    needs_processing = stats_tier is not None or price_tier is not None

    try:
        async for chunk in stream:
            if not needs_processing:
                yield chunk
                continue

            buffer += chunk
            # Process complete SSE events (delimited by \n\n)
            while b"\n\n" in buffer:
                event_bytes, _, buffer = buffer.partition(b"\n\n")
                event_out = event_bytes  # default: unmodified

                # Only parse events that might contain usage data
                if b"message_start" in event_bytes or b"message_delta" in event_bytes:
                    lines = event_bytes.split(b"\n")
                    new_lines = []
                    modified = False
                    for line in lines:
                        if not line.startswith(b"data: "):
                            new_lines.append(line)
                            continue
                        try:
                            data = json.loads(line[6:])
                            evt_type = data.get("type")
                            if evt_type == "message_start":
                                usage = data.get("message", {}).get("usage", {})
                                real_in = usage.get("input_tokens", 0)
                                input_tokens += real_in
                                if price_tier and real_in:
                                    usage["input_tokens"] = _scale_tokens(real_in, price_tier, "input")
                                    # Also scale cache tokens if present
                                    for cache_key in ("cache_creation_input_tokens", "cache_read_input_tokens"):
                                        if usage.get(cache_key, 0):
                                            usage[cache_key] = _scale_tokens(usage[cache_key], price_tier, "input")
                                    modified = True
                            elif evt_type == "message_delta":
                                usage = data.get("usage", {})
                                real_out = usage.get("output_tokens", 0)
                                output_tokens += real_out
                                if price_tier and real_out:
                                    usage["output_tokens"] = _scale_tokens(real_out, price_tier, "output")
                                    modified = True
                            if modified:
                                new_lines.append(b"data: " + json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode())
                            else:
                                new_lines.append(line)
                        except (json.JSONDecodeError, AttributeError):
                            new_lines.append(line)
                    if modified:
                        event_out = b"\n".join(new_lines)

                yield event_out + b"\n\n"

        # Yield any remaining partial data
        if buffer:
            yield buffer

    except httpx.ReadTimeout:
        log_err(rid, f"Mid-stream timeout: {label}")
    except httpx.NetworkError as e:
        log_err(rid, f"Mid-stream network error: {label} - {e}")
    except Exception as e:
        log_err(rid, f"Mid-stream error: {label} - {type(e).__name__}: {e}")
    finally:
        # Use fallback estimate when provider didn't return input_tokens
        estimated = False
        if input_tokens == 0 and fallback_input_tokens > 0 and output_tokens > 0:
            input_tokens = fallback_input_tokens
            estimated = True
        if stats_tier and (input_tokens or output_tokens):
            await stats.record_tokens(stats_tier, input_tokens, output_tokens)
        elapsed = f" ({time.time() - start_time:.1f}s)" if start_time else ""
        fmt = stats._fmt_tokens  # reuse compact formatter
        if input_tokens or output_tokens:
            in_prefix = "~" if estimated else ""
            log_ok(rid, f"Done {in_prefix}{fmt(input_tokens)} in / {fmt(output_tokens)} out{elapsed}")
        elif start_time:
            log_ok(rid, f"Done{elapsed}")


# ---------------------------------------------------------------------------
# Main proxy endpoint
# ---------------------------------------------------------------------------
def _is_zai_server_error_status(status_code: int, body_str: str = "") -> bool:
    """Detect Z.AI server errors that should trigger Anthropic fallback.

    Triggers on:
    - Any HTTP 5xx (real server error)
    - HTTP 400 with "code":"500" in body (Z.AI disguised error)
    """
    if status_code >= 500:
        return True
    if status_code == 400 and ('"code":"500"' in body_str or '"code": "500"' in body_str):
        return True
    return False


def _build_anthropic_headers(original_headers: dict) -> dict:
    """Pass through all headers to Anthropic, stripping only hop-by-hop headers."""
    skip = {"host", "content-length", "transfer-encoding", "connection"}
    return {k: v for k, v in original_headers.items() if k.lower() not in skip}


@app.post("/v1/messages")
async def proxy_messages(request: Request):
    rid = short_id()
    data = await request.json()
    original_model = data.get("model", "")
    is_streaming = data.get("stream", False)
    original_headers = dict(request.headers)
    stream_tag = "⇄" if is_streaming else "→"
    original_data = None  # Lazy: only copied when needed for Z.AI fallback

    provider_config = get_provider_config(original_model)
    is_zai_route = provider_config is not None
    bypass_reason = None

    # ── Anthropic fallback for incompatible features ──
    if provider_config:
        bypass_reason = None
        web_reason = _has_server_web_tools(data)
        if web_reason:
            bypass_reason = web_reason
        elif _has_image_content(data):
            bypass_reason = "vision/image"
        elif _has_document_content(data):
            bypass_reason = "document/pdf"
        elif not ALLOW_FORCED_TOOL_CHOICE and _has_forced_tool_choice(data):
            bypass_reason = "forced_tool_choice"

        if bypass_reason:
            provider_config = None  # → Anthropic OAuth
            is_zai_route = False
            log_route(rid, f"{original_model} {stream_tag} Anthropic ({bypass_reason} bypass)")

    # ── Circuit breaker: bypass Z.AI if too many recent failures ──
    tier = _detect_tier(original_model)
    circuit_breaker_open = provider_config and tier and circuit_breaker.is_open(tier)
    if circuit_breaker_open:
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

        # Keep clean copy for Anthropic fallback before mutating
        original_data = json.loads(json.dumps(data, default=str))
        # Rewrite model name to the tier-specific Z.AI model
        zai_model = _zai_model_for_tier(tier)
        data["model"] = zai_model
        # Sanitize Anthropic-specific parameters
        data = sanitize_for_zai(data, rid)

        log_route(rid, f"{original_model} {stream_tag} {provider_label} (model→{zai_model})")

    # ── Route to Anthropic (OAuth passthrough) ──
    else:
        provider_semaphore = None
        target_url = f"{ANTHROPIC_BASE_URL}/v1/messages"
        target_headers = _build_anthropic_headers(original_headers)

        # Only log if not already logged by bypass/circuit-breaker above
        if not bypass_reason and not circuit_breaker_open:
            auth_method = "OAuth" if "authorization" in original_headers else "API-Key"
            log_route(rid, f"{original_model} {stream_tag} Anthropic ({auth_method})")

    # ── Execute request ──
    # Only retry on Z.AI routes — Anthropic SDK handles its own retries
    client = request.app.state.http_client
    sem = provider_semaphore if provider_semaphore else asyncio.Semaphore(9999)
    stats_tier = tier if is_zai_route and tier else "anthropic"
    price_tier = tier if is_zai_route and tier else None  # Scale pricing only for Z.AI routes
    max_attempts = MAX_RETRIES if is_zai_route else 1
    request_start = time.time()

    async with sem:
        for attempt in range(max_attempts):
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
                        if is_zai_route and _is_zai_server_error_status(response.status_code, body_str):
                            if tier:
                                circuit_breaker.record_failure(tier)
                            await stats.record(stats_tier, time.time() - request_start, is_error=True, is_fallback=True)
                            log_warn(rid, "Provider error, falling back to Anthropic")
                            fallback_headers = _build_anthropic_headers(original_headers)
                            fallback_headers["Accept"] = "text/event-stream"
                            fb_req = client.build_request("POST", f"{ANTHROPIC_BASE_URL}/v1/messages", json=original_data, headers=fallback_headers)
                            fb_response = await client.send(fb_req, stream=True)
                            if fb_response.status_code < 400:
                                log_ok(rid, f"Anthropic fallback OK ({fb_response.status_code})")
                                return StreamingResponse(
                                    safe_stream_wrapper(fb_response.aiter_bytes(), rid, original_model, stats_tier="anthropic", start_time=request_start),
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
                    await stats.record(stats_tier, time.time() - request_start)
                    retry_info = f" retry {attempt+1}/{max_attempts}" if attempt > 0 else ""
                    log_ok(rid, f"Stream started ({response.status_code}){retry_info}")
                    # Estimate input tokens for providers that don't return them (Z.AI)
                    est_input = _estimate_input_tokens(data) if is_zai_route else 0
                    return StreamingResponse(
                        safe_stream_wrapper(response.aiter_bytes(), rid, original_model, stats_tier=stats_tier, price_tier=price_tier, start_time=request_start, fallback_input_tokens=est_input),
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
                        if is_zai_route and _is_zai_server_error_status(response.status_code, response.text[:1000]):
                            if tier:
                                circuit_breaker.record_failure(tier)
                            await stats.record(stats_tier, time.time() - request_start, is_error=True, is_fallback=True)
                            log_warn(rid, "Provider error, falling back to Anthropic")
                            fallback_headers = _build_anthropic_headers(original_headers)
                            fb_response = await client.post(f"{ANTHROPIC_BASE_URL}/v1/messages", json=original_data, headers=fallback_headers)
                            if fb_response.status_code < 400:
                                log_ok(rid, f"Anthropic fallback OK ({fb_response.status_code})")
                                inp, out = _extract_tokens_from_response(fb_response.content)
                                if inp or out:
                                    await stats.record_tokens("anthropic", inp, out)
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
                        elapsed = time.time() - request_start
                        await stats.record(stats_tier, elapsed)
                        inp, out = _extract_tokens_from_response(response.content)
                        # Fallback: estimate input tokens when provider doesn't return them
                        in_prefix = ""
                        if inp == 0 and out > 0 and is_zai_route:
                            inp = _estimate_input_tokens(data)
                            in_prefix = "~"
                        retry_info = f" retry {attempt+1}/{max_attempts}" if attempt > 0 else ""
                        if inp or out:
                            await stats.record_tokens(stats_tier, inp, out)
                            fmt = stats._fmt_tokens
                            log_ok(rid, f"OK {in_prefix}{fmt(inp)} in / {fmt(out)} out ({elapsed:.1f}s){retry_info}")
                        else:
                            log_ok(rid, f"OK ({elapsed:.1f}s){retry_info}")
                    else:
                        await stats.record(stats_tier, time.time() - request_start, is_error=True)
                    # Scale tokens in non-streaming response for correct cost display
                    resp_content = response.content
                    if price_tier and response.status_code < 400:
                        resp_content = _scale_response_usage(resp_content, price_tier)
                    return Response(
                        content=resp_content,
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
                    await stats.record(stats_tier, time.time() - request_start, is_error=True, is_fallback=True)
                    log_warn(rid, "Provider timeout, falling back to Anthropic")
                    try:
                        fallback_headers = _build_anthropic_headers(original_headers)
                        fb_response = await client.post(f"{ANTHROPIC_BASE_URL}/v1/messages", json=original_data, headers=fallback_headers)
                        elapsed = time.time() - request_start
                        if fb_response.status_code < 400:
                            inp, out = _extract_tokens_from_response(fb_response.content)
                            if inp or out:
                                await stats.record_tokens("anthropic", inp, out)
                                fmt = stats._fmt_tokens
                                log_ok(rid, f"Anthropic fallback OK {fmt(inp)} in / {fmt(out)} out ({elapsed:.1f}s)")
                            else:
                                log_ok(rid, f"Anthropic fallback OK ({elapsed:.1f}s)")
                        else:
                            log_err(rid, f"Anthropic fallback also failed: {fb_response.status_code}")
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

        log_err(rid, f"Max retries exhausted ({max_attempts} attempts)")
        await stats.record(stats_tier, time.time() - request_start, is_error=True)
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
    target_headers = _build_anthropic_headers(original_headers)

    log_route(rid, f"count_tokens {original_model} → Anthropic")

    client = request.app.state.http_client
    count_start = time.time()
    try:
        response = await client.post(target_url, json=data, headers=target_headers)
        elapsed = time.time() - count_start
        if response.status_code >= 400:
            log_err(rid, f"count_tokens HTTP {response.status_code}: {response.text[:300]}")
        else:
            log_ok(rid, f"count_tokens OK ({elapsed:.1f}s)")
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
        "models": {
            "opus": PROVIDER_OPUS_MODEL if OPUS_BASE_URL else None,
            "sonnet": PROVIDER_SONNET_MODEL if SONNET_BASE_URL else None,
            "haiku": PROVIDER_HAIKU_MODEL if HAIKU_BASE_URL else None,
        },
        "routing": {
            "opus": f"Provider ({PROVIDER_OPUS_MODEL})" if OPUS_BASE_URL else "Anthropic (OAuth)",
            "sonnet": f"Provider ({PROVIDER_SONNET_MODEL})" if SONNET_BASE_URL else "Anthropic (OAuth)",
            "haiku": f"Provider ({PROVIDER_HAIKU_MODEL})" if HAIKU_BASE_URL else "Anthropic (OAuth)",
        },
        "circuit_breaker": circuit_breaker.status(),
        "stats": stats.summary(),
        "fallbacks": [
            "web_search → Anthropic",
            "web_fetch → Anthropic",
            "vision/image → Anthropic",
            "document/pdf → Anthropic",
            "forced_tool_choice → Provider (allowed)" if ALLOW_FORCED_TOOL_CHOICE else "forced_tool_choice → Anthropic",
        ],
        "sanitization": [
            "Anthropic blocks stripped from history (thinking, redacted_thinking, server_tool_use, web_search_tool_result, web_fetch_tool_result)",
            "citations stripped from text blocks in history",
            "cache_control passthrough to provider" if PROVIDER_PASS_CACHE_CONTROL else "cache_control stripped everywhere",
            "Top-level params stripped: metadata, prompt_caching, service_tier, context_management, output_config, inference_geo, container, citations, betas, effort, speed, mcp_servers",
            "Thinking normalized: adaptive→enabled, budget_tokens/effort stripped",
            "Server tools stripped: web_search_*, web_fetch_*, tool_search_tool_*",
            "Tool fields stripped: defer_loading, allowed_callers, input_examples",
        ],
    }


# ---------------------------------------------------------------------------
# Token stats endpoint
# ---------------------------------------------------------------------------
@app.get("/stats/tokens")
async def token_stats():
    s = stats.summary()
    tiers = {}
    total_cost = 0.0
    for tier, data in s["per_tier"].items():
        inp = data["input_tokens"]
        out = data["output_tokens"]
        if not inp and not out:
            continue
        # Calculate real cost based on model pricing
        model_price = _model_pricing_for_tier(tier)
        if model_price:
            cost = (inp * model_price["input"] + out * model_price["output"]) / 1_000_000
        else:
            ap = ANTHROPIC_PRICING.get(tier)
            cost = (inp * ap["input"] + out * ap["output"]) / 1_000_000 if ap else 0.0
        total_cost += cost
        tiers[tier] = {
            "input": inp,
            "output": out,
            "total": data["total_tokens"],
            "cost": f"${cost:.4f}",
            "model": _zai_model_for_tier(tier) if model_price else tier,
        }
    # Show active model pricing
    active_pricing = {}
    for tier in ("sonnet", "haiku"):
        model = _zai_model_for_tier(tier)
        mp = _model_pricing_for_tier(tier)
        if mp:
            active_pricing[model] = f"${mp['input']}/MTok in, ${mp['output']}/MTok out"
    return {
        "total": s["total_tokens"],
        "total_cost": f"${total_cost:.4f}",
        "pricing": active_pricing,
        "per_tier": tiers,
        "uptime": s["uptime"],
    }


# ---------------------------------------------------------------------------
# Catch-all — forward unhandled endpoints to Anthropic
# ---------------------------------------------------------------------------
@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def catch_all(request: Request, path: str):
    """Forward any unhandled endpoint to Anthropic transparently."""
    rid = short_id()
    method = request.method
    target_url = f"{ANTHROPIC_BASE_URL}/{path}"
    original_headers = dict(request.headers)
    target_headers = _build_anthropic_headers(original_headers)
    wants_stream = original_headers.get("accept", "") == "text/event-stream"

    log_route(rid, f"catch-all {method} /{path} → Anthropic{' (stream)' if wants_stream else ''}")

    client = request.app.state.http_client
    catch_start = time.time()
    try:
        body = await request.body()
        if wants_stream:
            req = client.build_request(method, target_url, content=body, headers=target_headers)
            response = await client.send(req, stream=True)
            if response.status_code >= 400:
                error_body = await response.aread()
                await response.aclose()
                log_err(rid, f"catch-all stream error {response.status_code}: {error_body.decode(errors='replace')[:300]}")
                return Response(content=error_body, status_code=response.status_code, headers=strip_encoding_headers(response.headers))
            return StreamingResponse(
                safe_stream_wrapper(response.aiter_bytes(), rid, path, stats_tier="anthropic", start_time=catch_start),
                media_type="text/event-stream",
                background=BackgroundTask(response.aclose),
            )
        else:
            response = await client.request(method, target_url, content=body, headers=target_headers)
            elapsed = time.time() - catch_start
            if response.status_code < 400:
                log_ok(rid, f"catch-all OK ({response.status_code}, {elapsed:.1f}s)")
            else:
                log_err(rid, f"catch-all HTTP {response.status_code}: {response.text[:300]}")
            return Response(
                content=response.content,
                status_code=response.status_code,
                headers=strip_encoding_headers(response.headers),
            )
    except Exception as e:
        log_err(rid, f"catch-all error: {type(e).__name__}: {e}")
        return JSONResponse(status_code=502, content={"error": f"Proxy error: {e}"})


# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    import uvicorn

    validate_config()
    host = os.getenv("HOST", "127.0.0.1")

    print("=" * 60)
    print("  Claude Code Proxy — Multi-Provider Router v5")
    print("=" * 60)
    print()
    print("Routing (by model name substring):")
    print(f"  *opus*   → {'Z.AI (' + PROVIDER_OPUS_MODEL + ')' if OPUS_BASE_URL else 'Anthropic (OAuth)'}")
    print(f"  *sonnet* → {'Z.AI (' + PROVIDER_SONNET_MODEL + ')' if SONNET_BASE_URL else 'Anthropic (OAuth)'}")
    print(f"  *haiku*  → {'Z.AI (' + PROVIDER_HAIKU_MODEL + ')' if HAIKU_BASE_URL else 'Anthropic (OAuth)'}")
    print()
    print("Anthropic fallbacks:")
    print("  web_search       → Anthropic")
    print("  web_fetch        → Anthropic")
    print("  vision/image     → Anthropic")
    print("  document/pdf     → Anthropic")
    tc_status = "Provider (allowed)" if ALLOW_FORCED_TOOL_CHOICE else "Anthropic"
    print(f"  tool_choice≠auto → {tc_status}")
    cc_status = "Provider (passthrough)" if PROVIDER_PASS_CACHE_CONTROL else "stripped"
    print(f"  cache_control    → {cc_status}")
    print()
    print(f"Listen: {host}:{PORT} | Log: {LOG_LEVEL}")
    print("=" * 60)

    uvicorn.run(app, host=host, port=PORT, log_level="info", access_log=False)
