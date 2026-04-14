//+------------------------------------------------------------------+
//| GoldScalp_EA.mq5 v1.3 - Gold Scalper (Buy Only)                 |
//| Grid-style entries every $2.1, TP $2.1 per position              |
//| Cost basis: $0.17 per 0.01 lot (spread + commission)             |
//+------------------------------------------------------------------+
#property copyright "GoldScalp"
#property version   "1.30"

#include <Trade/Trade.mqh>

#define SLIPPAGE 30

//=====================================================================
// INPUT PARAMETERS
//=====================================================================
input group "=== Trade ==="
input int      InpMagic           = 600000;
input double   InpLotSize         = 0.01;
input double   InpTP              = 9.2;
input int      InpMaxPositions    = 50;
input double   InpMaxSpread       = 0.50;

input group "=== Entry Spacing ==="
input double   InpMinSpacing      = 1.8;

input group "=== Momentum Filter ==="
input int      InpRSI_Period      = 14;
input double   InpRSI_OB          = 75.0;

input group "=== Session ==="
input int      InpStartHour       = 5;
input int      InpEndHour         = 20;

//=====================================================================
// GLOBALS
//=====================================================================
CTrade   g_trade;
datetime g_lastBarTime     = 0;
int      g_hRSI            = INVALID_HANDLE;

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
bool IsSessionActive()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;
   if(dt.day_of_week == 1 && dt.hour < 1) return false;
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

   PrintFormat("[GS] GoldScalp v1.3 | Lot=%.2f TP=%.1f MaxPos=%d Spacing=%.1f RSI_OB=%.0f",
               InpLotSize, InpTP, InpMaxPositions, InpMinSpacing, InpRSI_OB);
   return INIT_SUCCEEDED;
}

//=====================================================================
void OnDeinit(const int reason)
{
   if(g_hRSI != INVALID_HANDLE) IndicatorRelease(g_hRSI);
   Print("[GS] Stopped.");
}

//=====================================================================
void OnTick()
{
   if(!IsSessionActive()) return;

   datetime curBar = iTime(_Symbol, PERIOD_M1, 0);
   if(curBar == 0 || curBar == g_lastBarTime) return;
   g_lastBarTime = curBar;

   if(!IsSpreadOK()) return;

   int posCount = CountPositions();
   if(posCount >= InpMaxPositions) return;
   if(posCount > 0 && NearestEntryDistance() < InpMinSpacing) return;

   double rsi = Ind(g_hRSI, 1);
   if(rsi >= InpRSI_OB) return;

   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double lots = NormLot(InpLotSize);
   int    dig  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double tp   = (InpTP > 0) ? NormalizeDouble(ask + InpTP, dig) : 0;

   if(g_trade.Buy(lots, _Symbol, ask, 0, tp,
                   StringFormat("Scalp_%d", posCount + 1)))
   {
      PrintFormat("[GS] BUY %.2f @ %.3f TP=%.3f [%d/%d] RSI=%.1f",
                  lots, ask, tp, posCount + 1, InpMaxPositions, rsi);
   }
   else
   {
      PrintFormat("[GS] BUY FAIL: %s", g_trade.ResultRetcodeDescription());
   }
}
//+------------------------------------------------------------------+
