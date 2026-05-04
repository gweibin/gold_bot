//+------------------------------------------------------------------+
//| GoldGridDual_EA.mq5 v1.07                                        |
//| Dual-direction grid + trailing batch close                       |
//| v1.01: direction filter — price vs N bars ago decides which side |
//| v1.02: trend filter (displacement ratio), daily loss limit,      |
//|         news blackout, EquityBreaker lowered to 10%              |
//| v1.03: displacement ratio + entry throttle moved to M5           |
//| v1.04: dynamic LotStep scaled to account balance                 |
//| v1.05: remove daily loss limit (redundant with EquityBreaker)    |
//| v1.06: news blackout uses hardcoded 2026 NFP/CPI/FOMC dates      |
//| v1.07: trend filter replaced with net displacement in points     |
//+------------------------------------------------------------------+
#property copyright "GoldGridDual"
#property version   "1.07"

#include <Trade/Trade.mqh>

#define SLIPPAGE 30

//=====================================================================
// INPUT PARAMETERS
//=====================================================================
input group "=== Trade ==="
input int      InpMagic           = 600030;
input double   InpLotStep         = 0.02;      // Lot increment per layer (at base balance)
input double   InpBaseBalance     = 20000.0;   // Reference balance for LotStep scaling
input int      InpMaxPosBuy       = 30;        // Max Buy positions
input int      InpMaxPosSell      = 30;        // Max Sell positions
input double   InpMaxSpread       = 0.50;

input group "=== Direction Filter ==="
input int      InpDirBars         = 5;         // Compare current price vs N bars ago

input group "=== Grid Spacing ==="
input bool     InpUseATR          = true;
input int      InpATR_Period      = 14;        // ATR period (M15)
input double   InpSpacingCoef     = 0.18;      // ATR multiplier for spacing
input double   InpSpacingMin      = 2.0;
input double   InpSpacingMax      = 8.0;
input double   InpFallbackSpacing = 5.0;

input group "=== Trailing Batch Close ==="
input double   InpTPActivate      = 80.0;     // Min profit to arm trailing ($)
input double   InpTPTrailback     = 30.0;     // Pullback from peak to trigger close ($)

input group "=== Session ==="
input int      InpStartHour       = 5;
input int      InpEndHour         = 20;

input group "=== Friday Cutoff ==="
input int      InpServerGMT       = 0;
input int      InpFriCutoffBJ     = 24;

input group "=== Friday Force Close ==="
input bool     InpFriForceOn      = true;
input int      InpFriCloseBJHour  = 5;      // BJ hour (Sat) to force close; GMT0 Fri 21:00
input int      InpFriEarlyBJHour  = 4;      // BJ hour (Sat) for early close if loss exceeds threshold
input double   InpFriEarlyLossPct = 15.0;   // Floating loss % of equity triggering early close

input group "=== Equity Circuit Breaker ==="
input bool     InpEqBreakerOn     = true;
input double   InpEqBreakerPct    = 20.0;

input group "=== Trend Filter ==="
input bool     InpTrendFilterOn   = true;
input int      InpDispBars        = 60;    // M5 bars to measure net displacement (60 bars = 5h)
input double   InpDispDollar      = 100.0;  // Net price move ($) to confirm trend and block counter entries

input group "=== News Blackout ==="
input bool     InpNewsOn          = true;  // Enable news time blackout


//=====================================================================
// GLOBALS
//=====================================================================
CTrade   g_trade;
datetime g_lastBarTime  = 0;   // M5 bar throttle
datetime g_lastBarTimeM5 = 0;  // M5 bar for trend filter
int      g_hATR         = INVALID_HANDLE;

// Trailing close state per direction
double   g_peakPnlBuy   = 0.0;
double   g_peakPnlSell  = 0.0;

// Halt flags
bool     g_eqHaltToday  = false;
int      g_eqHaltDoy    = -1;
bool     g_friHalt      = false;

double   g_initBalance     = 0.0;  // Fixed at OnInit, used for LotStep scaling

