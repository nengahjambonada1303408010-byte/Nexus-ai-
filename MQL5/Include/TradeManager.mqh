//+------------------------------------------------------------------+
//|                                                 TradeManager.mqh |
//|                           Nexus AI - XAUUSD Scalper Self-Healing |
//|                    Trade execution, management & trailing system  |
//+------------------------------------------------------------------+
#pragma once

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//+------------------------------------------------------------------+
//| Trade Manager Class                                              |
//+------------------------------------------------------------------+
class CTradeManager {
private:
    CTrade        m_trade;
    CPositionInfo m_position;
    ulong         m_magic;
    int           m_maxSlippage;
    bool          m_trailingActive;
    double        m_trailStartPips;   // Activate trailing after X pips profit
    double        m_trailStepPips;    // Trail by X pips
    double        m_breakEvenPips;    // Move SL to BE after X pips profit

    // Last closed trade info for self-healer
    double        m_lastClosedProfit;
    bool          m_lastWasWin;

public:
    CTradeManager() {
        m_magic          = 202401;
        m_maxSlippage    = 30;       // 30 points slippage for gold
        m_trailingActive = true;
        m_trailStartPips = 15;       // Start trailing after 15 pips
        m_trailStepPips  = 8;        // Trail 8 pips
        m_breakEvenPips  = 10;       // Break-even after 10 pips
        m_lastClosedProfit = 0;
        m_lastWasWin = false;
    }

    void Init(ulong magic, int slippage, double trailStart, double trailStep, double breakEven) {
        m_magic          = magic;
        m_maxSlippage    = slippage;
        m_trailStartPips = trailStart;
        m_trailStepPips  = trailStep;
        m_breakEvenPips  = breakEven;

        m_trade.SetExpertMagicNumber(magic);
        m_trade.SetDeviationInPoints(slippage);
        m_trade.SetTypeFilling(ORDER_FILLING_IOC);
        m_trade.LogLevel(LOG_LEVEL_ERRORS);

        Print(StringFormat("[TradeMgr] Init: Magic=%d Slippage=%d", magic, slippage));
    }

