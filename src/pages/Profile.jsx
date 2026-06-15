import { useState, useEffect, useRef } from 'react';
import { usePageLayout } from '@/components/customize/usePageLayout';
import ResetAppDataButton from '@/components/plan/ResetAppDataButton';

const PAGE_KEY = 'profile';
import { motion, AnimatePresence } from 'framer-motion';
import { ChevronRight, LogOut, User, Target, Utensils, Dumbbell, ShieldAlert, Brain, Plus, X, Check, Ruler, Loader2, Crown, Sparkles, Trash2 } from 'lucide-react';
import { useNavigate } from 'react-router-dom';
import { useSubscription } from '@/hooks/useSubscription';
import { backend } from '@/api/backendClient';
import { useAuth } from '@/lib/AuthContext';
import { getUnitSystem, setUnitSystem, UNIT_SYSTEMS } from '@/lib/units';
import {
  saveUserProfile, saveWorkoutProfile, saveNutritionProfile,
  loadActiveGoals, createGoal, deleteGoal, loadActiveInjuries, invalidateUserAIContext
} from '@/lib/personalizationSync';
import { loadProfileEffectiveValues } from '@/lib/profilePlanSync';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

function DeleteAccountModal({ onConfirm, onCancel, logout }) {
  const [confirming, setConfirming] = useState(false);

  const handleConfirm = async () => {
    setConfirming(true);
    try {
      // Delete all user entity data via backend function
      await backend.functions.invoke('deleteUserData', {});
      // Then log out via AuthContext so appCache + module caches are cleared.
      await logout();
      onConfirm?.();
    } catch (err) {
      console.error('Delete account failed:', err);
      setConfirming(false);
    }
  };

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      className="fixed inset-0 z-[200] flex items-end justify-center"
      style={{ background: 'rgba(0,0,0,0.6)' }}
      onClick={onCancel}
    >
      <motion.div
        initial={{ y: '100%' }}
        animate={{ y: 0 }}
        exit={{ y: '100%' }}
        transition={{ type: 'spring', damping: 28, stiffness: 320 }}
        className="w-full max-w-md rounded-t-3xl p-6"
        style={{ minHeight: '50vh', paddingBottom: 'calc(3rem + env(safe-area-inset-bottom))', display: 'flex', flexDirection: 'column', justifyContent: 'center', background: '#ffffff', border: '1px solid #e8e1d4' }}
        onClick={e => e.stopPropagation()}
      >
        <div className="w-10 h-1 rounded-full mx-auto mb-6" style={{ background: '#e8e1d4' }} />
        <div className="w-12 h-12 rounded-full flex items-center justify-center mx-auto mb-4" style={{ background: 'rgba(176,90,58,0.1)' }}>
          <Trash2 size={22} style={{ color: '#b05a3a' }} />
        </div>
        <h2 className="text-lg font-bold text-center mb-2" style={{ color: '#141613' }}>Delete Account</h2>
        <p className="text-sm text-center mb-6 leading-relaxed" style={{ color: '#5d635d' }}>
          This action is <strong>permanent and irreversible</strong>. All your cloud data, workouts, nutrition logs, goals, and account information will be permanently deleted.
        </p>
        <div className="space-y-3">
          <button
            onClick={onCancel}
            className="w-full py-3.5 rounded-2xl text-sm font-semibold"
            style={{ background: '#f2efe7', color: '#141613', border: '1px solid #e8e1d4' }}
          >
            Cancel
          </button>
          <button
            onClick={handleConfirm}
            disabled={confirming}
            className="w-full py-3.5 rounded-2xl text-sm font-bold flex items-center justify-center gap-2"
            style={{
              background: '#b05a3a',
              color: '#ffffff',
              opacity: confirming ? 0.7 : 1,
              cursor: confirming ? 'not-allowed' : 'pointer',
            }}
          >
            {confirming ? <Loader2 size={14} className="animate-spin" /> : <Trash2 size={14} />}
            {confirming ? 'Deleting…' : 'Delete All Data'}
          </button>
        </div>
      </motion.div>
    </motion.div>
  );
}

const SECTIONS = [
  { id: 'goals', icon: Target, label: 'Goals', subtitle: 'What you\'re working toward' },
  { id: 'nutrition', icon: Utensils, label: 'Nutrition Preferences', subtitle: 'Food likes, dislikes, targets' },
  { id: 'workout', icon: Dumbbell, label: 'Workout Preferences', subtitle: 'Training style and schedule' },
  { id: 'limitations', icon: ShieldAlert, label: 'Limitations', subtitle: 'Injuries and movement cautions' },
  { id: 'coaching', icon: Brain, label: 'Coaching Style', subtitle: 'How Execute coaches you' },
  { id: 'units', icon: Ruler, label: 'Units', subtitle: 'Imperial or metric measurements' },
];

const GOAL_CATEGORIES = ['body', 'fitness', 'sleep', 'energy', 'nutrition', 'recovery', 'mental', 'habit'];
const GOAL_PRESETS = [
  'Lose body fat', 'Build muscle', 'Improve sleep consistency', 'Increase daily energy',
  'Train 4x per week', 'Improve recovery score', 'Drink more water', 'Reduce stress',
  'Improve nutrition quality', 'Build a consistent morning routine',
];
const DISLIKE_PRESETS = ['fish', 'liver', 'tofu', 'mushrooms', 'spicy food', 'dairy', 'gluten'];
const LIKE_PRESETS = ['chicken', 'eggs', 'rice', 'oats', 'berries', 'Greek yogurt', 'sweet potato'];
const EQUIPMENT_OPTIONS = ['Barbell', 'Dumbbells', 'Cables', 'Pull-up bar', 'Resistance bands', 'Kettlebell', 'Bodyweight only', 'Full gym'];
const COACHING_STYLES = [
  { id: 'structured', label: 'Structured', desc: 'Clear schedules, precise targets, step-by-step plans' },
  { id: 'balanced', label: 'Balanced', desc: 'Mix of structure and flexibility, adaptable guidance' },
  { id: 'flexible', label: 'Flexible', desc: 'Looser recommendations, more autonomy, general direction' },
];

