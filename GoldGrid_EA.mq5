//+------------------------------------------------------------------+
//| GoldGrid_EA.mq5 v3.0 - Trend Core + Grid Overlay + Compounding  |
//| Core rides trend with trailing SL | Grid captures pullbacks       |
//| Dynamic lot sizing based on equity growth                         |
//+------------------------------------------------------------------+
#property copyright "GoldGrid"
#property version   "3.00"

#include <Trade/Trade.mqh>

#define SLIPPAGE     30

//=====================================================================
// INPUT PARAMETERS
//=====================================================================
input group "=== Global ==="
input int      InpMagic           = 500000;
input double   InpBaseLot         = 0.05;
input double   InpMaxSpreadUSD    = 3.0;

input group "=== Compounding ==="
input double   InpEquityPerLot    = 10000.0;

input group "=== Trend Filter ==="
input int      InpEMA_Fast        = 21;
input int      InpEMA_Slow        = 50;
input double   InpRSI_Entry       = 40.0;
input double   InpRSI_Avoid       = 65.0;

input group "=== Core Trend Position ==="
input bool     InpEnableCore      = true;
input double   InpTrailATRMult    = 1.5;

input group "=== Grid Structure ==="
input double   InpGridSpacing     = 6.0;
input int      InpOrdersPerTier   = 3;
input int      InpMaxTiers        = 3;
input double   InpLotMultiplier   = 1.5;
input int      InpMaxGridsPerDay  = 2;

input group "=== Grid Take Profit ==="
input double   InpTPFromAvg       = 5.0;
input double   InpTPMinProfit     = 0.0;

input group "=== Cooldown ==="
input int      InpCooldownAfterTP   = 300;
input int      InpCooldownAfterLoss = 7200;
input int      InpCooldownCoreReopen = 3600;
input bool     InpCloseBeforeWeekend = true;

input group "=== Session (Server UTC+0) ==="
input int      InpStartHour       = 5;
input int      InpEndHour         = 20;
input int      InpFridayClose     = 20;

input group "=== Safety (0=disabled) ==="
input double   InpMaxDrawdownPct  = 30.0;
input double   InpMaxTotalLots    = 0.0;
input int      InpDDPauseHours    = 24;

//=====================================================================
// GLOBAL STATE
//=====================================================================
CTrade   g_trade;
datetime g_lastGridClose     = 0;
datetime g_lastCoreClose     = 0;
datetime g_lastBarTime       = 0;
datetime g_lastH1BarTime     = 0;
double   g_initialEquity     = 0;
bool     g_lastGridWasLoss   = false;
int      g_gridsToday        = 0;
int      g_lastResetDay      = -1;
datetime g_ddPauseUntil      = 0;
ulong    g_coreTicket        = 0;

int      g_hH1EMAFast        = INVALID_HANDLE;
int      g_hH1EMASlow        = INVALID_HANDLE;
int      g_hRSI              = INVALID_HANDLE;
int      g_hM5ATR            = INVALID_HANDLE;
int      g_hH1ATR            = INVALID_HANDLE;

//=====================================================================
// UTILITY FUNCTIONS
//=====================================================================
double Ind(int handle, int buf, int shift) {
   double v[];
   if(CopyBuffer(handle, buf, shift, 1, v) != 1) return 0.0;
   return v[0];
}

double NL(double lots) {
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(st <= 0) st = 0.01;
   lots = MathMax(mn, MathMin(mx, lots));
   return NormalizeDouble(MathFloor(lots / st) * st, 2);
}

ENUM_ORDER_TYPE_FILLING DetectFilling() {
   long fm = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if(fm & SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if(fm & SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

bool IsSpreadOK() {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return (ask - bid <= InpMaxSpreadUSD);
}

bool IsSessionActive() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;
   if(dt.day_of_week == 5 && dt.hour >= InpFridayClose) return false;
   if(dt.day_of_week == 1 && dt.hour < 1) return false;
   return (dt.hour >= InpStartHour && dt.hour < InpEndHour);
}

bool IsWeekendClose() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 5 && dt.hour >= InpFridayClose) return true;
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return true;
   return false;
}

