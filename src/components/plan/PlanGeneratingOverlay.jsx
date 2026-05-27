import { useState, useEffect } from 'react';
import { motion } from 'framer-motion';
import { Sparkles, Check } from 'lucide-react';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

const STEPS = [
  { id: 'profile',   label: 'Reading your profile & goals',        duration: 3000 },
  { id: 'training',  label: 'Building your training split',         duration: 8000 },
  { id: 'nutrition', label: 'Calculating nutrition targets',        duration: 7000 },
  { id: 'recovery',  label: 'Designing your recovery strategy',     duration: 6000 },
  { id: 'week',      label: 'Mapping out your weekly schedule',     duration: 8000 },
  { id: 'workouts',  label: 'Pre-building today\'s workouts',       duration: 9000 },
];

const TOTAL_DURATION = STEPS.reduce((s, step) => s + step.duration, 0);
const START_TIME_KEY = 'plan_gen_start_time';

function getOrSetStartTime() {
  const stored = sessionStorage.getItem(START_TIME_KEY);
  if (stored) return Number(stored);
  const now = Date.now();
  sessionStorage.setItem(START_TIME_KEY, String(now));
  return now;
}

export function clearGenerationStartTime() {
  sessionStorage.removeItem(START_TIME_KEY);
}

export default function PlanGeneratingOverlay() {
  const [activeStep, setActiveStep] = useState(0);
  const [stepProgress, setStepProgress] = useState(0);
  const [elapsed, setElapsed] = useState(0);
  const [completedSteps, setCompletedSteps] = useState([]);

  useEffect(() => {
    const startTime = getOrSetStartTime();

    // Compute initial state from elapsed time so we resume correctly
    const computeState = (totalElapsed) => {
      let acc = 0;
      for (let i = 0; i < STEPS.length; i++) {
        if (totalElapsed < acc + STEPS[i].duration || i === STEPS.length - 1) {
          const sinceStepStart = totalElapsed - acc;
          const pct = Math.min((sinceStepStart / STEPS[i].duration) * 100, 99);
          const done = Array.from({ length: i }, (_, k) => k);
          return { stepIdx: i, stepProgress: pct, completedSteps: done };
        }
        acc += STEPS[i].duration;
      }
    };

    let { stepIdx, stepProgress: initPct, completedSteps: initDone } = computeState(
      Math.min(Date.now() - startTime, TOTAL_DURATION)
    );

    setActiveStep(stepIdx);
    setStepProgress(initPct);
    setCompletedSteps(initDone);
    setElapsed(Math.min(Date.now() - startTime, TOTAL_DURATION));

    const tick = setInterval(() => {
      const totalElapsed = Math.min(Date.now() - startTime, TOTAL_DURATION);
      setElapsed(totalElapsed);

      const state = computeState(totalElapsed);
      setActiveStep(state.stepIdx);
      setStepProgress(state.stepProgress);
      setCompletedSteps(state.completedSteps);
    }, 80);

    return () => clearInterval(tick);
  }, []);

  const overallProgress = Math.min((elapsed / TOTAL_DURATION) * 100, 98);
  const estimatedSecondsLeft = Math.ceil((TOTAL_DURATION - elapsed) / 1000);
  const timeLabel = estimatedSecondsLeft > 60
    ? `~${Math.ceil(estimatedSecondsLeft / 60)} min left`
    : estimatedSecondsLeft > 5
      ? `~${estimatedSecondsLeft}s left`
      : 'Almost done…';

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      className="fixed inset-0 z-30 flex flex-col items-center justify-center px-6"
      style={{ background: 'rgba(246,242,232,0.98)', backdropFilter: 'blur(16px)' }}
    >
      {/* Icon */}
      <motion.div
        className="w-16 h-16 rounded-2xl flex items-center justify-center mb-7"
        style={{ background: 'rgba(200,224,0,0.12)', border: '1px solid rgba(200,224,0,0.3)' }}
        animate={{ scale: [1, 1.05, 1] }}
        transition={{ repeat: Infinity, duration: 1.8, ease: 'easeInOut' }}
      >
        <Sparkles size={26} style={{ color: ACCENT_DARK }} />
      </motion.div>

      {/* Title */}
      <p className="text-lg font-black tracking-tight mb-1" style={{ color: '#141613' }}>
        Building your plan
      </p>
      <p className="text-sm mb-8" style={{ color: '#91968e' }}>
        Personalizing everything to you
      </p>

      {/* Overall progress bar */}
      <div className="w-full max-w-xs mb-2">
        <div className="flex items-center justify-between mb-2">
          <span className="text-xs font-bold" style={{ color: ACCENT_DARK }}>
            {Math.round(overallProgress)}%
          </span>
          <span className="text-xs" style={{ color: '#91968e' }}>{timeLabel}</span>
        </div>
        <div className="h-2 w-full rounded-full overflow-hidden" style={{ background: '#e8e1d4' }}>
          <motion.div
            className="h-full rounded-full"
            style={{ background: `linear-gradient(90deg, ${ACCENT_DARK}, ${ACCENT})` }}
            animate={{ width: `${overallProgress}%` }}
            transition={{ duration: 0.3, ease: 'linear' }}
          />
        </div>
      </div>

      {/* Steps list */}
      <div className="w-full max-w-xs mt-6 space-y-3">
        {STEPS.map((step, i) => {
          const isDone = completedSteps.includes(i);
          const isActive = activeStep === i;
          const isPending = !isDone && !isActive;

          return (
            <motion.div
              key={step.id}
              initial={{ opacity: 0, x: -8 }}
              animate={{ opacity: isPending ? 0.35 : 1, x: 0 }}
              transition={{ delay: i * 0.05 }}
              className="flex items-center gap-3"
            >
              {/* Step indicator */}
              <div
                className="w-5 h-5 rounded-full flex-shrink-0 flex items-center justify-center"
                style={{
                  background: isDone
                    ? ACCENT
                    : isActive
                      ? 'rgba(200,224,0,0.2)'
                      : '#e8e1d4',
                  border: isActive ? `1.5px solid ${ACCENT}` : 'none',
                  transition: 'background 0.3s',
                }}
              >
                {isDone ? (
                  <Check size={11} style={{ color: '#141613' }} strokeWidth={3} />
                ) : isActive ? (
                  <motion.div
                    className="w-2 h-2 rounded-full"
                    style={{ background: ACCENT }}
                    animate={{ scale: [1, 1.4, 1] }}
                    transition={{ repeat: Infinity, duration: 0.8 }}
                  />
                ) : null}
              </div>

              {/* Label + micro-progress bar for active step */}
              <div className="flex-1 min-w-0">
                <p
                  className="text-xs font-semibold leading-tight"
                  style={{ color: isDone ? '#91968e' : isActive ? '#141613' : '#b8b4ac' }}
                >
                  {step.label}
                </p>
                {isActive && (
                  <div className="mt-1 h-0.5 w-full rounded-full overflow-hidden" style={{ background: '#e8e1d4' }}>
                    <motion.div
                      className="h-full rounded-full"
                      style={{ background: ACCENT }}
                      animate={{ width: `${stepProgress}%` }}
                      transition={{ duration: 0.15, ease: 'linear' }}
                    />
                  </div>
                )}
              </div>
            </motion.div>
          );
        })}
      </div>
    </motion.div>
  );
}