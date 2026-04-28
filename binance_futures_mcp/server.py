"""
Binance USDⓈ-M Futures Public Data MCP Server.

Exposes Binance Futures public market data endpoints (no API key required) for
LLM-driven analysis: open interest, funding rate, long/short ratios, taker
volume, klines, ticker. Uses fapi.binance.com.

Run via: python3 server.py
"""

from __future__ import annotations

import os
from typing import Any, Optional

import httpx
from mcp.server.fastmcp import FastMCP


FAPI = "https://fapi.binance.com"
DEFAULT_TIMEOUT = 15.0
USER_AGENT = "binance-futures-mcp/0.1 (+local)"


mcp = FastMCP("binance_futures")


async def _get(path: str, params: dict[str, Any] | None = None) -> Any:
    """GET helper for Binance fapi public endpoints."""
    clean = {k: v for k, v in (params or {}).items() if v is not None}
    headers = {"User-Agent": USER_AGENT, "Accept": "application/json"}
    url = f"{FAPI}{path}"
    async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT, headers=headers) as client:
        r = await client.get(url, params=clean)
        if r.status_code != 200:
            return {
                "ok": False,
                "status": r.status_code,
                "url": str(r.url),
                "error": r.text[:500],
            }
        try:
            return {"ok": True, "data": r.json()}
        except Exception as e:
            return {"ok": False, "error": f"parse_error: {e}", "raw": r.text[:500]}


# ---------------------------------------------------------------------------
# Market Data: Price / Klines
# ---------------------------------------------------------------------------


@mcp.tool()
async def get_price(symbol: str = "BTCUSDT") -> Any:
    """Latest mark/last price for a futures symbol.

    Args:
        symbol: e.g. BTCUSDT, ETHUSDT, DOGEUSDT.
    """
    return await _get("/fapi/v1/ticker/price", {"symbol": symbol.upper()})


@mcp.tool()
async def get_24hr_ticker(symbol: str = "BTCUSDT") -> Any:
    """24-hour rolling price change statistics for a futures symbol."""
    return await _get("/fapi/v1/ticker/24hr", {"symbol": symbol.upper()})


@mcp.tool()
async def get_book_ticker(symbol: str = "BTCUSDT") -> Any:
    """Best bid/ask price and quantity for a futures symbol."""
    return await _get("/fapi/v1/ticker/bookTicker", {"symbol": symbol.upper()})


@mcp.tool()
async def get_klines(
    symbol: str = "BTCUSDT",
    interval: str = "1h",
    limit: int = 50,
    startTime: Optional[int] = None,
    endTime: Optional[int] = None,
) -> Any:
    """Futures kline/candlestick data.

    Args:
        symbol: e.g. BTCUSDT.
        interval: 1m, 3m, 5m, 15m, 30m, 1h, 2h, 4h, 6h, 8h, 12h, 1d, 3d, 1w, 1M.
        limit: 1-1500 (default 50).
        startTime: Optional ms timestamp.
        endTime: Optional ms timestamp.
    """
    return await _get(
        "/fapi/v1/klines",
        {
            "symbol": symbol.upper(),
            "interval": interval,
            "limit": min(max(limit, 1), 1500),
            "startTime": startTime,
            "endTime": endTime,
        },
    )


@mcp.tool()
async def get_order_book(symbol: str = "BTCUSDT", limit: int = 50) -> Any:
    """Order book depth. limit: 5,10,20,50,100,500,1000."""
    return await _get(
        "/fapi/v1/depth",
        {"symbol": symbol.upper(), "limit": limit},
    )


# ---------------------------------------------------------------------------
# Open Interest
# ---------------------------------------------------------------------------


@mcp.tool()
async def get_open_interest(symbol: str = "BTCUSDT") -> Any:
    """Current open interest of a futures symbol (in base asset units)."""
    return await _get("/fapi/v1/openInterest", {"symbol": symbol.upper()})


@mcp.tool()
async def get_open_interest_hist(
    symbol: str = "BTCUSDT",
    period: str = "1h",
    limit: int = 30,
    startTime: Optional[int] = None,
    endTime: Optional[int] = None,
) -> Any:
    """Open interest history (per period).

    Args:
        symbol: e.g. BTCUSDT.
        period: 5m, 15m, 30m, 1h, 2h, 4h, 6h, 12h, 1d.
        limit: 1-500 (default 30).
        startTime/endTime: optional ms timestamps.

    Returns rows with: sumOpenInterest (BTC), sumOpenInterestValue (USDT), timestamp.
    """
    return await _get(
        "/futures/data/openInterestHist",
        {
            "symbol": symbol.upper(),
            "period": period,
            "limit": min(max(limit, 1), 500),
            "startTime": startTime,
            "endTime": endTime,
        },
    )


# ---------------------------------------------------------------------------
# Funding Rate
# ---------------------------------------------------------------------------


@mcp.tool()
async def get_premium_index(symbol: str = "BTCUSDT") -> Any:
    """Current mark price, index price and last funding rate for a symbol.

    Useful real-time check of funding-rate sentiment.
    """
    return await _get("/fapi/v1/premiumIndex", {"symbol": symbol.upper()})