// Trend filter state
bool     g_trendBuy         = false; // buy direction is trending (block buy entries)
bool     g_trendSell        = false; // sell direction is trending (block sell entries)

//=====================================================================
double Ind(int handle, int shift)
{
   double v[];
   if(CopyBuffer(handle, 0, shift, 1, v) != 1) return 0.0;
   return v[0];
}

//=====================================================================
double NormLot(double lots)
{
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(st <= 0) st = 0.01;
   lots = MathMax(mn, MathMin(mx, lots));
   return NormalizeDouble(MathFloor(lots / st) * st, 2);
}

//=====================================================================
ENUM_ORDER_TYPE_FILLING DetectFilling()
{
   long fm = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if(fm & SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if(fm & SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//=====================================================================
bool IsSpreadOK()
{
   return (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
           SymbolInfoDouble(_Symbol, SYMBOL_BID) <= InpMaxSpread);
}

//=====================================================================
void ServerToBJ(int &bjHour, int &bjDow)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   bjHour = dt.hour + (8 - InpServerGMT);
   bjDow  = dt.day_of_week;
   if(bjHour >= 24) { bjHour -= 24; bjDow = (bjDow + 1) % 7; }
   if(bjHour < 0)   { bjHour += 24; bjDow = (bjDow + 6) % 7; }
}

//=====================================================================
bool IsSessionActive()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;
   if(dt.day_of_week == 1 && dt.hour < 1) return false;

   int bjHour, bjDow;
   ServerToBJ(bjHour, bjDow);
   if(bjDow == 6) return false;
   if(bjDow == 5 && bjHour >= InpFriCutoffBJ) return false;

   return (dt.hour >= InpStartHour && dt.hour < InpEndHour);
}

//=====================================================================
// Count positions by direction
int CountPositions(ENUM_POSITION_TYPE type)
{
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC)  != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)  continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;
      c++;
   }
   return c;
}

//=====================================================================
// Nearest entry distance for a given direction
double NearestEntryDistance(ENUM_POSITION_TYPE type)
{
   double price = (type == POSITION_TYPE_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                  : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minD = DBL_MAX;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;
      double d = MathAbs(price - PositionGetDouble(POSITION_PRICE_OPEN));
      if(d < minD) minD = d;
   }
   return minD;
}

//=====================================================================
// Floating PnL for one direction
double DirFloatingPnL(ENUM_POSITION_TYPE type)
{
   double pnl = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;
      pnl += PositionGetDouble(POSITION_PROFIT)
           + PositionGetDouble(POSITION_SWAP);
   }
   return pnl;
}

//=====================================================================
// Total floating PnL (both directions)
double TotalFloatingPnL()
{
   return DirFloatingPnL(POSITION_TYPE_BUY) + DirFloatingPnL(POSITION_TYPE_SELL);
}

//=====================================================================
void CloseByDirection(ENUM_POSITION_TYPE type, const string reason)
{
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;
      if(g_trade.PositionClose(tk)) closed++;
      else PrintFormat("[GD] CLOSE FAIL ticket=%I64u: %s",
                       tk, g_trade.ResultRetcodeDescription());
   }
   string dir = (type == POSITION_TYPE_BUY) ? "BUY" : "SELL";
   PrintFormat("[GD] FLATTEN %s (%s): closed=%d", dir, reason, closed);
}

//=====================================================================
void CloseAllPositions(const string reason)
{
   CloseByDirection(POSITION_TYPE_BUY,  reason);
   CloseByDirection(POSITION_TYPE_SELL, reason);
}

//=====================================================================
double CurrentSpacing()
{
   if(!InpUseATR || g_hATR == INVALID_HANDLE) return InpFallbackSpacing;
   double atr = Ind(g_hATR, 1);
   if(atr <= 0.0) return InpFallbackSpacing;
   double s = atr * InpSpacingCoef;
   return MathMax(InpSpacingMin, MathMin(InpSpacingMax, s));
}