void CheckDailyReset() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day != g_lastResetDay) {
      g_gridsToday = 0;
      g_lastResetDay = dt.day;
   }
}

//=====================================================================
// COMPOUNDING: DYNAMIC LOT BASED ON EQUITY
//=====================================================================
double CalcCompoundLot(double baseLot) {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double mult = equity / InpEquityPerLot;
   if(mult < 1.0) mult = 1.0;
   return NL(baseLot * mult);
}

//=====================================================================
// TREND DETECTION
//=====================================================================
bool IsTrendUp() {
   double emaFast = Ind(g_hH1EMAFast, 0, 1);
   double emaSlow = Ind(g_hH1EMASlow, 0, 1);
   if(emaFast <= 0 || emaSlow <= 0) return false;
   return (emaFast > emaSlow);
}

bool CheckGridEntrySignal() {
   double emaFast1 = Ind(g_hH1EMAFast, 0, 1);
   double emaSlow1 = Ind(g_hH1EMASlow, 0, 1);
   double emaFast2 = Ind(g_hH1EMAFast, 0, 2);
   double emaSlow2 = Ind(g_hH1EMASlow, 0, 2);
   if(emaFast1 <= 0 || emaSlow1 <= 0) return false;
   if(emaFast1 <= emaSlow1 || emaFast2 <= emaSlow2) return false;
   double h1Close = iClose(_Symbol, PERIOD_H1, 1);
   if(h1Close <= 0 || h1Close < emaSlow1) return false;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid < emaFast1) return false;
   double rsi1 = Ind(g_hRSI, 0, 1);
   double rsi2 = Ind(g_hRSI, 0, 2);
   double rsi3 = Ind(g_hRSI, 0, 3);
   if(rsi1 >= InpRSI_Avoid) return false;
   bool hadDip = (rsi2 <= InpRSI_Entry || rsi3 <= InpRSI_Entry);
   bool isRecovering = (rsi1 > rsi2);
   if(!hadDip || !isRecovering) return false;
   double c1 = iClose(_Symbol, PERIOD_M5, 1);
   double o1 = iOpen(_Symbol, PERIOD_M5, 1);
   double h2 = iHigh(_Symbol, PERIOD_M5, 2);
   if(!(c1 > o1 && c1 > h2)) return false;
   double atr = Ind(g_hM5ATR, 0, 1);
   if(atr <= 0) return false;
   if(MathAbs(c1 - o1) < atr * 0.15) return false;
   return true;
}

//=====================================================================
// CORE POSITION MANAGEMENT
//=====================================================================
bool HasCorePosition() {
   if(g_coreTicket == 0) return false;
   if(!PositionSelectByTicket(g_coreTicket)) {
      g_coreTicket = 0;
      return false;
   }
   if(PositionGetInteger(POSITION_MAGIC) != InpMagic ||
      PositionGetString(POSITION_SYMBOL) != _Symbol) {
      g_coreTicket = 0;
      return false;
   }
   return true;
}

void ScanForCoreTicket() {
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      string cmt = PositionGetString(POSITION_COMMENT);
      if(StringFind(cmt, "Core") == 0) {
         g_coreTicket = tk;
         return;
      }
   }
}

bool OpenCorePosition() {
   double lots = CalcCompoundLot(InpBaseLot);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double ema21 = Ind(g_hH1EMAFast, 0, 1);
   double h1atr = Ind(g_hH1ATR, 0, 1);
   double sl = 0;
   if(ema21 > 0 && h1atr > 0) {
      sl = ema21 - h1atr * InpTrailATRMult;
      if(sl >= ask) sl = 0;
   }
   g_trade.SetExpertMagicNumber(InpMagic);
   bool ok = g_trade.Buy(lots, _Symbol, ask, sl, 0, "Core");
   if(ok) {
      ScanForCoreTicket();
      PrintFormat("[GG] CORE BUY %.2f @ %.2f SL=%.2f", lots, ask, sl);
   } else {
      PrintFormat("[GG] CORE BUY FAIL: %s", g_trade.ResultRetcodeDescription());
   }
   return ok;
}

