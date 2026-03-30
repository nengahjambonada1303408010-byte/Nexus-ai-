//+------------------------------------------------------------------+
//|                                               MarketAnalyzer.mqh |
//|                           Nexus AI - XAUUSD Scalper Self-Healing |
//|              Multi-timeframe market analysis & signal generation  |
//+------------------------------------------------------------------+
#pragma once

//+------------------------------------------------------------------+
//| Signal structure                                                 |
//+------------------------------------------------------------------+
struct SignalResult {
    int    direction;     // 1=BUY, -1=SELL, 0=NONE
    double strength;      // 0.0 - 1.0
    double entryPrice;
    double stopLoss;
    double takeProfit;
    double atr;
    string reason;
};

//+------------------------------------------------------------------+
//| Market Analyzer Class                                            |
//+------------------------------------------------------------------+
class CMarketAnalyzer {
private:
    // Indicator handles
    int m_emaFastH1,   m_emaSlowH1;   // EMA on H1
    int m_emaFastM15,  m_emaSlowM15;  // EMA on M15
    int m_emaFastM5,   m_emaSlowM5;   // EMA on M5 (entry)
    int m_rsiH1,       m_rsiM5;
    int m_macdM5;
    int m_bbM5;
    int m_atrM5;
    int m_stochM5;
    int m_ichimokuH1;
    int m_adxM5;

    // Adaptive parameters (self-optimizing)
    int    m_emaFastPeriod;
    int    m_emaSlowPeriod;
    int    m_rsiPeriod;
    double m_rsiOverbought;
    double m_rsiOversold;
    double m_atrMultiplierSL;
    double m_atrMultiplierTP;
    int    m_adxMinStrength;

    // Performance tracking for self-optimization
    int    m_winCount;
    int    m_lossCount;
    double m_totalProfit;
    double m_avgWin;
    double m_avgLoss;

public:
    CMarketAnalyzer() {
        // Default adaptive parameters
        m_emaFastPeriod    = 9;
        m_emaSlowPeriod    = 21;
        m_rsiPeriod        = 14;
        m_rsiOverbought    = 70.0;
        m_rsiOversold      = 30.0;
        m_atrMultiplierSL  = 1.5;
        m_atrMultiplierTP  = 3.0;
        m_adxMinStrength   = 20;
        m_winCount         = 0;
        m_lossCount        = 0;
        m_totalProfit      = 0;
        m_avgWin           = 0;
        m_avgLoss          = 0;
    }

