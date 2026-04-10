//+------------------------------------------------------------------+
//| GoldPulse_EA.mq5 v4.0 - XAUUSD Multi-TF Swing Strategy         |
//| H1 EMA trend + M5 pullback entry | Fixed R:R | Structure-based  |
//+------------------------------------------------------------------+
#property copyright "GoldPulse"
#property version   "4.00"

#include <Trade/Trade.mqh>

//=====================================================================
// SECTION 1: ENUMS, CONSTANTS, STRUCTS
//=====================================================================
enum ENUM_SESSION {
   SESSION_ASIA,
   SESSION_EUROPE,
   SESSION_OVERLAP,
   SESSION_US_LATE,
   SESSION_LOW_LIQ,
   SESSION_CLOSED
};

enum ENUM_SHIELD_LEVEL { SHIELD_GREEN=0, SHIELD_YELLOW=1, SHIELD_ORANGE=2, SHIELD_RED=3 };
enum ENUM_TREND_BIAS   { BIAS_BULL=1, BIAS_BEAR=-1, BIAS_NEUTRAL=0 };

#define SLIPPAGE  30
#define DIR_BUY   1
#define DIR_SELL  -1
#define DIR_NONE  0
#define MAX_TRACKED_POS 20

struct SignalResult {
   int    direction;
   double sl;
   double tp;
   string reason;
};

struct DailyStats {
   double            initialEquity;
   double            startEquity;
   double            peakEquity;
   double            realizedPnL;
   datetime          lastResetDay;
   ENUM_SHIELD_LEVEL shieldLevel;
   bool              isDayLocked;
   bool              isTotalLocked;
};

struct VolatilityState {
   double atrCurrent;
   double atrNormal;
   bool   isStormActive;
   int    gapPauseBars;
};

struct PosTracker {
   ulong  ticket;
   double entryPrice;
   double slDist;
   bool   tp1Done;
};

//=====================================================================
// SECTION 2: INPUT PARAMETERS
//=====================================================================
input group "=== Global ==="
input int      InpMagic              = 400000;
input double   InpRiskPercent        = 2.0;
input double   InpMaxSpreadATR       = 0.3;
input int      InpMaxPositions       = 2;
input int      InpMaxBuyPos          = 2;
input int      InpMaxSellPos         = 1;
input bool     InpAllowShort         = true;
input bool     InpCloseBeforeWeekend = true;

input group "=== Equity Shield ==="
input double   InpYellowLossPct      = 5.0;
input double   InpOrangeLossPct      = 10.0;
input double   InpRedLossPct         = 15.0;
input double   InpTotalDrawdownPct   = 30.0;

input group "=== H1 Trend (EMA) ==="
input int      InpEMA_Fast           = 21;
input int      InpEMA_Slow           = 50;

input group "=== Entry: Pullback ==="
input double   InpPullbackZoneATR    = 1.0;
input int      InpRSIPeriod          = 14;
input double   InpRSIRecoverLow      = 40.0;
input double   InpRSIRecoverHigh     = 60.0;
input int      InpMFIPeriod          = 14;
input double   InpMFIMin             = 30.0;
input int      InpCooldownBars       = 8;
input double   InpMinGapATR          = 2.0;

input group "=== Risk:Reward ==="
input double   InpMinRR              = 1.2;
input double   InpTP1_RR             = 1.5;
input double   InpTP1_ClosePct       = 50.0;
input double   InpSLBufferATR        = 0.3;
input int      InpSwingLookbackM5    = 10;
input int      InpSwingLookbackH1    = 20;

input group "=== Trailing (after TP1) ==="
input int      InpTrailSwingBars     = 6;
input double   InpTrailBufferATR     = 0.3;

input group "=== Position Management ==="
input int      InpMaxHoldBars        = 240;

input group "=== Volatility Guard ==="
input double   InpStormExpansion     = 2.5;
input double   InpFlashCrashATR      = 3.0;
input double   InpGapATR             = 2.0;
input int      InpGapPauseBars       = 5;

input group "=== Session (Server Hour UTC+0) ==="
input int      InpAsiaEnd            = 5;
input int      InpOverlapStart       = 11;
input int      InpOverlapEnd         = 15;
input int      InpUSEnd              = 19;
input int      InpDayCloseHour       = 22;
input int      InpFridayClose        = 22;

input group "=== Equity Curve Filter ==="
input int      InpECFWindow          = 8;
input double   InpECFMinWinRate      = 20.0;
input int      InpECFPauseBars       = 20;
input int      InpConsecLossPause    = 4;
input int      InpConsecLossPauseBars = 15;

//=====================================================================
// SECTION 3: GLOBAL STATE
//=====================================================================
DailyStats      g_daily;
VolatilityState g_vol;
CTrade          g_trade;
datetime        g_lastBarM5        = 0;
ulong           g_lastDealTicket   = 0;
datetime        g_lastDealCheck    = 0;
bool            g_firstTick        = true;
int             g_cooldownBars     = 0;
int             g_consecutiveLosses = 0;
bool            g_isPaused         = false;
int             g_pauseBarsLeft    = 0;
double          g_winRate          = 100.0;

