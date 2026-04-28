//+------------------------------------------------------------------+
//| GoldRangeScalp_EA.mq5 v1.02                                       |
//|                                                                   |
//| v1.02 更新：                                                       |
//|  - 双重硬底保护：每单开仓时把 SL 设到 InpHardLow                   |
//|    （broker 端持久化保护，断网/EA 重启都不影响）                    |
//|  - 自动遵守 broker 最小止损距离，过近时退化为仅靠 OnTick 兜底       |
//|                                                                   |
//| v1.01 更新：                                                       |
//|  - 新增「硬底安全缓冲区」InpHardLowSafetyBuf（默认 30 USD）        |
//|    距 HardLow 此距离内不开新仓，避免在硬底附近开仓被全平连累       |
//|                                                                   |
//| 设计思路（参考 GoldScalp + 区间感知）：                            |
//|  - 沿用 GoldScalp 的高频低单 buy-only 思路                         |
//|  - 利用用户提供的区间结构做"分层加密"：越便宜越多买                |
//|  - 区间硬下沿（4500）作为天然 SL：突破即全平 + 暂停                |
//|                                                                   |
//| 区间结构（XAUUSD）：                                               |
//|   HardLow 4500  ──── 折扣区 ──── InnerLow 4650                     |
//|   InnerLow 4650 ──── 内核区 ──── InnerHigh 4750                    |
//|   InnerHigh 4750 ── （暂停开新仓）── HardHigh 4900                  |
//|                                                                   |
//| 入场规则（buy-only）：                                             |
//|   Ask > InnerHigh        → 暂停                                    |
//|   InnerLow ≤ Ask ≤ InnerHigh → 标准频率（每 M1 1 单）              |
//|   HardLow ≤ Ask < InnerLow   → 折扣区：双倍仓位 + 双倍频率         |
//|   Ask < HardLow              → 全部平仓 + 暂停                     |
//+------------------------------------------------------------------+
#property copyright "GoldRangeScalp"
#property version   "1.02"

#include <Trade/Trade.mqh>

#define SLIPPAGE 30

//=====================================================================
// INPUT PARAMETERS
//=====================================================================
input group "=== Trade ==="
input int      InpMagic           = 600008;     // Magic Number（避免冲突）
input double   InpLotSize         = 0.01;       // 内核区单笔仓位
input double   InpTP              = 9.2;        // 固定 TP（USD）
input double   InpMaxSpread       = 0.50;

input group "=== Range Structure ==="
input double   InpHardLow         = 4500.0;     // 区间硬下沿（突破触发全平）
input double   InpInnerLow        = 4650.0;     // 内核下沿（折扣区起点）
input double   InpInnerHigh       = 4750.0;     // 内核上沿（停止开仓）
input double   InpHardHigh        = 4900.0;     // 区间硬上沿（仅记录）

input group "=== Core Layer (4650-4750) ==="
input double   InpCoreSpacing     = 1.8;        // 内核区入场间距（USD）
input int      InpCoreMaxPos      = 30;         // 内核区最大持仓数

input group "=== Discount Layer (4500-4650) ==="
input bool     InpDiscountEnable  = true;       // 是否开启折扣区加密
input double   InpDiscountLotMult = 2.0;        // 折扣区仓位倍数
input double   InpDiscountSpacing = 1.0;        // 折扣区入场间距（USD）
input int      InpDiscountAddPos  = 15;         // 折扣区额外允许的持仓数

input group "=== Hard Low Protection ==="
input bool     InpHardLowProtect    = true;     // 突破硬下沿是否全平
input int      InpHardLowHaltMin    = 240;      // 全平后暂停分钟数（4 小时）
input double   InpHardLowSafetyBuf  = 30.0;     // 距硬底多少 USD 内不开新仓（0=禁用）

input group "=== Momentum Filter ==="
input int      InpRSI_Period      = 14;
input double   InpRSI_OB          = 75.0;       // RSI 高于此值不开仓

input group "=== Session ==="
input int      InpStartHour       = 5;
input int      InpEndHour         = 20;

input group "=== Friday Cutoff ==="
input int      InpServerGMT       = 0;          // Server GMT offset（Exness=0）
input int      InpFriCutoffBJ     = 24;         // Friday 北京时间截止小时

