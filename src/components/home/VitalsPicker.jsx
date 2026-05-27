import { motion } from 'framer-motion';
import { Check } from 'lucide-react';

const ACCENT_DARK = '#8ea400';

export default function VitalsPicker({ allVitals, selectedIds, onToggle }) {
  return (
    <motion.div
      initial={{ opacity: 0, y: 6 }}
      animate={{ opacity: 1, y: 0 }}
      className="p-4 rounded-2xl border"
      style={{ background: '#ffffff', borderColor: 'rgba(200,224,0,0.4)' }}
    >
      <p className="text-[10px] font-bold uppercase tracking-widest mb-3" style={{ color: '#8ea400' }}>
        Choose Vitals — tap to toggle
      </p>
      <div className="grid grid-cols-2 gap-2">
        {allVitals.map(v => {
          const selected = selectedIds.includes(v.id);
          return (
            <button
              key={v.id}
              type="button"
              onClick={(e) => { e.stopPropagation(); onToggle(v.id); }}
              className="flex items-center justify-between px-3 py-2.5 rounded-xl border text-left transition-all"
              style={{
                background: selected ? 'rgba(200,224,0,0.12)' : '#f9f7f3',
                borderColor: selected ? 'rgba(200,224,0,0.55)' : '#e8e1d4',
              }}
            >
              <span className="text-xs font-semibold" style={{ color: selected ? ACCENT_DARK : '#5d635d' }}>
                {v.label}
                {v.custom && <span className="ml-1 text-[9px] opacity-60">custom</span>}
              </span>
              {selected && <Check size={12} style={{ color: ACCENT_DARK }} />}
            </button>
          );
        })}
      </div>
      <p className="text-[10px] mt-2.5" style={{ color: '#91968e' }}>
        {selectedIds.length} selected · 1–12 allowed
      </p>
    </motion.div>
  );
}