PosTracker      g_tracker[];
int             g_trackerCount     = 0;

datetime        g_posOpenTime[];
ulong           g_posOpenTicket[];
int             g_posOpenCount     = 0;

int g_hH1EMAFast, g_hH1EMASlow, g_hH1ATR;
int g_hM5ATR, g_hRSI, g_hMFI;

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

ENUM_SESSION GetSession() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return SESSION_CLOSED;
   if(dt.day_of_week == 5 && h >= InpFridayClose) return SESSION_CLOSED;
   if(dt.day_of_week == 1 && h < 1)               return SESSION_CLOSED;
   if(h < InpAsiaEnd)       return SESSION_ASIA;
   if(h < InpOverlapStart)  return SESSION_EUROPE;
   if(h < InpOverlapEnd)    return SESSION_OVERLAP;
   if(h < InpUSEnd)         return SESSION_US_LATE;
   return SESSION_LOW_LIQ;
}

double SessionLotScale(ENUM_SESSION ses) {
   switch(ses) {
      case SESSION_ASIA:    return 0.5;
      case SESSION_EUROPE:  return 1.0;
      case SESSION_OVERLAP: return 1.2;
      case SESSION_US_LATE: return 0.8;
      default:              return 0.5;
   }
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

int CountPositions() {
   int c = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(tk > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic &&
         PositionGetString(POSITION_SYMBOL) == _Symbol) c++;
   }
   return c;
}

int CountByDirection(long dir) {
   int c = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_TYPE) == dir) c++;
   }
   return c;
}

double GetMinStopDist() {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spd = ask - bid;
   long stopLevel = (long)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopLevel * _Point;
   if(minDist < spd * 2) minDist = spd * 2;
   return minDist;
}

bool HasNearbyPosition(double minGap) {
   double mid = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(MathAbs(mid - PositionGetDouble(POSITION_PRICE_OPEN)) < minGap) return true;
   }
   return false;
}

void TrackPositionOpenTime(ulong ticket) {
   ArrayResize(g_posOpenTime, g_posOpenCount + 1);
   ArrayResize(g_posOpenTicket, g_posOpenCount + 1);
   g_posOpenTicket[g_posOpenCount] = ticket;
   g_posOpenTime[g_posOpenCount]   = TimeCurrent();
   g_posOpenCount++;
}

int GetPositionAgeBars(ulong ticket) {
   for(int i = 0; i < g_posOpenCount; i++) {
      if(g_posOpenTicket[i] == ticket)
         return (int)((TimeCurrent() - g_posOpenTime[i]) / 300);
   }
   return 0;
}

void CleanPositionTimeTracker() {
   ulong tmpTicket[];
   datetime tmpTime[];
   int cnt = 0;
   for(int i = 0; i < g_posOpenCount; i++) {
      bool found = false;
      for(int j = PositionsTotal()-1; j >= 0; j--)
         if(PositionGetTicket(j) == g_posOpenTicket[i]) { found = true; break; }
      if(found) {
         ArrayResize(tmpTicket, cnt+1);
         ArrayResize(tmpTime, cnt+1);
         tmpTicket[cnt] = g_posOpenTicket[i];
         tmpTime[cnt]   = g_posOpenTime[i];
         cnt++;
      }
   }
   ArrayResize(g_posOpenTicket, cnt);
   ArrayResize(g_posOpenTime, cnt);
   for(int i = 0; i < cnt; i++) {
      g_posOpenTicket[i] = tmpTicket[i];
      g_posOpenTime[i]   = tmpTime[i];
   }
   g_posOpenCount = cnt;
}

//=====================================================================
// SECTION 4B: POSITION TRACKER (R:R state per position)
//=====================================================================
void AddTracker(ulong ticket, double entryPrice, double slDist) {
   if(g_trackerCount >= MAX_TRACKED_POS) CleanTracker();
   ArrayResize(g_tracker, g_trackerCount + 1);
   g_tracker[g_trackerCount].ticket     = ticket;
   g_tracker[g_trackerCount].entryPrice = entryPrice;
   g_tracker[g_trackerCount].slDist     = slDist;
   g_tracker[g_trackerCount].tp1Done    = false;
   g_trackerCount++;
}

int FindTracker(ulong ticket) {
   for(int i = 0; i < g_trackerCount; i++)
      if(g_tracker[i].ticket == ticket) return i;
   return -1;
}

void CleanTracker() {
   PosTracker tmp[];
   int cnt = 0;
   for(int i = 0; i < g_trackerCount; i++) {
      bool found = false;
      for(int j = PositionsTotal()-1; j >= 0; j--)
         if(PositionGetTicket(j) == g_tracker[i].ticket) { found = true; break; }
      if(found) {
         ArrayResize(tmp, cnt+1);
         tmp[cnt] = g_tracker[i];
         cnt++;
      }
   }
   ArrayResize(g_tracker, cnt);
   for(int i = 0; i < cnt; i++) g_tracker[i] = tmp[i];
   g_trackerCount = cnt;
}