void UpdateCoreTrailingStop() {
   if(!HasCorePosition()) return;
   double ema21 = Ind(g_hH1EMAFast, 0, 1);
   double h1atr = Ind(g_hH1ATR, 0, 1);
   if(ema21 <= 0 || h1atr <= 0) return;
   double newSL = ema21 - h1atr * InpTrailATRMult;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid - newSL < 1.0) return;
   PositionSelectByTicket(g_coreTicket);
   double currentSL = PositionGetDouble(POSITION_SL);
   if(newSL > currentSL) {
      g_trade.PositionModify(g_coreTicket, newSL, 0);
   }
}

void CloseCorePosition(string reason) {
   if(!HasCorePosition()) return;
   g_trade.SetExpertMagicNumber(InpMagic);
   if(g_trade.PositionClose(g_coreTicket, SLIPPAGE)) {
      PrintFormat("[GG] CORE CLOSE: %s", reason);
      g_coreTicket = 0;
      g_lastCoreClose = TimeCurrent();
   }
}

//=====================================================================
// GRID POSITION QUERIES (excluding core)
//=====================================================================
int CountGridPositions() {
   int c = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(tk == g_coreTicket) continue;
      c++;
   }
   return c;
}

double GetLowestGridEntry() {
   double lowest = DBL_MAX;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(tk == g_coreTicket) continue;
      double op = PositionGetDouble(POSITION_PRICE_OPEN);
      if(op < lowest) lowest = op;
   }
   return lowest;
}

void CalcGridStats(double &avgPrice, double &totalLots, double &totalPnL) {
   avgPrice = 0; totalLots = 0; totalPnL = 0;
   double weightedSum = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(tk == g_coreTicket) continue;
      double op  = PositionGetDouble(POSITION_PRICE_OPEN);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double pft = PositionGetDouble(POSITION_PROFIT)
                 + PositionGetDouble(POSITION_SWAP);
      weightedSum += op * vol;
      totalLots   += vol;
      totalPnL    += pft;
   }
   if(totalLots > 0) avgPrice = weightedSum / totalLots;
}

double CalcTierLot(int orderIndex) {
   int tier = orderIndex / InpOrdersPerTier;
   double baseLot = CalcCompoundLot(InpBaseLot);
   return NL(baseLot * MathPow(InpLotMultiplier, tier));
}

int GetMaxOrders() {
   return InpOrdersPerTier * InpMaxTiers;
}

//=====================================================================
// GRID TRADE ACTIONS
//=====================================================================
bool OpenGridBuy(double lots, string comment) {
   g_trade.SetExpertMagicNumber(InpMagic);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(lots <= 0) return false;
   bool ok = g_trade.Buy(lots, _Symbol, ask, 0, 0, comment);
   if(ok) {
      PrintFormat("[GG] GRID BUY %.2f @ %.2f [%s]", lots, ask, comment);
   } else {
      PrintFormat("[GG] GRID BUY FAIL: %s", g_trade.ResultRetcodeDescription());
   }
   return ok;
}

void CloseAllGrid(string reason, bool isLoss) {
   int closed = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(tk == g_coreTicket) continue;
      g_trade.SetExpertMagicNumber(InpMagic);
      if(g_trade.PositionClose(tk, SLIPPAGE)) closed++;
   }
   if(closed > 0) {
      g_lastGridClose = TimeCurrent();
      g_lastGridWasLoss = isLoss;
      PrintFormat("[GG] CloseGrid: %s (%d pos, loss=%s)", reason, closed, isLoss ? "Y" : "N");
   }
}

void CloseEverything(string reason) {
   if(HasCorePosition()) {
      g_trade.SetExpertMagicNumber(InpMagic);
      g_trade.PositionClose(g_coreTicket, SLIPPAGE);
      g_coreTicket = 0;
      g_lastCoreClose = TimeCurrent();
   }
   int closed = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      g_trade.SetExpertMagicNumber(InpMagic);
      if(g_trade.PositionClose(tk, SLIPPAGE)) closed++;
   }
   g_lastGridClose = TimeCurrent();
   g_lastGridWasLoss = true;
   PrintFormat("[GG] CloseAll: %s (%d pos)", reason, closed);
}