// -------- Sub-panels --------

function GoalsPanel() {
  const [goals, setGoals] = useState([]);
  const [loading, setLoading] = useState(true);
  const [newTitle, setNewTitle] = useState('');
  const [newCat, setNewCat] = useState('fitness');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    loadActiveGoals().then(setGoals).catch(() => setGoals([])).finally(() => setLoading(false));
  }, []);

  const addGoal = async () => {
    if (!newTitle.trim()) return;
    setSaving(true);
    const created = await createGoal({ title: newTitle.trim(), category: newCat }).catch(() => null);
    if (created) setGoals(prev => [...prev, created]);
    setNewTitle('');
    setSaving(false);
  };

  const removeGoal = async (id) => {
    setGoals(prev => prev.filter(g => g.id !== id));
    await deleteGoal(id).catch(() => {});
  };

  const toggleGoal = async (id, currentStatus) => {
    const newStatus = currentStatus === 'active' ? 'paused' : 'active';
    setGoals(prev => prev.map(g => g.id === id ? { ...g, status: newStatus } : g));
    await backend.entities.Goal.update(id, { status: newStatus }).catch(() => {});
    await invalidateUserAIContext().catch(() => {});
  };

  if (loading) return <div className="flex justify-center py-8"><Loader2 size={18} className="animate-spin" style={{ color: '#8ea400' }} /></div>;

  return (
    <div className="space-y-4">
      <p className="text-xs" style={{ color: '#91968e' }}>Your goals shape recommendations across the entire app.</p>

      {goals.map((goal) => (
        <div key={goal.id} className="flex items-center gap-3 p-3.5 rounded-xl border" style={{ background: goal.status === 'active' ? '#ffffff' : '#f2efe7', borderColor: goal.status === 'active' ? 'rgba(200,224,0,0.3)' : '#e8e1d4' }}>
          <div className="flex-1 min-w-0">
            <p className="text-sm font-medium" style={{ color: goal.status === 'active' ? '#141613' : '#91968e' }}>{goal.title}</p>
            <p className="text-[10px]" style={{ color: '#91968e' }}>{goal.category}</p>
          </div>
          <button onClick={() => toggleGoal(goal.id, goal.status)} className="text-[10px] px-2 py-1 rounded-full font-semibold border"
            style={{ background: goal.status === 'active' ? 'rgba(200,224,0,0.1)' : '#f2efe7', color: goal.status === 'active' ? ACCENT_DARK : '#91968e', borderColor: goal.status === 'active' ? 'rgba(200,224,0,0.3)' : '#e8e1d4' }}>
            {goal.status === 'active' ? 'Active' : 'Paused'}
          </button>
          <button onClick={() => removeGoal(goal.id)}><X size={13} style={{ color: '#d9d1c2' }} /></button>
        </div>
      ))}

      <div className="flex flex-wrap gap-2 mb-2">
        {GOAL_PRESETS.filter(p => !goals.some(g => g.title === p)).slice(0, 6).map(p => (
          <button key={p} onClick={() => setNewTitle(p)} className="px-3 py-1.5 rounded-full text-xs border"
            style={{ background: newTitle === p ? 'rgba(200,224,0,0.1)' : '#f2efe7', borderColor: newTitle === p ? 'rgba(200,224,0,0.4)' : '#e8e1d4', color: '#5d635d' }}>
            {p}
          </button>
        ))}
      </div>

      <div className="flex gap-2">
        <input value={newTitle} onChange={e => setNewTitle(e.target.value)} placeholder="Add a goal..."
          className="flex-1 px-3 py-2.5 rounded-xl border text-sm outline-none"
          style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
          onKeyDown={e => e.key === 'Enter' && addGoal()} />
        <button onClick={addGoal} disabled={saving} className="px-3.5 py-2.5 rounded-xl text-sm font-bold" style={{ background: ACCENT, color: '#141613' }}>
          {saving ? <Loader2 size={14} className="animate-spin" /> : <Plus size={14} />}
        </button>
      </div>
    </div>
  );
}

