//+------------------------------------------------------------------+
//|                                                   SelfHealer.mqh |
//|                          Nexus AI v3 - XAUUSD Aggressive Scalper |
//|  Features: Regime detection, Rolling vs all-time stats,         |
//|            Adaptive cycle, Granular 9-action healing engine     |
//+------------------------------------------------------------------+
#pragma once

#include <Files\FileTxt.mqh>

//+------------------------------------------------------------------+
//| Performance snapshot                                             |
//+------------------------------------------------------------------+
struct PerfStats {
    int    total, wins, losses;
    double grossProfit, grossLoss;
    double winRate, profitFactor;
    double avgWin, avgLoss;
    double expectancy;
    double maxDrawdown;
    double calmar;       // Return / MaxDD
    double sortino;
    double kellyPct;     // Optimal bet fraction
    datetime stamp;

    void Reset() {
        total = wins = losses = 0;
        grossProfit = grossLoss = 0;
        winRate = profitFactor = avgWin = avgLoss = 0;
        expectancy = maxDrawdown = calmar = sortino = kellyPct = 0;
        stamp = 0;
    }
    void Calc() {
        if (total == 0) return;
        winRate      = (double)wins / total;
        profitFactor = grossLoss != 0 ? grossProfit / MathAbs(grossLoss) : grossProfit;
        avgWin       = wins   > 0 ? grossProfit / wins   : 0;
        avgLoss      = losses > 0 ? grossLoss   / losses : 0;
        expectancy   = winRate * avgWin + (1 - winRate) * avgLoss;
        // Kelly
        double b = (avgLoss != 0) ? MathAbs(avgWin / avgLoss) : 0;
        kellyPct = (b > 0) ? (b * winRate - (1 - winRate)) / b : 0;
        stamp = TimeCurrent();
    }
};

//+------------------------------------------------------------------+
//| Market regime                                                    |
//+------------------------------------------------------------------+
enum MarketRegime {
    REGIME_UNKNOWN,
    REGIME_TRENDING,
    REGIME_RANGING,
    REGIME_VOLATILE
};

//+------------------------------------------------------------------+
//| Healing actions                                                  |
//+------------------------------------------------------------------+
enum HealAction {
    HEAL_NONE,
    HEAL_TIGHTEN_ENTRY,
    HEAL_RELAX_ENTRY,
    HEAL_WIDEN_TP,
    HEAL_TIGHTEN_SL,
    HEAL_WIDEN_SL,
    HEAL_REDUCE_RISK,
    HEAL_PAUSE_SHORT,    // 30-min pause
    HEAL_PAUSE_LONG,     // 2-hour pause
    HEAL_FULL_RESET
};

//+------------------------------------------------------------------+
//| Self Healer                                                      |
//+------------------------------------------------------------------+
class CSelfHealer {
private:
    PerfStats  m_all;          // All-time stats
    PerfStats  m_rolling[5];   // 5 rolling windows (last 20 trades each)
    int        m_rollIdx;
    PerfStats  m_window;       // Current accumulation window

    // Baseline (set after first 30 trades)
    double     m_baseWR, m_basePF;
    bool       m_baseSet;
    int        m_degradCount;  // Consecutive degradation cycles

    // Optimization schedule
    int        m_cycleTrades;
    int        m_tradesSinceCycle;
    datetime   m_lastCycleTime;
    int        m_minCycleInterval; // seconds

    // Regime tracking (ADX-based, updated externally)
    MarketRegime m_regime;
    double       m_lastADX;

    // Log
    string     m_logFile;
    int        m_logLines;
    int        m_maxLogLines;

