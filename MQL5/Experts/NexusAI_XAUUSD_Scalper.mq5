//+------------------------------------------------------------------+
//|                                   NexusAI_XAUUSD_Scalper.mq5   |
//|                           Nexus AI - XAUUSD Self-Healing Scalper |
//|                                                                  |
//|  STRATEGI:                                                       |
//|  - Multi-timeframe confluence (H1 trend + M15 konfirmasi + M5)  |
//|  - 7 indikator: EMA, RSI, MACD, BB, Stoch, ADX, Ichimoku       |
//|  - Session filter: London + NY (08:00-21:00 GMT+7)             |
//|  - ATR-based dynamic SL/TP                                       |
//|  - Trailing stop + Break-even otomatis                          |
//|  - Self-healing: auto-optimize parameter tiap 20 trade          |
//|  - Self-repair: reduce risk, pause, atau reset saat degradasi   |
//|  - Recovery mode: lot lebih kecil setelah consecutive losses    |
//+------------------------------------------------------------------+

#property copyright "Nexus AI Trading System"
#property link      "https://github.com/nengahjambonada1303408010-byte/nexus-ai-"
#property version   "2.00"
#property description "XAUUSD Self-Healing Scalper with AI Self-Optimization"
#property strict

#include <NexusAI\RiskManager.mqh>
#include <NexusAI\MarketAnalyzer.mqh>
#include <NexusAI\SelfHealer.mqh>
#include <NexusAI\TradeManager.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "=== RISK MANAGEMENT ==="
input double InpRiskPercent     = 1.0;   // Risk % per trade
input double InpMaxDailyLoss    = 5.0;   // Max daily loss %
input double InpMaxDrawdown     = 15.0;  // Max total drawdown %
input int    InpMaxConsecLoss   = 5;     // Max consecutive losses
input int    InpMaxDailyTrades  = 25;    // Max trades per day

input group "=== TRADE SETTINGS ==="
input ulong  InpMagicNumber     = 202401;  // EA Magic Number
input int    InpMaxSlippage     = 30;      // Max slippage (points)
input double InpTrailStartPips  = 15.0;    // Trail start (pips)
input double InpTrailStepPips   = 8.0;     // Trail step (pips)
input double InpBreakEvenPips   = 10.0;    // Break-even pips

input group "=== SELF-HEALING ==="
input bool   InpSelfHealEnabled = true;    // Enable self-healing engine
input int    InpOptimizeCycle   = 20;      // Optimize every N trades
input bool   InpAutoReset       = true;    // Auto-reset params if critical
input int    InpHealPauseMins   = 60;      // Pause duration after heal (min)

input group "=== FILTERS ==="
input bool   InpSessionFilter   = true;    // Use session filter
input bool   InpNewsFilter      = true;    // Avoid news times
input double InpMinATR          = 0.5;     // Minimum ATR to trade (0=off)
input double InpMaxSpreadPts    = 50;      // Max spread in points

input group "=== DISPLAY ==="
input bool   InpShowPanel       = true;    // Show info panel
input color  InpPanelBG         = clrMidnightBlue;
input color  InpPanelText       = clrWhite;

//+------------------------------------------------------------------+
//| Global Objects                                                   |
//+------------------------------------------------------------------+
CRiskManager    g_risk;
CMarketAnalyzer g_analyzer;
CSelfHealer     g_healer;
CTradeManager   g_trader;

