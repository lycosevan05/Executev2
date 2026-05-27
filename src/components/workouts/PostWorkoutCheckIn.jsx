import { useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { ChevronRight } from 'lucide-react';

const ACCENT = '#c8e000';

const EXERTION_OPTIONS = ['Easy', 'Moderate', 'Hard', 'Very hard', 'Max effort'];
const FEELING_OPTIONS = ['Energized', 'Good', 'Tired', 'Drained', 'Sore', 'Pain or discomfort'];
const PAIN_OPTIONS = ['No', 'Yes, minor', 'Yes, concerning'];
const PERFORMANCE_OPTIONS = ['Better than expected', 'As expected', 'Worse than expected'];

function Step({ title, subtitle, children }) {
  return (
    <div>
      <h2 className="text-xl font-black mb-1" style={{ color: '#ffffff', letterSpacing: '-0.03em' }}>{title}</h2>
      {subtitle && <p className="text-sm mb-5" style={{ color: '#5d635d' }}>{subtitle}</p>}
      {children}
    </div>
  );
}

function OptionButton({ label, selected, onSelect }) {
  return (
    <motion.button whileTap={{ scale: 0.97 }} onClick={onSelect}
      className="w-full text-left px-4 py-4 rounded-2xl border font-semibold text-sm transition-all"
      style={{
        background: selected ? 'rgba(200,224,0,0.12)' : 'rgba(255,255,255,0.04)',
        borderColor: selected ? 'rgba(200,224,0,0.4)' : 'rgba(255,255,255,0.07)',
        color: selected ? ACCENT : '#91968e',
      }}>
      {label}
    </motion.button>
  );
}

export default function PostWorkoutCheckIn({ onDone, onBack }) {
  const [step, setStep] = useState(0);
  const [submitting, setSubmitting] = useState(false);
  const [data, setData] = useState({
    exertionLevel: '',
    rpe: 7,
    feeling: '',
    pain: '',
    painNotes: '',
    performance: '',
    notes: '',
  });

  const set = (key, val) => setData(d => ({ ...d, [key]: val }));

  const steps = [
    {
      key: 'exertionLevel',
      render: () => (
        <Step title="How hard did that feel?" subtitle="Session intensity">
          <div className="space-y-2">
            {EXERTION_OPTIONS.map(o => (
              <OptionButton key={o} label={o} selected={data.exertionLevel === o} onSelect={() => set('exertionLevel', o)} />
            ))}
          </div>
        </Step>
      ),
      canNext: () => !!data.exertionLevel,
    },
    {
      key: 'rpe',
      render: () => (
        <Step title="Rate your exertion" subtitle={`RPE: ${data.rpe} / 10`}>
          <div className="flex justify-between mb-3">
            {[1,2,3,4,5,6,7,8,9,10].map(n => (
              <motion.button key={n} whileTap={{ scale: 0.9 }} onClick={() => set('rpe', n)}
                className="w-8 h-10 rounded-xl font-bold text-xs flex items-center justify-center"
                style={{
                  background: data.rpe === n ? ACCENT : 'rgba(255,255,255,0.06)',
                  color: data.rpe === n ? '#141613' : '#5d635d',
                }}>
                {n}
              </motion.button>
            ))}
          </div>
          <div className="flex justify-between text-[10px] px-1" style={{ color: '#3a3f3a' }}>
            <span>Very easy</span><span>Max effort</span>
          </div>
        </Step>
      ),
      canNext: () => true,
    },
    {
      key: 'feeling',
      render: () => (
        <Step title="How do you feel now?">
          <div className="space-y-2">
            {FEELING_OPTIONS.map(o => (
              <OptionButton key={o} label={o} selected={data.feeling === o} onSelect={() => set('feeling', o)} />
            ))}
          </div>
        </Step>
      ),
      canNext: () => !!data.feeling,
    },
    {
      key: 'pain',
      render: () => (
        <Step title="Any pain or discomfort?" subtitle="This is not medical advice. Consult a professional if concerned.">
          <div className="space-y-2 mb-4">
            {PAIN_OPTIONS.map(o => (
              <OptionButton key={o} label={o} selected={data.pain === o} onSelect={() => set('pain', o)} />
            ))}
          </div>
          {data.pain && data.pain !== 'No' && (
            <motion.div initial={{ opacity: 0, y: -4 }} animate={{ opacity: 1, y: 0 }}>
              <textarea
                value={data.painNotes}
                onChange={e => set('painNotes', e.target.value)}
                placeholder="Where and what kind of discomfort?"
                rows={2}
                className="w-full px-4 py-3 rounded-2xl text-sm outline-none resize-none"
                style={{ background: 'rgba(255,255,255,0.05)', border: '1px solid rgba(255,255,255,0.08)', color: '#ffffff', caretColor: ACCENT }}
              />
              {data.pain === 'Yes, concerning' && (
                <p className="text-xs mt-2 leading-relaxed" style={{ color: '#b05a3a' }}>
                  If pain is significant or worsening, consider stopping intense training and consulting a qualified professional.
                </p>
              )}
            </motion.div>
          )}
        </Step>
      ),
      canNext: () => !!data.pain,
    },
    {
      key: 'performance',
      render: () => (
        <Step title="How was your performance?">
          <div className="space-y-2">
            {PERFORMANCE_OPTIONS.map(o => (
              <OptionButton key={o} label={o} selected={data.performance === o} onSelect={() => set('performance', o)} />
            ))}
          </div>
        </Step>
      ),
      canNext: () => !!data.performance,
    },
    {
      key: 'notes',
      render: () => (
        <Step title="Anything to note?" subtitle="Optional — PRs, struggles, how it felt">
          <textarea
            value={data.notes}
            onChange={e => set('notes', e.target.value)}
            placeholder="e.g. Hit a new PR on bench. Left shoulder felt tight near the end."
            rows={4}
            className="w-full px-4 py-3 rounded-2xl text-sm outline-none resize-none"
            style={{ background: 'rgba(255,255,255,0.05)', border: '1px solid rgba(255,255,255,0.08)', color: '#ffffff', caretColor: ACCENT }}
          />
        </Step>
      ),
      canNext: () => true,
    },
  ];

  const currentStep = steps[step];
  const isLast = step === steps.length - 1;

  return (
    <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
      className="fixed inset-0 z-50 flex flex-col" style={{ background: '#0f1010' }}>
      {/* Progress */}
      <div className="h-0.5 w-full" style={{ background: 'rgba(255,255,255,0.06)' }}>
        <motion.div className="h-full" style={{ background: ACCENT }} animate={{ width: `${((step + 1) / steps.length) * 100}%` }} transition={{ duration: 0.3 }} />
      </div>

      <div className="flex-1 px-6 pt-10 pb-6 overflow-y-auto">
        <p className="text-[10px] uppercase tracking-widest mb-6" style={{ color: '#4a4f4a' }}>Post-Workout Check-in · {step + 1}/{steps.length}</p>

        <AnimatePresence mode="wait">
          <motion.div key={step} initial={{ opacity: 0, x: 20 }} animate={{ opacity: 1, x: 0 }} exit={{ opacity: 0, x: -20 }} transition={{ duration: 0.2 }}>
            {currentStep.render()}
          </motion.div>
        </AnimatePresence>
      </div>

      <div className="px-6 pb-10 flex gap-3">
        {step > 0 && (
          <button onClick={() => setStep(s => s - 1)}
            className="flex-1 py-4 rounded-2xl font-bold text-sm"
            style={{ background: 'rgba(255,255,255,0.07)', color: '#91968e' }}>
            Back
          </button>
        )}
        <motion.button whileTap={{ scale: 0.97 }} disabled={!currentStep.canNext() || submitting}
          onClick={async () => {
            if (!isLast) {
              setStep(s => s + 1);
              return;
            }
            setSubmitting(true);
            await onDone(data);
          }}
          className="flex-1 py-4 rounded-2xl font-black text-sm flex items-center justify-center gap-2 disabled:opacity-30"
          style={{ background: ACCENT, color: '#141613' }}>
          {submitting ? 'Saving…' : isLast ? 'Complete Workout' : 'Next'} <ChevronRight size={14} />
        </motion.button>
      </div>
    </motion.div>
  );
}