    // Trade journal (last 100 trades for pattern analysis)
    double     m_journal[100];
    int        m_journalIdx;
    int        m_journalCount;

public:
    CSelfHealer() {
        m_all.Reset();  m_window.Reset();
        m_rollIdx           = 0;
        m_baseWR            = 0;
        m_basePF            = 0;
        m_baseSet           = false;
        m_degradCount       = 0;
        m_cycleTrades       = 20;
        m_tradesSinceCycle  = 0;
        m_lastCycleTime     = 0;
        m_minCycleInterval  = 1800; // min 30 min between cycles
        m_regime            = REGIME_UNKNOWN;
        m_lastADX           = 0;
        m_logFile           = "NexusAI_SelfHeal.log";
        m_logLines          = 0;
        m_maxLogLines       = 2000;
        m_journalIdx        = 0;
        m_journalCount      = 0;
        for (int i = 0; i < 5; i++) m_rolling[i].Reset();
        ArrayInitialize(m_journal, 0);
    }

    void Init(int cycleTrades) {
        m_cycleTrades = cycleTrades;
        LoadStats();
        Log(StringFormat("SelfHealer v3 init | Cycle=%d | History=%d trades",
            cycleTrades, m_all.total));
    }

    void RecordTrade(double profit, string signalType, double adx) {
        bool win = (profit > 0);
        m_lastADX = adx;

        // Update all-time stats
        m_all.total++;
        if (win) { m_all.wins++;   m_all.grossProfit += profit; }
        else     { m_all.losses++; m_all.grossLoss   += profit; }
        m_all.Calc();

        // Update window
        m_window.total++;
        if (win) { m_window.wins++;   m_window.grossProfit += profit; }
        else     { m_window.losses++; m_window.grossLoss   += profit; }

        // Journal
        m_journal[m_journalIdx % 100] = profit;
        m_journalIdx++;
        if (m_journalCount < 100) m_journalCount++;

        m_tradesSinceCycle++;

        // Set baseline after 30 trades
        if (!m_baseSet && m_all.total >= 30) {
            m_all.Calc();
            m_baseWR   = m_all.winRate;
            m_basePF   = m_all.profitFactor;
            m_baseSet  = true;
            Log(StringFormat("BASELINE SET: WR=%.1f%% PF=%.2f", m_baseWR*100, m_basePF));
        }

        // Update regime estimate
        UpdateRegime(adx);

        Log(StringFormat("Trade #%d | %s $%.2f | %s | WR=%.1f%% PF=%.2f | ADX=%.0f",
            m_all.total, win?"WIN":"LOSS", profit, signalType,
            m_all.winRate*100, m_all.profitFactor, adx));

        SaveStats();
    }

    bool ShouldOptimize() {
        if (m_all.total < 15) return false;
        if (m_tradesSinceCycle < m_cycleTrades) {
            // Emergency early cycle: if 5 consecutive losses detected
            if (DetectConsecLosses(5)) {
                Log("Early heal cycle: 5 consecutive losses detected");
                return true;
            }
            return false;
        }
        if ((TimeCurrent() - m_lastCycleTime) < m_minCycleInterval) return false;
        return true;
    }

    HealAction Analyze() {
        // Commit current window to rolling history
        m_window.Calc();
        m_rolling[m_rollIdx % 5] = m_window;
        m_rollIdx++;
        m_window.Reset();

        m_tradesSinceCycle = 0;
        m_lastCycleTime    = TimeCurrent();

        m_all.Calc();
        Log("====== HEAL CYCLE ======");
        Log(StringFormat("All-time: WR=%.1f%% PF=%.2f Exp=$%.2f Kelly=%.1f%%",
            m_all.winRate*100, m_all.profitFactor, m_all.expectancy, m_all.kellyPct*100));
        Log(StringFormat("Recent:   WR=%.1f%% PF=%.2f Regime=%s",
            RecentWinRate()*100, RecentPF(), RegimeStr()));

        HealAction action = DetermineAction();
        if (IsDegrading()) m_degradCount++;
        else               m_degradCount = MathMax(0, m_degradCount - 1);

        Log(StringFormat("Action: %s | DegradCount=%d", ActionStr(action), m_degradCount));
        return action;
    }

    void UpdateADX(double adx) {
        m_lastADX = adx;
        UpdateRegime(adx);
    }

