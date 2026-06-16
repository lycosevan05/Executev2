import { useState, useCallback, useEffect, useRef } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { Check, ChevronLeft, ChevronDown, Sparkles, ArrowRight, Plus, X, Loader2, Upload } from 'lucide-react';
import { getUnitSystem, lbsToKg, ftInToCm, kgToLbs, cmToFtIn } from '@/lib/units';
import { getPlatform } from '@/lib/platform';
import { savePendingAnswers } from '@/lib/planGenerationState';
import { structurePastedPlan } from '@/lib/plans/structurePastedPlan';
import { extractPdfTextClient, processPdfWithAI } from '@/lib/plans/extractPdfText';
import { saveByoDraft, loadByoDraft } from '@/lib/plans/byoDraft';
import SportWeekSchedule from '@/components/plan/SportWeekSchedule';
import SupplementsPicker from '@/components/plan/SupplementsPicker';


const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

// ─── BYO ("Input your own plan") gating helpers ───────────────────────────────
// Which side(s) the custom user is supplying themselves.
function byoTargets(a) {
  if (a.planType !== 'custom') return [];
  if (a.byoScope === 'both') return ['workout', 'nutrition'];
  if (a.byoScope === 'training') return ['workout'];
  if (a.byoScope === 'nutrition') return ['nutrition'];
  return [];
}
// Show the AI workout questions only when AI is building that side.
function appliesWorkout(a) {
  if (a.planType === 'workout' || a.planType === 'daily_performance') return true;
  if (a.planType === 'custom') {
    if (!a.byoScope) return false; // never leak workout Qs while scope is unset
    return !byoTargets(a).includes('workout');
  }
  return false;
}
function appliesNutrition(a) {
  if (a.planType === 'nutrition' || a.planType === 'daily_performance') return true;
  if (a.planType === 'custom') {
    if (!a.byoScope) return false;
    return !byoTargets(a).includes('nutrition');
  }
  return false;
}

// ─── Question flow definition ─────────────────────────────────────────────────

const QUESTION_FLOW = [
  { id: 'planType',          applies: () => true },
  // BYO scope sits BEFORE any workout/nutrition-gated step so gating never leaks.
  { id: 'byoScope',          applies: a => a.planType === 'custom' },
  { id: 'goals',             applies: () => true },
  // If user selected sport-specific training, ask about the sport immediately after goals
  { id: 'primarySport',      applies: a => appliesWorkout(a) && (a.goals || []).includes('sport_specific') },
  { id: 'optimize',          applies: () => true },
  { id: 'bodyStats',         applies: () => true },

  // BYO paste sheets — the side(s) the user supplies themselves.
  { id: 'byoWorkoutInput',   applies: a => a.planType === 'custom' && byoTargets(a).includes('workout') },
  { id: 'byoMealInput',      applies: a => a.planType === 'custom' && byoTargets(a).includes('nutrition') },

  // Workout-only or complete path
  { id: 'currentTraining',   applies: appliesWorkout },
  { id: 'trainingDays',      applies: appliesWorkout },
  { id: 'sessionLength',     applies: appliesWorkout },
  { id: 'trainingLocation',  applies: appliesWorkout },
  { id: 'equipment',         applies: a => appliesWorkout(a) && a.trainingLocation !== 'gym' },
  { id: 'limitations',       applies: appliesWorkout },
  { id: 'aggressiveness',    applies: appliesWorkout },

  // Nutrition-only or complete path
  { id: 'mealsPerDay',       applies: appliesNutrition },
  { id: 'foodsToAvoid',      applies: appliesNutrition },
  { id: 'favoriteFoods',     applies: appliesNutrition },
  { id: 'supplements',       applies: () => true },

  { id: 'desiredOutcome',    applies: () => true },
  { id: 'mainBarrier',       applies: () => true },
  { id: 'nutritionStruggles',applies: a => appliesNutrition(a) && Array.isArray(a.mainBarrier) && a.mainBarrier.includes('food_consistency') },
  { id: 'coachingStyle',     applies: () => true },
  { id: 'additionalNotes',   applies: () => true },
  // Structuring pre-call (custom only) runs LAST, after all answers exist.
  { id: 'byoStructuring',    applies: a => a.planType === 'custom' && byoTargets(a).length > 0 },
];

function isStepComplete(id, answers) {
  if (id === 'planType') return !!answers.planType;
  if (id === 'byoScope') return !!answers.byoScope;
  if (id === 'byoWorkoutInput') return (answers.byoWorkoutText || '').trim().length > 0;
  if (id === 'byoMealInput') return (answers.byoMealText || '').trim().length > 0;
  if (id === 'byoStructuring') return answers.byoStructured?.resolved === true;
  if (id === 'goals') return (answers.goals || []).length > 0;
  if (id === 'optimize') return !!answers.optimize;
  if (id === 'bodyStats') return !!answers.age;
  if (id === 'primarySport') return true; // optional
  if (id === 'currentTraining') return !!answers.currentTraining;
  if (id === 'trainingDays') return !!answers.trainingDays;
  if (id === 'sessionLength') return !!answers.sessionLength;
  if (id === 'trainingLocation') return !!answers.trainingLocation;
  if (id === 'equipment') return (answers.equipment || []).length > 0;
  if (id === 'limitations') return answers.hasLimitations !== null && answers.hasLimitations !== undefined;
  if (id === 'aggressiveness') return !!answers.aggressiveness;
  if (id === 'activityLevel') return !!answers.currentActivity;
  if (id === 'mealsPerDay') return !!answers.mealsPerDay;
  if (id === 'favoriteFoods') return true; // optional
  if (id === 'foodsToAvoid') return true; // optional
  if (id === 'supplements') return true; // optional
  if (id === 'nutritionStruggles') return true; // optional
  if (id === 'desiredOutcome') return Array.isArray(answers.desiredOutcomeFeeling) ? answers.desiredOutcomeFeeling.length > 0 : !!answers.desiredOutcomeFeeling;
  if (id === 'mainBarrier') return Array.isArray(answers.mainBarrier) ? answers.mainBarrier.length > 0 : !!answers.mainBarrier;
  if (id === 'coachingStyle') return !!answers.coachingStyle;
  if (id === 'additionalNotes') return true; // optional
  return true;
}

// ─── Reusable UI primitives ───────────────────────────────────────────────────

function OptionRow({ selected, onClick, label, desc, emoji }) {
  return (
    <button
      onClick={onClick}
      className="w-full flex items-center justify-between p-4 rounded-2xl border text-left transition-all"
      style={{
        background: selected ? 'rgba(200,224,0,0.08)' : '#ffffff',
        borderColor: selected ? 'rgba(200,224,0,0.45)' : '#e8e1d4',
      }}
    >
      <div className="flex items-start gap-3 flex-1 min-w-0">
        {emoji && <span className="text-xl flex-shrink-0">{emoji}</span>}
        <div className="flex-1 min-w-0">
          <p className="text-sm font-semibold" style={{ color: '#141613' }}>{label}</p>
          {desc && <p className="text-xs mt-0.5 leading-relaxed" style={{ color: '#91968e' }}>{desc}</p>}
        </div>
      </div>
      {selected && <Check size={16} style={{ color: ACCENT_DARK, flexShrink: 0, marginLeft: 12 }} />}
    </button>
  );
}

function ChipGrid({ options, selected, onToggle, multi = true }) {
  return (
    <div className="flex flex-wrap gap-2">
      {options.map(opt => {
        const isSelected = multi
          ? (selected || []).includes(opt.id)
          : selected === opt.id;
        return (
          <button
            key={opt.id}
            onClick={() => onToggle(opt.id)}
            className="flex items-center gap-1.5 px-3.5 py-2 rounded-xl border text-sm font-medium transition-all"
            style={{
              background: isSelected ? 'rgba(200,224,0,0.12)' : '#ffffff',
              borderColor: isSelected ? 'rgba(200,224,0,0.5)' : '#e8e1d4',
              color: isSelected ? ACCENT_DARK : '#141613',
            }}
          >
            {opt.emoji && <span>{opt.emoji}</span>}
            {opt.label}
            {isSelected && <Check size={11} style={{ color: ACCENT_DARK }} />}
          </button>
        );
      })}
    </div>
  );
}

// ─── Per-step content ─────────────────────────────────────────────────────────

const GOALS_OPTIONS = [
  { id: 'lose_fat', label: 'Lose fat', emoji: '🔥' },
  { id: 'build_muscle', label: 'Build muscle', emoji: '💪' },
  { id: 'get_stronger', label: 'Get stronger', emoji: '🏋️' },
  { id: 'improve_flexibility', label: 'Improve flexibility', emoji: '🧘' },
  { id: 'sport_specific', label: 'Sport-specific training', emoji: '⚽' },
  { id: 'feel_better', label: 'Feel better', emoji: '✨' },
  { id: 'other', label: 'Something else', emoji: '🎯' },
];

const OPTIMIZE_OPTIONS = [
  { id: 'fastest', label: 'Fastest progress', desc: 'Push hard for results' },
  { id: 'consistent', label: 'Easiest consistency', desc: 'Habits I can actually stick to' },
  { id: 'balanced', label: 'Balanced', desc: 'Progress without burning out' },
  { id: 'injury_safe', label: 'Injury-safe / low stress', desc: 'Protect my body first' },
];

const BYO_SCOPE_OPTIONS = [
  { id: 'training',  label: 'My training plan', emoji: '🏋️', desc: "I'll bring my own workout plan." },
  { id: 'nutrition', label: 'My meal plan',     emoji: '🥗', desc: "I'll bring my own nutrition plan." },
  { id: 'both',      label: 'Both',             emoji: '📦', desc: "I'll bring both myself." },
];

const CURRENT_TRAINING_OPTIONS = [
  { id: 'never', label: 'Never / rarely', desc: 'Getting started or restarting' },
  { id: '1_2_days', label: '1–2 days a week', desc: 'Some activity but inconsistent' },
  { id: '3_4_days', label: '3–4 days a week', desc: 'Fairly consistent' },
  { id: '5_plus', label: '5+ days a week', desc: 'Very active' },
];