    bool Init() {
        string sym = _Symbol;

        // H1 trend indicators
        m_emaFastH1  = iMA(sym, PERIOD_H1,  m_emaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
        m_emaSlowH1  = iMA(sym, PERIOD_H1,  m_emaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
        m_ichimokuH1 = iIchimoku(sym, PERIOD_H1, 9, 26, 52);
        m_rsiH1      = iRSI(sym, PERIOD_H1, m_rsiPeriod, PRICE_CLOSE);

        // M15 confirmation
        m_emaFastM15 = iMA(sym, PERIOD_M15, m_emaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
        m_emaSlowM15 = iMA(sym, PERIOD_M15, m_emaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);

        // M5 entry indicators
        m_emaFastM5  = iMA(sym, PERIOD_M5,  m_emaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
        m_emaSlowM5  = iMA(sym, PERIOD_M5,  m_emaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
        m_rsiM5      = iRSI(sym, PERIOD_M5,  m_rsiPeriod, PRICE_CLOSE);
        m_macdM5     = iMACD(sym, PERIOD_M5, 12, 26, 9, PRICE_CLOSE);
        m_bbM5       = iBands(sym, PERIOD_M5, 20, 0, 2.0, PRICE_CLOSE);
        m_atrM5      = iATR(sym, PERIOD_M5,  14);
        m_stochM5    = iStochastic(sym, PERIOD_M5, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
        m_adxM5      = iADX(sym, PERIOD_M5,  14);

        bool ok = (m_emaFastH1 != INVALID_HANDLE && m_emaSlowH1 != INVALID_HANDLE &&
                   m_emaFastM5 != INVALID_HANDLE && m_rsiM5 != INVALID_HANDLE &&
                   m_macdM5 != INVALID_HANDLE && m_atrM5 != INVALID_HANDLE &&
                   m_adxM5 != INVALID_HANDLE);

        if (!ok) Print("[Analyzer] ERROR: Failed to create indicator handles");
        else     Print("[Analyzer] All indicators initialized successfully");
        return ok;
    }

    void Deinit() {
        IndicatorRelease(m_emaFastH1);  IndicatorRelease(m_emaSlowH1);
        IndicatorRelease(m_emaFastM15); IndicatorRelease(m_emaSlowM15);
        IndicatorRelease(m_emaFastM5);  IndicatorRelease(m_emaSlowM5);
        IndicatorRelease(m_rsiH1);      IndicatorRelease(m_rsiM5);
        IndicatorRelease(m_macdM5);     IndicatorRelease(m_bbM5);
        IndicatorRelease(m_atrM5);      IndicatorRelease(m_stochM5);
        IndicatorRelease(m_adxM5);      IndicatorRelease(m_ichimokuH1);
    }

    // Main signal generation with multi-timeframe confluence
    SignalResult GenerateSignal() {
        SignalResult sig;
        sig.direction = 0;
        sig.strength  = 0;
        sig.reason    = "";

        // Get indicator values
        double emaFastH1[1], emaSlowH1[1];
        double emaFastM15[1], emaSlowM15[1];
        double emaFastM5[2], emaSlowM5[2];
        double rsiH1[1], rsiM5[1];
        double macdMain[1], macdSignal[1];
        double bbUpper[1], bbMiddle[1], bbLower[1];
        double atr[1];
        double stochMain[1], stochSignal[1];
        double adxMain[1];
        double ichTenkan[1], ichKijun[1], ichSpanA[1], ichSpanB[1];

        if (!GetValues(m_emaFastH1, emaFastH1, 1)  || !GetValues(m_emaSlowH1, emaSlowH1, 1)) return sig;
        if (!GetValues(m_emaFastM15, emaFastM15, 1) || !GetValues(m_emaSlowM15, emaSlowM15, 1)) return sig;
        if (!GetValues(m_emaFastM5, emaFastM5, 2)   || !GetValues(m_emaSlowM5, emaSlowM5, 2)) return sig;
        if (!GetValues(m_rsiH1, rsiH1, 1)           || !GetValues(m_rsiM5, rsiM5, 1)) return sig;
        if (!GetMACDValues(macdMain, macdSignal))    return sig;
        if (!GetBBValues(bbUpper, bbMiddle, bbLower)) return sig;
        if (!GetValues(m_atrM5, atr, 1))             return sig;
        if (!GetStochValues(stochMain, stochSignal)) return sig;
        if (!GetValues(m_adxM5, adxMain, 1))         return sig;
        if (!GetIchimokuValues(ichTenkan, ichKijun, ichSpanA, ichSpanB)) return sig;

        sig.atr = atr[0];
        double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

        // --- Trend Filter (H1) ---
        bool h1Bullish = (emaFastH1[0] > emaSlowH1[0]) &&
                         (price > ichSpanA[0]) && (price > ichSpanB[0]) &&
                         (ichTenkan[0] > ichKijun[0]);
        bool h1Bearish = (emaFastH1[0] < emaSlowH1[0]) &&
                         (price < ichSpanA[0]) && (price < ichSpanB[0]) &&
                         (ichTenkan[0] < ichKijun[0]);

        // --- M15 Confirmation ---
        bool m15Bullish = emaFastM15[0] > emaSlowM15[0];
        bool m15Bearish = emaFastM15[0] < emaSlowM15[0];

        // --- ADX: Market must have direction ---
        bool hasTrend = adxMain[0] >= m_adxMinStrength;

        // --- M5 Entry Conditions ---
        bool emaCrossBuy  = (emaFastM5[0] > emaSlowM5[0]) && (emaFastM5[1] <= emaSlowM5[1]);
        bool emaCrossSell = (emaFastM5[0] < emaSlowM5[0]) && (emaFastM5[1] >= emaSlowM5[1]);

        bool rsiConfirmBuy  = (rsiM5[0] > 45 && rsiM5[0] < m_rsiOverbought) && (rsiH1[0] > 40);
        bool rsiConfirmSell = (rsiM5[0] < 55 && rsiM5[0] > m_rsiOversold)   && (rsiH1[0] < 60);

        bool macdBuy  = macdMain[0] > macdSignal[0] && macdMain[0] > 0;
        bool macdSell = macdMain[0] < macdSignal[0] && macdMain[0] < 0;

        bool stochBuy  = stochMain[0] > stochSignal[0] && stochMain[0] < 80;
        bool stochSell = stochMain[0] < stochSignal[0] && stochMain[0] > 20;

        bool bbBounce = (price > bbLower[0] && price < bbMiddle[0]);
        bool bbReject = (price < bbUpper[0] && price > bbMiddle[0]);

        // --- Score confluence ---
        int buyScore  = 0;
        int sellScore = 0;

        if (h1Bullish)     buyScore  += 3; // Strong weight
        if (h1Bearish)     sellScore += 3;
        if (m15Bullish)    buyScore  += 2;
        if (m15Bearish)    sellScore += 2;
        if (emaCrossBuy)   buyScore  += 2;
        if (emaCrossSell)  sellScore += 2;
        if (rsiConfirmBuy)  buyScore  += 1;
        if (rsiConfirmSell) sellScore += 1;
        if (macdBuy)       buyScore  += 2;
        if (macdSell)      sellScore += 2;
        if (stochBuy)      buyScore  += 1;
        if (stochSell)     sellScore += 1;
        if (bbBounce)      buyScore  += 1;
        if (bbReject)      sellScore += 1;
        if (hasTrend)      { buyScore += 1; sellScore += 1; } // Trend presence bonus

        int maxScore = 13;
        double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);

        // Reject if spread too wide (> 3 ATR units)
        if (spread > atr[0] * 0.3) {
            sig.reason = StringFormat("Spread too wide: %.5f vs ATR: %.5f", spread, atr[0]);
            return sig;
        }

        // Minimum score = 8/13 for BUY, 8/13 for SELL
        if (buyScore >= 8 && buyScore > sellScore) {
            sig.direction  = 1;
            sig.strength   = (double)buyScore / maxScore;
            sig.entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            sig.stopLoss   = sig.entryPrice - atr[0] * m_atrMultiplierSL;
            sig.takeProfit = sig.entryPrice + atr[0] * m_atrMultiplierTP;
            sig.reason     = StringFormat("BUY score=%d H1=%s M15=%s MACD=%s RSI=%.1f ADX=%.1f",
                             buyScore, h1Bullish?"bull":"", m15Bullish?"bull":"",
                             macdBuy?"bull":"", rsiM5[0], adxMain[0]);
        }
        else if (sellScore >= 8 && sellScore > buyScore) {
            sig.direction  = -1;
            sig.strength   = (double)sellScore / maxScore;
            sig.entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            sig.stopLoss   = sig.entryPrice + atr[0] * m_atrMultiplierSL;
            sig.takeProfit = sig.entryPrice - atr[0] * m_atrMultiplierTP;
            sig.reason     = StringFormat("SELL score=%d H1=%s M15=%s MACD=%s RSI=%.1f ADX=%.1f",
                             sellScore, h1Bearish?"bear":"", m15Bearish?"bear":"",
                             macdSell?"bear":"", rsiM5[0], adxMain[0]);
        }

        return sig;
    }

    // Self-optimization: adjust parameters based on recent performance
    void OptimizeParams(double winRate, double profitFactor) {
        Print("[Analyzer] Running self-optimization...");
        Print(StringFormat("[Analyzer] Current: WinRate=%.1f%% PF=%.2f", winRate * 100, profitFactor));

        // If win rate is low, tighten entry conditions
        if (winRate < 0.45) {
            m_adxMinStrength = MathMin(30, m_adxMinStrength + 2);
            m_rsiOverbought  = MathMin(75, m_rsiOverbought + 2);
            m_rsiOversold    = MathMax(25, m_rsiOversold - 2);
            Print("[Analyzer] Tightened entry: ADX=" + IntegerToString(m_adxMinStrength));
        }
        // If win rate is high but profit factor is low, widen TP
        else if (winRate > 0.60 && profitFactor < 1.5) {
            m_atrMultiplierTP = MathMin(4.0, m_atrMultiplierTP + 0.2);
            Print("[Analyzer] Widened TP multiplier: " + DoubleToString(m_atrMultiplierTP, 2));
        }
        // Good performance - keep or slightly relax conditions
        else if (winRate > 0.55 && profitFactor > 2.0) {
            m_adxMinStrength = MathMax(18, m_adxMinStrength - 1);
            Print("[Analyzer] Relaxed ADX filter: " + IntegerToString(m_adxMinStrength));
        }

        // Adjust SL based on profit factor
        if (profitFactor < 1.2) {
            m_atrMultiplierSL = MathMax(1.0, m_atrMultiplierSL - 0.1); // Tighter SL
        } else if (profitFactor > 2.5) {
            m_atrMultiplierSL = MathMin(2.5, m_atrMultiplierSL + 0.1); // Give more room
        }

        Print(StringFormat("[Analyzer] Optimized params: ATR_SL=%.1f ATR_TP=%.1f ADX=%d",
              m_atrMultiplierSL, m_atrMultiplierTP, m_adxMinStrength));
    }

    double GetCurrentATR() {
        double atr[1];
        if (!GetValues(m_atrM5, atr, 1)) return 0;
        return atr[0];
    }

    // Session filter: only trade during high-liquidity sessions
    bool IsGoodSession() {
        MqlDateTime dt;
        TimeToStruct(TimeGMT(), dt);
        int hourGMT = dt.hour;

        // London: 07:00-16:00 GMT
        bool london = (hourGMT >= 7 && hourGMT < 16);
        // New York: 13:00-21:00 GMT
        bool newYork = (hourGMT >= 13 && hourGMT < 21);
        // London/NY overlap: 13:00-16:00 GMT (best for gold)
        bool overlap = (hourGMT >= 13 && hourGMT < 16);

        // Avoid low-liquidity Asian session (00:00-06:00 GMT)
        bool asianLow = (hourGMT >= 0 && hourGMT < 6);

        return (london || newYork) && !asianLow;
    }

    // Check if near major news (placeholder - integrate with news API for production)
    bool IsNearNews() {
        // In production: fetch from economic calendar
        // For now, avoid end-of-hour gaps
        MqlDateTime dt;
        TimeToStruct(TimeCurrent(), dt);
        return (dt.min >= 57 || dt.min <= 3); // Avoid 3 min around hour change
    }

private:
    bool GetValues(int handle, double &buf[], int count) {
        ArraySetAsSeries(buf, true);
        return CopyBuffer(handle, 0, 0, count, buf) == count;
    }

    bool GetMACDValues(double &main[], double &signal[]) {
        ArraySetAsSeries(main, true);
        ArraySetAsSeries(signal, true);
        return (CopyBuffer(m_macdM5, 0, 0, 1, main)   == 1 &&
                CopyBuffer(m_macdM5, 1, 0, 1, signal) == 1);
    }

    bool GetBBValues(double &upper[], double &mid[], double &lower[]) {
        ArraySetAsSeries(upper, true);
        ArraySetAsSeries(mid,   true);
        ArraySetAsSeries(lower, true);
        return (CopyBuffer(m_bbM5, 1, 0, 1, upper) == 1 &&
                CopyBuffer(m_bbM5, 0, 0, 1, mid)   == 1 &&
                CopyBuffer(m_bbM5, 2, 0, 1, lower) == 1);
    }

    bool GetStochValues(double &main[], double &sig[]) {
        ArraySetAsSeries(main, true);
        ArraySetAsSeries(sig,  true);
        return (CopyBuffer(m_stochM5, 0, 0, 1, main) == 1 &&
                CopyBuffer(m_stochM5, 1, 0, 1, sig)  == 1);
    }

    bool GetIchimokuValues(double &tenkan[], double &kijun[],
                           double &spanA[],  double &spanB[]) {
        ArraySetAsSeries(tenkan, true);
        ArraySetAsSeries(kijun,  true);
        ArraySetAsSeries(spanA,  true);
        ArraySetAsSeries(spanB,  true);
        return (CopyBuffer(m_ichimokuH1, 0, 0, 1, tenkan) == 1 &&
                CopyBuffer(m_ichimokuH1, 1, 0, 1, kijun)  == 1 &&
                CopyBuffer(m_ichimokuH1, 2, 0, 1, spanA)  == 1 &&
                CopyBuffer(m_ichimokuH1, 3, 0, 1, spanB)  == 1);
    }
};
