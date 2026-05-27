import { useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { ArrowRight, ArrowLeft, Check, Loader2 } from 'lucide-react';
import { useNavigate } from 'react-router-dom';
import { saveUserProfile, saveWorkoutProfile, saveNutritionProfile, saveInjuryProfile, upsertPrimaryGoal, invalidateUserAIContext } from '@/lib/personalizationSync';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

const GOALS = [
  { id: 'lose_fat', label: 'Lose Fat', emoji: '🔥', desc: 'Burn body fat, lean out' },
  { id: 'build_muscle', label: 'Build Muscle', emoji: '💪', desc: 'Grow size and strength' },
  { id: 'get_stronger', label: 'Get Stronger', emoji: '🏋️', desc: 'Increase lifts and power' },
  { id: 'improve_fitness', label: 'Improve Fitness', emoji: '🏃', desc: 'Cardio, endurance, health' },
  { id: 'feel_better', label: 'Feel Better', emoji: '✨', desc: 'Energy, mood, sleep' },
];

const ACTIVITY_LEVELS = [
  { id: 'daily', label: 'Daily', desc: 'I exercise most days' },
  { id: '4x_week', label: '4x a week', desc: 'Fairly consistent training' },
  { id: '2x_week', label: 'Couple times a week', desc: 'Regular but not every day' },
  { id: 'monthly', label: 'Couple times a month', desc: 'Getting started or restarting' },
];

const EATING_PATTERNS = [
  { id: 'structured', label: 'Structured', desc: 'I meal prep and track calories' },
  { id: 'pretty_good', label: 'Pretty Good', desc: 'I eat well most of the time' },
  { id: 'inconsistent', label: 'Inconsistent', desc: 'Good days and bad days' },
  { id: 'struggle', label: 'I Struggle', desc: 'Food is my main challenge' },
];

const STEPS = [
  { id: 'goal', title: 'What\'s your main goal right now?', subtitle: 'This shapes your recommendations across Execute.' },
  { id: 'activity', title: 'How active are you right now?', subtitle: 'Tell us what a normal week looks like.' },
  { id: 'injuries', title: 'Any injuries or physical limitations?', subtitle: 'Your plan will adapt around these.' },
  { id: 'eating', title: 'What does your typical eating look like?', subtitle: 'And where do you struggle most?' },
];

export default function Onboarding({ onComplete }) {
  const navigate = useNavigate();
  const [step, setStep] = useState(0);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState(null);
  const [answers, setAnswers] = useState({
    goal: null,
    goalOther: '',
    activity: null,
    activityDetail: '',
    hasInjuries: null,
    injuryDetail: '',
    eating: null,
    eatingDetail: '',
  });

  const update = (key, val) => setAnswers(prev => ({ ...prev, [key]: val }));

  const canAdvance = () => {
    if (step === 0) return answers.goal !== null;
    if (step === 1) return answers.activity !== null;
    if (step === 2) return answers.hasInjuries !== null;
    if (step === 3) return answers.eating !== null;
    return true;
  };

  const finish = async () => {
    const goalTitleMap = {
      lose_fat: 'Lose body fat',
      build_muscle: 'Build muscle',
      get_stronger: 'Get stronger',
      improve_fitness: 'Improve overall fitness',
      feel_better: 'Feel more energetic & healthy',
      other: answers.goalOther || 'Custom goal',
    };
    const goalCategoryMap = {
      lose_fat: 'body',
      build_muscle: 'fitness',
      get_stronger: 'performance',
      improve_fitness: 'fitness',
      feel_better: 'habit',
      other: 'fitness',
    };
    const activityDaysMap = { daily: 6, '4x_week': 4, '2x_week': 2, monthly: 1 };
    const days = activityDaysMap[answers.activity] || 3;
    const experienceLevel = days >= 5 ? 'advanced' : days >= 3 ? 'intermediate' : 'beginner';

    const workoutGoalMap = {
      lose_fat: 'fat_loss',
      build_muscle: 'muscle_gain',
      get_stronger: 'strength',
      improve_fitness: 'general_fitness',
      feel_better: 'general_fitness',
      other: 'general_fitness',
    };

    // Map eating pattern → structured NutritionProfile fields
    const nutritionGoalMap = {
      lose_fat: 'fat_loss',
      build_muscle: 'muscle_gain',
      get_stronger: 'performance',
      improve_fitness: 'general_health',
      feel_better: 'general_health',
      other: 'general_health',
    };
    const eatingCookingStyleMap = {
      structured: 'meal_prep',
      pretty_good: 'balanced',
      inconsistent: 'quick_easy',
      struggle: 'quick_easy',
    };

    setSaving(true);
    setSaveError(null);

    try {
      // All canonical writes to Supabase — awaited before navigation
      await Promise.all([
        saveUserProfile({
          fitness_level: experienceLevel,
          onboarding_complete: true,
          coaching_style: 'balanced',
        }),
        saveWorkoutProfile({
          primary_goal: workoutGoalMap[answers.goal] || 'general_fitness',
          days_per_week: days,
          experience_level: experienceLevel,
          ...(answers.activityDetail ? { workout_styles: [answers.activityDetail] } : {}),
        }),
        saveNutritionProfile({
          primary_goal: nutritionGoalMap[answers.goal] || 'general_health',
          cooking_style: eatingCookingStyleMap[answers.eating] || 'balanced',
          ...(answers.eatingDetail ? { notes: answers.eatingDetail } : {}),
        }),
        answers.goal
          ? upsertPrimaryGoal({
              title: goalTitleMap[answers.goal] || answers.goalOther,
              category: goalCategoryMap[answers.goal] || 'fitness',
              priority: 'high',
            })
          : Promise.resolve(),
        answers.hasInjuries && answers.injuryDetail
          ? saveInjuryProfile({
              body_area: 'unspecified',
              severity: 'mild_discomfort',
              is_active: true,
              notes: answers.injuryDetail,
            })
          : Promise.resolve(),
      ]);

      // Invalidate AI context only after all writes succeed
      await invalidateUserAIContext();

      if (onComplete) onComplete();
      else navigate('/plan?generate=true');
    } catch (err) {
      console.error('[Onboarding] Save failed', err);
      setSaveError('We could not save your setup. Please try again.');
    } finally {
      setSaving(false);
    }
  };

  const progress = ((step) / STEPS.length) * 100;

  return (
    <div className="min-h-screen flex flex-col" style={{ background: '#f6f2e8' }}>
      {/* Progress bar */}
      <div className="h-1 w-full" style={{ background: '#e8e1d4' }}>
        <motion.div className="h-full" style={{ background: ACCENT }} animate={{ width: `${progress}%` }} transition={{ duration: 0.4 }} />
      </div>

      <div className="flex-1 flex flex-col px-6 pt-12 pb-8 max-w-md mx-auto w-full">
        {/* Logo */}
        <div className="flex items-center gap-2 mb-12">
          <div className="w-7 h-7 rounded-lg flex items-center justify-center" style={{ background: ACCENT }}>
            <span className="font-black text-xs" style={{ color: '#141613' }}>E</span>
          </div>
          <span className="text-sm font-bold" style={{ color: '#141613' }}>Execute</span>
        </div>

        <AnimatePresence mode="wait">
          <motion.div key={step} initial={{ opacity: 0, x: 30 }} animate={{ opacity: 1, x: 0 }} exit={{ opacity: 0, x: -30 }} transition={{ duration: 0.22 }} className="flex-1">
            <p className="text-xs font-bold uppercase tracking-widest mb-2" style={{ color: '#91968e' }}>Step {step + 1} of {STEPS.length}</p>
            <h1 className="text-2xl font-black mb-2 leading-tight" style={{ color: '#141613', letterSpacing: '-0.03em' }}>{STEPS[step].title}</h1>
            <p className="text-sm mb-7" style={{ color: '#91968e' }}>{STEPS[step].subtitle}</p>

            {/* STEP 0 — Goal */}
            {step === 0 && (
              <div className="space-y-3">
                {GOALS.map(g => (
                  <button key={g.id} onClick={() => update('goal', g.id)}
                    className="w-full flex items-center gap-4 p-4 rounded-2xl border text-left transition-all"
                    style={{ background: answers.goal === g.id ? 'rgba(200,224,0,0.1)' : '#ffffff', borderColor: answers.goal === g.id ? 'rgba(200,224,0,0.5)' : '#e8e1d4' }}>
                    <span className="text-2xl">{g.emoji}</span>
                    <div className="flex-1">
                      <p className="text-sm font-bold" style={{ color: '#141613' }}>{g.label}</p>
                      <p className="text-xs" style={{ color: '#91968e' }}>{g.desc}</p>
                    </div>
                    {answers.goal === g.id && <Check size={16} style={{ color: ACCENT_DARK }} />}
                  </button>
                ))}
                <button onClick={() => update('goal', 'other')}
                  className="w-full flex items-center gap-4 p-4 rounded-2xl border text-left transition-all"
                  style={{ background: answers.goal === 'other' ? 'rgba(200,224,0,0.1)' : '#ffffff', borderColor: answers.goal === 'other' ? 'rgba(200,224,0,0.5)' : '#e8e1d4' }}>
                  <span className="text-2xl">🎯</span>
                  <div className="flex-1">
                    <p className="text-sm font-bold" style={{ color: '#141613' }}>Something else</p>
                    <p className="text-xs" style={{ color: '#91968e' }}>I'll describe it</p>
                  </div>
                </button>
                {answers.goal === 'other' && (
                  <motion.input initial={{ opacity: 0, y: -8 }} animate={{ opacity: 1, y: 0 }}
                    value={answers.goalOther} onChange={e => update('goalOther', e.target.value)}
                    placeholder="Describe your goal..."
                    className="w-full px-4 py-3.5 rounded-2xl border text-sm outline-none"
                    style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }} />
                )}
              </div>
            )}

            {/* STEP 1 — Activity */}
            {step === 1 && (
              <div className="space-y-3">
                {ACTIVITY_LEVELS.map(a => (
                  <button key={a.id} onClick={() => update('activity', a.id)}
                    className="w-full flex items-center justify-between p-4 rounded-2xl border text-left transition-all"
                    style={{ background: answers.activity === a.id ? 'rgba(200,224,0,0.1)' : '#ffffff', borderColor: answers.activity === a.id ? 'rgba(200,224,0,0.5)' : '#e8e1d4' }}>
                    <div>
                      <p className="text-sm font-bold" style={{ color: '#141613' }}>{a.label}</p>
                      <p className="text-xs" style={{ color: '#91968e' }}>{a.desc}</p>
                    </div>
                    {answers.activity === a.id && <Check size={16} style={{ color: ACCENT_DARK }} />}
                  </button>
                ))}
                {answers.activity && (
                  <motion.div initial={{ opacity: 0, y: -8 }} animate={{ opacity: 1, y: 0 }}>
                    <textarea value={answers.activityDetail} onChange={e => update('activityDetail', e.target.value)}
                      placeholder="Tell us more — what type of exercise do you usually do? (optional)"
                      rows={3} className="w-full px-4 py-3.5 rounded-2xl border text-sm outline-none resize-none"
                      style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }} />
                  </motion.div>
                )}
              </div>
            )}

            {/* STEP 2 — Injuries */}
            {step === 2 && (
              <div className="space-y-3">
                <div className="grid grid-cols-2 gap-3">
                  {[{ id: false, label: 'No', desc: 'No current limitations', emoji: '✅' }, { id: true, label: 'Yes', desc: 'I have something to share', emoji: '⚠️' }].map(opt => (
                    <button key={String(opt.id)} onClick={() => update('hasInjuries', opt.id)}
                      className="p-4 rounded-2xl border text-center transition-all"
                      style={{ background: answers.hasInjuries === opt.id ? 'rgba(200,224,0,0.1)' : '#ffffff', borderColor: answers.hasInjuries === opt.id ? 'rgba(200,224,0,0.5)' : '#e8e1d4' }}>
                      <span className="text-3xl block mb-2">{opt.emoji}</span>
                      <p className="text-sm font-bold" style={{ color: '#141613' }}>{opt.label}</p>
                      <p className="text-xs" style={{ color: '#91968e' }}>{opt.desc}</p>
                    </button>
                  ))}
                </div>
                {answers.hasInjuries && (
                  <motion.div initial={{ opacity: 0, y: -8 }} animate={{ opacity: 1, y: 0 }}>
                    <textarea value={answers.injuryDetail} onChange={e => update('injuryDetail', e.target.value)}
                      placeholder="Describe your injuries, pain, or health issues... e.g. 'Lower back pain when squatting, bad left knee from old injury'"
                      rows={4} className="w-full px-4 py-3.5 rounded-2xl border text-sm outline-none resize-none"
                      style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }} />
                  </motion.div>
                )}
              </div>
            )}

            {/* STEP 3 — Eating */}
            {step === 3 && (
              <div className="space-y-3">
                {EATING_PATTERNS.map(e => (
                  <button key={e.id} onClick={() => update('eating', e.id)}
                    className="w-full flex items-center justify-between p-4 rounded-2xl border text-left transition-all"
                    style={{ background: answers.eating === e.id ? 'rgba(200,224,0,0.1)' : '#ffffff', borderColor: answers.eating === e.id ? 'rgba(200,224,0,0.5)' : '#e8e1d4' }}>
                    <div>
                      <p className="text-sm font-bold" style={{ color: '#141613' }}>{e.label}</p>
                      <p className="text-xs" style={{ color: '#91968e' }}>{e.desc}</p>
                    </div>
                    {answers.eating === e.id && <Check size={16} style={{ color: ACCENT_DARK }} />}
                  </button>
                ))}
                {answers.eating && (
                  <motion.div initial={{ opacity: 0, y: -8 }} animate={{ opacity: 1, y: 0 }}>
                    <textarea value={answers.eatingDetail} onChange={e => update('eatingDetail', e.target.value)}
                      placeholder="What does a typical day of eating look like? Where do you struggle most? (optional)"
                      rows={3} className="w-full px-4 py-3.5 rounded-2xl border text-sm outline-none resize-none"
                      style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }} />
                  </motion.div>
                )}
              </div>
            )}
          </motion.div>
        </AnimatePresence>

        {/* Navigation */}
        {saveError && (
          <p className="text-sm text-center mt-4 mb-1 font-medium" style={{ color: '#b05a3a' }}>{saveError}</p>
        )}
        <div className="flex items-center gap-3 mt-4">
          {step > 0 && !saving && (
            <button onClick={() => setStep(s => s - 1)} className="w-12 h-12 rounded-2xl flex items-center justify-center border flex-shrink-0"
              style={{ background: '#f2efe7', borderColor: '#e8e1d4' }}>
              <ArrowLeft size={18} style={{ color: '#5d635d' }} />
            </button>
          )}
          <motion.button whileTap={{ scale: 0.97 }} onClick={step < STEPS.length - 1 ? () => setStep(s => s + 1) : finish}
            disabled={!canAdvance() || saving}
            className="flex-1 py-4 rounded-2xl text-sm font-bold flex items-center justify-center gap-2 disabled:opacity-40 transition-all"
            style={{ background: ACCENT, color: '#141613' }}>
            {saving ? (
              <><Loader2 size={15} className="animate-spin" /> Saving your setup…</>
            ) : step < STEPS.length - 1 ? (
              <>Continue <ArrowRight size={16} /></>
            ) : (
              <>Start my plan <ArrowRight size={16} /></>
            )}
          </motion.button>
        </div>
      </div>
    </div>
  );
}