# NEXUS AI v3 - XAUUSD Aggressive Self-Healing Scalper

## Overview

AI Trading Agent untuk scalping **XAUUSD (Gold)** di MetaTrader 5 dengan 3 strategi entry,
4-timeframe confluence, dual-TP execution, pyramid add-on, dan engine **self-healing** berbasis
Kelly criterion + Calmar ratio.

## Arsitektur Sistem

```
NexusAI/
├── MQL5/
│   ├── Experts/
│   │   └── NexusAI_XAUUSD_Scalper.mq5     ← EA utama v3 (pasang di MT5)
│   ├── Include/
│   │   ├── RiskManager.mqh                 ← Kelly lot sizing, tiered recovery
│   │   ├── MarketAnalyzer.mqh              ← 4-TF analysis, 3 signal types
│   │   ├── SelfHealer.mqh                  ← 9-action AI heal engine
│   │   └── TradeManager.mqh                ← Dual-TP, pyramid, ATR trailing
│   └── Scripts/
│       └── NexusAI_ReportGenerator.mq5     ← HTML/CSV performance report
└── Python/
    ├── nexus_optimizer.py                   ← ML optimizer + equity chart
    └── requirements.txt
```

## Cara Install di MT5

### 1. Copy File MQL5

```
Copy MQL5/Include/*.mqh  →  [MT5 Data Folder]/MQL5/Include/NexusAI/
Copy MQL5/Experts/*.mq5  →  [MT5 Data Folder]/MQL5/Experts/NexusAI/
Copy MQL5/Scripts/*.mq5  →  [MT5 Data Folder]/MQL5/Scripts/NexusAI/
```

> MT5 → File → Open Data Folder untuk menemukan lokasi folder

### 2. Compile

MetaEditor (F4) → Buka `NexusAI_XAUUSD_Scalper.mq5` → F7 → **0 errors**

### 3. Pasang di Chart

1. Chart **XAUUSD M5** → Drag EA
2. Aktifkan **"Allow Algo Trading"**
3. Set input parameters

## Parameter Penting

| Parameter | Default | Keterangan |
|-----------|---------|-----------|
| `InpRiskPercent` | 1.5 | Base risk % per trade (Kelly-blended) |
| `InpMaxDailyLoss` | 6.0 | Halt jika rugi >6% hari ini |
| `InpMaxDrawdown` | 18.0 | Halt jika total DD >18% |
| `InpMaxConsecLoss` | 4 | Konsekutif loss → naik 1 recovery tier |
| `InpCompoundMode` | true | Risk scale naik seiring pertumbuhan balance |
| `InpPyramidEnabled` | true | Add ke winner saat profit > 1.5 ATR |
| `InpSelfHealEnabled` | true | Aktifkan engine self-healing |
| `InpOptimizeCycle` | 20 | Heal cycle tiap 20 trade |
| `InpShortPauseMins` | 30 | Pause singkat setelah degradasi |
| `InpLongPauseMins` | 120 | Pause panjang setelah degradasi parah |
| `InpSessionFilter` | true | Hanya London + NY session |
| `InpOverlapBonus` | true | Signal kuat ekstra di overlap session |
| `InpMaxSpreadPts` | 45 | Tolak sinyal jika spread >45 poin |

## Strategi Trading v3

### 4-Timeframe Confluence

```
H4  → Macro bias (EMA 50/200 - bull/bear market)
H1  → Trend (EMA 8/21 + Ichimoku Cloud)
M15 → Konfirmasi arah (EMA alignment)
M5  → Entry precise (EMA + RSI + MACD + BB + ADX + CCI + Stoch)
```

### 3 Tipe Sinyal

| Tipe | Kondisi | Karakteristik |
|------|---------|---------------|
| **MOMENTUM** | EMA cross + MACD cross fresh | Agresif, ikut breakout |
| **PULLBACK** | BB pullback + M15 aligned + above/below trend EMA | Masuk di retest |
| **BREAKOUT** | BB break + ADX >35 + H1 strong | Wide TP, tight SL |

### Scoring System (min 7/15, turun ke 6 jika ADX >35)

| Faktor | Bobot | Kondisi |
|--------|-------|---------|
| H4 Bias (EMA 50/200) | 2 | Bull or bear alignment |
| H1 Strong Trend | 3 | EMA + Ichimoku + RSI |
| H1 Basic Trend | 1 | EMA only |
| M15 EMA Aligned | 1 | Fast > Slow |
| M5 EMA Fresh Cross | 2 | Crossover baru |
| M5 EMA Aligned | 1 | Tanpa crossover |
| MACD Fresh Cross | 2 | Signal bersamaan crossover |
| MACD Aligned | 1 | Direction saja |
| Stoch Cross | 1 | Konfirmasi |
| RSI + CCI | 1+1 | Momentum confirmation |
| Price Action | 1 | Pin bar / Engulfing / Strong candle |
| ADX Trend | +1/-1 | >20 bonus, <20 penalty |

### Session Filter (GMT)