//=====================================================================
// GLOBALS
//=====================================================================
CTrade   g_trade;
datetime g_lastBarTime    = 0;
datetime g_haltUntil      = 0;
int      g_hRSI           = INVALID_HANDLE;

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

   int bjHour = dt.hour + (8 - InpServerGMT);
   int bjDow  = dt.day_of_week;
   if(bjHour >= 24) { bjHour -= 24; bjDow = (bjDow + 1) % 7; }
   if(bjHour < 0)   { bjHour += 24; bjDow = (bjDow + 6) % 7; }

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
// 平掉本 EA 所有持仓（硬底突破时调用）
//=====================================================================
int CloseAllOwn()
{
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(g_trade.PositionClose(tk)) closed++;
   }
   return closed;
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
      Print("[GRS] RSI init failed");
      return INIT_FAILED;
   }

   // 参数自检
   if(InpHardLow >= InpInnerLow || InpInnerLow >= InpInnerHigh || InpInnerHigh >= InpHardHigh)
   {
      Print("[GRS] Range params invalid: must be HardLow < InnerLow < InnerHigh < HardHigh");
      return INIT_FAILED;
   }

   PrintFormat("[GRS] GoldRangeScalp v1.02 | Range[%.0f-%.0f-%.0f-%.0f] | CoreLot=%.2f x%d sp=%.1f | Discount=%s x%.1f +%dpos sp=%.1f | TP=%.1f RSI<%.0f | HardLowProtect=%s halt=%dmin SafeBuf=%.0f",
               InpHardLow, InpInnerLow, InpInnerHigh, InpHardHigh,
               InpLotSize, InpCoreMaxPos, InpCoreSpacing,
               (InpDiscountEnable ? "ON" : "OFF"), InpDiscountLotMult, InpDiscountAddPos, InpDiscountSpacing,
               InpTP, InpRSI_OB,
               (InpHardLowProtect ? "ON" : "OFF"), InpHardLowHaltMin, InpHardLowSafetyBuf);
   return INIT_SUCCEEDED;
}

//=====================================================================
void OnDeinit(const int reason)
{
   if(g_hRSI != INVALID_HANDLE) IndicatorRelease(g_hRSI);
   Print("[GRS] Stopped.");
}

//=====================================================================
void OnTick()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // 1) 硬下沿保护：最高优先级，不受 session/spread 影响
   if(InpHardLowProtect && bid < InpHardLow)
   {
      if(CountPositions() > 0)
      {
         int n = CloseAllOwn();
         PrintFormat("[GRS] HARD-LOW BREACH bid=%.3f < %.1f → closed %d positions, halt %d min",
                     bid, InpHardLow, n, InpHardLowHaltMin);
      }
      g_haltUntil = TimeCurrent() + (datetime)InpHardLowHaltMin * 60;
      return;
   }

   // 2) 暂停期内不开新单
   if(TimeCurrent() < g_haltUntil) return;

   // 3) 交易时段
   if(!IsSessionActive()) return;

   // 4) M1 K 线节流（沿用 GoldScalp 的逻辑：每根 K 线最多 1 单）
   datetime curBar = iTime(_Symbol, PERIOD_M1, 0);
   if(curBar == 0 || curBar == g_lastBarTime) return;
   g_lastBarTime = curBar;

   if(!IsSpreadOK()) return;

   // 5) 价格 > 内核高点：暂停开新单（让现有持仓走 TP）
   if(ask > InpInnerHigh) return;

   // 5.5) 硬底安全缓冲：距 HardLow 太近不再加仓（避免拉低均价 + 被全平连累）
   if(InpHardLowSafetyBuf > 0.0 && (ask - InpHardLow) < InpHardLowSafetyBuf) return;

   // 6) 判断当前所在层
   bool inDiscount = (ask < InpInnerLow);
   if(inDiscount && !InpDiscountEnable) return;   // 折扣区未开启时不在该区开仓

   double curSpacing = inDiscount ? InpDiscountSpacing : InpCoreSpacing;
   double curLotMult = inDiscount ? InpDiscountLotMult : 1.0;
   int    curMaxPos  = InpCoreMaxPos + (inDiscount ? InpDiscountAddPos : 0);

   // 7) 持仓数上限
   int posCount = CountPositions();
   if(posCount >= curMaxPos) return;

   // 8) 入场间距
   if(posCount > 0 && NearestEntryDistance() < curSpacing) return;

   // 9) RSI 过滤（避免在已严重超买的尖顶接刀）
   double rsi = Ind(g_hRSI, 1);
   if(rsi >= InpRSI_OB) return;

   // 10) 计算仓位 + TP
   double lots = NormLot(InpLotSize * curLotMult);
   int    dig  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double tp   = (InpTP > 0) ? NormalizeDouble(ask + InpTP, dig) : 0;

   // 11) 硬底 SL：开启 HardLowProtect 时把 SL 设到 InpHardLow（broker 端持久化保护）
   //     若距 InpHardLow 小于 broker 最小止损距离，则退化为不设 SL（OnTick 全平兜底）
   double sl = 0;
   if(InpHardLowProtect && InpHardLow > 0)
   {
      double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      long   stopsLv = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double minDist = (double)stopsLv * point;     // broker 要求的最小止损距离（USD）
      if((bid - InpHardLow) > (minDist + 0.5))      // 留 0.5 USD 安全余量
         sl = NormalizeDouble(InpHardLow, dig);
   }

   string layer = inDiscount ? "DISC" : "CORE";
   if(g_trade.Buy(lots, _Symbol, ask, sl, tp,
                   StringFormat("RScalp_%s_%d", layer, posCount + 1)))
   {
      PrintFormat("[GRS] BUY %.2f @ %.3f SL=%.3f TP=%.3f [%s %d/%d] RSI=%.1f",
                  lots, ask, sl, tp, layer, posCount + 1, curMaxPos, rsi);
   }
   else
   {
      PrintFormat("[GRS] BUY FAIL: %s", g_trade.ResultRetcodeDescription());
   }
}
//+------------------------------------------------------------------+
