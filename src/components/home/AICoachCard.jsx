import { motion } from 'framer-motion';
import { Brain, Zap } from 'lucide-react';
import { Link } from 'react-router-dom';

export default function AICoachCard({ insights }) {
  if (!insights || insights.length === 0) return null;

  const primary = insights[0];
  const secondary = insights.slice(1, 3);

  const categoryColors = {
    recovery: '#7DF9FF',
    nutrition: '#ADFF2F',
    workout: '#FF5F1F',
    sleep: '#a78bfa',
    steps: '#7DF9FF',
    default: '#7DF9FF',
  };

  const color = categoryColors[primary.category] || categoryColors.default;

  return (
    <motion.div
      initial={{ opacity: 0, y: 16 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ delay: 0.4 }}
      className="rounded-3xl overflow-hidden border"
      style={{ background: '#0E0E14', borderColor: `${color}20` }}
    >
      {/* Header */}
      <div className="px-5 pt-5 pb-4 border-b border-white/5">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2">
            <div className="w-7 h-7 rounded-xl flex items-center justify-center" style={{ background: `${color}18` }}>
              <Brain size={14} style={{ color }} />
            </div>
            <span className="text-sm font-bold text-ice-white">Coach Insight</span>
          </div>
          <Link to="/plan" className="text-[11px] font-medium" style={{ color }}>Full Plan →</Link>
        </div>
        <p className="text-[10px] text-slate-mist mt-1.5">Based on your recent sleep, activity & calorie balance</p>
      </div>

      {/* Primary insight */}
      <div className="px-5 py-4 border-b border-white/5">
        <span className="text-[10px] font-semibold uppercase tracking-widest block mb-2" style={{ color }}>
          {primary.category} · {primary.label || 'Observation'}
        </span>

        {/* 3-part format */}
        <div className="space-y-2">
          {primary.what && (
            <div className="flex items-start gap-2">
              <span className="text-[10px] font-bold text-slate-mist w-14 flex-shrink-0 pt-0.5">NOTICED</span>
              <p className="text-sm text-ice-white/90 leading-snug">{primary.what}</p>
            </div>
          )}
          {primary.means && (
            <div className="flex items-start gap-2">
              <span className="text-[10px] font-bold text-slate-mist w-14 flex-shrink-0 pt-0.5">MEANS</span>
              <p className="text-sm text-slate-mist leading-snug">{primary.means}</p>
            </div>
          )}
          {primary.action && (
            <div className="flex items-start gap-2">
              <span className="text-[10px] font-bold flex-shrink-0 pt-0.5 w-14" style={{ color }}>DO NOW</span>
              <p className="text-sm font-medium leading-snug" style={{ color }}>{primary.action}</p>
            </div>
          )}
          {!primary.what && primary.insight && (
            <p className="text-sm text-ice-white/90 leading-snug">{primary.insight}</p>
          )}
        </div>
      </div>

      {/* Secondary insights */}
      {secondary.length > 0 && (
        <div className="px-5 py-3 space-y-2.5">
          {secondary.map((ins, i) => {
            const c2 = categoryColors[ins.category] || categoryColors.default;
            return (
              <div key={i} className="flex items-start gap-2.5">
                <div className="w-1.5 h-1.5 rounded-full mt-1.5 flex-shrink-0" style={{ background: c2 }} />
                <p className="text-xs text-slate-mist leading-relaxed">{ins.insight || ins.action}</p>
              </div>
            );
          })}
        </div>
      )}

      {/* Bottom CTA */}
      <div className="px-5 pb-5 pt-2">
        <Link
          to="/plan"
          className="flex items-center justify-center gap-2 w-full py-3 rounded-2xl text-sm font-semibold"
          style={{ background: `${color}12`, color, border: `1px solid ${color}25` }}
        >
          <Zap size={14} />
          Generate Today's Full Plan
        </Link>
      </div>
    </motion.div>
  );
}