const TRAINING_DAYS_OPTIONS = [
  { id: '2_or_less', label: '2 or less' },
  { id: '3_5', label: '3–5' },
  { id: '5_7', label: '5–7' },
  { id: 'seven_plus', label: '7+' },
];

const SESSION_LENGTH_OPTIONS = [
  { id: '20', label: '20 min', desc: 'Quick sessions' },
  { id: '30', label: '30 min', desc: 'Short and effective' },
  { id: '45', label: '45 min', desc: 'Standard' },
  { id: '60', label: '60 min', desc: 'Full session' },
  { id: '75', label: '75+ min', desc: 'Long sessions' },
  { id: 'best', label: 'Whatever is best', desc: 'Execute recommends' },
];

const LOCATION_OPTIONS = [
  { id: 'gym', label: 'Gym', emoji: '🏟️', desc: 'Commercial gym access' },
  { id: 'home', label: 'Home', emoji: '🏠', desc: 'Home setup' },
  { id: 'mixed', label: 'Mixed', emoji: '🔄', desc: 'Combination of locations' },
];

const EQUIPMENT_HOME = [
  { id: 'calisthenics', label: 'Calisthenics', emoji: '🤸' },
  { id: 'free_weights', label: 'Free weights', emoji: '🏋️', desc: 'Dumbbells & kettlebells' },
  { id: 'resistance_bands', label: 'Resistance bands', emoji: '🎗️' },
  { id: 'pullup_bar', label: 'Pull-up bar', emoji: '🔝' },
  { id: 'cardio_machines', label: 'Bike / treadmill', emoji: '🚴' },
  { id: 'sport_facility', label: 'Sport-specific facility', emoji: '🏟️', desc: 'Court, field, track, dojo, climbing gym…' },
];

const EQUIPMENT_GYM = [
  { id: 'full_gym', label: 'Full gym', emoji: '🏟️' },
  { id: 'cables', label: 'Cables', emoji: '🔗' },
  { id: 'free_weights', label: 'Free weights', emoji: '🏋️', desc: 'Dumbbells & kettlebells' },
  { id: 'calisthenics', label: 'Calisthenics', emoji: '🤸' },
  { id: 'cardio_machines', label: 'Cardio machines', emoji: '🚴' },
  { id: 'sport_facility', label: 'Sport-specific facility', emoji: '🥋', desc: 'Court, field, track, dojo, climbing gym…' },
];

const AGGRESSIVENESS_OPTIONS = [
  { id: 'easy', label: 'Easy to stick to', emoji: '🌱', desc: 'Sustainable habits first' },
  { id: 'balanced', label: 'Balanced challenge', emoji: '⚖️', desc: 'Progress with some effort' },
  { id: 'hard', label: 'Push me hard', emoji: '🔥', desc: 'Maximum results focus' },
];

const DESIRED_OUTCOME_OPTIONS = [
  { id: 'look_fitter', label: 'I want to look noticeably fitter', emoji: '💪' },
  { id: 'feel_stronger', label: 'I want to feel stronger and more athletic', emoji: '🏋️' },
  { id: 'energy_confidence', label: 'I want better energy and confidence', emoji: '⚡' },
  { id: 'rebuild_consistency', label: 'I want to rebuild consistency', emoji: '🔄' },
  { id: 'sport_performance', label: 'I want to improve performance in a sport or activity', emoji: '🎯' },
  { id: 'health_control', label: 'I want to feel in control of my health again', emoji: '🌿' },
];

const MAIN_BARRIER_OPTIONS = [
  { id: 'lose_motivation', label: 'I lose motivation after a few weeks', emoji: '📉' },
  { id: 'overwhelmed', label: 'I get overwhelmed by complicated plans', emoji: '🤯' },
  { id: 'food_consistency', label: 'I struggle with food consistency', emoji: '🍽️' },
  { id: 'changing_schedule', label: 'My schedule changes a lot', emoji: '📅' },
  { id: 'burnout', label: 'I push too hard and burn out', emoji: '🔥' },
  { id: 'unsure_what_todo', label: "I'm not sure what to do each day", emoji: '❓' },
];

const COACHING_STYLE_OPTIONS = [
  { id: 'data_driven', label: 'Data-driven and analytical', emoji: '📊', desc: 'Numbers and progress metrics' },
  { id: 'encouraging', label: 'Encouraging and supportive', emoji: '🙌', desc: 'Positive reinforcement' },
  { id: 'ruthless', label: 'Ruthless', emoji: '🔥', desc: 'Direct and performance-focused' },
  { id: 'simple', label: 'Simple and practical', emoji: '✅', desc: 'Easy to follow, low friction' },
];

const NUTRITION_GOAL_OPTIONS = [
  { id: 'lose_fat', label: 'Lose fat', emoji: '🔥' },
  { id: 'build_muscle', label: 'Build muscle', emoji: '💪' },
  { id: 'fuel_performance', label: 'Fuel performance', emoji: '⚡' },
  { id: 'eat_healthier', label: 'Eat healthier', emoji: '🥗' },
  { id: 'maintain', label: 'Maintain weight', emoji: '⚖️' },
  { id: 'improve_energy', label: 'Improve energy', emoji: '✨' },
];

const ACTIVITY_LEVEL_OPTIONS = [
  { id: 'monthly', label: 'Mostly sitting', desc: 'Desk job, minimal movement' },
  { id: '2x_week', label: 'Light movement', desc: 'Walk occasionally, some activity' },
  { id: '4x_week', label: 'Moderately active', desc: 'Active job or regular walks' },
  { id: 'daily', label: 'Very active', desc: 'Train 3+ times / week or active job' },
];

const MEALS_PER_DAY_OPTIONS = [
  { id: '2', label: '2 meals' },
  { id: '3', label: '3 meals' },
  { id: '4', label: '4 meals' },
  { id: '5+', label: '5+ meals' },
];

const FOODS = [
  'Chicken', 'Beef', 'Fish', 'Eggs', 'Rice', 'Pasta', 'Potatoes', 'Oats',
  'Greek yogurt', 'Fruit', 'Vegetables', 'Smoothies', 'Salads', 'Wraps',
  'Bowls', 'Stir-fries', 'Soups', 'Sandwiches', 'Protein shakes', 'Healthy snacks', 'Tofu',
];

const STRUGGLES = [
  'Cravings', 'Skipping meals', 'Late-night eating', 'Low protein',
  'Too much takeout', 'No time to cook', 'Budget', 'Tracking food',
  'Weekend consistency', 'Eating too much', 'Emotional eating', "I'm not sure",
];

// ─── Step renderers ───────────────────────────────────────────────────────────

function StepPlanType({ answers, set, onDeveloperPreset }) {
  return (
    <div className="space-y-3">
      <div className="mb-6">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>
          What do you want Execute to build first?
        </h2>
        <p className="text-sm leading-relaxed" style={{ color: '#91968e' }}>
          You can always expand later. Start with what matters most right now.
        </p>
      </div>
      {[
        { id: 'workout', label: 'Training plan', emoji: '🏋️', desc: 'Build workouts around your goal, schedule, equipment, and recovery.' },
        { id: 'nutrition', label: 'Nutrition plan', emoji: '🥗', desc: 'Build a practical eating plan around your goal, food preferences, routine, and constraints.' },
        { id: 'daily_performance', label: 'Complete performance plan', emoji: '🌿', desc: 'Build training, nutrition, recovery, and daily actions together.' },
        { id: 'custom', label: 'Input your own plan', emoji: '📝', desc: 'Already have a plan? Paste it or upload a PDF. Execute structures it and builds the other side around it.' },
      ].map(opt => (
        <OptionRow key={opt.id} selected={answers.planType === opt.id}
          onClick={() => set('planType', opt.id)} label={opt.label} desc={opt.desc} emoji={opt.emoji} />
      ))}
      {(import.meta.env.DEV || getPlatform() === 'ios') && typeof onDeveloperPreset === 'function' && (
        <button
          type="button"
          onClick={onDeveloperPreset}
          className="w-full flex items-center justify-center gap-2 px-4 py-3 rounded-xl border text-xs font-bold transition-all"
          style={{
            background: '#141613',
            borderColor: '#141613',
            color: '#ffffff',
          }}
        >
          <Sparkles size={14} />
          Dev shortcut: generate Evan preset
        </button>
      )}
    </div>
  );
}

function StepGoals({ answers, set }) {
  const goals = answers.goals || [];
  const toggle = id => set('goals', goals.includes(id) ? goals.filter(x => x !== id) : [...goals, id]);
  return (
    <div>
      <div className="mb-6">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>
          What result do you want most right now?
        </h2>
        <p className="text-sm" style={{ color: '#91968e' }}>Select all that apply.</p>
      </div>
      <div className="space-y-2">
        {GOALS_OPTIONS.map(opt => (
          <OptionRow key={opt.id} selected={goals.includes(opt.id)}
            onClick={() => toggle(opt.id)} label={opt.label} emoji={opt.emoji} />
        ))}
        <AnimatePresence>
          {goals.includes('other') && (
            <motion.input
              initial={{ opacity: 0, height: 0 }} animate={{ opacity: 1, height: 'auto' }} exit={{ opacity: 0, height: 0 }}
              value={answers.goalOther || ''}
              onChange={e => set('goalOther', e.target.value)}
              placeholder="Describe your goal…"
              className="w-full px-4 py-3 rounded-xl border text-sm outline-none"
              style={{ background: '#f9f7f3', borderColor: '#e8e1d4', color: '#141613' }}
            />
          )}
        </AnimatePresence>
      </div>
    </div>
  );
}

function StepOptimize({ answers, set }) {
  return (
    <div>
      <div className="mb-6">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>
          What should the plan optimize for?
        </h2>
        <p className="text-sm" style={{ color: '#91968e' }}>This shapes the intensity, pacing, and structure of everything.</p>
      </div>
      <div className="space-y-2">
        {OPTIMIZE_OPTIONS.map(opt => (
          <OptionRow key={opt.id} selected={answers.optimize === opt.id}
            onClick={() => set('optimize', opt.id)} label={opt.label} desc={opt.desc} />
        ))}
      </div>
    </div>
  );
}