// State
bool     g_initialized      = false;
bool     g_healPause         = false;
datetime g_healPauseEnd      = 0;
int      g_lastTradeCount    = 0;
datetime g_lastBarTime       = 0;
string   g_lastSignalReason  = "Waiting...";
string   g_healStatus        = "OK";

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
    Print("==================================================");
    Print(" NEXUS AI - XAUUSD Self-Healing Scalper v2.0 ");
    Print("==================================================");

    // Validate symbol
    if (StringFind(_Symbol, "XAU") < 0 && StringFind(_Symbol, "GOLD") < 0) {
        Print("WARNING: This EA is optimized for XAUUSD/GOLD");
    }

    // Initialize modules
    g_risk.Init(InpRiskPercent, InpMaxDailyLoss, InpMaxDrawdown,
                InpMaxConsecLoss, InpMaxDailyTrades);

    if (!g_analyzer.Init()) {
        Print("ERROR: Market analyzer initialization failed!");
        return INIT_FAILED;
    }

    g_healer.Init(InpOptimizeCycle);

    g_trader.Init(InpMagicNumber, InpMaxSlippage, InpTrailStartPips,
                  InpTrailStepPips, InpBreakEvenPips);

    g_initialized = true;

    // Draw panel
    if (InpShowPanel) CreatePanel();

    EventSetTimer(30); // Update every 30 seconds
    Print("[NexusAI] Initialization complete. Ready to trade.");
    Print(StringFormat("[NexusAI] Risk: %.1f%% | Max DD: %.1f%% | Magic: %d",
          InpRiskPercent, InpMaxDrawdown, (int)InpMagicNumber));

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    g_analyzer.Deinit();
    EventKillTimer();
    ObjectsDeleteAll(0, "NexusAI_");
    Print("[NexusAI] Deinitialized. Reason: " + IntegerToString(reason));
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
    if (!g_initialized) return;

    // Update risk manager every tick
    g_risk.Update();

    // Manage open positions (trailing, BE)
    g_trader.ManagePositions();

    // Check for new closed trade -> feed to self-healer
    CheckNewClosedTrades();

    // Only process new bar to avoid signal spam
    datetime barTime = iTime(_Symbol, PERIOD_M5, 0);
    if (barTime == g_lastBarTime) {
        if (InpShowPanel) UpdatePanel();
        return;
    }
    g_lastBarTime = barTime;

    // --- Main trading logic on new M5 bar ---
    ProcessNewBar();

    if (InpShowPanel) UpdatePanel();
}

//+------------------------------------------------------------------+
//| Timer event                                                      |
//+------------------------------------------------------------------+
void OnTimer() {
    // Self-heal check every 30 seconds
    if (InpSelfHealEnabled) {
        RunSelfHealCycle();
    }
    if (InpShowPanel) UpdatePanel();
}

//+------------------------------------------------------------------+
//| Process new M5 bar                                               |
//+------------------------------------------------------------------+
void ProcessNewBar() {
    // Check heal pause
    if (g_healPause && TimeCurrent() < g_healPauseEnd) {
        g_lastSignalReason = StringFormat("Heal pause: %d min left",
            (int)((g_healPauseEnd - TimeCurrent()) / 60));
        return;
    }
    if (g_healPause && TimeCurrent() >= g_healPauseEnd) {
        g_healPause  = false;
        g_healStatus = "OK - Resumed";
        Print("[NexusAI] Heal pause ended - resuming trading");
    }

    // Risk checks
    if (!g_risk.CanTrade()) return;

    // Don't open new trade if we have one
    if (g_trader.HasOpenPosition()) return;

    // Session filter
    if (InpSessionFilter && !g_analyzer.IsGoodSession()) {
        g_lastSignalReason = "Outside trading session";
        return;
    }

    // News filter
    if (InpNewsFilter && g_analyzer.IsNearNews()) {
        g_lastSignalReason = "Near news time - waiting";
        return;
    }

    // Spread check
    double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double spreadPts = spread / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    if (spreadPts > InpMaxSpreadPts) {
        g_lastSignalReason = StringFormat("Spread too wide: %.0f pts", spreadPts);
        return;
    }

    // ATR filter
    double atr = g_analyzer.GetCurrentATR();
    if (InpMinATR > 0 && atr < InpMinATR * SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10) {
        g_lastSignalReason = "ATR too low - market consolidating";
        return;
    }

    // Generate signal
    SignalResult sig = g_analyzer.GenerateSignal();
    g_lastSignalReason = sig.reason == "" ? "No signal" : sig.reason;

    if (sig.direction == 0) return;

    // Calculate lot size
    double slPips = MathAbs(sig.entryPrice - sig.stopLoss) /
                   (SymbolInfoDouble(_Symbol, SYMBOL_POINT));
    double lot = g_risk.CalcLotSize(slPips, atr);

    if (lot <= 0) {
        Print("[NexusAI] Lot size = 0, skipping trade");
        return;
    }

    // Execute trade
    string comment = StringFormat("NexusAI|%s|str=%.0f%%",
        sig.direction == 1 ? "BUY" : "SELL",
        sig.strength * 100);

    bool opened = g_trader.OpenTrade(sig.direction, lot, sig.stopLoss, sig.takeProfit, comment);

    if (opened) {
        PrintFormat("[NexusAI] TRADE OPENED: %s %.2f lots | SL=%.2f TP=%.2f | %s",
            sig.direction == 1 ? "BUY" : "SELL",
            lot, sig.stopLoss, sig.takeProfit, sig.reason);
    }
}

