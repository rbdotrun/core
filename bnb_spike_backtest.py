#!/usr/bin/env python3
"""
BNB/USDT 15m Spike Analysis & DCA-on-Dip Backtest

1. Loads 1 year of 15m candles (from Binance data archive CSVs)
2. Detects "hiccups": sudden drops >= 2% within 30 minutes
3. Reports all hiccups sorted by magnitude
4. Backtests a DCA strategy:
   - Trigger: -2% within 30 min
   - Buy $10 at -2%, then $10 more at each -0.5% step (-2.5%, -3%, -3.5%...)
   - STRICT thresholds: only fills if price actually reaches the level
   - Sell when price recovers to pre-drop level
   - Starting capital: $100
"""

import csv
import os
import sys
from datetime import datetime, timezone


DATA_DIR = "/tmp/bnb_data"

# Binance data archive CSV columns (no header):
# open_time, open, high, low, close, volume, close_time,
# quote_volume, num_trades, taker_buy_vol, taker_buy_quote_vol, ignore
# NOTE: timestamps are in microseconds (divide by 1000 for ms, by 1e6 for seconds)


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
                # Timestamps in the archive are microseconds
                open_ts = int(row[0]) // 1000  # -> milliseconds
                close_ts = int(row[6]) // 1000
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
    """Convert millisecond timestamp to readable string."""
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).strftime("%Y-%m-%d %H:%M")


def detect_hiccups(candles):
    """
    Detect sudden drops >= 2% within a 30-min rolling window.

    30 min = 2 candles of 15m. For each position, we compare the close of
    candle[i] against the lowest low in candles[i+1] and [i+2].

    When triggered, we track the full downspike:
    - The reference price (close before the drop started)
    - The absolute bottom reached
    - Recovery: when price closes back at or above ref price

    Merged/cooled-down so overlapping spikes count as one event.
    """
    hiccups = []
    cooldown_until = -1
    n = len(candles)

    for i in range(n - 2):
        if i <= cooldown_until:
            continue

        ref_price = candles[i]["close"]

        # Find lowest low in the next 2 candles (30 min window)
        window_low = min(candles[i + 1]["low"], candles[i + 2]["low"])

        trigger_drop = ((ref_price - window_low) / ref_price) * 100
        if trigger_drop < 2.0:
            continue

        # Trigger found! Now track the full spike depth and recovery.
        # Scan forward to find true bottom and recovery point.
        # Max scan: 96 candles = 24 hours (generous for spike events)
        bottom_price = window_low
        bottom_idx = i + 1 if candles[i + 1]["low"] <= candles[i + 2]["low"] else i + 2
        recovery_idx = None

        scan_end = min(i + 97, n)
        for k in range(i + 1, scan_end):
            if candles[k]["low"] < bottom_price:
                bottom_price = candles[k]["low"]
                bottom_idx = k
            # Recovery: close returns to at or above ref price
            if candles[k]["close"] >= ref_price:
                recovery_idx = k
                break

        if recovery_idx is None:
            recovery_idx = min(i + 96, n - 1)

        total_drop = ((ref_price - bottom_price) / ref_price) * 100
        duration_min = (recovery_idx - i) * 15
        recovered = candles[recovery_idx]["close"] >= ref_price

        hiccups.append({
            "idx": i,
            "time": ts_str(candles[i]["close_ts"]),
            "ref_price": ref_price,
            "bottom_price": bottom_price,
            "bottom_idx": bottom_idx,
            "bottom_time": ts_str(candles[bottom_idx]["ts"]),
            "recovery_idx": recovery_idx,
            "recovery_time": ts_str(candles[recovery_idx]["ts"]),
            "recovery_price": candles[recovery_idx]["close"],
            "recovered": recovered,
            "drop_pct": total_drop,
            "duration_min": duration_min,
        })

        # Cooldown: skip past recovery to avoid double-counting
        cooldown_until = recovery_idx

    return hiccups


def backtest(candles, hiccups, initial_capital=100.0, order_size=10.0,
             trigger_pct=2.0, step_pct=0.5):
    """
    Backtest the DCA-on-dip strategy (chronological order).

    For each hiccup:
      - Compute buy levels: -2.0%, -2.5%, -3.0%, -3.5%, ... from ref_price
      - STRICT fill: only if bottom_price actually reached that level
      - Each filled level costs $10 from available capital
      - Sell all when price recovers to ref_price (or at partial recovery)
    """
    capital = initial_capital
    trades = []

    for h in hiccups:
        ref = h["ref_price"]
        bottom = h["bottom_price"]

        buys = []
        level_pct = trigger_pct

        while True:
            buy_price = ref * (1 - level_pct / 100)

            # STRICT: only fill if price actually dipped to this level
            if buy_price < bottom:
                break

            if capital < order_size:
                break

            qty = order_size / buy_price
            buys.append({
                "level": f"-{level_pct:.1f}%",
                "price": buy_price,
                "qty": qty,
                "cost": order_size,
            })
            capital -= order_size
            level_pct += step_pct

        if not buys:
            continue

        # Sell price
        sell_price = ref if h["recovered"] else h["recovery_price"]

        total_qty = sum(b["qty"] for b in buys)
        total_cost = sum(b["cost"] for b in buys)
        avg_buy = total_cost / total_qty
        revenue = total_qty * sell_price
        profit = revenue - total_cost
        pnl_pct = (profit / total_cost) * 100

        capital += revenue

        trades.append({
            "time": h["time"],
            "ref_price": ref,
            "bottom": bottom,
            "drop_pct": h["drop_pct"],
            "num_buys": len(buys),
            "invested": total_cost,
            "avg_buy": avg_buy,
            "sell_price": sell_price,
            "revenue": revenue,
            "profit": profit,
            "pnl_pct": pnl_pct,
            "capital_after": capital,
            "recovered": h["recovered"],
            "buys": buys,
            "duration_min": h["duration_min"],
        })

    return trades, capital


