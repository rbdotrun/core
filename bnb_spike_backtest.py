#!/usr/bin/env python3
"""
BNB/USDT 5m Weekly Drawdown Backtest (Compounding)

1. Loads 2 years of 5m candles (from Binance data archive CSVs)
2. Detects drawdowns: price drops >= 10% from its 5-day rolling high
3. Backtests a compounding buy-the-dip strategy:
   - Trigger: close is >= 10% below the 5-day high
   - Deploy 100% of capital at trigger candle close
   - Take profit at +10%, stop loss at -7%
   - Starting capital: $100
"""

import csv
import os
import sys
from collections import deque
from datetime import datetime, timezone


PAIRS = {
    "BNB":  "/tmp/bnb_5m",
    "BTC":  "/tmp/btc_5m",
    "ETH":  "/tmp/eth_5m",
    "SOL":  "/tmp/sol_5m",
    "XRP":  "/tmp/xrp_5m",
}

PAIR = sys.argv[1].upper() if len(sys.argv) > 1 else "BNB"
DATA_DIR = PAIRS.get(PAIR, f"/tmp/{PAIR.lower()}_5m")
CANDLE_MINUTES = 5
WINDOW_DAYS = 5
WINDOW_CANDLES = WINDOW_DAYS * 24 * 60 // CANDLE_MINUTES  # 1440

# Binance data archive CSV columns (no header):
# open_time, open, high, low, close, volume, close_time,
# quote_volume, num_trades, taker_buy_vol, taker_buy_quote_vol, ignore

TRIGGER_PCT = 10.0
POSITION_PCT = 100.0     # deploy 100% of capital per trade (compound)
INITIAL_CAPITAL = 100.0
TAKE_PROFIT_PCT = 10.0   # sell when position is +10%
STOP_LOSS_PCT = 7.0      # sell when position is -7%
MAX_HOLD_DAYS = 60       # max hold before forced exit


def load_candles_from_csv(data_dir):
    """Load and merge all monthly CSV files into a sorted candle list."""
    all_candles = []
    csv_files = sorted(f for f in os.listdir(data_dir) if f.endswith(".csv"))

    if not csv_files:
        print(f"No CSV files found in {data_dir}")
        sys.exit(1)

    for fname in csv_files:
        path = os.path.join(data_dir, fname)
        with open(path, "r") as f:
            reader = csv.reader(f)
            for row in reader:
                if len(row) < 6:
                    continue
                raw_open = int(row[0])
                raw_close = int(row[6])
                open_ts = raw_open // 1000 if raw_open > 9_999_999_999_999 else raw_open
                close_ts = raw_close // 1000 if raw_close > 9_999_999_999_999 else raw_close
                all_candles.append({
                    "ts": open_ts,
                    "open": float(row[1]),
                    "high": float(row[2]),
                    "low": float(row[3]),
                    "close": float(row[4]),
                    "volume": float(row[5]),
                    "close_ts": close_ts,
                })
        print(f"  Loaded {fname} ({len(all_candles)} total)")

    all_candles.sort(key=lambda c: c["ts"])
    return all_candles


def ts_str(ms):
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).strftime("%Y-%m-%d %H:%M")


def compute_rolling_high(candles, window):
    """Compute rolling max high over trailing `window` candles using a deque."""
    n = len(candles)
    rolling_high = [0.0] * n
    dq = deque()  # stores indices, front = index of current max

    for i in range(n):
        # Remove elements outside window
        while dq and dq[0] < i - window + 1:
            dq.popleft()
        # Remove smaller elements from back
        while dq and candles[dq[-1]]["high"] <= candles[i]["high"]:
            dq.pop()
        dq.append(i)
        rolling_high[i] = candles[dq[0]]["high"]

    return rolling_high


