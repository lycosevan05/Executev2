import { motion } from 'framer-motion';
import { ChevronRight, Brain } from 'lucide-react';

export default function PlanInsightCard({ activePlan, onSeeAdjustments }) {
  const planSummary = activePlan?.plan_summary || activePlan?.plan_payload?.plan_summary || {};
  const body = planSummary?.rationale ||
    'Based on your recent logs, this week prioritizes strength while protecting recovery.';

  return (
    <motion.div
      initial={{ opacity: 0, y: 8 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ delay: 0.18 }}
      className="flex items-center gap-4 p-4 rounded-2xl border"
      style={{ background: '#ffffff', borderColor: '#e8e1d4', boxShadow: '0 2px 8px rgba(20,22,19,0.05)' }}
    >
      <div className="w-11 h-11 rounded-2xl flex items-center justify-center flex-shrink-0"
        style={{ background: 'rgba(200,224,0,0.1)' }}>
        <Brain size={20} style={{ color: '#8ea400' }} />
      </div>
      <div className="flex-1 min-w-0">
        <p className="text-sm font-bold mb-0.5" style={{ color: '#141613' }}>Why this plan fits you</p>
        <p className="text-xs leading-relaxed" style={{ color: '#5d635d' }}>{body}</p>
      </div>
      <button
        onClick={onSeeAdjustments}
        className="flex items-center gap-0.5 text-xs font-semibold flex-shrink-0"
        style={{ color: '#8ea400' }}
      >
        See adjustments <ChevronRight size={13} />
      </button>
    </motion.div>
  );
}