function NutritionPanel({ onSaved }) {
  const [nutr, setNutr] = useState({ disliked_foods: [], liked_foods: [], dietary_preference: 'none', calorie_target: '', calorie_target_source: 'ai_plan', protein_target_g: 0, carbs_target_g: 0, fats_target_g: 0 });
  const [effective, setEffective] = useState(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  // Track which fields the user actually edited so we don't lock in AI-plan-hydrated
  // values onto the profile entity (which would then mask future plan updates).
  const dirtyRef = useRef(new Set());
  const update = (k, v) => {
    dirtyRef.current.add(k);
    setNutr(prev => ({ ...prev, [k]: v }));
  };

  // Scroll-to focus from query param
  const caloriesRef = useRef(null);
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    if (params.get('focus') === 'calories') {
      setTimeout(() => caloriesRef.current?.scrollIntoView({ behavior: 'smooth', block: 'center' }), 300);
    }
  }, []);

  useEffect(() => {
    loadProfileEffectiveValues().then(snapshot => {
      setEffective(snapshot);
      const r = snapshot.nutritionProfile || {};
      const eff = snapshot.effective;
      // Display values: prefer the resolved effective values (AI plan wins over starter)
      // unless the user explicitly set a manual calorie_target on the profile.
      const isManual = r.calorie_target_source === 'manual' && Number(r.calorie_target) > 0;
      setNutr({
        ...r,
        calorie_target: isManual ? String(r.calorie_target) : '',
        calorie_target_source: r.calorie_target_source || 'ai_plan',
        // Hydrate macros from effective resolver so blank profile fields fall back to the AI plan.
        protein_target_g: Number(r.protein_target_g) > 0 ? r.protein_target_g : (eff.protein_g.value || 0),
        carbs_target_g: Number(r.carbs_target_g) > 0 ? r.carbs_target_g : (eff.carbs_g.value || 0),
        fats_target_g: Number(r.fats_target_g) > 0 ? r.fats_target_g : (eff.fats_g.value || 0),
        // Liked / disliked: keep saved values; plan likes act as suggestions, not overwrites.
        disliked_foods: r.disliked_foods?.length ? r.disliked_foods : (eff.dislikedFoods.value || []),
        liked_foods: r.liked_foods?.length ? r.liked_foods : (eff.likedFoods.value || []),
        dietary_preference: (r.dietary_preference && r.dietary_preference !== 'none')
          ? r.dietary_preference
          : (eff.dietaryPreference.value || 'none'),
      });
    }).catch(() => {}).finally(() => setLoading(false));
  }, []);

  const calorieSource = effective?.effective?.calories?.source || 'none';
  const planCalories = effective?.planFields?.calories || null;

  const toggleArray = (arr, item) => (arr || []).includes(item) ? (arr || []).filter(x => x !== item) : [...(arr || []), item];

  const isManual = nutr.calorie_target_source === 'manual';

  const handleCalorieInput = (val) => {
    update('calorie_target', val);
    if (val && Number(val) > 0) {
      update('calorie_target_source', 'manual');
    }
  };

  const handleUseAITarget = () => {
    update('calorie_target', '');
    update('calorie_target_source', 'ai_plan');
  };

  return (
    <div className="space-y-5">
      {/* Calorie target — primary, prominent */}
      <div ref={caloriesRef} className="p-4 rounded-2xl border" style={{ background: isManual ? 'rgba(200,224,0,0.06)' : '#ffffff', borderColor: isManual ? 'rgba(200,224,0,0.35)' : '#e8e1d4' }}>
        <div className="flex items-center justify-between mb-2">
          <p className="text-xs font-bold uppercase tracking-widest" style={{ color: '#91968e' }}>Daily Calorie Target</p>
          <div className="flex items-center gap-2">
            {calorieSource === 'ai_plan' && (
              <span className="text-[10px] font-semibold px-2 py-0.5 rounded-full" style={{ background: 'rgba(200,224,0,0.12)', color: ACCENT_DARK }}>
                From AI plan
              </span>
            )}
            {isManual && (
              <button onClick={handleUseAITarget} className="text-[10px] font-semibold px-2.5 py-1 rounded-full border"
                style={{ borderColor: '#e8e1d4', color: '#91968e', background: '#f9f7f3' }}>
                {planCalories ? 'Use plan target' : 'Reset'}
              </button>
            )}
          </div>
        </div>
        <div className="relative">
          <input
            type="number"
            value={nutr.calorie_target}
            onChange={e => handleCalorieInput(e.target.value)}
            placeholder={planCalories && !isManual ? String(planCalories) : 'Set a personal target…'}
            className="w-full px-4 py-3 rounded-xl border text-base font-bold outline-none"
            style={{ background: '#ffffff', borderColor: isManual ? 'rgba(200,224,0,0.4)' : '#e8e1d4', color: '#141613' }}
          />
          <span className="absolute right-4 top-1/2 -translate-y-1/2 text-xs font-semibold" style={{ color: '#91968e' }}>kcal</span>
        </div>
        <p className="text-[10px] mt-2 leading-snug" style={{ color: '#91968e' }}>
          {isManual
            ? 'Manual override active — used across Home, meal plans, and recommendations.'
            : planCalories
              ? `Currently using your AI plan target of ${planCalories} kcal. Enter a value to override.`
              : 'Leave blank to use your plan target or an estimate from your profile.'}
        </p>
      </div>

      {/* Macros */}
      <div>
        <div className="flex items-center justify-between mb-3">
          <p className="text-xs font-semibold" style={{ color: '#91968e' }}>Other daily targets</p>
          {effective?.effective?.protein_g?.source === 'ai_plan' && (
            <span className="text-[10px] font-semibold px-2 py-0.5 rounded-full" style={{ background: 'rgba(200,224,0,0.12)', color: ACCENT_DARK }}>
              From AI plan
            </span>
          )}
        </div>
        {[
          { label: 'Protein (g)', key: 'protein_target_g', max: 300 },
          { label: 'Carbs (g)', key: 'carbs_target_g', max: 500 },
          { label: 'Fat (g)', key: 'fats_target_g', max: 150 },
        ].map(field => (
          <div key={field.key} className="mb-3">
            <div className="flex items-center justify-between mb-1">
              <span className="text-xs" style={{ color: '#141613' }}>{field.label}</span>
              <span className="text-sm font-bold" style={{ color: ACCENT_DARK }}>{nutr[field.key] || 0}</span>
            </div>
            <input type="range" min={0} max={field.max} value={nutr[field.key] || 0} onChange={e => update(field.key, Number(e.target.value))}
              className="w-full" style={{ accentColor: ACCENT }} />
          </div>
        ))}
      </div>

      <div>
        <p className="text-xs font-semibold mb-2" style={{ color: '#91968e' }}>Foods to avoid in meal plans</p>
        <div className="flex flex-wrap gap-2">
          {DISLIKE_PRESETS.map(f => (
            <button key={f} onClick={() => update('disliked_foods', toggleArray(nutr.disliked_foods, f))}
              className="px-3 py-1.5 rounded-full text-xs border"
              style={{ background: (nutr.disliked_foods || []).includes(f) ? 'rgba(176,90,58,0.1)' : '#f2efe7', borderColor: (nutr.disliked_foods || []).includes(f) ? 'rgba(176,90,58,0.3)' : '#e8e1d4', color: (nutr.disliked_foods || []).includes(f) ? '#b05a3a' : '#5d635d' }}>
              {f}
            </button>
          ))}
        </div>
      </div>

      <div>
        <p className="text-xs font-semibold mb-2" style={{ color: '#91968e' }}>Foods to prioritize in meal plans</p>
        <div className="flex flex-wrap gap-2">
          {LIKE_PRESETS.map(f => (
            <button key={f} onClick={() => update('liked_foods', toggleArray(nutr.liked_foods, f))}
              className="px-3 py-1.5 rounded-full text-xs border"
              style={{ background: (nutr.liked_foods || []).includes(f) ? 'rgba(200,224,0,0.1)' : '#f2efe7', borderColor: (nutr.liked_foods || []).includes(f) ? 'rgba(200,224,0,0.3)' : '#e8e1d4', color: (nutr.liked_foods || []).includes(f) ? ACCENT_DARK : '#5d635d' }}>
              {f}
            </button>
          ))}
        </div>
      </div>

      <div>
        <p className="text-xs font-semibold mb-2" style={{ color: '#91968e' }}>Dietary preference</p>
        <div className="flex flex-wrap gap-2">
          {['none', 'vegetarian', 'vegan', 'keto', 'paleo', 'gluten_free', 'dairy_free'].map(pref => (
            <button key={pref} onClick={() => update('dietary_preference', pref)}
              className="px-3 py-1.5 rounded-full text-xs border capitalize"
              style={{ background: nutr.dietary_preference === pref ? 'rgba(200,224,0,0.12)' : '#f2efe7', borderColor: nutr.dietary_preference === pref ? 'rgba(200,224,0,0.4)' : '#e8e1d4', color: nutr.dietary_preference === pref ? ACCENT_DARK : '#5d635d' }}>
              {pref === 'none' ? 'No restriction' : pref.replace('_', ' ')}
            </button>
          ))}
        </div>
      </div>

      {loading ? <div className="flex justify-center py-4"><Loader2 size={18} className="animate-spin" style={{ color: '#8ea400' }} /></div> : null}
      <button onClick={async () => {
        setSaving(true);
        // Only persist fields the user actually touched. AI-plan-hydrated values stay
        // as display defaults and don't get locked into the profile entity.
        const dirty = dirtyRef.current;
        const updates = { nutrition_targets_updated_at: new Date().toISOString() };
        const calorieVal = Number(nutr.calorie_target) || 0;
        if (dirty.has('calorie_target')) {
          updates.calorie_target = calorieVal > 0 ? calorieVal : null;
          updates.calorie_target_source = calorieVal > 0 ? 'manual' : 'ai_plan';
        }
        if (dirty.has('protein_target_g')) updates.protein_target_g = Number(nutr.protein_target_g) || 0;
        if (dirty.has('carbs_target_g'))   updates.carbs_target_g   = Number(nutr.carbs_target_g)   || 0;
        if (dirty.has('fats_target_g'))    updates.fats_target_g    = Number(nutr.fats_target_g)    || 0;
        if (dirty.has('disliked_foods'))   updates.disliked_foods   = nutr.disliked_foods || [];
        if (dirty.has('liked_foods'))      updates.liked_foods      = nutr.liked_foods || [];
        if (dirty.has('dietary_preference')) updates.dietary_preference = nutr.dietary_preference || 'none';
        await saveNutritionProfile(updates).catch(() => {});
        dirtyRef.current = new Set();
        setSaving(false);
        onSaved?.();
      }} disabled={saving} className="w-full py-3.5 rounded-2xl text-sm font-bold" style={{ background: ACCENT, color: '#141613' }}>
        {saving ? 'Saving…' : 'Save Preferences'}
      </button>
    </div>
  );
}

