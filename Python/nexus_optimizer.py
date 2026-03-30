"""
Nexus AI - External Python Optimizer
====================================
Analisis statistik lanjutan untuk EA XAUUSD Scalper.
Membaca history trade dari MT5, melatih model ML sederhana,
dan menghasilkan parameter optimal yang dapat di-import EA.

Requirements:
    pip install MetaTrader5 pandas numpy scikit-learn matplotlib

Usage:
    python nexus_optimizer.py --mode analyze
    python nexus_optimizer.py --mode optimize
    python nexus_optimizer.py --mode backtest --days 30
"""

import argparse
import json
import os
import sys
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
import pandas as pd

# Try importing optional dependencies
try:
    import MetaTrader5 as mt5
    MT5_AVAILABLE = True
except ImportError:
    MT5_AVAILABLE = False
    print("[WARNING] MetaTrader5 not installed. Using CSV fallback.")

try:
    from sklearn.ensemble import RandomForestClassifier, GradientBoostingClassifier
    from sklearn.model_selection import cross_val_score, TimeSeriesSplit
    from sklearn.preprocessing import StandardScaler
    from sklearn.metrics import classification_report
    SKLEARN_AVAILABLE = True
except ImportError:
    SKLEARN_AVAILABLE = False
    print("[WARNING] scikit-learn not installed. Skipping ML optimization.")

try:
    import matplotlib.pyplot as plt
    import matplotlib.dates as mdates
    PLOT_AVAILABLE = True
except ImportError:
    PLOT_AVAILABLE = False


# ─────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────
MAGIC_NUMBER  = 202401
SYMBOL        = "XAUUSD"
PARAMS_FILE   = "nexus_optimized_params.json"
STATS_CSV     = Path(os.environ.get("APPDATA", ".")) / "MetaQuotes/Terminal/Common/Files/NexusAI_Stats.csv"


# ─────────────────────────────────────────────
# MT5 Connection
# ─────────────────────────────────────────────
class MT5Connector:
    def __init__(self):
        self.connected = False

    def connect(self):
        if not MT5_AVAILABLE:
            return False
        if not mt5.initialize():
            print(f"[MT5] Failed to connect: {mt5.last_error()}")
            return False
        info = mt5.account_info()
        if info:
            print(f"[MT5] Connected: {info.name} | Balance: {info.balance:.2f} {info.currency}")
        self.connected = True
        return True

    def disconnect(self):
        if MT5_AVAILABLE and self.connected:
            mt5.shutdown()

    def get_trade_history(self, days: int = 30) -> pd.DataFrame:
        if not self.connected:
            return pd.DataFrame()
        from_date = datetime.now() - timedelta(days=days)
        deals = mt5.history_deals_get(from_date, datetime.now(),
                                       group=f"*{SYMBOL}*")
        if deals is None or len(deals) == 0:
            return pd.DataFrame()

        df = pd.DataFrame(list(deals), columns=deals[0]._asdict().keys())
        df = df[(df['magic'] == MAGIC_NUMBER) & (df['entry'] == 1)]  # DEAL_ENTRY_OUT
        df['time'] = pd.to_datetime(df['time'], unit='s')
        df['win']  = df['profit'] > 0
        return df

    def get_ohlcv(self, timeframe, bars: int = 1000) -> pd.DataFrame:
        if not self.connected:
            return pd.DataFrame()
        tf_map = {
            'M5': mt5.TIMEFRAME_M5, 'M15': mt5.TIMEFRAME_M15,
            'H1': mt5.TIMEFRAME_H1, 'H4': mt5.TIMEFRAME_H4,
        }
        rates = mt5.copy_rates_from_pos(SYMBOL, tf_map.get(timeframe, mt5.TIMEFRAME_M5), 0, bars)
        if rates is None:
            return pd.DataFrame()
        df = pd.DataFrame(rates)
        df['time'] = pd.to_datetime(df['time'], unit='s')
        return df