def detect_drawdowns(candles, rolling_high, min_drop_pct=TRIGGER_PCT):
    """
    Detect when close drops >= min_drop_pct below the 7-day rolling high.
    Exit: +TAKE_PROFIT_PCT% from buy (TP) or -STOP_LOSS_PCT% from buy (SL).
    """
    events = []
    cooldown_until = -1
    n = len(candles)
    max_hold_candles = MAX_HOLD_DAYS * 24 * 60 // CANDLE_MINUTES

    for i in range(WINDOW_CANDLES, n):
        if i <= cooldown_until:
            continue

        peak = rolling_high[i - 1]  # 7-day high as of previous candle
        close = candles[i]["close"]
        drop_pct = ((peak - close) / peak) * 100

        if drop_pct < min_drop_pct:
            continue

        # Found a trigger
        buy_price = close
        tp_price = buy_price * (1 + TAKE_PROFIT_PCT / 100)
        sl_price = buy_price * (1 - STOP_LOSS_PCT / 100)

        bottom_price = close
        bottom_idx = i
        exit_idx = None
        exit_reason = None

        scan_end = min(i + max_hold_candles + 1, n)
        for k in range(i + 1, scan_end):
            if candles[k]["low"] < bottom_price:
                bottom_price = candles[k]["low"]
                bottom_idx = k
            # Check stop loss first (worst case within candle)
            if candles[k]["low"] <= sl_price:
                exit_idx = k
                exit_reason = "SL"
                break
            # Check take profit
            if candles[k]["high"] >= tp_price:
                exit_idx = k
                exit_reason = "TP"
                break

        if exit_idx is None:
            exit_idx = min(i + max_hold_candles, n - 1)
            exit_reason = "TIMEOUT"

        # Determine sell price based on exit reason
        if exit_reason == "TP":
            sell_price = tp_price
        elif exit_reason == "SL":
            sell_price = sl_price
        else:
            sell_price = candles[exit_idx]["close"]

        total_drop = ((peak - bottom_price) / peak) * 100

        events.append({
            "idx": i,
            "time": ts_str(candles[i]["ts"]),
            "peak_price": peak,
            "buy_price": buy_price,
            "bottom_price": bottom_price,
            "bottom_idx": bottom_idx,
            "bottom_time": ts_str(candles[bottom_idx]["ts"]),
            "exit_idx": exit_idx,
            "exit_time": ts_str(candles[exit_idx]["ts"]),
            "sell_price": sell_price,
            "exit_reason": exit_reason,
            "trigger_drop_pct": drop_pct,
            "max_drop_pct": total_drop,
            "hold_days": (exit_idx - i) * CANDLE_MINUTES / 1440,
        })

        cooldown_until = exit_idx

    return events


def backtest(events):
    """
    Compounding backtest: deploy POSITION_PCT% of capital per trade.
    """
    capital = INITIAL_CAPITAL
    trades = []

    for e in events:
        invest = capital * (POSITION_PCT / 100)
        if invest < 1.0:
            break

        buy_price = e["buy_price"]
        sell_price = e["sell_price"]
        qty = invest / buy_price

        capital -= invest
        revenue = qty * sell_price
        profit = revenue - invest
        pnl_pct = (profit / invest) * 100
        capital += revenue

        trades.append({
            "time": e["time"],
            "peak": e["peak_price"],
            "buy_price": buy_price,
            "sell_price": sell_price,
            "trigger_drop": e["trigger_drop_pct"],
            "max_drop": e["max_drop_pct"],
            "qty": qty,
            "invested": invest,
            "revenue": revenue,
            "profit": profit,
            "pnl_pct": pnl_pct,
            "capital_after": capital,
            "exit_reason": e["exit_reason"],
            "hold_days": e["hold_days"],
        })

    return trades, capital