@mcp.tool()
async def get_funding_rate_history(
    symbol: str = "BTCUSDT",
    limit: int = 30,
    startTime: Optional[int] = None,
    endTime: Optional[int] = None,
) -> Any:
    """Historical funding-rate records for a symbol (one record per 8h funding).

    limit: 1-1000 (default 30).
    """
    return await _get(
        "/fapi/v1/fundingRate",
        {
            "symbol": symbol.upper(),
            "limit": min(max(limit, 1), 1000),
            "startTime": startTime,
            "endTime": endTime,
        },
    )


# ---------------------------------------------------------------------------
# Long/Short Ratios (the killer feature for sentiment analysis)
# ---------------------------------------------------------------------------


@mcp.tool()
async def get_top_long_short_account_ratio(
    symbol: str = "BTCUSDT",
    period: str = "5m",
    limit: int = 30,
    startTime: Optional[int] = None,
    endTime: Optional[int] = None,
) -> Any:
    """Top trader long/short ratio by ACCOUNTS (top 20% accounts by balance).

    Reveals what 'elite retail / mid-tier traders' are doing.
    period: 5m, 15m, 30m, 1h, 2h, 4h, 6h, 12h, 1d.
    """
    return await _get(
        "/futures/data/topLongShortAccountRatio",
        {
            "symbol": symbol.upper(),
            "period": period,
            "limit": min(max(limit, 1), 500),
            "startTime": startTime,
            "endTime": endTime,
        },
    )


@mcp.tool()
async def get_top_long_short_position_ratio(
    symbol: str = "BTCUSDT",
    period: str = "5m",
    limit: int = 30,
    startTime: Optional[int] = None,
    endTime: Optional[int] = None,
) -> Any:
    """Top trader long/short ratio by POSITIONS (institutional money).

    Reveals what big-money positions are: bullish or bearish.
    period: 5m, 15m, 30m, 1h, 2h, 4h, 6h, 12h, 1d.
    """
    return await _get(
        "/futures/data/topLongShortPositionRatio",
        {
            "symbol": symbol.upper(),
            "period": period,
            "limit": min(max(limit, 1), 500),
            "startTime": startTime,
            "endTime": endTime,
        },
    )


@mcp.tool()
async def get_global_long_short_account_ratio(
    symbol: str = "BTCUSDT",
    period: str = "5m",
    limit: int = 30,
    startTime: Optional[int] = None,
    endTime: Optional[int] = None,
) -> Any:
    """Global long/short ratio across ALL accounts (broad retail sentiment).

    Useful contrarian indicator: extreme long bias often precedes drops.
    """
    return await _get(
        "/futures/data/globalLongShortAccountRatio",
        {
            "symbol": symbol.upper(),
            "period": period,
            "limit": min(max(limit, 1), 500),
            "startTime": startTime,
            "endTime": endTime,
        },
    )


@mcp.tool()
async def get_taker_long_short_ratio(
    symbol: str = "BTCUSDT",
    period: str = "5m",
    limit: int = 30,
    startTime: Optional[int] = None,
    endTime: Optional[int] = None,
) -> Any:
    """Taker buy/sell volume ratio per period (aggressive money direction).

    >1 means more aggressive buying; <1 means more aggressive selling.
    Best short-term momentum gauge.
    """
    return await _get(
        "/futures/data/takerlongshortRatio",
        {
            "symbol": symbol.upper(),
            "period": period,
            "limit": min(max(limit, 1), 500),
            "startTime": startTime,
            "endTime": endTime,
        },
    )


# ---------------------------------------------------------------------------
# Composite snapshot (optional convenience)
# ---------------------------------------------------------------------------


@mcp.tool()
async def get_market_snapshot(symbol: str = "BTCUSDT") -> Any:
    """One-shot snapshot combining price, OI, funding rate, and short-term ratios.

    Returns a dict bundling: ticker24h, openInterest, premiumIndex,
    topAccountRatio (5m x3), topPositionRatio (5m x3), takerRatio (5m x3).
    """
    sym = symbol.upper()
    headers = {"User-Agent": USER_AGENT, "Accept": "application/json"}
    out: dict[str, Any] = {"symbol": sym}
    async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT, headers=headers) as client:

        async def _safe(name: str, path: str, params: dict[str, Any]) -> None:
            clean = {k: v for k, v in params.items() if v is not None}
            try:
                r = await client.get(f"{FAPI}{path}", params=clean)
                out[name] = r.json() if r.status_code == 200 else {"error": r.text[:200]}
            except Exception as e:
                out[name] = {"error": f"{type(e).__name__}: {e}"}

        await _safe("ticker24h", "/fapi/v1/ticker/24hr", {"symbol": sym})
        await _safe("openInterest", "/fapi/v1/openInterest", {"symbol": sym})
        await _safe("premiumIndex", "/fapi/v1/premiumIndex", {"symbol": sym})
        await _safe(
            "openInterestHist_1h",
            "/futures/data/openInterestHist",
            {"symbol": sym, "period": "1h", "limit": 6},
        )
        await _safe(
            "topAccountRatio_5m",
            "/futures/data/topLongShortAccountRatio",
            {"symbol": sym, "period": "5m", "limit": 3},
        )
        await _safe(
            "topPositionRatio_5m",
            "/futures/data/topLongShortPositionRatio",
            {"symbol": sym, "period": "5m", "limit": 3},
        )
        await _safe(
            "takerRatio_5m",
            "/futures/data/takerlongshortRatio",
            {"symbol": sym, "period": "5m", "limit": 3},
        )
    return {"ok": True, "data": out}


if __name__ == "__main__":
    mcp.run(transport=os.environ.get("MCP_TRANSPORT", "stdio"))
