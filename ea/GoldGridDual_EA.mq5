//+------------------------------------------------------------------+
//| GoldGridDual_EA.mq5 v1.05                                        |
//| Dual-direction grid + trailing batch close                       |
//| v1.01: direction filter — price vs N bars ago decides which side |
//| v1.02: trend filter (displacement ratio), daily loss limit,      |
//|         news blackout, EquityBreaker lowered to 10%              |
//| v1.03: displacement ratio + entry throttle moved to M5           |
//| v1.04: dynamic LotStep scaled to account balance                 |
//| v1.05: remove daily loss limit (redundant with EquityBreaker)    |
//+------------------------------------------------------------------+
#property copyright "GoldGridDual"
#property version   "1.05"

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
input double   InpEqBreakerPct    = 10.0;

input group "=== Trend Filter ==="
input bool     InpTrendFilterOn   = true;
input int      InpDispBars        = 20;    // M5 bars for displacement ratio (20 bars = 100 min)
input double   InpDispThreshold   = 0.60; // Ratio above this = trending, block counter-trend entries
input int      InpDispConfirmBars = 20;   // Consecutive M5 bars above threshold to confirm trend

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
int      g_dispConfirmCount = 0;  // consecutive bars with high displacement ratio
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
// Displacement ratio: |net displacement| / total path over N M5 bars
// Close to 1 = trending; close to 0 = ranging
double CalcDisplacementRatio(int bars)
{
   if(bars < 2) return 0.0;
   double closes[];
   if(CopyClose(_Symbol, PERIOD_M5, 1, bars, closes) != bars) return 0.0;

   double totalPath = 0.0;
   for(int i = 1; i < bars; i++)
      totalPath += MathAbs(closes[i] - closes[i-1]);
   if(totalPath <= 0.0) return 0.0;

   double netDisp = MathAbs(closes[bars-1] - closes[0]);
   return netDisp / totalPath;
}

//=====================================================================
// Update trend filter on each new M5 bar.
// Sets g_trendBuy / g_trendSell based on displacement ratio + direction.
void UpdateTrendFilter()
{
   if(!InpTrendFilterOn) return;

   datetime curM5 = iTime(_Symbol, PERIOD_M5, 0);
   if(curM5 == 0 || curM5 == g_lastBarTimeM5) return;
   g_lastBarTimeM5 = curM5;

   double ratio = CalcDisplacementRatio(InpDispBars);

   if(ratio >= InpDispThreshold)
   {
      g_dispConfirmCount++;
   }
   else
   {
      g_dispConfirmCount = 0;
      g_trendBuy  = false;
      g_trendSell = false;
      return;
   }

   if(g_dispConfirmCount < InpDispConfirmBars) return;

   // Confirmed trend — determine direction from net displacement
   double closes[];
   if(CopyClose(_Symbol, PERIOD_M5, 1, InpDispBars, closes) != InpDispBars) return;
   double netDisp = closes[InpDispBars-1] - closes[0];

   if(netDisp < 0)
   {
      g_trendBuy  = true;
      g_trendSell = false;
      PrintFormat("[GD] TREND DOWN detected (ratio=%.2f, %d M5 bars) — BUY entries blocked", ratio, g_dispConfirmCount);
   }
   else
   {
      g_trendSell = true;
      g_trendBuy  = false;
      PrintFormat("[GD] TREND UP detected (ratio=%.2f, %d M5 bars) — SELL entries blocked", ratio, g_dispConfirmCount);
   }
}

//=====================================================================
// News blackout: block entries during high-impact news windows (GMT).
// Times are approximate; adjust InpServerGMT if server is not GMT0.
bool IsNewsBlackout()
{
   if(!InpNewsOn) return false;

   MqlDateTime dt;
   datetime gmt = TimeCurrent() + InpServerGMT * 3600;
   TimeToStruct(gmt, dt);

   int h = dt.hour;
   int m = dt.min;
   int hm = h * 100 + m;

   // US NFP: first Friday of month 12:25-13:05 GMT
   // US CPI: varies, typically Tue/Wed 12:25-13:05 GMT
   // FOMC:   Wed 18:55-19:05 GMT (statement), 19:25-20:05 (presser)
   // Covers: 12:25-13:05, 18:55-20:05 GMT on weekdays
   if(hm >= 1225 && hm <= 1305) return true;
   if(hm >= 1855 && hm <= 2005) return true;

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

   PrintFormat("[GD] GoldGridDual v1.04 | LotStep=%.2f BaseBalance=%.0f MaxBuy=%d MaxSell=%d TPActivate=%.0f TPTrailback=%.0f ATR=%s",
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
