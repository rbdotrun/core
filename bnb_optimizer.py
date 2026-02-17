#!/usr/bin/env python3
"""
Parameter sweep to find a strategy returning ~300% on BNB 5m data (2yr).

Key insight: compounding (% of capital per trade) instead of flat $10.
Sweeps: window_days, trigger%, TP%, SL%, position_size%.
"""

import csv
import os
import sys
from collections import deque
from itertools import product

DATA_DIR = "/tmp/bnb_5m"
CANDLE_MINUTES = 5
INITIAL_CAPITAL = 100.0
MAX_HOLD_DAYS = 60


def load_candles(data_dir):
    all_candles = []
    csv_files = sorted(f for f in os.listdir(data_dir) if f.endswith(".csv"))
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
                all_candles.append((
                    open_ts,           # 0: ts
                    float(row[1]),     # 1: open
                    float(row[2]),     # 2: high
                    float(row[3]),     # 3: low
                    float(row[4]),     # 4: close
                    close_ts,          # 5: close_ts
                ))
    all_candles.sort(key=lambda c: c[0])
    return all_candles


def compute_rolling_high(candles, window):
    n = len(candles)
    rolling_high = [0.0] * n
    dq = deque()
    for i in range(n):
        while dq and dq[0] < i - window + 1:
            dq.popleft()
        while dq and candles[dq[-1]][2] <= candles[i][2]:
            dq.pop()
        dq.append(i)
        rolling_high[i] = candles[dq[0]][2]
    return rolling_high


def run_strategy(candles, rolling_high, window_candles,
                 trigger_pct, tp_pct, sl_pct, pos_pct):
    """Full pipeline: detect entries + backtest with compounding position sizing."""
    n = len(candles)
    max_hold_candles = MAX_HOLD_DAYS * 24 * 60 // CANDLE_MINUTES
    capital = INITIAL_CAPITAL
    cooldown_until = -1
    num_trades = 0
    wins = 0
    losses = 0
    max_dd = 0.0
    peak_capital = capital

    for i in range(window_candles, n):
        if i <= cooldown_until:
            continue

        peak = rolling_high[i - 1]
        close = candles[i][4]  # close
        drop_pct = ((peak - close) / peak) * 100

        if drop_pct < trigger_pct:
            continue

        # Entry
        buy_price = close
        tp_price = buy_price * (1 + tp_pct / 100)
        sl_price = buy_price * (1 - sl_pct / 100)

        # Position size: pos_pct% of current capital
        invest = capital * (pos_pct / 100)
        if invest < 1.0:  # minimum $1
            continue

        # Scan for exit
        exit_reason = "TIMEOUT"
        sell_price = 0
        scan_end = min(i + max_hold_candles + 1, n)
        exit_idx = min(i + max_hold_candles, n - 1)

        for k in range(i + 1, scan_end):
            if candles[k][3] <= sl_price:  # low <= SL
                exit_reason = "SL"
                sell_price = sl_price
                exit_idx = k
                break
            if candles[k][2] >= tp_price:  # high >= TP
                exit_reason = "TP"
                sell_price = tp_price
                exit_idx = k
                break

        if exit_reason == "TIMEOUT":
            sell_price = candles[exit_idx][4]

        # P&L
        qty = invest / buy_price
        revenue = qty * sell_price
        profit = revenue - invest

        capital = capital - invest + revenue
        num_trades += 1

        if profit > 0:
            wins += 1
        else:
            losses += 1

        if capital > peak_capital:
            peak_capital = capital
        dd = ((peak_capital - capital) / peak_capital) * 100
        if dd > max_dd:
            max_dd = dd

        cooldown_until = exit_idx

    total_return = ((capital - INITIAL_CAPITAL) / INITIAL_CAPITAL) * 100
    win_rate = (wins / num_trades * 100) if num_trades > 0 else 0

    return {
        "final_capital": capital,
        "return_pct": total_return,
        "num_trades": num_trades,
        "wins": wins,
        "losses": losses,
        "win_rate": win_rate,
        "max_dd": max_dd,
    }


