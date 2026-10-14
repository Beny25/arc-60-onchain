import { useCallback, useEffect, useRef, useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { Play, RotateCcw, CheckCircle } from 'lucide-react';

const TOTAL = 60;

type Status = 'idle' | 'running' | 'done';

export default function ArcCountdown() {
  const [timeLeft, setTimeLeft] = useState(TOTAL);
  const [status, setStatus] = useState<Status>('idle');
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const clearTick = () => {
    if (intervalRef.current !== null) {
      clearInterval(intervalRef.current);
      intervalRef.current = null;
    }
  };

  const start = useCallback(() => {
    if (status === 'running') return;
    if (timeLeft === 0) return;
    setStatus('running');
    intervalRef.current = setInterval(() => {
      setTimeLeft((prev) => {
        if (prev <= 1) {
          clearInterval(intervalRef.current!);
          intervalRef.current = null;
          setStatus('done');
          return 0;
        }
        return prev - 1;
      });
    }, 1000);
  }, [status, timeLeft]);

  const reset = useCallback(() => {
    clearTick();
    setTimeLeft(TOTAL);
    setStatus('idle');
  }, []);

  useEffect(() => () => clearTick(), []);

  const progress = (TOTAL - timeLeft) / TOTAL; // 0 → 1
  const radius = 88;
  const circumference = 2 * Math.PI * radius;
  const strokeDashoffset = circumference * (1 - progress);

  const mins = String(Math.floor(timeLeft / 60)).padStart(2, '0');
  const secs = String(timeLeft % 60).padStart(2, '0');

  return (
    <div className="min-h-dvh flex flex-col items-center justify-center px-4 py-10">
      {/* Card */}
      <motion.div
        initial={{ opacity: 0, y: 24 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.5, ease: [0.25, 0.46, 0.45, 0.94] }}
        className="w-full max-w-sm rounded-3xl px-8 py-10 flex flex-col items-center gap-8"
        style={{
          background: 'var(--surface-strong)',
          border: '1px solid var(--border)',
          boxShadow: '0 8px 40px rgba(18,45,69,0.10)',
          backdropFilter: 'blur(20px)',
        }}
      >
        {/* Title */}
        <div className="text-center">
          <p
            className="text-xs font-semibold uppercase tracking-widest mb-1"
            style={{ color: 'var(--muted)', letterSpacing: '0.1em' }}
          >
            Arc Studio
          </p>
          <h1
            className="display text-2xl font-700"
            style={{ color: 'var(--ink)', fontWeight: 700 }}
          >
            Arc Countdown
          </h1>
        </div>

        {/* Ring + Timer */}
        <div className="relative flex items-center justify-center" style={{ width: 216, height: 216 }}>
          {/* Background track */}
          <svg
            width={216}
            height={216}
            viewBox="0 0 216 216"
            className="absolute inset-0 rotate-[-90deg]"
            style={{ transform: 'rotate(-90deg)' }}
          >
            <circle
              cx={108}
              cy={108}
              r={radius}
              fill="none"
              stroke="var(--border)"
              strokeWidth={10}
            />
            <motion.circle
              cx={108}
              cy={108}
              r={radius}
              fill="none"
              stroke={status === 'done' ? 'var(--success)' : 'var(--accent)'}
              strokeWidth={10}
              strokeLinecap="round"
              strokeDasharray={circumference}
              strokeDashoffset={strokeDashoffset}
              style={{ transition: 'stroke-dashoffset 0.9s linear, stroke 0.4s ease' }}
            />
          </svg>

          {/* Center content */}
          <AnimatePresence mode="wait">
            {status === 'done' ? (
              <motion.div
                key="done"
                initial={{ scale: 0.7, opacity: 0 }}
                animate={{ scale: 1, opacity: 1 }}
                exit={{ scale: 0.7, opacity: 0 }}
                transition={{ type: 'spring', stiffness: 300, damping: 22 }}
                className="flex flex-col items-center gap-1"
              >
                <CheckCircle
                  size={40}
                  style={{ color: 'var(--success)' }}
                  strokeWidth={1.8}
                />
                <span
                  className="display text-base font-600 text-center"
                  style={{ color: 'var(--success)', fontWeight: 600 }}
                >
                  Complete!
                </span>
              </motion.div>
            ) : (
              <motion.div
                key="timer"
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                exit={{ opacity: 0 }}
                className="flex flex-col items-center"
              >
                <motion.span
                  key={timeLeft}
                  initial={{ y: -8, opacity: 0 }}
                  animate={{ y: 0, opacity: 1 }}
                  transition={{ duration: 0.25 }}
                  className="display font-700 tabular-nums"
                  style={{
                    fontSize: 54,
                    fontWeight: 700,
                    lineHeight: 1,
                    color: status === 'idle' ? 'var(--muted)' : 'var(--ink)',
                    letterSpacing: '-0.03em',
                  }}
                >
                  {mins}:{secs}
                </motion.span>
                <span
                  className="text-xs font-medium mt-1"
                  style={{ color: 'var(--subtle)' }}
                >
                  {status === 'idle' ? 'ready' : 'seconds left'}
                </span>
              </motion.div>
            )}
          </AnimatePresence>
        </div>

        {/* Progress bar (shown while running) */}
        <div
          className="w-full rounded-full overflow-hidden"
          style={{ height: 4, background: 'var(--border)' }}
        >
          <motion.div
            className="h-full rounded-full"
            style={{
              background: status === 'done' ? 'var(--success)' : 'var(--accent)',
              width: `${Math.round(progress * 100)}%`,
              transition: 'width 0.9s linear, background 0.4s ease',
            }}
          />
        </div>

        {/* Completion message */}
        <AnimatePresence>
          {status === 'done' && (
            <motion.p
              key="msg"
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: 8 }}
              transition={{ duration: 0.35 }}
              className="text-sm font-medium text-center -mt-4"
              style={{ color: 'var(--success)' }}
            >
              Countdown complete!
            </motion.p>
          )}
        </AnimatePresence>

        {/* Buttons */}
        <div className="flex gap-3 w-full">
          <button
            onClick={start}
            disabled={status === 'running' || status === 'done'}
            className="flex-1 flex items-center justify-center gap-2 rounded-2xl font-semibold text-sm transition-all duration-150"
            style={{
              height: 48,
              background:
                status === 'running' || status === 'done'
                  ? 'var(--surface-muted)'
                  : 'var(--accent)',
              color:
                status === 'running' || status === 'done'
                  ? 'var(--subtle)'
                  : '#ffffff',
              border: 'none',
              cursor:
                status === 'running' || status === 'done' ? 'not-allowed' : 'pointer',
            }}
            onMouseEnter={(e) => {
              if (status !== 'running' && status !== 'done') {
                (e.currentTarget).style.background =
                  'var(--accent-hover)';
              }
            }}
            onMouseLeave={(e) => {
              if (status !== 'running' && status !== 'done') {
                (e.currentTarget).style.background =
                  'var(--accent)';
              }
            }}
          >
            <Play size={15} strokeWidth={2.5} />
            Start
          </button>

          <button
            onClick={reset}
            className="flex items-center justify-center gap-2 rounded-2xl font-semibold text-sm transition-all duration-150"
            style={{
              height: 48,
              paddingLeft: 20,
              paddingRight: 20,
              background: 'var(--surface-muted)',
              color: 'var(--ink-2)',
              border: '1px solid var(--border)',
              cursor: 'pointer',
            }}
            onMouseEnter={(e) => {
              (e.currentTarget).style.borderColor =
                'var(--border-strong)';
            }}
            onMouseLeave={(e) => {
              (e.currentTarget).style.borderColor =
                'var(--border)';
            }}
          >
            <RotateCcw size={14} strokeWidth={2.5} />
            Reset
          </button>
        </div>
      </motion.div>
    </div>
  );
}
