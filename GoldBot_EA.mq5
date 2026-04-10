//+------------------------------------------------------------------+
//| GoldBot_EA.mq5 - XAUUSD Intraday Bidirectional Multi-Mode EA
//| 4 modes × long/short | M5 entry | M15/H1 trend gate
//| Unified risk engine | Adaptive disable | ATR trailing
//+------------------------------------------------------------------+
#property copyright "GoldBot"
#property version   "3.31"

#include <Trade/Trade.mqh>

//=====================================================================
// SECTION 1: ENUMS, CONSTANTS, STRUCTS
//=====================================================================
enum ENUM_SESSION_TYPE {
   SESSION_ASIA,
   SESSION_EUROPE,
   SESSION_OVERLAP,
   SESSION_US_LATE,
   SESSION_LOW_LIQUIDITY,
   SESSION_CLOSED
};

enum ENUM_TRADE_MODE { MODE_A=0, MODE_B=1, MODE_C=2, MODE_D=3 };

#define MODE_COUNT       4
#define SLIPPAGE_DEFAULT 30
#define DIR_BUY    1
#define DIR_SELL  -1
#define DIR_NONE   0

const string MODE_NAMES[MODE_COUNT] = {"A_EMA","B_BB","C_ST","D_CCI"};

struct SignalResult {
   int    direction;
   double sl;
   double tp;
   string reason;
};

struct ModeState {
   bool     isEnabled;
   bool     isDisabledByAdaptive;
   bool     isInRecovery;
   int      magicNumber;
   int      cooldownBarsLeft;
   int      pauseBarsLeft;
   int      consecutiveLosses;
   int      recoveryCountdown;
   int      recoveryTrialsLeft;
   int      recentWins;
   int      recentTotal;
   double   winRate;
};

struct DailyStats {
   double   startEquity;
   double   peakEquity;
   double   realizedPnL;
   datetime lastResetDay;
   bool     isDailyLocked;
   bool     isDrawdownLocked;
};


//=====================================================================
// SECTION 2: INPUT PARAMETERS
//=====================================================================
input group "=== Global ==="
input int      InpMagicBase            = 100000;
input double   InpRiskPercent          = 0.5;
input double   InpMaxSpreadATR         = 0.35;
input int      InpMaxTotalPositions    = 8;
input double   InpDailyMaxLossPct     = 5.0;
input double   InpTotalDrawdownPct    = 12.0;
input bool     InpCloseBeforeWeekend   = true;
input bool     InpAllowShort          = true;
input bool     InpForceCloseOnRiskLock = true;

input group "=== Trend Gate (M15/H1) ==="
input int      InpM15_EMA_Fast         = 8;
input int      InpM15_EMA_Slow         = 21;
input int      InpH1_EMA_Fast          = 20;
input int      InpH1_EMA_Slow          = 50;
input int      InpH1_ST_Period         = 10;
input double   InpH1_ST_Mult           = 3.0;
input int      InpTrendGateMin         = 2;
input double   InpM5VetoATR            = 0.5;

input group "=== Mode A: EMA Momentum ==="
input bool     InpEnableA              = true;
input int      InpA_EMA_Fast           = 9;
input int      InpA_EMA_Slow           = 21;
input int      InpA_RSI                = 14;
input int      InpA_ADX                = 14;
input double   InpA_ADX_Min            = 22.0;
input double   InpA_SL                 = 1.2;
input double   InpA_TP                 = 2.5;
input int      InpA_Cooldown           = 3;
input int      InpA_MaxPos             = 1;
input double   InpA_MaxChaseATR        = 2.0;

input group "=== Mode B: BB Mean Reversion ==="
input bool     InpEnableB              = true;
input int      InpB_BB_Period          = 20;
input double   InpB_BB_Dev             = 2.0;
input int      InpB_RSI                = 14;
input double   InpB_RSI_OS             = 35.0;
input double   InpB_RSI_OB             = 65.0;
input int      InpB_ADX                = 14;
input double   InpB_ADX_Max            = 30.0;
input double   InpB_SL                 = 1.0;
input int      InpB_Cooldown           = 2;
input int      InpB_MaxPos             = 3;

input group "=== Mode C: Supertrend+MACD ==="
input bool     InpEnableC              = true;
input int      InpC_ST_Period          = 7;
input double   InpC_ST_Mult            = 2.0;
input int      InpC_MACD_Fast          = 8;
input int      InpC_MACD_Slow          = 21;
input int      InpC_MACD_Sig           = 5;
input double   InpC_TP                 = 2.5;
input int      InpC_Cooldown           = 3;
input int      InpC_MaxPos             = 3;

input group "=== Mode D: CCI+Keltner ==="
input bool     InpEnableD              = true;
input int      InpD_CCI                = 14;
input int      InpD_KC_Period          = 20;
input double   InpD_KC_Mult            = 1.5;
input double   InpD_SL                 = 1.0;
input int      InpD_Cooldown           = 2;
input int      InpD_MaxPos             = 3;

input group "=== Adaptive Disable ==="
input int      InpAdaptiveWindow       = 30;
input double   InpMinWinRate           = 35.0;
input int      InpRecoveryBars         = 60;
input double   InpRecoveryScale        = 0.7;
input int      InpRecoveryTrials       = 3;

input group "=== Session (Server Hour UTC+0 Exness) ==="
input int      InpAsiaEnd              = 5;
input int      InpOverlapStart         = 11;
input int      InpOverlapEnd           = 15;
input int      InpUSEnd                = 19;
input int      InpFridayClose          = 22;

input group "=== Position Limits ==="
input int      InpMaxPosPerDir         = 4;
input double   InpMaxLotsPerMode       = 0.10;
input double   InpMaxDirRiskPct        = 3.0;

input group "=== Partial Close ==="
input double   InpPartialATR           = 1.5;
input double   InpPartialPct           = 50.0;

input group "=== Confidence & Guard ==="
input double   InpGateBoostMult        = 1.3;
input double   InpProfitGuardATR       = 2.0;

input group "=== Session TP Scaling ==="
input double   InpOverlapTPScale       = 1.2;
input double   InpAsiaTPScale          = 0.8;

input group "=== Cooldown ==="
input int      InpMaxConsecLoss        = 4;
input int      InpPauseBars            = 20;

input group "=== SL Guard ==="
input double   InpMinSlATR             = 1.0;

//=====================================================================
// SECTION 3: GLOBAL STATE
//=====================================================================
ModeState  g_mode[MODE_COUNT];
DailyStats g_daily;
CTrade     g_trade;
datetime   g_lastBarM5 = 0;
ulong      g_lastDealTicket = 0;
datetime   g_lastDealCheck  = 0;
bool       g_firstTick      = true;
int        g_gateScore      = 0;

ulong      g_partialDone[];
int        g_partialCount   = 0;

int g_hM15emaF, g_hM15emaS, g_hH1emaF, g_hH1emaS, g_hH1atr, g_hM5atr, g_hM5gateEma;
int g_hAemaF, g_hAemaS, g_hArsi, g_hAadx;
int g_hBbb, g_hBrsi, g_hBadx;
int g_hCmacd, g_hCatr;
int g_hDcci, g_hDkcEma, g_hDkcAtr;

double g_h1stLine=0, g_m5stLine=0;
bool   g_h1stBull=true, g_m5stBull=true, g_m5stFlip=false, g_m5stFlipBear=false;
double g_h1stPrevUp=0, g_h1stPrevLo=0;
bool   g_h1stPrevBull=true;
double g_m5stPrevUp=0, g_m5stPrevLo=0;
bool   g_m5stPrevBull=true;

datetime g_lastCalcH1 = 0;
datetime g_lastCalcM5 = 0;

//=====================================================================
// SECTION 4: UTILITY FUNCTIONS
//=====================================================================
double Ind(int handle, int buf, int shift) {
   double v[];
   if(CopyBuffer(handle, buf, shift, 1, v) != 1) return 0.0;
   return v[0];
}