//=====================================================================
// SAFETY
//=====================================================================
bool CheckMaxDrawdown() {
   if(InpMaxDrawdownPct <= 0 || g_initialEquity <= 0) return false;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = (g_initialEquity - eq) / g_initialEquity * 100.0;
   if(dd >= InpMaxDrawdownPct) {
      PrintFormat("[GG] DD PAUSE: %.1f%% pausing %dh", dd, InpDDPauseHours);
      CloseEverything("MaxDD_Pause");
      g_ddPauseUntil = TimeCurrent() + InpDDPauseHours * 3600;
      g_initialEquity = eq;
      return true;
   }
   return false;
}

bool IsDDPaused() {
   if(g_ddPauseUntil == 0) return false;
   if(TimeCurrent() >= g_ddPauseUntil) {
      PrintFormat("[GG] DD Pause ended. Resuming.");
      g_ddPauseUntil = 0;
      return false;
   }
   return true;
}

bool CheckMaxLots(double gridLots, double newLots) {
   if(InpMaxTotalLots <= 0) return false;
   double coreLot = 0;
   if(HasCorePosition()) {
      PositionSelectByTicket(g_coreTicket);
      coreLot = PositionGetDouble(POSITION_VOLUME);
   }
   return (gridLots + coreLot + newLots > InpMaxTotalLots);
}

