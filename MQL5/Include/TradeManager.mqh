//+------------------------------------------------------------------+
//|                                                 TradeManager.mqh |
//|                          Nexus AI v3 - XAUUSD Aggressive Scalper |
//|  Features: Dual-TP partial close, Dynamic ATR trailing,         |
//|            Pyramid add-on, Multi-position management            |
//+------------------------------------------------------------------+
#pragma once

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//+------------------------------------------------------------------+
//| Position lifecycle state                                         |
//+------------------------------------------------------------------+
enum PositionState {
    POS_STATE_OPEN,
    POS_STATE_BREAKEVEN,  // SL moved to BE
    POS_STATE_TP1_HIT,    // 50% closed, runner active
    POS_STATE_TRAILING    // Full trailing mode
};

struct ManagedPosition {
    ulong          ticket;
    PositionState  state;
    double         openPrice;
    double         originalSL;
    double         tp1;
    double         tp2;
    double         lotOriginal;
    bool           tp1Closed;
    datetime       openTime;
};

//+------------------------------------------------------------------+
//| Trade Manager                                                    |
//+------------------------------------------------------------------+
class CTradeManager {
private:
    CTrade        m_trade;
    CPositionInfo m_pos;
    ulong         m_magic;

    // Position tracking
    ManagedPosition m_positions[10];
    int             m_posCount;

    // Trade settings
    int    m_slippage;
    double m_trailAtrMult;    // Trail distance = ATR * this
    double m_beAtrMult;       // Break-even after ATR * this profit
    double m_tp1Ratio;        // Close 50% at TP1 (default 0.5)
    bool   m_pyramidEnabled;
    double m_pyramidThreshold; // Add at ATR * X in profit
    double m_pyramidLotRatio;  // Pyramid lot as fraction of original

    // Stats
    int    m_tradesOpened;
    int    m_tp1Hits;
    int    m_pyramidAdds;

public:
    CTradeManager() {
        m_magic            = 202401;
        m_slippage         = 30;
        m_trailAtrMult     = 1.0;     // Trail at 1x ATR
        m_beAtrMult        = 0.8;     // BE after 0.8 ATR profit
        m_tp1Ratio         = 0.5;     // Close 50% at TP1
        m_pyramidEnabled   = true;
        m_pyramidThreshold = 1.5;     // Add at 1.5 ATR profit
        m_pyramidLotRatio  = 0.5;     // Pyramid = 50% of original lot
        m_posCount         = 0;
        m_tradesOpened     = 0;
        m_tp1Hits          = 0;
        m_pyramidAdds      = 0;
    }

    void Init(ulong magic, int slippage, double trailMult, double beMult,
              bool pyramid, double pyramidThresh) {
        m_magic            = magic;
        m_slippage         = slippage;
        m_trailAtrMult     = trailMult;
        m_beAtrMult        = beMult;
        m_pyramidEnabled   = pyramid;
        m_pyramidThreshold = pyramidThresh;

        m_trade.SetExpertMagicNumber(magic);
        m_trade.SetDeviationInPoints(slippage);
        m_trade.SetTypeFilling(ORDER_FILLING_IOC);
        m_trade.LogLevel(LOG_LEVEL_ERRORS);

        PrintFormat("[TradeMgr] v3 | Magic=%d | Pyramid=%s | TrailMult=%.1f",
                    magic, pyramid ? "ON" : "OFF", trailMult);
    }

    // Open trade with dual TP
    bool OpenTrade(int direction, double lot, double sl,
                   double tp1, double tp2, string comment = "NexusAI") {
        if (lot <= 0) { Print("[TradeMgr] Invalid lot"); return false; }

        int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
        double nSL    = NormalizeDouble(sl,  digits);
        double nTP1   = NormalizeDouble(tp1, digits);
        double nTP2   = NormalizeDouble(tp2, digits);

        bool result = false;
        double price = 0;

        if (direction == 1) {
            price  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            // Open first half with TP1
            result = m_trade.Buy(lot * m_tp1Ratio, _Symbol, price, nSL, nTP1,
                                  comment + "|P1");
            if (result) {
                ulong t1 = m_trade.ResultOrder();
                // Open second half with TP2 (the "runner")
                m_trade.Buy(lot * (1.0 - m_tp1Ratio), _Symbol, price, nSL, nTP2,
                             comment + "|P2");
            }
        } else if (direction == -1) {
            price  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            result = m_trade.Sell(lot * m_tp1Ratio, _Symbol, price, nSL, nTP1,
                                   comment + "|P1");
            if (result) {
                m_trade.Sell(lot * (1.0 - m_tp1Ratio), _Symbol, price, nSL, nTP2,
                              comment + "|P2");
            }
        }

        if (result) {
            m_tradesOpened++;
            TrackPosition(direction, price, nSL, nTP1, nTP2, lot);
            PrintFormat("[TradeMgr] %s opened | Lot=%.2f+%.2f | SL=%.2f | TP1=%.2f | TP2=%.2f",
                direction == 1 ? "BUY" : "SELL",
                lot * m_tp1Ratio, lot * (1.0 - m_tp1Ratio),
                nSL, nTP1, nTP2);
        } else {
            PrintFormat("[TradeMgr] OPEN FAILED: %s (retcode=%d)",
                m_trade.ResultComment(), m_trade.ResultRetcode());
        }
        return result;
    }

    // Close all our positions
    bool CloseAll(string reason = "") {
        bool ok = true;
        for (int i = PositionsTotal() - 1; i >= 0; i--) {
            if (!m_pos.SelectByIndex(i)) continue;
            if (m_pos.Magic() != m_magic || m_pos.Symbol() != _Symbol) continue;
            if (!m_trade.PositionClose(m_pos.Ticket())) {
                PrintFormat("[TradeMgr] Close failed #%llu: %s",
                    m_pos.Ticket(), m_trade.ResultComment());
                ok = false;
            } else {
                PrintFormat("[TradeMgr] Closed #%llu | Reason: %s", m_pos.Ticket(), reason);
            }
        }
        m_posCount = 0;
        return ok;
    }