double NP(double price) {
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0) return NormalizeDouble(price, _Digits);
   return NormalizeDouble(MathRound(price / ts) * ts, _Digits);
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

bool IsNewBarM5() {
   datetime t = iTime(_Symbol, PERIOD_M5, 0);
   if(t == 0 || t == g_lastBarM5) return false;
   g_lastBarM5 = t;
   return true;
}

ENUM_SESSION_TYPE GetSession() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return SESSION_CLOSED;
   if(dt.day_of_week == 5 && h >= InpFridayClose)  return SESSION_CLOSED;
   if(dt.day_of_week == 1 && h < 1)                return SESSION_CLOSED;
   if(h < InpAsiaEnd)       return SESSION_ASIA;
   if(h < InpOverlapStart)  return SESSION_EUROPE;
   if(h < InpOverlapEnd)    return SESSION_OVERLAP;
   if(h < InpUSEnd)         return SESSION_US_LATE;
   return SESSION_LOW_LIQUIDITY;
}

bool IsModeInSession(ENUM_TRADE_MODE m, ENUM_SESSION_TYPE s) {
   if(s == SESSION_CLOSED) return false;
   if(s == SESSION_ASIA || s == SESSION_LOW_LIQUIDITY) return (m == MODE_B);
   return true;
}

int SessionCooldown(ENUM_SESSION_TYPE s, int base) {
   return (s == SESSION_OVERLAP) ? MathMax(base - 1, 1) : base;
}

double SessionLotScale(ENUM_SESSION_TYPE s) {
   if(s == SESSION_ASIA || s == SESSION_LOW_LIQUIDITY) return 0.5;
   return 1.0;
}

double SessionTPScale(ENUM_SESSION_TYPE s) {
   if(s == SESSION_OVERLAP) return InpOverlapTPScale;
   if(s == SESSION_ASIA)    return InpAsiaTPScale;
   return 1.0;
}

bool IsPartialDone(ulong ticket) {
   for(int i=0; i<g_partialCount; i++)
      if(g_partialDone[i]==ticket) return true;
   return false;
}

void MarkPartialDone(ulong ticket) {
   ArrayResize(g_partialDone, g_partialCount+1);
   g_partialDone[g_partialCount++]=ticket;
}

void CleanPartialList() {
   ulong temp[];
   int cnt=0;
   for(int i=0; i<g_partialCount; i++) {
      bool found=false;
      for(int j=PositionsTotal()-1; j>=0; j--) {
         if(PositionGetTicket(j)==g_partialDone[i]) { found=true; break; }
      }
      if(found) { ArrayResize(temp,cnt+1); temp[cnt++]=g_partialDone[i]; }
   }
   ArrayResize(g_partialDone, cnt);
   for(int i=0; i<cnt; i++) g_partialDone[i]=temp[i];
   g_partialCount=cnt;
}

bool IsSpreadOK(double atr) {
   if(atr <= 0) return false;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0 || ask <= bid) return false;
   return ((ask - bid) <= InpMaxSpreadATR * atr);
}

bool IsNewDay() {
   MqlDateTime a, b;
   TimeToStruct(TimeCurrent(), a);
   TimeToStruct(g_daily.lastResetDay, b);
   return (a.day != b.day || a.mon != b.mon || a.year != b.year);
}

int CountByMagic(int magic) {
   int c = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(tk > 0 && PositionGetInteger(POSITION_MAGIC) == magic && PositionGetString(POSITION_SYMBOL) == _Symbol)
         c++;
   }
   return c;
}

int CountTotal() {
   int c = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      long mg = PositionGetInteger(POSITION_MAGIC);
      if(mg >= InpMagicBase+1 && mg <= InpMagicBase+MODE_COUNT && PositionGetString(POSITION_SYMBOL) == _Symbol)
         c++;
   }
   return c;
}

int CountByDirection(long dir) {
   int c = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i); if(tk == 0) continue;
      long mg = PositionGetInteger(POSITION_MAGIC);
      if(mg < InpMagicBase+1 || mg > InpMagicBase+MODE_COUNT) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_TYPE) == dir) c++;
   }
   return c;
}

double LotsByMagic(int magic) {
   double total = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i); if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      total += PositionGetDouble(POSITION_VOLUME);
   }
   return total;
}

int GetModeCooldown(ENUM_TRADE_MODE m) {
   switch(m) { case MODE_A: return InpA_Cooldown; case MODE_B: return InpB_Cooldown;
                case MODE_C: return InpC_Cooldown; default: return InpD_Cooldown; }
}
int GetModeMaxPos(ENUM_TRADE_MODE m) {
   switch(m) { case MODE_A: return InpA_MaxPos; case MODE_B: return InpB_MaxPos;
                case MODE_C: return InpC_MaxPos; default: return InpD_MaxPos; }
}

bool IsBullCandle(int shift) { return iClose(_Symbol,PERIOD_M5,shift) > iOpen(_Symbol,PERIOD_M5,shift); }
bool IsBearCandle(int shift) { return iClose(_Symbol,PERIOD_M5,shift) < iOpen(_Symbol,PERIOD_M5,shift); }

bool IsHammerOrBullEngulf() {
   double o1=iOpen(_Symbol,PERIOD_M5,1), c1=iClose(_Symbol,PERIOD_M5,1);
   double h1=iHigh(_Symbol,PERIOD_M5,1), l1=iLow(_Symbol,PERIOD_M5,1);
   double body1=MathAbs(c1-o1), rng=h1-l1;
   if(rng <= 0 || body1 < rng*0.05) return false;
   double lw = MathMin(o1,c1) - l1;
   if(c1>o1 && lw>=body1*2.0 && body1>rng*0.1) return true;
   double o2=iOpen(_Symbol,PERIOD_M5,2), c2=iClose(_Symbol,PERIOD_M5,2);
   return (c2<o2 && c1>o1 && c1>o2 && o1<c2);
}

bool IsShootingStarOrBearEngulf() {
   double o1=iOpen(_Symbol,PERIOD_M5,1), c1=iClose(_Symbol,PERIOD_M5,1);
   double h1=iHigh(_Symbol,PERIOD_M5,1), l1=iLow(_Symbol,PERIOD_M5,1);
   double body1=MathAbs(c1-o1), rng=h1-l1;
   if(rng <= 0 || body1 < rng*0.05) return false;
   double uw = h1 - MathMax(o1,c1);
   if(c1<o1 && uw>=body1*2.0 && body1>rng*0.1) return true;
   double o2=iOpen(_Symbol,PERIOD_M5,2), c2=iClose(_Symbol,PERIOD_M5,2);
   return (c2>o2 && c1<o1 && c1<o2 && o1>c2);
}

