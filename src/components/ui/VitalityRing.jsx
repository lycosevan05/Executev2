import { motion } from 'framer-motion';

export default function VitalityRing({ value = 0, max = 100, size = 200, color = '#7DF9FF', label, sublabel }) {
  const pct = Math.min(value / max, 1);
  const r = (size - 24) / 2;
  const circumference = 2 * Math.PI * r;
  const offset = circumference * (1 - pct);
  const cx = size / 2;
  const cy = size / 2;

  return (
    <div className="relative flex items-center justify-center" style={{ width: size, height: size }}>
      <svg width={size} height={size} style={{ transform: 'rotate(-90deg)' }}>
        {/* Background track */}
        <circle
          cx={cx} cy={cy} r={r}
          fill="none"
          stroke="rgba(255,255,255,0.06)"
          strokeWidth={10}
        />
        {/* Glow filter */}
        <defs>
          <filter id={`glow-${color.replace('#','')}`} x="-50%" y="-50%" width="200%" height="200%">
            <feGaussianBlur stdDeviation="4" result="coloredBlur" />
            <feMerge>
              <feMergeNode in="coloredBlur" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>
        </defs>
        {/* Progress arc */}
        <motion.circle
          cx={cx} cy={cy} r={r}
          fill="none"
          stroke={color}
          strokeWidth={10}
          strokeLinecap="round"
          strokeDasharray={circumference}
          initial={{ strokeDashoffset: circumference }}
          animate={{ strokeDashoffset: offset }}
          transition={{ duration: 1.5, ease: [0.4, 0, 0.2, 1] }}
          filter={`url(#glow-${color.replace('#','')})`}
        />
      </svg>
      {/* Center content */}
      <div className="absolute inset-0 flex flex-col items-center justify-center">
        {label && <span className="text-3xl font-bold text-ice-white">{label}</span>}
        {sublabel && <span className="text-xs text-slate-mist mt-0.5 text-center px-4">{sublabel}</span>}
      </div>
    </div>
  );
}