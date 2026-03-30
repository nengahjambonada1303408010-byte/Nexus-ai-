//+------------------------------------------------------------------+
//|                                                  RiskManager.mqh |
//|                          Nexus AI v3 - XAUUSD Aggressive Scalper |
//|  Features: Kelly criterion lot sizing, Tiered recovery,         |
//|            Compound mode, Calmar/Sortino metrics                 |
//+------------------------------------------------------------------+
#pragma once

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Risk Manager                                                     |
//+------------------------------------------------------------------+
class CRiskManager {
private:
    // Settings
    double m_riskPct;
    double m_maxDailyLossPct;
    double m_maxDrawdownPct;
    int    m_maxConsecLoss;
    int    m_maxDailyTrades;
    bool   m_compoundMode;      // Risk grows with balance if true

    // State
    double   m_startBalance;
    double   m_dailyStartBal;
    double   m_peakBalance;
    datetime m_lastDayReset;

    // Streak tracking
    int  m_consecLosses;
    int  m_consecWins;
    int  m_dailyTrades;
    int  m_dailyWins;
    int  m_dailyLosses;

    // Recovery tiers
    // 0=normal, 1=caution(75%), 2=recovery(50%), 3=minimal(25%)
    int  m_recoveryTier;
    int  m_recoveryTradesLeft;

    // Halt
    bool   m_halted;
    string m_haltCode;

    // Kelly tracking
    double m_kellyWinRate;
    double m_kellyAvgWin;
    double m_kellyAvgLoss;
    int    m_kellyN;           // Samples for Kelly estimate

    // Daily P&L history for Sortino
    double m_dailyPnL[30];
    int    m_dailyPnLIdx;
    int    m_dailyPnLCount;

public:
    CRiskManager() {
        m_riskPct          = 1.0;
        m_maxDailyLossPct  = 5.0;
        m_maxDrawdownPct   = 15.0;
        m_maxConsecLoss    = 5;
        m_maxDailyTrades   = 30;
        m_compoundMode     = true;
        m_consecLosses     = 0;
        m_consecWins       = 0;
        m_dailyTrades      = 0;
        m_dailyWins        = 0;
        m_dailyLosses      = 0;
        m_recoveryTier     = 0;
        m_recoveryTradesLeft = 0;
        m_halted           = false;
        m_haltCode         = "";
        m_kellyWinRate     = 0.5;
        m_kellyAvgWin      = 1.0;
        m_kellyAvgLoss     = 1.0;
        m_kellyN           = 0;
        m_dailyPnLIdx      = 0;
        m_dailyPnLCount    = 0;
        m_startBalance     = 0;
        m_dailyStartBal    = 0;
        m_peakBalance      = 0;
        m_lastDayReset     = 0;
    }

    void Init(double riskPct, double maxDaily, double maxDD,
              int maxConsec, int maxDaily_trades, bool compound = true) {
        m_riskPct         = riskPct;
        m_maxDailyLossPct = maxDaily;
        m_maxDrawdownPct  = maxDD;
        m_maxConsecLoss   = maxConsec;
        m_maxDailyTrades  = maxDaily_trades;
        m_compoundMode    = compound;
        m_startBalance    = AccountInfoDouble(ACCOUNT_BALANCE);
        m_dailyStartBal   = m_startBalance;
        m_peakBalance     = m_startBalance;
        m_lastDayReset    = TimeCurrent();
        PrintFormat("[RiskMgr] Init: Risk=%.1f%% MaxDD=%.1f%% Compound=%s",
                    riskPct, maxDD, compound ? "ON" : "OFF");
    }

    void Update() {
        CheckDailyReset();
        double bal = AccountInfoDouble(ACCOUNT_BALANCE);
        if (bal > m_peakBalance) m_peakBalance = bal;
        CheckEmergency(bal);
    }

