//+------------------------------------------------------------------+
//|                                                  SelfHealer.mqh |
//|                           Nexus AI - XAUUSD Scalper Self-Healing |
//|        AI Self-Optimization Engine - Repairs & Improves Strategy |
//+------------------------------------------------------------------+
#pragma once

#include <Files\FileTxt.mqh>

//+------------------------------------------------------------------+
//| Performance Statistics                                           |
//+------------------------------------------------------------------+
struct PerfStats {
    int    totalTrades;
    int    winTrades;
    int    lossTrades;
    double totalProfit;
    double totalLoss;
    double maxDrawdown;
    double winRate;
    double profitFactor;
    double avgWin;
    double avgLoss;
    double expectancy;       // Expected value per trade
    double sharpeRatio;      // Risk-adjusted return
    datetime lastCalc;
    datetime lastOptimize;

    void Reset() {
        totalTrades = 0; winTrades = 0; lossTrades = 0;
        totalProfit = 0; totalLoss = 0; maxDrawdown = 0;
        winRate = 0; profitFactor = 0; avgWin = 0; avgLoss = 0;
        expectancy = 0; sharpeRatio = 0;
        lastCalc = 0; lastOptimize = 0;
    }

    void Recalculate() {
        if (totalTrades == 0) return;
        winRate      = (double)winTrades / totalTrades;
        profitFactor = (totalLoss != 0) ? totalProfit / MathAbs(totalLoss) : totalProfit;
        avgWin       = (winTrades > 0)  ? totalProfit / winTrades  : 0;
        avgLoss      = (lossTrades > 0) ? totalLoss   / lossTrades : 0;
        expectancy   = (winRate * avgWin) + ((1 - winRate) * avgLoss);
        lastCalc     = TimeCurrent();
    }
};

//+------------------------------------------------------------------+
//| Healing Action Types                                             |
//+------------------------------------------------------------------+
enum HealAction {
    HEAL_NONE,
    HEAL_TIGHTEN_ENTRY,    // More restrictive entry conditions
    HEAL_WIDEN_TP,         // Increase take profit target
    HEAL_TIGHTEN_SL,       // Tighter stop loss
    HEAL_REDUCE_RISK,      // Lower risk per trade
    HEAL_PAUSE_TRADING,    // Pause temporarily
    HEAL_RESET_PARAMS,     // Reset to defaults
    HEAL_INCREASE_FILTERS  // Add more filters
};

//+------------------------------------------------------------------+
//| Self Healer Engine                                               |
//+------------------------------------------------------------------+
class CSelfHealer {
private:
    PerfStats m_stats;
    PerfStats m_history[10];    // Rolling 10 optimization cycles
    int       m_historyIdx;
    int       m_historyCount;

    int       m_optimizeCycleTrades;   // Optimize every N trades
    int       m_tradesSinceOptimize;
    datetime  m_lastOptimizeTime;
    int       m_minOptimizeInterval;   // Min seconds between optimizations

    // Degradation detection
    double    m_baselineWinRate;
    double    m_baselinePF;
    bool      m_baselineSet;
    int       m_degradationCount;
    int       m_maxDegradations;

    // Log file
    string    m_logFile;

public:
    CSelfHealer() {
        m_stats.Reset();
        m_historyIdx             = 0;
        m_historyCount           = 0;
        m_optimizeCycleTrades    = 20;  // Check every 20 trades
        m_tradesSinceOptimize    = 0;
        m_lastOptimizeTime       = 0;
        m_minOptimizeInterval    = 3600; // Min 1 hour between optimizations
        m_baselineWinRate        = 0;
        m_baselinePF             = 0;
        m_baselineSet            = false;
        m_degradationCount       = 0;
        m_maxDegradations        = 3;
        m_logFile                = "NexusAI_SelfHeal.log";
    }

    void Init(int cycleTrades = 20) {
        m_optimizeCycleTrades = cycleTrades;
        LoadStats();
        Log("SelfHealer initialized. Total trades in history: " + IntegerToString(m_stats.totalTrades));
    }

