# NEXUS AI - XAUUSD Self-Healing Scalper

## Overview

AI Trading Agent untuk scalping XAUUSD (Gold) di MetaTrader 5 dengan kemampuan **self-healing** dan **self-optimization** otomatis.

## Arsitektur Sistem

```
NexusAI/
├── MQL5/
│   ├── Experts/
│   │   └── NexusAI_XAUUSD_Scalper.mq5     ← EA utama (pasang di MT5)
│   ├── Include/
│   │   ├── RiskManager.mqh                 ← Manajemen risiko & lot sizing
│   │   ├── MarketAnalyzer.mqh              ← Analisis pasar multi-timeframe
│   │   ├── SelfHealer.mqh                  ← Engine self-healing & optimasi
│   │   └── TradeManager.mqh                ← Eksekusi & manajemen trade
│   └── Scripts/
│       └── NexusAI_ReportGenerator.mq5     ← Generate laporan HTML/CSV
└── Python/
    ├── nexus_optimizer.py                   ← Optimizer eksternal berbasis ML
    └── requirements.txt
```

## Cara Install di MT5

### 1. Copy File MQL5

```
Copy MQL5/Include/*.mqh  →  [MT5 Data Folder]/MQL5/Include/NexusAI/
Copy MQL5/Experts/*.mq5  →  [MT5 Data Folder]/MQL5/Experts/NexusAI/
Copy MQL5/Scripts/*.mq5  →  [MT5 Data Folder]/MQL5/Scripts/NexusAI/
```

> Buka MT5 → File → Open Data Folder untuk menemukan lokasi folder

### 2. Compile EA

Di MetaEditor (F4 di MT5):
- Buka `NexusAI_XAUUSD_Scalper.mq5`
- Tekan F7 untuk compile
- Pastikan **0 errors**

### 3. Pasang di Chart

1. Buka chart **XAUUSD** timeframe **M5**
2. Drag & drop EA ke chart
3. Aktifkan **"Allow Algo Trading"**
4. Set parameter input sesuai kebutuhan

## Parameter Penting

| Parameter | Default | Keterangan |
|-----------|---------|-----------|
| `InpRiskPercent` | 1.0 | % risiko per trade (rekomendasi: 0.5-2%) |
| `InpMaxDailyLoss` | 5.0 | Stop trading jika rugi >5% hari ini |
| `InpMaxDrawdown` | 15.0 | Stop trading jika DD >15% total |
| `InpMaxConsecLoss` | 5 | Masuk recovery mode setelah 5 loss berturut |
| `InpSelfHealEnabled` | true | Aktifkan engine self-healing |
| `InpOptimizeCycle` | 20 | Optimasi parameter tiap 20 trade |
| `InpHealPauseMins` | 60 | Pause trading 60 menit setelah healing kritis |
| `InpSessionFilter` | true | Hanya trade saat London/NY session |
| `InpMaxSpreadPts` | 50 | Tolak sinyal jika spread >50 poin |

## Strategi Trading

### Multi-Timeframe Confluence

```
H1  → Trend filter (EMA 9/21 + Ichimoku Cloud)
M15 → Konfirmasi arah (EMA cross)
M5  → Entry signal (EMA + RSI + MACD + Stoch + ADX + BB)
```

### Scoring System (min 8/13 untuk entry)

| Indikator | Bobot | Kondisi |
|-----------|-------|---------|
| H1 Trend (EMA+Ichimoku) | 3 | Fast EMA di atas Slow + price di atas cloud |
| M15 EMA | 2 | Fast EMA cross slow |
| M5 EMA Cross | 2 | Crossover baru di M5 |
| MACD | 2 | Main di atas signal, di atas/bawah 0 |
| ADX | 1 | > 20 (ada tren yang jelas) |
| RSI | 1 | Tidak overbought/oversold |
| Stochastic | 1 | Konfirmasi arah |
| Bollinger Bands | 1 | Bounce/reject dari band |

### Session Filter (GMT)

- **London**: 07:00-16:00 GMT ✅
- **New York**: 13:00-21:00 GMT ✅
- **Overlap London/NY**: 13:00-16:00 GMT ✅ (terbaik untuk gold)
- **Asian low-liquidity**: 00:00-06:00 GMT ❌ (skip)

## Fitur Self-Healing

### Siklus Optimasi (tiap 20 trade)