    // ── Getters ──────────────────────────────────────────────────
    PerfStats    GetStats()         { return m_all; }
    MarketRegime GetRegime()        { return m_regime; }
    double       GetRecentWR()      { return RecentWinRate(); }
    double       GetRecentPF()      { return RecentPF(); }
    bool         IsDegrading()      {
        if (!m_baseSet || m_all.total < 40) return false;
        return (m_all.winRate < m_baseWR * 0.82) ||
               (m_all.profitFactor < m_basePF * 0.75);
    }
    int          GetDegradCount()   { return m_degradCount; }

    string GetFullReport() {
        m_all.Calc();
        string r = "======= NEXUS AI v3 REPORT =======\n";
        r += StringFormat("All-Time  : %d trades | WR=%.1f%% | PF=%.2f\n",
             m_all.total, m_all.winRate*100, m_all.profitFactor);
        r += StringFormat("P&L       : +$%.2f / -$%.2f  Net=$%.2f\n",
             m_all.grossProfit, MathAbs(m_all.grossLoss),
             m_all.grossProfit + m_all.grossLoss);
        r += StringFormat("Avg Win   : $%.2f | Avg Loss: $%.2f | Exp: $%.2f\n",
             m_all.avgWin, m_all.avgLoss, m_all.expectancy);
        r += StringFormat("Kelly %%   : %.1f%%  (half-Kelly: %.1f%%)\n",
             m_all.kellyPct*100, m_all.kellyPct*50);
        r += StringFormat("Recent    : WR=%.1f%% | PF=%.2f | Regime: %s\n",
             RecentWinRate()*100, RecentPF(), RegimeStr());
        r += StringFormat("Degrading : %s (count: %d)\n",
             IsDegrading()?"YES !!!" : "No", m_degradCount);
        r += "===================================";
        return r;
    }

private:
    HealAction DetermineAction() {
        double wr  = m_all.winRate;
        double pf  = m_all.profitFactor;
        double rwr = RecentWinRate();
        double rpf = RecentPF();

        // Use recent stats for faster response
        double effectiveWR = (m_all.total > 50) ? (wr * 0.4 + rwr * 0.6) : wr;
        double effectivePF = (m_all.total > 50) ? (pf * 0.4 + rpf * 0.6) : pf;

        // Full reset - critical
        if (m_degradCount >= 3 || (effectiveWR < 0.28 && effectivePF < 0.9)) {
            Log("CRITICAL: Full reset triggered");
            return HEAL_FULL_RESET;
        }

        // Long pause
        if (effectiveWR < 0.33 && effectivePF < 1.0) return HEAL_PAUSE_LONG;

        // Degrading significantly
        if (IsDegrading() && effectiveWR < 0.40)      return HEAL_PAUSE_SHORT;

        // Entry quality issues
        if (effectiveWR < 0.42)                        return HEAL_TIGHTEN_ENTRY;

        // Too much risk / DD
        if (m_all.maxDrawdown > 10.0)                  return HEAL_REDUCE_RISK;

        // Avg loss too large vs avg win
        double rr = (m_all.avgLoss != 0) ? MathAbs(m_all.avgWin / m_all.avgLoss) : 0;
        if (rr > 0 && rr < 1.3)                        return HEAL_TIGHTEN_SL;
        if (rr > 2.5)                                   return HEAL_WIDEN_SL;

        // Win often but not making money
        if (effectiveWR > 0.60 && effectivePF < 1.5)  return HEAL_WIDEN_TP;

        // Very good performance - relax slightly to get more trades
        if (effectiveWR > 0.60 && effectivePF > 2.0)  return HEAL_RELAX_ENTRY;

        return HEAL_NONE;
    }

    // Recent stats (average of rolling windows)
    double RecentWinRate() {
        int count = MathMin(m_rollIdx, 5);
        if (count == 0) return m_all.winRate;
        double sum = 0;
        for (int i = 0; i < count; i++) {
            if (m_rolling[i].total > 0) sum += m_rolling[i].winRate;
        }
        return sum / count;
    }
    double RecentPF() {
        int count = MathMin(m_rollIdx, 5);
        if (count == 0) return m_all.profitFactor;
        double sum = 0;
        for (int i = 0; i < count; i++) {
            if (m_rolling[i].total > 0) sum += m_rolling[i].profitFactor;
        }
        return sum / count;
    }

