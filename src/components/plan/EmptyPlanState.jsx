import { motion } from 'framer-motion';
import { Sparkles } from 'lucide-react';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

export default function EmptyPlanState({ onGenerate }) {
  return (
    <motion.div
      initial={{ opacity: 0, y: 12 }}
      animate={{ opacity: 1, y: 0 }}
      className="flex flex-col items-center text-center px-4 py-14"
    >
      <div className="w-20 h-20 rounded-3xl flex items-center justify-center mb-5"
        style={{ background: 'rgba(200,224,0,0.1)', border: '1.5px solid rgba(200,224,0,0.25)' }}>
        <Sparkles size={30} style={{ color: ACCENT_DARK }} />
      </div>
      <h2 className="text-xl font-black tracking-tight mb-2" style={{ color: '#141613' }}>
        Create your first adaptive plan
      </h2>
      <p className="text-sm leading-relaxed max-w-xs mb-8" style={{ color: '#91968e' }}>
        Execute can build a weekly plan around your goals, recovery, training history, and nutrition needs.
      </p>
      <motion.button
        whileTap={{ scale: 0.96 }}
        onClick={onGenerate}
        className="flex items-center gap-2 px-8 py-4 rounded-2xl text-sm font-bold"
        style={{ background: ACCENT, color: '#141613', boxShadow: '0 4px 16px rgba(200,224,0,0.25)' }}
      >
        <Sparkles size={15} /> Generate My Plan
      </motion.button>
    </motion.div>
  );
}