    // Called every tick - manage all positions
    void ManagePositions(double currentATR) {
        if (currentATR <= 0) return;
        double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
        double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        for (int i = PositionsTotal() - 1; i >= 0; i--) {
            if (!m_pos.SelectByIndex(i)) continue;
            if (m_pos.Magic() != m_magic || m_pos.Symbol() != _Symbol) continue;

            ulong  ticket   = m_pos.Ticket();
            double open     = m_pos.PriceOpen();
            double curSL    = m_pos.StopLoss();
            double curTP    = m_pos.TakeProfit();
            bool   isBuy    = (m_pos.PositionType() == POSITION_TYPE_BUY);

            double profitDist = isBuy ? (bid - open) : (open - ask);
            double beLevel    = currentATR * m_beAtrMult;
            double trailDist  = currentATR * m_trailAtrMult;

            if (isBuy) {
                // ── Break-even ──
                if (profitDist >= beLevel && curSL < open + point * 2) {
                    double newSL = NormalizeDouble(open + point * 3, _Digits);
                    if (newSL > curSL) {
                        m_trade.PositionModify(ticket, newSL, curTP);
                        PrintFormat("[TradeMgr] BUY #%llu BE set @ %.5f", ticket, newSL);
                    }
                }
                // ── Dynamic ATR trailing ──
                if (profitDist >= currentATR) {
                    double newSL = NormalizeDouble(bid - trailDist, _Digits);
                    if (newSL > curSL + point) {
                        m_trade.PositionModify(ticket, newSL, curTP);
                    }
                }
            } else {
                // SELL
                if (profitDist >= beLevel && (curSL > open - point * 2 || curSL == 0)) {
                    double newSL = NormalizeDouble(open - point * 3, _Digits);
                    if (newSL < curSL || curSL == 0) {
                        m_trade.PositionModify(ticket, newSL, curTP);
                        PrintFormat("[TradeMgr] SELL #%llu BE set @ %.5f", ticket, newSL);
                    }
                }
                if (profitDist >= currentATR) {
                    double newSL = NormalizeDouble(ask + trailDist, _Digits);
                    if (newSL < curSL - point || curSL == 0) {
                        m_trade.PositionModify(ticket, newSL, curTP);
                    }
                }
            }

            // ── Pyramid add-on ──
            if (m_pyramidEnabled) TryPyramid(ticket, profitDist, currentATR, isBuy,
                                              curSL, curTP, m_pos.Volume());
        }
    }

    // True if we have any open position
    bool HasOpenPosition() {
        for (int i = 0; i < PositionsTotal(); i++) {
            if (m_pos.SelectByIndex(i))
                if (m_pos.Magic() == m_magic && m_pos.Symbol() == _Symbol)
                    return true;
        }
        return false;
    }

    // Count open positions
    int OpenPositionCount() {
        int cnt = 0;
        for (int i = 0; i < PositionsTotal(); i++) {
            if (m_pos.SelectByIndex(i))
                if (m_pos.Magic() == m_magic && m_pos.Symbol() == _Symbol)
                    cnt++;
        }
        return cnt;
    }

    // Total floating profit
    double GetFloatingProfit() {
        double total = 0;
        for (int i = 0; i < PositionsTotal(); i++) {
            if (m_pos.SelectByIndex(i))
                if (m_pos.Magic() == m_magic && m_pos.Symbol() == _Symbol)
                    total += m_pos.Profit() + m_pos.Swap() + m_pos.Commission();
        }
        return total;
    }

    int GetTradesOpened()  { return m_tradesOpened; }
    int GetTP1Hits()       { return m_tp1Hits; }
    int GetPyramidAdds()   { return m_pyramidAdds; }
    ulong GetMagic()       { return m_magic; }

private:
    void TrackPosition(int dir, double open, double sl, double tp1, double tp2, double lot) {
        if (m_posCount >= 10) return;
        m_positions[m_posCount].openPrice   = open;
        m_positions[m_posCount].originalSL  = sl;
        m_positions[m_posCount].tp1         = tp1;
        m_positions[m_posCount].tp2         = tp2;
        m_positions[m_posCount].lotOriginal = lot;
        m_positions[m_posCount].state       = POS_STATE_OPEN;
        m_positions[m_posCount].tp1Closed   = false;
        m_positions[m_posCount].openTime    = TimeCurrent();
        m_posCount++;
    }

    void TryPyramid(ulong ticket, double profitDist, double atr,
                    bool isBuy, double curSL, double curTP, double curLot) {
        if (profitDist < atr * m_pyramidThreshold) return;

        // Check if already pyramided (prevent re-adding)
        string comment = m_pos.Comment();
        if (StringFind(comment, "|PYR") >= 0) return;

        double pyramidLot = NormalizeDouble(curLot * m_pyramidLotRatio,
                               (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
        double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
        if (pyramidLot < minLot) return;

        bool result = false;
        if (isBuy) {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            result = m_trade.Buy(pyramidLot, _Symbol, ask, curSL, curTP,
                                  "NexusAI|PYR");
        } else {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            result = m_trade.Sell(pyramidLot, _Symbol, bid, curSL, curTP,
                                   "NexusAI|PYR");
        }
        if (result) {
            m_pyramidAdds++;
            PrintFormat("[TradeMgr] PYRAMID added %.2f lots | total adds: %d",
                pyramidLot, m_pyramidAdds);
        }
    }
};