//=====================================================================
// MAIN EA LIFECYCLE
//=====================================================================
int OnInit() {
   g_trade.SetDeviationInPoints(SLIPPAGE);
   g_trade.SetTypeFilling(DetectFilling());
   g_initialEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_lastGridClose = 0;
   g_lastCoreClose = 0;
   g_lastGridWasLoss = false;
   g_gridsToday = 0;
   g_lastResetDay = -1;
   g_ddPauseUntil = 0;
   g_coreTicket = 0;
   g_hH1EMAFast = iMA(_Symbol, PERIOD_H1, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   g_hH1EMASlow = iMA(_Symbol, PERIOD_H1, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   g_hRSI       = iRSI(_Symbol, PERIOD_M5, 14, PRICE_CLOSE);
   g_hM5ATR     = iATR(_Symbol, PERIOD_M5, 14);
   g_hH1ATR     = iATR(_Symbol, PERIOD_H1, 14);
   int all[] = {g_hH1EMAFast, g_hH1EMASlow, g_hRSI, g_hM5ATR, g_hH1ATR};
   for(int i = 0; i < ArraySize(all); i++) {
      if(all[i] == INVALID_HANDLE) {
         PrintFormat("[GG] Indicator %d init failed", i);
         return INIT_FAILED;
      }
   }
   ScanForCoreTicket();
   PrintFormat("[GG] v3.0 Core+Grid+Compound. Lot=%.2f Equity/Lot=%.0f Core=%s Trail=%.1fATR Grid=$%.1f %dx%d",
              InpBaseLot, InpEquityPerLot, InpEnableCore ? "ON" : "OFF",
              InpTrailATRMult, InpGridSpacing, InpMaxTiers, InpOrdersPerTier);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   int all[] = {g_hH1EMAFast, g_hH1EMASlow, g_hRSI, g_hM5ATR, g_hH1ATR};
   for(int i = 0; i < ArraySize(all); i++)
      if(all[i] != INVALID_HANDLE) IndicatorRelease(all[i]);
   Print("[GG] Stopped.");
}

void OnTick() {
   if(IsDDPaused()) return;
   if(CheckMaxDrawdown()) return;
   CheckDailyReset();
   bool newH1 = false;
   {
      datetime t = iTime(_Symbol, PERIOD_H1, 0);
      if(t != 0 && t != g_lastH1BarTime) { g_lastH1BarTime = t; newH1 = true; }
   }
   bool newM5 = false;
   {
      datetime t = iTime(_Symbol, PERIOD_M5, 0);
      if(t != 0 && t != g_lastBarTime) { g_lastBarTime = t; newM5 = true; }
   }
   bool hasCore = HasCorePosition();
   int gridCount = CountGridPositions();
   //--- CORE: trailing stop + trend exit (on H1 bar) ---
   if(hasCore && newH1) {
      UpdateCoreTrailingStop();
      if(!IsTrendUp()) {
         CloseCorePosition("TrendEnd");
         hasCore = false;
      }
   }
   if(g_coreTicket != 0 && !HasCorePosition()) {
      PrintFormat("[GG] Core stopped out by trailing SL");
      g_coreTicket = 0;
      g_lastCoreClose = TimeCurrent();
      hasCore = false;
   }
   //--- GRID: TP check (every tick for speed) ---
   if(gridCount > 0) {
      double avgPrice = 0, totalLots = 0, totalPnL = 0;
      CalcGridStats(avgPrice, totalLots, totalPnL);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(bid >= avgPrice + InpTPFromAvg && totalPnL >= InpTPMinProfit) {
         PrintFormat("[GG] GRID TP: avg=%.2f bid=%.2f pnl=%.2f lots=%.2f cnt=%d",
                    avgPrice, bid, totalPnL, totalLots, gridCount);
         CloseAllGrid("TP", false);
         g_gridsToday++;
         gridCount = 0;
      }
   }
   if(gridCount > 0 && InpCloseBeforeWeekend && IsWeekendClose()) {
      double ap = 0, tl = 0, tp = 0;
      CalcGridStats(ap, tl, tp);
      if(tp > 0) {
         CloseAllGrid("Weekend+Profit", false);
         gridCount = 0;
      }
   }
   if(gridCount > 0 && gridCount >= GetMaxOrders() && !IsTrendUp()) {
      double ap = 0, tl = 0, tp = 0;
      CalcGridStats(ap, tl, tp);
      PrintFormat("[GG] Grid trend break: pnl=%.2f", tp);
      CloseAllGrid("TrendBreak", true);
      g_gridsToday = InpMaxGridsPerDay;
      gridCount = 0;
   }
   if(!newM5) return;
   //--- GRID: expansion on dip ---
   if(gridCount > 0 && gridCount < GetMaxOrders() && IsSessionActive() && IsSpreadOK()) {
      double lowestEntry = GetLowestGridEntry();
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(lowestEntry - ask >= InpGridSpacing) {
         double avgP = 0, totL = 0, totPnL = 0;
         CalcGridStats(avgP, totL, totPnL);
         double nextLots = CalcTierLot(gridCount);
         if(!CheckMaxLots(totL, nextLots)) {
            int tier = gridCount / InpOrdersPerTier + 1;
            int inTier = gridCount % InpOrdersPerTier + 1;
            OpenGridBuy(nextLots, StringFormat("Grid_T%d_%d", tier, inTier));
         }
      }
   }
   if(!IsSessionActive() || !IsSpreadOK()) return;
   //--- CORE: open if trend up and no core ---
   if(!hasCore && InpEnableCore && IsTrendUp()) {
      if(TimeCurrent() - g_lastCoreClose >= InpCooldownCoreReopen) {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double emaFast = Ind(g_hH1EMAFast, 0, 1);
         if(bid > emaFast && emaFast > 0) {
            OpenCorePosition();
         }
      }
   }
   //--- GRID: new grid entry ---
   if(gridCount == 0 && g_gridsToday < InpMaxGridsPerDay) {
      int cooldown = g_lastGridWasLoss ? InpCooldownAfterLoss : InpCooldownAfterTP;
      if(TimeCurrent() - g_lastGridClose >= cooldown) {
         if(CheckGridEntrySignal()) {
            double emaF = Ind(g_hH1EMAFast, 0, 1);
            double emaS = Ind(g_hH1EMASlow, 0, 1);
            double rsi  = Ind(g_hRSI, 0, 1);
            PrintFormat("[GG] GRID ENTRY: ema21=%.1f ema50=%.1f rsi=%.1f #%d",
                       emaF, emaS, rsi, g_gridsToday + 1);
            OpenGridBuy(CalcTierLot(0), "Grid_T1_1");
         }
      }
   }
}
//+------------------------------------------------------------------+