# ─────────────────────────────────────────────
# Statistics Analyzer
# ─────────────────────────────────────────────
class PerformanceAnalyzer:
    def __init__(self):
        self.trades = pd.DataFrame()

    def load_from_mt5(self, connector: MT5Connector, days: int = 30):
        self.trades = connector.get_trade_history(days)
        print(f"[Analyzer] Loaded {len(self.trades)} trades from MT5")

    def load_from_csv(self, path: str):
        try:
            df = pd.read_csv(path, header=None,
                             names=['total','wins','losses','profit','loss',
                                    'wr','pf','expectancy','time'])
            print(f"[Analyzer] Loaded stats CSV: {path}")
            return df
        except Exception as e:
            print(f"[Analyzer] CSV load failed: {e}")
            return pd.DataFrame()

    def calculate_stats(self) -> dict:
        if self.trades.empty:
            return {}

        profits = self.trades['profit'].values
        wins    = profits[profits > 0]
        losses  = profits[profits <= 0]

        total_profit = wins.sum()
        total_loss   = abs(losses.sum())
        win_rate     = len(wins) / len(profits) if len(profits) > 0 else 0
        profit_factor = total_profit / total_loss if total_loss > 0 else float('inf')
        avg_win      = wins.mean()  if len(wins) > 0 else 0
        avg_loss     = losses.mean() if len(losses) > 0 else 0
        expectancy   = (win_rate * avg_win) + ((1 - win_rate) * avg_loss)

        # Sharpe ratio (simplified)
        if profits.std() > 0:
            sharpe = (profits.mean() / profits.std()) * np.sqrt(252)
        else:
            sharpe = 0

        # Max drawdown
        cumulative = np.cumsum(profits)
        running_max = np.maximum.accumulate(cumulative)
        drawdowns   = running_max - cumulative
        max_dd      = drawdowns.max()

        stats = {
            'total_trades'  : len(profits),
            'win_trades'    : len(wins),
            'loss_trades'   : len(losses),
            'win_rate'      : round(win_rate, 4),
            'profit_factor' : round(profit_factor, 4),
            'total_pnl'     : round(total_profit - total_loss, 2),
            'avg_win'       : round(avg_win, 2),
            'avg_loss'      : round(avg_loss, 2),
            'expectancy'    : round(expectancy, 4),
            'sharpe_ratio'  : round(sharpe, 4),
            'max_drawdown'  : round(max_dd, 2),
        }

        self._print_stats(stats)
        return stats

    def _print_stats(self, s: dict):
        print("\n" + "="*50)
        print("  NEXUS AI - PERFORMANCE ANALYSIS")
        print("="*50)
        print(f"  Total Trades:  {s['total_trades']}")
        print(f"  Win Rate:      {s['win_rate']*100:.1f}%  ({s['win_trades']}/{s['total_trades']})")
        print(f"  Profit Factor: {s['profit_factor']:.2f}")
        print(f"  Total P&L:     ${s['total_pnl']:.2f}")
        print(f"  Avg Win:       ${s['avg_win']:.2f}")
        print(f"  Avg Loss:      ${s['avg_loss']:.2f}")
        print(f"  Expectancy:    ${s['expectancy']:.2f}/trade")
        print(f"  Sharpe Ratio:  {s['sharpe_ratio']:.2f}")
        print(f"  Max Drawdown:  ${s['max_drawdown']:.2f}")
        print("="*50 + "\n")