//+------------------------------------------------------------------+
//| Check for newly closed trades                                    |
//+------------------------------------------------------------------+
void CheckNewClosedTrades() {
    HistorySelect(TimeCurrent() - 86400, TimeCurrent());
    int currentCount = 0;

    for (int i = 0; i < HistoryDealsTotal(); i++) {
        ulong ticket = HistoryDealGetTicket(i);
        if (HistoryDealGetInteger(ticket, DEAL_MAGIC)  != (long)InpMagicNumber) continue;
        if (HistoryDealGetString(ticket, DEAL_SYMBOL)  != _Symbol) continue;
        if (HistoryDealGetInteger(ticket, DEAL_ENTRY)  != DEAL_ENTRY_OUT) continue;
        currentCount++;
    }

    if (currentCount > g_lastTradeCount) {
        // New trade(s) closed
        int newTrades = currentCount - g_lastTradeCount;
        g_lastTradeCount = currentCount;

        // Get the latest closed trade profit
        for (int i = HistoryDealsTotal() - 1; i >= 0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if (HistoryDealGetInteger(ticket, DEAL_MAGIC)  != (long)InpMagicNumber) continue;
            if (HistoryDealGetString(ticket, DEAL_SYMBOL)  != _Symbol) continue;
            if (HistoryDealGetInteger(ticket, DEAL_ENTRY)  != DEAL_ENTRY_OUT) continue;

            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT) +
                           HistoryDealGetDouble(ticket, DEAL_SWAP) +
                           HistoryDealGetDouble(ticket, DEAL_COMMISSION);
            bool win = profit > 0;

            // Feed to both risk manager and self-healer
            g_risk.RecordTrade(win, profit);

            if (InpSelfHealEnabled) {
                string reason = g_lastSignalReason;
                g_healer.RecordTrade(profit, 0, 0, 0, reason);
            }
            break;
        }
    }
}

//+------------------------------------------------------------------+
//| Self-Healing Cycle                                               |
//+------------------------------------------------------------------+
void RunSelfHealCycle() {
    if (!g_healer.ShouldOptimize()) return;

    Print("[NexusAI] ====== SELF-HEAL CYCLE ======");

    HealAction action = g_healer.Analyze();
    PerfStats stats   = g_healer.GetStats();

    Print(g_healer.GetStatsReport());

    switch (action) {
        case HEAL_NONE:
            g_healStatus = StringFormat("OK | WR=%.0f%% PF=%.2f",
                stats.winRate * 100, stats.profitFactor);
            break;

        case HEAL_TIGHTEN_ENTRY:
            g_analyzer.OptimizeParams(stats.winRate, stats.profitFactor);
            g_healStatus = "Healed: Tightened entry filters";
            Print("[NexusAI] Self-heal: Entry criteria tightened");
            break;

        case HEAL_WIDEN_TP:
            g_analyzer.OptimizeParams(stats.winRate, stats.profitFactor);
            g_healStatus = "Healed: TP widened";
            Print("[NexusAI] Self-heal: Take profit widened");
            break;

        case HEAL_TIGHTEN_SL:
            g_analyzer.OptimizeParams(stats.winRate, stats.profitFactor);
            g_healStatus = "Healed: SL tightened";
            Print("[NexusAI] Self-heal: Stop loss tightened");
            break;

        case HEAL_REDUCE_RISK: {
            // Already handled in risk manager via recovery mode
            g_healStatus = "Healed: Risk reduced";
            Print("[NexusAI] Self-heal: Entering reduced risk mode");
            break;
        }

        case HEAL_PAUSE_TRADING: {
            g_healPause   = true;
            g_healPauseEnd = TimeCurrent() + InpHealPauseMins * 60;
            g_healStatus  = StringFormat("PAUSED %d min - recovering", InpHealPauseMins);
            Print(StringFormat("[NexusAI] Self-heal: PAUSING %d minutes. WR=%.0f%% PF=%.2f",
                InpHealPauseMins, stats.winRate * 100, stats.profitFactor));
            break;
        }

        case HEAL_RESET_PARAMS:
            if (InpAutoReset) {
                g_healPause   = true;
                g_healPauseEnd = TimeCurrent() + 120 * 60; // 2 hour pause
                g_healStatus  = "RESET - 2hr pause";
                Print("[NexusAI] !!! CRITICAL: Resetting parameters + 2hr pause !!!");
                // Re-init analyzer with defaults
                g_analyzer.Deinit();
                g_analyzer.Init();
            }
            break;

        case HEAL_INCREASE_FILTERS:
            g_analyzer.OptimizeParams(stats.winRate * 0.9, stats.profitFactor); // Force tighten
            g_healStatus = "Healed: More filters added";
            break;
    }

    Print("[NexusAI] Self-heal complete: " + g_healStatus);
}