- **London**: 07:00-16:00 GMT ✅
- **New York**: 13:00-21:00 GMT ✅
- **Overlap L/NY**: 13:00-16:00 GMT ✅ 🌟 **BONUS signal strength +15%**
- **Asian**: 00:00-06:00 GMT ❌

## Execution Model - Dual TP

```
Buka 2 posisi bersamaan:
  Posisi 1 (50% lot) → TP1 = 2.0 × ATR  (partial close)
  Posisi 2 (50% lot) → TP2 = 3.5 × ATR  (runner, dinaikkan dengan trailing)

Break-even: setelah profit ≥ 0.8 × ATR → SL pindah ke BE
Trailing  : setelah profit ≥ 1.0 × ATR → trail di 1.0 × ATR
Pyramid   : setelah profit ≥ 1.5 × ATR → tambah 50% lot lagi
```

## Self-Healing Engine v3

### Kelly-Blended Lot Sizing

```
BaseRisk = FixedFraction × 0.70 + (HalfKelly) × 0.30
Adjusted = BaseRisk × SignalStrength(0.8x - 1.2x) × TierMultiplier
```

### 4-Level Recovery Tiers

| Tier | Konsekutif Loss | Lot Multiplier |
|------|----------------|----------------|
| 0 | Normal | 100% |
| 1 | ≥ 4 loss | 75% |
| 2 | ≥ 4 loss lagi | 50% |
| 3 | ≥ 4 loss lagi | 25% |

Tier turun 1 setiap 5 win setelah masuk recovery.

### 9 Healing Actions

| Action | Kondisi | Efek |
|--------|---------|------|
| `TIGHTEN_ENTRY` | WR < 42% | ADX+, RSI range ketat, score threshold+ |
| `RELAX_ENTRY` | WR > 60% & PF > 2.0 | ADX-, score- |
| `WIDEN_TP` | WR > 60% & PF < 1.5 | ATR TP2 multiplier+ |
| `TIGHTEN_SL` | AvgLoss > 1.3x AvgWin | ATR SL- |
| `WIDEN_SL` | AvgWin > 2.5x AvgLoss | ATR SL+ |
| `REDUCE_RISK` | DD > 10% | Recovery tier naik |
| `PAUSE_SHORT` | WR < 40% & degrading | Pause 30 menit |
| `PAUSE_LONG` | WR < 33% & PF < 1.0 | Pause 2 jam |
| `FULL_RESET` | Degradasi 3x berturut | Reset params + 2 jam pause |

### Regime Detection

```
ADX > 30  → TRENDING  → prioritas MOMENTUM & BREAKOUT signals
ADX < 20  → RANGING   → prioritas PULLBACK signals
ADX 20-30 → UNKNOWN   → semua signal aktif
```

### Performance Metrics yang dipantau

- Win Rate (rolling 5 windows vs all-time)
- Profit Factor
- Expectancy per trade
- Kelly % optimal bet fraction
- Sortino ratio (downside-adjusted return)
- Calmar ratio (return / max drawdown)

## Python Optimizer

```bash
pip install -r Python/requirements.txt

python nexus_optimizer.py --mode analyze   # Equity curve + stats
python nexus_optimizer.py --mode optimize  # Generate optimal params JSON
python nexus_optimizer.py --mode ml        # Train ML signal predictor
```

## Testing di MT5 Strategy Tester

1. **Ctrl+R** → Expert: `NexusAI/NexusAI_XAUUSD_Scalper`
2. Symbol: XAUUSD | Period: M5
3. Model: **Every tick based on real ticks**
4. Date range: minimal 6 bulan
5. Deposit: $10,000

### Parameter Focus untuk Optimization Pass

```
InpRiskPercent      : 0.5, 1.0, 1.5, 2.0
InpTrailAtrMult     : 0.8, 1.0, 1.2, 1.5
InpBEAtrMult        : 0.5, 0.7, 0.9
InpPyramidATR       : 1.2, 1.5, 2.0
```

## Konvensi Kode

- Class prefix: `C` (e.g. `CRiskManager`)
- Input prefix: `Inp` (e.g. `InpRiskPercent`)
- Global prefix: `g_` (e.g. `g_risk`)
- Panel object prefix: `NX_`
- Magic Number: **202401** (default)
- Log prefix: `[ClassName]`

## File Log

| File | Lokasi | Isi |
|------|--------|-----|
| `NexusAI_SelfHeal.log` | MT5 Common Files | Semua healing actions |
| `NexusAI_Stats.csv` | MT5 Common Files | Stats persistent (reload saat restart) |
| `NexusAI_Report.html` | MT5 Common Files | Report terakhir dari ReportGenerator |
| `nexus_performance.png` | Python dir | Equity curve chart |

---

> **DISCLAIMER**: Trading forex/gold melibatkan risiko tinggi. Gunakan akun demo minimal
> 2-3 bulan sebelum live trading. Tidak ada jaminan profit. Gunakan di broker ECN/STP
> dengan spread < 25 pts pada XAUUSD.