    // Record completed trade
    void RecordTrade(double profit, double sl, double tp, int direction, string reason) {
        bool win = (profit > 0);

        if (win) {
            m_stats.winTrades++;
            m_stats.totalProfit += profit;
        } else {
            m_stats.lossTrades++;
            m_stats.totalLoss += profit; // profit is negative here
        }
        m_stats.totalTrades++;
        m_stats.Recalculate();
        m_tradesSinceOptimize++;

        Log(StringFormat("Trade #%d | %s | Profit: %.2f | WR: %.1f%% | PF: %.2f",
            m_stats.totalTrades, win ? "WIN" : "LOSS", profit,
            m_stats.winRate * 100, m_stats.profitFactor));

        // Set baseline after 30 trades
        if (!m_baselineSet && m_stats.totalTrades >= 30) {
            m_baselineWinRate = m_stats.winRate;
            m_baselinePF      = m_stats.profitFactor;
            m_baselineSet     = true;
            Log(StringFormat("Baseline set: WR=%.1f%% PF=%.2f",
                m_baselineWinRate * 100, m_baselinePF));
        }

        SaveStats();
    }

    // Should we optimize now?
    bool ShouldOptimize() {
        if (m_stats.totalTrades < 15) return false;
        if (m_tradesSinceOptimize < m_optimizeCycleTrades) return false;
        if ((TimeCurrent() - m_lastOptimizeTime) < m_minOptimizeInterval) return false;
        return true;
    }

    // Main self-healing analysis - returns recommended action
    HealAction Analyze() {
        m_stats.Recalculate();
        m_tradesSinceOptimize = 0;
        m_lastOptimizeTime    = TimeCurrent();

        Log("=== SELF-HEAL ANALYSIS ===");
        Log(StringFormat("Stats: Trades=%d WR=%.1f%% PF=%.2f Expectancy=%.2f",
            m_stats.totalTrades, m_stats.winRate*100, m_stats.profitFactor, m_stats.expectancy));

        // Store in history
        m_history[m_historyIdx % 10] = m_stats;
        m_historyIdx++;
        if (m_historyCount < 10) m_historyCount++;

        HealAction action = DetermineAction();
        Log(StringFormat("Heal action: %s", ActionToString(action)));
        return action;
    }

    // Get current stats
    PerfStats GetStats() { return m_stats; }

    // Detect if performance is degrading vs baseline
    bool IsPerformanceDegrading() {
        if (!m_baselineSet || m_stats.totalTrades < 40) return false;
        bool wrDrop = (m_stats.winRate < m_baselineWinRate * 0.85);
        bool pfDrop = (m_stats.profitFactor < m_baselinePF * 0.80);
        return wrDrop || pfDrop;
    }

    // Get healing recommendation as text
    string GetRecommendation() {
        HealAction a = Analyze();
        switch (a) {
            case HEAL_TIGHTEN_ENTRY:   return "Tighten entry criteria - win rate low";
            case HEAL_WIDEN_TP:        return "Widen take profit - profit factor low";
            case HEAL_TIGHTEN_SL:      return "Tighten stop loss - avg loss too large";
            case HEAL_REDUCE_RISK:     return "Reduce risk per trade - drawdown elevated";
            case HEAL_PAUSE_TRADING:   return "Pause trading - critical performance degradation";
            case HEAL_RESET_PARAMS:    return "Reset parameters - all metrics poor";
            case HEAL_INCREASE_FILTERS: return "Add more filters - too many false signals";
            default:                   return "Performance OK - no action needed";
        }
    }