//=====================================================================
// SECTION 5: INDICATOR INITIALIZATION
//=====================================================================
bool InitIndicators() {
   g_hH1EMAFast = iMA(_Symbol, PERIOD_H1, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   g_hH1EMASlow = iMA(_Symbol, PERIOD_H1, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   g_hH1ATR     = iATR(_Symbol, PERIOD_H1, 14);
   g_hM5ATR     = iATR(_Symbol, PERIOD_M5, 14);
   g_hRSI       = iRSI(_Symbol, PERIOD_M5, InpRSIPeriod, PRICE_CLOSE);
   g_hMFI       = iMFI(_Symbol, PERIOD_M5, InpMFIPeriod, VOLUME_TICK);
   int all[] = {g_hH1EMAFast, g_hH1EMASlow, g_hH1ATR, g_hM5ATR, g_hRSI, g_hMFI};
   for(int i = 0; i < ArraySize(all); i++)
      if(all[i] == INVALID_HANDLE) { PrintFormat("[GP] Indicator %d init failed", i); return false; }
   return true;
}

void ReleaseIndicators() {
   int all[] = {g_hH1EMAFast, g_hH1EMASlow, g_hH1ATR, g_hM5ATR, g_hRSI, g_hMFI};
   for(int i = 0; i < ArraySize(all); i++)
      if(all[i] != INVALID_HANDLE) IndicatorRelease(all[i]);
}

//=====================================================================
// SECTION 6: H1 EMA TREND DETECTION
//=====================================================================
ENUM_TREND_BIAS GetH1TrendBias() {
   double emaFast1 = Ind(g_hH1EMAFast, 0, 1);
   double emaSlow1 = Ind(g_hH1EMASlow, 0, 1);
   double emaFast2 = Ind(g_hH1EMAFast, 0, 2);
   double emaSlow2 = Ind(g_hH1EMASlow, 0, 2);
   if(emaFast1 <= 0 || emaSlow1 <= 0) return BIAS_NEUTRAL;
   double close1 = iClose(_Symbol, PERIOD_H1, 1);
   if(close1 <= 0) return BIAS_NEUTRAL;
   double emaDiff = MathAbs(emaFast1 - emaSlow1);
   double minSep = emaSlow1 * 0.001;
   if(emaDiff < minSep) return BIAS_NEUTRAL;
   if(emaFast1 > emaSlow1 && emaFast2 > emaSlow2 && close1 > emaFast1)
      return BIAS_BULL;
   if(emaFast1 < emaSlow1 && emaFast2 < emaSlow2 && close1 < emaFast1)
      return BIAS_BEAR;
   return BIAS_NEUTRAL;
}

//=====================================================================
// SECTION 7: H1 SWING DETECTION
//=====================================================================
double GetH1SwingHigh(int lookback) {
   double high = 0;
   for(int i = 1; i <= lookback; i++) {
      double h = iHigh(_Symbol, PERIOD_H1, i);
      if(h > high) high = h;
   }
   return high;
}

double GetH1SwingLow(int lookback) {
   double low = DBL_MAX;
   for(int i = 1; i <= lookback; i++) {
      double l = iLow(_Symbol, PERIOD_H1, i);
      if(l < low) low = l;
   }
   return low;
}

double GetM5SwingLow(int lookback) {
   double low = DBL_MAX;
   for(int i = 1; i <= lookback; i++) {
      double l = iLow(_Symbol, PERIOD_M5, i);
      if(l < low) low = l;
   }
   return low;
}

double GetM5SwingHigh(int lookback) {
   double high = 0;
   for(int i = 1; i <= lookback; i++) {
      double h = iHigh(_Symbol, PERIOD_M5, i);
      if(h > high) high = h;
   }
   return high;
}

//=====================================================================
// SECTION 8: ENTRY SIGNAL - H1 PULLBACK + M5 REVERSAL + R:R FILTER
//=====================================================================
SignalResult CheckSignal(ENUM_TREND_BIAS bias) {
   SignalResult r;
   ZeroMemory(r);
   if(bias == BIAS_NEUTRAL) return r;
   double m5atr = Ind(g_hM5ATR, 0, 1);
   double h1atr = Ind(g_hH1ATR, 0, 1);
   if(m5atr <= 0 || h1atr <= 0) return r;
   double emaFast = Ind(g_hH1EMAFast, 0, 1);
   if(emaFast <= 0) return r;
   double c1  = iClose(_Symbol, PERIOD_M5, 1);
   double c2  = iClose(_Symbol, PERIOD_M5, 2);
   double o1  = iOpen(_Symbol, PERIOD_M5, 1);
   double h2  = iHigh(_Symbol, PERIOD_M5, 2);
   double l2  = iLow(_Symbol, PERIOD_M5, 2);
   double rsi1 = Ind(g_hRSI, 0, 1);
   double rsi2 = Ind(g_hRSI, 0, 2);
   double rsi3 = Ind(g_hRSI, 0, 3);
   double mfi  = Ind(g_hMFI, 0, 1);
   double zoneWidth = InpPullbackZoneATR * h1atr;
   if(bias == BIAS_BULL) {
      bool inPullbackZone = (c2 <= emaFast + zoneWidth && c2 >= emaFast - zoneWidth);
      if(!inPullbackZone) return r;
      bool isReversalCandle = (c1 > o1 && c1 > h2);
      bool rsiRecovery      = (rsi1 > InpRSIRecoverLow && (rsi2 < InpRSIRecoverLow || rsi3 < InpRSIRecoverLow));
      bool mfiConfirm       = (mfi >= InpMFIMin);
      if(!isReversalCandle || !rsiRecovery || !mfiConfirm) return r;
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double swingLow = GetM5SwingLow(InpSwingLookbackM5);
      double rawSL = swingLow - InpSLBufferATR * m5atr;
      double slDist = ask - rawSL;
      if(slDist <= 0) return r;
      double h1SwingHigh = GetH1SwingHigh(InpSwingLookbackH1);
      double tpDist = h1SwingHigh - ask;
      if(tpDist <= 0) tpDist = InpTP1_RR * slDist;
      double rr = tpDist / slDist;
      if(rr < InpMinRR) return r;
      r.direction = DIR_BUY;
      r.sl = NP(rawSL);
      r.tp = NP(h1SwingHigh);
      r.reason = "PB_Buy";
      return r;
   }
   if(bias == BIAS_BEAR) {
      bool inPullbackZone = (c2 >= emaFast - zoneWidth && c2 <= emaFast + zoneWidth);
      if(!inPullbackZone) return r;
      bool isReversalCandle = (c1 < o1 && c1 < l2);
      bool rsiRecovery      = (rsi1 < InpRSIRecoverHigh && (rsi2 > InpRSIRecoverHigh || rsi3 > InpRSIRecoverHigh));
      bool mfiConfirm       = (mfi >= InpMFIMin);
      if(!isReversalCandle || !rsiRecovery || !mfiConfirm) return r;
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double swingHigh = GetM5SwingHigh(InpSwingLookbackM5);
      double rawSL = swingHigh + InpSLBufferATR * m5atr;
      double slDist = rawSL - bid;
      if(slDist <= 0) return r;
      double h1SwingLow = GetH1SwingLow(InpSwingLookbackH1);
      double tpDist = bid - h1SwingLow;
      if(tpDist <= 0) tpDist = InpTP1_RR * slDist;
      double rr = tpDist / slDist;
      if(rr < InpMinRR) return r;
      r.direction = DIR_SELL;
      r.sl = NP(rawSL);
      r.tp = NP(h1SwingLow);
      r.reason = "PB_Sell";
      return r;
   }
   return r;
}

//=====================================================================
// SECTION 9: PROTECTION SYSTEM
//=====================================================================
void InitDailyStats() {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   g_daily.initialEquity = eq;
   g_daily.startEquity   = eq;
   g_daily.peakEquity    = eq;
   g_daily.realizedPnL   = 0;
   g_daily.lastResetDay  = TimeCurrent();
   g_daily.shieldLevel   = SHIELD_GREEN;
   g_daily.isDayLocked   = false;
   g_daily.isTotalLocked = false;
}

void CheckDailyReset() {
   if(!IsNewDay()) return;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   PrintFormat("[GP] Daily PnL=%.2f  WR=%.0f%%  Equity=%.2f", g_daily.realizedPnL, g_winRate, eq);
   g_daily.startEquity  = eq;
   g_daily.peakEquity   = eq;
   g_daily.realizedPnL  = 0;
   g_daily.shieldLevel  = SHIELD_GREEN;
   g_daily.isDayLocked  = false;
   g_daily.lastResetDay = TimeCurrent();
   g_consecutiveLosses  = 0;
   g_isPaused           = false;
   g_pauseBarsLeft      = 0;
   Print("[GP] Daily reset.");
}

ENUM_SHIELD_LEVEL UpdateEquityShield() {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_daily.peakEquity) g_daily.peakEquity = eq;
   double totalAccountDD = (g_daily.initialEquity > 0)
      ? (g_daily.initialEquity - eq) / g_daily.initialEquity * 100.0 : 0;
   if(totalAccountDD >= InpTotalDrawdownPct) {
      if(!g_daily.isTotalLocked)
         PrintFormat("[GP] TOTAL DD KILL: %.1f%% (initial=%.0f current=%.0f)",
                    totalAccountDD, g_daily.initialEquity, eq);
      g_daily.isTotalLocked = true;
      g_daily.shieldLevel = SHIELD_RED;
      return SHIELD_RED;
   }
   double dailyLoss = (g_daily.startEquity > 0)
      ? (g_daily.startEquity - eq) / g_daily.startEquity * 100.0 : 0;
   if(dailyLoss >= InpRedLossPct) {
      if(g_daily.shieldLevel < SHIELD_RED)
         PrintFormat("[GP] SHIELD RED: daily=%.1f%%", dailyLoss);
      g_daily.shieldLevel = SHIELD_RED;
      return SHIELD_RED;
   }
   if(dailyLoss >= InpOrangeLossPct) {
      if(g_daily.shieldLevel < SHIELD_ORANGE)
         PrintFormat("[GP] SHIELD ORANGE: daily=%.1f%%", dailyLoss);
      g_daily.shieldLevel = SHIELD_ORANGE;
      return SHIELD_ORANGE;
   }
   if(dailyLoss >= InpYellowLossPct) {
      if(g_daily.shieldLevel < SHIELD_YELLOW)
         PrintFormat("[GP] SHIELD YELLOW: daily=%.1f%%", dailyLoss);
      g_daily.shieldLevel = SHIELD_YELLOW;
      return SHIELD_YELLOW;
   }
   if(dailyLoss < InpYellowLossPct * 0.4 && g_daily.shieldLevel == SHIELD_YELLOW) {
      g_daily.shieldLevel = SHIELD_GREEN;
      Print("[GP] Shield recovered to GREEN.");
   }
   return g_daily.shieldLevel;
}

void InitVolatilityState() {
   g_vol.atrCurrent    = 0;
   g_vol.atrNormal     = 0;
   g_vol.isStormActive = false;
   g_vol.gapPauseBars  = 0;
}

void UpdateVolatilityState() {
   g_vol.atrCurrent = Ind(g_hM5ATR, 0, 1);
   double sum = 0;
   int cnt = 0;
   for(int i = 5; i <= 24; i++) {
      double a = Ind(g_hM5ATR, 0, i);
      if(a > 0) { sum += a; cnt++; }
   }
   g_vol.atrNormal = (cnt > 0) ? sum / cnt : g_vol.atrCurrent;
   if(g_vol.atrNormal > 0 && g_vol.atrCurrent > 0) {
      double expansion = g_vol.atrCurrent / g_vol.atrNormal;
      if(expansion >= InpStormExpansion) {
         if(!g_vol.isStormActive) {
            g_vol.isStormActive = true;
            PrintFormat("[GP] STORM ACTIVE: expansion=%.1fx", expansion);
         }
      } else if(expansion < 1.3) {
         if(g_vol.isStormActive) {
            g_vol.isStormActive = false;
            Print("[GP] Storm cleared.");
         }
      }
   }
   if(g_vol.gapPauseBars > 0) g_vol.gapPauseBars--;
}

void HandleStormMode() {
   if(!g_vol.isStormActive) return;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minDist = GetMinStopDist();
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      long ptype = PositionGetInteger(POSITION_TYPE);
      double op  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl  = PositionGetDouble(POSITION_SL);
      double pft = (ptype == POSITION_TYPE_BUY) ? (bid - op) : (op - ask);
      if(pft < 0) {
         g_trade.SetExpertMagicNumber(InpMagic);
         g_trade.PositionClose(tk, SLIPPAGE);
         PrintFormat("[GP] Storm close #%llu pft=%.2f", tk, pft);
      } else {
         double spd = ask - bid;
         double be = (ptype == POSITION_TYPE_BUY) ? NP(op + spd + _Point) : NP(op - spd - _Point);
         if(ptype == POSITION_TYPE_BUY && be > sl + _Point*10 && be < bid - minDist) {
            g_trade.SetExpertMagicNumber(InpMagic);
            g_trade.PositionModify(tk, be, 0);
         }
         if(ptype == POSITION_TYPE_SELL && (sl <= 0 || be < sl - _Point*10) && be > ask + minDist) {
            g_trade.SetExpertMagicNumber(InpMagic);
            g_trade.PositionModify(tk, be, 0);
         }
      }
   }
}

