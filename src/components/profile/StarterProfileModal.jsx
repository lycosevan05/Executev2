import { useState, useEffect } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { X, Check, Loader2, ChevronRight, ChevronLeft } from 'lucide-react';
import {
  saveUserProfile,
  saveWorkoutProfile,
  saveNutritionProfile,
  loadActivePlan,
} from '@/lib/personalizationSync';
import { backend } from '@/api/backendClient';
import { estimateCalorieGoal, estimateMacroTargets } from '@/lib/calorieGoal';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

// Steps — 'commitment' is inserted dynamically when activityLevel is low
const ALL_STEPS = ['basics', 'sport', 'activity', 'commitment', 'goal'];
const BASE_STEPS = ['basics', 'sport', 'activity', 'goal'];

const LOW_ACTIVITY_IDS = ['sedentary', 'lightly_active'];

const ACTIVITY_OPTIONS = [
  { id: 'gym', label: 'Gym', emoji: '🏋️', desc: 'Weight training, machines, free weights' },
  { id: 'general_fitness', label: 'General Fitness', emoji: '🌿', desc: 'Overall health, cardio, and wellbeing' },
  { id: 'sport', label: 'Sport', emoji: '⚽', desc: 'Competitive or recreational sport' },
];

// Activity level options — ids match PlanQuestionnaire's StepActivityLevel
const ACTIVITY_LEVEL_OPTIONS = [
  { id: 'sedentary',         label: 'Mostly sitting',      desc: 'Desk job, minimal movement',             calKey: 'sedentary' },
  { id: 'lightly_active',    label: 'Light movement',      desc: 'Walk occasionally, some activity',       calKey: 'lightly_active' },
  { id: 'moderately_active', label: 'Moderately active',   desc: 'Active job or regular walks',            calKey: 'moderately_active' },
  { id: 'very_active',       label: 'Very active',         desc: 'Train 3+ times / week or active job',    calKey: 'very_active' },
];

const COMMITMENT_OPTIONS = [
  { id: 'commit_2',  label: '2x per week',  emoji: '🌱', desc: 'A gentle, sustainable start' },
  { id: 'commit_3',  label: '3x per week',  emoji: '🏃', desc: 'Building a solid routine' },
  { id: 'commit_4',  label: '4x per week',  emoji: '⚡', desc: 'Consistent, meaningful progress' },
  { id: 'commit_5',  label: '5x per week',  emoji: '🔥', desc: 'High commitment, faster results' },
];

const GOAL_OPTIONS = [
  { id: 'lose_fat', label: 'Lose fat', emoji: '🔥', desc: 'Reduce body fat and improve body composition' },
  { id: 'build_muscle', label: 'Build muscle', emoji: '💪', desc: 'Gain lean muscle and increase strength' },
  { id: 'maintain_weight', label: 'Maintain weight', emoji: '⚖️', desc: 'Stay at current weight and improve performance' },
];