    // Open a new position
    bool OpenTrade(int direction, double lot, double sl, double tp,
                   string comment = "NexusAI") {
        if (HasOpenPosition()) {
            Print("[TradeMgr] Already have open position, skipping");
            return false;
        }
        if (lot <= 0) {
            Print("[TradeMgr] Invalid lot size");
            return false;
        }

        // Normalize prices
        int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
        sl = NormalizeDouble(sl, digits);
        tp = NormalizeDouble(tp, digits);

        bool result = false;
        if (direction == 1) {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            result = m_trade.Buy(lot, _Symbol, ask, sl, tp, comment);
        } else if (direction == -1) {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            result = m_trade.Sell(lot, _Symbol, bid, sl, tp, comment);
        }

        if (result) {
            PrintFormat("[TradeMgr] Opened %s %.2f lots @ %.5f SL=%.5f TP=%.5f",
                direction == 1 ? "BUY" : "SELL", lot,
                direction == 1 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID),
                sl, tp);
        } else {
            PrintFormat("[TradeMgr] OPEN FAILED: %s (code: %d)",
                m_trade.ResultComment(), m_trade.ResultRetcode());
        }
        return result;
    }

    // Close all open positions for this EA
    bool CloseAll(string reason = "") {
        bool allClosed = true;
        for (int i = PositionsTotal() - 1; i >= 0; i--) {
            if (m_position.SelectByIndex(i)) {
                if (m_position.Magic() == m_magic && m_position.Symbol() == _Symbol) {
                    if (!m_trade.PositionClose(m_position.Ticket())) {
                        PrintFormat("[TradeMgr] Close failed: %s", m_trade.ResultComment());
                        allClosed = false;
                    } else {
                        PrintFormat("[TradeMgr] Closed position #%d %s",
                            m_position.Ticket(), reason);
                    }
                }
            }
        }
        return allClosed;
    }

    // Manage open positions: trailing stop & break-even
    void ManagePositions() {
        double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

        for (int i = PositionsTotal() - 1; i >= 0; i--) {
            if (!m_position.SelectByIndex(i)) continue;
            if (m_position.Magic() != m_magic) continue;
            if (m_position.Symbol() != _Symbol) continue;

            double openPrice = m_position.PriceOpen();
            double currentSL = m_position.StopLoss();
            double currentTP = m_position.TakeProfit();
            double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            ulong  ticket    = m_position.Ticket();

            if (m_position.PositionType() == POSITION_TYPE_BUY) {
                double pipsProfit = (bid - openPrice) / point;

                // Break-even
                if (pipsProfit >= m_breakEvenPips && currentSL < openPrice + point) {
                    double newSL = NormalizeDouble(openPrice + point * 2, _Digits);
                    if (newSL > currentSL) {
                        m_trade.PositionModify(ticket, newSL, currentTP);
                        Print("[TradeMgr] BUY Break-even set");
                    }
                }

                // Trailing stop
                if (m_trailingActive && pipsProfit >= m_trailStartPips) {
                    double newSL = NormalizeDouble(bid - point * m_trailStepPips, _Digits);
                    if (newSL > currentSL + point) {
                        m_trade.PositionModify(ticket, newSL, currentTP);
                    }
                }
            }
            else if (m_position.PositionType() == POSITION_TYPE_SELL) {
                double pipsProfit = (openPrice - ask) / point;

                // Break-even
                if (pipsProfit >= m_breakEvenPips && (currentSL > openPrice - point || currentSL == 0)) {
                    double newSL = NormalizeDouble(openPrice - point * 2, _Digits);
                    if (newSL < currentSL || currentSL == 0) {
                        m_trade.PositionModify(ticket, newSL, currentTP);
                        Print("[TradeMgr] SELL Break-even set");
                    }
                }

                // Trailing stop
                if (m_trailingActive && pipsProfit >= m_trailStartPips) {
                    double newSL = NormalizeDouble(ask + point * m_trailStepPips, _Digits);
                    if (newSL < currentSL - point || currentSL == 0) {
                        m_trade.PositionModify(ticket, newSL, currentTP);
                    }
                }
            }
        }
    }

    // Check if we have an open position
    bool HasOpenPosition() {
        for (int i = 0; i < PositionsTotal(); i++) {
            if (m_position.SelectByIndex(i)) {
                if (m_position.Magic() == m_magic && m_position.Symbol() == _Symbol)
                    return true;
            }
        }
        return false;
    }

    // Get profit of open position
    double GetOpenProfit() {
        for (int i = 0; i < PositionsTotal(); i++) {
            if (m_position.SelectByIndex(i)) {
                if (m_position.Magic() == m_magic && m_position.Symbol() == _Symbol)
                    return m_position.Profit() + m_position.Swap() + m_position.Commission();
            }
        }
        return 0;
    }

    // Check last closed trade result
    bool CheckLastClosedTrade(double &profit) {
        uint total = HistoryDealsTotal();
        if (total == 0) return false;

        for (int i = total - 1; i >= 0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if (HistoryDealGetInteger(ticket, DEAL_MAGIC) != m_magic) continue;
            if (HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
            if (HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

            profit = HistoryDealGetDouble(ticket, DEAL_PROFIT) +
                     HistoryDealGetDouble(ticket, DEAL_SWAP) +
                     HistoryDealGetDouble(ticket, DEAL_COMMISSION);
            return true;
        }
        return false;
    }

    // Scan recent history for completed trades (called periodically)
    int ScanRecentTrades(int lookback, double &profits[]) {
        HistorySelect(TimeCurrent() - lookback * 86400, TimeCurrent());
        int count = 0;
        uint total = HistoryDealsTotal();
        ArrayResize(profits, 0);

        for (uint i = 0; i < total; i++) {
            ulong ticket = HistoryDealGetTicket(i);
            if (HistoryDealGetInteger(ticket, DEAL_MAGIC) != m_magic) continue;
            if (HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
            if (HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

            double p = HistoryDealGetDouble(ticket, DEAL_PROFIT) +
                       HistoryDealGetDouble(ticket, DEAL_SWAP)   +
                       HistoryDealGetDouble(ticket, DEAL_COMMISSION);
            ArrayResize(profits, count + 1);
            profits[count] = p;
            count++;
        }
        return count;
    }

    ulong GetMagic() { return m_magic; }
};