//=====================================================================
// SECTION 5: INDICATORS / SUPERTREND
//=====================================================================
bool InitIndicators() {
   g_hM15emaF = iMA(_Symbol, PERIOD_M15, InpM15_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   g_hM15emaS = iMA(_Symbol, PERIOD_M15, InpM15_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   g_hH1emaF  = iMA(_Symbol, PERIOD_H1,  InpH1_EMA_Fast,  0, MODE_EMA, PRICE_CLOSE);
   g_hH1emaS  = iMA(_Symbol, PERIOD_H1,  InpH1_EMA_Slow,  0, MODE_EMA, PRICE_CLOSE);
   g_hH1atr   = iATR(_Symbol, PERIOD_H1, InpH1_ST_Period);
   g_hM5atr   = iATR(_Symbol, PERIOD_M5, 14);
   g_hM5gateEma = iMA(_Symbol, PERIOD_M5, 50, 0, MODE_EMA, PRICE_CLOSE);
   g_hAemaF   = iMA(_Symbol, PERIOD_M5, InpA_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   g_hAemaS   = iMA(_Symbol, PERIOD_M5, InpA_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   g_hArsi    = iRSI(_Symbol, PERIOD_M5, InpA_RSI, PRICE_CLOSE);
   g_hAadx    = iADX(_Symbol, PERIOD_M5, InpA_ADX);
   g_hBbb     = iBands(_Symbol, PERIOD_M5, InpB_BB_Period, 0, InpB_BB_Dev, PRICE_CLOSE);
   g_hBrsi    = iRSI(_Symbol, PERIOD_M5, InpB_RSI, PRICE_CLOSE);
   g_hBadx    = iADX(_Symbol, PERIOD_M5, InpB_ADX);
   g_hCmacd   = iMACD(_Symbol, PERIOD_M5, InpC_MACD_Fast, InpC_MACD_Slow, InpC_MACD_Sig, PRICE_CLOSE);
   g_hCatr    = iATR(_Symbol, PERIOD_M5, InpC_ST_Period);
   g_hDcci    = iCCI(_Symbol, PERIOD_M5, InpD_CCI, PRICE_TYPICAL);
   g_hDkcEma  = iMA(_Symbol, PERIOD_M5, InpD_KC_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_hDkcAtr  = iATR(_Symbol, PERIOD_M5, InpD_KC_Period);
   int all[] = {g_hM15emaF,g_hM15emaS,g_hH1emaF,g_hH1emaS,g_hH1atr,g_hM5atr,g_hM5gateEma,
                g_hAemaF,g_hAemaS,g_hArsi,g_hAadx,g_hBbb,g_hBrsi,g_hBadx,g_hCmacd,g_hCatr,g_hDcci,g_hDkcEma,g_hDkcAtr};
   for(int i=0; i<ArraySize(all); i++)
      if(all[i] == INVALID_HANDLE) { PrintFormat("[GoldBot] Indicator %d failed",i); return false; }
   return true;
}

void ReleaseIndicators() {
   int all[] = {g_hM15emaF,g_hM15emaS,g_hH1emaF,g_hH1emaS,g_hH1atr,g_hM5atr,g_hM5gateEma,
                g_hAemaF,g_hAemaS,g_hArsi,g_hAadx,g_hBbb,g_hBrsi,g_hBadx,g_hCmacd,g_hCatr,g_hDcci,g_hDkcEma,g_hDkcAtr};
   for(int i=0; i<ArraySize(all); i++)
      if(all[i] != INVALID_HANDLE) IndicatorRelease(all[i]);
}

void CalcSupertrend(ENUM_TIMEFRAMES tf, int atrHandle, double mult,
                    double &line, bool &bull, bool &flipped,
                    double &prevUp, double &prevLo, bool &prevBull) {
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(atrHandle, 0, 1, 3, atrBuf) < 3) return;
   double hi=iHigh(_Symbol,tf,1), lo=iLow(_Symbol,tf,1);
   double c1=iClose(_Symbol,tf,1), c2=iClose(_Symbol,tf,2);
   double atr=atrBuf[0], hl2=(hi+lo)/2.0;
   double up=hl2+mult*atr, dn=hl2-mult*atr;
   if(prevLo > 0 && c2 > prevLo) dn = MathMax(dn, prevLo);
   if(prevUp > 0 && c2 < prevUp) up = MathMin(up, prevUp);
   bool b = prevBull ? (c1 >= dn) : (c1 > up);
   flipped = (!prevBull && b);
   line = b ? dn : up;  bull = b;
   prevUp = up;  prevLo = dn;  prevBull = b;
}

void UpdateSupertrends() {
   datetime tH1 = iTime(_Symbol, PERIOD_H1, 0);
   if(tH1 != 0 && tH1 != g_lastCalcH1) {
      g_lastCalcH1 = tH1;
      bool dummy = false;
      CalcSupertrend(PERIOD_H1, g_hH1atr, InpH1_ST_Mult,
                     g_h1stLine, g_h1stBull, dummy,
                     g_h1stPrevUp, g_h1stPrevLo, g_h1stPrevBull);
   }
   datetime tM5 = iTime(_Symbol, PERIOD_M5, 0);
   if(tM5 != 0 && tM5 != g_lastCalcM5) {
      g_lastCalcM5 = tM5;
      bool prevBull = g_m5stPrevBull;
      CalcSupertrend(PERIOD_M5, g_hCatr, InpC_ST_Mult,
                     g_m5stLine, g_m5stBull, g_m5stFlip,
                     g_m5stPrevUp, g_m5stPrevLo, g_m5stPrevBull);
      g_m5stFlipBear = (prevBull && !g_m5stBull);
   }
}

void WarmupSupertrends() {
   int warmupBars = 30;
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(g_hH1atr, 0, 1, warmupBars + 3, atrBuf) >= warmupBars) {
      for(int s = warmupBars; s >= 1; s--) {
         double hi=iHigh(_Symbol,PERIOD_H1,s), lo=iLow(_Symbol,PERIOD_H1,s);
         double c1=iClose(_Symbol,PERIOD_H1,s), c2=iClose(_Symbol,PERIOD_H1,s+1);
         double atr=atrBuf[s-1], hl2=(hi+lo)/2.0;
         if(atr <= 0) continue;
         double up=hl2+InpH1_ST_Mult*atr, dn=hl2-InpH1_ST_Mult*atr;
         if(g_h1stPrevLo > 0 && c2 > g_h1stPrevLo) dn=MathMax(dn, g_h1stPrevLo);
         if(g_h1stPrevUp > 0 && c2 < g_h1stPrevUp) up=MathMin(up, g_h1stPrevUp);
         bool b = g_h1stPrevBull ? (c1 >= dn) : (c1 > up);
         g_h1stLine = b ? dn : up;  g_h1stBull = b;
         g_h1stPrevUp = up;  g_h1stPrevLo = dn;  g_h1stPrevBull = b;
      }
   }
   double m5AtrBuf[];
   ArraySetAsSeries(m5AtrBuf, true);
   if(CopyBuffer(g_hCatr, 0, 1, warmupBars + 3, m5AtrBuf) >= warmupBars) {
      for(int s = warmupBars; s >= 1; s--) {
         double hi=iHigh(_Symbol,PERIOD_M5,s), lo=iLow(_Symbol,PERIOD_M5,s);
         double c1=iClose(_Symbol,PERIOD_M5,s), c2=iClose(_Symbol,PERIOD_M5,s+1);
         double atr=m5AtrBuf[s-1], hl2=(hi+lo)/2.0;
         if(atr <= 0) continue;
         double up=hl2+InpC_ST_Mult*atr, dn=hl2-InpC_ST_Mult*atr;
         if(g_m5stPrevLo > 0 && c2 > g_m5stPrevLo) dn=MathMax(dn, g_m5stPrevLo);
         if(g_m5stPrevUp > 0 && c2 < g_m5stPrevUp) up=MathMin(up, g_m5stPrevUp);
         bool prevBull = g_m5stPrevBull;
         bool b = prevBull ? (c1 >= dn) : (c1 > up);
         g_m5stFlip = (!prevBull && b);
         g_m5stFlipBear = (prevBull && !b);
         g_m5stLine = b ? dn : up;  g_m5stBull = b;
         g_m5stPrevUp = up;  g_m5stPrevLo = dn;  g_m5stPrevBull = b;
      }
   }
   Print("[GoldBot] Supertrend warmup done.");
}

int CheckTrendGate() {
   int bullPass = 0;
   if(Ind(g_hM15emaF,0,1) > Ind(g_hM15emaS,0,1)) bullPass++;
   if(Ind(g_hH1emaF,0,1) > Ind(g_hH1emaS,0,1))   bullPass++;
   if(g_h1stBull) bullPass++;
   return bullPass;
}

bool IsM5VetoBuy() {
   if(InpM5VetoATR <= 0) return false;
   double c1  = iClose(_Symbol, PERIOD_M5, 1);
   double ema = Ind(g_hM5gateEma, 0, 1);
   double atr = Ind(g_hM5atr, 0, 1);
   if(ema <= 0 || atr <= 0) return false;
   return (c1 < ema - InpM5VetoATR * atr);
}

bool IsM5VetoSell() {
   if(InpM5VetoATR <= 0) return false;
   double c1  = iClose(_Symbol, PERIOD_M5, 1);
   double ema = Ind(g_hM5gateEma, 0, 1);
   double atr = Ind(g_hM5atr, 0, 1);
   if(ema <= 0 || atr <= 0) return false;
   return (c1 > ema + InpM5VetoATR * atr);
}

//=====================================================================
// SECTION 6: SIGNAL GENERATION (4 MODES × BUY/SELL)
//=====================================================================
SignalResult CheckSignalA() {
   SignalResult r;
   ZeroMemory(r);
   double adx = Ind(g_hAadx,0,1);
   if(adx < InpA_ADX_Min) return r;
   if(adx <= Ind(g_hAadx,0,2)) return r;
   double ef1=Ind(g_hAemaF,0,1), es1=Ind(g_hAemaS,0,1);
   double ef2=Ind(g_hAemaF,0,2), es2=Ind(g_hAemaS,0,2);
   double ef3=Ind(g_hAemaF,0,3), es3=Ind(g_hAemaS,0,3);
   double rsi1=Ind(g_hArsi,0,1), rsi2=Ind(g_hArsi,0,2);
   double atr=Ind(g_hM5atr,0,1);
   if(atr<=0) return r;
   double gateEma=Ind(g_hM5gateEma,0,1);
   double c1=iClose(_Symbol,PERIOD_M5,1);
   bool bullCross=(ef2<=es2 && ef1>es1);
   bool bullCrossRecent=(ef3<=es3 && ef2>es2 && ef1>es1);
   if((bullCross || bullCrossRecent) && rsi1>50.0 && rsi1>rsi2 && IsBullCandle(1)) {
      if(gateEma>0 && c1>gateEma+InpA_MaxChaseATR*atr) return r;
      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      r.direction=DIR_BUY; r.sl=NP(ask-InpA_SL*atr); r.tp=NP(ask+InpA_TP*atr);
      r.reason="GoldenX";
      return r;
   }
   bool bearCross=(ef2>=es2 && ef1<es1);
   bool bearCrossRecent=(ef3>=es3 && ef2<es2 && ef1<es1);
   if((bearCross || bearCrossRecent) && rsi1<50.0 && rsi1<rsi2 && IsBearCandle(1)) {
      if(gateEma>0 && c1<gateEma-InpA_MaxChaseATR*atr) return r;
      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      r.direction=DIR_SELL; r.sl=NP(bid+InpA_SL*atr); r.tp=NP(bid-InpA_TP*atr);
      r.reason="DeathX";
      return r;
   }
   return r;
}

bool ExitSignalA(long posType) {
   if(posType==POSITION_TYPE_BUY)  return Ind(g_hAemaF,0,1) < Ind(g_hAemaS,0,1);
   if(posType==POSITION_TYPE_SELL) return Ind(g_hAemaF,0,1) > Ind(g_hAemaS,0,1);
   return false;
}

SignalResult CheckSignalB() {
   SignalResult r;
   ZeroMemory(r);
   double adx = Ind(g_hBadx,0,1);
   if(adx > InpB_ADX_Max) return r;
   double bbl1=Ind(g_hBbb,2,1), bbl2=Ind(g_hBbb,2,2);
   double bbm1=Ind(g_hBbb,0,1), bbm2=Ind(g_hBbb,0,2);
   double bbu1=Ind(g_hBbb,1,1), bbu2=Ind(g_hBbb,1,2);
   double c1=iClose(_Symbol,PERIOD_M5,1), c2=iClose(_Symbol,PERIOD_M5,2);
   double rsi1=Ind(g_hBrsi,0,1), rsi2=Ind(g_hBrsi,0,2);
   double atr=Ind(g_hM5atr,0,1);
   if(atr<=0) return r;
   double l2=iLow(_Symbol,PERIOD_M5,2);
   if(!((c2>bbl2 && l2>bbl2) || c1<=bbl1)) {
      if((rsi2<InpB_RSI_OS || rsi1<InpB_RSI_OS) && rsi1>rsi2 && bbm1>=bbm2-0.01) {
         double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
         r.direction=DIR_BUY; r.sl=NP(bbl1-InpB_SL*atr*0.5); r.tp=NP(bbm1);
         if(r.tp-ask < atr*0.5) r.tp=NP(bbu1);
         r.reason="BB_BuyBounce";
         return r;
      }
   }
   double h2=iHigh(_Symbol,PERIOD_M5,2);
   if(!((c2<bbu2 && h2<bbu2) || c1>=bbu1)) {
      if((rsi2>InpB_RSI_OB || rsi1>InpB_RSI_OB) && rsi1<rsi2 && bbm1<=bbm2+0.01) {
         double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
         r.direction=DIR_SELL; r.sl=NP(bbu1+InpB_SL*atr*0.5); r.tp=NP(bbm1);
         if(bid-r.tp < atr*0.5) r.tp=NP(bbl1);
         r.reason="BB_SellBounce";
         return r;
      }
   }
   return r;
}

bool ExitSignalB(long posType) {
   double c1=iClose(_Symbol,PERIOD_M5,1);
   double bbm=Ind(g_hBbb,0,1);
   double rsi=Ind(g_hBrsi,0,1);
   if(posType==POSITION_TYPE_BUY)  return (c1 >= bbm) || (rsi > InpB_RSI_OB);
   if(posType==POSITION_TYPE_SELL) return (c1 <= bbm) || (rsi < InpB_RSI_OS);
   return false;
}

SignalResult CheckSignalC() {
   SignalResult r;
   ZeroMemory(r);
   bool flippedBear = g_m5stFlipBear;
   double mm1=Ind(g_hCmacd,0,1), ms1=Ind(g_hCmacd,1,1);
   double mm2=Ind(g_hCmacd,0,2), ms2=Ind(g_hCmacd,1,2);
   double body=MathAbs(iClose(_Symbol,PERIOD_M5,1)-iOpen(_Symbol,PERIOD_M5,1));
   double avg=0;
   for(int i=1; i<=10; i++) avg+=MathAbs(iClose(_Symbol,PERIOD_M5,i)-iOpen(_Symbol,PERIOD_M5,i));
   if(body < avg/10.0*0.8) return r;
   double atr=Ind(g_hM5atr,0,1);
   if(atr<=0) return r;
   double minSlDist = atr * 0.8;
   if(g_m5stFlip || g_m5stBull) {
      bool macdGoldenX = (mm2<=ms2 && mm1>ms1);
      bool macdFreshBull = (mm2<0 && mm1>=0);
      if(g_m5stFlip || macdGoldenX || macdFreshBull) {
         double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
         double rawSl = g_m5stLine - atr * 0.5;
         if(ask - rawSl < minSlDist) rawSl = ask - minSlDist;
         r.direction=DIR_BUY; r.sl=NP(rawSl); r.tp=NP(ask+InpC_TP*atr);
         r.reason=g_m5stFlip?"ST_FlipBuy":"ST_MACD_Buy";
         return r;
      }
   }
   if(flippedBear || !g_m5stBull) {
      bool macdDeathX = (mm2>=ms2 && mm1<ms1);
      if(flippedBear && (mm1-ms1)<0) macdDeathX=true;
      if(macdDeathX) {
         double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
         double rawSl = g_m5stLine + atr * 0.5;
         if(rawSl - bid < minSlDist) rawSl = bid + minSlDist;
         r.direction=DIR_SELL; r.sl=NP(rawSl); r.tp=NP(bid-InpC_TP*atr);
         r.reason=flippedBear?"ST_FlipSell":"ST_MACD_Sell";
         return r;
      }
   }
   return r;
}

bool ExitSignalC(long posType) {
   if(posType==POSITION_TYPE_BUY) {
      if(!g_m5stBull) return true;
      double h1=Ind(g_hCmacd,0,1)-Ind(g_hCmacd,1,1);
      double h2=Ind(g_hCmacd,0,2)-Ind(g_hCmacd,1,2);
      double h3=Ind(g_hCmacd,0,3)-Ind(g_hCmacd,1,3);
      if(Ind(g_hCmacd,0,1)<Ind(g_hCmacd,1,1) && Ind(g_hCmacd,0,2)>=Ind(g_hCmacd,1,2)) return true;
      if(h1<h2 && h2<h3 && h3>0) return true;
   }
   if(posType==POSITION_TYPE_SELL) {
      if(g_m5stBull) return true;
      double h1=Ind(g_hCmacd,0,1)-Ind(g_hCmacd,1,1);
      double h2=Ind(g_hCmacd,0,2)-Ind(g_hCmacd,1,2);
      double h3=Ind(g_hCmacd,0,3)-Ind(g_hCmacd,1,3);
      if(Ind(g_hCmacd,0,1)>Ind(g_hCmacd,1,1) && Ind(g_hCmacd,0,2)<=Ind(g_hCmacd,1,2)) return true;
      if(h1>h2 && h2>h3 && h3<0) return true;
   }
   return false;
}

SignalResult CheckSignalD() {
   SignalResult r;
   ZeroMemory(r);
   double cci1=Ind(g_hDcci,0,1), cci2=Ind(g_hDcci,0,2);
   double kcEma=Ind(g_hDkcEma,0,1), kcAtr=Ind(g_hDkcAtr,0,1);
   double kcLo=kcEma-InpD_KC_Mult*kcAtr, kcHi=kcEma+InpD_KC_Mult*kcAtr;
   double c1=iClose(_Symbol,PERIOD_M5,1);
   double atr=Ind(g_hM5atr,0,1);
   if(atr<=0) return r;
   if(cci2 < -100.0 && cci1 > -100.0 && c1-kcLo < atr*0.5 && IsHammerOrBullEngulf()) {
      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      r.direction=DIR_BUY; r.sl=NP(kcLo-InpD_SL*atr*0.7); r.tp=NP(kcEma);
      if(r.tp-ask < atr*0.5) r.tp=NP(ask+atr*1.5);
      r.reason="CCI_KC_Buy";
      return r;
   }
   if(cci2 > 100.0 && cci1 < 100.0 && kcHi-c1 < atr*0.5 && IsShootingStarOrBearEngulf()) {
      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      r.direction=DIR_SELL; r.sl=NP(kcHi+InpD_SL*atr*0.7); r.tp=NP(kcEma);
      if(bid-r.tp < atr*0.5) r.tp=NP(bid-atr*1.5);
      r.reason="CCI_KC_Sell";
      return r;
   }
   return r;
}

bool ExitSignalD(long posType) {
   double cci=Ind(g_hDcci,0,1), c1=iClose(_Symbol,PERIOD_M5,1), km=Ind(g_hDkcEma,0,1);
   if(posType==POSITION_TYPE_BUY)  return (cci>100.0) || (cci<0 && c1<km);
   if(posType==POSITION_TYPE_SELL) return (cci<-100.0) || (cci>0 && c1>km);
   return false;
}

typedef SignalResult (*SignalFunc)();
typedef bool (*ExitFunc)(long);

SignalFunc g_signalFuncs[MODE_COUNT];
ExitFunc  g_exitFuncs[MODE_COUNT];

void InitSignalFuncPtrs() {
   g_signalFuncs[MODE_A]=CheckSignalA; g_signalFuncs[MODE_B]=CheckSignalB;
   g_signalFuncs[MODE_C]=CheckSignalC; g_signalFuncs[MODE_D]=CheckSignalD;
   g_exitFuncs[MODE_A]=ExitSignalA; g_exitFuncs[MODE_B]=ExitSignalB;
   g_exitFuncs[MODE_C]=ExitSignalC; g_exitFuncs[MODE_D]=ExitSignalD;
}

//=====================================================================
// SECTION 7: RISK MANAGEMENT
//=====================================================================
void InitModeStates() {
   bool enables[] = {InpEnableA, InpEnableB, InpEnableC, InpEnableD};
   for(int i=0; i<MODE_COUNT; i++) {
      ModeState tmp; ZeroMemory(tmp);
      tmp.isEnabled=enables[i]; tmp.magicNumber=InpMagicBase+i+1; tmp.winRate=100.0;
      g_mode[i]=tmp;
   }
}
void InitDailyStats() {
   g_daily.startEquity=AccountInfoDouble(ACCOUNT_EQUITY); g_daily.peakEquity=g_daily.startEquity;
   g_daily.realizedPnL=0; g_daily.lastResetDay=TimeCurrent();
   g_daily.isDailyLocked=false; g_daily.isDrawdownLocked=false;
}
void CheckDailyReset() {
   if(!IsNewDay()) return;
   if(g_daily.realizedPnL != 0)
      PrintFormat("[GoldBot] Daily PnL=%.2f  A[%.0f%% %d/%d] B[%.0f%% %d/%d] C[%.0f%% %d/%d] D[%.0f%% %d/%d]",
         g_daily.realizedPnL,
         g_mode[0].winRate,g_mode[0].recentWins,g_mode[0].recentTotal,
         g_mode[1].winRate,g_mode[1].recentWins,g_mode[1].recentTotal,
         g_mode[2].winRate,g_mode[2].recentWins,g_mode[2].recentTotal,
         g_mode[3].winRate,g_mode[3].recentWins,g_mode[3].recentTotal);
   g_daily.startEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_daily.startEquity > g_daily.peakEquity) g_daily.peakEquity=g_daily.startEquity;
   g_daily.realizedPnL=0; g_daily.isDailyLocked=false;
   g_daily.lastResetDay=TimeCurrent();
   for(int i=0; i<MODE_COUNT; i++) { g_mode[i].consecutiveLosses=0; g_mode[i].pauseBarsLeft=0; }
   Print("[GoldBot] Daily reset.");
}
bool IsDailyLossHit() {
   if(g_daily.isDailyLocked) return true;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_daily.startEquity-eq > g_daily.startEquity*InpDailyMaxLossPct/100.0) {
      g_daily.isDailyLocked=true; Print("[GoldBot] Daily loss limit."); return true;
   }
   return false;
}
bool IsDrawdownHit() {
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_daily.isDrawdownLocked) {
      if(eq > g_daily.peakEquity*(1.0-InpTotalDrawdownPct/100.0+0.03)) {
         g_daily.isDrawdownLocked=false; Print("[GoldBot] Drawdown recovered.");
      }
      return g_daily.isDrawdownLocked;
   }
   if(eq > g_daily.peakEquity) g_daily.peakEquity=eq;
   double dd=(g_daily.peakEquity-eq)/g_daily.peakEquity*100.0;
   if(dd>=InpTotalDrawdownPct) {
      g_daily.isDrawdownLocked=true; PrintFormat("[GoldBot] Drawdown %.1f%%.",dd); return true;
   }
   return false;
}
void UpdateCooldowns() {
   for(int i=0; i<MODE_COUNT; i++) {
      if(g_mode[i].cooldownBarsLeft>0) g_mode[i].cooldownBarsLeft--;
      if(g_mode[i].pauseBarsLeft>0) g_mode[i].pauseBarsLeft--;
      if(g_mode[i].isDisabledByAdaptive && !g_mode[i].isInRecovery) {
         if(--g_mode[i].recoveryCountdown<=0) {
            g_mode[i].isInRecovery=true;
            g_mode[i].recoveryTrialsLeft=InpRecoveryTrials;
            PrintFormat("[GoldBot] %s entered recovery mode.",MODE_NAMES[i]);
         }
      }
   }
}
bool HasNearbyPosition(int magic, double minGap) {
   double mid=(SymbolInfoDouble(_Symbol,SYMBOL_ASK)+SymbolInfoDouble(_Symbol,SYMBOL_BID))/2.0;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong tk=PositionGetTicket(i); if(tk==0) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(MathAbs(mid-PositionGetDouble(POSITION_PRICE_OPEN)) < minGap) return true;
   }
   return false;
}
double CalcDirectionRiskPct(long posDir) {
   double totalRisk = 0;
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(ts <= 0 || tv <= 0) return 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i); if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      long mg = PositionGetInteger(POSITION_MAGIC);
      if(mg < InpMagicBase+1 || mg > InpMagicBase+MODE_COUNT) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_TYPE) != posDir) continue;
      double op = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double slDist = (sl > 0) ? MathAbs(op - sl) : Ind(g_hM5atr,0,1) * 2.0;
      totalRisk += (slDist / ts) * tv * vol;
   }
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   return (eq > 0) ? (totalRisk / eq * 100.0) : 0;
}