export default function StarterProfileModal({ onClose, onSaved, showIntroPopup = false }) {
  const [step, setStep] = useState(0);
  const [saving, setSaving] = useState(false);
  const [showIntro, setShowIntro] = useState(showIntroPopup);

  // Dynamically insert 'commitment' step if user selected low activity
  const getSteps = (activityLevel, trainingCommitment) => {
    const isLow = LOW_ACTIVITY_IDS.includes(activityLevel) || activityLevel === 'sedentary' || activityLevel === 'lightly_active';
    return isLow ? ALL_STEPS : BASE_STEPS;
  };
  const [useMetric, setUseMetric] = useState(false);
  const [data, setData] = useState({
    displayName: '',
    age: '',
    sex: '',
    heightCm: '',
    heightFt: '',
    heightIn: '',
    weightKg: '',
    weightLbs: '',
    primarySport: '',
    primarySportName: '',
    secondarySport: '',
    primaryGoal: '',
    setManualMacros: false,
    manualCalories: '',
    manualProtein: '',
    manualCarbs: '',
    manualFat: '',
    activityLevel: '',
    trainingCommitment: '',
    likedFoods: '',
    dislikedFoods: '',
    allergies: '',
  });

  // Preload existing profile data
  useEffect(() => {
    async function load() {
      const [profiles, workoutProfiles, nutritionProfiles] = await Promise.allSettled([
        backend.entities.UserProfile.list('-updated_date', 1),
        backend.entities.WorkoutProfile.list('-updated_date', 1),
        backend.entities.NutritionProfile.list('-updated_date', 1),
      ]);
      const up = profiles.status === 'fulfilled' ? profiles.value?.[0] : null;
      const wp = workoutProfiles.status === 'fulfilled' ? workoutProfiles.value?.[0] : null;
      const np = nutritionProfiles.status === 'fulfilled' ? nutritionProfiles.value?.[0] : null;

      const heightCm = up?.height_cm || '';
      const weightKg = up?.weight_kg || '';
      // Convert stored metric to imperial for display
      const lbs = weightKg ? Math.round(weightKg * 2.20462) : '';
      const totalInches = heightCm ? Math.round(heightCm / 2.54) : '';
      const ft = totalInches ? Math.floor(totalInches / 12) : '';
      const inches = totalInches ? totalInches % 12 : '';

      setData(prev => ({
        ...prev,
        displayName: up?.display_name || '',
        age: up?.age ? String(up.age) : '',
        sex: up?.sex || '',
        heightCm: heightCm ? String(heightCm) : '',
        heightFt: ft ? String(ft) : '',
        heightIn: inches !== '' ? String(inches) : '',
        weightKg: weightKg ? String(weightKg) : '',
        weightLbs: lbs ? String(lbs) : '',
        primarySport: wp?.primary_sport ? [wp.primary_sport] : [],
        secondarySport: wp?.sport_position || '',
        primaryGoal: up?.goals?.[0] || '',
        activityLevel: np?.activity_level || wp?.current_activity_level || '',
        likedFoods: (np?.liked_foods || []).join(', '),
        dislikedFoods: (np?.disliked_foods || []).join(', '),
        allergies: (np?.allergies || []).join(', '),
      }));
    }
    load().catch(() => {});
  }, []);

  const update = (key, val) => setData(prev => ({ ...prev, [key]: val }));

  const handleSave = async () => {
    setSaving(true);
    try {
      const now = new Date().toISOString();

      const userUpdates = {
        onboarding_complete: true,
        profile_setup_completed: true,
        profile_setup_completed_at: now,
        updated_from_starter_profile: true,
      };
      if (data.displayName) userUpdates.display_name = data.displayName;
      if (data.age) userUpdates.age = Number(data.age);
      if (data.sex) userUpdates.sex = data.sex;
      if (useMetric) {
        if (data.heightCm) userUpdates.height_cm = Number(data.heightCm);
        if (data.weightKg) userUpdates.weight_kg = Number(data.weightKg);
      } else {
        const totalIn = (Number(data.heightFt) || 0) * 12 + (Number(data.heightIn) || 0);
        if (totalIn > 0) userUpdates.height_cm = Math.round(totalIn * 2.54);
        if (data.weightLbs) userUpdates.weight_kg = Math.round(Number(data.weightLbs) / 2.20462 * 10) / 10;
      }

      // Map activityLevel to numeric days; if commitment was given, use that instead
      const ACTIVITY_DAYS = {
        sedentary: 1,
        lightly_active: 2,
        moderately_active: 4,
        very_active: 6,
        athlete: 14, // 2x/day indicator stored as 14 so display logic shows "2x/day"
      };
      const COMMITMENT_DAYS = {
        commit_2: 2,
        commit_3: 3,
        commit_4: 4,
        commit_5: 5,
      };
      const workoutUpdates = { updated_from_starter_profile: true };
      const resolvedDays = data.trainingCommitment
        ? COMMITMENT_DAYS[data.trainingCommitment]
        : (data.activityLevel ? ACTIVITY_DAYS[data.activityLevel] : null);
      // Only persist days_per_week as a starter value when there's no active AI plan.
      // Otherwise the AI plan's training_split.days_per_week is the source of truth and
      // we mustn't lock in a competing value on the WorkoutProfile entity.
      // (planHasNutritionTargets is computed below — load the active plan once here.)
      const _activePlanForWorkoutSync = await loadActivePlan('daily').catch(() => null);
      if (resolvedDays && !_activePlanForWorkoutSync) {
        workoutUpdates.days_per_week = resolvedDays;
      }
      // Store activity types; if "sport" is selected use the typed name
      const sports = data.primarySport || [];
      const sportValue = sports.includes('sport')
        ? (data.primarySportName || 'sport')
        : sports[0] || '';
      const secondarySportValue = sports.length > 1
        ? (sports[1] === 'sport' ? (data.primarySportName || 'sport') : sports[1])
        : '';
      if (sportValue) workoutUpdates.primary_sport = sportValue;
      if (secondarySportValue) workoutUpdates.sport_position = secondarySportValue;
      if (data.secondarySport) workoutUpdates.sport_position = data.secondarySport;

      if (data.primaryGoal) userUpdates.goals = [data.primaryGoal];

      // Map goal ID to nutrition primary_goal format
      const goalMap = { lose_fat: 'fat_loss', build_muscle: 'muscle_gain', maintain_weight: 'maintenance' };
      const nutritionPrimaryGoal = goalMap[data.primaryGoal] || data.primaryGoal || '';

      const nutritionUpdates = { updated_from_starter_profile: true };
      const liked = data.likedFoods.split(',').map(f => f.trim()).filter(Boolean);
      const disliked = data.dislikedFoods.split(',').map(f => f.trim()).filter(Boolean);
      const allergies = data.allergies.split(',').map(f => f.trim()).filter(Boolean);
      if (data.activityLevel) nutritionUpdates.activity_level = data.activityLevel;
      if (nutritionPrimaryGoal) nutritionUpdates.primary_goal = nutritionPrimaryGoal;
      if (liked.length > 0) nutritionUpdates.liked_foods = liked;
      if (disliked.length > 0) nutritionUpdates.disliked_foods = disliked;
      if (allergies.length > 0) nutritionUpdates.allergies = allergies;

      // If an AI plan is already active, its nutrition targets are the source of truth —
      // starter estimates must NOT override it. Only an explicit "Set manual macros" toggle
      // counts as a manual override that wins over the AI plan.
      const activePlan = _activePlanForWorkoutSync;
      const planHasNutritionTargets = Number(
        activePlan?.nutrition_targets?.calories ||
        activePlan?.plan_payload?.nutrition_targets?.calories ||
        0
      ) > 0;

      if (data.setManualMacros && Number(data.manualCalories) > 0) {
        // Explicit user override — wins over AI plan
        nutritionUpdates.calorie_target = Number(data.manualCalories);
        nutritionUpdates.calorie_target_source = 'manual';
        nutritionUpdates.nutrition_targets_updated_at = new Date().toISOString();
        if (Number(data.manualProtein) > 0) nutritionUpdates.protein_target_g = Number(data.manualProtein);
        if (Number(data.manualCarbs) > 0) nutritionUpdates.carbs_target_g = Number(data.manualCarbs);
        if (Number(data.manualFat) > 0) nutritionUpdates.fats_target_g = Number(data.manualFat);
      } else if (planHasNutritionTargets) {
        // AI plan is the source of truth — clear any stale starter override so the
        // calorie resolver picks up the AI plan's targets.
        nutritionUpdates.calorie_target = null;
        nutritionUpdates.calorie_target_source = 'ai_plan';
        nutritionUpdates.protein_target_g = null;
        nutritionUpdates.carbs_target_g = null;
        nutritionUpdates.fats_target_g = null;
      } else {
        // No AI plan yet — calculate starter estimates so the home page reflects them.
        // These are marked 'manual' only because that's the only enum currently >0
        // — they'll be cleared the moment an AI plan is generated (above branch).
        const estimatedProfile = {
          age: Number(userUpdates.age) || 0,
          weight_kg: Number(userUpdates.weight_kg) || 0,
          height_cm: Number(userUpdates.height_cm) || 0,
          sex: userUpdates.sex || '',
        };
        const estimatedNutrition = {
          activity_level: data.activityLevel || '',
          primary_goal: nutritionPrimaryGoal,
        };
        const estimatedCalories = estimateCalorieGoal(estimatedProfile, estimatedNutrition);
        if (estimatedCalories > 0) {
          nutritionUpdates.calorie_target = estimatedCalories;
          nutritionUpdates.calorie_target_source = 'manual';
          nutritionUpdates.nutrition_targets_updated_at = new Date().toISOString();
          const macros = estimateMacroTargets(estimatedCalories, estimatedProfile, estimatedNutrition);
          if (macros) {
            nutritionUpdates.protein_target_g = macros.protein_g;
            nutritionUpdates.carbs_target_g = macros.carbs_g;
            nutritionUpdates.fats_target_g = macros.fat_g;
          }
        }
      }

      await Promise.all([
        saveUserProfile(userUpdates),
        saveWorkoutProfile(workoutUpdates),
        saveNutritionProfile(nutritionUpdates),
      ]);

      onSaved?.({ ...data, useMetric, resolvedDays });
    } catch (err) {
      console.error('StarterProfileModal save error', err);
    } finally {
      setSaving(false);
    }
  };

  const STEPS = getSteps(data.activityLevel, data.trainingCommitment);
  const currentStepId = STEPS[step];
  const isLast = step === STEPS.length - 1;

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      className="fixed inset-0 flex flex-col"
      style={{ background: '#f6f2e8', zIndex: 100, position: 'fixed' }}
    >
      {/* Header */}
      <div className="flex-shrink-0 px-5 pb-3 border-b" style={{ paddingTop: 'max(2.5rem, calc(env(safe-area-inset-top) + 1rem))', borderColor: '#e8e1d4' }}>
        <div className="flex items-center justify-between mb-3">
          <div>
            <h2 className="text-base font-black" style={{ color: '#141613' }}>Personalize Execute</h2>
            <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>
              Step {step + 1} of {STEPS.length}{currentStepId === 'commitment' ? ' · Training commitment' : ''}
            </p>
          </div>
          <button
            onClick={onClose}
            className="w-9 h-9 rounded-full flex items-center justify-center border"
            style={{ background: '#f2efe7', borderColor: '#e8e1d4' }}
          >
            <X size={15} style={{ color: '#5d635d' }} />
          </button>
        </div>
        {/* Progress bar */}
        <div className="h-1.5 rounded-full overflow-hidden" style={{ background: '#e8e1d4' }}>
          <motion.div
            className="h-full rounded-full"
            style={{ background: ACCENT }}
            animate={{ width: `${((step + 1) / STEPS.length) * 100}%` }}
            transition={{ duration: 0.3 }}
          />
        </div>
      </div>

      {/* Scrollable body */}
      <div className="flex-1 overflow-y-auto px-5 py-5" style={{ paddingBottom: '120px' }}>
        <AnimatePresence mode="wait">
          <motion.div
            key={currentStepId}
            initial={{ opacity: 0, x: 12 }}
            animate={{ opacity: 1, x: 0 }}
            exit={{ opacity: 0, x: -12 }}
            transition={{ duration: 0.18 }}
          >
            {/* STEP 1: Basics */}
            {currentStepId === 'basics' && (
              <div className="space-y-5">
                <div>
                  <p className="text-xs font-bold uppercase tracking-widest mb-1.5" style={{ color: '#91968e' }}>Name</p>
                  <input
                    value={data.displayName}
                    onChange={e => update('displayName', e.target.value)}
                    placeholder="First name"
                    className="w-full px-4 py-3 rounded-2xl border text-sm outline-none"
                    style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
                  />
                </div>
                <div className="grid grid-cols-2 gap-3">
                  <div>
                    <p className="text-xs font-bold uppercase tracking-widest mb-1.5" style={{ color: '#91968e' }}>Age</p>
                    <input
                      type="number"
                      value={data.age}
                      onChange={e => update('age', e.target.value)}
                      placeholder="e.g. 28"
                      className="w-full px-4 py-3 rounded-2xl border text-sm outline-none"
                      style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
                    />
                  </div>
                  <div>
                    <p className="text-xs font-bold uppercase tracking-widest mb-1.5" style={{ color: '#91968e' }}>Sex</p>
                    <div className="flex gap-2">
                      {['male', 'female'].map(s => (
                        <button
                          key={s}
                          onClick={() => update('sex', data.sex === s ? '' : s)}
                          className="flex-1 py-3 rounded-2xl border text-xs font-semibold transition-all capitalize"
                          style={{
                            background: data.sex === s ? 'rgba(200,224,0,0.12)' : '#ffffff',
                            borderColor: data.sex === s ? 'rgba(200,224,0,0.5)' : '#e8e1d4',
                            color: data.sex === s ? ACCENT_DARK : '#5d635d',
                          }}
                        >
                          {s}
                        </button>
                      ))}
                    </div>
                  </div>
                </div>
                {/* Unit toggle */}
                <div className="flex items-center justify-end gap-1 -mb-2">
                  <span className="text-xs font-semibold" style={{ color: useMetric ? '#91968e' : ACCENT_DARK }}>Imperial</span>
                  <button
                    onClick={() => setUseMetric(m => !m)}
                    className="relative w-10 h-5 rounded-full transition-all mx-1"
                    style={{ background: useMetric ? ACCENT : '#d9d1c2' }}
                  >
                    <span
                      className="absolute top-0.5 w-4 h-4 rounded-full bg-white shadow transition-all"
                      style={{ left: useMetric ? '22px' : '2px' }}
                    />
                  </button>
                  <span className="text-xs font-semibold" style={{ color: useMetric ? ACCENT_DARK : '#91968e' }}>Metric</span>
                </div>

                {useMetric ? (
                  <div className="grid grid-cols-2 gap-3">
                    <div>
                      <p className="text-xs font-bold uppercase tracking-widest mb-1.5" style={{ color: '#91968e' }}>Height (cm)</p>
                      <input
                        type="number"
                        value={data.heightCm}
                        onChange={e => update('heightCm', e.target.value)}
                        placeholder="e.g. 178"
                        className="w-full px-4 py-3 rounded-2xl border text-sm outline-none"
                        style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
                      />
                    </div>
                    <div>
                      <p className="text-xs font-bold uppercase tracking-widest mb-1.5" style={{ color: '#91968e' }}>Weight (kg)</p>
                      <input
                        type="number"
                        value={data.weightKg}
                        onChange={e => update('weightKg', e.target.value)}
                        placeholder="e.g. 80"
                        className="w-full px-4 py-3 rounded-2xl border text-sm outline-none"
                        style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
                      />
                    </div>
                  </div>
                ) : (
                  <div className="space-y-3">
                    <div>
                      <p className="text-xs font-bold uppercase tracking-widest mb-1.5" style={{ color: '#91968e' }}>Height</p>
                      <div className="grid grid-cols-2 gap-2">
                        <div className="relative">
                          <input
                            type="number"
                            value={data.heightFt}
                            onChange={e => update('heightFt', e.target.value)}
                            placeholder="5"
                            className="w-full px-4 py-3 rounded-2xl border text-sm outline-none pr-10"
                            style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
                          />
                          <span className="absolute right-3 top-1/2 -translate-y-1/2 text-xs font-semibold" style={{ color: '#91968e' }}>ft</span>
                        </div>
                        <div className="relative">
                          <input
                            type="number"
                            value={data.heightIn}
                            onChange={e => update('heightIn', e.target.value)}
                            placeholder="10"
                            min={0} max={11}
                            className="w-full px-4 py-3 rounded-2xl border text-sm outline-none pr-10"
                            style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
                          />
                          <span className="absolute right-3 top-1/2 -translate-y-1/2 text-xs font-semibold" style={{ color: '#91968e' }}>in</span>
                        </div>
                      </div>
                    </div>
                    <div>
                      <p className="text-xs font-bold uppercase tracking-widest mb-1.5" style={{ color: '#91968e' }}>Weight</p>
                      <div className="relative">
                        <input
                          type="number"
                          value={data.weightLbs}
                          onChange={e => update('weightLbs', e.target.value)}
                          placeholder="e.g. 175"
                          className="w-full px-4 py-3 rounded-2xl border text-sm outline-none pr-12"
                          style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
                        />
                        <span className="absolute right-3 top-1/2 -translate-y-1/2 text-xs font-semibold" style={{ color: '#91968e' }}>lbs</span>
                      </div>
                    </div>
                  </div>
                )}
              </div>
            )}

            {/* STEP 2: Sport */}
            {currentStepId === 'sport' && (
              <div className="space-y-5">
                <div>
                  <h3 className="text-base font-black mb-1" style={{ color: '#141613' }}>What's your primary activity?</h3>
                  <p className="text-xs mb-4" style={{ color: '#91968e' }}>Select up to two — this shapes your workout plan.</p>
                  <div className="space-y-2">
                    {ACTIVITY_OPTIONS.map(opt => {
                      const selected = (data.primarySport || []).includes(opt.id);
                      const atMax = (data.primarySport || []).length >= 2;
                      return (
                        <button
                          key={opt.id}
                          onClick={() => {
                            const current = data.primarySport || [];
                            if (selected) {
                              update('primarySport', current.filter(x => x !== opt.id));
                            } else if (!atMax) {
                              update('primarySport', [...current, opt.id]);
                            }
                          }}
                          className="w-full flex items-center gap-3 px-4 py-3.5 rounded-2xl border text-left transition-all"
                          style={{
                            background: selected ? 'rgba(200,224,0,0.1)' : '#ffffff',
                            borderColor: selected ? 'rgba(200,224,0,0.5)' : '#e8e1d4',
                            opacity: !selected && atMax ? 0.45 : 1,
                          }}
                        >
                          <span className="text-lg flex-shrink-0">{opt.emoji}</span>
                          <div className="flex-1 min-w-0">
                            <p className="text-sm font-semibold" style={{ color: '#141613' }}>{opt.label}</p>
                            <p className="text-xs" style={{ color: '#91968e' }}>{opt.desc}</p>
                          </div>
                          {selected && <Check size={15} style={{ color: ACCENT_DARK, flexShrink: 0 }} />}
                        </button>
                      );
                    })}
                  </div>
                </div>

                {/* Sport text inputs — only shown when "sport" is selected */}
                <AnimatePresence>
                  {(data.primarySport || []).includes('sport') && (
                    <motion.div
                      initial={{ opacity: 0, height: 0 }}
                      animate={{ opacity: 1, height: 'auto' }}
                      exit={{ opacity: 0, height: 0 }}
                      className="space-y-3 overflow-hidden"
                    >
                      <div>
                        <p className="text-xs font-bold uppercase tracking-widest mb-1.5" style={{ color: '#91968e' }}>Primary sport</p>
                        <input
                          value={data.primarySportName}
                          onChange={e => update('primarySportName', e.target.value)}
                          placeholder="e.g. basketball, soccer, tennis…"
                          className="w-full px-4 py-3 rounded-2xl border text-sm outline-none"
                          style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
                        />
                      </div>
                      <div>
                        <p className="text-xs font-bold uppercase tracking-widest mb-1.5" style={{ color: '#91968e' }}>Secondary sport <span className="font-normal normal-case" style={{ color: '#b8b4ac' }}>(optional)</span></p>
                        <input
                          value={data.secondarySport}
                          onChange={e => update('secondarySport', e.target.value)}
                          placeholder="e.g. swimming, running…"
                          className="w-full px-4 py-3 rounded-2xl border text-sm outline-none"
                          style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
                        />
                      </div>
                    </motion.div>
                  )}
                </AnimatePresence>
              </div>
            )}

            {/* STEP 3: Activity */}
            {currentStepId === 'activity' && (
              <div className="space-y-4">
                <div>
                  <h3 className="text-base font-black mb-1" style={{ color: '#141613' }}>How active are you?</h3>
                  <p className="text-xs mb-4" style={{ color: '#91968e' }}>Used to estimate your daily calorie needs and calibrate plans.</p>
                  <div className="space-y-2">
                    {ACTIVITY_LEVEL_OPTIONS.map(opt => (
                     <button
                       key={opt.id}
                       onClick={() => update('activityLevel', data.activityLevel === opt.id ? '' : opt.id)}
                       className="w-full flex items-center justify-between p-4 rounded-2xl border text-left transition-all"
                       style={{
                         background: data.activityLevel === opt.id ? 'rgba(200,224,0,0.08)' : '#ffffff',
                         borderColor: data.activityLevel === opt.id ? 'rgba(200,224,0,0.45)' : '#e8e1d4',
                       }}
                     >
                       <div className="flex-1 min-w-0">
                         <p className="text-sm font-semibold" style={{ color: '#141613' }}>{opt.label}</p>
                         <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>{opt.desc}</p>
                       </div>
                       {data.activityLevel === opt.id && <Check size={16} style={{ color: ACCENT_DARK, flexShrink: 0, marginLeft: 12 }} />}
                     </button>
                    ))}
                  </div>
                </div>
              </div>
            )}

            {/* STEP commitment: Training target */}
            {currentStepId === 'commitment' && (
              <div className="space-y-4">
                <div>
                  <h3 className="text-base font-black mb-1" style={{ color: '#141613' }}>How often do you want to train?</h3>
                  <p className="text-xs mb-4" style={{ color: '#91968e' }}>You mentioned you're currently less active — how many days per week are you willing to commit to?</p>
                  <div className="space-y-2">
                    {COMMITMENT_OPTIONS.map(opt => (
                      <button
                        key={opt.id}
                        onClick={() => update('trainingCommitment', data.trainingCommitment === opt.id ? '' : opt.id)}
                        className="w-full flex items-center gap-4 px-4 py-3.5 rounded-2xl border text-left transition-all"
                        style={{
                          background: data.trainingCommitment === opt.id ? 'rgba(200,224,0,0.1)' : '#ffffff',
                          borderColor: data.trainingCommitment === opt.id ? 'rgba(200,224,0,0.5)' : '#e8e1d4',
                        }}
                      >
                        <span className="text-xl flex-shrink-0">{opt.emoji}</span>
                        <div className="flex-1 min-w-0">
                          <p className="text-sm font-bold" style={{ color: '#141613' }}>{opt.label}</p>
                          <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>{opt.desc}</p>
                        </div>
                        {data.trainingCommitment === opt.id && <Check size={15} style={{ color: ACCENT_DARK, flexShrink: 0 }} />}
                      </button>
                    ))}
                  </div>
                </div>
              </div>
            )}

            {/* STEP 4: Goal */}
            {currentStepId === 'goal' && (
              <div className="space-y-5">
                <div>
                  <h3 className="text-base font-black mb-1" style={{ color: '#141613' }}>What's your main goal?</h3>
                  <p className="text-xs mb-4" style={{ color: '#91968e' }}>This helps calibrate your logged statistics and recommendations.</p>
                  <div className="space-y-3">
                    {GOAL_OPTIONS.map(opt => (
                      <button
                        key={opt.id}
                        onClick={() => update('primaryGoal', data.primaryGoal === opt.id ? '' : opt.id)}
                        className="w-full flex items-center gap-4 px-4 py-4 rounded-2xl border text-left transition-all"
                        style={{
                          background: data.primaryGoal === opt.id ? 'rgba(200,224,0,0.1)' : '#ffffff',
                          borderColor: data.primaryGoal === opt.id ? 'rgba(200,224,0,0.5)' : '#e8e1d4',
                        }}
                      >
                        <span className="text-2xl flex-shrink-0">{opt.emoji}</span>
                        <div className="flex-1 min-w-0">
                          <p className="text-sm font-bold" style={{ color: '#141613' }}>{opt.label}</p>
                          <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>{opt.desc}</p>
                        </div>
                        {data.primaryGoal === opt.id && <Check size={15} style={{ color: ACCENT_DARK, flexShrink: 0 }} />}
                      </button>
                    ))}
                  </div>
                </div>

                {/* Manual macros toggle */}
                <div className="p-4 rounded-2xl border" style={{ background: data.setManualMacros ? 'rgba(200,224,0,0.06)' : '#ffffff', borderColor: data.setManualMacros ? 'rgba(200,224,0,0.35)' : '#e8e1d4' }}>
                  <div className="flex items-center justify-between">
                    <div>
                      <p className="text-sm font-semibold" style={{ color: '#141613' }}>Set manual macros</p>
                      <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>Override our macro target with your own</p>
                    </div>
                    <button
                      onClick={() => update('setManualMacros', !data.setManualMacros)}
                      className="relative w-11 h-6 rounded-full transition-all flex-shrink-0"
                      style={{ background: data.setManualMacros ? ACCENT : '#d9d1c2' }}
                    >
                      <span
                        className="absolute top-0.5 w-5 h-5 rounded-full bg-white shadow transition-all"
                        style={{ left: data.setManualMacros ? '23px' : '2px' }}
                      />
                    </button>
                  </div>
                  <AnimatePresence>
                    {data.setManualMacros && (
                      <motion.div
                        initial={{ opacity: 0, height: 0 }}
                        animate={{ opacity: 1, height: 'auto' }}
                        exit={{ opacity: 0, height: 0 }}
                        className="overflow-hidden"
                      >
                        <div className="space-y-3 mt-3">
                          {[
                            { key: 'manualCalories', label: 'Calories', unit: 'kcal', placeholder: 'e.g. 2200' },
                            { key: 'manualProtein',  label: 'Protein',  unit: 'g',    placeholder: 'e.g. 160' },
                            { key: 'manualCarbs',    label: 'Carbs',    unit: 'g',    placeholder: 'e.g. 220' },
                            { key: 'manualFat',      label: 'Fat',      unit: 'g',    placeholder: 'e.g. 70' },
                          ].map(field => (
                            <div key={field.key} className="relative">
                              <label className="text-[10px] font-bold uppercase tracking-widest mb-1 block" style={{ color: '#91968e' }}>{field.label}</label>
                              <div className="relative">
                                <input
                                  type="number"
                                  value={data[field.key]}
                                  onChange={e => update(field.key, e.target.value)}
                                  placeholder={field.placeholder}
                                  className="w-full px-4 py-3 rounded-xl border text-sm font-bold outline-none pr-14"
                                  style={{ background: '#ffffff', borderColor: 'rgba(200,224,0,0.4)', color: '#141613' }}
                                />
                                <span className="absolute right-4 top-1/2 -translate-y-1/2 text-xs font-semibold" style={{ color: '#91968e' }}>{field.unit}</span>
                              </div>
                            </div>
                          ))}
                        </div>
                      </motion.div>
                    )}
                  </AnimatePresence>
                </div>
              </div>
            )}


          </motion.div>
        </AnimatePresence>
      </div>

      {/* Intro popup */}
      <AnimatePresence>
        {showIntro && (
          <motion.div
            key="intro-popup"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            className="absolute inset-0 flex items-center justify-center px-6"
            style={{ background: 'rgba(20,22,19,0.5)', zIndex: 110 }}
          >
            <motion.div
              initial={{ scale: 0.92, opacity: 0 }}
              animate={{ scale: 1, opacity: 1 }}
              exit={{ scale: 0.92, opacity: 0 }}
              className="w-full max-w-sm rounded-2xl p-6 text-center"
              style={{ background: '#ffffff', border: '1px solid #e8e1d4' }}
            >
              <p className="text-sm font-semibold mb-2" style={{ color: '#141613' }}>Starter Targets</p>
              <p className="text-xs leading-relaxed mb-5" style={{ color: '#5d635d' }}>
                Starter targets based on your profile. Upgrade for adaptive plans that adjust to readiness, progress, and schedule.
              </p>
              <button
                onClick={() => setShowIntro(false)}
                className="w-full py-2.5 rounded-xl text-sm font-bold"
                style={{ background: '#c8e000', color: '#141613' }}
              >
                Okay
              </button>
            </motion.div>
          </motion.div>
        )}
      </AnimatePresence>

      {/* Sticky footer */}
      <div
        className="flex-shrink-0 px-5 pt-3 border-t flex gap-3"
        style={{
          paddingBottom: 'calc(16px + env(safe-area-inset-bottom))',
          borderColor: '#e8e1d4',
          background: '#f6f2e8',
        }}
      >
        {step > 0 && (
          <button
            onClick={() => setStep(s => s - 1)}
            className="flex items-center gap-1.5 px-5 py-4 rounded-2xl border text-sm font-semibold flex-shrink-0"
            style={{ borderColor: '#e8e1d4', color: '#5d635d', background: '#ffffff' }}
          >
            <ChevronLeft size={14} /> Back
          </button>
        )}
        <button
          onClick={isLast ? handleSave : () => setStep(s => s + 1)}
          disabled={saving}
          className="flex-1 py-4 rounded-2xl text-sm font-bold flex items-center justify-center gap-2 transition-all"
          style={{ background: saving ? 'rgba(200,224,0,0.5)' : ACCENT, color: '#141613' }}
        >
          {saving ? (
            <><Loader2 size={14} className="animate-spin" /> Saving…</>
          ) : isLast ? (
            <><Check size={14} /> Save personalization</>
          ) : (
            <>Continue <ChevronRight size={14} /></>
          )}
        </button>
      </div>
    </motion.div>
  );
}