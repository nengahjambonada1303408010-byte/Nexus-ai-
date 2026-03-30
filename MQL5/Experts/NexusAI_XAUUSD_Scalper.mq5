//+------------------------------------------------------------------+
//|                                   NexusAI_XAUUSD_Scalper.mq5   |
//|                   Nexus AI v3 - XAUUSD AGGRESSIVE Self-Healing  |
//|                                                                  |
//|  3 Signal Types: MOMENTUM | PULLBACK | BREAKOUT                 |
//|  4 Timeframes  : H4 + H1 + M15 + M5                            |
//|  10 Indicators : EMA x5 + RSI + MACD + BB + ADX + CCI +        |
//|                  Stoch + Ichimoku + ATR                         |
//|  Execution     : Dual-TP (50% at 2R, runner to 3.5R)           |
//|                  Dynamic ATR trailing + Pyramid add-on          |
//|  Self-Healing  : 9-action engine, regime detection, Kelly lot   |
//|  Risk          : Tiered recovery (4 levels), Kelly-blended lot  |
//+------------------------------------------------------------------+

#property copyright "Nexus AI Trading"
#property link      "https://github.com/nengahjambonada1303408010-byte/nexus-ai-"
#property version   "3.00"
#property description "XAUUSD Aggressive Self-Healing Scalper v3"
#property strict

#include <NexusAI\RiskManager.mqh>
#include <NexusAI\MarketAnalyzer.mqh>
#include <NexusAI\SelfHealer.mqh>
#include <NexusAI\TradeManager.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "═══════ RISK MANAGEMENT ═══════"
input double InpRiskPercent     = 1.5;   // Base risk % per trade (Kelly-blended)
input double InpMaxDailyLoss    = 6.0;   // Max daily loss % before halt
input double InpMaxDrawdown     = 18.0;  // Max total DD % before halt
input int    InpMaxConsecLoss   = 4;     // Consecutive losses → recovery tier up
input int    InpMaxDailyTrades  = 30;    // Max trades per day
input bool   InpCompoundMode    = true;  // Risk scales with balance growth

input group "═══════ TRADE EXECUTION ═══════"
input ulong  InpMagicNumber     = 202401;  // EA Magic Number
input int    InpMaxSlippage     = 20;      // Max slippage (points)
input double InpTrailAtrMult    = 1.0;     // Trailing stop = ATR × this
input double InpBEAtrMult       = 0.8;     // Break-even after ATR × this profit
input bool   InpPyramidEnabled  = true;    // Add to winners (pyramid)
input double InpPyramidATR      = 1.5;     // Pyramid trigger at ATR × this profit

input group "═══════ SELF-HEALING AI ═══════"
input bool   InpSelfHealEnabled = true;    // Enable self-healing engine
input int    InpOptimizeCycle   = 20;      // Heal every N trades (min 15)
input bool   InpAutoReset       = true;    // Auto full-reset on critical degradation
input int    InpShortPauseMins  = 30;      // Short heal pause (minutes)
input int    InpLongPauseMins   = 120;     // Long heal pause (minutes)

input group "═══════ SIGNAL FILTERS ═══════"
input bool   InpSessionFilter   = true;    // Trade only London + NY sessions
input bool   InpOverlapBonus    = true;    // Extra signal strength in L/NY overlap
input bool   InpNewsFilter      = true;    // Avoid ±3 min around hour change
input double InpMaxSpreadPts    = 45;      // Max spread (points) to trade
input double InpMinATRPts       = 3.0;     // Min ATR in points (0 = disabled)

input group "═══════ DISPLAY ═══════"
input bool   InpShowPanel       = true;
input color  InpBGColor         = C'10,15,35';   // Dark navy background
input color  InpTextColor       = clrWhite;

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CRiskManager    g_risk;
CMarketAnalyzer g_analyzer;
CSelfHealer     g_healer;
CTradeManager   g_trader;