bool CanOpen(ENUM_TRADE_MODE m, ENUM_SESSION_TYPE s, int dir=DIR_NONE) {
   if(!g_mode[m].isEnabled) return false;
   if(g_mode[m].isDisabledByAdaptive && !g_mode[m].isInRecovery) return false;
   if(!IsModeInSession(m,s)) return false;
   if(g_mode[m].cooldownBarsLeft>0 || g_mode[m].pauseBarsLeft>0) return false;
   if(CountByMagic(g_mode[m].magicNumber)>=GetModeMaxPos(m)) return false;
   if(CountTotal()>=InpMaxTotalPositions) return false;
   if(LotsByMagic(g_mode[m].magicNumber)>=InpMaxLotsPerMode) return false;
   if(dir==DIR_BUY  && CountByDirection(POSITION_TYPE_BUY)>=InpMaxPosPerDir)  return false;
   if(dir==DIR_SELL && CountByDirection(POSITION_TYPE_SELL)>=InpMaxPosPerDir) return false;
   if(dir==DIR_BUY  && CalcDirectionRiskPct(POSITION_TYPE_BUY)>=InpMaxDirRiskPct)  return false;
   if(dir==DIR_SELL && CalcDirectionRiskPct(POSITION_TYPE_SELL)>=InpMaxDirRiskPct) return false;
   double atr=Ind(g_hM5atr,0,1);
   if(atr>0 && HasNearbyPosition(g_mode[m].magicNumber,atr*0.5)) return false;
   return true;
}
void OnOpened(ENUM_TRADE_MODE m, ENUM_SESSION_TYPE s) { g_mode[m].cooldownBarsLeft=SessionCooldown(s,GetModeCooldown(m)); }
void UpdateAdaptive(ENUM_TRADE_MODE m) {
   int wins=0,total=0;
   long visitedPosIds[];
   int  visitedCount=0;
   HistorySelect(0,TimeCurrent());
   for(int i=HistoryDealsTotal()-1; i>=0 && total<InpAdaptiveWindow; i--) {
      ulong tk=HistoryDealGetTicket(i); if(tk==0) continue;
      if(HistoryDealGetInteger(tk,DEAL_MAGIC)!=g_mode[m].magicNumber) continue;
      if(HistoryDealGetString(tk,DEAL_SYMBOL)!=_Symbol) continue;
      if(HistoryDealGetInteger(tk,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
      long posId=HistoryDealGetInteger(tk,DEAL_POSITION_ID);
      if(IsPositionStillOpen(posId)) continue;
      bool alreadyVisited=false;
      for(int j=0; j<visitedCount; j++)
         if(visitedPosIds[j]==posId) { alreadyVisited=true; break; }
      if(alreadyVisited) continue;
      ArrayResize(visitedPosIds,visitedCount+1);
      visitedPosIds[visitedCount++]=posId;
      double posPnl=CalcPositionTotalPnL(posId,g_mode[m].magicNumber);
      total++;
      if(posPnl>0) wins++;
   }
   g_mode[m].recentTotal=total; g_mode[m].recentWins=wins;
   if(total>=InpAdaptiveWindow) {
      g_mode[m].winRate=(double)wins/total*100.0;
      if(g_mode[m].winRate<InpMinWinRate && !g_mode[m].isDisabledByAdaptive) {
         g_mode[m].isDisabledByAdaptive=true; g_mode[m].isInRecovery=false;
         g_mode[m].recoveryCountdown=InpRecoveryBars;
         PrintFormat("[GoldBot] %s disabled. WR=%.1f%%",MODE_NAMES[m],g_mode[m].winRate);
      }
   }
}
void OnPositionClosed(ENUM_TRADE_MODE m, double totalProfit) {
   if(totalProfit>0) {
      g_mode[m].consecutiveLosses=0;
      if(g_mode[m].isInRecovery && g_mode[m].isDisabledByAdaptive) {
         g_mode[m].isDisabledByAdaptive=false; g_mode[m].isInRecovery=false;
         PrintFormat("[GoldBot] %s re-enabled.",MODE_NAMES[m]);
      }
   } else {
      g_mode[m].consecutiveLosses++;
      if(g_mode[m].consecutiveLosses>=InpMaxConsecLoss) {
         g_mode[m].pauseBarsLeft=InpPauseBars;
         PrintFormat("[GoldBot] %s paused. %d losses.",MODE_NAMES[m],g_mode[m].consecutiveLosses);
      }
      if(g_mode[m].isInRecovery) {
         g_mode[m].recoveryTrialsLeft--;
         if(g_mode[m].recoveryTrialsLeft<=0) {
            g_mode[m].isInRecovery=false;
            g_mode[m].recoveryCountdown=InpRecoveryBars;
            PrintFormat("[GoldBot] %s recovery failed, re-disabled.",MODE_NAMES[m]);
         }
      }
   }
   UpdateAdaptive(m);
}
double CalcLots(double slDist, ENUM_TRADE_MODE m, ENUM_SESSION_TYPE s) {
   if(slDist<=0) return 0;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   if(ts<=0||tv<=0) return 0;
   double lots=(eq*InpRiskPercent/100.0)/(slDist/ts*tv);
   lots*=SessionLotScale(s);
   if(g_mode[m].isInRecovery) lots*=InpRecoveryScale;
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   if(lots < minLot) lots = minLot;
   return NL(lots);
}

//=====================================================================
// SECTION 8: TRADE EXECUTION & POSITION MANAGEMENT
//=====================================================================
double GetMinStopDist() {
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double spd=ask-bid;
   long stopLevel=(long)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minDist=stopLevel*_Point;
   if(minDist<spd*2) minDist=spd*2;
   return minDist;
}

bool OpenBuy(ENUM_TRADE_MODE m, double sl, double tp, double lots, string comment) {
   g_trade.SetExpertMagicNumber(g_mode[m].magicNumber);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   sl=NP(sl); tp=NP(tp);
   if(sl>=ask || tp<=ask || lots<=0) return false;
   double minDist=GetMinStopDist();
   if(ask-sl < minDist) sl=NP(ask-minDist);
   if(tp-ask < minDist) tp=NP(ask+minDist);
   if(!IsSpreadOK(Ind(g_hM5atr,0,1))) return false;
   bool ok=g_trade.Buy(lots,_Symbol,ask,sl,tp,comment);
   if(ok) PrintFormat("[GoldBot] BUY %s | %.2f @ %.2f SL=%.2f TP=%.2f",MODE_NAMES[m],lots,ask,sl,tp);
   else   PrintFormat("[GoldBot] BUY FAIL %s: %s",MODE_NAMES[m],g_trade.ResultRetcodeDescription());
   return ok;
}
bool OpenSell(ENUM_TRADE_MODE m, double sl, double tp, double lots, string comment) {
   g_trade.SetExpertMagicNumber(g_mode[m].magicNumber);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   sl=NP(sl); tp=NP(tp);
   if(sl<=bid || tp>=bid || lots<=0) return false;
   double minDist=GetMinStopDist();
   if(sl-bid < minDist) sl=NP(bid+minDist);
   if(bid-tp < minDist) tp=NP(bid-minDist);
   if(!IsSpreadOK(Ind(g_hM5atr,0,1))) return false;
   bool ok=g_trade.Sell(lots,_Symbol,bid,sl,tp,comment);
   if(ok) PrintFormat("[GoldBot] SELL %s | %.2f @ %.2f SL=%.2f TP=%.2f",MODE_NAMES[m],lots,bid,sl,tp);
   else   PrintFormat("[GoldBot] SELL FAIL %s: %s",MODE_NAMES[m],g_trade.ResultRetcodeDescription());
   return ok;
}

void ManageTrailing(double atr) {
   if(atr<=0) return;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double spd=ask-bid;
   long stopLevel=(long)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minDist=stopLevel*_Point;
   if(minDist<spd*2) minDist=spd*2;
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong tk=PositionGetTicket(i); if(tk==0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      long mg=PositionGetInteger(POSITION_MAGIC);
      if(mg<InpMagicBase+1 || mg>InpMagicBase+MODE_COUNT) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      long ptype=PositionGetInteger(POSITION_TYPE);
      double op=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      double vol=PositionGetDouble(POSITION_VOLUME);
      double pft=(ptype==POSITION_TYPE_BUY)?(bid-op):(op-ask);
      if(InpPartialPct>0 && pft>=InpPartialATR*atr && !IsPartialDone(tk)) {
         double closeVol=NL(vol*InpPartialPct/100.0);
         if(closeVol>=minLot && (vol-closeVol)>=minLot) {
            g_trade.SetExpertMagicNumber((int)mg);
            if(g_trade.PositionClosePartial(tk,closeVol,SLIPPAGE_DEFAULT)) {
               MarkPartialDone(tk);
               PrintFormat("[GoldBot] PARTIAL %s %.2f of %.2f @ pft=%.1f ATR",
                           (ptype==POSITION_TYPE_BUY)?"BUY":"SELL",closeVol,vol,pft/atr);
            }
            continue;
         }
      }
      double nsl=sl;
      bool isTrendPos=(mg==InpMagicBase+1 || mg==InpMagicBase+3);
      if(ptype==POSITION_TYPE_BUY) {
         double be=NP(op+spd+_Point);
         if(pft>=3.5*atr)      nsl=MathMax(nsl,NP(op+3.0*atr));
         else if(pft>=3.0*atr) nsl=MathMax(nsl,NP(op+2.5*atr));
         else if(pft>=2.5*atr) nsl=MathMax(nsl,NP(op+2.0*atr));
         else if(pft>=2.0*atr) nsl=MathMax(nsl,NP(op+1.5*atr));
         else if(pft>=1.5*atr) nsl=MathMax(nsl,be);
         else if(isTrendPos && pft>=1.0*atr) nsl=MathMax(nsl,be);
         if(tp>0 && nsl>tp-minDist) nsl=NP(tp-minDist);
         if(nsl>sl+_Point*10 && nsl<bid-minDist) { g_trade.SetExpertMagicNumber((int)mg); g_trade.PositionModify(tk,nsl,tp); }
      }
      if(ptype==POSITION_TYPE_SELL) {
         double be=NP(op-spd-_Point);
         double slRef=sl>0 ? sl : NP(op+5.0*atr);
         if(pft>=3.5*atr)      nsl=MathMin(slRef,NP(op-3.0*atr));
         else if(pft>=3.0*atr) nsl=MathMin(slRef,NP(op-2.5*atr));
         else if(pft>=2.5*atr) nsl=MathMin(slRef,NP(op-2.0*atr));
         else if(pft>=2.0*atr) nsl=MathMin(slRef,NP(op-1.5*atr));
         else if(pft>=1.5*atr) nsl=MathMin(slRef,be);
         else if(isTrendPos && pft>=1.0*atr) nsl=MathMin(slRef,be);
         else nsl=sl;
         if(tp>0 && nsl<tp+minDist) nsl=NP(tp+minDist);
         if(nsl<sl-_Point*10 && nsl>ask+minDist) { g_trade.SetExpertMagicNumber((int)mg); g_trade.PositionModify(tk,nsl,tp); }
      }
   }
}

void CheckExits() {
   double atr=Ind(g_hM5atr,0,1);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong tk=PositionGetTicket(i); if(tk==0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      long mg=PositionGetInteger(POSITION_MAGIC);
      if(mg<InpMagicBase+1 || mg>InpMagicBase+MODE_COUNT) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      ENUM_TRADE_MODE m=(ENUM_TRADE_MODE)(mg-InpMagicBase-1);
      long ptype=PositionGetInteger(POSITION_TYPE);
      if(InpProfitGuardATR>0 && atr>0) {
         double op=PositionGetDouble(POSITION_PRICE_OPEN);
         double pft=(ptype==POSITION_TYPE_BUY)?(bid-op):(op-ask);
         if(pft>=InpProfitGuardATR*atr) continue;
      }
      if(g_exitFuncs[m](ptype)) { g_trade.SetExpertMagicNumber((int)mg); g_trade.PositionClose(tk,SLIPPAGE_DEFAULT); }
   }
}

void ForceCloseAll(string reason) {
   int closed = 0;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong tk=PositionGetTicket(i); if(tk==0) continue;
      long mg=PositionGetInteger(POSITION_MAGIC);
      if(mg<InpMagicBase+1 || mg>InpMagicBase+MODE_COUNT) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      g_trade.SetExpertMagicNumber((int)mg);
      if(g_trade.PositionClose(tk,SLIPPAGE_DEFAULT)) closed++;
   }
   if(closed > 0) PrintFormat("[GoldBot] ForceClose: %s (%d positions)",reason,closed);
}

void CheckFlashCrash(double atr) {
   if(atr<=0) return;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double prevClose=iClose(_Symbol,PERIOD_M5,1);
   if(prevClose <= 0) return;
   double mid=(ask+bid)/2.0;
   double diff=MathAbs(mid-prevClose);
   if(diff > 2.5*atr) ForceCloseAll("FlashCrash");
}

bool IsPositionStillOpen(long positionId) {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong tk=PositionGetTicket(i);
      if(tk>0 && PositionGetInteger(POSITION_IDENTIFIER)==positionId) return true;
   }
   return false;
}