    bool DetectConsecLosses(int n) {
        if (m_journalCount < n) return false;
        for (int i = 0; i < n; i++) {
            int idx = ((m_journalIdx - 1 - i) % 100 + 100) % 100;
            if (m_journal[idx] >= 0) return false;
        }
        return true;
    }

    void UpdateRegime(double adx) {
        // Simple regime classification from ADX
        if      (adx > 30) m_regime = REGIME_TRENDING;
        else if (adx < 20) m_regime = REGIME_RANGING;
        else               m_regime = REGIME_UNKNOWN;
    }

    string RegimeStr() {
        switch (m_regime) {
            case REGIME_TRENDING:  return "TRENDING";
            case REGIME_RANGING:   return "RANGING";
            case REGIME_VOLATILE:  return "VOLATILE";
            default:               return "UNKNOWN";
        }
    }

    string ActionStr(HealAction a) {
        switch (a) {
            case HEAL_NONE:           return "NONE";
            case HEAL_TIGHTEN_ENTRY:  return "TIGHTEN_ENTRY";
            case HEAL_RELAX_ENTRY:    return "RELAX_ENTRY";
            case HEAL_WIDEN_TP:       return "WIDEN_TP";
            case HEAL_TIGHTEN_SL:     return "TIGHTEN_SL";
            case HEAL_WIDEN_SL:       return "WIDEN_SL";
            case HEAL_REDUCE_RISK:    return "REDUCE_RISK";
            case HEAL_PAUSE_SHORT:    return "PAUSE_30MIN";
            case HEAL_PAUSE_LONG:     return "PAUSE_2HR";
            case HEAL_FULL_RESET:     return "FULL_RESET";
            default:                  return "?";
        }
    }

    void Log(string msg) {
        string entry = StringFormat("[%s] %s",
            TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), msg);
        Print("[Healer] " + msg);
        if (m_logLines >= m_maxLogLines) return; // Don't flood disk
        int h = FileOpen(m_logFile, FILE_WRITE|FILE_READ|FILE_TXT|FILE_COMMON);
        if (h != INVALID_HANDLE) {
            FileSeek(h, 0, SEEK_END);
            FileWriteString(h, entry + "\n");
            FileClose(h);
            m_logLines++;
        }
    }

    void SaveStats() {
        int h = FileOpen("NexusAI_Stats.csv", FILE_WRITE|FILE_CSV|FILE_COMMON);
        if (h == INVALID_HANDLE) return;
        FileWrite(h, m_all.total, m_all.wins, m_all.losses,
                  DoubleToString(m_all.grossProfit, 2),
                  DoubleToString(m_all.grossLoss, 2),
                  DoubleToString(m_all.winRate, 4),
                  DoubleToString(m_all.profitFactor, 4),
                  DoubleToString(m_all.expectancy, 4),
                  DoubleToString(m_all.kellyPct, 4),
                  TimeToString(TimeCurrent()));
        FileClose(h);
    }

    void LoadStats() {
        int h = FileOpen("NexusAI_Stats.csv", FILE_READ|FILE_CSV|FILE_COMMON);
        if (h == INVALID_HANDLE) return;
        if (!FileIsEnding(h)) {
            m_all.total       = (int)FileReadNumber(h);
            m_all.wins        = (int)FileReadNumber(h);
            m_all.losses      = (int)FileReadNumber(h);
            m_all.grossProfit = FileReadNumber(h);
            m_all.grossLoss   = FileReadNumber(h);
            m_all.winRate     = FileReadNumber(h);
            m_all.profitFactor= FileReadNumber(h);
            m_all.expectancy  = FileReadNumber(h);
            m_all.kellyPct    = FileReadNumber(h);
            Log(StringFormat("Loaded: %d trades | WR=%.1f%% | PF=%.2f",
                m_all.total, m_all.winRate*100, m_all.profitFactor));
        }
        FileClose(h);
    }
};