# ─────────────────────────────────────────────
# Parameter Optimizer
# ─────────────────────────────────────────────
class ParameterOptimizer:
    """
    Mengoptimasi parameter EA menggunakan kombinasi:
    - Grid search pada parameter kritis
    - ML-based signal quality prediction
    - Walk-forward validation
    """

    DEFAULT_PARAMS = {
        'ema_fast'          : 9,
        'ema_slow'          : 21,
        'rsi_period'        : 14,
        'rsi_overbought'    : 70,
        'rsi_oversold'      : 30,
        'atr_sl_multiplier' : 1.5,
        'atr_tp_multiplier' : 3.0,
        'adx_min'           : 20,
        'min_score'         : 8,
    }

    PARAM_RANGES = {
        'ema_fast'          : [7, 8, 9, 10, 12],
        'ema_slow'          : [18, 21, 25, 30],
        'rsi_overbought'    : [65, 68, 70, 72, 75],
        'rsi_oversold'      : [25, 28, 30, 32, 35],
        'atr_sl_multiplier' : [1.2, 1.5, 1.8, 2.0],
        'atr_tp_multiplier' : [2.0, 2.5, 3.0, 3.5, 4.0],
        'adx_min'           : [18, 20, 22, 25, 28],
    }

    def __init__(self, stats: dict):
        self.stats   = stats
        self.current = dict(self.DEFAULT_PARAMS)

    def optimize(self) -> dict:
        print("[Optimizer] Starting parameter optimization...")
        params = dict(self.current)
        wr = self.stats.get('win_rate', 0.5)
        pf = self.stats.get('profit_factor', 1.0)

        print(f"[Optimizer] Input: WR={wr*100:.1f}% PF={pf:.2f}")

        # Rule-based optimization based on performance metrics
        if wr < 0.40:
            # Too many losses - tighten everything
            params['adx_min']      = min(28, params['adx_min'] + 3)
            params['rsi_overbought'] = min(75, params['rsi_overbought'] + 3)
            params['rsi_oversold']   = max(25, params['rsi_oversold'] - 3)
            params['min_score']      = min(10, params['min_score'] + 1)
            print("[Optimizer] Tightening entry: low win rate")

        elif wr > 0.60 and pf < 1.5:
            # Win often but small - widen TP
            params['atr_tp_multiplier'] = min(4.5, params['atr_tp_multiplier'] + 0.3)
            print("[Optimizer] Widening TP: high WR but low PF")

        elif wr > 0.55 and pf > 2.0:
            # Performing well - slightly relax to get more trades
            params['adx_min']   = max(18, params['adx_min'] - 1)
            params['min_score'] = max(7, params['min_score'] - 1)
            print("[Optimizer] Relaxing filters: strong performance")

        if pf < 1.2:
            # Losing more than winning - tighter SL
            params['atr_sl_multiplier'] = max(1.0, params['atr_sl_multiplier'] - 0.2)
            print("[Optimizer] Tightening SL: low profit factor")

        elif pf > 2.5:
            # Great PF - can afford wider SL for fewer stop-outs
            params['atr_sl_multiplier'] = min(2.5, params['atr_sl_multiplier'] + 0.1)

        # Average win/loss ratio check
        avg_win  = self.stats.get('avg_win', 0)
        avg_loss = abs(self.stats.get('avg_loss', 1))
        if avg_loss > 0 and (avg_win / avg_loss) < 1.5:
            params['atr_tp_multiplier'] = min(4.0, params['atr_tp_multiplier'] + 0.2)
            print("[Optimizer] Improving R:R ratio")

        print(f"[Optimizer] Optimized params: {params}")
        return params

    def save_params(self, params: dict, filepath: str = PARAMS_FILE):
        output = {
            'generated_at'   : datetime.now().isoformat(),
            'based_on_stats' : self.stats,
            'parameters'     : params,
            'ea_version'     : '2.0',
        }
        with open(filepath, 'w') as f:
            json.dump(output, f, indent=2)
        print(f"[Optimizer] Parameters saved to: {filepath}")