    //+----------------------------------------------------------------+
    //| Lot sizing: Kelly-blended with fixed-fraction                  |
    //+----------------------------------------------------------------+
    double CalcLotSize(double slPips, double atrValue, double signalStrength = 1.0) {
        if (m_halted) return 0;
        if (slPips <= 0) return 0;

        double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
        double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

        // Use fixed-fraction risk as base
        double baseRisk  = m_riskPct / 100.0;

        // Kelly criterion blend (only when we have enough history)
        if (m_kellyN >= 30) {
            double kelly = KellyCriterion();
            // Half-Kelly for safety, blended 30% Kelly / 70% fixed
            baseRisk = baseRisk * 0.70 + (kelly * 0.5) * 0.30;
            baseRisk = MathMin(baseRisk, m_riskPct * 2.0 / 100.0); // cap at 2x
        }

        // Signal strength modifier: strong signal = slightly more
        baseRisk *= (0.8 + signalStrength * 0.4); // 0.8x to 1.2x based on strength

        // Recovery tier reduction
        double tierMult[] = {1.0, 0.75, 0.50, 0.25};
        baseRisk *= tierMult[m_recoveryTier];

        double riskAmount = balance * baseRisk;
        double pipValue   = (tickVal / tickSize) * point;
        double lot        = riskAmount / (slPips * pipValue);

        // Normalize
        double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
        double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
        double step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
        lot = MathMax(minLot, MathMin(maxLot, MathFloor(lot / step) * step));

        return NormalizeDouble(lot, 2);
    }

    void RecordTrade(bool win, double profit) {
        m_dailyTrades++;
        if (win) {
            m_dailyWins++;
            m_consecLosses = 0;
            m_consecWins++;
            UpdateKelly(true, MathAbs(profit));
            // Step down recovery tier if performing well
            if (m_recoveryTier > 0) {
                m_recoveryTradesLeft--;
                if (m_recoveryTradesLeft <= 0) {
                    m_recoveryTier = MathMax(0, m_recoveryTier - 1);
                    m_recoveryTradesLeft = 5;
                    PrintFormat("[RiskMgr] Recovery improved → Tier %d", m_recoveryTier);
                }
            }
        } else {
            m_dailyLosses++;
            m_consecWins  = 0;
            m_consecLosses++;
            UpdateKelly(false, MathAbs(profit));
            // Escalate recovery tier
            if (m_consecLosses >= m_maxConsecLoss) {
                int newTier = MathMin(3, m_recoveryTier + 1);
                if (newTier != m_recoveryTier) {
                    m_recoveryTier       = newTier;
                    m_recoveryTradesLeft = 5 * m_recoveryTier;
                    PrintFormat("[RiskMgr] !!! RECOVERY TIER %d (%.0f%% lot) after %d consec losses",
                        m_recoveryTier, tierMult(m_recoveryTier) * 100, m_consecLosses);
                }
                m_consecLosses = 0; // Reset counter per tier
            }
        }
        PrintFormat("[RiskMgr] Trade: %s $%.2f | Streak: %d | Tier: %d | Daily: %dW/%dL",
            win ? "WIN" : "LOSS", profit,
            win ? m_consecWins : -m_consecLosses,
            m_recoveryTier, m_dailyWins, m_dailyLosses);
    }

    bool CanTrade() {
        if (m_halted)                          { Print("[RiskMgr] HALTED: " + m_haltCode); return false; }
        if (m_dailyTrades >= m_maxDailyTrades) { Print("[RiskMgr] Daily trade limit reached"); return false; }
        return true;
    }

    // ── Metrics ──────────────────────────────────────────────────
    double GetDrawdown() {
        double bal = AccountInfoDouble(ACCOUNT_BALANCE);
        return m_peakBalance > 0 ? (m_peakBalance - bal) / m_peakBalance * 100.0 : 0;
    }
    double GetDailyPnLPct() {
        double bal = AccountInfoDouble(ACCOUNT_BALANCE);
        return m_dailyStartBal > 0 ? (bal - m_dailyStartBal) / m_dailyStartBal * 100.0 : 0;
    }
    double GetSortino() {
        if (m_dailyPnLCount < 5) return 0;
        double mean = 0, negVar = 0;
        for (int i = 0; i < m_dailyPnLCount; i++) mean += m_dailyPnL[i];
        mean /= m_dailyPnLCount;
        int negCnt = 0;
        for (int i = 0; i < m_dailyPnLCount; i++) {
            if (m_dailyPnL[i] < 0) { negVar += m_dailyPnL[i] * m_dailyPnL[i]; negCnt++; }
        }
        if (negCnt == 0) return 99.0;
        double downDev = MathSqrt(negVar / negCnt);
        return downDev > 0 ? mean / downDev : 0;
    }