void CheckFlashCrash(double atr) {
   if(atr <= 0) return;
   double mid = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   double prevClose = iClose(_Symbol, PERIOD_M5, 1);
   if(prevClose <= 0) return;
   if(MathAbs(mid - prevClose) > InpFlashCrashATR * atr) {
      ForceCloseAll("FlashCrash");
      g_daily.isDayLocked = true;
   }
}

void CheckGapGuard(double atr) {
   if(atr <= 0) return;
   double open0  = iOpen(_Symbol, PERIOD_M5, 0);
   double close1 = iClose(_Symbol, PERIOD_M5, 1);
   if(open0 <= 0 || close1 <= 0) return;
   if(MathAbs(open0 - close1) > InpGapATR * atr && g_vol.gapPauseBars <= 0) {
      g_vol.gapPauseBars = InpGapPauseBars;
      PrintFormat("[GP] Gap detected, pausing %d bars", InpGapPauseBars);
   }
}

void CheckTimeGuard() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   bool nearDayClose = (dt.hour >= InpDayCloseHour);
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      int ageBars = GetPositionAgeBars(tk);
      bool shouldClose = false;
      string reason = "";
      if(ageBars >= InpMaxHoldBars) { shouldClose = true; reason = "MaxHold"; }
      if(nearDayClose) { shouldClose = true; reason = "DayClose"; }
      if(shouldClose) {
         g_trade.SetExpertMagicNumber(InpMagic);
         if(g_trade.PositionClose(tk, SLIPPAGE))
            PrintFormat("[GP] TimeGuard close #%llu: %s (age=%d)", tk, reason, ageBars);
      }
   }
}