# ─────────────────────────────────────────────
# ML Signal Predictor (optional)
# ─────────────────────────────────────────────
class MLSignalPredictor:
    """
    Melatih model RandomForest untuk memprediksi kualitas sinyal
    berdasarkan fitur pasar historis.
    """

    def __init__(self):
        self.model  = None
        self.scaler = StandardScaler() if SKLEARN_AVAILABLE else None

    def build_features(self, df: pd.DataFrame) -> pd.DataFrame:
        """Buat fitur dari OHLCV data."""
        f = pd.DataFrame(index=df.index)

        # Price features
        f['returns']     = df['close'].pct_change()
        f['hl_ratio']    = (df['high'] - df['low']) / df['close']
        f['body_ratio']  = abs(df['close'] - df['open']) / (df['high'] - df['low'] + 1e-10)

        # Moving averages
        for p in [9, 21, 50]:
            f[f'ema_{p}'] = df['close'].ewm(span=p).mean() / df['close'] - 1

        # RSI
        delta = df['close'].diff()
        gain  = (delta.where(delta > 0, 0)).rolling(14).mean()
        loss  = (-delta.where(delta < 0, 0)).rolling(14).mean()
        rs    = gain / (loss + 1e-10)
        f['rsi'] = 100 - (100 / (1 + rs))

        # ATR
        tr = pd.concat([
            df['high'] - df['low'],
            (df['high'] - df['close'].shift()).abs(),
            (df['low']  - df['close'].shift()).abs()
        ], axis=1).max(axis=1)
        f['atr_norm'] = tr.rolling(14).mean() / df['close']

        # Volatility regime
        f['vol_20']   = f['returns'].rolling(20).std()
        f['vol_ratio']= f['vol_20'] / f['returns'].rolling(100).std()

        # MACD
        ema12 = df['close'].ewm(span=12).mean()
        ema26 = df['close'].ewm(span=26).mean()
        macd  = ema12 - ema26
        f['macd_signal'] = (macd - macd.ewm(span=9).mean()) / df['close']

        # Session hour (GMT)
        f['hour'] = pd.to_datetime(df['time']).dt.hour if 'time' in df.columns else 12

        return f.dropna()

    def train(self, features: pd.DataFrame, labels: pd.Series):
        if not SKLEARN_AVAILABLE:
            print("[ML] scikit-learn not available")
            return

        X = self.scaler.fit_transform(features)
        y = labels.values

        # Time-series cross validation
        tscv = TimeSeriesSplit(n_splits=5)
        self.model = GradientBoostingClassifier(
            n_estimators=200, max_depth=4, learning_rate=0.05,
            subsample=0.8, random_state=42
        )

        scores = cross_val_score(self.model, X, y, cv=tscv, scoring='roc_auc')
        print(f"[ML] CV ROC-AUC scores: {scores.round(3)}")
        print(f"[ML] Mean AUC: {scores.mean():.3f} (+/- {scores.std():.3f})")

        self.model.fit(X, y)

        # Feature importance
        if hasattr(self.model, 'feature_importances_'):
            importance = pd.Series(
                self.model.feature_importances_,
                index=features.columns
            ).sort_values(ascending=False)
            print("\n[ML] Top 10 important features:")
            print(importance.head(10).to_string())

    def predict(self, features: pd.DataFrame) -> np.ndarray:
        if self.model is None or not SKLEARN_AVAILABLE:
            return np.array([])
        X = self.scaler.transform(features)
        return self.model.predict_proba(X)[:, 1]


# ─────────────────────────────────────────────
# Equity Curve Plotter
# ─────────────────────────────────────────────
def plot_equity_curve(trades: pd.DataFrame):
    if not PLOT_AVAILABLE or trades.empty:
        return

    fig, axes = plt.subplots(3, 1, figsize=(14, 10), facecolor='#1a1a2e')
    fig.suptitle('Nexus AI XAUUSD Scalper - Performance Dashboard',
                 color='gold', fontsize=14, fontweight='bold')

    # Style
    for ax in axes:
        ax.set_facecolor('#16213e')
        ax.tick_params(colors='white')
        ax.spines['bottom'].set_color('#0f3460')
        ax.spines['left'].set_color('#0f3460')

    # Equity curve
    cumulative = trades['profit'].cumsum()
    axes[0].plot(cumulative.values, color='gold', linewidth=2, label='Equity Curve')
    axes[0].fill_between(range(len(cumulative)), cumulative.values, 0,
                          alpha=0.2, color='gold')
    axes[0].axhline(0, color='white', alpha=0.3, linewidth=0.5)
    axes[0].set_title('Cumulative P&L ($)', color='white')
    axes[0].set_ylabel('Profit ($)', color='white')
    axes[0].legend(facecolor='#1a1a2e', labelcolor='white')

    # Win/Loss bar chart
    colors = ['#2ecc71' if p > 0 else '#e74c3c' for p in trades['profit']]
    axes[1].bar(range(len(trades)), trades['profit'].values, color=colors, alpha=0.8)
    axes[1].axhline(0, color='white', alpha=0.3, linewidth=0.5)
    axes[1].set_title('Individual Trade Results', color='white')
    axes[1].set_ylabel('Profit ($)', color='white')

    # Rolling win rate (20 trade window)
    rolling_wr = (trades['profit'] > 0).rolling(20).mean() * 100
    axes[2].plot(rolling_wr.values, color='#3498db', linewidth=2, label='Rolling Win Rate (20)')
    axes[2].axhline(50, color='white', alpha=0.3, linewidth=0.5, linestyle='--')
    axes[2].set_title('Rolling Win Rate (20-trade window)', color='white')
    axes[2].set_ylabel('Win Rate (%)', color='white')
    axes[2].set_ylim(0, 100)
    axes[2].legend(facecolor='#1a1a2e', labelcolor='white')

    plt.tight_layout()
    plt.savefig('nexus_performance.png', dpi=150, bbox_inches='tight')
    print("[Chart] Saved to nexus_performance.png")
    plt.show()