//=====================================================================
// Dynamic lot step scaled to current balance vs base balance
double DynamicLotStep()
{
   if(InpBaseBalance <= 0) return InpLotStep;
   if(g_initBalance <= 0) return InpLotStep;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;
   double raw = InpLotStep * (g_initBalance / InpBaseBalance);
   return NormalizeDouble(MathFloor(raw / step) * step, 2);
}

//=====================================================================
// Next lot size = (layer_count + 1) * DynamicLotStep
double NextLot(ENUM_POSITION_TYPE type)
{
   int layers = CountPositions(type);
   return NormLot((layers + 1) * DynamicLotStep());
}

//=====================================================================
// Update trend filter on each new M5 bar.
// Blocks counter-trend entries when net displacement over InpDispBars exceeds InpDispPoints.
void UpdateTrendFilter()
{
   if(!InpTrendFilterOn) return;

   datetime curM5 = iTime(_Symbol, PERIOD_M5, 0);
   if(curM5 == 0 || curM5 == g_lastBarTimeM5) return;
   g_lastBarTimeM5 = curM5;

   double closes[];
   if(CopyClose(_Symbol, PERIOD_M5, 1, InpDispBars, closes) != InpDispBars)
   {
      g_trendBuy  = false;
      g_trendSell = false;
      return;
   }

   double netDisp = closes[InpDispBars-1] - closes[0];

   if(netDisp <= -InpDispDollar)
   {
      if(!g_trendBuy)
         PrintFormat("[GD] TREND DOWN: net=%.2f$ over %d M5 bars — BUY entries blocked", netDisp, InpDispBars);
      g_trendBuy  = true;
      g_trendSell = false;
   }
   else if(netDisp >= InpDispDollar)
   {
      if(!g_trendSell)
         PrintFormat("[GD] TREND UP: net=%.2f$ over %d M5 bars — SELL entries blocked", netDisp, InpDispBars);
      g_trendSell = true;
      g_trendBuy  = false;
   }
   else
   {
      g_trendBuy  = false;
      g_trendSell = false;
   }
}

//=====================================================================
// News blackout: hardcoded 2026 NFP/CPI/FOMC dates (Exness server time GMT+3).
// NFP/CPI: 15:25-16:05 server; FOMC decision day: 21:55-23:05 server.
bool IsNewsBlackout()
{
   if(!InpNewsOn) return false;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(dt.year != 2026) return false;

   int mon = dt.mon;
   int day = dt.day;
   int hm  = dt.hour * 100 + dt.min;

   // 2026 NFP dates (first Friday of each month)
   static int nfp[][2] = {{1,9},{2,6},{3,6},{4,3},{5,8},{6,5},{7,2},{8,7},{9,4},{10,2},{11,6},{12,4}};
   // 2026 CPI dates
   static int cpi[][2] = {{1,13},{2,13},{3,11},{4,10},{5,12},{6,10},{7,14},{8,12},{9,11},{10,14},{11,10},{12,10}};
   // 2026 FOMC decision days (second day of each meeting)
   static int fomc[][2] = {{1,28},{3,18},{4,29},{6,17},{7,29},{9,16},{10,28},{12,9}};

   // NFP and CPI: block 15:25-16:05 server time (GMT 12:25-13:05)
   if(hm >= 1525 && hm <= 1605)
   {
      for(int i = 0; i < ArrayRange(nfp, 0); i++)
         if(nfp[i][0] == mon && nfp[i][1] == day) return true;
      for(int i = 0; i < ArrayRange(cpi, 0); i++)
         if(cpi[i][0] == mon && cpi[i][1] == day) return true;
   }

   // FOMC: block 21:55-23:05 server time (GMT 18:55-20:05)
   if(hm >= 2155 && hm <= 2305)
   {
      for(int i = 0; i < ArrayRange(fomc, 0); i++)
         if(fomc[i][0] == mon && fomc[i][1] == day) return true;
   }

   return false;
}