    string GetStatsReport() {
        return StringFormat(
            "=== NEXUS AI STATS ===\n"
            "Total Trades: %d\n"
            "Win Rate: %.1f%% (%d/%d)\n"
            "Profit Factor: %.2f\n"
            "Total P&L: %.2f\n"
            "Avg Win: %.2f | Avg Loss: %.2f\n"
            "Expectancy: %.2f/trade\n"
            "Degrading: %s\n"
            "======================",
            m_stats.totalTrades,
            m_stats.winRate * 100, m_stats.winTrades, m_stats.totalTrades,
            m_stats.profitFactor,
            m_stats.totalProfit + m_stats.totalLoss,
            m_stats.avgWin, m_stats.avgLoss,
            m_stats.expectancy,
            IsPerformanceDegrading() ? "YES !!!" : "No"
        );
    }

private:
    HealAction DetermineAction() {
        double wr = m_stats.winRate;
        double pf = m_stats.profitFactor;

        // Critical conditions
        if (wr < 0.30 && pf < 1.0) {
            m_degradationCount++;
            if (m_degradationCount >= m_maxDegradations) return HEAL_RESET_PARAMS;
            return HEAL_PAUSE_TRADING;
        }

        if (IsPerformanceDegrading()) {
            m_degradationCount++;
            Log(StringFormat("Degradation detected (#%d)", m_degradationCount));
        } else {
            m_degradationCount = MathMax(0, m_degradationCount - 1);
        }

        // Specific conditions
        if (wr < 0.42) return HEAL_TIGHTEN_ENTRY;
        if (pf < 1.3 && wr > 0.50) return HEAL_WIDEN_TP;
        if (MathAbs(m_stats.avgLoss) > m_stats.avgWin * 2.0) return HEAL_TIGHTEN_SL;
        if (m_stats.maxDrawdown > 8.0) return HEAL_REDUCE_RISK;
        if (m_stats.totalTrades > 50 && wr < 0.48) return HEAL_INCREASE_FILTERS;

        return HEAL_NONE;
    }

    string ActionToString(HealAction a) {
        switch (a) {
            case HEAL_NONE:             return "NONE";
            case HEAL_TIGHTEN_ENTRY:    return "TIGHTEN_ENTRY";
            case HEAL_WIDEN_TP:         return "WIDEN_TP";
            case HEAL_TIGHTEN_SL:       return "TIGHTEN_SL";
            case HEAL_REDUCE_RISK:      return "REDUCE_RISK";
            case HEAL_PAUSE_TRADING:    return "PAUSE_TRADING";
            case HEAL_RESET_PARAMS:     return "RESET_PARAMS";
            case HEAL_INCREASE_FILTERS: return "INCREASE_FILTERS";
            default:                    return "UNKNOWN";
        }
    }

    void Log(string msg) {
        string logEntry = StringFormat("[%s] %s", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), msg);
        Print("[SelfHealer] " + msg);
        // Append to log file
        int handle = FileOpen(m_logFile, FILE_WRITE | FILE_READ | FILE_TXT | FILE_COMMON);
        if (handle != INVALID_HANDLE) {
            FileSeek(handle, 0, SEEK_END);
            FileWriteString(handle, logEntry + "\n");
            FileClose(handle);
        }
    }

    void SaveStats() {
        int handle = FileOpen("NexusAI_Stats.csv", FILE_WRITE | FILE_CSV | FILE_COMMON);
        if (handle != INVALID_HANDLE) {
            FileWrite(handle, m_stats.totalTrades, m_stats.winTrades, m_stats.lossTrades,
                      DoubleToString(m_stats.totalProfit, 2),
                      DoubleToString(m_stats.totalLoss, 2),
                      DoubleToString(m_stats.winRate, 4),
                      DoubleToString(m_stats.profitFactor, 4),
                      DoubleToString(m_stats.expectancy, 4),
                      TimeToString(TimeCurrent()));
            FileClose(handle);
        }
    }

    void LoadStats() {
        int handle = FileOpen("NexusAI_Stats.csv", FILE_READ | FILE_CSV | FILE_COMMON);
        if (handle == INVALID_HANDLE) return;
        if (!FileIsEnding(handle)) {
            m_stats.totalTrades  = (int)FileReadNumber(handle);
            m_stats.winTrades    = (int)FileReadNumber(handle);
            m_stats.lossTrades   = (int)FileReadNumber(handle);
            m_stats.totalProfit  = FileReadNumber(handle);
            m_stats.totalLoss    = FileReadNumber(handle);
            m_stats.winRate      = FileReadNumber(handle);
            m_stats.profitFactor = FileReadNumber(handle);
            m_stats.expectancy   = FileReadNumber(handle);
            Log(StringFormat("Loaded saved stats: %d trades", m_stats.totalTrades));
        }
        FileClose(handle);
    }
};
