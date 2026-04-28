# Binance Futures Public Data MCP

Local MCP server exposing Binance USDⓈ-M Futures **public** market data
(no API key required) — focused on the data needed for derivatives sentiment
and flow analysis.

## Why this exists

Existing public Binance MCP packages on npm are either spot-only or require
trading API keys. We only need read-only futures data: Open Interest history,
funding rate, top long/short ratios, taker buy/sell, klines.

## Tools

Market data:

- `get_price` — latest price.
- `get_24hr_ticker` — 24h stats.
- `get_book_ticker` — best bid/ask.
- `get_klines` — futures candlesticks (1m–1M).
- `get_order_book` — depth.

Derivatives:

- `get_open_interest` — current OI.
- `get_open_interest_hist` — OI history (5m … 1d).
- `get_premium_index` — mark/index price + current funding rate.
- `get_funding_rate_history` — funding rate history.

Sentiment / flow:

- `get_top_long_short_account_ratio` — top 20% accounts long/short.
- `get_top_long_short_position_ratio` — top accounts by position size.
- `get_global_long_short_account_ratio` — all accounts long/short.
- `get_taker_long_short_ratio` — aggressive buy vs sell volume.

Convenience:

- `get_market_snapshot` — one-shot bundle of the most-used signals.

## Install

```bash
pip3 install "mcp[cli]" httpx
```

## Cursor MCP config

Add to `~/.cursor/mcp.json`:

```jsonc
{
  "mcpServers": {
    "binance_futures": {
      "command": "python3",
      "args": [
        "/Users/chandashi/mt5_bot/gold_bot/binance_futures_mcp/server.py"
      ],
      "transport": "stdio"
    }
  }
}
```

Restart Cursor for the server to be picked up.

## Manual smoke test

```bash
python3 -c "
import asyncio, sys
sys.path.insert(0, '/Users/chandashi/mt5_bot/gold_bot/binance_futures_mcp')
from server import get_market_snapshot
print(asyncio.run(get_market_snapshot('BTCUSDT')))
"
```
