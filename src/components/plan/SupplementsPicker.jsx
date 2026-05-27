import { AnimatePresence, motion } from 'framer-motion';
import { Check } from 'lucide-react';

const ACCENT_DARK = '#8ea400';

// High-level supplement categories. Specific products are decided later
// during nutrition plan generation based on the user's full profile.
export const SUPPLEMENT_CATEGORIES = [
  { id: 'protein',     label: 'Protein powders',           emoji: '🥛', desc: 'Whey, casein, plant, collagen' },
  { id: 'performance', label: 'Performance & strength',    emoji: '🏋️', desc: 'Creatine, beta-alanine, EAAs' },
  { id: 'energy',      label: 'Energy & focus',            emoji: '⚡', desc: 'Caffeine, NAD+, intra-workout carbs' },
  { id: 'health',      label: 'Health & recovery',         emoji: '🛡️', desc: 'Omega-3, probiotics, joint support' },
  { id: 'vitamins',    label: 'Vitamins & minerals',       emoji: '🌿', desc: 'Multivitamin, vitamin D, magnesium, electrolytes' },
];

export default function SupplementsPicker({ answers, set }) {
  const noSupps = answers.noSupplements === true;
  const selected = Array.isArray(answers.supplements) ? answers.supplements : [];

  const toggle = (id) => {
    const next = selected.includes(id) ? selected.filter(x => x !== id) : [...selected, id];
    set('supplements', next);
  };

  const allIds = SUPPLEMENT_CATEGORIES.map(c => c.id);
  const allSelected = !noSupps && allIds.every(id => selected.includes(id));

  return (
    <div>
      <div className="mb-3">
        <h2 className="text-base font-black tracking-tight mb-0.5" style={{ color: '#141613' }}>
          Any supplement categories you're open to?
        </h2>
        <p className="text-xs leading-snug" style={{ color: '#91968e' }}>
          Optional. Specific products are picked when your nutrition plan is built.
        </p>
      </div>

      <div className="grid grid-cols-2 gap-2 mb-3">
        <button
          onClick={() => {
            if (noSupps) set('noSupplements', false);
            set('supplements', allSelected ? [] : allIds);
          }}
          className="py-2 rounded-xl border text-xs font-semibold transition-all"
          style={{
            background: allSelected ? 'rgba(200,224,0,0.12)' : '#ffffff',
            borderColor: allSelected ? 'rgba(200,224,0,0.5)' : '#e8e1d4',
            color: allSelected ? ACCENT_DARK : '#5d635d',
          }}
        >
          {allSelected ? '✓ All selected' : 'Open to anything'}
        </button>
        <button
          onClick={() => {
            const next = !noSupps;
            set('noSupplements', next);
            if (next) {
              set('supplements', []);
              set('supplementsNotes', '');
            }
          }}
          className="py-2 rounded-xl border text-xs font-semibold transition-all"
          style={{
            background: noSupps ? 'rgba(200,224,0,0.12)' : '#ffffff',
            borderColor: noSupps ? 'rgba(200,224,0,0.5)' : '#e8e1d4',
            color: noSupps ? ACCENT_DARK : '#5d635d',
          }}
        >
          {noSupps ? '✓ None — food only' : 'None — food only'}
        </button>
      </div>

      <AnimatePresence>
        {!noSupps && (
          <motion.div
            initial={{ opacity: 0, height: 0 }}
            animate={{ opacity: 1, height: 'auto' }}
            exit={{ opacity: 0, height: 0 }}
            className="grid grid-cols-2 gap-2 overflow-hidden"
          >
            {SUPPLEMENT_CATEGORIES.map(cat => {
              const on = selected.includes(cat.id);
              const fullWidth = cat.id === 'vitamins';
              return (
                <button
                  key={cat.id}
                  onClick={() => toggle(cat.id)}
                  className={`flex items-center justify-between px-3 py-3.5 rounded-xl border text-left transition-all ${fullWidth ? 'col-span-2' : ''}`}
                  style={{
                    background: on ? 'rgba(200,224,0,0.08)' : '#ffffff',
                    borderColor: on ? 'rgba(200,224,0,0.45)' : '#e8e1d4',
                  }}
                >
                  <div className="flex items-start gap-2 flex-1 min-w-0">
                    <span className="text-base flex-shrink-0 leading-none mt-0.5">{cat.emoji}</span>
                    <div className="flex-1 min-w-0">
                      <p className="text-xs font-semibold leading-tight" style={{ color: '#141613' }}>{cat.label}</p>
                      <p className="text-[10px] mt-0.5 leading-tight" style={{ color: '#91968e' }}>{cat.desc}</p>
                    </div>
                  </div>
                  {on && <Check size={13} style={{ color: ACCENT_DARK, flexShrink: 0, marginLeft: 6, marginTop: 2 }} />}
                </button>
              );
            })}
          </motion.div>
        )}
      </AnimatePresence>

      <div className="pt-3">
        <p className="text-xs font-semibold mb-1.5" style={{ color: '#5d635d' }}>
          Anything you need to avoid? <span className="font-normal" style={{ color: '#91968e' }}>(optional)</span>
        </p>
        <textarea
          value={answers.supplementsNotes || ''}
          onChange={e => set('supplementsNotes', e.target.value)}
          placeholder="e.g. allergic to whey, no stimulants, plant-based only"
          rows={2}
          className="w-full px-3 py-2 rounded-xl border text-xs outline-none resize-none placeholder:text-[#91968e]"
          style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
        />
      </div>
    </div>
  );
}