function StepBodyStats({ answers, set }) {
  const unitSystem = getUnitSystem();
  const isImperial = unitSystem === 'imperial';

  return (
    <div>
      <div className="mb-6">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>About you</h2>
        <p className="text-sm leading-relaxed" style={{ color: '#91968e' }}>
          Used to personalize calorie targets, training volume, and recovery recommendations.
        </p>
      </div>
      <div className="space-y-4">
        <div>
          <p className="text-xs font-semibold mb-1.5" style={{ color: '#5d635d' }}>Your name</p>
          <input type="text" value={answers.name || ''} onChange={e => set('name', e.target.value)}
            placeholder="First name"
            className="w-full px-3 py-3 rounded-xl border text-sm outline-none"
            style={{ background: '#f9f7f3', borderColor: answers.name ? 'rgba(200,224,0,0.45)' : '#e8e1d4', color: '#141613' }} />
        </div>
        <div className="grid grid-cols-2 gap-3">
          <div>
            <p className="text-xs font-semibold mb-1.5" style={{ color: '#5d635d' }}>Age <span style={{ color: '#b05a3a' }}>*</span></p>
            <input type="number" value={answers.age || ''} onChange={e => set('age', e.target.value)}
              placeholder="e.g. 28" min={10} max={100}
              className="w-full px-3 py-3 rounded-xl border text-sm outline-none"
              style={{ background: '#f9f7f3', borderColor: answers.age ? 'rgba(200,224,0,0.45)' : '#e8e1d4', color: '#141613' }} />
          </div>
          <div>
            <p className="text-xs font-semibold mb-1.5" style={{ color: '#5d635d' }}>Weight ({isImperial ? 'lbs' : 'kg'})</p>
            <input type="number" value={answers.weightDisplay || ''} onChange={e => set('weightDisplay', e.target.value)}
              placeholder={isImperial ? 'e.g. 175' : 'e.g. 80'} min={isImperial ? 66 : 30} max={isImperial ? 660 : 300}
              className="w-full px-3 py-3 rounded-xl border text-sm outline-none"
              style={{ background: '#f9f7f3', borderColor: answers.weightDisplay ? 'rgba(200,224,0,0.45)' : '#e8e1d4', color: '#141613' }} />
          </div>
        </div>
        <div>
          <p className="text-xs font-semibold mb-1.5" style={{ color: '#5d635d' }}>Height {isImperial ? '(ft / in)' : '(cm)'}</p>
          {isImperial ? (
            <div className="flex gap-2">
              <input type="number" value={answers.heightFt || ''} onChange={e => set('heightFt', e.target.value)}
                placeholder="ft" min={3} max={8}
                className="w-1/2 px-3 py-3 rounded-xl border text-sm outline-none"
                style={{ background: '#f9f7f3', borderColor: answers.heightFt ? 'rgba(200,224,0,0.45)' : '#e8e1d4', color: '#141613' }} />
              <input type="number" value={answers.heightIn || ''} onChange={e => set('heightIn', e.target.value)}
                placeholder="in" min={0} max={11}
                className="w-1/2 px-3 py-3 rounded-xl border text-sm outline-none"
                style={{ background: '#f9f7f3', borderColor: answers.heightIn ? 'rgba(200,224,0,0.45)' : '#e8e1d4', color: '#141613' }} />
            </div>
          ) : (
            <input type="number" value={answers.heightCmDirect || ''} onChange={e => set('heightCmDirect', e.target.value)}
              placeholder="e.g. 178" min={100} max={250}
              className="w-full px-3 py-3 rounded-xl border text-sm outline-none"
              style={{ background: '#f9f7f3', borderColor: answers.heightCmDirect ? 'rgba(200,224,0,0.45)' : '#e8e1d4', color: '#141613' }} />
          )}
        </div>
        <div>
          <p className="text-xs font-semibold mb-2" style={{ color: '#5d635d' }}>Sex <span className="font-normal" style={{ color: '#91968e' }}>(optional)</span></p>
          <div className="flex gap-2">
            {[{ id: 'male', label: '♂ Male' }, { id: 'female', label: '♀ Female' }].map(opt => (
              <button key={opt.id} onClick={() => set('sex', answers.sex === opt.id ? null : opt.id)}
                className="flex-1 py-3 rounded-xl border text-sm font-medium transition-all"
                style={{
                  background: answers.sex === opt.id ? 'rgba(200,224,0,0.1)' : '#f9f7f3',
                  borderColor: answers.sex === opt.id ? 'rgba(200,224,0,0.45)' : '#e8e1d4',
                  color: answers.sex === opt.id ? ACCENT_DARK : '#5d635d',
                }}>
                {opt.label}
              </button>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

function ScheduleDropdown({ value, onChange, accent, accentDark }) {
  const [open, setOpen] = useState(false);
  const daysSet = Object.values(value || {}).filter(arr => Array.isArray(arr) && arr.length > 0).length;
  const summary = daysSet > 0 ? `${daysSet} day${daysSet === 1 ? '' : 's'} scheduled` : 'Tap to set your weekly schedule';
  return (
    <div className="rounded-xl border overflow-hidden" style={{ background: '#ffffff', borderColor: daysSet > 0 ? 'rgba(200,224,0,0.45)' : '#e8e1d4' }}>
      <button
        type="button"
        onClick={() => setOpen(o => !o)}
        className="w-full flex items-center justify-between px-4 py-3 text-left"
      >
        <div>
          <p className="text-sm font-semibold" style={{ color: '#141613' }}>Schedule</p>
          <p className="text-xs mt-0.5" style={{ color: daysSet > 0 ? accentDark : '#91968e' }}>{summary}</p>
        </div>
        <ChevronDown size={16} style={{ color: '#91968e', transform: open ? 'rotate(180deg)' : 'none', transition: 'transform 0.2s' }} />
      </button>
      <AnimatePresence initial={false}>
        {open && (
          <motion.div
            initial={{ height: 0, opacity: 0 }}
            animate={{ height: 'auto', opacity: 1 }}
            exit={{ height: 0, opacity: 0 }}
            className="overflow-hidden"
          >
            <div className="px-3 pb-3 pt-1 border-t" style={{ borderColor: '#e8e1d4' }}>
              <SportWeekSchedule value={value} onChange={onChange} accent={accent} accentDark={accentDark} />
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}

function StepPrimarySport({ answers, set }) {
  const hasSecondSport = answers.hasSecondSport === true;

  // Auto-mark as primary sport user the moment we reach this step
  useEffect(() => {
    if (answers.hasPrimarySport !== true) set('hasPrimarySport', true);
     
  }, []);

  return (
    <div>
      <div className="mb-6">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>
          Which sport are you training for?
        </h2>
        <p className="text-sm leading-relaxed" style={{ color: '#91968e' }}>
          Execute will tailor your workouts around this sport and balance your weekly exertion so you don't over- or under-train.
        </p>
      </div>
      <div className="space-y-4">
            {/* Primary sport */}
            <div className="p-4 rounded-2xl border" style={{ background: 'rgba(200,224,0,0.04)', borderColor: 'rgba(200,224,0,0.25)' }}>
              <p className="text-[10px] font-bold uppercase tracking-widest mb-3" style={{ color: ACCENT_DARK }}>Primary Sport</p>
              <div className="space-y-3">
                <div>
                  <p className="text-xs font-semibold mb-1.5" style={{ color: '#5d635d' }}>Which sport?</p>
                  <input
                    value={answers.primarySport || ''}
                    onChange={e => set('primarySport', e.target.value)}
                    placeholder="e.g. basketball, soccer, jiu-jitsu, running…"
                    className="w-full px-4 py-3 rounded-xl border text-sm outline-none"
                    style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
                  />
                </div>
                <div>
                  <ScheduleDropdown
                    value={answers.primarySportSchedule}
                    onChange={(v) => set('primarySportSchedule', v)}
                    accent={ACCENT}
                    accentDark={ACCENT_DARK}
                  />
                </div>
                <div>
                  <p className="text-xs font-semibold mb-1.5" style={{ color: '#5d635d' }}>What do you want to improve? <span className="font-normal" style={{ color: '#91968e' }}>(optional)</span></p>
                  <textarea
                    value={answers.sportFocus || ''}
                    onChange={e => set('sportFocus', e.target.value)}
                    placeholder="e.g. top speed, explosiveness, endurance, agility…"
                    rows={2}
                    className="w-full px-4 py-3 rounded-xl border text-sm outline-none resize-none"
                    style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
                  />
                </div>
              </div>
            </div>

            {/* Add a second sport */}
            {!hasSecondSport && (
              <button
                onClick={() => set('hasSecondSport', true)}
                className="w-full flex items-center justify-center gap-1.5 py-3 rounded-xl border text-xs font-semibold transition-all"
                style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}
              >
                <Plus size={14} /> Add a second sport
              </button>
            )}

            {/* Second sport details */}
            <AnimatePresence>
              {hasSecondSport === true && (
                <motion.div
                  initial={{ opacity: 0, height: 0 }}
                  animate={{ opacity: 1, height: 'auto' }}
                  exit={{ opacity: 0, height: 0 }}
                  className="p-4 rounded-2xl border overflow-hidden"
                  style={{ background: 'rgba(93,138,168,0.06)', borderColor: 'rgba(93,138,168,0.25)' }}
                >
                  <div className="flex items-center justify-between mb-3">
                    <p className="text-[10px] font-bold uppercase tracking-widest" style={{ color: '#5d8aa8' }}>Second Sport</p>
                    <button
                      type="button"
                      onClick={() => {
                        set('hasSecondSport', false);
                        set('secondSport', '');
                        set('secondSportFocus', '');
                        set('secondSportSchedule', {});
                      }}
                      className="flex items-center gap-1 text-[10px] font-semibold px-2 py-1 rounded-lg"
                      style={{ background: 'rgba(176,90,58,0.08)', color: '#b05a3a' }}
                    >
                      <X size={11} /> Remove
                    </button>
                  </div>
                  <div className="space-y-3">
                    <div>
                      <p className="text-xs font-semibold mb-1.5" style={{ color: '#5d635d' }}>Which sport?</p>
                      <input
                        value={answers.secondSport || ''}
                        onChange={e => set('secondSport', e.target.value)}
                        placeholder="e.g. climbing, cycling, yoga…"
                        className="w-full px-4 py-3 rounded-xl border text-sm outline-none"
                        style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
                      />
                    </div>
                    <div>
                      <ScheduleDropdown
                        value={answers.secondSportSchedule}
                        onChange={(v) => set('secondSportSchedule', v)}
                        accent="#5d8aa8"
                        accentDark="#3f6a87"
                      />
                    </div>
                    <div>
                      <p className="text-xs font-semibold mb-1.5" style={{ color: '#5d635d' }}>Focus <span className="font-normal" style={{ color: '#91968e' }}>(optional)</span></p>
                      <textarea
                        value={answers.secondSportFocus || ''}
                        onChange={e => set('secondSportFocus', e.target.value)}
                        placeholder="What do you want to improve?"
                        rows={2}
                        className="w-full px-4 py-3 rounded-xl border text-sm outline-none resize-none"
                        style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
                      />
                    </div>
                  </div>
                </motion.div>
              )}
            </AnimatePresence>
      </div>
    </div>
  );
}

function StepCurrentTraining({ answers, set }) {
  return (
    <div>
      <div className="mb-6">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>How often are you training right now?</h2>
        <p className="text-sm" style={{ color: '#91968e' }}>Be honest — this helps set the right starting point.</p>
      </div>
      <div className="space-y-2">
        {CURRENT_TRAINING_OPTIONS.map(opt => (
          <OptionRow key={opt.id} selected={answers.currentTraining === opt.id}
            onClick={() => set('currentTraining', opt.id)} label={opt.label} desc={opt.desc} />
        ))}
      </div>
      <AnimatePresence>
        {answers.currentTraining && (
          <motion.div initial={{ opacity: 0, y: -4 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }} className="mt-4">
            <textarea value={answers.activityDetail || ''} onChange={e => set('activityDetail', e.target.value)}
              placeholder="What kind of training? (optional — e.g. lifting, running, classes)"
              rows={2} className="w-full px-4 py-3 rounded-xl border text-sm outline-none resize-none"
              style={{ background: '#f9f7f3', borderColor: '#e8e1d4', color: '#141613' }} />
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}

function StepTrainingDays({ answers, set }) {
  return (
    <div>
      <div className="mb-6">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>How many days a week do you want to train?</h2>
        <p className="text-sm" style={{ color: '#91968e' }}>Realistically. Not the best-case version.</p>
      </div>
      <div className="grid grid-cols-2 gap-2">
        {TRAINING_DAYS_OPTIONS.map(opt => (
          <button key={opt.id} onClick={() => set('trainingDays', opt.id)}
            className="py-4 rounded-2xl border text-sm font-bold transition-all"
            style={{
              background: answers.trainingDays === opt.id ? ACCENT : '#ffffff',
              borderColor: answers.trainingDays === opt.id ? ACCENT : '#e8e1d4',
              color: answers.trainingDays === opt.id ? '#141613' : '#5d635d',
            }}>
            {opt.label}
          </button>
        ))}
      </div>
    </div>
  );
}

function StepSessionLength({ answers, set }) {
  return (
    <div>
      <div className="mb-6">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>How long should most workouts be?</h2>
      </div>
      <div className="space-y-2">
        {SESSION_LENGTH_OPTIONS.map(opt => (
          <OptionRow key={opt.id} selected={answers.sessionLength === opt.id}
            onClick={() => set('sessionLength', opt.id)} label={opt.label} desc={opt.desc} />
        ))}
      </div>
    </div>
  );
}

function StepTrainingLocation({ answers, set }) {
  const handleSelect = (id) => {
    set('trainingLocation', id);
    // When training at a commercial gym, auto-set full gym equipment so the
    // equipment step can be safely skipped and downstream AI prompts still have a value.
    if (id === 'gym') {
      set('equipment', ['full_gym']);
    } else if (answers.trainingLocation === 'gym') {
      // Switching away from gym — clear the auto-set value so the user picks fresh
      set('equipment', []);
    }
  };
  return (
    <div>
      <div className="mb-6">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>Where will you train most often?</h2>
      </div>
      <div className="space-y-2">
        {LOCATION_OPTIONS.map(opt => (
          <OptionRow key={opt.id} selected={answers.trainingLocation === opt.id}
            onClick={() => handleSelect(opt.id)} label={opt.label} desc={opt.desc} emoji={opt.emoji} />
        ))}
      </div>
    </div>
  );
}

function StepEquipment({ answers, set }) {
  const equipment = answers.equipment || [];
  const toggle = id => set('equipment', equipment.includes(id) ? equipment.filter(x => x !== id) : [...equipment, id]);
  const isHome = answers.trainingLocation === 'home';
  const options = isHome ? EQUIPMENT_HOME : EQUIPMENT_GYM;

  return (
    <div>
      <div className="mb-6">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>What equipment do you have access to?</h2>
        <p className="text-sm" style={{ color: '#91968e' }}>Select all that apply.</p>
      </div>
      <div className="space-y-2">
        {options.map(opt => (
          <OptionRow key={opt.id} selected={equipment.includes(opt.id)}
            onClick={() => toggle(opt.id)} label={opt.label} emoji={opt.emoji} />
        ))}
      </div>
    </div>
  );
}

function StepLimitations({ answers, set }) {
  return (
    <div>
      <div className="mb-6">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>Any pain, injuries, or movements to avoid?</h2>
        <p className="text-sm leading-relaxed" style={{ color: '#91968e' }}>
          Execute can adapt workouts around limitations, but does not diagnose or treat injuries. Always consult a qualified professional for medical concerns.
        </p>
      </div>
      <div className="flex gap-2 mb-4">
        {[{ id: false, label: "✅ No, I'm good" }, { id: true, label: '⚠️ Yes, I have some' }].map(opt => (
          <button key={String(opt.id)} onClick={() => set('hasLimitations', opt.id)}
            className="flex-1 py-3.5 rounded-xl border text-sm font-medium transition-all"
            style={{
              background: answers.hasLimitations === opt.id ? 'rgba(200,224,0,0.1)' : '#ffffff',
              borderColor: answers.hasLimitations === opt.id ? 'rgba(200,224,0,0.45)' : '#e8e1d4',
              color: '#141613',
            }}>
            {opt.label}
          </button>
        ))}
      </div>
      <AnimatePresence>
        {answers.hasLimitations === true && (
          <motion.textarea
            initial={{ opacity: 0, height: 0 }} animate={{ opacity: 1, height: 'auto' }} exit={{ opacity: 0, height: 0 }}
            value={answers.limitationsDetail || ''} onChange={e => set('limitationsDetail', e.target.value)}
            placeholder="Describe your injuries or movements to avoid…" rows={3}
            className="w-full px-4 py-3 rounded-xl border text-sm outline-none resize-none"
            style={{ background: '#f9f7f3', borderColor: '#e8e1d4', color: '#141613' }} />
        )}
      </AnimatePresence>
    </div>
  );
}

function StepAggressiveness({ answers, set }) {
  return (
    <div>
      <div className="mb-6">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>How hard should the first version feel?</h2>
        <p className="text-sm" style={{ color: '#91968e' }}>You can always adjust after you start.</p>
      </div>
      <div className="space-y-2">
        {AGGRESSIVENESS_OPTIONS.map(opt => (
          <OptionRow key={opt.id} selected={answers.aggressiveness === opt.id}
            onClick={() => set('aggressiveness', opt.id)} label={opt.label} desc={opt.desc} emoji={opt.emoji} />
        ))}
      </div>
    </div>
  );
}

function StepNutritionGoal({ answers, set }) {
  return (
    <div>
      <div className="mb-6">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>What is your main nutrition goal?</h2>
      </div>
      <div className="space-y-2">
        {NUTRITION_GOAL_OPTIONS.map(opt => (
          <OptionRow key={opt.id} selected={answers.nutritionGoal === opt.id}
            onClick={() => set('nutritionGoal', opt.id)} label={opt.label} emoji={opt.emoji} />
        ))}
      </div>
    </div>
  );
}

function StepActivityLevel({ answers, set }) {
  return (
    <div>
      <div className="mb-6">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>How active is a normal week for you?</h2>
        <p className="text-sm" style={{ color: '#91968e' }}>Used to estimate your daily calorie needs accurately.</p>
      </div>
      <div className="space-y-2">
        {ACTIVITY_LEVEL_OPTIONS.map(opt => (
          <OptionRow key={opt.id} selected={answers.currentActivity === opt.id}
            onClick={() => set('currentActivity', opt.id)} label={opt.label} desc={opt.desc} />
        ))}
      </div>
    </div>
  );
}

function StepMealsPerDay({ answers, set }) {
  return (
    <div>
      <div className="mb-6">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>How many meals do you usually eat per day?</h2>
      </div>
      <div className="grid grid-cols-2 gap-3">
        {MEALS_PER_DAY_OPTIONS.map(opt => (
          <button key={opt.id} onClick={() => set('mealsPerDay', opt.id)}
            className="py-4 rounded-2xl border text-sm font-bold transition-all"
            style={{
              background: answers.mealsPerDay === opt.id ? ACCENT : '#ffffff',
              borderColor: answers.mealsPerDay === opt.id ? ACCENT : '#e8e1d4',
              color: answers.mealsPerDay === opt.id ? '#141613' : '#5d635d',
            }}>
            {opt.label}
          </button>
        ))}
      </div>
    </div>
  );
}

function StepFavoriteFoods({ answers, set }) {
  const noPref = answers.noFoodPreference === true;

  return (
    <div>
      <div className="mb-4">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>Foods you'd be happy eating often</h2>
        <p className="text-sm" style={{ color: '#91968e' }}>
          List the proteins, carbs, and fats you actually enjoy. Helps Execute build meals around foods you'll stick with.
        </p>
      </div>

      <button
        onClick={() => {
          const next = !noPref;
          set('noFoodPreference', next);
          if (next) {
            set('favoriteProteins', '');
            set('favoriteCarbs', '');
            set('favoriteFats', '');
          }
        }}
        className="w-full mb-4 py-3 rounded-xl border text-sm font-semibold transition-all"
        style={{
          background: noPref ? 'rgba(200,224,0,0.12)' : '#ffffff',
          borderColor: noPref ? 'rgba(200,224,0,0.5)' : '#e8e1d4',
          color: noPref ? ACCENT_DARK : '#5d635d',
        }}
      >
        {noPref ? '✓ No preference — surprise me' : 'No preference — surprise me'}
      </button>

      <AnimatePresence>
        {!noPref && (
          <motion.div
            initial={{ opacity: 0, height: 0 }}
            animate={{ opacity: 1, height: 'auto' }}
            exit={{ opacity: 0, height: 0 }}
            className="space-y-4 overflow-hidden"
          >
            <div>
              <p className="text-xs font-semibold mb-1.5" style={{ color: '#5d635d' }}>Proteins you enjoy</p>
              <textarea
                value={answers.favoriteProteins || ''}
                onChange={e => set('favoriteProteins', e.target.value)}
                placeholder="e.g. chicken, eggs, greek yogurt, tofu, salmon…"
                rows={2}
                className="w-full px-4 py-3 rounded-xl border text-sm outline-none resize-none"
                style={{ background: '#f9f7f3', borderColor: '#e8e1d4', color: '#141613' }}
              />
            </div>
            <div>
              <p className="text-xs font-semibold mb-1.5" style={{ color: '#5d635d' }}>Carbs you enjoy</p>
              <textarea
                value={answers.favoriteCarbs || ''}
                onChange={e => set('favoriteCarbs', e.target.value)}
                placeholder="e.g. rice, oats, potatoes, pasta, fruit…"
                rows={2}
                className="w-full px-4 py-3 rounded-xl border text-sm outline-none resize-none"
                style={{ background: '#f9f7f3', borderColor: '#e8e1d4', color: '#141613' }}
              />
            </div>
            <div>
              <p className="text-xs font-semibold mb-1.5" style={{ color: '#5d635d' }}>Fats you enjoy</p>
              <textarea
                value={answers.favoriteFats || ''}
                onChange={e => set('favoriteFats', e.target.value)}
                placeholder="e.g. avocado, olive oil, nuts, cheese…"
                rows={2}
                className="w-full px-4 py-3 rounded-xl border text-sm outline-none resize-none"
                style={{ background: '#f9f7f3', borderColor: '#e8e1d4', color: '#141613' }}
              />
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}

const DIET_STYLES = [
  { id: 'keto',          label: 'Keto',           emoji: '🥑', desc: 'Very low carb, high fat' },
  { id: 'vegan',         label: 'Vegan',           emoji: '🌱', desc: 'No animal products' },
  { id: 'vegetarian',    label: 'Vegetarian',      emoji: '🥦', desc: 'No meat or fish' },
  { id: 'pescatarian',   label: 'Pescatarian',     emoji: '🐟', desc: 'Fish, no other meat' },
  { id: 'paleo',         label: 'Paleo',           emoji: '🍖', desc: 'Whole foods, no grains or dairy' },
  { id: 'mediterranean', label: 'Mediterranean',   emoji: '🫒', desc: 'Wholegrains, fish, olive oil, veg' },
  { id: 'gluten_free',   label: 'Gluten-free',     emoji: '🌾', desc: 'No wheat, barley, or rye' },
  { id: 'dairy_free',    label: 'Dairy-free',      emoji: '🥛', desc: 'No milk, cheese, or dairy' },
  { id: 'high_protein',  label: 'High-protein',    emoji: '💪', desc: 'Protein-focused eating' },
  { id: 'intermittent_fasting', label: 'Intermittent fasting', emoji: '⏱️', desc: 'Time-restricted eating window' },
];

function StepFoodsToAvoid({ answers, set }) {
  const selectedDiets = answers.dietStyles || [];
  const toggleDiet = id => set('dietStyles', selectedDiets.includes(id) ? selectedDiets.filter(x => x !== id) : [...selectedDiets, id]);

  return (
    <div>
      <div className="mb-5">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>Any food or dietary restrictions you?</h2>
        <p className="text-sm" style={{ color: '#91968e' }}>Optional — skip if none.</p>
      </div>
      <div className="space-y-4">
        {/* Diet styles */}
        <div>
          <p className="text-xs font-semibold mb-2" style={{ color: '#5d635d' }}>Dietary style <span className="font-normal" style={{ color: '#91968e' }}>(select all that apply)</span></p>
          <div className="flex flex-wrap gap-2">
            {DIET_STYLES.map(opt => {
              const isSelected = selectedDiets.includes(opt.id);
              return (
                <button
                  key={opt.id}
                  onClick={() => toggleDiet(opt.id)}
                  className="flex items-center gap-1.5 px-3 py-2 rounded-xl border text-sm font-medium transition-all"
                  style={{
                    background: isSelected ? 'rgba(200,224,0,0.12)' : '#ffffff',
                    borderColor: isSelected ? 'rgba(200,224,0,0.5)' : '#e8e1d4',
                    color: isSelected ? ACCENT_DARK : '#141613',
                  }}
                >
                  <span>{opt.emoji}</span>
                  {opt.label}
                  {isSelected && <Check size={11} style={{ color: ACCENT_DARK }} />}
                </button>
              );
            })}
          </div>
        </div>
        {/* Allergies */}
        <div>
          <p className="text-xs font-semibold mb-1.5" style={{ color: '#5d635d' }}>Allergies or medical restrictions</p>
          <textarea value={answers.allergies || ''} onChange={e => set('allergies', e.target.value)}
            placeholder="e.g. nuts, shellfish, gluten, dairy…" rows={2}
            className="w-full px-4 py-3 rounded-xl border text-sm outline-none resize-none"
            style={{ background: '#f9f7f3', borderColor: '#e8e1d4', color: '#141613' }} />
        </div>
        {/* Dislikes */}
        <div>
          <p className="text-xs font-semibold mb-1.5" style={{ color: '#5d635d' }}>Foods I dislike or prefer not to eat</p>
          <textarea value={answers.foodsToAvoid || ''} onChange={e => set('foodsToAvoid', e.target.value)}
            placeholder="e.g. broccoli, lamb…" rows={2}
            className="w-full px-4 py-3 rounded-xl border text-sm outline-none resize-none"
            style={{ background: '#f9f7f3', borderColor: '#e8e1d4', color: '#141613' }} />
        </div>
      </div>
    </div>
  );
}

function StepNutritionStruggles({ answers, set }) {
  const struggles = answers.struggles || [];
  const toggle = s => set('struggles', struggles.includes(s) ? struggles.filter(x => x !== s) : [...struggles, s]);

  return (
    <div>
      <div className="mb-6">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>What usually gets in the way of eating well?</h2>
        <p className="text-sm" style={{ color: '#91968e' }}>Optional. Select all that apply.</p>
      </div>
      <div className="flex flex-wrap gap-2">
        {STRUGGLES.map(s => (
          <button key={s} onClick={() => toggle(s)}
            className="px-3.5 py-2 rounded-xl border text-sm font-medium transition-all"
            style={{
              background: struggles.includes(s) ? 'rgba(176,90,58,0.1)' : '#f2efe7',
              borderColor: struggles.includes(s) ? 'rgba(176,90,58,0.35)' : '#e8e1d4',
              color: struggles.includes(s) ? '#b05a3a' : '#5d635d',
            }}>
            {struggles.includes(s) && '✓ '}{s}
          </button>
        ))}
      </div>
    </div>
  );
}

function StepAdditionalNotes({ answers, set }) {
  return (
    <div>
      <div className="mb-6">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>Anything important Execute should know?</h2>
        <p className="text-sm" style={{ color: '#91968e' }}>Optional. Travel schedule, upcoming events, specific constraints…</p>
      </div>
      <textarea value={answers.additionalNotes || ''} onChange={e => set('additionalNotes', e.target.value)}
        placeholder="e.g. 'I travel a lot for work', 'Competition in 6 weeks', 'Need morning-only sessions'…"
        rows={5} className="w-full px-4 py-3 rounded-xl border text-sm outline-none resize-none"
        style={{ background: '#f9f7f3', borderColor: '#e8e1d4', color: '#141613' }} />
    </div>
  );
}

function StepDesiredOutcome({ answers, set }) {
  const selected = answers.desiredOutcomeFeeling
    ? (Array.isArray(answers.desiredOutcomeFeeling) ? answers.desiredOutcomeFeeling : [answers.desiredOutcomeFeeling])
    : [];
  const toggle = id => {
    const next = selected.includes(id) ? selected.filter(x => x !== id) : [...selected, id];
    set('desiredOutcomeFeeling', next);
  };
  return (
    <div>
      <div className="mb-6">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>What outcome matters most to you?</h2>
        <p className="text-sm" style={{ color: '#91968e' }}>This shapes how Execute writes your personal performance plan. Select all that apply.</p>
      </div>
      <div className="space-y-2">
        {DESIRED_OUTCOME_OPTIONS.map(opt => (
          <OptionRow key={opt.id} selected={selected.includes(opt.id)}
            onClick={() => toggle(opt.id)} label={opt.label} emoji={opt.emoji} />
        ))}
      </div>
    </div>
  );
}

function StepMainBarrier({ answers, set }) {
  const selected = Array.isArray(answers.mainBarrier)
    ? answers.mainBarrier
    : (answers.mainBarrier ? [answers.mainBarrier] : []);
  const toggle = id => {
    const next = selected.includes(id) ? selected.filter(x => x !== id) : [...selected, id];
    set('mainBarrier', next);
  };
  return (
    <div>
      <div className="mb-6">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>What usually gets in the way?</h2>
        <p className="text-sm" style={{ color: '#91968e' }}>Select all that apply. Execute will build your plan around these so it actually sticks.</p>
      </div>
      <div className="space-y-2">
        {MAIN_BARRIER_OPTIONS.map(opt => (
          <OptionRow key={opt.id} selected={selected.includes(opt.id)}
            onClick={() => toggle(opt.id)} label={opt.label} emoji={opt.emoji} />
        ))}
      </div>
    </div>
  );
}

function StepCoachingStyle({ answers, set }) {
  return (
    <div>
      <div className="mb-6">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>How do you want to be coached?</h2>
        <p className="text-sm" style={{ color: '#91968e' }}>Sets the tone of your plan and daily guidance.</p>
      </div>
      <div className="space-y-2">
        {COACHING_STYLE_OPTIONS.map(opt => (
          <OptionRow key={opt.id} selected={answers.coachingStyle === opt.id}
            onClick={() => set('coachingStyle', opt.id)} label={opt.label} desc={opt.desc} emoji={opt.emoji} />
        ))}
      </div>
    </div>
  );
}

// ─── BYO ("Input your own plan") steps ────────────────────────────────────────

function StepByoScope({ answers, set }) {
  return (
    <div className="space-y-3">
      <div className="mb-6">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>
          What are you bringing yourself?
        </h2>
        <p className="text-sm leading-relaxed" style={{ color: '#91968e' }}>
          Execute structures what you provide and builds the other side around it.
        </p>
      </div>
      {BYO_SCOPE_OPTIONS.map(opt => (
        <OptionRow key={opt.id} selected={answers.byoScope === opt.id}
          onClick={() => set('byoScope', opt.id)} label={opt.label} desc={opt.desc} emoji={opt.emoji} />
      ))}
    </div>
  );
}

// Auto-growing paste sheet with PDF upload, shared by workout + meal steps.
function ByoPasteSheet({ side, value, onChange, title, subtitle, placeholder }) {
  const taRef = useRef(null);
  const fileRef = useRef(null);
  const [savedState, setSavedState] = useState('idle'); // idle | saving | saved
  const [pdfState, setPdfState] = useState('idle');      // idle | extracting | needs_choice | processing | error
  const [pdfFile, setPdfFile] = useState(null);
  const [pdfError, setPdfError] = useState('');

  // Auto-grow the textarea to fit content.
  useEffect(() => {
    const el = taRef.current;
    if (!el) return;
    el.style.height = 'auto';
    el.style.height = `${Math.min(el.scrollHeight, 520)}px`;
  }, [value]);

  // Cosmetic "Saved" chip — the real durable write is debounced in the parent.
  useEffect(() => {
    if (!value) { setSavedState('idle'); return; }
    setSavedState('saving');
    const t = setTimeout(() => setSavedState('saved'), 700);
    return () => clearTimeout(t);
  }, [value]);

  const handleFile = async (file) => {
    if (!file) return;
    setPdfError('');
    setPdfFile(file);
    setPdfState('extracting');
    try {
      const { text, sufficient } = await extractPdfTextClient(file);
      if (sufficient) {
        onChange(text);
        setPdfState('idle');
        setPdfFile(null);
      } else {
        // Insufficient/garbled — do not auto-send. Offer a one-tap choice.
        setPdfState('needs_choice');
      }
    } catch {
      setPdfState('needs_choice');
    }
  };

  const handleProcessWithAI = async () => {
    if (!pdfFile) return;
    setPdfState('processing');
    setPdfError('');
    try {
      const { text, sufficient } = await processPdfWithAI(pdfFile, side);
      if (text && sufficient) {
        onChange(text);
        setPdfState('idle');
        setPdfFile(null);
      } else if (text) {
        // Some text came back but it's thin — let it through; structuring will
        // clarify if needed.
        onChange(text);
        setPdfState('idle');
        setPdfFile(null);
      } else {
        setPdfState('error');
        setPdfError("We couldn't read that PDF. Please paste the text instead.");
      }
    } catch (e) {
      setPdfState('error');
      setPdfError(e?.message || "We couldn't read that PDF. Please paste the text instead.");
    }
  };

  const handlePasteManually = () => {
    setPdfState('idle');
    setPdfFile(null);
    setPdfError('');
    taRef.current?.focus();
  };

  return (
    <div>
      <div className="mb-5">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>{title}</h2>
        <p className="text-sm leading-relaxed" style={{ color: '#91968e' }}>{subtitle}</p>
      </div>

      <div className="relative">
        <textarea
          ref={taRef}
          value={value || ''}
          onChange={e => onChange(e.target.value)}
          placeholder={placeholder}
          rows={8}
          className="w-full px-4 py-3 rounded-xl border text-sm outline-none resize-none"
          style={{ background: '#f9f7f3', borderColor: '#e8e1d4', color: '#141613', minHeight: 200 }}
        />
        {savedState === 'saved' && (
          <span className="absolute bottom-2 right-3 text-[11px] font-semibold flex items-center gap-1"
            style={{ color: '#8ea400' }}>
            <Check size={11} /> Saved
          </span>
        )}
      </div>

      <input
        ref={fileRef}
        type="file"
        accept="application/pdf"
        className="hidden"
        onChange={e => handleFile(e.target.files?.[0])}
      />

      {pdfState === 'extracting' || pdfState === 'processing' ? (
        <div className="mt-3 flex items-center gap-2 text-sm" style={{ color: '#5d635d' }}>
          <Loader2 size={15} className="animate-spin" />
          {pdfState === 'processing' ? 'Reading your PDF with AI…' : 'Reading your PDF…'}
        </div>
      ) : pdfState === 'needs_choice' ? (
        <div className="mt-3 p-3 rounded-xl border" style={{ background: '#fbfaf6', borderColor: '#e8e1d4' }}>
          <p className="text-xs mb-2.5" style={{ color: '#5d635d' }}>
            We couldn't reliably read text from that PDF (it may be scanned). Process it with AI, or paste the text yourself.
          </p>
          <div className="flex gap-2">
            <button onClick={handleProcessWithAI}
              className="flex-1 py-2.5 rounded-xl text-xs font-bold" style={{ background: ACCENT, color: '#141613' }}>
              Process with AI
            </button>
            <button onClick={handlePasteManually}
              className="flex-1 py-2.5 rounded-xl text-xs font-bold border" style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}>
              Paste manually
            </button>
          </div>
        </div>
      ) : (
        <button
          type="button"
          onClick={() => fileRef.current?.click()}
          className="mt-3 w-full flex items-center justify-center gap-2 py-3 rounded-xl border text-sm font-semibold"
          style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}
        >
          <Upload size={15} /> Upload PDF
        </button>
      )}

      {pdfError && <p className="mt-2 text-xs" style={{ color: '#b05a3a' }}>{pdfError}</p>}
    </div>
  );
}

function StepByoWorkoutInput({ answers, set }) {
  return (
    <ByoPasteSheet
      side="workout"
      value={answers.byoWorkoutText}
      onChange={v => set('byoWorkoutText', v)}
      title="Your training plan"
      subtitle="Paste your workout plan, or upload it as a PDF. Include days, exercises, sets/reps — whatever you have."
      placeholder="e.g. Day 1 — Push: Bench 4x8, Incline DB 3x10…"
    />
  );
}

function StepByoMealInput({ answers, set }) {
  return (
    <ByoPasteSheet
      side="nutrition"
      value={answers.byoMealText}
      onChange={v => set('byoMealText', v)}
      title="Your meal plan"
      subtitle="Paste your nutrition plan, or upload it as a PDF. Include meals, macros, calories — whatever you have."
      placeholder="e.g. 2400 kcal, 200g protein. Breakfast: oats + eggs…"
    />
  );
}

function StepByoStructuring({ answers, set }) {
  const targets = byoTargets(answers);
  const [phase, setPhase] = useState('loading'); // loading | clarify | error | done
  const [questions, setQuestions] = useState([]);
  const [picks, setPicks] = useState({});        // questionId -> optionId
  const roundsRef = useRef(0);
  const clarRef = useRef([]);                     // accumulated answered clarifications
  const runningRef = useRef(false);

  const fallbackAll = useCallback(() => {
    const side = targets.length === 2 ? 'both' : targets[0];
    set('byoStructured', { resolved: true, fallback: side });
    setPhase('done');
  }, [set, targets]);

  const run = useCallback(async (clarificationAnswers) => {
    if (runningRef.current) return;
    runningRef.current = true;
    setPhase('loading');
    try {
      const res = await structurePastedPlan({
        byoWorkoutText: answers.byoWorkoutText || '',
        byoMealText: answers.byoMealText || '',
        byoTargets: targets,
        clarificationAnswers,
      });
      if (res?.needs_clarification && Array.isArray(res?.clarification?.questions) && res.clarification.questions.length > 0) {
        roundsRef.current += 1;
        // Auto-trip to graceful fallback after 2 unproductive rounds.
        if (roundsRef.current > 2) {
          fallbackAll();
          return;
        }
        setQuestions(res.clarification.questions);
        setPicks({});
        setPhase('clarify');
      } else {
        const structured = res?.structured || null;
        const cadence = structured?.workout?.cadence || null;
        set('byoStructured', { resolved: true, structured, cadence });
        setPhase('done');
      }
    } catch {
      setPhase('error');
    } finally {
      runningRef.current = false;
    }
  }, [answers.byoWorkoutText, answers.byoMealText, targets, set, fallbackAll]);

  // Kick the structuring call on entry.
  useEffect(() => {
    run([]);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const allPicked = questions.length > 0 && questions.every(q => picks[q.id]);

  const submitClarifications = () => {
    const answered = questions.map(q => {
      const opt = q.options.find(o => o.id === picks[q.id]);
      return { id: q.id, side: q.side, label: q.label, answerId: picks[q.id], answerLabel: opt?.label || '' };
    });
    clarRef.current = [...clarRef.current, ...answered];
    run(clarRef.current);
  };

  if (phase === 'loading') {
    return (
      <div className="py-10 flex flex-col items-center text-center">
        <Loader2 size={28} className="animate-spin mb-4" style={{ color: ACCENT_DARK }} />
        <h2 className="text-lg font-black tracking-tight mb-1" style={{ color: '#141613' }}>
          Structuring your plan…
        </h2>
        <p className="text-sm" style={{ color: '#91968e' }}>Reading what you provided so we can reproduce it faithfully.</p>
      </div>
    );
  }

  if (phase === 'error') {
    return (
      <div className="py-8 text-center">
        <h2 className="text-lg font-black tracking-tight mb-1" style={{ color: '#141613' }}>Something went wrong</h2>
        <p className="text-sm mb-5" style={{ color: '#91968e' }}>We couldn't structure your plan just now.</p>
        <div className="flex flex-col gap-2">
          <button onClick={() => run(clarRef.current)}
            className="w-full py-3 rounded-xl text-sm font-bold" style={{ background: ACCENT, color: '#141613' }}>
            Try again
          </button>
          <button onClick={fallbackAll}
            className="w-full py-3 rounded-xl text-sm font-bold border" style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}>
            Use a standard plan instead
          </button>
        </div>
      </div>
    );
  }

  if (phase === 'done') {
    return (
      <div className="py-10 flex flex-col items-center text-center">
        <div className="w-12 h-12 rounded-full flex items-center justify-center mb-4" style={{ background: ACCENT }}>
          <Check size={24} style={{ color: '#141613' }} />
        </div>
        <h2 className="text-lg font-black tracking-tight mb-1" style={{ color: '#141613' }}>You're all set</h2>
        <p className="text-sm" style={{ color: '#91968e' }}>Tap Generate My Plan below to build it.</p>
      </div>
    );
  }

  // clarify
  return (
    <div>
      <div className="mb-5">
        <h2 className="text-xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>A few quick questions</h2>
        <p className="text-sm" style={{ color: '#91968e' }}>
          Your plan was a little sparse in places. Pick what fits so we can build it accurately.
        </p>
      </div>
      <div className="space-y-5">
        {questions.map(q => (
          <div key={q.id}>
            <p className="text-sm font-semibold mb-2" style={{ color: '#141613' }}>{q.label}</p>
            <div className="space-y-2">
              {q.options.map(o => (
                <OptionRow key={o.id} selected={picks[q.id] === o.id}
                  onClick={() => setPicks(p => ({ ...p, [q.id]: o.id }))} label={o.label} />
              ))}
            </div>
          </div>
        ))}
      </div>
      <button
        onClick={submitClarifications}
        disabled={!allPicked}
        className="mt-6 w-full py-3.5 rounded-2xl text-sm font-bold flex items-center justify-center gap-2"
        style={{ background: allPicked ? ACCENT : '#e8e1d4', color: allPicked ? '#141613' : '#91968e' }}
      >
        Continue <ArrowRight size={15} />
      </button>
      <button onClick={fallbackAll}
        className="mt-3 w-full py-3 rounded-xl text-xs font-semibold" style={{ color: '#91968e' }}>
        Use a standard plan instead
      </button>
    </div>
  );
}

const STEP_COMPONENTS = {
  planType: StepPlanType,
  byoScope: StepByoScope,
  byoWorkoutInput: StepByoWorkoutInput,
  byoMealInput: StepByoMealInput,
  byoStructuring: StepByoStructuring,
  goals: StepGoals,
  optimize: StepOptimize,
  bodyStats: StepBodyStats,
  primarySport: StepPrimarySport,
  currentTraining: StepCurrentTraining,
  trainingDays: StepTrainingDays,
  sessionLength: StepSessionLength,
  trainingLocation: StepTrainingLocation,
  equipment: StepEquipment,
  limitations: StepLimitations,
  aggressiveness: StepAggressiveness,
  activityLevel: StepActivityLevel,
  mealsPerDay: StepMealsPerDay,
  favoriteFoods: StepFavoriteFoods,
  supplements: SupplementsPicker,
  foodsToAvoid: StepFoodsToAvoid,
  nutritionStruggles: StepNutritionStruggles,
  desiredOutcome: StepDesiredOutcome,
  mainBarrier: StepMainBarrier,
  coachingStyle: StepCoachingStyle,
  additionalNotes: StepAdditionalNotes,
};

// Steps where a single selection completes the step (no multi-select)
const SINGLE_CHOICE_STEPS = new Set([
  'planType', 'byoScope', 'optimize', 'currentTraining', 'trainingDays', 'sessionLength',
  'trainingLocation', 'aggressiveness', 'mealsPerDay',
  'coachingStyle',
]);

const DEVELOPER_SUPPLEMENT_PRESET = ['protein', 'performance', 'energy', 'health', 'vitamins'];

const DEVELOPER_SOCCER_SCHEDULE = {
  mon: ['team'],
  tue: ['team'],
  wed: ['team'],
  thu: ['team'],
  fri: ['team'],
  sat: [],
  sun: [],
};

function cloneSchedule(schedule) {
  return Object.fromEntries(
    Object.entries(schedule).map(([day, sessions]) => [day, Array.isArray(sessions) ? [...sessions] : []])
  );
}

function buildDeveloperPresetAnswers(imperial, base = {}) {
  return {
    ...base,
    name: 'Evan',
    planType: 'daily_performance',
    goals: ['build_muscle', 'get_stronger', 'improve_flexibility'],
    goalOther: '',
    optimize: 'fastest',
    age: '20',
    weightDisplay: imperial ? '180' : String(lbsToKg(180)),
    heightFt: imperial ? '6' : '',
    heightIn: imperial ? '0' : '',
    heightCmDirect: imperial ? '' : String(ftInToCm(6, 0)),
    sex: 'male',
    currentActivity: 'daily',
    currentTraining: '5_plus',
    activityDetail: 'I play soccer 5 days a week and gym 6 days a week.',
    trainingDays: 'seven_plus',
    sessionLength: 'best',
    trainingLocation: 'gym',
    equipment: ['full_gym'],
    hasLimitations: false,
    limitationsDetail: '',
    aggressiveness: 'hard',
    nutritionGoal: 'build_muscle',
    mealsPerDay: '4',
    dietStyles: [],
    allergies: '',
    foodsToAvoid: '',
    selectedFoods: [],
    favoriteProteins: '',
    favoriteCarbs: '',
    favoriteFats: '',
    noFoodPreference: true,
    supplements: [...DEVELOPER_SUPPLEMENT_PRESET],
    supplementsNotes: '',
    noSupplements: false,
    desiredOutcomeFeeling: ['look_fitter', 'feel_stronger'],
    mainBarrier: ['unsure_what_todo'],
    struggles: [],
    coachingStyle: 'ruthless',
    additionalNotes: 'I want to get as strong and big as I physically can as fast as I physically can',
    hasPrimarySport: true,
    primarySport: 'Soccer',
    sportFocus: 'Get stronger, bigger, more athletic, and more flexible while playing soccer 5 days a week.',
    primarySportSchedule: cloneSchedule(DEVELOPER_SOCCER_SCHEDULE),
    hasSecondSport: false,
    secondSport: '',
    secondSportFocus: '',
    secondSportSchedule: {},
  };
}

function buildSubmitPayload(sourceAnswers, imperial) {
  const answers = sourceAnswers || {};

  // Resolve metric values
  const resolvedHeightCm = imperial
    ? (answers.heightFt || answers.heightIn ? ftInToCm(answers.heightFt || 0, answers.heightIn || 0) : '')
    : (answers.heightCmDirect || '');
  const resolvedWeightKg = imperial
    ? (answers.weightDisplay ? lbsToKg(Number(answers.weightDisplay)) : '')
    : (answers.weightDisplay || '');

  // Resolve goal string
  const goals = answers.goals || [];
  const effectiveGoals = goals.includes('other') && answers.goalOther?.trim()
    ? [...goals.filter(g => g !== 'other'), answers.goalOther.trim()]
    : goals.filter(g => g !== 'other');

  // Map desiredActivity from training days range
  const trainingDaysToDesired = {
    '2_or_less': 'light',
    '3_5': 'high',
    '5_7': 'full',
    'seven_plus': 'full',
  };
  const desiredActivity = trainingDaysToDesired[answers.trainingDays] || null;

  // Map session length to minutes
  const sessionLengthMap = { '20': 20, '30': 30, '45': 45, '60': 60, '75': 75, 'best': 50 };
  const sessionDurationMin = sessionLengthMap[answers.sessionLength] || 50;

  // Map current training to currentActivity field (for TDEE)
  const trainingToActivity = {
    never: 'monthly',
    '1_2_days': '2x_week',
    '3_4_days': '4x_week',
    '5_plus': 'daily',
  };
  const currentActivity = answers.currentActivity || trainingToActivity[answers.currentTraining] || null;

  // Merge allergies into foodsToAvoid
  const combinedAvoid = [answers.allergies, answers.foodsToAvoid]
    .filter(Boolean).join(', ');

  // Aggregate favorite proteins / carbs / fats into selectedFoods (backward compatible)
  const aggregatedFoods = answers.noFoodPreference
    ? []
    : [answers.favoriteProteins, answers.favoriteCarbs, answers.favoriteFats]
        .filter(s => typeof s === 'string' && s.trim())
        .join(', ')
        .split(/[,\n]/)
        .map(s => s.trim())
        .filter(Boolean);

  // Preserve arrays so the AI prompt builder can map each ID to a label.
  const desiredOutcomeArr = Array.isArray(answers.desiredOutcomeFeeling)
    ? answers.desiredOutcomeFeeling
    : (answers.desiredOutcomeFeeling ? [answers.desiredOutcomeFeeling] : []);
  const mainBarrierArr = Array.isArray(answers.mainBarrier)
    ? answers.mainBarrier
    : (answers.mainBarrier ? [answers.mainBarrier] : []);

  // BYO ("Input your own plan") — the planType === 'custom' guard is the stale-text
  // guard: back-navigating and switching plan type drops paste text + structuring.
  const isCustom = answers.planType === 'custom';

  return {
    name: answers.name,
    planType: answers.planType,
    byoScope: isCustom ? (answers.byoScope || null) : null,
    byoTargets: isCustom ? byoTargets(answers) : [],
    byoWorkoutText: isCustom ? (answers.byoWorkoutText || '') : '',
    byoMealText: isCustom ? (answers.byoMealText || '') : '',
    byoStructured: isCustom ? (answers.byoStructured || null) : null,
    goal: effectiveGoals.join(', '),
    optimize: answers.optimize,
    desiredOutcomeFeeling: desiredOutcomeArr,
    mainBarrier: mainBarrierArr,
    coachingStyle: answers.coachingStyle,
    age: answers.age,
    heightCm: resolvedHeightCm,
    weightKg: resolvedWeightKg,
    sex: answers.sex,
    currentActivity,
    currentTraining: answers.currentTraining,
    activityDetail: answers.activityDetail,
    desiredActivity,
    trainingDays: answers.trainingDays,
    sessionLength: answers.sessionLength,
    sessionDurationMin,
    trainingLocation: answers.trainingLocation,
    aggressiveness: answers.aggressiveness,
    primarySport: answers.hasPrimarySport ? (answers.primarySport || '').trim() : '',
    sportFocus: answers.hasPrimarySport ? (answers.sportFocus || '').trim() : '',
    primarySportSchedule: answers.hasPrimarySport ? (answers.primarySportSchedule || {}) : {},
    hasPrimarySport: answers.hasPrimarySport === true,
    secondSport: answers.hasPrimarySport && answers.hasSecondSport ? (answers.secondSport || '').trim() : '',
    secondSportFocus: answers.hasPrimarySport && answers.hasSecondSport ? (answers.secondSportFocus || '').trim() : '',
    secondSportSchedule: answers.hasPrimarySport && answers.hasSecondSport ? (answers.secondSportSchedule || {}) : {},
    hasSecondSport: answers.hasPrimarySport === true && answers.hasSecondSport === true,
    equipment: answers.equipment || [],
    hasLimitations: answers.hasLimitations,
    limitationsDetail: answers.limitationsDetail,
    nutritionGoal: answers.nutritionGoal,
    mealsPerDay: answers.mealsPerDay,
    selectedFoods: aggregatedFoods.length > 0 ? aggregatedFoods : (answers.selectedFoods || []),
    favoriteProteins: answers.noFoodPreference ? '' : (answers.favoriteProteins || ''),
    favoriteCarbs: answers.noFoodPreference ? '' : (answers.favoriteCarbs || ''),
    favoriteFats: answers.noFoodPreference ? '' : (answers.favoriteFats || ''),
    noFoodPreference: answers.noFoodPreference === true,
    supplements: answers.noSupplements ? [] : (answers.supplements || []),
    supplementsNotes: answers.noSupplements ? '' : (answers.supplementsNotes || ''),
    noSupplements: answers.noSupplements === true,
    dietStyles: answers.dietStyles || [],
    foodsToAvoid: combinedAvoid,
    allergies: answers.allergies,
    struggles: answers.struggles || [],
    additionalNotes: answers.additionalNotes,
  };
}

// ─── Main component ───────────────────────────────────────────────────────────

export default function PlanQuestionnaire({ onSubmit, initialAnswers = {}, skipStepIds = [], initialStep = 0 }) {
  const unitSystem = getUnitSystem();
  const isImperial = unitSystem === 'imperial';

  function normalizeInitialAnswers(init, imperial) {
    const base = { ...init };
    if (init?.heightCm && imperial) {
      const { ft, inches } = cmToFtIn(init.heightCm);
      base.heightFt = String(ft);
      base.heightIn = String(inches);
    } else if (init?.heightCm) {
      base.heightCmDirect = String(init.heightCm);
    }
    if (init?.weightKg) {
      base.weightDisplay = imperial ? String(kgToLbs(init.weightKg)) : String(init.weightKg);
    }
    return base;
  }

  const [answers, setAnswers] = useState(() => normalizeInitialAnswers(initialAnswers, isImperial));

  // Re-merge when initialAnswers arrive asynchronously (e.g. from Plan page loading profile defaults)
  const prevInitRef = useRef(initialAnswers);
  useEffect(() => {
    if (prevInitRef.current === initialAnswers) return;
    prevInitRef.current = initialAnswers;
    const normalized = normalizeInitialAnswers(initialAnswers, isImperial);
    setAnswers(prev => {
      // Only overwrite fields that are not yet set by the user
      const merged = { ...normalized };
      Object.keys(prev).forEach(k => {
        if (prev[k] !== null && prev[k] !== undefined && prev[k] !== '' &&
            !(Array.isArray(prev[k]) && prev[k].length === 0)) {
          merged[k] = prev[k];
        }
      });
      return merged;
    });
  }, [initialAnswers, isImperial]);

  const [currentStep, setCurrentStep] = useState(initialStep || 0);
  const buttonRef = useRef(null);
  const containerRef = useRef(null);

  // Auto-save answers + current step to sessionStorage so navigating away doesn't lose progress
  useEffect(() => {
    savePendingAnswers(answers, currentStep);
  }, [answers, currentStep]);

  // BYO: restore a durable draft on mount (survives a true iOS hard-close, which
  // wipes sessionStorage). Seed only fields the user hasn't already filled in.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const draft = await loadByoDraft();
      if (cancelled || !draft) return;
      setAnswers(prev => {
        const next = { ...prev };
        if (!prev.byoScope && draft.byoScope) next.byoScope = draft.byoScope;
        if (!(prev.byoWorkoutText || '').trim() && draft.byoWorkoutText) next.byoWorkoutText = draft.byoWorkoutText;
        if (!(prev.byoMealText || '').trim() && draft.byoMealText) next.byoMealText = draft.byoMealText;
        return next;
      });
    })();
    return () => { cancelled = true; };
  }, []);

  // BYO: debounce-persist the durable draft as the user types / picks scope.
  useEffect(() => {
    if (answers.planType !== 'custom') return undefined;
    const t = setTimeout(() => {
      saveByoDraft({
        byoScope: answers.byoScope,
        byoWorkoutText: answers.byoWorkoutText,
        byoMealText: answers.byoMealText,
      });
    }, 600);
    return () => clearTimeout(t);
  }, [answers.planType, answers.byoScope, answers.byoWorkoutText, answers.byoMealText]);

  // Scroll to top of the scrollable overlay whenever the step changes
  useEffect(() => {
    if (!containerRef.current) return;
    let el = containerRef.current.parentElement;
    while (el && el !== document.body) {
      const style = window.getComputedStyle(el);
      if (/auto|scroll/.test(style.overflow + style.overflowY)) {
        el.scrollTo({ top: 0, behavior: 'smooth' });
        return;
      }
      el = el.parentElement;
    }
  }, [currentStep]);

  // Recompute visible questions each render — filter by applicability AND skip list
  const skipped = new Set(skipStepIds || []);
  const visibleQuestions = QUESTION_FLOW.filter(q => q.applies(answers) && !skipped.has(q.id));
  const totalSteps = visibleQuestions.length;
  const currentQuestion = visibleQuestions[currentStep];

  const set = useCallback((key, value) => {
    setAnswers(prev => {
      const newAnswers = { ...prev, [key]: value };
      if (currentQuestion && SINGLE_CHOICE_STEPS.has(currentQuestion.id) && isStepComplete(currentQuestion.id, newAnswers)) {
        setTimeout(() => {
          if (!buttonRef.current) return;
          // Find the nearest scrollable ancestor and scroll to the bottom
          let el = buttonRef.current.parentElement;
          while (el && el !== document.body) {
            const style = window.getComputedStyle(el);
            const overflow = style.overflow + style.overflowY;
            if (/auto|scroll/.test(overflow)) {
              el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' });
              return;
            }
            el = el.parentElement;
          }
          // Fallback: scroll within the window
          buttonRef.current.scrollIntoView({ behavior: 'smooth', block: 'end' });
        }, 150);
      }
      return newAnswers;
    });
  }, [currentQuestion]);
  const isLastStep = currentStep === totalSteps - 1;
  const canProceed = currentQuestion ? isStepComplete(currentQuestion.id, answers) : true;

  const handleNext = () => {
    if (isLastStep) {
      handleSubmit();
    } else {
      setCurrentStep(s => s + 1);
    }
  };

  const handleBack = () => {
    if (currentStep > 0) setCurrentStep(s => s - 1);
  };

  const handleSubmit = () => {
    onSubmit(buildSubmitPayload(answers, isImperial));
  };

  const handleDeveloperPresetSubmit = () => {
    const presetAnswers = buildDeveloperPresetAnswers(isImperial, answers);
    const presetVisibleQuestions = QUESTION_FLOW.filter(q => q.applies(presetAnswers) && !skipped.has(q.id));
    const presetStep = Math.max(presetVisibleQuestions.length - 1, 0);

    setAnswers(presetAnswers);
    setCurrentStep(presetStep);
    savePendingAnswers(presetAnswers, presetStep);
    onSubmit(buildSubmitPayload(presetAnswers, isImperial));
  };

  const StepComponent = currentQuestion ? STEP_COMPONENTS[currentQuestion.id] : null;
  const progressPct = totalSteps > 1 ? (currentStep / (totalSteps - 1)) * 100 : 100;

  return (
    <div ref={containerRef} className="flex flex-col min-h-0">
      {/* Progress bar */}
      <div className="mb-6">
        <div className="flex items-center justify-between mb-2">
          <span className="text-xs font-semibold" style={{ color: '#91968e' }}>
            {currentStep + 1} of {totalSteps}
          </span>
          {currentStep > 0 && (
            <button onClick={handleBack}
              className="flex items-center gap-1 text-xs font-semibold px-3 py-1.5 rounded-xl border"
              style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}>
              <ChevronLeft size={12} /> Back
            </button>
          )}
        </div>
        <div className="h-1.5 rounded-full overflow-hidden" style={{ background: '#e8e1d4' }}>
          <motion.div className="h-full rounded-full" style={{ background: ACCENT }}
            animate={{ width: `${progressPct}%` }} transition={{ duration: 0.35 }} />
        </div>
      </div>

      {/* Step content */}
      <AnimatePresence mode="wait">
        {StepComponent && (
          <motion.div
            key={currentQuestion.id}
            initial={{ opacity: 0, x: 20 }}
            animate={{ opacity: 1, x: 0 }}
            exit={{ opacity: 0, x: -20 }}
            transition={{ duration: 0.22 }}
          >
            <StepComponent
              answers={answers}
              set={set}
              onDeveloperPreset={handleDeveloperPresetSubmit}
            />
          </motion.div>
        )}
      </AnimatePresence>

      {/* CTA */}
      <div className="mt-8" ref={buttonRef}>
        <motion.button
          whileTap={{ scale: 0.97 }}
          onClick={handleNext}
          disabled={!canProceed}
          className="w-full py-4 rounded-2xl text-sm font-bold flex items-center justify-center gap-2 transition-all"
          style={{
            background: canProceed ? ACCENT : '#e8e1d4',
            color: canProceed ? '#141613' : '#91968e',
          }}
        >
          {isLastStep ? (
            <><Sparkles size={15} /> Generate My Plan</>
          ) : (
            <>Continue <ArrowRight size={15} /></>
          )}
        </motion.button>
      </div>
    </div>
  );
}
