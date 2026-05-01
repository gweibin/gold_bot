//+------------------------------------------------------------------+
//| GoldScalp_EA.mq5 v1.32 - Gold Scalper (Buy Only)                |
//| v1.32: equity circuit breaker, Friday force-close,               |
//|        ATR-adaptive spacing & TP                                 |
//+------------------------------------------------------------------+
#property copyright "GoldScalp"
#property version   "1.32"

#include <Trade/Trade.mqh>

#define SLIPPAGE 30

//=====================================================================
// INPUT PARAMETERS
//=====================================================================
input group "=== Trade ==="
input int      InpMagic           = 600000;
input double   InpLotSize         = 0.01;
input int      InpMaxPositions    = 30;
input double   InpMaxSpread       = 0.50;
input double   InpMaxPrice        = 4800.0;   // Price ceiling (0=disabled)

input group "=== Momentum Filter ==="
input int      InpRSI_Period      = 14;
input double   InpRSI_OB          = 75.0;

input group "=== Session ==="
input int      InpStartHour       = 5;
input int      InpEndHour         = 20;

input group "=== Friday Cutoff ==="
input int      InpServerGMT       = 0;      // Server GMT offset (Exness=0)
input int      InpFriCutoffBJ     = 24;     // Friday no-new-entry BJ hour (0-24)

input group "=== Equity Circuit Breaker ==="
input bool     InpEqBreakerOn     = false;
input double   InpEqBreakerPct    = 20.0;   // Floating loss % of equity -> flatten all

input group "=== Friday Force Close ==="
input bool     InpFriForceOn      = true;
input int      InpFriCloseBJHour  = 23;     // BJ hour (Fri) to force close; GMT0 Fri 15:00
input int      InpFriEarlyBJHour  = 22;     // BJ hour (Fri) for early close if loss exceeds threshold
input double   InpFriEarlyLossPct = 5.0;    // Floating loss % of equity triggering early close

input group "=== ATR Adaptive (M15, 14) ==="
input bool     InpUseATR          = false;
input int      InpATR_Period      = 14;
input double   InpSpacingCoef     = 0.18;
input double   InpTPCoef          = 0.65;
input double   InpSpacingMin      = 1.5;
input double   InpSpacingMax      = 6.0;
input double   InpTPMin           = 6.0;
input double   InpTPMax           = 18.0;
input double   InpFallbackSpacing = 1.8;    // Used when ATR unavailable
input double   InpFallbackTP      = 9.2;    // Used when ATR unavailable

//=====================================================================
// GLOBALS
//=====================================================================
CTrade   g_trade;
datetime g_lastBarTime     = 0;
int      g_hRSI            = INVALID_HANDLE;
int      g_hATR            = INVALID_HANDLE;

// Emergency halt flags
bool     g_eqHaltToday     = false;   // equity breaker halt (reset on day change)
int      g_eqHaltDoy       = -1;      // day_of_year when breaker fired
bool     g_friHalt         = false;   // Friday force-close halt (reset when not Friday)

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
// Convert server time to Beijing date/hour
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
int CountPositions()
{
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      c++;
   }
   return c;
}

//=====================================================================
double NearestEntryDistance()
{
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minD = DBL_MAX;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double d = MathAbs(bid - PositionGetDouble(POSITION_PRICE_OPEN));
      if(d < minD) minD = d;
   }
   return minD;
}

//=====================================================================
// Total floating PnL of this EA's positions (profit + swap + commission)
double BotFloatingPnL()
{
   double pnl = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      pnl += PositionGetDouble(POSITION_PROFIT)
           + PositionGetDouble(POSITION_SWAP);
   }
   return pnl;
}

//=====================================================================
void CloseAllBotPositions(const string reason)
{
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(g_trade.PositionClose(tk)) closed++;
      else PrintFormat("[GS] CLOSE FAIL ticket=%I64u: %s",
                       tk, g_trade.ResultRetcodeDescription());
   }
   PrintFormat("[GS] FLATTEN (%s): closed=%d", reason, closed);
}

//=====================================================================
// ATR-based spacing / TP with hard clamps; falls back if ATR unavailable
double CurrentSpacing()
{
   if(!InpUseATR || g_hATR == INVALID_HANDLE) return InpFallbackSpacing;
   double atr = Ind(g_hATR, 1);
   if(atr <= 0.0) return InpFallbackSpacing;
   double s = atr * InpSpacingCoef;
   return MathMax(InpSpacingMin, MathMin(InpSpacingMax, s));
}

double CurrentTP()
{
   if(!InpUseATR || g_hATR == INVALID_HANDLE) return InpFallbackTP;
   double atr = Ind(g_hATR, 1);
   if(atr <= 0.0) return InpFallbackTP;
   double t = atr * InpTPCoef;
   return MathMax(InpTPMin, MathMin(InpTPMax, t));
}

//=====================================================================
// Equity circuit breaker: flatten if floating loss >= pct of equity
// Returns true if halted this tick.
bool CheckEquityBreaker()
{
   if(!InpEqBreakerOn) return false;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   // Reset on day change
   if(g_eqHaltToday && g_eqHaltDoy != dt.day_of_year)
   {
      g_eqHaltToday = false;
      g_eqHaltDoy   = -1;
      Print("[GS] Equity halt reset (new day).");
   }

   if(g_eqHaltToday) return true;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0) return false;
   double pnl = BotFloatingPnL();
   if(pnl >= 0) return false;

   double lossPct = (-pnl) / equity * 100.0;
   if(lossPct >= InpEqBreakerPct)
   {
      PrintFormat("[GS] EQUITY BREAKER: loss=%.2f (%.2f%% of equity %.2f) >= %.1f%%",
                  pnl, lossPct, equity, InpEqBreakerPct);
      CloseAllBotPositions("EquityBreaker");
      g_eqHaltToday = true;
      g_eqHaltDoy   = dt.day_of_year;
      return true;
   }
   return false;
}