    bool   IsTradingHalted()  { return m_halted; }
    bool   IsInRecovery()     { return m_recoveryTier > 0; }
    int    GetRecoveryTier()  { return m_recoveryTier; }
    int    GetConsecLosses()  { return m_consecLosses; }
    int    GetConsecWins()    { return m_consecWins; }
    int    GetDailyTrades()   { return m_dailyTrades; }
    int    GetDailyWins()     { return m_dailyWins; }
    int    GetDailyLosses()   { return m_dailyLosses; }
    string GetHaltCode()      { return m_haltCode; }

    void   ResetHalt() {
        m_halted = false; m_haltCode = "";
        m_consecLosses = 0; m_recoveryTier = 0;
        Print("[RiskMgr] Halt manually reset");
    }

private:
    double tierMult(int tier) {
        double m[] = {1.0, 0.75, 0.50, 0.25};
        return m[MathMin(tier, 3)];
    }

    void CheckDailyReset() {
        MqlDateTime now, last;
        TimeToStruct(TimeCurrent(), now);
        TimeToStruct(m_lastDayReset, last);
        if (now.day != last.day) {
            // Record daily PnL for Sortino
            double dayPnL = AccountInfoDouble(ACCOUNT_BALANCE) - m_dailyStartBal;
            m_dailyPnL[m_dailyPnLIdx % 30] = dayPnL;
            m_dailyPnLIdx++;
            if (m_dailyPnLCount < 30) m_dailyPnLCount++;

            m_dailyStartBal  = AccountInfoDouble(ACCOUNT_BALANCE);
            m_dailyTrades    = 0;
            m_dailyWins      = 0;
            m_dailyLosses    = 0;
            m_lastDayReset   = TimeCurrent();
            if (m_halted && m_haltCode == "DAILY_LOSS") {
                m_halted = false; m_haltCode = "";
                Print("[RiskMgr] New day - daily halt lifted");
            }
            Print("[RiskMgr] Daily reset | Yesterday PnL: $" + DoubleToString(dayPnL, 2));
        }
    }

    void CheckEmergency(double bal) {
        double dailyLossPct = (m_dailyStartBal - bal) / m_dailyStartBal * 100.0;
        if (dailyLossPct >= m_maxDailyLossPct) {
            Halt("DAILY_LOSS", StringFormat("Daily loss %.2f%% >= %.2f%%",
                 dailyLossPct, m_maxDailyLossPct));
            return;
        }
        double dd = GetDrawdown();
        if (dd >= m_maxDrawdownPct) {
            Halt("MAX_DRAWDOWN", StringFormat("DD %.2f%% >= %.2f%%", dd, m_maxDrawdownPct));
        }
    }

    void Halt(string code, string reason) {
        if (!m_halted) {
            m_halted = true; m_haltCode = code;
            PrintFormat("[RiskMgr] !!! HALT: %s | %s !!!", code, reason);
        }
    }

    double KellyCriterion() {
        if (m_kellyAvgLoss == 0) return 0.01;
        double b = m_kellyAvgWin / m_kellyAvgLoss; // win/loss ratio
        double p = m_kellyWinRate;
        double q = 1.0 - p;
        double kelly = (b * p - q) / b;
        return MathMax(0.001, MathMin(0.05, kelly)); // cap 0.1% to 5%
    }

    void UpdateKelly(bool win, double amount) {
        // Exponential moving average for Kelly estimate
        double alpha = 2.0 / (MathMin(m_kellyN + 1, 50) + 1.0);
        if (win) {
            m_kellyWinRate = m_kellyWinRate * (1 - alpha) + alpha;
            m_kellyAvgWin  = m_kellyAvgWin  * (1 - alpha) + amount * alpha;
        } else {
            m_kellyWinRate = m_kellyWinRate * (1 - alpha);
            m_kellyAvgLoss = m_kellyAvgLoss * (1 - alpha) + amount * alpha;
        }
        m_kellyN++;
    }
};