```
Win Rate < 40%  → Perketat entry (ADX naik, RSI range dipersempit)
Win Rate > 60% & PF < 1.5 → Perlebar TP
PF < 1.2        → Perketat SL (kurangi ATR multiplier)
PF > 2.5        → Beri SL lebih lebar (kurangi stop-out)
```

### Healing Actions

| Action | Kondisi | Efek |
|--------|---------|------|
| `TIGHTEN_ENTRY` | WR < 42% | ADX min naik, RSI range dipersempit |
| `WIDEN_TP` | WR > 50% & PF < 1.3 | ATR TP multiplier bertambah |
| `TIGHTEN_SL` | Avg loss > 2x avg win | ATR SL multiplier berkurang |
| `REDUCE_RISK` | DD > 8% | Risk per trade dikurangi |
| `PAUSE_TRADING` | WR < 30% & PF < 1.0 | Pause 60 menit (default) |
| `RESET_PARAMS` | 3x degradasi kritis berturut | Reset + pause 2 jam |

### Recovery Mode

Setelah 5 consecutive losses → lot size otomatis dikurangi 50% untuk 5 trade berikutnya.

## Risk Management

### Lot Sizing (ATR-based)

```
Lot = (Balance × Risk%) / (SL_pips × PipValue)
SL  = MathMax(input_SL, ATR × 0.5)  ← pakai yang lebih besar
```

### Emergency Stop

- Daily loss > 5% → Halt sampai hari berikutnya
- Total DD > 15% → Halt (perlu manual reset)
- 5+ consecutive losses → Recovery mode (half lot)

## Python Optimizer (Opsional)

### Install Dependencies

```bash
pip install -r Python/requirements.txt
```

### Penggunaan

```bash
# Analisis performa + grafik equity
python Python/nexus_optimizer.py --mode analyze --days 30

# Optimasi parameter otomatis
python Python/nexus_optimizer.py --mode optimize --days 60

# Backtest sederhana
python Python/nexus_optimizer.py --mode backtest --days 30

# ML signal predictor training
python Python/nexus_optimizer.py --mode ml
```

Output: `nexus_optimized_params.json` berisi parameter optimal yang bisa di-input ke EA.

## Report Generator

Jalankan script `NexusAI_ReportGenerator.mq5` dari MT5:
- Script → NexusAI → NexusAI_ReportGenerator
- Output: `NexusAI_Report.html` + `NexusAI_Report_[date].csv`
- Tersimpan di `[MT5 Data Folder]/MQL5/Files/Common/`

## File Log & Data

| File | Lokasi | Isi |
|------|--------|-----|
| `NexusAI_SelfHeal.log` | MT5 Common Files | Log semua healing actions |
| `NexusAI_Stats.csv` | MT5 Common Files | Statistik performa (persistent) |
| `NexusAI_Report.html` | MT5 Common Files | Report HTML terakhir |
| `nexus_performance.png` | Python dir | Grafik equity curve |

## Konvensi Kode MQL5

- Semua class prefix `C` (e.g. `CRiskManager`)
- Input variables prefix `Inp` (e.g. `InpRiskPercent`)
- Global variables prefix `g_` (e.g. `g_risk`)
- Magic Number: **202401** (default)
- Semua error di-log dengan `[ClassName]` prefix

## Testing & Backtest

### Strategy Tester MT5

1. Buka Strategy Tester (Ctrl+R)
2. Expert: `NexusAI/NexusAI_XAUUSD_Scalper`
3. Symbol: XAUUSD, Period: M5
4. Model: **Every tick based on real ticks** (paling akurat)
5. Date: minimal 3-6 bulan data
6. Deposit: $10,000 recommended untuk test

### Parameter Optimasi di Tester

Parameter yang paling berpengaruh untuk optimization pass:
- `InpRiskPercent`: 0.5, 1.0, 1.5, 2.0
- `InpAtrSlMultiplier`: 1.2-2.0 (step 0.2)
- `InpAtrTpMultiplier`: 2.0-4.0 (step 0.5)

## Catatan Penting

> **DISCLAIMER**: Trading forex/gold melibatkan risiko tinggi. Gunakan pada akun demo
> terlebih dahulu minimal 1-3 bulan sebelum live. Tidak ada jaminan profit.

- EA ini dioptimalkan untuk **broker ECN/STP** dengan spread rendah (<30 pips untuk XAU)
- Pastikan broker mengizinkan algorithmic trading pada akun Anda
- Self-healing memerlukan minimal **30 trade** sebelum baseline terbentuk
- Disarankan VPS dengan ping <10ms ke server broker untuk eksekusi optimal