def main():
    print("=" * 80)
    print(f"  {PAIR}/USDT {CANDLE_MINUTES}m WEEKLY DRAWDOWN BACKTEST")
    print(f"  Trigger: -{TRIGGER_PCT}% from {WINDOW_DAYS}-day high | {POSITION_PCT:.0f}% capital")
    print("=" * 80)

    print(f"\nLoading candle data from {DATA_DIR}...")
    candles = load_candles_from_csv(DATA_DIR)
    print(f"\n  Total candles: {len(candles)}")
    print(f"  Period: {ts_str(candles[0]['ts'])} -> {ts_str(candles[-1]['close_ts'])}")

    price_start = candles[0]["close"]
    price_end = candles[-1]["close"]
    bnh = ((price_end - price_start) / price_start) * 100
    print(f"  Price: ${price_start:.2f} -> ${price_end:.2f} ({bnh:+.1f}% buy & hold)")

    # ── Compute rolling high ──
    print(f"\n  Computing {WINDOW_DAYS}-day rolling high...")
    rolling_high = compute_rolling_high(candles, WINDOW_CANDLES)

    # ── Phase 1: Detect Drawdowns ──
    print("\n" + "=" * 80)
    print(f"  PHASE 1: DRAWDOWN DETECTION (>= {TRIGGER_PCT}% below {WINDOW_DAYS}-day high)")
    print("=" * 80)

    events = detect_drawdowns(candles, rolling_high)
    by_drop = sorted(events, key=lambda e: e["max_drop_pct"], reverse=True)

    print(f"\n  Found {len(by_drop)} drawdown events\n")

    hdr = (f"{'#':>3} | {'Trigger Date':>16} | {'7d High':>9} | {'Buy @':>9} | "
           f"{'Bottom':>9} | {'MaxDrop':>7} | {'Hold':>7} | {'Exit':>7}")
    print(hdr)
    print("-" * len(hdr))

    for i, e in enumerate(by_drop, 1):
        print(f"{i:>3} | {e['time']:>16} | "
              f"${e['peak_price']:>8.2f} | ${e['buy_price']:>8.2f} | "
              f"${e['bottom_price']:>8.2f} | {e['max_drop_pct']:>5.1f}%  | "
              f"{e['hold_days']:>5.1f}d | {e['exit_reason']:>7}")

    # ── Phase 2: Backtest ──
    print("\n" + "=" * 80)
    print("  PHASE 2: BUY-THE-DIP BACKTEST")
    print("=" * 80)
    print(f"""
  Strategy Rules:
    Capital:     ${INITIAL_CAPITAL:.0f}
    Trigger:     close >= {TRIGGER_PCT}% below {WINDOW_DAYS}-day rolling high
    Position:    {POSITION_PCT:.0f}% of capital (compounding)
    Take profit: +{TAKE_PROFIT_PCT}% from buy price
    Stop loss:   -{STOP_LOSS_PCT}% from buy price
    Max hold:    {MAX_HOLD_DAYS} days (forced exit at market price)
    """)

    by_time = sorted(events, key=lambda e: e["idx"])
    trades, final_capital = backtest(by_time)

    hdr2 = (f"{'#':>3} | {'Date':>16} | {'Buy @':>9} | {'Sell @':>9} | "
            f"{'Invested':>10} | {'Exit':>4} | {'Hold':>6} | "
            f"{'Profit':>10} | {'P&L':>7} | {'Capital':>10}")
    print(hdr2)
    print("-" * len(hdr2))

    for i, t in enumerate(trades, 1):
        print(f"{i:>3} | {t['time']:>16} | ${t['buy_price']:>8.2f} | "
              f"${t['sell_price']:>8.2f} | ${t['invested']:>9.2f} | "
              f"{t['exit_reason']:>4} | {t['hold_days']:>4.1f}d | "
              f"${t['profit']:>+9.2f} | {t['pnl_pct']:>+5.1f}%  | "
              f"${t['capital_after']:>9.2f}")

    # ── Summary ──
    total_profit = final_capital - INITIAL_CAPITAL
    total_return = (total_profit / INITIAL_CAPITAL) * 100

    print("\n" + "=" * 80)
    print("  SUMMARY")
    print("=" * 80)
    print(f"  Period:              {ts_str(candles[0]['ts'])} -> {ts_str(candles[-1]['close_ts'])}")
    print(f"  Price:           ${price_start:.2f} -> ${price_end:.2f} ({bnh:+.1f}% buy & hold)")
    print(f"  Trigger threshold:   -{TRIGGER_PCT}% from {WINDOW_DAYS}-day high")
    print(f"  Total events found:  {len(events)}")
    print(f"  Trades executed:     {len(trades)}")
    print(f"  Initial capital:     ${INITIAL_CAPITAL:.2f}")
    print(f"  Final capital:       ${final_capital:.2f}")
    print(f"  Total profit:        ${total_profit:+.2f}")
    print(f"  Strategy return:     {total_return:+.1f}%")

    if trades:
        winners = [t for t in trades if t["profit"] > 0]
        losers = [t for t in trades if t["profit"] <= 0]
        print(f"\n  Winning trades:      {len(winners)}/{len(trades)} "
              f"({len(winners)/len(trades)*100:.0f}%)")
        print(f"  Losing trades:       {len(losers)}/{len(trades)} "
              f"({len(losers)/len(trades)*100:.0f}%)")
        if winners:
            print(f"  Avg win:             "
                  f"${sum(t['profit'] for t in winners)/len(winners):+.2f}")
        if losers:
            print(f"  Avg loss:            "
                  f"${sum(t['profit'] for t in losers)/len(losers):+.2f}")
        print(f"  Best trade:          ${max(t['profit'] for t in trades):+.2f}")
        print(f"  Worst trade:         ${min(t['profit'] for t in trades):+.2f}")
        total_invested = sum(t["invested"] for t in trades)
        total_rev = sum(t["revenue"] for t in trades)
        print(f"  Total $ deployed:    ${total_invested:.2f}")
        print(f"  Total $ returned:    ${total_rev:.2f}")
        avg_hold = sum(t["hold_days"] for t in trades) / len(trades)
        print(f"  Avg hold time:       {avg_hold:.1f} days")

        tp_count = sum(1 for t in trades if t["exit_reason"] == "TP")
        sl_count = sum(1 for t in trades if t["exit_reason"] == "SL")
        to_count = sum(1 for t in trades if t["exit_reason"] == "TIMEOUT")
        print(f"\n  Exit breakdown:")
        print(f"    Take profit (+{TAKE_PROFIT_PCT}%): {tp_count}")
        print(f"    Stop loss (-{STOP_LOSS_PCT}%):   {sl_count}")
        if to_count:
            print(f"    Timeout ({MAX_HOLD_DAYS}d):       {to_count}")

        # Top trades
        by_profit = sorted(trades, key=lambda t: t["profit"], reverse=True)
        print(f"\n  TOP 5 MOST PROFITABLE TRADES:")
        for i, t in enumerate(by_profit[:5], 1):
            print(f"    {i}. {t['time']} | ${t['invested']:.2f} in @ ${t['buy_price']:.2f} "
                  f"| sold ${t['sell_price']:.2f} [{t['exit_reason']}] "
                  f"| held {t['hold_days']:.1f}d "
                  f"| profit ${t['profit']:+.2f} ({t['pnl_pct']:+.1f}%)")

        # Worst trades
        by_loss = sorted(trades, key=lambda t: t["profit"])
        worst = [t for t in by_loss[:5] if t["profit"] < 0]
        if worst:
            print(f"\n  WORST {len(worst)} TRADES (losses):")
            for i, t in enumerate(worst, 1):
                print(f"    {i}. {t['time']} | ${t['invested']:.2f} in @ ${t['buy_price']:.2f} "
                      f"| sold ${t['sell_price']:.2f} [{t['exit_reason']}] "
                      f"| held {t['hold_days']:.1f}d "
                      f"| P&L ${t['profit']:+.2f} ({t['pnl_pct']:+.1f}%)")

        # Capital curve
        capitals = [INITIAL_CAPITAL] + [t["capital_after"] for t in trades]
        peak = max(capitals)
        trough = min(capitals)
        max_dd = 0
        running_peak = capitals[0]
        for c in capitals:
            if c > running_peak:
                running_peak = c
            dd = ((running_peak - c) / running_peak) * 100
            if dd > max_dd:
                max_dd = dd
        print(f"\n  Peak capital:        ${peak:.2f}")
        print(f"  Trough capital:      ${trough:.2f}")
        print(f"  Max drawdown:        {max_dd:.1f}%")

    print("\n" + "=" * 80)


if __name__ == "__main__":
    main()