//=====================================================================
bool CheckEquityBreaker()
{
   if(!InpEqBreakerOn) return false;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(g_eqHaltToday && g_eqHaltDoy != dt.day_of_year)
   {
      g_eqHaltToday = false;
      g_eqHaltDoy   = -1;
      Print("[GD] Equity halt reset (new day).");
   }
   if(g_eqHaltToday) return true;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0) return false;
   double pnl = TotalFloatingPnL();
   if(pnl >= 0) return false;

   double lossPct = (-pnl) / equity * 100.0;
   if(lossPct >= InpEqBreakerPct)
   {
      PrintFormat("[GD] EQUITY BREAKER: loss=%.2f (%.2f%%) >= %.1f%%",
                  pnl, lossPct, InpEqBreakerPct);
      CloseAllPositions("EquityBreaker");
      g_eqHaltToday = true;
      g_eqHaltDoy   = dt.day_of_year;
      return true;
   }
   return false;
}

//=====================================================================
bool CheckFridayForceClose()
{
   if(!InpFriForceOn) return false;

   int bjHour, bjDow;
   ServerToBJ(bjHour, bjDow);

   if(g_friHalt && bjDow != 5 && bjDow != 6)
   {
      g_friHalt = false;
      Print("[GD] Friday halt reset.");
   }
   if(g_friHalt) return true;

   // Trigger on BJ Saturday early hours (covers GMT Fri night session)
   bool isFriSat = (bjDow == 5 || (bjDow == 6 && bjHour <= 6));
   if(!isFriSat) return false;

   if(bjHour >= InpFriCloseBJHour)
   {
      PrintFormat("[GD] FRIDAY FORCE CLOSE (BJ Fri %02d:00)", bjHour);
      CloseAllPositions("FridayForceClose");
      g_friHalt = true;
      return true;
   }

   if(bjHour >= InpFriEarlyBJHour)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double pnl    = TotalFloatingPnL();
      if(equity > 0 && pnl < 0)
      {
         double lossPct = (-pnl) / equity * 100.0;
         if(lossPct >= InpFriEarlyLossPct)
         {
            PrintFormat("[GD] FRIDAY EARLY CLOSE: loss=%.2f (%.2f%%)", pnl, lossPct);
            CloseAllPositions("FridayEarlyClose");
            g_friHalt = true;
            return true;
         }
      }
   }
   return false;
}