bool     g_ready           = false;
bool     g_healPaused      = false;
datetime g_healPauseEnd    = 0;
datetime g_lastBarTime     = 0;
int      g_lastDealCount   = 0;
string   g_lastSignal      = "Waiting...";
string   g_healStatus      = "OK";
int      g_signalCount     = 0;   // Total signals fired
datetime g_startTime       = 0;

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit() {
    Print("╔══════════════════════════════════════╗");
    Print("║  NEXUS AI v3 - XAUUSD Scalper        ║");
    Print("║  Aggressive Self-Healing Edition     ║");
    Print("╚══════════════════════════════════════╝");

    if (StringFind(_Symbol, "XAU") < 0 && StringFind(_Symbol, "GOLD") < 0)
        Print("[WARNING] Designed for XAUUSD/GOLD. Other symbols may be suboptimal.");

    g_risk.Init(InpRiskPercent, InpMaxDailyLoss, InpMaxDrawdown,
                InpMaxConsecLoss, InpMaxDailyTrades, InpCompoundMode);

    if (!g_analyzer.Init()) {
        Print("[FATAL] MarketAnalyzer init failed");
        return INIT_FAILED;
    }

    g_healer.Init(InpOptimizeCycle);

    g_trader.Init(InpMagicNumber, InpMaxSlippage, InpTrailAtrMult,
                  InpBEAtrMult, InpPyramidEnabled, InpPyramidATR);

    g_startTime = TimeCurrent();
    g_ready     = true;

    if (InpShowPanel) BuildPanel();
    EventSetTimer(15);

    PrintFormat("[NexusAI] READY | Risk=%.1f%% | DD limit=%.1f%% | Pyramid=%s | Magic=%d",
        InpRiskPercent, InpMaxDrawdown, InpPyramidEnabled?"ON":"OFF", (int)InpMagicNumber);
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
    g_analyzer.Deinit();
    EventKillTimer();
    ObjectsDeleteAll(0, "NX_");
    Print("[NexusAI] Stopped. Reason=" + IntegerToString(reason));
}

//+------------------------------------------------------------------+
//| Tick                                                             |
//+------------------------------------------------------------------+
void OnTick() {
    if (!g_ready) return;

    g_risk.Update();

    double atr = g_analyzer.GetCurrentATR();
    g_trader.ManagePositions(atr);

    ScanClosedTrades();

    // New M5 bar only
    datetime bar = iTime(_Symbol, PERIOD_M5, 0);
    if (bar == g_lastBarTime) {
        if (InpShowPanel) RefreshPanel();
        return;
    }
    g_lastBarTime = bar;

    OnNewBar();

    if (InpShowPanel) RefreshPanel();
}

void OnTimer() {
    if (InpSelfHealEnabled) RunHealCycle();
    if (InpShowPanel) RefreshPanel();
}