//=====================================================================
// SECTION 10: POSITION MANAGEMENT - TP1 + STRUCTURAL TRAILING
//=====================================================================
double CalcLots(double slDist, ENUM_SESSION ses) {
   if(slDist <= 0) return 0;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(ts <= 0 || tv <= 0) return 0;
   double riskPct = InpRiskPercent;
   if(g_daily.shieldLevel == SHIELD_YELLOW) riskPct *= 0.5;
   double lots = (eq * riskPct / 100.0) / (slDist / ts * tv);
   lots *= SessionLotScale(ses);
   if(g_vol.atrNormal > 0 && g_vol.atrCurrent > 0) {
      double volRatio = g_vol.atrCurrent / g_vol.atrNormal;
      if(volRatio > 1.5) lots *= 0.7;
      else if(volRatio > 1.2) lots *= 0.85;
   }
   return NL(lots);
}

void ManagePositions(double atr) {
   if(atr <= 0) return;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spd = ask - bid;
   double minDist = GetMinStopDist();
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      long ptype = PositionGetInteger(POSITION_TYPE);
      double op  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl  = PositionGetDouble(POSITION_SL);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double pft = (ptype == POSITION_TYPE_BUY) ? (bid - op) : (op - ask);
      int idx = FindTracker(tk);
      if(idx < 0) continue;
      double slDist = g_tracker[idx].slDist;
      if(slDist <= 0) continue;
      if(!g_tracker[idx].tp1Done && pft >= InpTP1_RR * slDist) {
         double closeVol = NL(vol * InpTP1_ClosePct / 100.0);
         bool didPartial = false;
         if(closeVol >= minLot && (vol - closeVol) >= minLot) {
            g_trade.SetExpertMagicNumber(InpMagic);
            didPartial = g_trade.PositionClosePartial(tk, closeVol, SLIPPAGE);
            if(didPartial)
               PrintFormat("[GP] TP1 hit: partial %.2f lots, pft=%.1fR", closeVol, pft / slDist);
         }
         g_tracker[idx].tp1Done = true;
         double be = (ptype == POSITION_TYPE_BUY) ? NP(op + spd + _Point) : NP(op - spd - _Point);
         g_trade.SetExpertMagicNumber(InpMagic);
         if(ptype == POSITION_TYPE_BUY && be < bid - minDist)
            g_trade.PositionModify(tk, be, 0);
         if(ptype == POSITION_TYPE_SELL && be > ask + minDist)
            g_trade.PositionModify(tk, be, 0);
         if(!didPartial)
            PrintFormat("[GP] TP1 hit: vol too small for partial, moved SL to BE, pft=%.1fR", pft / slDist);
         continue;
      }
      if(g_tracker[idx].tp1Done) {
         double nsl = sl;
         if(ptype == POSITION_TYPE_BUY) {
            double trailRef = GetM5SwingLow(InpTrailSwingBars);
            double trailSL  = NP(trailRef - InpTrailBufferATR * atr);
            nsl = MathMax(nsl, trailSL);
            if(nsl > sl + _Point * 10 && nsl < bid - minDist) {
               g_trade.SetExpertMagicNumber(InpMagic);
               g_trade.PositionModify(tk, nsl, 0);
            }
         }
         if(ptype == POSITION_TYPE_SELL) {
            double trailRef = GetM5SwingHigh(InpTrailSwingBars);
            double trailSL  = NP(trailRef + InpTrailBufferATR * atr);
            double slRef = (sl > 0) ? sl : NP(op + 5.0 * atr);
            nsl = MathMin(slRef, trailSL);
            if(sl > 0 && nsl < sl - _Point * 10 && nsl > ask + minDist) {
               g_trade.SetExpertMagicNumber(InpMagic);
               g_trade.PositionModify(tk, nsl, 0);
            }
         }
      }
   }
}

