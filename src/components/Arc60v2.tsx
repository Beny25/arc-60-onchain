import { useCallback, useEffect, useRef, useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { TrendingUp, TrendingDown, Minus, RefreshCw, ChevronUp, ChevronDown } from 'lucide-react';

// ─── Constants ────────────────────────────────────────────────────────────────
const ROUND_DURATION = 60; // seconds
const SETTLE_DURATION = 4; // seconds to show result before next round
const BTC_BASE = 62_400;
const TICK_INTERVAL_MS = 3000; // poll Binance price every 3 s
const BINANCE_PRICE_URL = 'https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT';
const VIRTUAL_BALANCE_START = 500; // USDC
const DEFAULT_BET = 10; // USDC

// ─── Types ────────────────────────────────────────────────────────────────────
type Direction = 'UP' | 'DOWN';
type MarketStatus = 'live' | 'settling' | 'stopped';
type RoundResult = 'UP' | 'DOWN' | 'TIE';

interface Prediction {
  direction: Direction;
  amount: number;
}

interface SettlementInfo {
  openPrice: number;
  closePrice: number;
  result: RoundResult;
  userPrediction: Prediction | null;
  userWon: boolean | null; // null = tie / no bet
  payout: number;
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

function fmtPrice(n: number) {
  return n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function fmtUsdc(n: number) {
  return n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

// Glass surface tokens
const glass = {
  card: {
    background: 'rgba(255,255,255,0.70)',
    backdropFilter: 'blur(24px) saturate(180%)',
    WebkitBackdropFilter: 'blur(24px) saturate(180%)',
    border: '1px solid rgba(255,255,255,0.72)',
    boxShadow: '0 8px 32px rgba(18,45,69,0.09), inset 0 1px 0 rgba(255,255,255,0.55)',
  } as React.CSSProperties,
  inner: {
    background: 'rgba(255,255,255,0.48)',
    border: '1px solid rgba(255,255,255,0.58)',
  } as React.CSSProperties,
};

const springs = {
  snappy: { type: 'spring', stiffness: 420, damping: 32 } as const,
  gentle: { type: 'spring', stiffness: 300, damping: 26 } as const,
};

// ─── Component ────────────────────────────────────────────────────────────────
export default function Arc60v2() {
  // Market state
  const [status, setStatus] = useState<MarketStatus>('stopped');
  const [round, setRound] = useState(0);
  const [timeLeft, setTimeLeft] = useState(ROUND_DURATION);
  const [btcPrice, setBtcPrice] = useState(BTC_BASE);
  const [openPrice, setOpenPrice] = useState(BTC_BASE);
  const [priceLoaded, setPriceLoaded] = useState(false);
  const [priceDir, setPriceDir] = useState<'up' | 'down' | 'flat'>('flat');

  // Pools
  const [poolUp, setPoolUp] = useState(240);
  const [poolDown, setPoolDown] = useState(180);

  // User
  const [balance, setBalance] = useState(VIRTUAL_BALANCE_START);
  const [prediction, setPrediction] = useState<Prediction | null>(null);
  const [betAmount, setBetAmount] = useState(DEFAULT_BET);
  const [betInput, setBetInput] = useState(String(DEFAULT_BET));

  // Settlement
  const [settlement, setSettlement] = useState<SettlementInfo | null>(null);
  const [settleCountdown, setSettleCountdown] = useState(SETTLE_DURATION);

  // Refs for intervals
  const tickRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const roundRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const settleRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const priceRef = useRef(BTC_BASE);
  const openPriceRef = useRef(BTC_BASE);
  const roundRef2 = useRef(0); // track round number without stale closures
  const statusRef = useRef<MarketStatus>('stopped');

useEffect(() => {
  statusRef.current = status;
}, [status]);

  // ── Price ticker ──────────────────────────────────────────────────────────
  const startPriceTicker = useCallback(() => {
    if (tickRef.current) clearInterval(tickRef.current);

    const fetchPrice = async () => {
      try {
        const response = await fetch(BINANCE_PRICE_URL);
        if (!response.ok) throw new Error('Binance API request failed');

        const data: { price: string } = await response.json();
        const next = Number(data.price);

        if (!Number.isFinite(next) || next <= 0) {
          throw new Error('Invalid BTC price');
        }

        const dir =
          next > priceRef.current ? 'up' :
          next < priceRef.current ? 'down' : 'flat';

        priceRef.current = next;
        setBtcPrice(next);
        setPriceLoaded(true);
        setPriceDir(dir);
      } catch (error) {
        console.error('Failed to fetch Binance BTC price:', error);
      }
    };

    void fetchPrice();
    tickRef.current = setInterval(() => {
      void fetchPrice();
    }, TICK_INTERVAL_MS);
  }, []);

  const stopPriceTicker = useCallback(() => {
    if (tickRef.current) { clearInterval(tickRef.current); tickRef.current = null; }
  }, []);

  useEffect(() => {
    startPriceTicker();
    return () => stopPriceTicker();
  }, [startPriceTicker, stopPriceTicker]);

  // ── Settlement ────────────────────────────────────────────────────────────
  const settleRound = useCallback((close: number, open: number, pred: Prediction | null, pUp: number, pDown: number) => {
    const result: RoundResult = close > open ? 'UP' : close < open ? 'DOWN' : 'TIE';
    let userWon: boolean | null = null;
    let payout = 0;

    if (pred) {
      if (result === 'TIE') {
        userWon = null; // refund
        payout = pred.amount;
      } else {
        userWon = pred.direction === result;
        if (userWon) {
          const total = pUp + pDown;
          const winPool = result === 'UP' ? pUp : pDown;
          payout = winPool > 0 ? (pred.amount / winPool) * total * 0.95 : pred.amount;
        }
      }
      setBalance((b) => parseFloat((b + payout).toFixed(2)));
    }

    setSettlement({ openPrice: open, closePrice: close, result, userPrediction: pred, userWon, payout });
  }, []);

  // ── Start next round ──────────────────────────────────────────────────────
  const startRound = useCallback((roundNum: number) => {
    roundRef2.current = roundNum;
    setRound(roundNum);
    setTimeLeft(ROUND_DURATION);
    setPrediction(null);
    setSettlement(null);
    setStatus('live');

    // Snapshot open price
    openPriceRef.current = priceRef.current;
    setOpenPrice(priceRef.current);

    // Seed pools with some simulated liquidity each round
    setPoolUp(Math.round(180 + Math.random() * 120));
    setPoolDown(Math.round(160 + Math.random() * 140));

    // Round countdown
    if (roundRef.current) clearInterval(roundRef.current);
    let t = ROUND_DURATION;
    roundRef.current = setInterval(() => {
      t -= 1;
      setTimeLeft(t);
      if (t <= 0) {
        clearInterval(roundRef.current!);
        roundRef.current = null;
        setStatus('settling');
      }
    }, 1000);
  }, []);

  // Watch for settling status → run settlement logic once
  // We use a separate effect so we can read latest state
  const predictionRef = useRef<Prediction | null>(null);
  const poolUpRef = useRef(240);
  const poolDownRef = useRef(180);

  // Keep refs in sync
  useEffect(() => { predictionRef.current = prediction; }, [prediction]);
  useEffect(() => { poolUpRef.current = poolUp; }, [poolUp]);
  useEffect(() => { poolDownRef.current = poolDown; }, [poolDown]);

  useEffect(() => {
    if (status !== 'settling') return;

    const close = priceRef.current;
    settleRound(close, openPriceRef.current, predictionRef.current, poolUpRef.current, poolDownRef.current);

    setSettleCountdown(SETTLE_DURATION);
    let s = SETTLE_DURATION;
    settleRef.current = setInterval(() => {
      s -= 1;
      setSettleCountdown(s);

if (s <= 0) {
  clearInterval(settleRef.current!);
  settleRef.current = null;

  if (statusRef.current === 'settling') {
    startRound(roundRef2.current + 1);
  }
}

    }, 1000);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [status]);

  // ── Start market ──────────────────────────────────────────────────────────
  const startMarket = useCallback(() => {
    statusRef.current = 'live';

    setBalance(VIRTUAL_BALANCE_START);
    setBetAmount(DEFAULT_BET);
    setBetInput(String(DEFAULT_BET));
    startPriceTicker();
    startRound(1);
  }, [startPriceTicker, startRound]);

  // ── Stop market ───────────────────────────────────────────────────────────
  const stopMarket = useCallback(() => {
  statusRef.current = 'stopped';
    if (roundRef.current) { clearInterval(roundRef.current); roundRef.current = null; }
    if (settleRef.current) { clearInterval(settleRef.current); settleRef.current = null; }
    setStatus('stopped');
    setSettlement(null);
    setPrediction(null);
    setRound(0);
    setTimeLeft(ROUND_DURATION);
    setBalance(VIRTUAL_BALANCE_START);
    setPoolUp(240);
    setPoolDown(180);
    setPriceDir('flat');
  }, []);

  // Cleanup on unmount
  useEffect(() => () => {
    stopPriceTicker();
    if (roundRef.current) clearInterval(roundRef.current);
    if (settleRef.current) clearInterval(settleRef.current);
  }, [stopPriceTicker]);

  // ── Place prediction ──────────────────────────────────────────────────────
  const placePrediction = useCallback((dir: Direction) => {
    if (status !== 'live' || prediction !== null) return;
    const amt = Math.min(Math.max(betAmount, 1), balance);
    if (amt > balance) return;
    setBalance((b) => parseFloat((b - amt).toFixed(2)));
    setPrediction({ direction: dir, amount: amt });
    if (dir === 'UP') setPoolUp((p) => p + amt);
    else setPoolDown((p) => p + amt);
  }, [status, prediction, betAmount, balance]);

  // ── Bet input ─────────────────────────────────────────────────────────────
  const handleBetInput = (v: string) => {
    setBetInput(v);
    const n = parseFloat(v);
    if (!isNaN(n) && n > 0) setBetAmount(n);
  };

  // ── Derived ───────────────────────────────────────────────────────────────
  const progress = status === 'live' ? (ROUND_DURATION - timeLeft) / ROUND_DURATION : status === 'settling' ? 1 : 0;
  const radius = 80;
  const circ = 2 * Math.PI * radius;
  const priceDelta = btcPrice - openPrice;
  const priceDeltaPct = openPrice > 0 ? (priceDelta / openPrice) * 100 : 0;
  const totalPool = poolUp + poolDown;
  const upPct = totalPool > 0 ? (poolUp / totalPool) * 100 : 50;
  const downPct = 100 - upPct;

  const resultColor = (r: RoundResult) =>
    r === 'UP' ? 'var(--success)' : r === 'DOWN' ? 'var(--danger)' : 'var(--muted)';

  return (
    <div
      className="relative min-h-dvh overflow-hidden"
      style={{ background: 'linear-gradient(180deg, #f9f9fc 0%, #fffcf7 52%, #fbf7f2 100%)' }}
    >
      {/* Background blobs */}
      <div className="fixed inset-0 pointer-events-none overflow-hidden">
        <div style={{ position: 'absolute', top: '6%', left: '4%', width: 280, height: 280, borderRadius: '50%', background: 'radial-gradient(circle, rgba(133,177,237,0.20) 0%, transparent 70%)', filter: 'blur(60px)' }} />
        <div style={{ position: 'absolute', bottom: '6%', right: '6%', width: 260, height: 260, borderRadius: '50%', background: 'radial-gradient(circle, rgba(255,205,131,0.18) 0%, transparent 70%)', filter: 'blur(58px)' }} />
      </div>

      <div className="relative z-10 mx-auto max-w-md px-4 pb-10 pt-6">

        {/* ── Header ─────────────────────────────────────────────────────── */}
        <header className="mb-5 flex items-center justify-between">
          <div>
            <p className="text-xs font-semibold uppercase" style={{ color: 'var(--muted)', letterSpacing: '0.1em' }}>
              Simulated Market
            </p>
            <h1 className="display text-xl font-bold" style={{ color: 'var(--ink)', fontWeight: 700 }}>
              ARC 60 v2
            </h1>
          </div>
          <div className="flex items-center gap-2">
            {status !== 'stopped' && (
              <span
                className="flex items-center gap-1.5 rounded-full px-3 py-1 text-xs font-semibold"
                style={{ background: 'rgba(26,128,71,0.12)', color: 'var(--success)' }}
              >
                <span className="inline-block h-1.5 w-1.5 rounded-full" style={{ background: 'var(--success)' }} />
                LIVE
              </span>
            )}
            {status === 'stopped' ? (
              <button
                onClick={startMarket}
                className="rounded-2xl px-4 py-2 text-xs font-semibold transition-all"
                style={{ background: 'var(--accent)', color: '#fff', border: 'none', cursor: 'pointer', height: 34 }}
              >
                Start Market
              </button>
            ) : (
              <button
                onClick={stopMarket}
                className="rounded-2xl px-3 py-2 text-xs font-semibold transition-all"
                style={{ background: 'var(--surface-muted)', color: 'var(--muted)', border: '1px solid var(--border)', cursor: 'pointer', height: 34 }}
              >
                Stop
              </button>
            )}
          </div>
        </header>

        {/* ── Simulated notice ───────────────────────────────────────────── */}
        <div
          className="mb-4 rounded-2xl px-4 py-2.5 text-xs text-center font-medium"
          style={{ background: 'rgba(139,132,156,0.10)', color: 'var(--muted)', border: '1px solid var(--border)' }}
        >
          This is a simulated prototype. No real funds or blockchain transactions.
        </div>

        {/* ── BTC Price card ─────────────────────────────────────────────── */}
        <motion.div
          className="rounded-3xl p-5 mb-3"
          style={glass.card}
          initial={{ opacity: 0, y: 16 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.4, ease: [0.25, 0.1, 0.25, 1] }}
        >
          <div className="flex items-start justify-between">
            <div>
              <p className="text-xs font-semibold uppercase mb-1" style={{ color: 'var(--muted)', letterSpacing: '0.08em' }}>
                BTC / USDC
              </p>
              <AnimatePresence mode="wait">
                <motion.p
                  key={Math.floor(btcPrice)}
                  initial={{ y: priceDir === 'up' ? -6 : priceDir === 'down' ? 6 : 0, opacity: 0.4 }}
                  animate={{ y: 0, opacity: 1 }}
                  transition={springs.snappy}
                  className="display font-bold tabular-nums"
                  style={{ fontSize: 34, lineHeight: 1, color: 'var(--ink)', letterSpacing: '-0.03em' }}
                >
                  {priceLoaded ? `$${fmtPrice(btcPrice)}` : 'Loading BTC price…'}
                </motion.p>
              </AnimatePresence>

<div className="flex items-center gap-1.5 mt-1">
{priceLoaded && status !== 'stopped' ? (
    <>
      {priceDelta !== 0 && (
        priceDelta > 0
          ? <ChevronUp size={13} style={{ color: 'var(--success)' }} />
          : <ChevronDown size={13} style={{ color: 'var(--danger)' }} />
      )}
      <span
        className="text-xs font-semibold tabular-nums"
        style={{ color: priceDelta > 0 ? 'var(--success)' : priceDelta < 0 ? 'var(--danger)' : 'var(--muted)' }}
      >
        {priceDelta >= 0 ? '+' : ''}{fmtPrice(priceDelta)} ({priceDeltaPct >= 0 ? '+' : ''}{priceDeltaPct.toFixed(3)}%)
      </span>
      <span className="text-xs" style={{ color: 'var(--subtle)' }}>this round</span>
    </>
  ) : (
    <span className="text-xs" style={{ color: 'var(--muted)' }}>
{!priceLoaded ? 'Waiting for Binance price…' : 'Start market to track change'}
    </span>
  )}
</div>

            </div>

            {/* Round ring */}
            <div className="flex flex-col items-center">
              <div style={{ position: 'relative', width: 76, height: 76 }}>
                <svg width={76} height={76} viewBox="0 0 180 180" style={{ transform: 'rotate(-90deg)', position: 'absolute', inset: 0 }}>
                  <circle cx={90} cy={90} r={radius} fill="none" stroke="var(--border)" strokeWidth={10} />
                  <motion.circle
                    cx={90} cy={90} r={radius}
                    fill="none"
                    stroke={status === 'settling' ? 'var(--muted)' : 'var(--accent)'}
                    strokeWidth={10}
                    strokeLinecap="round"
                    strokeDasharray={circ}
                    strokeDashoffset={circ * (1 - progress)}
                    style={{ transition: 'stroke-dashoffset 0.85s linear' }}
                  />
                </svg>
                <div style={{ position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center' }}>
                  <span className="display font-bold tabular-nums" style={{ fontSize: 18, fontWeight: 700, color: status === 'settling' ? 'var(--muted)' : 'var(--ink)', lineHeight: 1, letterSpacing: '-0.02em' }}>
                    {status === 'settling' ? settleCountdown : status === 'live' ? timeLeft : '—'}
                  </span>
                  <span className="text-[9px] font-medium" style={{ color: 'var(--subtle)', marginTop: 1 }}>
                    {status === 'settling' ? 'settle' : 'sec'}
                  </span>
                </div>
              </div>
              <p className="text-[10px] font-semibold mt-1 tabular-nums" style={{ color: 'var(--muted)' }}>
                {round > 0 ? `Round ${round}` : '—'}
              </p>
            </div>
          </div>

          {/* Pool bar */}
          {status !== 'stopped' && (
            <div className="mt-4">
              <div className="flex justify-between text-[10px] font-semibold mb-1.5" style={{ color: 'var(--muted)' }}>
                <span style={{ color: 'var(--success)' }}>UP ${fmtUsdc(poolUp)}</span>
                <span style={{ color: 'var(--danger)' }}>DOWN ${fmtUsdc(poolDown)}</span>
              </div>
              <div className="w-full rounded-full overflow-hidden flex" style={{ height: 6, background: 'var(--border)' }}>
                <motion.div
                  className="rounded-l-full"
                  style={{ height: '100%', background: 'var(--success)' }}
                  animate={{ width: `${upPct}%` }}
                  transition={{ duration: 0.6, ease: 'easeOut' }}
                />
                <motion.div
                  className="rounded-r-full"
                  style={{ height: '100%', background: 'var(--danger)' }}
                  animate={{ width: `${downPct}%` }}
                  transition={{ duration: 0.6, ease: 'easeOut' }}
                />
              </div>
              <div className="flex justify-between text-[10px] mt-1" style={{ color: 'var(--subtle)' }}>
                <span>{upPct.toFixed(0)}%</span>
                <span>Total pool: ${fmtUsdc(totalPool)}</span>
                <span>{downPct.toFixed(0)}%</span>
              </div>
            </div>
          )}
        </motion.div>

        {/* ── Settlement result ──────────────────────────────────────────── */}
        <AnimatePresence>
          {settlement && (
            <motion.div
              key="settlement"
              initial={{ opacity: 0, scale: 0.96, y: 8 }}
              animate={{ opacity: 1, scale: 1, y: 0 }}
              exit={{ opacity: 0, scale: 0.96, y: 8 }}
              transition={springs.gentle}
              className="rounded-3xl p-5 mb-3 text-center"
              style={{
                ...glass.card,
                border: `1px solid ${resultColor(settlement.result)}40`,
              }}
            >
              <div className="flex items-center justify-center gap-2 mb-2">
                {settlement.result === 'UP' && <TrendingUp size={18} style={{ color: 'var(--success)' }} />}
                {settlement.result === 'DOWN' && <TrendingDown size={18} style={{ color: 'var(--danger)' }} />}
                {settlement.result === 'TIE' && <Minus size={18} style={{ color: 'var(--muted)' }} />}
                <span className="display font-bold text-base" style={{ color: resultColor(settlement.result), fontWeight: 700 }}>
                  {settlement.result === 'TIE' ? 'Round Tied' : `${settlement.result} wins`}
                </span>
              </div>
              <div className="flex justify-center gap-6 text-xs mb-3" style={{ color: 'var(--muted)' }}>
                <span>Open <span className="tabular-nums font-semibold" style={{ color: 'var(--ink)' }}>${fmtPrice(settlement.openPrice)}</span></span>
                <span>Close <span className="tabular-nums font-semibold" style={{ color: 'var(--ink)' }}>${fmtPrice(settlement.closePrice)}</span></span>
              </div>
              {settlement.userPrediction ? (
                <div
                  className="rounded-2xl px-4 py-2.5 inline-flex flex-col items-center gap-0.5"
                  style={{
                    ...glass.inner,
                    borderColor: settlement.userWon === true ? 'rgba(26,128,71,0.3)' : settlement.userWon === false ? 'rgba(186,43,76,0.3)' : 'rgba(107,101,128,0.25)',
                  }}
                >
                  {settlement.userWon === true && (
                    <span className="text-xs font-bold" style={{ color: 'var(--success)' }}>
                      You won +${fmtUsdc(settlement.payout)} USDC
                    </span>
                  )}
                  {settlement.userWon === false && (
                    <span className="text-xs font-bold" style={{ color: 'var(--danger)' }}>
                      You lost ${fmtUsdc(settlement.userPrediction.amount)} USDC
                    </span>
                  )}
                  {settlement.userWon === null && settlement.userPrediction && (
                    <span className="text-xs font-bold" style={{ color: 'var(--muted)' }}>
                      Tie — refunded ${fmtUsdc(settlement.payout)} USDC
                    </span>
                  )}
                  <span className="text-[10px]" style={{ color: 'var(--subtle)' }}>
                    Your call: {settlement.userPrediction.direction} · ${fmtUsdc(settlement.userPrediction.amount)}
                  </span>
                </div>
              ) : (
                <p className="text-xs" style={{ color: 'var(--subtle)' }}>No prediction placed this round</p>
              )}
              <p className="text-[10px] mt-3" style={{ color: 'var(--subtle)' }}>
                Next round in {settleCountdown}s…
              </p>
            </motion.div>
          )}
        </AnimatePresence>

        {/* ── Prediction card ────────────────────────────────────────────── */}
        <motion.div
          className="rounded-3xl p-5 mb-3"
          style={glass.card}
          initial={{ opacity: 0, y: 16 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.4, delay: 0.1, ease: [0.25, 0.1, 0.25, 1] }}
        >
          <p className="text-xs font-semibold uppercase mb-3" style={{ color: 'var(--muted)', letterSpacing: '0.08em' }}>
            Your Prediction
          </p>

          {/* Balance */}
          <div className="flex items-center justify-between mb-4">
            <span className="text-sm" style={{ color: 'var(--ink-2)' }}>Virtual USDC balance</span>
            <span className="display font-bold tabular-nums text-sm" style={{ color: 'var(--ink)', fontWeight: 700 }}>
              ${fmtUsdc(balance)}
            </span>
          </div>

          {/* Bet input */}
          <div className="mb-4">
            <label className="block text-xs font-medium mb-1.5" style={{ color: 'var(--muted)' }}>
              Bet amount (USDC)
            </label>
            <div className="flex gap-2">
              <input
                type="number"
                min={1}
                max={balance}
                value={betInput}
                onChange={(e) => handleBetInput(e.target.value)}
                disabled={status !== 'live' || prediction !== null}
                className="flex-1 rounded-2xl px-4 text-sm font-semibold tabular-nums outline-none transition-all"
                style={{
                  ...glass.inner,
                  height: 44,
                  color: 'var(--ink)',
                  opacity: status !== 'live' || prediction !== null ? 0.5 : 1,
                }}
              />
              {[10, 25, 50].map((v) => (
                <button
                  key={v}
                  onClick={() => { handleBetInput(String(v)); }}
                  disabled={status !== 'live' || prediction !== null || v > balance}
                  className="rounded-2xl text-xs font-semibold transition-all"
                  style={{
                    height: 44,
                    width: 44,
                    background: betAmount === v ? 'var(--accent)' : 'var(--surface-muted)',
                    color: betAmount === v ? '#fff' : 'var(--ink-2)',
                    border: '1px solid var(--border)',
                    cursor: status !== 'live' || prediction !== null || v > balance ? 'not-allowed' : 'pointer',
                    opacity: v > balance ? 0.4 : 1,
                  }}
                >
                  {v}
                </button>
              ))}
            </div>
          </div>

          {/* UP / DOWN buttons */}
          {prediction === null ? (
            <div className="flex gap-3">
              <motion.button
                onClick={() => placePrediction('UP')}
                disabled={status !== 'live'}
                whileTap={{ scale: status === 'live' ? 0.97 : 1 }}
                className="flex-1 flex items-center justify-center gap-2 rounded-2xl font-bold text-sm transition-all"
                style={{
                  height: 52,
                  background: status === 'live' ? 'var(--success)' : 'var(--surface-muted)',
                  color: status === 'live' ? '#fff' : 'var(--subtle)',
                  border: 'none',
                  cursor: status === 'live' ? 'pointer' : 'not-allowed',
                  opacity: status !== 'live' ? 0.5 : 1,
                }}
              >
                <TrendingUp size={16} strokeWidth={2.5} />
                UP
              </motion.button>
              <motion.button
                onClick={() => placePrediction('DOWN')}
                disabled={status !== 'live'}
                whileTap={{ scale: status === 'live' ? 0.97 : 1 }}
                className="flex-1 flex items-center justify-center gap-2 rounded-2xl font-bold text-sm transition-all"
                style={{
                  height: 52,
                  background: status === 'live' ? 'var(--danger)' : 'var(--surface-muted)',
                  color: status === 'live' ? '#fff' : 'var(--subtle)',
                  border: 'none',
                  cursor: status === 'live' ? 'pointer' : 'not-allowed',
                  opacity: status !== 'live' ? 0.5 : 1,
                }}
              >
                <TrendingDown size={16} strokeWidth={2.5} />
                DOWN
              </motion.button>
            </div>
          ) : (
            <motion.div
              initial={{ opacity: 0, scale: 0.96 }}
              animate={{ opacity: 1, scale: 1 }}
              transition={springs.snappy}
              className="rounded-2xl flex items-center justify-between px-4"
              style={{
                height: 52,
                background: prediction.direction === 'UP' ? 'rgba(26,128,71,0.10)' : 'rgba(186,43,76,0.10)',
                border: `1px solid ${prediction.direction === 'UP' ? 'rgba(26,128,71,0.30)' : 'rgba(186,43,76,0.30)'}`,
              }}
            >
              <div className="flex items-center gap-2">
                {prediction.direction === 'UP'
                  ? <TrendingUp size={16} style={{ color: 'var(--success)' }} />
                  : <TrendingDown size={16} style={{ color: 'var(--danger)' }} />}
                <span className="text-sm font-bold" style={{ color: prediction.direction === 'UP' ? 'var(--success)' : 'var(--danger)' }}>
                  {prediction.direction} locked in
                </span>
              </div>
              <span className="text-sm font-semibold tabular-nums" style={{ color: 'var(--ink-2)' }}>
                ${fmtUsdc(prediction.amount)}
              </span>
            </motion.div>
          )}

          {status === 'stopped' && (
            <p className="text-center text-xs mt-3" style={{ color: 'var(--subtle)' }}>
              Start the market to place predictions
            </p>
          )}
          {status === 'settling' && prediction === null && (
            <p className="text-center text-xs mt-3" style={{ color: 'var(--subtle)' }}>
              Round settling — next round starts soon
            </p>
          )}
        </motion.div>

        {/* ── How it works ───────────────────────────────────────────────── */}
        <motion.div
          className="rounded-3xl px-5 py-4"
          style={{ ...glass.inner, border: '1px solid var(--border)' }}
          initial={{ opacity: 0, y: 12 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.4, delay: 0.2 }}
        >
          <p className="text-xs font-semibold uppercase mb-2" style={{ color: 'var(--muted)', letterSpacing: '0.08em' }}>
            How it works
          </p>
          <ul className="space-y-1.5">
            {[
              'Each round lasts 60 seconds.',
              'Predict UP or DOWN before the round ends.',
              'BTC price is compared at open vs. close.',
              'Winners share the losing pool (5% fee simulated).',
              'Rounds run continuously — no operator needed.',
              'Ties refund all bets for that round.',
            ].map((line) => (
              <li key={line} className="flex items-start gap-2 text-xs" style={{ color: 'var(--muted)' }}>
                <RefreshCw size={10} strokeWidth={2} className="mt-0.5 shrink-0" style={{ color: 'var(--subtle)' }} />
                {line}
              </li>
            ))}
          </ul>
        </motion.div>

      </div>
    </div>
  );
}