//+------------------------------------------------------------------+
//| New bar logic                                                    |
//+------------------------------------------------------------------+
void OnNewBar() {
    // Lift pause if expired
    if (g_healPaused) {
        if (TimeCurrent() >= g_healPauseEnd) {
            g_healPaused  = false;
            g_healStatus  = "OK - Resumed";
            Print("[NexusAI] Heal pause ended — trading resumed");
        } else {
            g_lastSignal = StringFormat("Paused: %d min remaining",
                (int)((g_healPauseEnd - TimeCurrent()) / 60));
            return;
        }
    }

    if (!g_risk.CanTrade()) return;
    if (g_trader.HasOpenPosition()) return;

    // Session guard
    if (InpSessionFilter && !g_analyzer.IsGoodSession()) {
        g_lastSignal = "Outside session (London/NY)"; return;
    }
    // News guard
    if (InpNewsFilter && g_analyzer.IsNearHourChange()) {
        g_lastSignal = "Near hour — spread guard"; return;
    }
    // Spread check
    double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
                     SymbolInfoDouble(_Symbol, SYMBOL_BID)) /
                    SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    if (spread > InpMaxSpreadPts) {
        g_lastSignal = StringFormat("Spread %.0f > %.0f pts", spread, InpMaxSpreadPts);
        return;
    }
    // ATR floor
    double atr = g_analyzer.GetCurrentATR();
    if (InpMinATRPts > 0 && atr < InpMinATRPts * SymbolInfoDouble(_Symbol, SYMBOL_POINT)) {
        g_lastSignal = StringFormat("ATR too low (%.1f pts)", atr / SymbolInfoDouble(_Symbol, SYMBOL_POINT));
        return;
    }

    // ── Generate signal ──
    SignalResult sig = g_analyzer.GenerateSignal();
    g_lastSignal = (sig.direction == 0) ? "No signal" : sig.reason;
    if (sig.direction == 0) return;

    // Bonus strength in London/NY overlap
    double effStrength = sig.strength;
    if (InpOverlapBonus && g_analyzer.IsOverlapSession())
        effStrength = MathMin(1.0, effStrength * 1.15);

    // Lot sizing (Kelly-blended, signal-strength scaled)
    double slPips = MathAbs(sig.entryPrice - sig.stopLoss) /
                   SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double lot = g_risk.CalcLotSize(slPips, atr, effStrength);
    if (lot <= 0) { Print("[NexusAI] Lot=0 skip"); return; }

    string comment = StringFormat("NX|%s|%s|str=%.0f%%",
        sig.direction == 1 ? "B" : "S",
        sig.type == SIG_MOMENTUM ? "MOM" : sig.type == SIG_PULLBACK ? "PB" : "BRK",
        effStrength * 100);

    bool opened = g_trader.OpenTrade(sig.direction, lot,
                                     sig.stopLoss,
                                     sig.takeProfit1,
                                     sig.takeProfit2,
                                     comment);
    if (opened) {
        g_signalCount++;
        PrintFormat("[NexusAI] ► %s %s | Lot=%.2f | SL=%.2f | TP1=%.2f | TP2=%.2f | RR=%.1f | %s",
            sig.direction == 1 ? "BUY" : "SELL",
            sig.type == SIG_MOMENTUM ? "MOMENTUM" :
            sig.type == SIG_PULLBACK ? "PULLBACK" : "BREAKOUT",
            lot, sig.stopLoss, sig.takeProfit1, sig.takeProfit2,
            sig.riskReward, sig.reason);
    }
}

//+------------------------------------------------------------------+
//| Scan for newly closed trades                                     |
//+------------------------------------------------------------------+
void ScanClosedTrades() {
    HistorySelect(TimeCurrent() - 86400, TimeCurrent());
    int cnt = 0;
    for (int i = 0; i < HistoryDealsTotal(); i++) {
        ulong t = HistoryDealGetTicket(i);
        if (HistoryDealGetInteger(t, DEAL_MAGIC)  != (long)InpMagicNumber) continue;
        if (HistoryDealGetString(t,  DEAL_SYMBOL) != _Symbol)              continue;
        if (HistoryDealGetInteger(t, DEAL_ENTRY)  != DEAL_ENTRY_OUT)       continue;
        cnt++;
    }

    if (cnt > g_lastDealCount) {
        g_lastDealCount = cnt;
        // Feed last closed trade to healer & risk manager
        for (int i = HistoryDealsTotal() - 1; i >= 0; i--) {
            ulong t = HistoryDealGetTicket(i);
            if (HistoryDealGetInteger(t, DEAL_MAGIC)  != (long)InpMagicNumber) continue;
            if (HistoryDealGetString(t,  DEAL_SYMBOL) != _Symbol)              continue;
            if (HistoryDealGetInteger(t, DEAL_ENTRY)  != DEAL_ENTRY_OUT)       continue;

            double profit = HistoryDealGetDouble(t, DEAL_PROFIT) +
                           HistoryDealGetDouble(t, DEAL_SWAP)    +
                           HistoryDealGetDouble(t, DEAL_COMMISSION);

            double adx = g_analyzer.GetCurrentATR() > 0 ? 25.0 : 15.0; // proxy

            g_risk.RecordTrade(profit > 0, profit);
            if (InpSelfHealEnabled)
                g_healer.RecordTrade(profit, g_lastSignal, adx);
            break;
        }
    }
}