// Map AI plan / questionnaire primary_goal strings to the panel's primary_goal enum
const WORKOUT_GOAL_NORMALIZE = {
  fat_loss: 'fat_loss', lose_fat: 'fat_loss',
  muscle_gain: 'muscle_gain', build_muscle: 'muscle_gain',
  strength: 'strength', get_stronger: 'strength',
  endurance: 'endurance',
  general_fitness: 'general_fitness',
  sport_performance: 'general_fitness',
};

function WorkoutPanel({ onSaved }) {
  const [wk, setWk] = useState({ primary_goal: null, experience_level: 'intermediate', days_per_week: 4, session_duration_min: 50, equipment_available: [] });
  const [effective, setEffective] = useState(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  // Track which fields the user actually edited so AI-plan-hydrated values don't get
  // locked onto the profile entity and mask future plan updates.
  const dirtyRef = useRef(new Set());
  const update = (k, v) => {
    dirtyRef.current.add(k);
    setWk(prev => ({ ...prev, [k]: v }));
  };
  const toggleEquip = (item) => {
    dirtyRef.current.add('equipment_available');
    setWk(prev => ({
      ...prev,
      equipment_available: (prev.equipment_available || []).includes(item)
        ? prev.equipment_available.filter(e => e !== item)
        : [...(prev.equipment_available || []), item],
    }));
  };

  useEffect(() => {
    loadProfileEffectiveValues().then(snapshot => {
      setEffective(snapshot);
      const r = snapshot.workoutProfile || {};
      const eff = snapshot.effective;
      const planFields = snapshot.planFields;
      // Hydrate from AI plan when the field on WorkoutProfile is blank/default
      const normalizedGoal = WORKOUT_GOAL_NORMALIZE[r.primary_goal] || r.primary_goal
        || (planFields?.primaryGoal ? null : null); // Goal text doesn't map cleanly — leave null
      setWk({
        ...r,
        primary_goal: normalizedGoal,
        days_per_week: Number(r.days_per_week) > 0 ? r.days_per_week : (eff.daysPerWeek.value || 4),
        session_duration_min: Number(r.session_duration_min) > 0 ? r.session_duration_min : (eff.sessionDurationMin.value || 50),
        equipment_available: r.equipment_available?.length ? r.equipment_available : (eff.equipment.value || []),
      });
    }).catch(() => {}).finally(() => setLoading(false));
  }, []);

  const daysSource = effective?.effective?.daysPerWeek?.source || 'none';
  const sessionSource = effective?.effective?.sessionDurationMin?.source || 'none';
  const equipSource = effective?.effective?.equipment?.source || 'none';

  return (
    <div className="space-y-5">
      <div>
        <p className="text-xs font-semibold mb-2" style={{ color: '#91968e' }}>Training goal</p>
        <div className="flex flex-wrap gap-2">
          {['muscle_gain', 'fat_loss', 'strength', 'endurance', 'general_fitness'].map(g => (
            <button key={g} onClick={() => update('primary_goal', g)}
              className="px-3 py-1.5 rounded-full text-xs border"
              style={{ background: wk.primary_goal === g ? 'rgba(200,224,0,0.12)' : '#f2efe7', borderColor: wk.primary_goal === g ? 'rgba(200,224,0,0.4)' : '#e8e1d4', color: wk.primary_goal === g ? ACCENT_DARK : '#5d635d' }}>
              {g.replace('_', ' ')}
            </button>
          ))}
        </div>
      </div>

      <div>
        <p className="text-xs font-semibold mb-2" style={{ color: '#91968e' }}>Experience level</p>
        <div className="flex gap-2">
          {['beginner', 'intermediate', 'advanced'].map(l => (
            <button key={l} onClick={() => update('experience_level', l)} className="flex-1 py-2.5 rounded-xl text-xs font-medium border capitalize"
              style={{ background: wk.experience_level === l ? ACCENT : '#f2efe7', borderColor: wk.experience_level === l ? ACCENT : '#e8e1d4', color: '#141613' }}>
              {l}
            </button>
          ))}
        </div>
      </div>

      <div>
        <div className="flex items-center justify-between mb-1">
          <div className="flex items-center gap-2">
            <p className="text-xs font-semibold" style={{ color: '#91968e' }}>Days per week</p>
            {daysSource === 'ai_plan' && (
              <span className="text-[9px] font-semibold px-1.5 py-0.5 rounded-full" style={{ background: 'rgba(200,224,0,0.12)', color: ACCENT_DARK }}>AI plan</span>
            )}
          </div>
          <span className="text-sm font-bold" style={{ color: ACCENT_DARK }}>{wk.days_per_week}</span>
        </div>
        <input type="range" min={1} max={7} value={wk.days_per_week} onChange={e => update('days_per_week', Number(e.target.value))} className="w-full" style={{ accentColor: ACCENT }} />
      </div>

      <div>
        <div className="flex items-center justify-between mb-1">
          <div className="flex items-center gap-2">
            <p className="text-xs font-semibold" style={{ color: '#91968e' }}>Session duration (min)</p>
            {sessionSource === 'ai_plan' && (
              <span className="text-[9px] font-semibold px-1.5 py-0.5 rounded-full" style={{ background: 'rgba(200,224,0,0.12)', color: ACCENT_DARK }}>AI plan</span>
            )}
          </div>
          <span className="text-sm font-bold" style={{ color: ACCENT_DARK }}>{wk.session_duration_min}</span>
        </div>
        <input type="range" min={20} max={120} step={5} value={wk.session_duration_min} onChange={e => update('session_duration_min', Number(e.target.value))} className="w-full" style={{ accentColor: ACCENT }} />
      </div>

      <div>
        <div className="flex items-center justify-between mb-2">
          <p className="text-xs font-semibold" style={{ color: '#91968e' }}>Equipment available</p>
          {equipSource === 'ai_plan' && (
            <span className="text-[9px] font-semibold px-1.5 py-0.5 rounded-full" style={{ background: 'rgba(200,224,0,0.12)', color: ACCENT_DARK }}>From AI plan</span>
          )}
        </div>
        <div className="flex flex-wrap gap-2">
          {EQUIPMENT_OPTIONS.map(eq => (
            <button key={eq} onClick={() => toggleEquip(eq.toLowerCase())}
              className="px-3 py-1.5 rounded-full text-xs border"
              style={{ background: (wk.equipment_available || []).includes(eq.toLowerCase()) ? 'rgba(200,224,0,0.12)' : '#f2efe7', borderColor: (wk.equipment_available || []).includes(eq.toLowerCase()) ? 'rgba(200,224,0,0.4)' : '#e8e1d4', color: (wk.equipment_available || []).includes(eq.toLowerCase()) ? ACCENT_DARK : '#5d635d' }}>
              {eq}
            </button>
          ))}
        </div>
      </div>

      {loading ? <div className="flex justify-center py-4"><Loader2 size={18} className="animate-spin" style={{ color: '#8ea400' }} /></div> : null}
      <button onClick={async () => {
        setSaving(true);
        // Only persist fields the user actually touched. AI-plan-hydrated defaults
        // stay as display values and don't override the active plan.
        const dirty = dirtyRef.current;
        const updates = {};
        if (dirty.has('primary_goal'))         updates.primary_goal = wk.primary_goal;
        if (dirty.has('experience_level'))     updates.experience_level = wk.experience_level;
        if (dirty.has('days_per_week'))        updates.days_per_week = Number(wk.days_per_week) || 0;
        if (dirty.has('session_duration_min')) updates.session_duration_min = Number(wk.session_duration_min) || 0;
        if (dirty.has('equipment_available'))  updates.equipment_available = wk.equipment_available || [];
        if (Object.keys(updates).length > 0) {
          await saveWorkoutProfile(updates).catch(() => {});
        }
        dirtyRef.current = new Set();
        setSaving(false);
        onSaved?.();
      }} disabled={saving} className="w-full py-3.5 rounded-2xl text-sm font-bold" style={{ background: ACCENT, color: '#141613' }}>
        {saving ? 'Saving…' : 'Save Preferences'}
      </button>
    </div>
  );
}

function CoachingPanel({ onSaved }) {
  const [style, setStyle] = useState('balanced');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    backend.entities.UserProfile.list('-updated_date', 1).then(records => {
      if (records.length > 0 && records[0].coaching_style) setStyle(records[0].coaching_style);
    }).catch(() => {});
  }, []);

  return (
    <div className="space-y-4">
      <p className="text-xs" style={{ color: '#91968e' }}>Choose your coaching tone.</p>
      {COACHING_STYLES.map(s => (
        <button key={s.id} onClick={() => setStyle(s.id)}
          className="w-full p-4 rounded-2xl border text-left"
          style={{ background: style === s.id ? 'rgba(200,224,0,0.08)' : '#ffffff', borderColor: style === s.id ? 'rgba(200,224,0,0.4)' : '#e8e1d4' }}>
          <div className="flex items-center justify-between mb-1">
            <p className="text-sm font-semibold" style={{ color: '#141613' }}>{s.label}</p>
            {style === s.id && <Check size={14} style={{ color: ACCENT_DARK }} />}
          </div>
          <p className="text-xs" style={{ color: '#91968e' }}>{s.desc}</p>
        </button>
      ))}
      <button onClick={async () => {
        setSaving(true);
        await saveUserProfile({ coaching_style: style }).catch(() => {});
        setSaving(false);
        onSaved?.();
      }} disabled={saving} className="w-full py-3.5 rounded-2xl text-sm font-bold" style={{ background: ACCENT, color: '#141613' }}>
        {saving ? 'Saving…' : 'Save Style'}
      </button>
    </div>
  );
}