//+------------------------------------------------------------------+
//| Panel display                                                    |
//+------------------------------------------------------------------+
void CreatePanel() {
    string prefix = "NexusAI_";
    int x = 10, y = 20, w = 280, lineH = 18;

    // Background
    string bg = prefix + "BG";
    ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
    ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, x - 5);
    ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, y - 5);
    ObjectSetInteger(0, bg, OBJPROP_XSIZE, w);
    ObjectSetInteger(0, bg, OBJPROP_YSIZE, lineH * 13 + 15);
    ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, InpPanelBG);
    ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, bg, OBJPROP_COLOR, InpPanelBG);

    // Create label slots
    string labels[] = {"Title","Status","Balance","Equity","DD","Trades","WinRate",
                        "PF","ConsecLoss","Session","Signal","Heal","Version"};
    for (int i = 0; i < ArraySize(labels); i++) {
        string name = prefix + labels[i];
        ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
        ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y + i * lineH);
        ObjectSetInteger(0, name, OBJPROP_COLOR, InpPanelText);
        ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
        ObjectSetString(0,  name, OBJPROP_FONT, "Courier New");
    }
}

void UpdatePanel() {
    if (!InpShowPanel) return;
    string prefix = "NexusAI_";
    PerfStats stats = g_healer.GetStats();
    double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
    double equity   = AccountInfoDouble(ACCOUNT_EQUITY);

    SetLabel(prefix + "Title",     "=== NEXUS AI XAUUSD SCALPER ===",  clrGold);
    SetLabel(prefix + "Status",    "Status: " + (g_risk.IsTradingHalted() ? "HALTED" :
             g_healPause ? "HEAL PAUSE" : "RUNNING"),
             g_risk.IsTradingHalted() ? clrRed : g_healPause ? clrOrange : clrLime);
    SetLabel(prefix + "Balance",   StringFormat("Balance:  $%.2f", balance),   clrWhite);
    SetLabel(prefix + "Equity",    StringFormat("Equity:   $%.2f", equity),    clrWhite);
    SetLabel(prefix + "DD",        StringFormat("Drawdown: %.2f%%", g_risk.GetDrawdown()),
             g_risk.GetDrawdown() > 10 ? clrOrange : clrWhite);
    SetLabel(prefix + "Trades",    StringFormat("Trades: %d (today: %d)",
             stats.totalTrades, g_risk.GetDailyTrades()), clrWhite);
    SetLabel(prefix + "WinRate",   StringFormat("Win Rate: %.1f%%  (%d/%d)",
             stats.winRate * 100, stats.winTrades, stats.totalTrades),
             stats.winRate >= 0.5 ? clrLime : clrOrange);
    SetLabel(prefix + "PF",        StringFormat("Prof Fctr: %.2f  Exp: %.2f",
             stats.profitFactor, stats.expectancy),
             stats.profitFactor >= 1.5 ? clrLime : clrOrange);
    SetLabel(prefix + "ConsecLoss",StringFormat("Consec Loss: %d  Recovery: %s",
             g_risk.GetConsecLosses(), g_risk.IsInRecovery() ? "YES" : "No"),
             g_risk.GetConsecLosses() >= 3 ? clrOrange : clrWhite);
    SetLabel(prefix + "Session",   StringFormat("Session: %s  Spread: %.0f pts",
             g_analyzer.IsGoodSession() ? "ACTIVE" : "LOW",
             (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) /
             SymbolInfoDouble(_Symbol, SYMBOL_POINT)),
             g_analyzer.IsGoodSession() ? clrLime : clrGray);
    SetLabel(prefix + "Signal",    StringFormat("Last: %s", g_lastSignalReason), clrCyan);
    SetLabel(prefix + "Heal",      "Heal: " + g_healStatus,
             StringFind(g_healStatus, "OK") >= 0 ? clrLime :
             StringFind(g_healStatus, "PAUSED") >= 0 ? clrOrange : clrYellow);
    SetLabel(prefix + "Version",   "v2.0 | Magic: " + IntegerToString((int)InpMagicNumber), clrDimGray);

    ChartRedraw();
}

void SetLabel(string name, string text, color clr) {
    ObjectSetString(0, name, OBJPROP_TEXT, text);
    ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
//| Trade transaction handler                                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result) {
    // Log position closed
    if (trans.type == TRADE_TRANSACTION_DEAL_ADD) {
        if (trans.deal_type == DEAL_TYPE_BUY || trans.deal_type == DEAL_TYPE_SELL) {
            if (HistoryDealSelect(trans.deal)) {
                if (HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
                    double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
                    PrintFormat("[NexusAI] Deal closed: Profit=%.2f", profit);
                }
            }
        }
    }
}