//+------------------------------------------------------------------+
//| Self-healing cycle                                               |
//+------------------------------------------------------------------+
void RunHealCycle() {
    if (!g_healer.ShouldOptimize()) return;

    Print("[NexusAI] ╔═══ SELF-HEAL CYCLE ═══╗");
    Print(g_healer.GetFullReport());

    HealAction action = g_healer.Analyze();
    PerfStats  stats  = g_healer.GetStats();

    switch (action) {
        case HEAL_NONE:
            g_healStatus = StringFormat("OK | WR=%.0f%% PF=%.2f", stats.winRate*100, stats.profitFactor);
            break;

        case HEAL_TIGHTEN_ENTRY:
        case HEAL_WIDEN_TP:
        case HEAL_TIGHTEN_SL:
        case HEAL_WIDEN_SL:
        case HEAL_RELAX_ENTRY:
            g_analyzer.OptimizeParams(stats.winRate, stats.profitFactor, stats.avgWin, stats.avgLoss);
            g_healStatus = StringFormat("Healed: %s", ActionLabel(action));
            break;

        case HEAL_REDUCE_RISK:
            g_healStatus = "Healed: Risk reduced (recovery tier)";
            Print("[NexusAI] Reducing risk via recovery tier");
            break;

        case HEAL_PAUSE_SHORT:
            SetHealPause(InpShortPauseMins);
            g_healStatus = StringFormat("PAUSED %d min", InpShortPauseMins);
            break;

        case HEAL_PAUSE_LONG:
            SetHealPause(InpLongPauseMins);
            g_healStatus = StringFormat("PAUSED %d min (severe)", InpLongPauseMins);
            break;

        case HEAL_FULL_RESET:
            if (InpAutoReset) {
                SetHealPause(InpLongPauseMins);
                g_analyzer.Deinit();
                g_analyzer.Init();
                g_healStatus = "FULL RESET + " + IntegerToString(InpLongPauseMins) + "min pause";
                Print("[NexusAI] !!! FULL RESET executed !!!");
            }
            break;
    }

    Print("[NexusAI] ╚══ Heal done: " + g_healStatus + " ══╝");
}

void SetHealPause(int minutes) {
    g_healPaused  = true;
    g_healPauseEnd = TimeCurrent() + minutes * 60;
    PrintFormat("[NexusAI] Trading paused %d min until %s",
        minutes, TimeToString(g_healPauseEnd, TIME_MINUTES));
}

string ActionLabel(HealAction a) {
    switch (a) {
        case HEAL_TIGHTEN_ENTRY:  return "Entry tightened";
        case HEAL_RELAX_ENTRY:    return "Entry relaxed";
        case HEAL_WIDEN_TP:       return "TP widened";
        case HEAL_TIGHTEN_SL:     return "SL tightened";
        case HEAL_WIDEN_SL:       return "SL widened";
        default: return "Adjusted";
    }
}

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
void BuildPanel() {
    string p = "NX_";
    int x = 8, y = 15, w = 310, h = 22;

    // BG
    CreateRect(p+"BG", x-6, y-6, w, h*16+12, InpBGColor, InpBGColor);

    string names[] = {"T0","T1","T2","T3","T4","T5","T6","T7",
                       "T8","T9","T10","T11","T12","T13","T14","T15"};
    for (int i = 0; i < 16; i++) {
        string nm = p + names[i];
        ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, x);
        ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, y + i * h);
        ObjectSetInteger(0, nm, OBJPROP_COLOR, InpTextColor);
        ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, 8);
        ObjectSetString(0,  nm, OBJPROP_FONT, "Courier New");
        ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    }
}

void CreateRect(string name, int x, int y, int w, int h, color bg, color border) {
    ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
    ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
    ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
    ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
    ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
    ObjectSetInteger(0, name, OBJPROP_COLOR, border);
    ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
}