def main():
    print("=" * 80)
    print("  BNB/USDT 15m SPIKE ANALYSIS & DCA-ON-DIP BACKTEST")
    print("=" * 80)

    # ── Load Data ──
    print(f"\nLoading candle data from {DATA_DIR}...")
    candles = load_candles_from_csv(DATA_DIR)
    print(f"\n  Total candles: {len(candles)}")
    print(f"  Period: {ts_str(candles[0]['ts'])} -> {ts_str(candles[-1]['close_ts'])}")

    price_start = candles[0]["close"]
    price_end = candles[-1]["close"]
    bnh = ((price_end - price_start) / price_start) * 100
    print(f"  BNB price: ${price_start:.2f} -> ${price_end:.2f} ({bnh:+.1f}% buy & hold)")

    # ── Phase 1: Detect Hiccups ──
    print("\n" + "=" * 80)
    print("  PHASE 1: HICCUP DETECTION (>= 2% drop within 30 min)")
    print("=" * 80)

    hiccups = detect_hiccups(candles)
    by_drop = sorted(hiccups, key=lambda h: h["drop_pct"], reverse=True)

    print(f"\n  Found {len(by_drop)} hiccup events\n")

    hdr = (f"{'#':>3} | {'Date':>16} | {'Ref $':>9} | {'Bottom $':>9} | "
           f"{'Drop':>7} | {'Duration':>8} | {'Recov':>7}")
    print(hdr)
    print("-" * len(hdr))

    for i, h in enumerate(by_drop, 1):
        rec = "FULL" if h["recovered"] else "PARTIAL"
        print(f"{i:>3} | {h['time']:>16} | "
              f"${h['ref_price']:>8.2f} | ${h['bottom_price']:>8.2f} | "
              f"{h['drop_pct']:>5.1f}%  | {h['duration_min']:>5}min | {rec:>7}")

    # ── Phase 2: Backtest ──
    print("\n" + "=" * 80)
    print("  PHASE 2: DCA-ON-DIP BACKTEST")
    print("=" * 80)
    print("""
  Strategy Rules:
    Capital:     $100
    Trigger:     price drops >= 2% within 30 minutes
    1st buy:     $10 at the -2.0% level
    DCA steps:   $10 more at each -0.5% (-2.5%, -3.0%, -3.5%, ...)
    Threshold:   STRICT (price must actually reach the level to fill)
    Exit:        sell all when price recovers to pre-drop level
    """)

    by_time = sorted(hiccups, key=lambda h: h["idx"])
    trades, final_capital = backtest(candles, by_time)

    hdr2 = (f"{'#':>3} | {'Date':>16} | {'Drop':>6} | {'Buys':>4} | "
            f"{'Invested':>9} | {'Avg Buy':>9} | {'Sell @':>9} | "
            f"{'Profit':>9} | {'P&L':>7} | {'Capital':>9}")
    print(hdr2)
    print("-" * len(hdr2))

    for i, t in enumerate(trades, 1):
        flag = " " if t["recovered"] else "*"
        print(f"{i:>3} | {t['time']:>16} | {t['drop_pct']:>5.1f}% | "
              f"{t['num_buys']:>4} | ${t['invested']:>8.2f} | "
              f"${t['avg_buy']:>8.2f} | ${t['sell_price']:>8.2f} | "
              f"${t['profit']:>+8.2f} | {t['pnl_pct']:>+5.1f}%  | "
              f"${t['capital_after']:>8.2f}{flag}")

    # ── Summary ──
    total_profit = final_capital - 100.0
    total_return = ((final_capital - 100) / 100) * 100

    print("\n" + "=" * 80)
    print("  SUMMARY")
    print("=" * 80)
    print(f"  Period:              {ts_str(candles[0]['ts'])} -> {ts_str(candles[-1]['close_ts'])}")
    print(f"  BNB price:           ${price_start:.2f} -> ${price_end:.2f} ({bnh:+.1f}% buy & hold)")
    print(f"  Total hiccups found: {len(hiccups)}")
    print(f"  Trades executed:     {len(trades)}")
    print(f"  Initial capital:     $100.00")
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

        partial = [t for t in trades if not t["recovered"]]
        if partial:
            print(f"\n  * {len(partial)} trade(s) did not fully recover (marked with *)")
            print(f"    These were sold at partial recovery price")

        # Top trades by profit
        by_profit = sorted(trades, key=lambda t: t["profit"], reverse=True)
        print(f"\n  TOP 5 MOST PROFITABLE TRADES:")
        for i, t in enumerate(by_profit[:5], 1):
            print(f"    {i}. {t['time']} | drop {t['drop_pct']:.1f}% | "
                  f"{t['num_buys']} buys | profit ${t['profit']:+.2f} "
                  f"({t['pnl_pct']:+.1f}%)")
            for b in t["buys"]:
                print(f"       {b['level']:>7} @ ${b['price']:.2f} "
                      f"-> {b['qty']:.6f} BNB (${b['cost']:.0f})")

        # Worst trades
        by_loss = sorted(trades, key=lambda t: t["profit"])
        worst = [t for t in by_loss[:5] if t["profit"] < 0]
        if worst:
            print(f"\n  WORST {len(worst)} TRADES (losses):")
            for i, t in enumerate(worst, 1):
                print(f"    {i}. {t['time']} | drop {t['drop_pct']:.1f}% | "
                      f"{t['num_buys']} buys | P&L ${t['profit']:+.2f} "
                      f"({t['pnl_pct']:+.1f}%)")

        # Capital curve stats
        capitals = [100.0] + [t["capital_after"] for t in trades]
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
