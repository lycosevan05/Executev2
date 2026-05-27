import { motion } from 'framer-motion';
import { Footprints, TrendingUp } from 'lucide-react';
import VitalityRing from './VitalityRing';

export default function HeroStepsCard({ currentSteps = 4200, goalSteps = 10000, neededSteps, insight }) {
  const pct = currentSteps / goalSteps;
  const needed = neededSteps || goalSteps - currentSteps;
  const walkMinutes = Math.round(needed / 100);

  return (
    <motion.div
      initial={{ opacity: 0, scale: 0.95 }}
      animate={{ opacity: 1, scale: 1 }}
      transition={{ duration: 0.6 }}
      className="relative overflow-hidden rounded-3xl p-6 card-z3 border border-electric-oxygen/15"
      style={{
        background: 'linear-gradient(145deg, #0E0E14 0%, #0a0a16 60%, #050508 100%)',
      }}
    >
      {/* Ambient glow */}
      <div
        className="absolute top-0 left-1/2 -translate-x-1/2 -translate-y-1/2 w-64 h-64 rounded-full opacity-20 blur-3xl pointer-events-none"
        style={{ background: 'radial-gradient(circle, #7DF9FF 0%, transparent 70%)' }}
      />

      {/* Shimmer overlay */}
      <div className="absolute inset-0 shimmer pointer-events-none" />

      {/* Header */}
      <div className="relative flex items-center justify-between mb-6">
        <div>
          <div className="flex items-center gap-2 mb-1">
            <div className="w-2 h-2 rounded-full bg-electric-oxygen pulse-aura" />
            <span className="text-xs font-medium text-electric-oxygen tracking-widest uppercase">Daily Mission</span>
          </div>
          <h2 className="text-lg font-bold text-ice-white">Movement Target</h2>
        </div>
        <div className="w-10 h-10 rounded-xl flex items-center justify-center" style={{ background: 'rgba(125, 249, 255, 0.12)' }}>
          <Footprints size={20} className="text-electric-oxygen" />
        </div>
      </div>

      {/* Ring + Stats */}
      <div className="relative flex items-center justify-between">
        <VitalityRing
          value={currentSteps}
          max={goalSteps}
          size={160}
          color="#7DF9FF"
          label={currentSteps.toLocaleString()}
          sublabel="steps today"
        />

        <div className="flex-1 pl-6 space-y-4">
          <div>
            <div className="text-3xl font-black text-ice-white">{needed.toLocaleString()}</div>
            <div className="text-xs text-slate-mist mt-0.5">steps remaining</div>
          </div>

          <div className="h-px bg-white/5" />

          <div>
            <div className="text-xl font-bold text-neon-ember">{walkMinutes} min</div>
            <div className="text-xs text-slate-mist mt-0.5">walk to goal</div>
          </div>

          <div className="flex items-center gap-1.5 px-3 py-1.5 rounded-full" style={{ background: 'rgba(173, 255, 47, 0.1)' }}>
            <TrendingUp size={12} className="text-hyper-lime" />
            <span className="text-[11px] font-medium text-hyper-lime">
              {Math.round(pct * 100)}% complete
            </span>
          </div>
        </div>
      </div>

      {/* AI Insight */}
      <motion.div
        initial={{ opacity: 0, y: 8 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ delay: 0.5 }}
        className="relative mt-5 p-3 rounded-2xl border border-electric-oxygen/10"
        style={{ background: 'rgba(125, 249, 255, 0.05)' }}
      >
        <div className="flex items-start gap-2">
          <div className="w-5 h-5 rounded-full flex-shrink-0 flex items-center justify-center mt-0.5" style={{ background: 'rgba(125, 249, 255, 0.2)' }}>
            <span className="text-[10px] text-electric-oxygen font-bold">Coach</span>
          </div>
          <p className="text-sm text-ice-white/90 leading-snug">
            {insight || `A ${walkMinutes}-minute walk this evening keeps you on pace for your weekly goal.`}
          </p>
        </div>
      </motion.div>
    </motion.div>
  );
}