void RefreshPanel() {
    if (!InpShowPanel) return;
    PerfStats st = g_healer.GetStats();
    double bal   = AccountInfoDouble(ACCOUNT_BALANCE);
    double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
    double dd    = g_risk.GetDrawdown();
    double dayPL = g_risk.GetDailyPnLPct();

    auto L = [](string name, string text, color c) {
        ObjectSetString(0, name, OBJPROP_TEXT, text);
        ObjectSetInteger(0, name, OBJPROP_COLOR, c);
    };

    L("NX_T0",  "╔═ NEXUS AI v3  XAUUSD SCALPER ═╗", clrGold);
    L("NX_T1",  StringFormat("║ Status: %-28s║",
         g_risk.IsTradingHalted() ? "■ HALTED" :
         g_healPaused ? "■ HEAL PAUSE" : "● RUNNING"),
         g_risk.IsTradingHalted() ? clrRed : g_healPaused ? clrOrange : clrLime);
    L("NX_T2",  StringFormat("  Balance : $%-10.2f  Equity: $%.2f", bal, eq), clrWhite);
    L("NX_T3",  StringFormat("  Drawdown: %5.2f%%   Day P&L: %+.2f%%", dd, dayPL),
         dd > 10 ? clrOrange : clrWhite);
    L("NX_T4",  StringFormat("  Trades  : %-6d  Signals: %-6d Regime: %s",
         st.total, g_signalCount,
         g_healer.GetRegime()==REGIME_TRENDING?"TREND":
         g_healer.GetRegime()==REGIME_RANGING?"RANGE":"UNK"), clrWhite);
    L("NX_T5",  StringFormat("  Win Rate: %5.1f%%  (%d/%d)",
         st.winRate*100, st.wins, st.total),
         st.winRate >= 0.52 ? clrLime : clrOrange);
    L("NX_T6",  StringFormat("  PF: %4.2f  Exp: $%+6.2f  Kelly: %.1f%%",
         st.profitFactor, st.expectancy, st.kellyPct*100),
         st.profitFactor >= 1.5 ? clrLime : clrOrange);
    L("NX_T7",  StringFormat("  Sortino : %5.2f", g_risk.GetSortino()),
         g_risk.GetSortino() > 1.0 ? clrLime : clrWhite);
    L("NX_T8",  StringFormat("  Streak  : W%d L%d  RecoveryTier: %d",
         g_risk.GetConsecWins(), g_risk.GetConsecLosses(), g_risk.GetRecoveryTier()),
         g_risk.GetRecoveryTier() > 0 ? clrOrange : clrWhite);
    L("NX_T9",  StringFormat("  Today   : %dW/%dL  MaxTrades: %d",
         g_risk.GetDailyWins(), g_risk.GetDailyLosses(), InpMaxDailyTrades), clrWhite);
    L("NX_T10", StringFormat("  Session : %-8s  Spread: %.0f pts",
         g_analyzer.IsGoodSession() ? (g_analyzer.IsOverlapSession()?"OVERLAP":"ACTIVE"):"OFF",
         (SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID))/
         SymbolInfoDouble(_Symbol,SYMBOL_POINT)),
         g_analyzer.IsOverlapSession() ? clrGold :
         g_analyzer.IsGoodSession() ? clrLime : clrGray);
    L("NX_T11", StringFormat("  Pyramid : %-4s Adds: %-4d TP1 hits: %d",
         InpPyramidEnabled?"ON":"OFF", g_trader.GetPyramidAdds(), g_trader.GetTP1Hits()), clrWhite);
    L("NX_T12", StringFormat("  Open P&L: $%+8.2f  Positions: %d",
         g_trader.GetFloatingProfit(), g_trader.OpenPositionCount()),
         g_trader.GetFloatingProfit() > 0 ? clrLime :
         g_trader.GetFloatingProfit() < 0 ? clrRed : clrWhite);
    L("NX_T13", "  Last Signal: " + StringSubstr(g_lastSignal, 0, 45), clrCyan);
    L("NX_T14", "  Heal: " + StringSubstr(g_healStatus, 0, 45),
         StringFind(g_healStatus,"OK")>=0 ? clrLime :
         StringFind(g_healStatus,"PAUSED")>=0 ? clrOrange : clrYellow);
    L("NX_T15", StringFormat("  v3.0 | Magic: %d | Up: %dh",
         (int)InpMagicNumber, (int)((TimeCurrent()-g_startTime)/3600)), clrDimGray);

    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Transaction hook                                                 |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& req,
                        const MqlTradeResult&  res) {
    if (trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
    if (!HistoryDealSelect(trans.deal)) return;
    if (HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != (long)InpMagicNumber) return;
    if (HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;

    double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) +
                   HistoryDealGetDouble(trans.deal, DEAL_SWAP)    +
                   HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
    PrintFormat("[NexusAI] ◄ Position closed | P&L: $%+.2f", profit);
}
