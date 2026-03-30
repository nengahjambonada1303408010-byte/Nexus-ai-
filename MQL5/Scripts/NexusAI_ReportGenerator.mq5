//+------------------------------------------------------------------+
//|                                      NexusAI_ReportGenerator.mq5|
//|                           Nexus AI - XAUUSD Scalper Self-Healing |
//|        Script: Generate detailed performance report to CSV/HTML  |
//+------------------------------------------------------------------+
#property copyright "Nexus AI"
#property version   "1.00"
#property script_show_inputs

input int    InpLookbackDays = 30;        // Lookback period (days)
input ulong  InpMagicNumber  = 202401;    // EA Magic Number
input bool   InpSaveHTML     = true;      // Save HTML report
input bool   InpSaveCSV      = true;      // Save CSV data

void OnStart() {
    Print("=== Nexus AI Report Generator ===");

    datetime from = TimeCurrent() - InpLookbackDays * 86400;
    datetime to   = TimeCurrent();

    if (!HistorySelect(from, to)) {
        Print("ERROR: HistorySelect failed");
        return;
    }

    // Collect trades
    struct TradeRecord {
        datetime closeTime;
        string   type;
        double   lots;
        double   openPrice;
        double   closePrice;
        double   sl, tp;
        double   profit;
        double   swap;
        double   commission;
        string   comment;
    };

    TradeRecord trades[];
    int count = 0;

    for (uint i = 0; i < (uint)HistoryDealsTotal(); i++) {
        ulong ticket = HistoryDealGetTicket(i);
        if (HistoryDealGetInteger(ticket, DEAL_MAGIC) != (long)InpMagicNumber) continue;
        if (HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

        ArrayResize(trades, count + 1);
        trades[count].closeTime  = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
        trades[count].type       = HistoryDealGetInteger(ticket, DEAL_TYPE) == DEAL_TYPE_BUY ? "BUY" : "SELL";
        trades[count].lots       = HistoryDealGetDouble(ticket, DEAL_VOLUME);
        trades[count].openPrice  = HistoryDealGetDouble(ticket, DEAL_PRICE);
        trades[count].closePrice = HistoryDealGetDouble(ticket, DEAL_PRICE);
        trades[count].profit     = HistoryDealGetDouble(ticket, DEAL_PROFIT);
        trades[count].swap       = HistoryDealGetDouble(ticket, DEAL_SWAP);
        trades[count].commission = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
        trades[count].comment    = HistoryDealGetString(ticket, DEAL_COMMENT);
        count++;
    }

    Print("Found " + IntegerToString(count) + " closed trades");

    if (count == 0) {
        Print("No trades found for magic " + IntegerToString((int)InpMagicNumber));
        return;
    }

    // Calculate statistics
    int    wins = 0, losses = 0;
    double totalProfit = 0, totalLoss = 0;
    double maxWin = 0, maxLoss = 0;
    double runningPL = 0, peakPL = 0, maxDD = 0;

    for (int i = 0; i < count; i++) {
        double net = trades[i].profit + trades[i].swap + trades[i].commission;
        if (net > 0) { wins++; totalProfit += net; maxWin  = MathMax(maxWin, net); }
        else         { losses++; totalLoss += net; maxLoss = MathMin(maxLoss, net); }
        runningPL += net;
        if (runningPL > peakPL) peakPL = runningPL;
        double dd = peakPL - runningPL;
        if (dd > maxDD) maxDD = dd;
    }

    double winRate      = count > 0 ? (double)wins / count : 0;
    double profitFactor = totalLoss != 0 ? totalProfit / MathAbs(totalLoss) : totalProfit;
    double avgWin       = wins   > 0 ? totalProfit / wins   : 0;
    double avgLoss      = losses > 0 ? totalLoss   / losses : 0;
    double expectancy   = (winRate * avgWin) + ((1 - winRate) * avgLoss);

    // Print summary
    PrintFormat("Total Trades:   %d", count);
    PrintFormat("Win Rate:       %.1f%% (%d/%d)", winRate * 100, wins, count);
    PrintFormat("Profit Factor:  %.2f", profitFactor);
    PrintFormat("Total P&L:      $%.2f", totalProfit + totalLoss);
    PrintFormat("Avg Win:        $%.2f | Avg Loss: $%.2f", avgWin, avgLoss);
    PrintFormat("Expectancy:     $%.2f/trade", expectancy);
    PrintFormat("Max Drawdown:   $%.2f", maxDD);
    PrintFormat("Best Trade:     $%.2f | Worst: $%.2f", maxWin, maxLoss);

    // Save CSV
    if (InpSaveCSV) {
        string fname = StringFormat("NexusAI_Report_%s.csv",
            TimeToString(TimeCurrent(), TIME_DATE));
        StringReplace(fname, ".", "-");
        StringReplace(fname, ":", "-");

        int fh = FileOpen(fname, FILE_WRITE | FILE_CSV | FILE_COMMON);
        if (fh != INVALID_HANDLE) {
            FileWrite(fh, "Time","Type","Lots","OpenPrice","ClosePrice","Profit","Swap","Commission","Net","Comment");
            for (int i = 0; i < count; i++) {
                double net = trades[i].profit + trades[i].swap + trades[i].commission;
                FileWrite(fh,
                    TimeToString(trades[i].closeTime),
                    trades[i].type,
                    DoubleToString(trades[i].lots, 2),
                    DoubleToString(trades[i].openPrice, 5),
                    DoubleToString(trades[i].closePrice, 5),
                    DoubleToString(trades[i].profit, 2),
                    DoubleToString(trades[i].swap, 2),
                    DoubleToString(trades[i].commission, 2),
                    DoubleToString(net, 2),
                    trades[i].comment
                );
            }
            FileClose(fh);
            Print("CSV saved: " + fname);
        }
    }

    // Save HTML Report
    if (InpSaveHTML) {
        string htmlFile = "NexusAI_Report.html";
        int fh = FileOpen(htmlFile, FILE_WRITE | FILE_TXT | FILE_COMMON);
        if (fh != INVALID_HANDLE) {
            string winColor   = wins > losses ? "#2ecc71" : "#e74c3c";
            string pfColor    = profitFactor >= 1.5 ? "#2ecc71" : profitFactor >= 1.0 ? "#f39c12" : "#e74c3c";
            string totalColor = (totalProfit + totalLoss) >= 0 ? "#2ecc71" : "#e74c3c";

            string html = "<!DOCTYPE html><html><head>";
            html += "<title>Nexus AI - Performance Report</title>";
            html += "<style>body{background:#1a1a2e;color:#eee;font-family:Arial;padding:20px}";
            html += ".card{background:#16213e;border-radius:8px;padding:20px;margin:10px;display:inline-block;min-width:160px;text-align:center}";
            html += ".val{font-size:28px;font-weight:bold;margin:8px 0}";
            html += ".lbl{font-size:12px;color:#888}";
            html += "h1{color:gold}table{width:100%;border-collapse:collapse;margin-top:20px}";
            html += "th{background:#0f3460;padding:8px}td{padding:6px;border-bottom:1px solid #333}";
            html += "tr:hover{background:#1e3a5f}</style></head><body>";

            html += "<h1>&#9733; NEXUS AI - XAUUSD Scalper Report</h1>";
            html += StringFormat("<p style='color:#888'>Generated: %s | Period: Last %d days | Magic: %d</p>",
                TimeToString(TimeCurrent()), InpLookbackDays, (int)InpMagicNumber);

            // Stats cards
            html += StringFormat(
                "<div class='card'><div class='lbl'>Total Trades</div><div class='val'>%d</div></div>",
                count);
            html += StringFormat(
                "<div class='card'><div class='lbl'>Win Rate</div><div class='val' style='color:%s'>%.1f%%</div></div>",
                winColor, winRate * 100);
            html += StringFormat(
                "<div class='card'><div class='lbl'>Profit Factor</div><div class='val' style='color:%s'>%.2f</div></div>",
                pfColor, profitFactor);
            html += StringFormat(
                "<div class='card'><div class='lbl'>Total P&amp;L</div><div class='val' style='color:%s'>$%.2f</div></div>",
                totalColor, totalProfit + totalLoss);
            html += StringFormat(
                "<div class='card'><div class='lbl'>Expectancy</div><div class='val'>$%.2f</div></div>",
                expectancy);
            html += StringFormat(
                "<div class='card'><div class='lbl'>Max Drawdown</div><div class='val' style='color:#f39c12'>$%.2f</div></div>",
                maxDD);

            // Trades table
            html += "<h2 style='color:gold;margin-top:30px'>Trade History</h2>";
            html += "<table><tr><th>Time</th><th>Type</th><th>Lots</th><th>Open</th><th>Close</th><th>Net P&L</th><th>Comment</th></tr>";

            for (int i = count - 1; i >= 0; i--) {
                double net = trades[i].profit + trades[i].swap + trades[i].commission;
                string rowColor = net > 0 ? "#1a3a1a" : "#3a1a1a";
                string netColor = net > 0 ? "#2ecc71" : "#e74c3c";
                html += StringFormat(
                    "<tr style='background:%s'><td>%s</td><td>%s</td><td>%.2f</td><td>%.2f</td><td>%.2f</td>"
                    "<td style='color:%s;font-weight:bold'>$%.2f</td><td>%s</td></tr>",
                    rowColor,
                    TimeToString(trades[i].closeTime),
                    trades[i].type,
                    trades[i].lots,
                    trades[i].openPrice,
                    trades[i].closePrice,
                    netColor, net,
                    trades[i].comment
                );
            }
            html += "</table></body></html>";

            FileWriteString(fh, html);
            FileClose(fh);
            Print("HTML report saved: " + htmlFile);
        }
    }

    Print("=== Report generation complete ===");
}