double CalcPositionTotalPnL(long positionId, long magic, bool needSelect=true) {
   double total=0;
   if(needSelect) HistorySelect(0,TimeCurrent());
   for(int i=HistoryDealsTotal()-1; i>=0; i--) {
      ulong tk=HistoryDealGetTicket(i); if(tk==0) continue;
      if(HistoryDealGetInteger(tk,DEAL_POSITION_ID)!=positionId) continue;
      if(HistoryDealGetInteger(tk,DEAL_MAGIC)!=magic) continue;
      if(HistoryDealGetInteger(tk,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
      total+=HistoryDealGetDouble(tk,DEAL_PROFIT)
            +HistoryDealGetDouble(tk,DEAL_SWAP)
            +HistoryDealGetDouble(tk,DEAL_COMMISSION);
   }
   return total;
}

void ProcessDeals() {
   datetime now=TimeCurrent();
   if(now-g_lastDealCheck<5) return;
   g_lastDealCheck=now;
   HistorySelect(0,now);
   for(int i=0; i<HistoryDealsTotal(); i++) {
      ulong tk=HistoryDealGetTicket(i);
      if(tk<=g_lastDealTicket) continue;
      if(HistoryDealGetInteger(tk,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
      if(HistoryDealGetString(tk,DEAL_SYMBOL)!=_Symbol) continue;
      long mg=HistoryDealGetInteger(tk,DEAL_MAGIC);
      if(mg<InpMagicBase+1 || mg>InpMagicBase+MODE_COUNT) continue;
      ENUM_TRADE_MODE m=(ENUM_TRADE_MODE)(mg-InpMagicBase-1);
      double dealPnl=HistoryDealGetDouble(tk,DEAL_PROFIT)
                    +HistoryDealGetDouble(tk,DEAL_SWAP)
                    +HistoryDealGetDouble(tk,DEAL_COMMISSION);
      g_daily.realizedPnL+=dealPnl;
      g_lastDealTicket=tk;
      long posId=HistoryDealGetInteger(tk,DEAL_POSITION_ID);
      if(IsPositionStillOpen(posId)) {
         PrintFormat("[GoldBot] Partial %s deal=%.2f (pos #%lld still open)",MODE_NAMES[m],dealPnl,posId);
         continue;
      }
      double totalPnl=CalcPositionTotalPnL(posId,mg,false);
      OnPositionClosed(m,totalPnl);
      PrintFormat("[GoldBot] Closed %s posPnL=%.2f (deal=%.2f)",MODE_NAMES[m],totalPnl,dealPnl);
   }
}

//=====================================================================
// SECTION 9: MAIN EA LIFECYCLE
//=====================================================================
int OnInit() {
   if(!InitIndicators()) { Print("[GoldBot] Indicator init failed."); return INIT_FAILED; }
   g_trade.SetDeviationInPoints(SLIPPAGE_DEFAULT);
   g_trade.SetTypeFilling(DetectFilling());
   InitModeStates(); InitDailyStats(); InitSignalFuncPtrs();
   HistorySelect(0, TimeCurrent());
   int totalDeals = HistoryDealsTotal();
   if(totalDeals > 0)
      g_lastDealTicket = HistoryDealGetTicket(totalDeals - 1);
   WarmupSupertrends();
   for(int i=0; i<MODE_COUNT; i++) UpdateAdaptive((ENUM_TRADE_MODE)i);
   PrintFormat("[GoldBot] v3 Started. Magic: A=%d B=%d C=%d D=%d",
               g_mode[0].magicNumber,g_mode[1].magicNumber,g_mode[2].magicNumber,g_mode[3].magicNumber);
   PrintFormat("[GoldBot] Session=%d ATR=%.2f Ask=%.2f Bid=%.2f",
               (int)GetSession(),Ind(g_hM5atr,0,1),SymbolInfoDouble(_Symbol,SYMBOL_ASK),SymbolInfoDouble(_Symbol,SYMBOL_BID));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { ReleaseIndicators(); Print("[GoldBot] Stopped."); }

void OnTick() {
   if(g_firstTick) {
      MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
      PrintFormat("[GoldBot] FIRST TICK: server=%s h=%d dow=%d",TimeToString(TimeCurrent()),dt.hour,dt.day_of_week);
      g_firstTick=false;
   }
   double atr=Ind(g_hM5atr,0,1);
   ManageTrailing(atr);
   CheckFlashCrash(atr);
   ProcessDeals();
   if(!IsNewBarM5()) return;
   UpdateSupertrends();
   CleanPartialList();
   CheckDailyReset();
   UpdateCooldowns();
   bool isRiskLocked = IsDailyLossHit() || IsDrawdownHit();
   if(isRiskLocked) {
      if(InpForceCloseOnRiskLock) ForceCloseAll("RiskLock");
      else                        CheckExits();
      return;
   }
   ENUM_SESSION_TYPE ses=GetSession();
   if(ses==SESSION_CLOSED) { if(InpCloseBeforeWeekend) ForceCloseAll("Weekend"); return; }
   CheckExits();
   if(!IsSpreadOK(atr)) return;
   int gate=CheckTrendGate();
   g_gateScore=gate;
   int bearPass = 3 - gate;
   bool m5VetoBuy  = IsM5VetoBuy();
   bool m5VetoSell = IsM5VetoSell();
   bool canLong  = (gate >= InpTrendGateMin) && !m5VetoBuy;
   bool canShort = InpAllowShort && (bearPass >= InpTrendGateMin) && !m5VetoSell;
   PrintFormat("[GoldBot] BAR: ses=%d atr=%.2f gate=%d L=%d S=%d pos=%d",
              (int)ses,atr,gate,(int)canLong,(int)canShort,CountTotal());
   for(int i=0; i<MODE_COUNT; i++) {
      ENUM_TRADE_MODE m=(ENUM_TRADE_MODE)i;
      if(!CanOpen(m,ses)) continue;
      SignalResult sig=g_signalFuncs[m]();
      if(sig.direction==DIR_NONE) continue;
      bool isTrendMode = (m == MODE_A || m == MODE_C);
      bool isMeanRevMode = (m == MODE_B || m == MODE_D);
      bool useLong = true, useShort = InpAllowShort;
      if(m == MODE_A) {
         useLong  = (gate == 3) && !m5VetoBuy;
         useShort = InpAllowShort && canShort;
      } else if(isTrendMode) {
         useLong  = canLong;
         useShort = InpAllowShort && canShort;
      } else if(isMeanRevMode) {
         useLong  = true;
         useShort = InpAllowShort;
      }
      if(sig.direction==DIR_BUY && !useLong) continue;
      if(sig.direction==DIR_SELL && !useShort) continue;
      if(!CanOpen(m,ses,sig.direction)) continue;
      double price=(sig.direction==DIR_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double tpScale=SessionTPScale(ses);
      if(tpScale!=1.0) {
         double tpDist=MathAbs(sig.tp-price)*tpScale;
         sig.tp=(sig.direction==DIR_BUY)?NP(price+tpDist):NP(price-tpDist);
      }
      double slDist=MathAbs(price-sig.sl);
      double h1atr=Ind(g_hH1atr,0,1);
      double refAtr=(h1atr>0)?MathMax(atr,h1atr/3.5):atr;
      double minSl=refAtr*InpMinSlATR;
      if(slDist < minSl) {
         slDist = minSl;
         sig.sl = (sig.direction==DIR_BUY) ? NP(price-minSl) : NP(price+minSl);
      }
      double lots=CalcLots(slDist,m,ses);
      bool boostBuy =(g_gateScore==3 && sig.direction==DIR_BUY  && m!=MODE_A);
      bool boostSell=(g_gateScore==0 && sig.direction==DIR_SELL);
      if((boostBuy||boostSell) && InpGateBoostMult>1.0) lots=NL(lots*InpGateBoostMult);
      double maxLotsEff=NL(InpMaxLotsPerMode*SessionLotScale(ses));
      double lotsRoom=NL(maxLotsEff-LotsByMagic(g_mode[m].magicNumber));
      if(lots>lotsRoom) lots=lotsRoom;
      if(lots<=0) continue;
      string dir=(sig.direction==DIR_BUY)?"BUY":"SELL";
      PrintFormat("[GoldBot] SIGNAL %s %s: %s sl=%.2f tp=%.2f lots=%.2f gate=%d",dir,MODE_NAMES[m],sig.reason,sig.sl,sig.tp,lots,g_gateScore);
      bool ok=false;
      if(sig.direction==DIR_BUY)  ok=OpenBuy(m,sig.sl,sig.tp,lots,MODE_NAMES[m]+"_"+sig.reason);
      if(sig.direction==DIR_SELL) ok=OpenSell(m,sig.sl,sig.tp,lots,MODE_NAMES[m]+"_"+sig.reason);
      if(ok) OnOpened(m,ses);
   }
}

void OnTrade() { ProcessDeals(); }