//=====================================================================
// Friday force-close: trigger on BJ Sat hour, early on heavy loss.
// Halt stays until we leave Friday.
bool CheckFridayForceClose()
{
   if(!InpFriForceOn) return false;

   int bjHour, bjDow;
   ServerToBJ(bjHour, bjDow);

   // Reset: once we're past Saturday (BJ Sunday or later), Friday window is over.
   if(g_friHalt && bjDow != 5 && bjDow != 6)
   {
      g_friHalt = false;
      Print("[GS] Friday halt reset.");
   }

   if(g_friHalt) return true;

   // Trigger window: BJ Friday (bjDow==5) from InpFriEarlyBJHour onward.
   if(bjDow != 5) return false;

   // Normal mandatory close
   if(bjHour >= InpFriCloseBJHour)
   {
      PrintFormat("[GS] FRIDAY FORCE CLOSE (BJ Fri %02d:00, threshold=%02d)",
                  bjHour, InpFriCloseBJHour);
      CloseAllBotPositions("FridayForceClose");
      g_friHalt = true;
      return true;
   }

   // Early close on heavy loss
   if(bjHour >= InpFriEarlyBJHour)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double pnl    = BotFloatingPnL();
      if(equity > 0 && pnl < 0)
      {
         double lossPct = (-pnl) / equity * 100.0;
         if(lossPct >= InpFriEarlyLossPct)
         {
            PrintFormat("[GS] FRIDAY EARLY CLOSE: loss=%.2f (%.2f%%) >= %.1f%% at BJ Fri %02d:00",
                        pnl, lossPct, InpFriEarlyLossPct, bjHour);
            CloseAllBotPositions("FridayEarlyClose");
            g_friHalt = true;
            return true;
         }
      }
   }
   return false;
}

//=====================================================================
int OnInit()
{
   g_trade.SetDeviationInPoints(SLIPPAGE);
   g_trade.SetTypeFilling(DetectFilling());
   g_trade.SetExpertMagicNumber(InpMagic);

   g_hRSI = iRSI(_Symbol, PERIOD_M1, InpRSI_Period, PRICE_CLOSE);
   if(g_hRSI == INVALID_HANDLE)
   {
      Print("[GS] RSI init failed");
      return INIT_FAILED;
   }

   g_hATR = iATR(_Symbol, PERIOD_M15, InpATR_Period);
   if(g_hATR == INVALID_HANDLE)
   {
      Print("[GS] ATR init failed (will use fallback values)");
   }

   PrintFormat("[GS] GoldScalp v1.32 | Lot=%.2f MaxPos=%d RSI_OB=%.0f MaxPrice=%.1f",
               InpLotSize, InpMaxPositions, InpRSI_OB, InpMaxPrice);
   PrintFormat("[GS] EqBreaker=%s (%.1f%%) FriForce=%s (close BJ Sat %02d:00, early %02d:00@%.1f%%) ATR=%s",
               InpEqBreakerOn ? "ON" : "OFF", InpEqBreakerPct,
               InpFriForceOn  ? "ON" : "OFF",
               InpFriCloseBJHour, InpFriEarlyBJHour, InpFriEarlyLossPct,
               InpUseATR ? "ON" : "OFF");
   return INIT_SUCCEEDED;
}

//=====================================================================
void OnDeinit(const int reason)
{
   if(g_hRSI != INVALID_HANDLE) IndicatorRelease(g_hRSI);
   if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
   Print("[GS] Stopped.");
}

//=====================================================================
void OnTick()
{
   // Safety checks fire every tick (not throttled to new bar)
   if(CheckEquityBreaker())   return;
   if(CheckFridayForceClose())return;

   if(!IsSessionActive()) return;

   datetime curBar = iTime(_Symbol, PERIOD_M1, 0);
   if(curBar == 0 || curBar == g_lastBarTime) return;
   g_lastBarTime = curBar;

   if(!IsSpreadOK()) return;

   int posCount = CountPositions();
   if(posCount >= InpMaxPositions) return;

   double spacing = CurrentSpacing();
   if(posCount > 0 && NearestEntryDistance() < spacing) return;

   double rsi = Ind(g_hRSI, 1);
   if(rsi >= InpRSI_OB) return;

   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(InpMaxPrice > 0 && ask > InpMaxPrice) return;

   double lots  = NormLot(InpLotSize);
   int    dig   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double tpAmt = CurrentTP();
   double tp    = (tpAmt > 0) ? NormalizeDouble(ask + tpAmt, dig) : 0;

   if(g_trade.Buy(lots, _Symbol, ask, 0, tp,
                   StringFormat("Scalp_%d", posCount + 1)))
   {
      PrintFormat("[GS] BUY %.2f @ %.3f TP=%.3f (+%.2f) sp=%.2f [%d/%d] RSI=%.1f",
                  lots, ask, tp, tpAmt, spacing, posCount + 1, InpMaxPositions, rsi);
   }
   else
   {
      PrintFormat("[GS] BUY FAIL: %s", g_trade.ResultRetcodeDescription());
   }
}
//+------------------------------------------------------------------+