function UnitsPanel() {
  const [system, setSystem] = useState(getUnitSystem());

  const handleSelect = (s) => {
    setSystem(s);
    setUnitSystem(s);
  };

  return (
    <div className="space-y-4">
      <p className="text-xs" style={{ color: '#91968e' }}>
        Choose your preferred measurement system. This affects height, weight, and distance inputs throughout the app.
      </p>
      {Object.entries(UNIT_SYSTEMS).map(([key, meta]) => (
        <button key={key} onClick={() => handleSelect(key)}
          className="w-full p-4 rounded-2xl border text-left transition-all"
          style={{ background: system === key ? 'rgba(200,224,0,0.08)' : '#ffffff', borderColor: system === key ? 'rgba(200,224,0,0.4)' : '#e8e1d4' }}>
          <div className="flex items-center justify-between mb-1">
            <p className="text-sm font-semibold" style={{ color: '#141613' }}>{meta.label}</p>
            {system === key && <Check size={14} style={{ color: ACCENT_DARK }} />}
          </div>
          <p className="text-xs" style={{ color: '#91968e' }}>
            Height: {meta.height} · Weight: {meta.weight} · Distance: {meta.distance}
          </p>
        </button>
      ))}
      <p className="text-[10px] text-center pt-1" style={{ color: '#d9d1c2' }}>
        Changes apply immediately — reopen forms to see updated units.
      </p>
    </div>
  );
}