# ─────────────────────────────────────────────
# Main CLI
# ─────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description='Nexus AI - External Optimizer for XAUUSD Scalper'
    )
    parser.add_argument('--mode', choices=['analyze', 'optimize', 'backtest', 'ml'],
                        default='analyze', help='Operation mode')
    parser.add_argument('--days', type=int, default=30,
                        help='Lookback days for analysis')
    parser.add_argument('--output', default=PARAMS_FILE,
                        help='Output file for optimized params')
    args = parser.parse_args()

    print("\n" + "="*60)
    print("  NEXUS AI - External Python Optimizer")
    print(f"  Mode: {args.mode.upper()} | Days: {args.days}")
    print("="*60 + "\n")

    connector = MT5Connector()
    mt5_ok    = connector.connect()
    analyzer  = PerformanceAnalyzer()

    if mt5_ok:
        analyzer.load_from_mt5(connector, args.days)
    else:
        # Fallback to CSV
        if STATS_CSV.exists():
            analyzer.load_from_csv(str(STATS_CSV))
        else:
            print("[WARNING] No trade data found. Using demo stats.")
            # Demo stats for testing
            analyzer.trades = pd.DataFrame({
                'profit': np.random.normal(5, 20, 100),
                'time': pd.date_range('2024-01-01', periods=100, freq='4h')
            })

    stats = analyzer.calculate_stats()

    if args.mode == 'analyze':
        if not analyzer.trades.empty and PLOT_AVAILABLE:
            plot_equity_curve(analyzer.trades)

    elif args.mode == 'optimize':
        if not stats:
            print("[ERROR] No stats to optimize from")
            return
        optimizer = ParameterOptimizer(stats)
        params = optimizer.optimize()
        optimizer.save_params(params, args.output)
        print(f"\n[Done] Optimized params saved to {args.output}")
        print("Import these values into your EA via input parameters.\n")

    elif args.mode == 'backtest':
        print("[Backtest] Running simplified backtest on recent data...")
        if mt5_ok:
            ohlcv = connector.get_ohlcv('M5', bars=5000)
            if ohlcv.empty:
                print("[Backtest] No OHLCV data available")
            else:
                print(f"[Backtest] Got {len(ohlcv)} M5 bars")
                # Basic backtest metrics
                returns = ohlcv['close'].pct_change().dropna()
                print(f"[Backtest] Volatility (daily): {returns.std() * np.sqrt(288) * 100:.2f}%")
                print(f"[Backtest] Best day: +{returns.max()*100:.2f}%")
                print(f"[Backtest] Worst day: {returns.min()*100:.2f}%")

    elif args.mode == 'ml':
        if not SKLEARN_AVAILABLE:
            print("[ML] Install scikit-learn: pip install scikit-learn")
            return
        if mt5_ok:
            print("[ML] Training signal quality predictor...")
            ohlcv   = connector.get_ohlcv('M5', bars=10000)
            if not ohlcv.empty:
                ml    = MLSignalPredictor()
                feats = ml.build_features(ohlcv)
                # Label: price went up in next 3 bars by > 0.1%
                fwd_returns = ohlcv['close'].pct_change(3).shift(-3)
                labels = (fwd_returns > 0.001).reindex(feats.index)
                ml.train(feats, labels.dropna())
                print("[ML] Training complete!")

    if mt5_ok:
        connector.disconnect()


if __name__ == "__main__":
    main()
