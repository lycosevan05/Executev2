import { useEffect, useRef, useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { Slider } from '@/components/ui/slider';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

const TARGETS = [
  { key: 'calories', label: 'Calories', unit: 'kcal', min: 1200, max: 5000, step: 50 },
  { key: 'protein_g', label: 'Protein', unit: 'g', min: 50, max: 300, step: 1 },
  { key: 'carbs_g', label: 'Carbs', unit: 'g', min: 50, max: 600, step: 1 },
  { key: 'fat_g', label: 'Fat', unit: 'g', min: 30, max: 200, step: 1 },
];

const MACRO_KEYS = ['protein_g', 'carbs_g', 'fat_g'];
const CALORIES_PER_GRAM = { protein_g: 4, carbs_g: 4, fat_g: 9 };

function rebalanceTargets(targets, key, value) {
  const next = { ...targets, [key]: value };

  if (key === 'calories') {
    const currentMacroCalories = MACRO_KEYS.reduce(
      (sum, macroKey) => sum + ((targets[macroKey] || 0) * CALORIES_PER_GRAM[macroKey]),
      0
    );

    const defaultShares = { protein_g: 0.3, carbs_g: 0.4, fat_g: 0.3 };

    MACRO_KEYS.forEach(macroKey => {
      const currentCalories = (targets[macroKey] || 0) * CALORIES_PER_GRAM[macroKey];
      const share = currentMacroCalories > 0 ? currentCalories / currentMacroCalories : defaultShares[macroKey];
      next[macroKey] = Math.max(0, Math.round((value * share) / CALORIES_PER_GRAM[macroKey]));
    });
    return next;
  }

  if (!MACRO_KEYS.includes(key)) return next;

  const calorieTarget = Math.max(0, targets.calories || 0);
  const changedCalories = value * CALORIES_PER_GRAM[key];
  const remainingCalories = Math.max(0, calorieTarget - changedCalories);
  const otherKeys = MACRO_KEYS.filter(macroKey => macroKey !== key);
  const currentOtherCalories = otherKeys.reduce(
    (sum, macroKey) => sum + ((targets[macroKey] || 0) * CALORIES_PER_GRAM[macroKey]),
    0
  );

  otherKeys.forEach(macroKey => {
    const share = currentOtherCalories > 0
      ? ((targets[macroKey] || 0) * CALORIES_PER_GRAM[macroKey]) / currentOtherCalories
      : 1 / otherKeys.length;
    next[macroKey] = Math.max(0, Math.round((remainingCalories * share) / CALORIES_PER_GRAM[macroKey]));
  });

  return next;
}

export default function EditableNutritionTargets({ targets, onChange, onSave }) {
  const [activeKey, setActiveKey] = useState(null);
  const hasMounted = useRef(false);

  const active = TARGETS.find(item => item.key === activeKey);

  const updateValue = (key, value) => {
    const nextValue = Math.max(0, Math.round(Number(value) || 0));
    onChange(rebalanceTargets(targets, key, nextValue));
  };

  useEffect(() => {
    if (!hasMounted.current) {
      hasMounted.current = true;
      return;
    }

    const timer = setTimeout(() => {
      onSave?.(targets);
    }, 600);

    return () => clearTimeout(timer);
  }, [targets]);

  return (
    <div className="rounded-2xl border p-3 mb-2" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
      <div className="mb-2">
        <p className="text-[10px] font-bold uppercase tracking-widest" style={{ color: '#91968e' }}>Calories & macros</p>
        <p className="text-xs mt-0.5" style={{ color: '#5d635d' }}>Tap a target to adjust it</p>
      </div>

      <div className="space-y-2">
        {TARGETS.slice(0, 1).map(item => {
          const selected = activeKey === item.key;
          return (
            <button
              key={item.key}
              onClick={() => setActiveKey(selected ? null : item.key)}
              className="rounded-2xl border px-3 py-2.5 text-left transition-all w-full flex items-center justify-between gap-3"
              style={{
                background: selected ? 'rgba(200,224,0,0.1)' : '#fbf8f1',
                borderColor: selected ? 'rgba(200,224,0,0.5)' : '#e8e1d4',
                opacity: 1,
              }}
            >
              <div>
                <p className="text-[9px] font-bold uppercase tracking-widest" style={{ color: '#91968e' }}>{item.label}</p>
                <p className="text-[10px] font-semibold" style={{ color: ACCENT_DARK }}>{item.unit}/day</p>
              </div>
              {selected ? (
                <input
                  type="number"
                  value={targets[item.key] || ''}
                  onClick={e => e.stopPropagation()}
                  onChange={e => updateValue(item.key, e.target.value)}
                  className="w-28 bg-transparent text-right text-xl font-black outline-none"
                  style={{ color: '#141613' }}
                />
              ) : (
                <p className="text-xl font-black" style={{ color: '#141613' }}>{(targets[item.key] || 0).toLocaleString()}</p>
              )}
            </button>
          );
        })}
        <div className="grid grid-cols-3 gap-2">
          {TARGETS.slice(1).map(item => {
            const selected = activeKey === item.key;
            return (
              <button
                key={item.key}
                onClick={() => setActiveKey(selected ? null : item.key)}
                className="rounded-2xl border px-2 py-2 text-center transition-all"
                style={{
                  background: selected ? 'rgba(200,224,0,0.1)' : '#fbf8f1',
                  borderColor: selected ? 'rgba(200,224,0,0.5)' : '#e8e1d4',
                  opacity: 1,
                }}
              >
                <p className="text-[8px] font-bold uppercase tracking-widest" style={{ color: '#91968e' }}>{item.label}</p>
                {selected ? (
                  <input
                    type="number"
                    value={targets[item.key] || ''}
                    onClick={e => e.stopPropagation()}
                    onChange={e => updateValue(item.key, e.target.value)}
                    className="w-full bg-transparent text-center text-base font-black outline-none"
                    style={{ color: '#141613' }}
                  />
                ) : (
                  <p className="text-base font-black mt-0.5" style={{ color: '#141613' }}>{(targets[item.key] || 0).toLocaleString()}</p>
                )}
                <p className="text-[8px] font-semibold" style={{ color: ACCENT_DARK }}>{item.unit}</p>
              </button>
            );
          })}
        </div>
      </div>

      <AnimatePresence>
        {active && (
          <motion.div
            initial={{ opacity: 0, height: 0 }}
            animate={{ opacity: 1, height: 'auto' }}
            exit={{ opacity: 0, height: 0 }}
            className="overflow-hidden"
          >
            <div className="pt-3">
              <div className="flex items-center justify-between mb-3">
                <span className="text-xs font-bold" style={{ color: '#141613' }}>Adjust {active.label}</span>
                <span className="text-xs font-semibold" style={{ color: '#91968e' }}>{targets[active.key]} {active.unit}</span>
              </div>
              <Slider
                value={[targets[active.key] || active.min]}
                min={active.min}
                max={active.max}
                step={active.step}
                onValueChange={value => updateValue(active.key, value[0])}
              />
              <p className="text-[9px] mt-2" style={{ color: '#91968e' }}>Tap the number to type an exact value.</p>
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}