//=====================================================================
// SECTION 11: TRADE EXECUTION
//=====================================================================
bool OpenBuy(double sl, double lots, string comment) {
   g_trade.SetExpertMagicNumber(InpMagic);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   sl = NP(sl);
   if(sl >= ask || lots <= 0) return false;
   double minDist = GetMinStopDist();
   if(ask - sl < minDist) sl = NP(ask - minDist);
   double atr = Ind(g_hM5ATR, 0, 1);
   if(!IsSpreadOK(atr)) return false;
   bool ok = g_trade.Buy(lots, _Symbol, ask, sl, 0, comment);
   if(ok) {
      PrintFormat("[GP] BUY %.2f @ %.2f SL=%.2f [%s]", lots, ask, sl, comment);
      ulong ticket = g_trade.ResultOrder();
      if(ticket > 0) {
         TrackPositionOpenTime(ticket);
         AddTracker(ticket, ask, ask - sl);
      }
   } else {
      PrintFormat("[GP] BUY FAIL: %s", g_trade.ResultRetcodeDescription());
   }
   return ok;
}

bool OpenSell(double sl, double lots, string comment) {
   g_trade.SetExpertMagicNumber(InpMagic);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   sl = NP(sl);
   if(sl <= bid || lots <= 0) return false;
   double minDist = GetMinStopDist();
   if(sl - bid < minDist) sl = NP(bid + minDist);
   double atr = Ind(g_hM5ATR, 0, 1);
   if(!IsSpreadOK(atr)) return false;
   bool ok = g_trade.Sell(lots, _Symbol, bid, sl, 0, comment);
   if(ok) {
      PrintFormat("[GP] SELL %.2f @ %.2f SL=%.2f [%s]", lots, bid, sl, comment);
      ulong ticket = g_trade.ResultOrder();
      if(ticket > 0) {
         TrackPositionOpenTime(ticket);
         AddTracker(ticket, bid, sl - bid);
      }
   } else {
      PrintFormat("[GP] SELL FAIL: %s", g_trade.ResultRetcodeDescription());
   }
   return ok;
}