//=====================================================================
// Trailing batch close logic for one direction.
// Arms when pnl >= InpTPActivate, fires when pnl drops InpTPTrailback from peak.
void CheckTrailingClose(ENUM_POSITION_TYPE type)
{
   if(CountPositions(type) == 0)
   {
      // Reset peak when no positions
      if(type == POSITION_TYPE_BUY)  g_peakPnlBuy  = 0.0;
      else                           g_peakPnlSell = 0.0;
      return;
   }

   double pnl = DirFloatingPnL(type);
   double peak;
   if(type == POSITION_TYPE_BUY) peak = g_peakPnlBuy;
   else                          peak = g_peakPnlSell;

   // Update peak
   if(pnl > peak)
   {
      peak = pnl;
      if(type == POSITION_TYPE_BUY) g_peakPnlBuy  = peak;
      else                          g_peakPnlSell = peak;
   }

   // Not yet armed
   double scale = (InpBaseBalance > 0 && g_initBalance > 0) ? (g_initBalance / InpBaseBalance) : 1.0;
   if(peak < InpTPActivate * scale) return;

   // Fire if pulled back enough from peak
   if(peak - pnl >= InpTPTrailback * scale)
   {
      string dir = (type == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      PrintFormat("[GD] TRAILING CLOSE %s: peak=%.2f cur=%.2f pullback=%.2f",
                  dir, peak, pnl, peak - pnl);
      CloseByDirection(type, "TrailingTP");
      if(type == POSITION_TYPE_BUY) g_peakPnlBuy  = 0.0;
      else                          g_peakPnlSell = 0.0;
   }
}

//=====================================================================
int OnInit()
{
   g_trade.SetDeviationInPoints(SLIPPAGE);
   g_trade.SetTypeFilling(DetectFilling());
   g_trade.SetExpertMagicNumber(InpMagic);

   g_hATR = iATR(_Symbol, PERIOD_M15, InpATR_Period);
   if(g_hATR == INVALID_HANDLE)
      Print("[GD] ATR init failed (will use fallback spacing)");

   PrintFormat("[GD] GoldGridDual v1.07 | LotStep=%.2f BaseBalance=%.0f MaxBuy=%d MaxSell=%d TPActivate=%.0f TPTrailback=%.0f ATR=%s",
               InpLotStep, InpBaseBalance, InpMaxPosBuy, InpMaxPosSell,
               InpTPActivate, InpTPTrailback,
               InpUseATR ? "ON" : "OFF");

   // Init balance tracking
   g_initBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   return INIT_SUCCEEDED;
}

//=====================================================================
void OnDeinit(const int reason)
{
   if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
   Print("[GD] Stopped.");
}

//=====================================================================
void OnTick()
{
   // Safety checks every tick
   if(CheckEquityBreaker())    return;
   if(CheckFridayForceClose()) return;

   // Trailing close checks every tick
   CheckTrailingClose(POSITION_TYPE_BUY);
   CheckTrailingClose(POSITION_TYPE_SELL);

   if(!IsSessionActive()) return;

   // Throttle new entries to new M5 bar
   datetime curBar = iTime(_Symbol, PERIOD_M5, 0);
   if(curBar == 0 || curBar == g_lastBarTime) return;
   g_lastBarTime = curBar;

   // Update trend filter on each new M5 bar (internal throttle inside)
   UpdateTrendFilter();

   // Block new entries during news blackout
   if(IsNewsBlackout())      return;

   if(!IsSpreadOK()) return;

   double spacing = CurrentSpacing();
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double priceNBarsAgo = iClose(_Symbol, PERIOD_M1, InpDirBars);

   // --- Buy grid: price falling → fade with Buy ---
   if(bid < priceNBarsAgo && !g_trendBuy)
   {
      int buyCount = CountPositions(POSITION_TYPE_BUY);
      if(buyCount < InpMaxPosBuy)
      {
         bool canBuy = (buyCount == 0) ||
                       (NearestEntryDistance(POSITION_TYPE_BUY) >= spacing);
         if(canBuy)
         {
            double lots = NextLot(POSITION_TYPE_BUY);
            if(g_trade.Buy(lots, _Symbol, ask, 0, 0,
                           StringFormat("GridBuy_%d", buyCount + 1)))
               PrintFormat("[GD] BUY %.2f @ %.3f sp=%.2f [%d/%d]",
                           lots, ask, spacing, buyCount + 1, InpMaxPosBuy);
            else
               PrintFormat("[GD] BUY FAIL: %s", g_trade.ResultRetcodeDescription());
         }
      }
   }

   // --- Sell grid: price rising → fade with Sell ---
   if(bid > priceNBarsAgo && !g_trendSell)
   {
      int sellCount = CountPositions(POSITION_TYPE_SELL);
      if(sellCount < InpMaxPosSell)
      {
         bool canSell = (sellCount == 0) ||
                        (NearestEntryDistance(POSITION_TYPE_SELL) >= spacing);
         if(canSell)
         {
            double lots = NextLot(POSITION_TYPE_SELL);
            if(g_trade.Sell(lots, _Symbol, bid, 0, 0,
                            StringFormat("GridSell_%d", sellCount + 1)))
               PrintFormat("[GD] SELL %.2f @ %.3f sp=%.2f [%d/%d]",
                           lots, bid, spacing, sellCount + 1, InpMaxPosSell);
            else
               PrintFormat("[GD] SELL FAIL: %s", g_trade.ResultRetcodeDescription());
         }
      }
   }
}
//+------------------------------------------------------------------+
