//+------------------------------------------------------------------+
//|                                                  RiskManager.mqh |
//|                           Nexus AI - XAUUSD Scalper Self-Healing |
//|                                   Dynamic Risk & Money Management |
//+------------------------------------------------------------------+
#pragma once

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//| Risk Manager Class                                               |
//+------------------------------------------------------------------+
class CRiskManager {
private:
    double   m_riskPercent;       // % of balance per trade
    double   m_maxDailyLoss;      // Max daily loss %
    double   m_maxDrawdown;       // Max total drawdown %
    double   m_startBalance;      // Balance at session start
    double   m_dailyStartBalance; // Balance at day start
    double   m_peakBalance;       // Highest balance ever reached
    int      m_maxConsecLoss;     // Max consecutive losses allowed
    int      m_consecLosses;      // Current consecutive losses
    int      m_dailyTrades;       // Trades today
    int      m_maxDailyTrades;    // Max trades per day
    datetime m_lastDayReset;      // Last daily reset time
    bool     m_tradingHalted;     // Emergency halt flag
    string   m_haltReason;        // Why trading was halted

    // Self-healing state
    double   m_recoveryMultiplier; // Lot multiplier in recovery mode
    bool     m_inRecovery;
    int      m_recoveryTradesLeft;

public:
    CRiskManager() {
        m_riskPercent       = 1.0;
        m_maxDailyLoss      = 5.0;
        m_maxDrawdown       = 15.0;
        m_maxConsecLoss     = 5;
        m_maxDailyTrades    = 30;
        m_consecLosses      = 0;
        m_dailyTrades       = 0;
        m_tradingHalted     = false;
        m_haltReason        = "";
        m_recoveryMultiplier = 1.0;
        m_inRecovery        = false;
        m_recoveryTradesLeft = 0;
        m_lastDayReset      = 0;
        m_peakBalance       = 0;
    }

    // Initialize with account balance
    void Init(double riskPct, double maxDailyLossPct, double maxDD, int maxConsec, int maxDailyTrades) {
        m_riskPercent       = riskPct;
        m_maxDailyLoss      = maxDailyLossPct;
        m_maxDrawdown       = maxDD;
        m_maxConsecLoss     = maxConsec;
        m_maxDailyTrades    = maxDailyTrades;
        m_startBalance      = AccountInfoDouble(ACCOUNT_BALANCE);
        m_dailyStartBalance = m_startBalance;
        m_peakBalance       = m_startBalance;
        m_lastDayReset      = TimeCurrent();
    }

    // Called every tick - update state
    void Update() {
        CheckDailyReset();
        double balance = AccountInfoDouble(ACCOUNT_BALANCE);
        if (balance > m_peakBalance) m_peakBalance = balance;
        CheckEmergencyConditions(balance);
    }

    // Calculate lot size based on ATR and risk
    double CalcLotSize(double slPips, double atrValue) {
        if (m_tradingHalted) return 0;

        double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
        double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double pointVal  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

        // Use wider of: fixed SL or ATR-based SL
        double effectiveSL = MathMax(slPips, atrValue / pointVal * 0.5);

        double riskAmount = balance * (m_riskPercent / 100.0);
        if (m_inRecovery) riskAmount *= m_recoveryMultiplier;

        double pipValue  = (tickValue / tickSize) * pointVal;
        double lot       = riskAmount / (effectiveSL * pipValue);

        // Normalize lot
        double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
        double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
        double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

        lot = MathMax(minLot, MathMin(maxLot, lot));
        lot = MathFloor(lot / lotStep) * lotStep;

        return NormalizeDouble(lot, 2);
    }

    // Record trade result for self-healing
    void RecordTrade(bool win, double profit) {
        m_dailyTrades++;
        if (win) {
            m_consecLosses = 0;
            if (m_inRecovery) {
                m_recoveryTradesLeft--;
                if (m_recoveryTradesLeft <= 0) ExitRecovery();
            }
        } else {
            m_consecLosses++;
            if (m_consecLosses >= m_maxConsecLoss) {
                EnterRecovery();
            }
        }
        PrintFormat("[RiskMgr] Trade recorded: %s | Profit: %.2f | Consec losses: %d",
                    win ? "WIN" : "LOSS", profit, m_consecLosses);
    }

    // Check if allowed to trade
    bool CanTrade() {
        if (m_tradingHalted) {
            PrintFormat("[RiskMgr] Trading HALTED: %s", m_haltReason);
            return false;
        }
        if (m_dailyTrades >= m_maxDailyTrades) {
            Print("[RiskMgr] Max daily trades reached");
            return false;
        }
        return true;
    }

    bool  IsTradingHalted() { return m_tradingHalted; }
    bool  IsInRecovery()    { return m_inRecovery; }
    int   GetConsecLosses() { return m_consecLosses; }
    int   GetDailyTrades()  { return m_dailyTrades; }
    double GetDrawdown() {
        double balance = AccountInfoDouble(ACCOUNT_BALANCE);
        if (m_peakBalance <= 0) return 0;
        return (m_peakBalance - balance) / m_peakBalance * 100.0;
    }

    void ResetHalt() {
        m_tradingHalted = false;
        m_haltReason    = "";
        m_consecLosses  = 0;
        Print("[RiskMgr] Trading halt RESET manually");
    }

private:
    void CheckDailyReset() {
        MqlDateTime nowDt, lastDt;
        TimeToStruct(TimeCurrent(),    nowDt);
        TimeToStruct(m_lastDayReset,   lastDt);
        if (nowDt.day != lastDt.day) {
            m_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
            m_dailyTrades       = 0;
            m_lastDayReset      = TimeCurrent();
            if (m_tradingHalted && m_haltReason == "DAILY_LOSS") {
                m_tradingHalted = false;
                m_haltReason    = "";
                m_consecLosses  = 0;
                Print("[RiskMgr] New day - daily loss halt lifted");
            }
            Print("[RiskMgr] Daily stats reset");
        }
    }

    void CheckEmergencyConditions(double balance) {
        // Daily loss check
        double dailyLossPct = (m_dailyStartBalance - balance) / m_dailyStartBalance * 100.0;
        if (dailyLossPct >= m_maxDailyLoss) {
            HaltTrading("DAILY_LOSS",
                StringFormat("Daily loss %.2f%% >= limit %.2f%%", dailyLossPct, m_maxDailyLoss));
            return;
        }
        // Max drawdown check
        double dd = GetDrawdown();
        if (dd >= m_maxDrawdown) {
            HaltTrading("MAX_DRAWDOWN",
                StringFormat("Drawdown %.2f%% >= limit %.2f%%", dd, m_maxDrawdown));
        }
    }

    void HaltTrading(string code, string reason) {
        if (!m_tradingHalted) {
            m_tradingHalted = true;
            m_haltReason    = code;
            PrintFormat("[RiskMgr] !!! TRADING HALTED !!! Reason: %s", reason);
        }
    }

    void EnterRecovery() {
        m_inRecovery         = true;
        m_recoveryMultiplier = 0.5; // Reduce size in recovery
        m_recoveryTradesLeft = 5;
        PrintFormat("[RiskMgr] Entering RECOVERY MODE after %d consecutive losses", m_consecLosses);
    }

    void ExitRecovery() {
        m_inRecovery         = false;
        m_recoveryMultiplier = 1.0;
        m_recoveryTradesLeft = 0;
        Print("[RiskMgr] Exiting RECOVERY MODE - performance restored");
    }
};