void ForceCloseAll(string reason) {
   int closed = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      g_trade.SetExpertMagicNumber(InpMagic);
      if(g_trade.PositionClose(tk, SLIPPAGE)) closed++;
   }
   if(closed > 0) PrintFormat("[GP] ForceClose: %s (%d positions)", reason, closed);
}

bool CanOpen(ENUM_SESSION ses, int dir) {
   if(ses == SESSION_CLOSED || ses == SESSION_LOW_LIQ || ses == SESSION_ASIA) return false;
   if(g_isPaused && g_pauseBarsLeft > 0) return false;
   if(g_cooldownBars > 0) return false;
   if(CountPositions() >= InpMaxPositions) return false;
   if(dir == DIR_BUY  && CountByDirection(POSITION_TYPE_BUY)  >= InpMaxBuyPos) return false;
   if(dir == DIR_SELL && CountByDirection(POSITION_TYPE_SELL) >= InpMaxSellPos) return false;
   double atr = Ind(g_hM5ATR, 0, 1);
   if(atr > 0 && HasNearbyPosition(InpMinGapATR * atr)) return false;
   return true;
}

//=====================================================================
// SECTION 12: DEAL PROCESSING & EQUITY CURVE FILTER
//=====================================================================
bool IsPositionStillOpen(long positionId) {
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(tk > 0 && PositionGetInteger(POSITION_IDENTIFIER) == positionId) return true;
   }
   return false;
}