// -------- Limitations panel (reads InjuryProfile) --------

function LimitationsPanel() {
  const [injuries, setInjuries] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    loadActiveInjuries().then(setInjuries).catch(() => setInjuries([])).finally(() => setLoading(false));
  }, []);

  if (loading) return <div className="flex justify-center py-8"><Loader2 size={18} className="animate-spin" style={{ color: '#8ea400' }} /></div>;

  return (
    <div className="space-y-3">
      <p className="text-xs" style={{ color: '#91968e' }}>Logged limitations are automatically used to adapt workout recommendations.</p>
      {injuries.length === 0 && <p className="text-sm text-center py-4" style={{ color: '#91968e' }}>No active limitations logged.</p>}
      {injuries.map((l) => (
        <div key={l.id} className="p-3.5 rounded-xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
          <p className="text-sm font-semibold" style={{ color: '#141613' }}>{l.body_area}</p>
          <p className="text-xs" style={{ color: '#91968e' }}>{(l.severity || '').replace('_', ' ')}{l.notes ? ` · ${l.notes}` : ''}</p>
        </div>
      ))}
      <p className="text-xs text-center pt-2" style={{ color: '#91968e' }}>Manage limitations in the Recovery tab.</p>
    </div>
  );
}

// -------- Main Profile page --------