def main():
    print("Loading candles...")
    candles = load_candles(DATA_DIR)
    print(f"  {len(candles)} candles loaded")

    # Parameter grid
    window_days_list = [3, 5, 7, 14]
    trigger_pct_list = [5, 7, 10, 15]
    tp_pct_list = [10, 15, 20, 30, 50]
    sl_pct_list = [3, 5, 7, 10]
    pos_pct_list = [25, 50, 75, 100]

    total_combos = (len(window_days_list) * len(trigger_pct_list) *
                    len(tp_pct_list) * len(sl_pct_list) * len(pos_pct_list))
    print(f"  Sweeping {total_combos} parameter combinations...\n")

    # Precompute rolling highs
    rolling_highs = {}
    for wd in window_days_list:
        wc = wd * 24 * 60 // CANDLE_MINUTES
        print(f"  Computing {wd}-day rolling high ({wc} candles)...")
        rolling_highs[wd] = (compute_rolling_high(candles, wc), wc)

    results = []
    count = 0

    for wd, trigger, tp, sl, pos in product(
        window_days_list, trigger_pct_list, tp_pct_list, sl_pct_list, pos_pct_list
    ):
        rh, wc = rolling_highs[wd]
        r = run_strategy(candles, rh, wc, trigger, tp, sl, pos)
        r["params"] = (wd, trigger, tp, sl, pos)
        results.append(r)
        count += 1
        if count % 100 == 0:
            print(f"  ... {count}/{total_combos} done")

    # Sort by return
    results.sort(key=lambda r: r["return_pct"], reverse=True)

    # Show top 30
    print("\n" + "=" * 120)
    print("  TOP 30 STRATEGIES BY RETURN")
    print("=" * 120)

    hdr = (f"{'#':>3} | {'Win':>3}d | {'Trig':>5} | {'TP':>4} | {'SL':>4} | "
           f"{'Pos%':>4} | {'Trades':>6} | {'WinR':>5} | {'Return':>8} | "
           f"{'Final$':>9} | {'MaxDD':>6}")
    print(hdr)
    print("-" * len(hdr))

    for i, r in enumerate(results[:30], 1):
        wd, trigger, tp, sl, pos = r["params"]
        print(f"{i:>3} | {wd:>3}  | {trigger:>4.0f}% | {tp:>3.0f}% | {sl:>3.0f}% | "
              f"{pos:>3.0f}% | {r['num_trades']:>6} | {r['win_rate']:>4.0f}% | "
              f"{r['return_pct']:>+7.1f}% | ${r['final_capital']:>8.2f} | "
              f"{r['max_dd']:>5.1f}%")

    # Show strategies near 300% target
    print("\n" + "=" * 120)
    print("  STRATEGIES CLOSEST TO +300% (with max drawdown < 50%)")
    print("=" * 120)

    target_300 = [r for r in results
                  if 250 <= r["return_pct"] <= 400 and r["max_dd"] < 50]
    target_300.sort(key=lambda r: abs(r["return_pct"] - 300))

    print(hdr)
    print("-" * len(hdr))
    for i, r in enumerate(target_300[:20], 1):
        wd, trigger, tp, sl, pos = r["params"]
        print(f"{i:>3} | {wd:>3}  | {trigger:>4.0f}% | {tp:>3.0f}% | {sl:>3.0f}% | "
              f"{pos:>3.0f}% | {r['num_trades']:>6} | {r['win_rate']:>4.0f}% | "
              f"{r['return_pct']:>+7.1f}% | ${r['final_capital']:>8.2f} | "
              f"{r['max_dd']:>5.1f}%")

    # Best risk-adjusted near 300%
    print("\n" + "=" * 120)
    print("  BEST RISK-ADJUSTED (return >= 280%, lowest drawdown)")
    print("=" * 120)

    good = [r for r in results if r["return_pct"] >= 280]
    good.sort(key=lambda r: r["max_dd"])

    print(hdr)
    print("-" * len(hdr))
    for i, r in enumerate(good[:10], 1):
        wd, trigger, tp, sl, pos = r["params"]
        print(f"{i:>3} | {wd:>3}  | {trigger:>4.0f}% | {tp:>3.0f}% | {sl:>3.0f}% | "
              f"{pos:>3.0f}% | {r['num_trades']:>6} | {r['win_rate']:>4.0f}% | "
              f"{r['return_pct']:>+7.1f}% | ${r['final_capital']:>8.2f} | "
              f"{r['max_dd']:>5.1f}%")

    print("\n" + "=" * 120)


if __name__ == "__main__":
    main()