double CalcPositionTotalPnL(long positionId, bool needSelect = true) {
   double total = 0;
   if(needSelect) HistorySelect(0, TimeCurrent());
   for(int i = HistoryDealsTotal()-1; i >= 0; i--) {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      if(HistoryDealGetInteger(tk, DEAL_POSITION_ID) != positionId) continue;
      if(HistoryDealGetInteger(tk, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetInteger(tk, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      total += HistoryDealGetDouble(tk, DEAL_PROFIT)
             + HistoryDealGetDouble(tk, DEAL_SWAP)
             + HistoryDealGetDouble(tk, DEAL_COMMISSION);
   }
   return total;
}

void UpdateEquityCurveFilter() {
   int wins = 0, total = 0;
   long visitedIds[];
   int visitedCount = 0;
   HistorySelect(0, TimeCurrent());
   for(int i = HistoryDealsTotal()-1; i >= 0 && total < InpECFWindow; i--) {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      if(HistoryDealGetInteger(tk, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetString(tk, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(tk, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      long posId = HistoryDealGetInteger(tk, DEAL_POSITION_ID);
      bool already = false;
      for(int j = 0; j < visitedCount; j++)
         if(visitedIds[j] == posId) { already = true; break; }
      if(already) continue;
      ArrayResize(visitedIds, visitedCount + 1);
      visitedIds[visitedCount++] = posId;
      double pnl = CalcPositionTotalPnL(posId, false);
      total++;
      if(pnl > 0) wins++;
   }
   g_winRate = (total > 0) ? ((double)wins / total * 100.0) : 100.0;
   if(total >= InpECFWindow && g_winRate < InpECFMinWinRate && !g_isPaused) {
      g_isPaused = true;
      g_pauseBarsLeft = InpECFPauseBars;
      PrintFormat("[GP] ECF paused: WR=%.1f%%", g_winRate);
   }
}

void OnPositionClosed(double totalProfit) {
   if(totalProfit > 0) {
      g_consecutiveLosses = 0;
      if(g_isPaused) {
         g_isPaused = false;
         g_pauseBarsLeft = 0;
         Print("[GP] Re-enabled after win.");
      }
   } else {
      g_consecutiveLosses++;
      if(g_consecutiveLosses >= InpConsecLossPause) {
         g_isPaused = true;
         g_pauseBarsLeft = InpConsecLossPauseBars;
         PrintFormat("[GP] Paused: %d consecutive losses", g_consecutiveLosses);
      }
   }
   UpdateEquityCurveFilter();
}

void ProcessDeals() {
   datetime now = TimeCurrent();
   if(now - g_lastDealCheck < 5) return;
   g_lastDealCheck = now;
   HistorySelect(0, now);
   for(int i = 0; i < HistoryDealsTotal(); i++) {
      ulong tk = HistoryDealGetTicket(i);
      if(tk <= g_lastDealTicket) continue;
      if(HistoryDealGetInteger(tk, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      if(HistoryDealGetString(tk, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(tk, DEAL_MAGIC) != InpMagic) continue;
      double dealPnl = HistoryDealGetDouble(tk, DEAL_PROFIT)
                     + HistoryDealGetDouble(tk, DEAL_SWAP)
                     + HistoryDealGetDouble(tk, DEAL_COMMISSION);
      g_daily.realizedPnL += dealPnl;
      g_lastDealTicket = tk;
      long posId = HistoryDealGetInteger(tk, DEAL_POSITION_ID);
      if(IsPositionStillOpen(posId)) {
         PrintFormat("[GP] Partial deal=%.2f (pos #%lld still open)", dealPnl, posId);
         continue;
      }
      double totalPnl = CalcPositionTotalPnL(posId, false);
      OnPositionClosed(totalPnl);
      PrintFormat("[GP] Closed posPnL=%.2f (deal=%.2f)", totalPnl, dealPnl);
   }
}

//=====================================================================
// SECTION 13: MAIN EA LIFECYCLE
//=====================================================================
int OnInit() {
   if(!InitIndicators()) {
      Print("[GP] Indicator init failed.");
      return INIT_FAILED;
   }
   g_trade.SetDeviationInPoints(SLIPPAGE);
   g_trade.SetTypeFilling(DetectFilling());
   InitDailyStats();
   InitVolatilityState();
   HistorySelect(0, TimeCurrent());
   int totalDeals = HistoryDealsTotal();
   if(totalDeals > 0) g_lastDealTicket = HistoryDealGetTicket(totalDeals - 1);
   UpdateEquityCurveFilter();
   PrintFormat("[GP] v4.0 Started. Magic=%d Risk=%.1f%% EMA=%d/%d MinRR=%.1f TP1=%.1fR",
              InpMagic, InpRiskPercent, InpEMA_Fast, InpEMA_Slow, InpMinRR, InpTP1_RR);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   ReleaseIndicators();
   Print("[GP] Stopped.");
}

void OnTick() {
   if(g_daily.isTotalLocked) return;
   if(g_firstTick) {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      PrintFormat("[GP] FIRST TICK: server=%s h=%d dow=%d",
                 TimeToString(TimeCurrent()), dt.hour, dt.day_of_week);
      g_firstTick = false;
   }
   double atr = Ind(g_hM5ATR, 0, 1);
   CheckFlashCrash(atr);
   ManagePositions(atr);
   ProcessDeals();
   if(!IsNewBarM5()) return;
   CleanPositionTimeTracker();
   CleanTracker();
   CheckDailyReset();
   UpdateVolatilityState();
   ENUM_SHIELD_LEVEL shield = UpdateEquityShield();
   if(shield == SHIELD_RED) {
      ForceCloseAll("RedShield");
      g_daily.isDayLocked = true;
      return;
   }
   if(g_daily.isDayLocked) return;
   HandleStormMode();
   CheckGapGuard(atr);
   CheckTimeGuard();
   if(g_cooldownBars > 0) g_cooldownBars--;
   if(g_pauseBarsLeft > 0) {
      g_pauseBarsLeft--;
      if(g_pauseBarsLeft <= 0) {
         g_isPaused = false;
         Print("[GP] Pause expired, re-enabled.");
      }
   }
   ENUM_SESSION ses = GetSession();
   if(ses == SESSION_CLOSED) {
      if(InpCloseBeforeWeekend) ForceCloseAll("Weekend");
      return;
   }
   if(!IsSpreadOK(atr)) return;
   if(shield == SHIELD_ORANGE) return;
   if(g_vol.isStormActive) return;
   if(g_vol.gapPauseBars > 0) return;
   ENUM_TREND_BIAS bias = GetH1TrendBias();
   double emaF = Ind(g_hH1EMAFast, 0, 1);
   double emaS = Ind(g_hH1EMASlow, 0, 1);
   PrintFormat("[GP] BAR: ses=%d atr=%.2f bias=%d ema21=%.1f ema50=%.1f shield=%d pos=%d",
              (int)ses, atr, (int)bias, emaF, emaS, (int)shield, CountPositions());
   SignalResult sig = CheckSignal(bias);
   if(sig.direction == DIR_NONE) return;
   if(sig.direction == DIR_SELL && !InpAllowShort) return;
   if(!CanOpen(ses, sig.direction)) return;
   double price = (sig.direction == DIR_BUY)
      ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slDist = MathAbs(price - sig.sl);
   double lots = CalcLots(slDist, ses);
   if(lots <= 0) return;
   PrintFormat("[GP] SIGNAL: %s sl=%.2f tp=%.2f lots=%.2f RR=%.1f [%s]",
              (sig.direction == DIR_BUY) ? "BUY" : "SELL", sig.sl, sig.tp, lots,
              MathAbs(sig.tp - price) / slDist, sig.reason);
   bool ok = false;
   if(sig.direction == DIR_BUY)  ok = OpenBuy(sig.sl, lots, sig.reason);
   if(sig.direction == DIR_SELL) ok = OpenSell(sig.sl, lots, sig.reason);
   if(ok) g_cooldownBars = InpCooldownBars;
}

void OnTrade() { ProcessDeals(); }
//+------------------------------------------------------------------+