export default function Profile() {
  const navigate = useNavigate();
  const { logout } = useAuth();
  const { isPremium, subscription, loading: subLoading } = useSubscription();

  const [activeSection, setActiveSection] = useState(() => {
    // Open section from query param on mount
    const params = new URLSearchParams(window.location.search);
    return params.get('section') || null;
  });
  const [savedSection, setSavedSection] = useState(null);
  const [isCustomizing, setIsCustomizing] = useState(false);
  const [userName, setUserName] = useState('');
  const [editingName, setEditingName] = useState(false);
  const [nameInput, setNameInput] = useState('');
  const [savingName, setSavingName] = useState(false);
  const [goalCount, setGoalCount] = useState(0);
  const [daysPerWeek, setDaysPerWeek] = useState(null);
  const [showDeleteModal, setShowDeleteModal] = useState(false);
  const custLayout = usePageLayout(PAGE_KEY);

  useEffect(() => {
    // Load summary data for profile header.
    // Combines profile entity values with AI plan fallbacks via loadProfileEffectiveValues
    // so the name + training days reflect the AI plan if the user hasn't set them on UserProfile.
    Promise.all([
      loadProfileEffectiveValues(),
      backend.entities.Goal.filter({ status: 'active' }, '-created_date', 20),
    ]).then(([snapshot, goals]) => {
      const eff = snapshot.effective;
      const name = eff.displayName || '';
      setUserName(name);
      setNameInput(name);
      setGoalCount(goals.length);
      const d = eff.daysPerWeek.value;
      if (d) setDaysPerWeek(d === 14 ? '2x/day' : d);
    }).catch(() => {});
  }, []);

  const handleSaved = () => {
    setSavedSection(activeSection);
    setTimeout(() => { setSavedSection(null); setActiveSection(null); }, 900);
  };

  const panelMap = {
    goals: <GoalsPanel />,
    nutrition: <NutritionPanel onSaved={handleSaved} />,
    workout: <WorkoutPanel onSaved={handleSaved} />,
    limitations: <LimitationsPanel />,
    coaching: <CoachingPanel onSaved={handleSaved} />,
    units: <UnitsPanel />,
  };

  return (
    <div className="min-h-screen" style={{ background: '#f6f2e8' }}>
      <div className="sticky top-0 z-40 px-5 pt-12 pb-4" style={{ background: 'rgba(251,248,241,0.95)', backdropFilter: 'blur(24px)', borderBottom: '1px solid #e8e1d4' }}>
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            {activeSection && (
              <button onClick={() => setActiveSection(null)} className="w-8 h-8 rounded-xl flex items-center justify-center border" style={{ background: '#f2efe7', borderColor: '#e8e1d4' }}>
                <ChevronRight size={14} className="rotate-180" style={{ color: '#5d635d' }} />
              </button>
            )}
            <div>
              <h1 className="text-lg font-bold tracking-tight" style={{ color: '#141613' }}>
                {activeSection ? SECTIONS.find(s => s.id === activeSection)?.label : 'Profile'}
              </h1>
              {!activeSection && <p className="text-xs" style={{ color: '#91968e' }}>Personalize your coaching experience</p>}
            </div>
          </div>
          {!activeSection && (
            <button onClick={() => navigate('/')}
              className="flex items-center gap-1.5 px-3 py-2 rounded-xl text-xs font-semibold border"
              style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}>
              ← Back
            </button>
          )}
        </div>
      </div>

      <div className="px-5 pb-8 space-y-4 pt-5">
        <AnimatePresence mode="wait">
          {!activeSection ? (
            <motion.div key="main" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} className="space-y-4">
              {/* Avatar */}
              <div className="p-5 rounded-3xl border text-center" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                <div className="w-16 h-16 rounded-full mx-auto mb-3 flex items-center justify-center" style={{ background: 'rgba(200,224,0,0.12)', border: '2px solid rgba(200,224,0,0.3)' }}>
                   <User size={26} style={{ color: ACCENT_DARK }} />
                 </div>
                 {editingName ? (
                   <div className="flex items-center gap-2 mb-1 justify-center">
                     <input
                       autoFocus
                       value={nameInput}
                       onChange={e => setNameInput(e.target.value)}
                       className="px-3 py-1.5 rounded-xl border text-sm text-center outline-none font-bold"
                       style={{ background: '#f6f2e8', borderColor: 'rgba(200,224,0,0.5)', color: '#141613', width: 160 }}
                       onKeyDown={async e => {
                         if (e.key === 'Enter') {
                           setSavingName(true);
                           await saveUserProfile({ display_name: nameInput.trim() }).catch(() => {});
                           setUserName(nameInput.trim());
                           setEditingName(false);
                           setSavingName(false);
                         } else if (e.key === 'Escape') {
                           setNameInput(userName);
                           setEditingName(false);
                         }
                       }}
                     />
                     <button
                       onClick={async () => {
                         setSavingName(true);
                         await saveUserProfile({ display_name: nameInput.trim() }).catch(() => {});
                         setUserName(nameInput.trim());
                         setEditingName(false);
                         setSavingName(false);
                       }}
                       className="w-7 h-7 rounded-full flex items-center justify-center"
                       style={{ background: ACCENT }}
                     >
                       {savingName ? <Loader2 size={12} className="animate-spin" /> : <Check size={12} style={{ color: '#141613' }} />}
                     </button>
                   </div>
                 ) : (
                   <button onClick={() => { setNameInput(userName); setEditingName(true); }} className="group flex items-center gap-1.5 justify-center mx-auto mb-1">
                     <h2 className="text-base font-bold" style={{ color: '#141613' }}>{userName || 'Your Profile'}</h2>
                     <span className="text-[10px] opacity-0 group-hover:opacity-100 transition-opacity" style={{ color: '#91968e' }}>edit</span>
                   </button>
                 )}
                 <p className="text-xs mt-0.5 mb-4" style={{ color: '#91968e' }}>
                   {goalCount} active goals · {daysPerWeek
                     ? (typeof daysPerWeek === 'string' ? `${daysPerWeek} training` : `${daysPerWeek}x/week training`)
                     : 'N/A training days'}
                 </p>
                 <div className="grid grid-cols-2 gap-3 pt-4 border-t" style={{ borderColor: '#f2efe7' }}>
                  {[
                    { label: 'Goals', value: goalCount },
                    { label: typeof daysPerWeek === 'string' ? 'Training' : 'Days/week', value: daysPerWeek ?? 'N/A' },
                  ].map(s => (
                   <div key={s.label} className="text-center">
                     <div className="text-lg font-black" style={{ color: ACCENT_DARK }}>{s.value}</div>
                     <div className="text-[10px]" style={{ color: '#91968e' }}>{s.label}</div>
                   </div>
                 ))}
                 </div>
              </div>

              {/* Active goals preview handled by GoalsPanel */}

              {/* Customize sections */}
              <p className="text-[10px] font-bold uppercase tracking-widest px-1" style={{ color: '#91968e' }}>Customise</p>
              <div className="rounded-3xl border overflow-hidden" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                {SECTIONS.map((section, i) => (
                  <div key={section.id}>
                    <button onClick={() => setActiveSection(section.id)}
                      className="w-full flex items-center justify-between px-5 py-4 transition-opacity hover:opacity-80">
                      <div className="flex items-center gap-3">
                        <div className="w-9 h-9 rounded-xl flex items-center justify-center" style={{ background: 'rgba(200,224,0,0.1)' }}>
                          <section.icon size={16} style={{ color: ACCENT_DARK }} />
                        </div>
                        <div className="text-left">
                          <p className="text-sm font-medium" style={{ color: '#141613' }}>{section.label}</p>
                          <p className="text-xs" style={{ color: '#91968e' }}>{section.subtitle}</p>
                        </div>
                      </div>
                      <div className="flex items-center gap-2">
                        {savedSection === section.id && <Check size={13} style={{ color: ACCENT_DARK }} />}
                        <ChevronRight size={16} style={{ color: '#d9d1c2' }} />
                      </div>
                    </button>
                    {i < SECTIONS.length - 1 && <div className="mx-5 h-px" style={{ background: '#f2efe7' }} />}
                  </div>
                ))}
              </div>

              {/* Premium / Billing */}
              <div className="rounded-3xl border overflow-hidden" style={{ background: isPremium ? 'linear-gradient(145deg, #141613 0%, #1c2110 100%)' : '#ffffff', borderColor: isPremium ? 'rgba(200,224,0,0.2)' : '#e8e1d4' }}>
                <button onClick={() => navigate('/billing')} className="w-full flex items-center justify-between px-5 py-4">
                  <div className="flex items-center gap-3">
                    <div className="w-9 h-9 rounded-xl flex items-center justify-center" style={{ background: isPremium ? 'rgba(200,224,0,0.15)' : 'rgba(200,224,0,0.1)' }}>
                      {isPremium ? <Crown size={16} style={{ color: ACCENT }} /> : <Sparkles size={16} style={{ color: ACCENT_DARK }} />}
                    </div>
                    <div className="text-left">
                      <p className="text-sm font-bold" style={{ color: isPremium ? '#ffffff' : '#141613' }}>
                        {isPremium ? 'Execute Premium' : 'Upgrade to Premium'}
                      </p>
                      <p className="text-xs" style={{ color: isPremium ? '#4a4f4a' : '#91968e' }}>
                        {isPremium
                          ? `Active${subscription?.current_period_end ? ' · Renews ' + new Date(subscription.current_period_end).toLocaleDateString('en-US', { month: 'short', day: 'numeric' }) : ''}`
                          : 'Unlock AI plans, meal guidance & insights'}
                      </p>
                    </div>
                  </div>
                  <ChevronRight size={16} style={{ color: isPremium ? '#4a4f4a' : '#d9d1c2' }} />
                </button>
              </div>

              {/* Reset app data */}
              <ResetAppDataButton />

              {/* Delete account */}
              <button onClick={() => setShowDeleteModal(true)}
                className="w-full py-4 rounded-2xl flex items-center justify-center gap-2 text-sm font-semibold border"
                style={{ background: 'rgba(176,90,58,0.08)', borderColor: 'rgba(176,90,58,0.25)', color: '#b05a3a' }}>
                <Trash2 size={16} /> Delete Account
              </button>

              {/* Sign out */}
              <button onClick={() => logout()}
                className="w-full py-4 rounded-2xl flex items-center justify-center gap-2 text-sm font-semibold border"
                style={{ background: 'rgba(176,90,58,0.06)', borderColor: 'rgba(176,90,58,0.2)', color: '#b05a3a' }}>
                <LogOut size={16} /> Sign Out
              </button>

              <div className="text-center py-3">
                <p className="text-xs font-medium" style={{ color: '#91968e' }}>Execute · Personal Performance OS</p>
                <div className="flex items-center justify-center gap-3 mt-2">
                  <button onClick={() => navigate('/privacy')} className="text-[11px] font-medium underline" style={{ color: '#91968e' }}>Privacy Policy</button>
                  <span className="text-[11px]" style={{ color: '#d9d1c2' }}>·</span>
                  <button onClick={() => navigate('/terms')} className="text-[11px] font-medium underline" style={{ color: '#91968e' }}>Terms</button>
                </div>
                <p className="text-[10px] mt-1.5" style={{ color: '#d9d1c2' }}>v2.0</p>
              </div>
            </motion.div>
          ) : (
            <motion.div key={activeSection} initial={{ opacity: 0, x: 24 }} animate={{ opacity: 1, x: 0 }} exit={{ opacity: 0, x: -24 }}>
              {panelMap[activeSection]}
            </motion.div>
          )}
        </AnimatePresence>
      </div>

      <AnimatePresence>
        {showDeleteModal && (
          <DeleteAccountModal
            logout={logout}
            onConfirm={() => setShowDeleteModal(false)}
            onCancel={() => setShowDeleteModal(false)}
          />
        )}
      </AnimatePresence>
    </div>
  );
}