//+------------------------------------------------------------------+
//|                                               MarketAnalyzer.mqh |
//|                          Nexus AI v3 - XAUUSD Aggressive Scalper |
//|  3 Signal Types: MOMENTUM | PULLBACK | BREAKOUT                  |
//|  Price Action: Pin Bar, Engulfing, Break-of-Structure            |
//|  Multi-timeframe: H4 bias + H1 trend + M15 confirm + M5 entry   |
//+------------------------------------------------------------------+
#pragma once

//+------------------------------------------------------------------+
//| Signal types                                                     |
//+------------------------------------------------------------------+
enum SignalType {
    SIG_NONE,
    SIG_MOMENTUM,   // Strong trend continuation
    SIG_PULLBACK,   // Retest of EMA/structure then resume
    SIG_BREAKOUT    // Break of recent high/low with volume
};

//+------------------------------------------------------------------+
//| Signal result                                                    |
//+------------------------------------------------------------------+
struct SignalResult {
    int        direction;    // 1=BUY -1=SELL 0=NONE
    double     strength;     // 0.0 - 1.0
    SignalType type;
    double     entryPrice;
    double     stopLoss;
    double     takeProfit1;  // Partial close target (1.5R)
    double     takeProfit2;  // Full target (3R)
    double     atr;
    double     riskReward;
    string     reason;
};

//+------------------------------------------------------------------+
//| Market Analyzer                                                  |
//+------------------------------------------------------------------+
class CMarketAnalyzer {
private:
    // --- Indicator handles ---
    // H4 bias
    int m_emaH4_50, m_emaH4_200;

    // H1 trend
    int m_emaH1_Fast, m_emaH1_Slow;
    int m_ichimokuH1;
    int m_rsiH1;
    int m_atrH1;

    // M15 confirmation
    int m_emaM15_Fast, m_emaM15_Slow;
    int m_rsiM15;

    // M5 entry (fast signals)
    int m_emaM5_Fast, m_emaM5_Slow, m_emaM5_Trend;
    int m_rsiM5;
    int m_macdM5;
    int m_bbM5;
    int m_atrM5;
    int m_stochM5;
    int m_adxM5;
    int m_cciM5;    // Aggressive momentum oscillator

    // --- Adaptive parameters ---
    int    m_emaFastPeriod;   // default 8
    int    m_emaSlowPeriod;   // default 21
    int    m_emaTrendPeriod;  // default 50
    int    m_rsiPeriod;
    double m_rsiOB, m_rsiOS;  // Overbought/oversold
    double m_atrSL;           // ATR SL multiplier
    double m_atrTP1;          // ATR TP1 multiplier (partial)
    double m_atrTP2;          // ATR TP2 multiplier (full)
    int    m_adxMin;          // Min ADX for trend signal
    int    m_minScore;        // Minimum score to open trade
    double m_momentumBonus;   // Extra lot multiplier when ADX > 35

public:
    CMarketAnalyzer() {
        m_emaFastPeriod  = 8;
        m_emaSlowPeriod  = 21;
        m_emaTrendPeriod = 50;
        m_rsiPeriod      = 14;
        m_rsiOB          = 68.0;
        m_rsiOS          = 32.0;
        m_atrSL          = 1.4;
        m_atrTP1         = 2.0;   // TP1 at 2R (close 50%)
        m_atrTP2         = 3.5;   // TP2 let runner go 3.5R
        m_adxMin         = 20;
        m_minScore       = 7;     // Aggressive: 7/15 (vs conservative 8)
        m_momentumBonus  = 1.3;
    }

    bool Init() {
        string s = _Symbol;

        // H4 macro bias
        m_emaH4_50  = iMA(s, PERIOD_H4, 50,  0, MODE_EMA, PRICE_CLOSE);
        m_emaH4_200 = iMA(s, PERIOD_H4, 200, 0, MODE_EMA, PRICE_CLOSE);

        // H1 trend
        m_emaH1_Fast  = iMA(s, PERIOD_H1, m_emaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
        m_emaH1_Slow  = iMA(s, PERIOD_H1, m_emaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
        m_ichimokuH1  = iIchimoku(s, PERIOD_H1, 9, 26, 52);
        m_rsiH1       = iRSI(s, PERIOD_H1, m_rsiPeriod, PRICE_CLOSE);
        m_atrH1       = iATR(s, PERIOD_H1, 14);

        // M15 confirmation
        m_emaM15_Fast = iMA(s, PERIOD_M15, m_emaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
        m_emaM15_Slow = iMA(s, PERIOD_M15, m_emaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
        m_rsiM15      = iRSI(s, PERIOD_M15, m_rsiPeriod, PRICE_CLOSE);

        // M5 entry
        m_emaM5_Fast  = iMA(s, PERIOD_M5, m_emaFastPeriod,  0, MODE_EMA, PRICE_CLOSE);
        m_emaM5_Slow  = iMA(s, PERIOD_M5, m_emaSlowPeriod,  0, MODE_EMA, PRICE_CLOSE);
        m_emaM5_Trend = iMA(s, PERIOD_M5, m_emaTrendPeriod, 0, MODE_EMA, PRICE_CLOSE);
        m_rsiM5       = iRSI(s, PERIOD_M5,  m_rsiPeriod, PRICE_CLOSE);
        m_macdM5      = iMACD(s, PERIOD_M5, 12, 26, 9, PRICE_CLOSE);
        m_bbM5        = iBands(s, PERIOD_M5, 20, 0, 2.0, PRICE_CLOSE);
        m_atrM5       = iATR(s, PERIOD_M5,  14);
        m_stochM5     = iStochastic(s, PERIOD_M5, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
        m_adxM5       = iADX(s, PERIOD_M5,  14);
        m_cciM5       = iCCI(s, PERIOD_M5,  20, PRICE_TYPICAL);

        bool ok = (m_emaH4_50   != INVALID_HANDLE && m_emaH4_200  != INVALID_HANDLE &&
                   m_emaH1_Fast != INVALID_HANDLE && m_emaH1_Slow != INVALID_HANDLE &&
                   m_emaM5_Fast != INVALID_HANDLE && m_rsiM5      != INVALID_HANDLE &&
                   m_macdM5     != INVALID_HANDLE && m_atrM5      != INVALID_HANDLE &&
                   m_adxM5      != INVALID_HANDLE && m_cciM5      != INVALID_HANDLE);

        if (ok) Print("[Analyzer] v3 All indicators ready (" +
                      IntegerToString(16) + " handles)");
        else    Print("[Analyzer] ERROR: One or more indicators failed");
        return ok;
    }

    void Deinit() {
        int handles[] = {
            m_emaH4_50, m_emaH4_200,
            m_emaH1_Fast, m_emaH1_Slow, m_ichimokuH1, m_rsiH1, m_atrH1,
            m_emaM15_Fast, m_emaM15_Slow, m_rsiM15,
            m_emaM5_Fast, m_emaM5_Slow, m_emaM5_Trend,
            m_rsiM5, m_macdM5, m_bbM5, m_atrM5, m_stochM5, m_adxM5, m_cciM5
        };
        for (int i = 0; i < ArraySize(handles); i++)
            IndicatorRelease(handles[i]);
    }

    //+------------------------------------------------------------------+
    //| Main signal engine                                               |
    //+------------------------------------------------------------------+
    SignalResult GenerateSignal() {
        SignalResult sig;
        sig.direction = 0; sig.strength = 0; sig.type = SIG_NONE;
        sig.reason = "";

        // ── Read all indicator buffers ──
        double h4_50[1], h4_200[1];
        double h1f[1], h1s[1], rsiH1[1], atrH1[1];
        double ichTenkan[1], ichKijun[1], ichSpanA[1], ichSpanB[1];
        double m15f[1], m15s[1], rsiM15[1];
        double m5f[3], m5s[3], m5trend[1];
        double rsiM5[2], cciM5[1], adx[1];
        double macdMain[2], macdSig[2];
        double bbU[1], bbM[1], bbL[1];
        double atr[1];
        double stochMain[1], stochSig[1];

        // H4
        if (!Buf(m_emaH4_50,  h4_50,  1)) return sig;
        if (!Buf(m_emaH4_200, h4_200, 1)) return sig;
        // H1
        if (!Buf(m_emaH1_Fast, h1f, 1))   return sig;
        if (!Buf(m_emaH1_Slow, h1s, 1))   return sig;
        if (!Buf(m_rsiH1,  rsiH1,  1))    return sig;
        if (!Buf(m_atrH1,  atrH1,  1))    return sig;
        if (!IchBuf(ichTenkan, ichKijun, ichSpanA, ichSpanB)) return sig;
        // M15
        if (!Buf(m_emaM15_Fast, m15f,   1)) return sig;
        if (!Buf(m_emaM15_Slow, m15s,   1)) return sig;
        if (!Buf(m_rsiM15,      rsiM15, 1)) return sig;
        // M5
        if (!Buf(m_emaM5_Fast,  m5f,     3)) return sig;
        if (!Buf(m_emaM5_Slow,  m5s,     3)) return sig;
        if (!Buf(m_emaM5_Trend, m5trend, 1)) return sig;
        if (!Buf(m_rsiM5,       rsiM5,   2)) return sig;
        if (!Buf(m_cciM5,       cciM5,   1)) return sig;
        if (!Buf(m_adxM5,       adx,     1)) return sig;
        if (!Buf(m_atrM5,       atr,     1)) return sig;
        if (!MacdBuf(macdMain, macdSig))     return sig;
        if (!BBBuf(bbU, bbM, bbL))           return sig;
        if (!StochBuf(stochMain, stochSig))  return sig;

        sig.atr = atr[0];
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

        // ── Price action on M5 ──
        double o1 = iOpen(_Symbol,  PERIOD_M5, 1);
        double h1bar = iHigh(_Symbol,  PERIOD_M5, 1);
        double l1 = iLow(_Symbol,   PERIOD_M5, 1);
        double c1 = iClose(_Symbol, PERIOD_M5, 1);
        double o2 = iOpen(_Symbol,  PERIOD_M5, 2);
        double c2 = iClose(_Symbol, PERIOD_M5, 2);

        // Price action patterns
        double body1  = MathAbs(c1 - o1);
        double range1 = h1bar - l1;
        double upperWick = h1bar - MathMax(c1, o1);
        double lowerWick = MathMin(c1, o1) - l1;
        bool   bullCandle = c1 > o1;
        bool   bearCandle = c1 < o1;

        bool pinBarBull = (lowerWick > body1 * 2.0) && (lowerWick > upperWick * 2.5);
        bool pinBarBear = (upperWick > body1 * 2.0) && (upperWick > lowerWick * 2.5);
        bool engulfBull = (c1 > o2) && (o1 < c2) && (body1 > MathAbs(c2-o2) * 1.2);
        bool engulfBear = (c1 < o2) && (o1 > c2) && (body1 > MathAbs(c2-o2) * 1.2);
        bool strongMomBull = bullCandle && (body1 / (range1 + 0.0001) > 0.70);
        bool strongMomBear = bearCandle && (body1 / (range1 + 0.0001) > 0.70);

        // ── Trend layers ──
        bool h4Bull   = h4_50[0] > h4_200[0];
        bool h4Bear   = h4_50[0] < h4_200[0];

        bool h1Bull   = (h1f[0] > h1s[0]) && (bid > ichSpanA[0]) && (bid > ichSpanB[0]);
        bool h1Bear   = (h1f[0] < h1s[0]) && (bid < ichSpanA[0]) && (bid < ichSpanB[0]);
        bool h1StrongBull = h1Bull && (ichTenkan[0] > ichKijun[0]) && (rsiH1[0] > 50);
        bool h1StrongBear = h1Bear && (ichTenkan[0] < ichKijun[0]) && (rsiH1[0] < 50);

        bool m15Bull  = m15f[0] > m15s[0];
        bool m15Bear  = m15f[0] < m15s[0];

        // ── M5 technicals ──
        bool priceAboveTrend = bid > m5trend[0];
        bool priceBelowTrend = bid < m5trend[0];
        bool emaCrossBull    = (m5f[0] > m5s[0]) && (m5f[1] <= m5s[1]); // fresh cross
        bool emaCrossBear    = (m5f[0] < m5s[0]) && (m5f[1] >= m5s[1]);
        bool emaAlignedBull  = m5f[0] > m5s[0];
        bool emaAlignedBear  = m5f[0] < m5s[0];

        bool rsiBull  = rsiM5[0] > 50 && rsiM5[0] < m_rsiOB && rsiM5[0] > rsiM5[1];
        bool rsiBear  = rsiM5[0] < 50 && rsiM5[0] > m_rsiOS && rsiM5[0] < rsiM5[1];
        bool rsiOSRecovery = rsiM5[0] > 30 && rsiM5[1] <= 30; // RSI just left oversold
        bool rsiOBDecline  = rsiM5[0] < 70 && rsiM5[1] >= 70; // RSI just left overbought

        bool macdBull  = macdMain[0] > macdSig[0] && macdMain[0] > macdMain[1];
        bool macdBear  = macdMain[0] < macdSig[0] && macdMain[0] < macdMain[1];
        bool macdXBull = macdMain[0] > macdSig[0] && macdMain[1] <= macdSig[1]; // fresh cross
        bool macdXBear = macdMain[0] < macdSig[0] && macdMain[1] >= macdSig[1];

        bool stochBull = stochMain[0] > stochSig[0] && stochMain[0] < 80;
        bool stochBear = stochMain[0] < stochSig[0] && stochMain[0] > 20;
        bool stochXBull = stochMain[0] > stochSig[0] && stochMain[1] <= stochSig[1];
        bool stochXBear = stochMain[0] < stochSig[0] && stochMain[1] >= stochSig[1];

        bool cciBull  = cciM5[0] > 0   && cciM5[0] < 200;
        bool cciBear  = cciM5[0] < 0   && cciM5[0] > -200;
        bool cciExtBull = cciM5[0] > 100; // strong momentum
        bool cciExtBear = cciM5[0] < -100;

        bool bbPullBull = (bid > bbL[0]) && (bid < bbM[0]); // pullback to lower half
        bool bbPullBear = (bid < bbU[0]) && (bid > bbM[0]); // pullback to upper half
        bool bbBreakBull = bid > bbU[0];
        bool bbBreakBear = bid < bbL[0];

        bool strongTrend = adx[0] >= m_adxMin;
        bool veryStrong  = adx[0] >= 35;

        // ── SESSION QUALITY BONUS ──
        bool overlapSession = IsOverlapSession(); // London/NY overlap = strongest

        // ══════════════════════════════════════════
        // SCORING ENGINE  (max 15 points)
        // ══════════════════════════════════════════
        int buyScore = 0, sellScore = 0;

        // H4 macro bias (2 pts)
        if (h4Bull) buyScore  += 2;
        if (h4Bear) sellScore += 2;

        // H1 trend (3 pts for strong, 1 for basic)
        if (h1StrongBull) buyScore  += 3;
        else if (h1Bull)  buyScore  += 1;
        if (h1StrongBear) sellScore += 3;
        else if (h1Bear)  sellScore += 1;

        // M15 alignment (1 pt)
        if (m15Bull) buyScore  += 1;
        if (m15Bear) sellScore += 1;

        // M5 EMA (2 pts: 1 for aligned, 2 for fresh cross)
        if (emaCrossBull)       buyScore  += 2;
        else if (emaAlignedBull) buyScore  += 1;
        if (emaCrossBear)       sellScore += 2;
        else if (emaAlignedBear) sellScore += 1;

        // MACD (2 pts: 1 for aligned, 2 for fresh cross)
        if (macdXBull) buyScore  += 2;
        else if (macdBull) buyScore += 1;
        if (macdXBear) sellScore += 2;
        else if (macdBear) sellScore += 1;

        // Stoch (1 pt cross, bonus 0.5 handled as +1 for combined)
        if (stochXBull) buyScore  += 1;
        if (stochXBear) sellScore += 1;

        // RSI (1 pt)
        if (rsiBull || rsiOSRecovery) buyScore  += 1;
        if (rsiBear || rsiOBDecline)  sellScore += 1;

        // CCI momentum (1 pt)
        if (cciBull) buyScore  += 1;
        if (cciBear) sellScore += 1;

        // Price action bonus (1 pt each)
        if (pinBarBull || engulfBull || strongMomBull) buyScore  += 1;
        if (pinBarBear || engulfBear || strongMomBear) sellScore += 1;

        // ADX trend filter (1 pt if strong, removes 1 if no trend)
        if (strongTrend) { buyScore += 1; sellScore += 1; }
        else             { buyScore = MathMax(0, buyScore - 1);
                           sellScore = MathMax(0, sellScore - 1); }

        // Dynamic threshold: very strong ADX lowers requirement by 1
        int threshold = m_minScore - (veryStrong ? 1 : 0);
        int maxScore  = 15;

        // ── Determine signal type ──
        SignalType sigType = SIG_NONE;
        if (emaCrossBull || macdXBull)                            sigType = SIG_MOMENTUM;
        else if (bbPullBull && m15Bull && priceAboveTrend)        sigType = SIG_PULLBACK;
        else if (bbBreakBull && veryStrong && h1Bull)             sigType = SIG_BREAKOUT;
        // sell mirror
        if (emaCrossBear || macdXBear)                            sigType = SIG_MOMENTUM;
        else if (bbPullBear && m15Bear && priceBelowTrend)        sigType = SIG_PULLBACK;
        else if (bbBreakBear && veryStrong && h1Bear)             sigType = SIG_BREAKOUT;

        // ── Compute SL/TP based on signal type ──
        double slMult  = m_atrSL;
        double tp1Mult = m_atrTP1;
        double tp2Mult = m_atrTP2;

        if (sigType == SIG_BREAKOUT) {
            // Breakouts: wider stop, bigger target
            slMult  = m_atrSL * 1.2;
            tp2Mult = m_atrTP2 * 1.3;
        } else if (sigType == SIG_PULLBACK) {
            // Pullbacks: tighter stop (entry near structure)
            slMult  = m_atrSL * 0.85;
        }

        // ── FIRE signal ──
        if (buyScore >= threshold && buyScore > sellScore) {
            sig.direction  = 1;
            sig.type       = sigType;
            sig.strength   = (double)buyScore / maxScore;
            sig.entryPrice = ask;
            sig.stopLoss   = NormalizeDouble(ask - atr[0] * slMult, _Digits);
            sig.takeProfit1 = NormalizeDouble(ask + atr[0] * tp1Mult, _Digits);
            sig.takeProfit2 = NormalizeDouble(ask + atr[0] * tp2Mult, _Digits);
            sig.riskReward  = tp2Mult / slMult;
            sig.reason = StringFormat("BUY|%s|sc=%d/%d|H4=%s|H1=%s|M15=%s|ADX=%.0f|RSI=%.0f|CCI=%.0f|%s%s%s",
                SignalTypeStr(sigType), buyScore, maxScore,
                h4Bull?"bull":"flat", h1StrongBull?"strong":(h1Bull?"bull":""),
                m15Bull?"bull":"", adx[0], rsiM5[0], cciM5[0],
                pinBarBull?"PinBar ":"", engulfBull?"Engulf ":"",
                emaCrossBull?"EMAx ":"");
        }
        else if (sellScore >= threshold && sellScore > buyScore) {
            sig.direction  = -1;
            sig.type       = sigType;
            sig.strength   = (double)sellScore / maxScore;
            sig.entryPrice = bid;
            sig.stopLoss   = NormalizeDouble(bid + atr[0] * slMult, _Digits);
            sig.takeProfit1 = NormalizeDouble(bid - atr[0] * tp1Mult, _Digits);
            sig.takeProfit2 = NormalizeDouble(bid - atr[0] * tp2Mult, _Digits);
            sig.riskReward  = tp2Mult / slMult;
            sig.reason = StringFormat("SELL|%s|sc=%d/%d|H4=%s|H1=%s|M15=%s|ADX=%.0f|RSI=%.0f|CCI=%.0f|%s%s%s",
                SignalTypeStr(sigType), sellScore, maxScore,
                h4Bear?"bear":"flat", h1StrongBear?"strong":(h1Bear?"bear":""),
                m15Bear?"bear":"", adx[0], rsiM5[0], cciM5[0],
                pinBarBear?"PinBar ":"", engulfBear?"Engulf ":"",
                emaCrossBear?"EMAx ":"");
        }

        return sig;
    }

    // ── Self-optimization ──────────────────────────────────────────
    void OptimizeParams(double winRate, double profitFactor,
                        double avgWin, double avgLoss) {
        Print(StringFormat("[Analyzer] OptimizeParams WR=%.1f%% PF=%.2f", winRate*100, profitFactor));

        // Entry tightness
        if (winRate < 0.42) {
            m_adxMin   = MathMin(30, m_adxMin + 3);
            m_rsiOB    = MathMin(72, m_rsiOB + 2);
            m_rsiOS    = MathMax(28, m_rsiOS - 2);
            m_minScore = MathMin(10, m_minScore + 1);
        } else if (winRate > 0.62 && profitFactor < 1.5) {
            m_atrTP2   = MathMin(5.0, m_atrTP2 + 0.3);
        } else if (winRate > 0.58 && profitFactor > 2.0) {
            m_adxMin   = MathMax(17, m_adxMin - 1);
            m_minScore = MathMax(6,  m_minScore - 1);
        }

        // R:R adjustment
        double rr = (avgLoss != 0) ? MathAbs(avgWin / avgLoss) : 0;
        if (rr < 1.5 && rr > 0) {
            m_atrTP2 = MathMin(5.0, m_atrTP2 + 0.2);
            Print(StringFormat("[Analyzer] R:R=%.2f → TP widened to %.1f", rr, m_atrTP2));
        }

        // SL adjustment based on PF
        if (profitFactor < 1.2)
            m_atrSL = MathMax(1.0, m_atrSL - 0.15);
        else if (profitFactor > 2.5)
            m_atrSL = MathMin(2.2, m_atrSL + 0.1);

        Print(StringFormat("[Analyzer] Params: SL=%.2f TP1=%.2f TP2=%.2f ADX=%d Score>=%d",
              m_atrSL, m_atrTP1, m_atrTP2, m_adxMin, m_minScore));
    }

    // ── Queries ──────────────────────────────────────────────────
    double GetCurrentATR() {
        double v[1]; return Buf(m_atrM5, v, 1) ? v[0] : 0;
    }
    double GetCurrentATRH1() {
        double v[1]; return Buf(m_atrH1, v, 1) ? v[0] : 0;
    }
    double GetMomentumBonus()  { return m_momentumBonus; }
    double GetAtrSLMultiplier(){ return m_atrSL; }
    double GetAtrTP1()         { return m_atrTP1; }
    double GetAtrTP2()         { return m_atrTP2; }

    // London: 07:00-16:00 GMT | NY: 13:00-21:00 GMT
    bool IsGoodSession() {
        MqlDateTime dt; TimeToStruct(TimeGMT(), dt);
        int h = dt.hour;
        return ((h >= 7 && h < 16) || (h >= 13 && h < 21)) && !(h >= 0 && h < 6);
    }
    // London/NY overlap 13:00-16:00 GMT = best for gold
    bool IsOverlapSession() {
        MqlDateTime dt; TimeToStruct(TimeGMT(), dt);
        return (dt.hour >= 13 && dt.hour < 16);
    }
    // Avoid 3 min around hour change (spread spike)
    bool IsNearHourChange() {
        MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
        return (dt.min >= 57 || dt.min <= 2);
    }

private:
    bool Buf(int handle, double &buf[], int n) {
        ArraySetAsSeries(buf, true);
        return CopyBuffer(handle, 0, 0, n, buf) == n;
    }
    bool MacdBuf(double &main[], double &sig[]) {
        ArraySetAsSeries(main, true); ArraySetAsSeries(sig, true);
        return CopyBuffer(m_macdM5, 0, 0, 2, main) == 2 &&
               CopyBuffer(m_macdM5, 1, 0, 2, sig)  == 2;
    }
    bool BBBuf(double &u[], double &m[], double &l[]) {
        ArraySetAsSeries(u, true); ArraySetAsSeries(m, true); ArraySetAsSeries(l, true);
        return CopyBuffer(m_bbM5, 1, 0, 1, u) == 1 &&
               CopyBuffer(m_bbM5, 0, 0, 1, m) == 1 &&
               CopyBuffer(m_bbM5, 2, 0, 1, l) == 1;
    }
    bool StochBuf(double &main[], double &sig[]) {
        ArraySetAsSeries(main, true); ArraySetAsSeries(sig, true);
        return CopyBuffer(m_stochM5, 0, 0, 1, main) == 1 &&
               CopyBuffer(m_stochM5, 1, 0, 1, sig)  == 1;
    }
    bool IchBuf(double &t[], double &k[], double &a[], double &b[]) {
        ArraySetAsSeries(t,true); ArraySetAsSeries(k,true);
        ArraySetAsSeries(a,true); ArraySetAsSeries(b,true);
        return CopyBuffer(m_ichimokuH1, 0, 0, 1, t) == 1 &&
               CopyBuffer(m_ichimokuH1, 1, 0, 1, k) == 1 &&
               CopyBuffer(m_ichimokuH1, 2, 0, 1, a) == 1 &&
               CopyBuffer(m_ichimokuH1, 3, 0, 1, b) == 1;
    }
    string SignalTypeStr(SignalType t) {
        if (t == SIG_MOMENTUM) return "MOMENTUM";
        if (t == SIG_PULLBACK) return "PULLBACK";
        if (t == SIG_BREAKOUT) return "BREAKOUT";
        return "GENERIC";
    }
};
