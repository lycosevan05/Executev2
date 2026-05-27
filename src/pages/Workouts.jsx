import { useState, useEffect } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import {
  Sparkles, Loader2, Dumbbell, Search, ChevronDown, ChevronUp,
  Check, Leaf, BatteryCharging, RotateCcw, Target, Calendar, SlidersHorizontal, Play,
} from 'lucide-react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { backend } from '@/api/backendClient';
import { getUnitSystem, kgToLbs } from '@/lib/units';
import WorkoutCompleteAnimation from '@/components/workouts/WorkoutCompleteAnimation';
import WorkoutHeroCard from '@/components/workouts/WorkoutHeroCard';
import CustomSplitSheet from '@/components/workouts/CustomSplitSheet';
import { getOrCreateWorkoutPlanForDate } from '@/lib/plans/getOrCreateWorkoutPlanForDate';
import { loadActiveAIPlan, userScopedFilter } from '@/lib/personalizationSync';
import PremiumPaywall from '@/components/premium/PremiumPaywall';
import { PremiumBadge } from '@/components/premium/PremiumBadge';
import { useSubscription } from '@/hooks/useSubscription';
import { appCache } from '@/lib/appCache';
import { getPlanDaySessionTitle } from '@/lib/planDayDisplay';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

const TABS = [
  { id: 'today', label: 'Today' },
  { id: 'split', label: 'My Split' },
  { id: 'library', label: 'Library' },
  { id: 'history', label: 'History' },
];

const EXERCISES = [
  // Push
  { id: 1,  name: 'Barbell Bench Press',       muscles: 'Chest, Triceps, Shoulders',    category: 'Push', equipment: 'Barbell',            difficulty: 'intermediate', notes: 'Retract shoulder blades. Controlled descent. Touch chest lightly.' },
  { id: 2,  name: 'Overhead Press',             muscles: 'Shoulders, Triceps, Core',     category: 'Push', equipment: 'Barbell',            difficulty: 'intermediate', notes: 'Tight core. Press bar in a slight arc over head. Lock out at top.' },
  { id: 3,  name: 'Incline Dumbbell Press',     muscles: 'Upper Chest, Front Delts',     category: 'Push', equipment: 'Dumbbells',          difficulty: 'intermediate', notes: '30–45° incline. Elbows at 45° to body. Full range of motion.' },
  { id: 4,  name: 'Dumbbell Shoulder Press',    muscles: 'Shoulders, Triceps',           category: 'Push', equipment: 'Dumbbells',          difficulty: 'beginner',     notes: 'Neutral grip or pronated. Press overhead, slight forward lean is fine.' },
  { id: 5,  name: 'Lateral Raise',              muscles: 'Lateral Delts',                category: 'Push', equipment: 'Dumbbells',          difficulty: 'beginner',     notes: 'Slight forward lean. Raise to shoulder height. Control descent.' },
  { id: 6,  name: 'Cable Fly',                  muscles: 'Chest, Anterior Delts',        category: 'Push', equipment: 'Cable',              difficulty: 'beginner',     notes: 'Slight elbow bend throughout. Think hugging a tree.' },
  { id: 7,  name: 'Tricep Pushdown',            muscles: 'Triceps',                      category: 'Push', equipment: 'Cable',              difficulty: 'beginner',     notes: 'Elbows tucked at sides. Full extension at bottom.' },
  { id: 8,  name: 'Close-Grip Bench Press',     muscles: 'Triceps, Chest',               category: 'Push', equipment: 'Barbell',            difficulty: 'intermediate', notes: 'Hands shoulder-width apart. Keep elbows close to body.' },
  { id: 9,  name: 'Dips',                       muscles: 'Chest, Triceps, Shoulders',    category: 'Push', equipment: 'Dip bars',           difficulty: 'intermediate', notes: 'Lean forward slightly for chest emphasis. Full lockout at top.' },
  { id: 10, name: 'Arnold Press',               muscles: 'Shoulders, Triceps',           category: 'Push', equipment: 'Dumbbells',          difficulty: 'intermediate', notes: 'Rotate wrists from palms-in to palms-out as you press.' },
  { id: 11, name: 'Push-Up',                    muscles: 'Chest, Triceps, Shoulders',    category: 'Push', equipment: 'None',               difficulty: 'beginner',     notes: 'Hands slightly wider than shoulders. Core tight. Full depth.' },
  { id: 12, name: 'Overhead Tricep Extension',  muscles: 'Triceps Long Head',            category: 'Push', equipment: 'Dumbbell or Cable',  difficulty: 'beginner',     notes: 'Keep elbows close to ears. Full stretch at bottom.' },
  // Pull
  { id: 13, name: 'Deadlift',                   muscles: 'Hamstrings, Glutes, Back',     category: 'Pull', equipment: 'Barbell',            difficulty: 'advanced',     notes: 'Neutral spine throughout. Hinge at hips first, then knees.' },
  { id: 14, name: 'Pull-Up',                    muscles: 'Lats, Biceps, Rear Delts',     category: 'Pull', equipment: 'Pull-up bar',        difficulty: 'intermediate', notes: 'Full hang at bottom. Drive elbows down and back to chest.' },
  { id: 15, name: 'Barbell Row',                muscles: 'Lats, Rhomboids, Biceps',      category: 'Pull', equipment: 'Barbell',            difficulty: 'intermediate', notes: 'Hinge to ~45°. Pull bar to lower chest. Squeeze scapula.' },
  { id: 16, name: 'Dumbbell Row',               muscles: 'Lats, Rhomboids, Biceps',      category: 'Pull', equipment: 'Dumbbell',           difficulty: 'beginner',     notes: 'Stable base. Pull elbow toward hip. Full stretch at bottom.' },
  { id: 17, name: 'Face Pull',                  muscles: 'Rear Delts, Rotator Cuff',     category: 'Pull', equipment: 'Cable',              difficulty: 'beginner',     notes: 'Pull toward face with external rotation. Great for shoulder health.' },
  { id: 18, name: 'Lat Pulldown',               muscles: 'Lats, Biceps',                 category: 'Pull', equipment: 'Cable',              difficulty: 'beginner',     notes: 'Slight lean back. Pull bar to upper chest. Full stretch at top.' },
  { id: 19, name: 'Bicep Curl',                 muscles: 'Biceps, Brachialis',           category: 'Pull', equipment: 'Dumbbells or Barbell', difficulty: 'beginner',   notes: 'No swinging. Supinate wrist at top of movement.' },
  { id: 20, name: 'Hammer Curl',                muscles: 'Brachialis, Brachioradialis',  category: 'Pull', equipment: 'Dumbbells',          difficulty: 'beginner',     notes: 'Neutral grip throughout. Elbows stay at sides.' },
  { id: 21, name: 'Seated Cable Row',           muscles: 'Mid Back, Lats, Biceps',       category: 'Pull', equipment: 'Cable',              difficulty: 'beginner',     notes: 'Tall posture. Drive elbows back. Squeeze mid-back at peak.' },
  { id: 22, name: 'T-Bar Row',                  muscles: 'Lats, Rhomboids, Lower Traps', category: 'Pull', equipment: 'Barbell',            difficulty: 'intermediate', notes: 'Chest against pad if available. Pull to sternum. Controlled negative.' },
  { id: 23, name: 'Chest-Supported Row',        muscles: 'Upper Back, Rear Delts',       category: 'Pull', equipment: 'Dumbbells',          difficulty: 'beginner',     notes: 'Eliminates lower back involvement. Pull elbows wide for upper back.' },
  { id: 24, name: 'Chin-Up',                    muscles: 'Lats, Biceps',                 category: 'Pull', equipment: 'Pull-up bar',        difficulty: 'intermediate', notes: 'Supinated grip. Initiate with scapula retraction, then pull.' },
  // Legs
  { id: 25, name: 'Barbell Squat',              muscles: 'Quads, Glutes, Core',          category: 'Legs', equipment: 'Barbell',            difficulty: 'intermediate', notes: 'Keep chest up, knees tracking over toes. Drive through heels.' },
  { id: 26, name: 'Romanian Deadlift',          muscles: 'Hamstrings, Glutes',           category: 'Legs', equipment: 'Barbell or Dumbbells', difficulty: 'beginner',  notes: 'Slight knee bend. Push hips back. Feel stretch in hamstrings.' },
  { id: 27, name: 'Hip Thrust',                 muscles: 'Glutes, Hamstrings',           category: 'Legs', equipment: 'Barbell',            difficulty: 'beginner',     notes: 'Drive through heels. Squeeze glutes hard at the top.' },
  { id: 28, name: 'Bulgarian Split Squat',      muscles: 'Quads, Glutes',                category: 'Legs', equipment: 'Dumbbells',          difficulty: 'intermediate', notes: 'Front foot does the work. Rear foot for balance only.' },
  { id: 29, name: 'Leg Press',                  muscles: 'Quads, Glutes, Hamstrings',    category: 'Legs', equipment: 'Machine',            difficulty: 'beginner',     notes: 'Feet shoulder-width. Do not lock knees at top. Full depth.' },
  { id: 30, name: 'Leg Curl',                   muscles: 'Hamstrings',                   category: 'Legs', equipment: 'Machine',            difficulty: 'beginner',     notes: 'Slow eccentric. Avoid hip rise. Squeeze at full contraction.' },
  { id: 31, name: 'Leg Extension',              muscles: 'Quadriceps',                   category: 'Legs', equipment: 'Machine',            difficulty: 'beginner',     notes: 'Full range. Pause briefly at top. Control the descent.' },
  { id: 32, name: 'Walking Lunge',              muscles: 'Quads, Glutes, Hamstrings',    category: 'Legs', equipment: 'Dumbbells or Barbell', difficulty: 'beginner',  notes: 'Long stride. Front knee tracks over toe. Tall torso.' },
  { id: 33, name: 'Sumo Deadlift',              muscles: 'Glutes, Adductors, Hamstrings', category: 'Legs', equipment: 'Barbell',           difficulty: 'intermediate', notes: 'Wide stance, toes out. Hips close to bar. Drive knees out.' },
  { id: 34, name: 'Hack Squat',                 muscles: 'Quads, Glutes',                category: 'Legs', equipment: 'Machine',            difficulty: 'intermediate', notes: 'Feet low on platform for more quad. Control descent fully.' },
  { id: 35, name: 'Calf Raise',                 muscles: 'Gastrocnemius, Soleus',        category: 'Legs', equipment: 'Machine or Dumbbell', difficulty: 'beginner',  notes: 'Full stretch at bottom. Full contraction at top. Slow tempo.' },
  { id: 36, name: 'Goblet Squat',               muscles: 'Quads, Glutes, Core',          category: 'Legs', equipment: 'Dumbbell or Kettlebell', difficulty: 'beginner', notes: 'Hold weight at chest. Deep squat. Elbows inside knees at bottom.' },
  // Core
  { id: 37, name: 'Plank',                      muscles: 'Core, Shoulders',              category: 'Core', equipment: 'None',               difficulty: 'beginner',     notes: "Neutral spine. Breathe steadily. Don't let hips drop or rise." },
  { id: 38, name: 'Cable Crunch',               muscles: 'Rectus Abdominis',             category: 'Core', equipment: 'Cable',              difficulty: 'beginner',     notes: 'Kneel and crunch through the abs — not the hip flexors.' },
  { id: 39, name: 'Hanging Leg Raise',          muscles: 'Lower Abs, Hip Flexors',       category: 'Core', equipment: 'Pull-up bar',        difficulty: 'intermediate', notes: 'Tuck chin. Control the swing. Exhale at the top of the movement.' },
  { id: 40, name: 'Ab Rollout',                 muscles: 'Core, Lats, Shoulders',        category: 'Core', equipment: 'Ab wheel',           difficulty: 'intermediate', notes: 'Keep lower back neutral. Roll out slowly. Pull back with lats.' },
  { id: 41, name: 'Pallof Press',               muscles: 'Anti-Rotation Core',           category: 'Core', equipment: 'Cable',              difficulty: 'beginner',     notes: 'Stand sideways to cable. Press out and hold. Resist rotation.' },
  { id: 42, name: 'Dead Bug',                   muscles: 'Deep Core, Transverse Abs',    category: 'Core', equipment: 'None',               difficulty: 'beginner',     notes: 'Lower back pressed to floor. Extend opposite arm and leg. Breathe.' },
  { id: 43, name: 'Russian Twist',              muscles: 'Obliques, Core',               category: 'Core', equipment: 'Weight plate or Dumbbell', difficulty: 'beginner', notes: 'Lean back 45°. Rotate slowly. Keep feet elevated for more challenge.' },
  // Cardio
  { id: 44, name: 'Box Jump',                   muscles: 'Quads, Glutes, Calves',        category: 'Cardio', equipment: 'Plyo box',         difficulty: 'intermediate', notes: 'Soft landing. Absorb with hips and knees. Step down — don\'t jump.' },
  { id: 45, name: 'Kettlebell Swing',           muscles: 'Glutes, Hamstrings, Core',     category: 'Cardio', equipment: 'Kettlebell',       difficulty: 'intermediate', notes: 'Hip hinge — not a squat. Drive hips forward explosively. Neutral spine.' },
  { id: 46, name: 'Battle Ropes',               muscles: 'Shoulders, Core, Full Body',   category: 'Cardio', equipment: 'Battle ropes',     difficulty: 'beginner',     notes: 'Maintain slight squat. Alternate or double waves. Stay in a rhythm.' },
  { id: 47, name: 'Sled Push',                  muscles: 'Quads, Glutes, Core',          category: 'Cardio', equipment: 'Sled',             difficulty: 'intermediate', notes: 'Lean into the sled. Drive through full foot. Short fast steps.' },
  { id: 48, name: 'Rowing Machine',             muscles: 'Full Body, Back, Legs',        category: 'Cardio', equipment: 'Rowing machine',   difficulty: 'beginner',     notes: 'Drive with legs first, then lean back, then pull arms. Reverse on return.' },
  { id: 49, name: 'Burpee',                     muscles: 'Full Body',                    category: 'Cardio', equipment: 'None',             difficulty: 'beginner',     notes: 'Maintain consistent pace. Land soft. Jump with arms overhead.' },
  { id: 50, name: 'Jump Rope',                  muscles: 'Calves, Shoulders, Coordination', category: 'Cardio', equipment: 'Jump rope',   difficulty: 'beginner',     notes: 'Stay on balls of feet. Small jumps. Wrists do most of the rotation.' },
  { id: 51, name: 'Mountain Climbers',          muscles: 'Core, Shoulders, Hip Flexors', category: 'Cardio', equipment: 'None',             difficulty: 'beginner',     notes: 'Keep hips level. Drive knees toward chest in a running motion.' },
  { id: 52, name: 'Assault Bike Sprint',        muscles: 'Full Body, Cardiovascular',    category: 'Cardio', equipment: 'Assault bike',     difficulty: 'intermediate', notes: 'Push and pull handles while pedaling. All-out effort for short intervals.' },
];

const RECOVERY_STRETCHES = [
  { name: 'Hip Flexor Stretch', duration: '60 sec/side', benefit: 'Releases tight hips from sitting and heavy leg work', muscles: 'Hip flexors, Quads' },
  { name: 'Thoracic Spine Rotation', duration: '30 sec/side', benefit: 'Improves upper back mobility and counters desk posture', muscles: 'Thoracic spine, Obliques' },
  { name: 'Hamstring Stretch', duration: '60 sec/side', benefit: 'Reduces lower back tension and posterior chain tightness', muscles: 'Hamstrings, Lower back' },
  { name: 'Pigeon Pose', duration: '90 sec/side', benefit: 'Deep glute and hip opener — essential after leg days', muscles: 'Glutes, External hip rotators' },
  { name: "Child's Pose", duration: '60 sec', benefit: 'Full spinal decompression and lats release', muscles: 'Lats, Spine, Glutes' },
  { name: 'Cat-Cow', duration: '10 reps slow', benefit: 'Restores spinal mobility and reduces lower back stiffness', muscles: 'Spine, Core' },
  { name: 'Shoulder Cross-Body Stretch', duration: '30 sec/side', benefit: 'Releases posterior shoulder tension after push/pull days', muscles: 'Rear delts, Rotator cuff' },
  { name: 'Calf Stretch', duration: '45 sec/side', benefit: 'Reduces ankle tightness and post-cardio soreness', muscles: 'Gastrocnemius, Soleus' },
];

const NON_TRAINING_TYPES = ['rest', 'recovery', 'mobility'];

function getTodayIso() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function getRollingScheduleDays(days) {
  const today = getTodayIso();
  return (Array.isArray(days) ? days : []).filter(day => day?.date >= today);
}

function isNonTrainingDay(day) {
  if (!day) return false;
  if (day.day_type && NON_TRAINING_TYPES.includes(day.day_type)) return true;
  if (day.workout_needed === false) {
    const t = (day.training_type || '').toLowerCase();
    if (/\brest\b|\brecovery\b|\boff\b|\bmobility\b|\bstretch/.test(t)) return true;
  }
  return false;
}

// ─── Sub-components ───────────────────────────────────────────────────────────

function NoPlanState({ onGenerate }) {
  return (
    <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
      className="flex flex-col items-center py-16 text-center px-4">
      <div className="w-20 h-20 rounded-3xl flex items-center justify-center mb-6"
        style={{ background: 'rgba(200,224,0,0.1)', border: '1px solid rgba(200,224,0,0.2)' }}>
        <Dumbbell size={32} style={{ color: ACCENT_DARK }} />
      </div>
      <h2 className="text-xl font-black tracking-tight mb-2" style={{ color: '#141613' }}>No training plan yet</h2>
      <p className="text-sm leading-relaxed max-w-xs mb-8" style={{ color: '#91968e' }}>
        Complete the Plan Questionnaire to build your personalized training schedule tailored to your goals, equipment, and readiness.
      </p>
      <motion.button whileTap={{ scale: 0.96 }} onClick={onGenerate}
        className="flex items-center gap-2 px-8 py-4 rounded-2xl text-sm font-bold"
        style={{ background: ACCENT, color: '#141613' }}>
        <Sparkles size={15} /> Complete questionnaire <PremiumBadge className="ml-1" />
      </motion.button>
    </motion.div>
  );
}

function PlanSummaryCard({ planSummary, trainingSplit, onViewSplit }) {
  const goal = planSummary?.primary_goal || 'Personalized training plan';
  const split = trainingSplit?.split_type || 'Adaptive split';
  const daysPerWeek = trainingSplit?.days_per_week;
  const sessionLength = trainingSplit?.session_length_minutes;

  return (
    <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
      className="rounded-3xl overflow-hidden"
      style={{ background: 'linear-gradient(145deg, #141613 0%, #1a1f1a 100%)', border: '1px solid rgba(200,224,0,0.18)' }}>
      <div className="p-5">
        <div className="flex items-start gap-3 mb-4">
          <div className="w-10 h-10 rounded-2xl flex items-center justify-center flex-shrink-0"
            style={{ background: 'rgba(200,224,0,0.15)' }}>
            <Target size={18} style={{ color: ACCENT }} />
          </div>
          <div>
            <p className="text-[10px] font-bold uppercase tracking-widest mb-0.5" style={{ color: ACCENT_DARK }}>Your Training Plan</p>
            <h2 className="text-base font-black" style={{ color: '#ffffff', letterSpacing: '-0.03em' }}>Your split is ready</h2>
            <p className="text-xs mt-0.5" style={{ color: '#5d635d' }}>Built from your goals, schedule, equipment, and preferences.</p>
          </div>
        </div>

        <div className="space-y-2 mb-4">
          <div className="px-3 py-2.5 rounded-xl" style={{ background: 'rgba(255,255,255,0.04)' }}>
            <p className="text-[10px] font-semibold uppercase tracking-wider mb-0.5" style={{ color: '#4a4f4a' }}>Primary Goal</p>
            <p className="text-sm font-semibold leading-snug" style={{ color: '#e3e6e3' }}>{goal}</p>
          </div>
          <div className="grid grid-cols-3 gap-1.5">
            <div className="px-2 py-3 rounded-xl text-center min-w-0" style={{ background: 'rgba(255,255,255,0.04)' }}>
              <p className="text-sm font-black truncate" style={{ color: '#ffffff', letterSpacing: '-0.02em' }} title={split}>{split}</p>
              <p className="text-[9px] uppercase tracking-wider mt-0.5" style={{ color: '#6a706a' }}>Split</p>
            </div>
            {daysPerWeek && (
              <div className="px-2 py-3 rounded-xl text-center" style={{ background: 'rgba(255,255,255,0.04)' }}>
                <p className="text-sm font-black" style={{ color: '#ffffff', letterSpacing: '-0.02em' }}>{daysPerWeek}<span className="text-xs font-bold" style={{ color: '#9aa09a' }}>×/wk</span></p>
                <p className="text-[9px] uppercase tracking-wider mt-0.5" style={{ color: '#6a706a' }}>Frequency</p>
              </div>
            )}
            {sessionLength && (
              <div className="px-2 py-3 rounded-xl text-center" style={{ background: 'rgba(255,255,255,0.04)' }}>
                <p className="text-sm font-black" style={{ color: '#ffffff', letterSpacing: '-0.02em' }}>{sessionLength}<span className="text-xs font-bold" style={{ color: '#9aa09a' }}>min</span></p>
                <p className="text-[9px] uppercase tracking-wider mt-0.5" style={{ color: '#6a706a' }}>Session</p>
              </div>
            )}
          </div>
        </div>

        <motion.button whileTap={{ scale: 0.97 }} onClick={onViewSplit}
          className="w-full py-3.5 rounded-2xl font-bold text-sm flex items-center justify-center gap-2"
          style={{ background: ACCENT, color: '#141613' }}>
          <Calendar size={14} /> View my split
        </motion.button>
      </div>
    </motion.div>
  );
}

function NoOverviewCard({ onRegenerate }) {
  return (
    <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
      className="rounded-3xl p-6 border text-center"
      style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
      <div className="w-14 h-14 rounded-2xl flex items-center justify-center mx-auto mb-4"
        style={{ background: 'rgba(200,224,0,0.1)', border: '1px solid rgba(200,224,0,0.2)' }}>
        <Dumbbell size={22} style={{ color: ACCENT_DARK }} />
      </div>
      <p className="text-sm font-bold mb-1" style={{ color: '#141613' }}>Your plan exists, but we could not find a weekly training schedule.</p>
      <p className="text-xs leading-relaxed mb-5" style={{ color: '#91968e' }}>Regenerate your plan overview to rebuild the weekly split.</p>
      <button onClick={onRegenerate}
        className="px-6 py-3 rounded-2xl text-sm font-bold"
        style={{ background: ACCENT, color: '#141613' }}>
        Regenerate plan overview
      </button>
    </motion.div>
  );
}

function BuildWorkoutCard({ overviewDay, onBuild, generating, error }) {
  const sessionTitle = getPlanDaySessionTitle(overviewDay, 'Build this workout');

  return (
    <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
      className="rounded-3xl overflow-hidden" style={{ background: '#ffffff', border: '1px solid #e8e1d4' }}>
      <div className="px-6 pt-6 pb-4">
        <div className="flex items-start gap-4 mb-5">
          <div className="w-14 h-14 rounded-2xl flex items-center justify-center flex-shrink-0"
            style={{ background: 'rgba(200,224,0,0.1)', border: '1px solid rgba(200,224,0,0.2)' }}>
            <Dumbbell size={24} style={{ color: ACCENT_DARK }} />
          </div>
          <div>
            <p className="text-[10px] font-bold uppercase tracking-widest mb-1" style={{ color: '#91968e' }}>Today's Training</p>
            <h2 className="text-xl font-black tracking-tight" style={{ color: '#141613' }}>
              {sessionTitle}
            </h2>
            {overviewDay?.priority && (
              <p className="text-sm mt-0.5" style={{ color: '#5d635d' }}>{overviewDay.priority}</p>
            )}
          </div>
        </div>

        <p className="text-sm leading-relaxed mb-4" style={{ color: '#91968e' }}>
          We'll tailor this session from your training plan, equipment, readiness, and preferences.
        </p>

        {overviewDay?.recovery_focus && (
          <div className="px-4 py-3 rounded-2xl mb-4" style={{ background: '#f9f7f3', border: '1px solid #e8e1d4' }}>
            <p className="text-[10px] font-bold uppercase tracking-widest mb-0.5" style={{ color: '#91968e' }}>Recovery Note</p>
            <p className="text-xs font-medium" style={{ color: '#5d635d' }}>{overviewDay.recovery_focus}</p>
          </div>
        )}

        {error && (
          <p className="text-xs mb-4 px-3 py-2 rounded-xl border" style={{ color: '#b05a3a', background: 'rgba(176,90,58,0.06)', borderColor: 'rgba(176,90,58,0.2)' }}>
            {error}
          </p>
        )}
      </div>

      <div className="px-6 pb-6">
        <motion.button whileTap={{ scale: 0.97 }} onClick={onBuild} disabled={generating}
          className="w-full py-4 rounded-2xl text-sm font-bold flex items-center justify-center gap-2"
          style={{ background: generating ? 'rgba(200,224,0,0.5)' : ACCENT, color: '#141613', boxShadow: generating ? 'none' : '0 5px 20px rgba(200,224,0,0.38)' }}>
          {generating
            ? <><Loader2 size={15} className="animate-spin" /> Building your workout…</>
            : <><Sparkles size={15} /> Build workout</>}
        </motion.button>
      </div>
    </motion.div>
  );
}

function RestDayCard({ overviewDay, onViewRecovery }) {
  const [expanded, setExpanded] = useState(false);
  const dayType = overviewDay?.day_type || 'rest';
  const label = dayType === 'mobility' ? 'Mobility Day' : dayType === 'recovery' ? 'Active Recovery' : 'Rest Day';

  return (
    <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} className="space-y-4">
      <div className="rounded-3xl overflow-hidden" style={{ background: '#ffffff', border: '1px solid #e8e1d4' }}>
        <div className="px-6 pt-6 pb-4">
          <div className="flex items-start gap-4 mb-4">
            <div className="w-14 h-14 rounded-2xl flex items-center justify-center flex-shrink-0"
              style={{ background: 'rgba(93,138,93,0.1)', border: '1px solid rgba(93,138,93,0.2)' }}>
              <Leaf size={24} style={{ color: '#5d8a5d' }} />
            </div>
            <div>
              <p className="text-[10px] font-bold uppercase tracking-widest mb-1" style={{ color: '#91968e' }}>Today</p>
              <h2 className="text-xl font-black tracking-tight" style={{ color: '#141613' }}>{label}</h2>
              <p className="text-sm mt-0.5" style={{ color: '#5d635d' }}>
                {overviewDay?.recovery_focus || 'Focus on mobility, rest, and recovery today.'}
              </p>
            </div>
          </div>
        </div>
        <div className="px-6 pb-6">
          <button onClick={onViewRecovery}
            className="w-full py-3.5 rounded-2xl text-sm font-bold flex items-center justify-center gap-2"
            style={{ background: ACCENT, color: '#141613', boxShadow: '0 4px 16px rgba(200,224,0,0.35)' }}>
            <BatteryCharging size={15} /> View Full Recovery Guidance
          </button>
        </div>
      </div>

      <div className="rounded-3xl overflow-hidden" style={{ background: '#ffffff', border: '1px solid #e8e1d4' }}>
        <button onClick={() => setExpanded(e => !e)}
          className="w-full flex items-center justify-between px-5 py-4">
          <div className="flex items-center gap-3">
            <div className="w-9 h-9 rounded-xl flex items-center justify-center" style={{ background: 'rgba(200,224,0,0.1)' }}>
              <RotateCcw size={16} style={{ color: ACCENT_DARK }} />
            </div>
            <div className="text-left">
              <p className="text-sm font-bold" style={{ color: '#141613' }}>Recovery Stretches</p>
              <p className="text-xs" style={{ color: '#91968e' }}>8 mobility exercises · ~20 min</p>
            </div>
          </div>
          {expanded ? <ChevronUp size={16} style={{ color: '#91968e' }} /> : <ChevronDown size={16} style={{ color: '#91968e' }} />}
        </button>
        <AnimatePresence>
          {expanded && (
            <motion.div initial={{ height: 0, opacity: 0 }} animate={{ height: 'auto', opacity: 1 }}
              exit={{ height: 0, opacity: 0 }} transition={{ duration: 0.22 }} className="overflow-hidden">
              <div className="px-5 pb-5 space-y-3" style={{ borderTop: '1px solid #f2efe7' }}>
                {RECOVERY_STRETCHES.map((stretch, i) => (
                  <div key={i} className="flex items-start gap-3 pt-3">
                    <span className="w-6 h-6 rounded-lg flex items-center justify-center text-[10px] font-bold flex-shrink-0 mt-0.5"
                      style={{ background: 'rgba(200,224,0,0.12)', color: ACCENT_DARK }}>{i + 1}</span>
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center justify-between gap-2">
                        <p className="text-sm font-semibold" style={{ color: '#141613' }}>{stretch.name}</p>
                        <span className="text-[10px] font-semibold flex-shrink-0 px-2 py-0.5 rounded-full"
                          style={{ background: '#f2efe7', color: '#5d635d' }}>{stretch.duration}</span>
                      </div>
                      <p className="text-xs mt-0.5 leading-relaxed" style={{ color: '#5d635d' }}>{stretch.benefit}</p>
                    </div>
                  </div>
                ))}
              </div>
            </motion.div>
          )}
        </AnimatePresence>
      </div>
    </motion.div>
  );
}

// ─── Split row components ─────────────────────────────────────────────────────

function SplitRestRow({ dateLabel, isToday, overviewDay, index }) {
  const [expanded, setExpanded] = useState(false);
  const dayType = overviewDay?.day_type || 'rest';
  const badge = dayType === 'mobility' ? 'Mobility' : dayType === 'recovery' ? 'Recovery' : 'Rest';
  const sessionTitle = getPlanDaySessionTitle(overviewDay, 'Recovery / Rest');

  return (
    <motion.div initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: index * 0.04 }}
      className="rounded-2xl border overflow-hidden"
      style={{ background: '#f9f7f3', borderColor: '#e8e1d4' }}>
      <button className="w-full flex items-center justify-between px-4 py-3.5" onClick={() => setExpanded(e => !e)}>
        <div className="flex items-center gap-3">
          {isToday && <span className="text-[10px] font-bold px-2 py-0.5 rounded-full" style={{ background: ACCENT, color: '#141613' }}>TODAY</span>}
          <Leaf size={14} style={{ color: '#5d8a5d', flexShrink: 0 }} />
          <div className="text-left">
            <p className="text-sm font-semibold" style={{ color: '#5d635d' }}>{dateLabel}</p>
            <p className="text-xs" style={{ color: '#b8b4ac' }}>{sessionTitle}</p>
          </div>
        </div>
        <div className="flex items-center gap-2">
          <span className="text-xs font-semibold px-3 py-1 rounded-full" style={{ background: '#e8e1d4', color: '#91968e' }}>{badge}</span>
          {expanded ? <ChevronUp size={14} style={{ color: '#91968e' }} /> : <ChevronDown size={14} style={{ color: '#91968e' }} />}
        </div>
      </button>
      <AnimatePresence>
        {expanded && (
          <motion.div initial={{ height: 0, opacity: 0 }} animate={{ height: 'auto', opacity: 1 }}
            exit={{ height: 0, opacity: 0 }} transition={{ duration: 0.22 }} className="overflow-hidden">
            <div className="px-4 pb-4 space-y-3" style={{ borderTop: '1px solid #e8e1d4' }}>
              {overviewDay?.recovery_focus && (
                <p className="text-xs pt-3 leading-relaxed" style={{ color: '#5d635d' }}>{overviewDay.recovery_focus}</p>
              )}
              {overviewDay?.priority && (
                <p className="text-xs font-medium" style={{ color: '#91968e' }}>{overviewDay.priority}</p>
              )}
              <p className="text-[10px] font-bold uppercase tracking-widest pt-1" style={{ color: '#91968e' }}>Recovery Stretches · ~20 min</p>
              {RECOVERY_STRETCHES.map((stretch, i) => (
                <div key={i} className="flex items-start gap-3">
                  <span className="w-5 h-5 rounded-md flex items-center justify-center text-[9px] font-bold flex-shrink-0 mt-0.5"
                    style={{ background: 'rgba(200,224,0,0.12)', color: ACCENT_DARK }}>{i + 1}</span>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center justify-between gap-2">
                      <p className="text-sm font-semibold" style={{ color: '#141613' }}>{stretch.name}</p>
                      <span className="text-[10px] font-semibold flex-shrink-0 px-2 py-0.5 rounded-full"
                        style={{ background: '#ffffff', color: '#5d635d' }}>{stretch.duration}</span>
                    </div>
                    <p className="text-xs mt-0.5 leading-relaxed" style={{ color: '#5d635d' }}>{stretch.benefit}</p>
                  </div>
                </div>
              ))}
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </motion.div>
  );
}

function SplitReadyRow({ date, dateLabel, isToday, plan, overviewDay, index, navigate }) {
  const [expanded, setExpanded] = useState(isToday);
  const exercises = plan.exercises || [];
  const workoutName = plan.name?.replace(/^Day\s+\d+\s*[—\-–]\s*/i, '') || getPlanDaySessionTitle(overviewDay, 'Workout');

  return (
    <motion.div initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: index * 0.04 }}
      className="rounded-2xl border overflow-hidden"
      style={{ background: '#ffffff', borderColor: isToday ? 'rgba(200,224,0,0.55)' : '#e0d9cc', boxShadow: isToday ? '0 2px 12px rgba(200,224,0,0.12)' : '0 1px 6px rgba(20,22,19,0.06)' }}>
      <button className="w-full px-4 pt-4 pb-3 flex items-center justify-between text-left"
        style={{ borderBottom: expanded ? '1px solid #f2efe7' : 'none', background: isToday ? 'rgba(200,224,0,0.04)' : 'transparent' }}
        onClick={() => setExpanded(e => !e)}>
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 mb-0.5 flex-wrap">
            {isToday && <span className="text-[10px] font-bold px-2 py-0.5 rounded-full flex-shrink-0" style={{ background: ACCENT, color: '#141613' }}>TODAY</span>}
            <p className="text-[10px] font-semibold uppercase tracking-wider" style={{ color: '#91968e' }}>{dateLabel}</p>
          </div>
          <p className="text-sm font-bold" style={{ color: '#141613' }}>{workoutName}</p>
          {exercises.length > 0 && (
            <p className="text-[10px] mt-0.5" style={{ color: '#91968e' }}>{exercises.length} exercises{plan.duration ? ` · ${plan.duration}` : ''}</p>
          )}
        </div>
        <div className="flex items-center gap-2 flex-shrink-0 ml-2">
          {isToday && (
            <button onClick={(e) => { e.stopPropagation(); navigate(`/workouts?date=${date}&planId=${plan.id}`); }}
              className="px-3 py-1.5 rounded-xl text-xs font-bold"
              style={{ background: ACCENT, color: '#141613' }}>
              Start
            </button>
          )}
          {exercises.length > 0 && (
            expanded ? <ChevronUp size={13} style={{ color: '#91968e' }} /> : <ChevronDown size={13} style={{ color: '#91968e' }} />
          )}
        </div>
      </button>
      <AnimatePresence>
        {expanded && exercises.length > 0 && (
          <motion.div initial={{ height: 0, opacity: 0 }} animate={{ height: 'auto', opacity: 1 }}
            exit={{ height: 0, opacity: 0 }} transition={{ duration: 0.22 }} className="overflow-hidden">
            <div className="px-4 py-3">
              {exercises.map((ex, ei) => (
                <div key={ei} className="flex items-center justify-between py-1.5 border-b last:border-0" style={{ borderColor: '#f9f7f3' }}>
                  <div className="flex items-center gap-2.5">
                    <span className="w-5 h-5 rounded-md flex items-center justify-center text-[9px] font-bold flex-shrink-0"
                      style={{ background: 'rgba(200,224,0,0.12)', color: ACCENT_DARK }}>{ei + 1}</span>
                    <div>
                      <p className="text-sm font-medium" style={{ color: '#141613' }}>{ex.name}</p>
                      <p className="text-[10px]" style={{ color: '#91968e' }}>{ex.muscles}</p>
                    </div>
                  </div>
                  <p className="text-xs font-semibold flex-shrink-0 ml-2" style={{ color: '#5d635d' }}>{ex.sets}×{ex.reps}</p>
                </div>
              ))}
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </motion.div>
  );
}

function SplitNeedsBuildRow({ date, dateLabel, isToday, overviewDay, onBuild, index }) {
  const sessionTitle = getPlanDaySessionTitle(overviewDay, 'Workout scheduled');

  return (
    <motion.div initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: index * 0.04 }}
      className="rounded-2xl border overflow-hidden"
      style={{ background: '#ffffff', borderColor: isToday ? 'rgba(200,224,0,0.4)' : '#e8e1d4' }}>
      <div className="px-4 py-3.5 flex items-center justify-between">
        <div className="flex items-center gap-3 min-w-0">
          <div className="w-9 h-9 rounded-xl flex items-center justify-center flex-shrink-0"
            style={{ background: 'rgba(200,224,0,0.1)' }}>
            <Dumbbell size={15} style={{ color: ACCENT_DARK }} />
          </div>
          <div className="min-w-0">
            <div className="flex items-center gap-2 mb-0.5 flex-wrap">
              {isToday && <span className="text-[10px] font-bold px-1.5 py-0.5 rounded-full flex-shrink-0" style={{ background: ACCENT, color: '#141613' }}>TODAY</span>}
              <p className="text-[10px] font-semibold" style={{ color: '#91968e' }}>{dateLabel}</p>
            </div>
            <p className="text-sm font-bold truncate" style={{ color: '#141613' }}>{sessionTitle}</p>
            <p className="text-xs" style={{ color: '#91968e' }}>{overviewDay?.priority || 'Ready to build'}</p>
          </div>
        </div>
        <button onClick={() => onBuild(date)}
          className="flex-shrink-0 px-3.5 py-2 rounded-xl text-xs font-bold ml-3 flex items-center gap-1.5"
          style={{ background: ACCENT, color: '#141613' }}>
          <Sparkles size={11} /> Build
        </button>
      </div>
      {overviewDay?.recovery_focus && (
        <div className="px-4 pb-3">
          <p className="text-[10px]" style={{ color: '#91968e' }}>Recovery: {overviewDay.recovery_focus}</p>
        </div>
      )}
    </motion.div>
  );
}

// SplitDayRow: driven by overviewDay (not by rolling date array)
function SplitDayRow({ date, overviewDay, splitResult, index, onBuild, navigate }) {
  const isToday = date === getTodayIso();
  const dateLabel = new Date(date + 'T12:00:00').toLocaleDateString('en-US', { weekday: 'long', month: 'short', day: 'numeric' });

  const isRest = isNonTrainingDay(overviewDay);
  const status = splitResult?.status;
  const plan = splitResult?.workoutPlan;

  // Loading skeleton
  if (status === 'loading') {
    return (
      <div className="rounded-2xl border px-4 py-3.5 flex items-center gap-3"
        style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
        <Loader2 size={14} className="animate-spin flex-shrink-0" style={{ color: ACCENT_DARK }} />
        <div>
          <p className="text-sm font-semibold" style={{ color: '#91968e' }}>{dateLabel}</p>
          <p className="text-xs" style={{ color: '#b8b4ac' }}>Loading…</p>
        </div>
      </div>
    );
  }

  // Rest / recovery / mobility day
  if (isRest) {
    return <SplitRestRow dateLabel={dateLabel} isToday={isToday} overviewDay={overviewDay} index={index} />;
  }

  // Training day with built workout
  if (status === 'ready' && plan) {
    return <SplitReadyRow date={date} dateLabel={dateLabel} isToday={isToday} plan={plan} overviewDay={overviewDay} index={index} navigate={navigate} />;
  }

  // Training day — needs build
  return <SplitNeedsBuildRow date={date} dateLabel={dateLabel} isToday={isToday} overviewDay={overviewDay} onBuild={onBuild} index={index} />;
}

// ─── Custom workout today card ────────────────────────────────────────────────

function CustomWorkoutTodayCard({ customDay, splitName, onEditSplit, navigate }) {
  const isRest = !customDay?.type || customDay.type === 'Rest';
  const exercises = customDay?.exercises || [];

  if (isRest) {
    return (
      <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
        className="rounded-3xl overflow-hidden" style={{ background: '#ffffff', border: '1px solid #e8e1d4' }}>
        <div className="px-6 pt-6 pb-4">
          <div className="flex items-start gap-4 mb-3">
            <div className="w-14 h-14 rounded-2xl flex items-center justify-center flex-shrink-0"
              style={{ background: 'rgba(93,138,93,0.1)', border: '1px solid rgba(93,138,93,0.2)' }}>
              <Leaf size={24} style={{ color: '#5d8a5d' }} />
            </div>
            <div>
              <p className="text-[10px] font-bold uppercase tracking-widest mb-1" style={{ color: '#91968e' }}>
                {splitName || 'My Custom Split'} · Today
              </p>
              <h2 className="text-xl font-black tracking-tight" style={{ color: '#141613' }}>Rest Day</h2>
              <p className="text-sm mt-0.5" style={{ color: '#5d635d' }}>{customDay?.day || ''} — Recovery & rest.</p>
            </div>
          </div>
        </div>
        <div className="px-6 pb-6">
          <button onClick={onEditSplit}
            className="w-full py-3.5 rounded-2xl text-sm font-semibold flex items-center justify-center gap-2 border"
            style={{ background: '#f9f7f3', borderColor: '#e8e1d4', color: '#5d635d' }}>
            <SlidersHorizontal size={14} /> Edit Split
          </button>
        </div>
      </motion.div>
    );
  }

  return (
    <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
      className="rounded-3xl overflow-hidden"
      style={{ background: 'linear-gradient(145deg, #141613 0%, #1a1f1a 100%)', border: '1px solid rgba(200,224,0,0.18)' }}>
      <div className="p-5">
        {/* Header */}
        <div className="flex items-start justify-between mb-4">
          <div>
            <div className="flex items-center gap-2 mb-1">
              <div className="w-6 h-6 rounded-lg flex items-center justify-center" style={{ background: 'rgba(200,224,0,0.15)' }}>
                <Dumbbell size={12} style={{ color: ACCENT }} />
              </div>
              <span className="text-[10px] font-bold uppercase tracking-widest" style={{ color: ACCENT_DARK }}>
                {splitName || 'My Custom Split'} · Today
              </span>
            </div>
            <h2 className="text-lg font-black" style={{ color: '#ffffff', letterSpacing: '-0.03em' }}>
              {customDay?.type || customDay?.day || "Today's Workout"}
            </h2>
            <p className="text-xs mt-0.5" style={{ color: '#5d635d' }}>
              {customDay?.day} · {exercises.length} exercise{exercises.length !== 1 ? 's' : ''}
            </p>
          </div>
          <button onClick={onEditSplit}
            className="w-8 h-8 rounded-xl flex items-center justify-center flex-shrink-0"
            style={{ background: 'rgba(255,255,255,0.07)' }}>
            <SlidersHorizontal size={13} style={{ color: '#5d635d' }} />
          </button>
        </div>

        {/* Exercises */}
        {exercises.length > 0 ? (
          <div className="space-y-1.5 mb-4">
            {exercises.map((ex, i) => (
              <div key={i} className="flex items-center justify-between px-3 py-2 rounded-xl"
                style={{ background: 'rgba(255,255,255,0.04)' }}>
                <div className="flex items-center gap-2">
                  <span className="w-4 h-4 rounded-md flex items-center justify-center text-[9px] font-bold"
                    style={{ background: 'rgba(200,224,0,0.12)', color: ACCENT_DARK }}>{i + 1}</span>
                  <p className="text-xs font-medium" style={{ color: '#c8cac8' }}>{ex.name}</p>
                </div>
                <p className="text-[10px]" style={{ color: '#4a4f4a' }}>{ex.sets}×{ex.reps}</p>
              </div>
            ))}
          </div>
        ) : (
          <div className="px-3 py-3 rounded-xl mb-4" style={{ background: 'rgba(255,255,255,0.04)' }}>
            <p className="text-xs" style={{ color: '#4a4f4a' }}>No exercises set for this day. Edit your split to add exercises.</p>
          </div>
        )}

        {/* CTA */}
        <motion.button whileTap={{ scale: 0.97 }}
          onClick={() => navigate('/workout-session', {
            state: {
              workout: {
                name: customDay?.type || 'Custom Workout',
                exercises: exercises,
                date: getTodayIso(),
                source: 'custom_split',
              },
            },
          })}
          className="w-full py-4 rounded-2xl font-black text-sm flex items-center justify-center gap-2"
          style={{ background: ACCENT, color: '#141613' }}>
          <Play size={14} /> Start Workout
        </motion.button>
      </div>
    </motion.div>
  );
}

// ─── Main page ────────────────────────────────────────────────────────────────

export default function Workouts() {
  const navigate = useNavigate();
  const [activeTab, setActiveTab] = useState('today');

  // Hydrate instantly from in-memory cache so returning to Train feels instant.
  const cachedToday = appCache.get('workouts-today') || {};

  // Active AIPlan
  const [activePlan, setActivePlan] = useState(cachedToday.activePlan || null);
  const [planLoading, setPlanLoading] = useState(false);

  // Today tab
  const [workout, setWorkout] = useState(cachedToday.workout || null);
  const [workoutStatus, setWorkoutStatus] = useState(cachedToday.workoutStatus || 'idle');
  const [overviewDay, setOverviewDay] = useState(cachedToday.overviewDay || null);
  const [generatingWorkout, setGeneratingWorkout] = useState(false);
  const [generationError, setGenerationError] = useState(null);
  const [showWorkoutComplete, setShowWorkoutComplete] = useState(false);

  // Split tab — keyed by date from weekly_overview. Hydrate from cache to avoid flash on re-entry.
  const cachedSplit = appCache.get('workouts-split') || {};
  const [splitResults, setSplitResults] = useState(cachedSplit.results || {}); // { [date]: { status, workoutPlan } }
  const [loadingSplit, setLoadingSplit] = useState(false);
  const [buildingAllSplit, setBuildingAllSplit] = useState(false);

  // Library tab
  const [searchQuery, setSearchQuery] = useState('');
  const [selectedCategory, setSelectedCategory] = useState('All');

  // History tab — hydrate from cache for instant tab swaps
  const cachedHistory = appCache.get('workouts-history') || {};
  const [workoutHistory, setWorkoutHistory] = useState(cachedHistory.logs || []);
  const [loadingHistory, setLoadingHistory] = useState(false);
  const [expandedLogId, setExpandedLogId] = useState(null);

  // Custom split
  const [showCustomSplit, setShowCustomSplit] = useState(false);
  const [customSplit, setCustomSplit] = useState(null);
  const [showSplitSourcePicker, setShowSplitSourcePicker] = useState(false);
  const [activeSplitSource, setActiveSplitSource] = useState('ai'); // 'ai' | 'custom'

  const { isPremium } = useSubscription();
  const [showPremiumPaywall, setShowPremiumPaywall] = useState(false);
  const unitSystem = getUnitSystem();

  // Load saved custom split from user profile on mount
  useEffect(() => {
    backend.auth.me().then(user => {
      if (user?.custom_split) {
        try {
          const parsed = JSON.parse(user.custom_split);
          setCustomSplit(parsed);
          if (user?.active_split_source) setActiveSplitSource(user.active_split_source);
        } catch (_) {
          // Ignore malformed saved split data.
        }
      }
    }).catch(() => {});
  }, []);

  const [searchParams] = useSearchParams();
  const dateParam = searchParams.get('date');
  const planIdParam = searchParams.get('planId');
  const targetDate = dateParam || getTodayIso();

  // ── Derived plan data ─────────────────────────────────────────────────────
  const planSummary = activePlan?.plan_summary || activePlan?.plan_payload?.plan_summary || {};
  const trainingSplit = activePlan?.training_split || activePlan?.plan_payload?.training_split || {};
  const weeklyOverview = activePlan?.weekly_overview || activePlan?.plan_payload?.weekly_overview || null;
  const overviewDays = weeklyOverview?.days || [];
  // Rolling: only today + future days for My Split
  const rollingDays = getRollingScheduleDays(overviewDays);

  // ── Load active AIPlan + today's workout atomically on mount/date change ─────
  // Always independently fetches the active plan — never relies on route state or other pages.
  useEffect(() => {
    let cancelled = false;
    setGenerationError(null);

    // If we already have a fresh cached plan + workout, skip network entirely
    if (appCache.isFresh('workouts-today') && cachedToday.workoutStatus === 'ready' && cachedToday.workout) {
      setPlanLoading(false);
      return;
    }

    async function load() {
      // Use the shared plan cache written by Home to avoid a redundant round-trip.
      // Fall back to a fresh fetch only if the cache is empty or stale.
      const cachedPlan = appCache.get('ai-plan:daily');
      const [plan, result] = await Promise.all([
        cachedPlan ? Promise.resolve(cachedPlan) : loadActiveAIPlan('daily').catch(() => null),
        // Fire the workout plan lookup in parallel — it also loads the plan internally if needed
        getOrCreateWorkoutPlanForDate(targetDate, { planId: planIdParam, generate: false, masterPlan: cachedPlan || undefined }).catch(() => null),
      ]);
      if (cancelled) return;

      // Refresh the plan cache if we fetched fresh
      if (!cachedPlan && plan) appCache.set('ai-plan:daily', plan);

      // Only update plan if we got a real result (never wipe a loaded plan with null)
      if (plan !== null) setActivePlan(plan);
      setPlanLoading(false);

      if (!result) {
        const status = plan ? 'needs_generation' : 'no_plan';
        setWorkoutStatus(status);
        setWorkout(null);
        appCache.set('workouts-today', { activePlan: plan, workout: null, workoutStatus: status, overviewDay: null });
        return;
      }

      // If no_plan but activePlan exists, treat as needs_generation
      const resolvedStatus = (result.status === 'no_plan' && plan)
        ? 'needs_generation'
        : result.status;

      setWorkoutStatus(resolvedStatus);
      setWorkout(result.workoutPlan || null);
      setOverviewDay(result.overviewDay || null);
      appCache.set('workouts-today', {
        activePlan: plan,
        workout: result.workoutPlan || null,
        workoutStatus: resolvedStatus,
        overviewDay: result.overviewDay || null,
      });
    }

    load();
    return () => { cancelled = true; };
  }, [targetDate, planIdParam]);

  // ── Build workout handler ─────────────────────────────────────────────────
  const handleBuildWorkout = async (dateOverride) => {
    const buildDate = dateOverride || targetDate;
    const isToday = buildDate === targetDate;

    if (isToday) {
      setGeneratingWorkout(true);
      setGenerationError(null);
    } else {
      setSplitResults(prev => ({ ...prev, [buildDate]: { status: 'loading', workoutPlan: null } }));
    }

    try {
      const result = await getOrCreateWorkoutPlanForDate(buildDate, { generate: true });
      if (isToday) {
        setWorkoutStatus(result.status);
        setWorkout(result.workoutPlan);
        setOverviewDay(result.overviewDay);
      } else {
        setSplitResults(prev => ({ ...prev, [buildDate]: { status: result.status, workoutPlan: result.workoutPlan } }));
      }
    } catch (err) {
      if (isToday) {
        setGenerationError(err?.message || 'Failed to generate workout. Please try again.');
      } else {
        setSplitResults(prev => ({ ...prev, [buildDate]: { status: 'needs_generation', workoutPlan: null } }));
      }
    } finally {
      if (isToday) setGeneratingWorkout(false);
    }
  };

  // ── Build all pending workouts in the rolling split ────────────────────────
  const handleBuildAllSplit = async () => {
    if (buildingAllSplit) return;
    const pending = rollingDays.filter(
      d => !isNonTrainingDay(d) && splitResults[d.date]?.status === 'needs_generation'
    );
    if (!pending.length) return;
    setBuildingAllSplit(true);
    setSplitResults(prev => {
      const next = { ...prev };
      pending.forEach(d => { next[d.date] = { status: 'loading', workoutPlan: null }; });
      return next;
    });
    // Persist every per-day update to appCache as well so a tab switch / re-mount
    // doesn't restore the pre-build "needs_generation" snapshot and resurrect the button.
    const writeDay = (date, value) => {
      setSplitResults(prev => {
        const merged = { ...prev, [date]: value };
        appCache.set('workouts-split', { planId: activePlanId, results: merged });
        return merged;
      });
    };
    for (const day of pending) {
      try {
        const result = await getOrCreateWorkoutPlanForDate(day.date, { generate: true });
        writeDay(day.date, { status: result.status, workoutPlan: result.workoutPlan });
      } catch {
        writeDay(day.date, { status: 'needs_generation', workoutPlan: null });
      }
    }
    setBuildingAllSplit(false);
  };

  // ── Load split tab — rolling days from today forward ─────────────────────
  const activePlanId = activePlan?.id || null;
  useEffect(() => {
    if (activeTab !== 'split' || !rollingDays.length) return;

    // If cached results cover today's rolling days AND cache is still fresh, skip refetch entirely.
    if (appCache.isFresh('workouts-split')) {
      const cached = appCache.get('workouts-split');
      if (cached?.planId === activePlanId && cached?.results) {
        const allCovered = rollingDays.slice(0, 7).every(d => cached.results[d.date]);
        if (allCovered) {
          setSplitResults(cached.results);
          return;
        }
      }
    }

    setLoadingSplit(true);

    // Only mark days as 'loading' if we don't already have a result for them.
    // This prevents the "everything flashes back to skeleton" glitch on re-entry.
    setSplitResults(prev => {
      const next = { ...prev };
      rollingDays.forEach(d => {
        if (!next[d.date]) next[d.date] = { status: 'loading', workoutPlan: null };
      });
      return next;
    });

    let cancelled = false;

    async function loadSplit() {
      const accumulated = {};
      for (const day of rollingDays.slice(0, 7)) {
        if (cancelled) break;
        if (isNonTrainingDay(day)) {
          accumulated[day.date] = { status: 'rest_day', workoutPlan: null };
          setSplitResults(prev => ({ ...prev, [day.date]: accumulated[day.date] }));
          continue;
        }
        const result = await getOrCreateWorkoutPlanForDate(day.date, { generate: false, masterPlan: activePlan || undefined }).catch(() => ({
          status: 'needs_generation', workoutPlan: null,
        }));
        if (cancelled) break;
        accumulated[day.date] = { status: result.status, workoutPlan: result.workoutPlan };
        setSplitResults(prev => ({ ...prev, [day.date]: accumulated[day.date] }));
        // Brief gap to spread API calls and play nicely with rate limits
        await new Promise(r => setTimeout(r, 120));
      }
      if (!cancelled) {
        // Persist the full set so the next tab-swap is instant
        setSplitResults(prev => {
          const merged = { ...prev, ...accumulated };
          appCache.set('workouts-split', { planId: activePlanId, results: merged });
          return merged;
        });
      }
    }

    loadSplit().finally(() => { if (!cancelled) setLoadingSplit(false); });
    return () => { cancelled = true; };
  }, [activeTab, activePlanId]);

  // ── Load history (user-scoped) ────────────────────────────────────────────
  useEffect(() => {
    if (activeTab !== 'history') return;
    // Skip network entirely if cached history is fresh
    if (appCache.isFresh('workouts-history') && workoutHistory.length > 0) return;
    let cancelled = false;
    setLoadingHistory(true);
    (async () => {
      try {
        const filter = await userScopedFilter({ status: 'completed' });
        const logs = await backend.entities.WorkoutLog.filter(filter, '-completed_at', 20);
        if (cancelled) return;
        setWorkoutHistory(logs);
        appCache.set('workouts-history', { logs });
      } catch {
        if (!cancelled) setWorkoutHistory(prev => prev.length ? prev : []);
      } finally {
        if (!cancelled) setLoadingHistory(false);
      }
    })();
    return () => { cancelled = true; };
   
  }, [activeTab]);

  const categories = ['All', ...new Set(EXERCISES.map(e => e.category))];
  const filteredExercises = EXERCISES.filter(ex => {
    const q = searchQuery.toLowerCase();
    const matchSearch = !q || ex.name.toLowerCase().includes(q) || ex.muscles.toLowerCase().includes(q);
    const matchCat = selectedCategory === 'All' || ex.category === selectedCategory;
    return matchSearch && matchCat;
  });

  const isNonAppDate = dateParam && dateParam !== getTodayIso();

  // Today tab: what to show (search all overview days, not just rolling)
  const todayOverviewDay = overviewDays.find(d => d.date === targetDate) || overviewDay;
  const todayIsRestDay = workoutStatus === 'rest_day' || (activePlan && todayOverviewDay && isNonTrainingDay(todayOverviewDay));

  // Custom split today: map JS day-of-week to the day name in the split
  const DAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
  const todayDayName = DAY_NAMES[new Date().getDay()];
  const customTodayDay = customSplit?.days?.find(d => d.day === todayDayName) || null;
  const isUsingCustomSplit = activeSplitSource === 'custom' && customSplit?.days?.length > 0;

  // console.log('[Workouts] weeklyOverview days', weeklyOverview?.days?.length, '| rolling', rollingDays?.length);

  return (
    <div className="min-h-screen" style={{ background: '#f6f2e8' }}>
      <AnimatePresence>
        {showPremiumPaywall && (
          <PremiumPaywall onClose={() => setShowPremiumPaywall(false)} context="AI workout generation requires Execute Premium" />
        )}
      </AnimatePresence>
      <AnimatePresence>
        {showWorkoutComplete && (
          <WorkoutCompleteAnimation workoutName={workout?.name} onDismiss={() => setShowWorkoutComplete(false)} />
        )}
      </AnimatePresence>
      <AnimatePresence>
        {showCustomSplit && (
          <CustomSplitSheet
            existingSplit={customSplit || null}
            onClose={() => setShowCustomSplit(false)}
            onSave={(split) => {
              setCustomSplit(split);
              setActiveSplitSource('custom');
              backend.auth.updateMe({ active_split_source: 'custom' }).catch(() => {});
              setShowCustomSplit(false);
            }}
          />
        )}
      </AnimatePresence>

      {/* Split source picker */}
      <AnimatePresence>
        {showSplitSourcePicker && (
          <motion.div
            initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
            className="fixed inset-0 z-50 flex flex-col justify-end"
            style={{ background: 'rgba(20,22,19,0.55)', backdropFilter: 'blur(4px)' }}
            onClick={() => setShowSplitSourcePicker(false)}
          >
            <motion.div
              initial={{ y: '100%' }} animate={{ y: 0 }} exit={{ y: '100%' }}
              transition={{ type: 'spring', damping: 28, stiffness: 300 }}
              className="rounded-t-3xl p-5 space-y-3"
              style={{ background: '#f6f2e8' }}
              onClick={e => e.stopPropagation()}
            >
              <div className="flex justify-center mb-1">
                <div className="w-10 h-1 rounded-full" style={{ background: '#ddd6c8' }} />
              </div>
              <p className="text-base font-black tracking-tight" style={{ color: '#141613' }}>Which split to show?</p>
              <p className="text-xs" style={{ color: '#91968e' }}>Choose which plan drives your weekly schedule.</p>

              {/* AI Plan option */}
              <button
                onClick={() => {
                  setActiveSplitSource('ai');
                  backend.auth.updateMe({ active_split_source: 'ai' }).catch(() => {});
                  setShowSplitSourcePicker(false);
                }}
                className="w-full flex items-center gap-4 p-4 rounded-2xl border text-left transition-all"
                style={{
                  background: activeSplitSource === 'ai' ? 'rgba(200,224,0,0.08)' : '#ffffff',
                  borderColor: activeSplitSource === 'ai' ? 'rgba(200,224,0,0.45)' : '#e8e1d4',
                }}
              >
                <div className="w-10 h-10 rounded-2xl flex items-center justify-center flex-shrink-0"
                  style={{ background: 'rgba(200,224,0,0.12)' }}>
                  <Sparkles size={18} style={{ color: ACCENT_DARK }} />
                </div>
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-bold" style={{ color: '#141613' }}>AI Plan</p>
                  <p className="text-xs" style={{ color: '#91968e' }}>Your personalized AI-generated split</p>
                </div>
                {activeSplitSource === 'ai' && <Check size={16} style={{ color: ACCENT_DARK }} />}
              </button>

              {/* Custom split option */}
              <button
                onClick={() => {
                  setActiveSplitSource('custom');
                  backend.auth.updateMe({ active_split_source: 'custom' }).catch(() => {});
                  setShowSplitSourcePicker(false);
                }}
                className="w-full flex items-center gap-4 p-4 rounded-2xl border text-left transition-all"
                style={{
                  background: activeSplitSource === 'custom' ? 'rgba(200,224,0,0.08)' : '#ffffff',
                  borderColor: activeSplitSource === 'custom' ? 'rgba(200,224,0,0.45)' : '#e8e1d4',
                }}
              >
                <div className="w-10 h-10 rounded-2xl flex items-center justify-center flex-shrink-0"
                  style={{ background: '#f2efe7' }}>
                  <SlidersHorizontal size={18} style={{ color: '#5d635d' }} />
                </div>
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-bold" style={{ color: '#141613' }}>{customSplit?.name || 'My Custom Split'}</p>
                  <p className="text-xs" style={{ color: '#91968e' }}>
                    {(customSplit?.days || []).filter(d => d.type && d.type !== 'Rest').length} training days · manually built
                  </p>
                </div>
                {activeSplitSource === 'custom' && <Check size={16} style={{ color: ACCENT_DARK }} />}
              </button>

              {/* Edit custom split */}
              <button
                onClick={() => { setShowSplitSourcePicker(false); setShowCustomSplit(true); }}
                className="w-full py-3 rounded-2xl border text-sm font-semibold"
                style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}
              >
                Edit custom split
              </button>
            </motion.div>
          </motion.div>
        )}
      </AnimatePresence>

      {/* Header */}
      <div className="sticky top-0 z-40 px-5 pb-3" style={{ paddingTop: 'max(3rem, calc(env(safe-area-inset-top) + 1rem))', background: 'rgba(251,248,241,0.97)', backdropFilter: 'blur(24px)', borderBottom: '1px solid #ddd6c8', boxShadow: '0 2px 12px rgba(20,22,19,0.06)' }}>
        <div className="flex items-center justify-between mb-3">
          <div>
            <h1 className="text-lg font-bold tracking-tight" style={{ color: '#141613' }}>Train</h1>
            <p className="text-xs" style={{ color: '#91968e' }}>
              {isNonAppDate
                ? new Date(dateParam + 'T12:00:00').toLocaleDateString('en-US', { weekday: 'long', month: 'short', day: 'numeric' })
                : new Date().toLocaleDateString('en-US', { weekday: 'long', month: 'short', day: 'numeric' })}
            </p>
          </div>
        </div>
        <div className="flex gap-1 p-1 rounded-2xl" style={{ background: '#e8e3d8' }}>
          {TABS.map(tab => (
            <button key={tab.id} onClick={() => setActiveTab(tab.id)}
              className="flex-1 py-2 rounded-xl text-xs font-semibold transition-all"
              style={{
                background: activeTab === tab.id ? '#ffffff' : 'transparent',
                color: activeTab === tab.id ? '#141613' : '#a09a90',
                boxShadow: activeTab === tab.id ? '0 2px 8px rgba(20,22,19,0.1)' : 'none',
              }}>
              {tab.label}
            </button>
          ))}
        </div>
      </div>

      <div className="px-5 pb-32 pt-5">
        <div>

          {/* ── TODAY TAB ── */}
          {activeTab === 'today' && (
            <motion.div key="today" initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ duration: 0.15 }} className="space-y-4">

              {/* Custom split — show today's custom workout */}
              {isUsingCustomSplit && (
                <CustomWorkoutTodayCard
                  customDay={customTodayDay}
                  splitName={customSplit?.name}
                  onEditSplit={() => setShowCustomSplit(true)}
                  navigate={navigate}
                />
              )}

              {/* AI plan flow — only when not using custom split */}
              {!isUsingCustomSplit && (
                <>
                  {/* No active plan at all */}
                  {!planLoading && workoutStatus !== 'loading' && workoutStatus !== 'idle' && !activePlan && (
                    <NoPlanState onGenerate={() => isPremium ? navigate('/plan?generate=true') : setShowPremiumPaywall(true)} />
                  )}

                  {/* Active plan exists — show relevant state */}
                  {workoutStatus === 'idle' && !activePlan && (
                    <div className="p-5 rounded-3xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                      <div className="h-4 w-24 rounded-full mb-3" style={{ background: '#f2efe7' }} />
                      <div className="h-7 w-52 rounded-full mb-2" style={{ background: '#f2efe7' }} />
                      <div className="h-3 w-40 rounded-full" style={{ background: '#f2efe7' }} />
                    </div>
                  )}

                  {workoutStatus !== 'loading' && workoutStatus !== 'idle' && activePlan && (
                    <>
                      {workoutStatus === 'ready' && workout && (
                        <WorkoutHeroCard
                          workout={workout}
                          generating={false}
                          onGenerate={() => handleBuildWorkout()}
                        />
                      )}

                      {(workoutStatus === 'needs_generation') && (
                        <BuildWorkoutCard
                          overviewDay={todayOverviewDay}
                          onBuild={() => isPremium ? handleBuildWorkout() : setShowPremiumPaywall(true)}
                          generating={generatingWorkout}
                          error={generationError}
                        />
                      )}

                      {(workoutStatus === 'rest_day' || todayIsRestDay) && workoutStatus !== 'needs_generation' && workoutStatus !== 'ready' && (
                        <RestDayCard
                          overviewDay={todayOverviewDay}
                          onViewRecovery={() => navigate(`/recovery?date=${targetDate}&source=workouts`)}
                        />
                      )}

                      {workoutStatus === 'no_plan' && (
                        <BuildWorkoutCard
                          overviewDay={todayOverviewDay}
                          onBuild={() => handleBuildWorkout()}
                          generating={generatingWorkout}
                          error={generationError}
                        />
                      )}

                      {(workoutStatus === 'needs_generation' || workoutStatus === 'no_plan') && !generatingWorkout && (
                        <PlanSummaryCard
                          planSummary={planSummary}
                          trainingSplit={trainingSplit}
                          onViewSplit={() => setActiveTab('split')}
                        />
                      )}
                    </>
                  )}
                </>
              )}

              {/* Switch source hint */}
              {isUsingCustomSplit && (
                <button
                  onClick={() => setShowSplitSourcePicker(true)}
                  className="w-full py-2.5 rounded-2xl border text-xs font-semibold flex items-center justify-center gap-1.5"
                  style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#91968e' }}>
                  <SlidersHorizontal size={11} /> Switch to AI Plan
                </button>
              )}
            </motion.div>
          )}

          {/* ── MY SPLIT TAB ── */}
          {activeTab === 'split' && (
            <motion.div key="split" initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ duration: 0.15 }} className="space-y-3">

              {!activePlan && workoutStatus === 'idle' ? (
                <div className="space-y-2">
                  {[0, 1, 2].map(i => (
                    <div key={i} className="p-4 rounded-2xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                      <div className="h-4 w-28 rounded-full mb-2" style={{ background: '#f2efe7' }} />
                      <div className="h-3 w-44 rounded-full" style={{ background: '#f2efe7' }} />
                    </div>
                  ))}
                </div>
              ) : !activePlan ? (
                <div className="space-y-4">
                  <NoPlanState onGenerate={() => navigate('/plan?generate=true')} />
                  <div className="text-center">
                    <p className="text-xs mb-3" style={{ color: '#91968e' }}>Or build your own split manually</p>
                    <button onClick={() => customSplit ? setShowSplitSourcePicker(true) : setShowCustomSplit(true)}
                      className="flex items-center gap-2 px-5 py-3 rounded-2xl border text-sm font-semibold mx-auto"
                      style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}>
                      <SlidersHorizontal size={14} /> Customize Split
                    </button>
                  </div>
                </div>
              ) : !overviewDays.length ? (
                <NoOverviewCard onRegenerate={() => navigate('/plan?generate=true')} />
              ) : (
                <>
                  {/* Split header */}
                  <div className="flex items-center justify-between px-1 mb-2">
                    <p className="text-xs font-bold uppercase tracking-widest" style={{ color: '#91968e' }}>
                      {activeSplitSource === 'custom' ? (customSplit?.name || 'My Custom Split') : 'AI Training Schedule'}
                    </p>
                    <button
                      onClick={() => customSplit ? setShowSplitSourcePicker(true) : setShowCustomSplit(true)}
                      className="flex items-center gap-1.5 px-3 py-1.5 rounded-xl border text-xs font-semibold"
                      style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}
                    >
                      <SlidersHorizontal size={11} /> Customize
                    </button>
                  </div>

                  {/* Custom split view */}
                  {activeSplitSource === 'custom' && customSplit?.days?.length > 0 ? (
                    <div className="space-y-2">
                      {customSplit.days.map((day, i) => {
                        const isRest = !day.type || day.type === 'Rest';
                        const exCount = (day.exercises || []).length;
                        return (
                          <div key={i} className="rounded-2xl border overflow-hidden px-4 py-3.5"
                            style={{ background: isRest ? '#f9f7f3' : '#ffffff', borderColor: isRest ? '#e8e1d4' : 'rgba(200,224,0,0.35)' }}>
                            <div className="flex items-center gap-3">
                              <div className="w-9 h-9 rounded-xl flex items-center justify-center flex-shrink-0 text-xs font-black"
                                style={{ background: isRest ? '#f2efe7' : 'rgba(200,224,0,0.15)', color: isRest ? '#91968e' : ACCENT_DARK }}>
                                {day.day.slice(0, 2)}
                              </div>
                              <div className="flex-1 min-w-0">
                                <p className="text-sm font-bold" style={{ color: '#141613' }}>{day.day}</p>
                                <p className="text-xs" style={{ color: '#5d635d' }}>
                                  {day.type || 'Rest'}
                                  {!isRest && exCount > 0 ? ` · ${exCount} exercise${exCount !== 1 ? 's' : ''}` : ''}
                                </p>
                              </div>
                              {!isRest && exCount > 0 && (
                                <span className="text-[10px] font-semibold px-2 py-1 rounded-full" style={{ background: 'rgba(200,224,0,0.12)', color: ACCENT_DARK }}>
                                  {exCount} ex
                                </span>
                              )}
                            </div>
                            {!isRest && (day.exercises || []).length > 0 && (
                              <div className="mt-2.5 space-y-1.5 pl-12">
                                {day.exercises.map((ex, ei) => (
                                  <div key={ei} className="flex items-center justify-between">
                                    <p className="text-xs font-medium" style={{ color: '#141613' }}>{ex.name}</p>
                                    <p className="text-xs" style={{ color: '#91968e' }}>{ex.sets}×{ex.reps}</p>
                                  </div>
                                ))}
                              </div>
                            )}
                          </div>
                        );
                      })}
                      <button
                        onClick={() => setShowCustomSplit(true)}
                        className="w-full py-3 rounded-2xl border text-sm font-semibold flex items-center justify-center gap-2"
                        style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}
                      >
                        <SlidersHorizontal size={13} /> Edit split
                      </button>
                    </div>
                  ) : rollingDays.length === 0 ? (
                    <div className="p-5 rounded-2xl border text-center" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                      <p className="text-sm font-semibold mb-1" style={{ color: '#141613' }}>No upcoming training days found.</p>
                      <p className="text-xs" style={{ color: '#91968e' }}>Your plan continues from today. New future weeks can be generated later.</p>
                    </div>
                  ) : (
                    <>
                      {(() => {
                        const pendingCount = rollingDays.filter(
                          d => !isNonTrainingDay(d) && splitResults[d.date]?.status === 'needs_generation'
                        ).length;
                        if (!pendingCount && !buildingAllSplit) return null;
                        return (
                          <motion.button
                            whileTap={{ scale: 0.98 }}
                            onClick={() => isPremium ? handleBuildAllSplit() : setShowPremiumPaywall(true)}
                            disabled={buildingAllSplit}
                            className="w-full flex items-center justify-center gap-2 py-3.5 rounded-2xl text-sm font-bold mb-2.5 transition-opacity"
                            style={{ background: '#141613', color: '#ffffff', opacity: buildingAllSplit ? 0.7 : 1 }}>
                            {buildingAllSplit
                              ? <><Loader2 size={14} className="animate-spin" /> Building workouts…</>
                              : <><Sparkles size={14} /> Build all {pendingCount} workouts</>}
                          </motion.button>
                        );
                      })()}
                      {rollingDays.map((day, i) => (
                        <SplitDayRow
                          key={day.date}
                          date={day.date}
                          overviewDay={day}
                          splitResult={splitResults[day.date]}
                          index={i}
                          onBuild={handleBuildWorkout}
                          navigate={navigate}
                        />
                      ))}
                    </>
                  )}
                </>

              )}
            </motion.div>
          )}

          {/* ── LIBRARY TAB ── */}
          {activeTab === 'library' && (
            <motion.div key="library" initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ duration: 0.15 }} className="space-y-4">
              <div className="relative">
                <Search size={14} className="absolute left-3.5 top-1/2 -translate-y-1/2" style={{ color: '#91968e' }} />
                <input type="text" value={searchQuery} onChange={e => setSearchQuery(e.target.value)}
                  placeholder="Search exercises or muscles..."
                  className="w-full pl-9 pr-4 py-3 rounded-xl border text-sm outline-none"
                  style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }} />
              </div>
              <div className="flex gap-2 overflow-x-auto pb-1">
                {categories.map(cat => (
                  <button key={cat} onClick={() => setSelectedCategory(cat)}
                    className="flex-shrink-0 px-3.5 py-1.5 rounded-full text-xs font-medium transition-all"
                    style={{ background: selectedCategory === cat ? ACCENT : '#ffffff', color: selectedCategory === cat ? '#141613' : '#5d635d', border: `1px solid ${selectedCategory === cat ? ACCENT : '#e8e1d4'}` }}>
                    {cat}
                  </button>
                ))}
              </div>
              <div className="space-y-2">
                {filteredExercises.map(ex => (
                  <div key={ex.id} className="p-4 rounded-2xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                    <div className="flex items-start justify-between mb-1.5">
                      <div className="flex-1 pr-3">
                        <div className="flex items-center gap-2 mb-0.5">
                          <h3 className="text-sm font-semibold" style={{ color: '#141613' }}>{ex.name}</h3>
                          <span className="text-[10px] px-1.5 py-0.5 rounded-full" style={{ background: '#f2efe7', color: '#5d635d' }}>{ex.difficulty}</span>
                        </div>
                        <p className="text-xs" style={{ color: '#91968e' }}>{ex.muscles}</p>
                        <p className="text-[10px] mt-0.5" style={{ color: '#d9d1c2' }}>{ex.equipment}</p>
                      </div>
                      <span className="text-[10px] font-bold px-2.5 py-1 rounded-full flex-shrink-0" style={{ background: 'rgba(200,224,0,0.12)', color: ACCENT_DARK }}>{ex.category}</span>
                    </div>
                    {ex.notes && <p className="text-xs mt-1.5 leading-relaxed" style={{ color: '#5d635d' }}>{ex.notes}</p>}
                  </div>
                ))}
              </div>
            </motion.div>
          )}

          {/* ── HISTORY TAB ── */}
          {activeTab === 'history' && (
            <motion.div key="history" initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ duration: 0.15 }} className="space-y-3">
              {loadingHistory ? (
                <div className="flex flex-col items-center py-16 gap-3">
                  <div className="w-12 h-12 rounded-2xl flex items-center justify-center" style={{ background: 'rgba(200,224,0,0.1)' }}>
                    <Loader2 size={20} className="animate-spin" style={{ color: ACCENT_DARK }} />
                  </div>
                  <p className="text-sm" style={{ color: '#91968e' }}>Loading history…</p>
                </div>
              ) : workoutHistory.length === 0 ? (
                <div className="flex flex-col items-center py-16 text-center">
                  <div className="w-16 h-16 rounded-2xl flex items-center justify-center mb-5"
                    style={{ background: 'rgba(200,224,0,0.1)', border: '1px solid rgba(200,224,0,0.2)' }}>
                    <Dumbbell size={26} style={{ color: ACCENT_DARK }} />
                  </div>
                  <p className="text-base font-bold mb-2" style={{ color: '#141613' }}>No completed workouts yet</p>
                  <p className="text-sm leading-relaxed max-w-xs" style={{ color: '#91968e' }}>Finish a workout and it will appear here.</p>
                </div>
              ) : (
                workoutHistory.map((log, i) => {
                  const dateLabel = log.completed_at
                    ? new Date(log.completed_at).toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' })
                    : log.date;
                  const duration = log.duration_minutes ? `${log.duration_minutes} min` : null;
                  const isExpanded = expandedLogId === log.id;
                  const exerciseLogs = log.exercise_logs || [];

                  return (
                    <motion.div key={log.id} initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: i * 0.05 }}
                      className="rounded-2xl border overflow-hidden" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                      <button className="w-full text-left p-4" onClick={() => setExpandedLogId(isExpanded ? null : log.id)}>
                        <div className="flex items-center justify-between mb-1.5">
                          <h3 className="text-sm font-semibold" style={{ color: '#141613' }}>{log.workout_name || 'Workout'}</h3>
                          <div className="flex items-center gap-2">
                            <span className="text-xs" style={{ color: '#91968e' }}>{dateLabel}</span>
                            {isExpanded ? <ChevronUp size={14} style={{ color: '#91968e' }} /> : <ChevronDown size={14} style={{ color: '#91968e' }} />}
                          </div>
                        </div>
                        <div className="flex items-center gap-3 flex-wrap">
                          {log.exercises_completed > 0 && <p className="text-xs" style={{ color: '#91968e' }}>{log.exercises_completed} exercises</p>}
                          {duration && <p className="text-xs" style={{ color: '#91968e' }}>{duration}</p>}
                          {log.exertion_level && <span className="text-[10px] px-2 py-0.5 rounded-full" style={{ background: '#f2efe7', color: '#5d635d' }}>{log.exertion_level}</span>}
                          {log.rating > 0 && (
                            <div className="flex gap-0.5 ml-auto">
                              {Array.from({ length: 5 }, (_, si) => (
                                <div key={si} className="w-2 h-2 rounded-full" style={{ background: si < log.rating ? ACCENT : '#e8e1d4' }} />
                              ))}
                            </div>
                          )}
                        </div>
                      </button>
                      <AnimatePresence>
                        {isExpanded && (
                          <motion.div initial={{ height: 0, opacity: 0 }} animate={{ height: 'auto', opacity: 1 }} exit={{ height: 0, opacity: 0 }} transition={{ duration: 0.22 }} className="overflow-hidden">
                            <div style={{ borderTop: '1px solid #f2efe7' }}>
                              {exerciseLogs.length > 0 && (
                                <div className="px-4 pt-3 pb-2">
                                  <p className="text-[10px] font-bold uppercase tracking-widest mb-2.5" style={{ color: '#91968e' }}>Exercises</p>
                                  <div className="space-y-2">
                                    {exerciseLogs.map((ex, ei) => {
                                      const completedSets = ex.completedSetIndices?.length ?? 0;
                                      return (
                                        <div key={ei} className="flex items-center justify-between py-2 border-b last:border-0" style={{ borderColor: '#f9f7f3' }}>
                                          <div className="flex items-center gap-2.5">
                                            <span className="w-5 h-5 rounded-md flex items-center justify-center text-[9px] font-bold flex-shrink-0"
                                              style={{ background: 'rgba(200,224,0,0.12)', color: ACCENT_DARK }}>{ei + 1}</span>
                                            <div>
                                              <p className="text-sm font-medium" style={{ color: '#141613' }}>{ex.name}</p>
                                              <p className="text-[10px]" style={{ color: '#91968e' }}>
                                                {completedSets} set{completedSets !== 1 ? 's' : ''}{ex.weight > 0 ? ` · ${unitSystem === 'imperial' ? kgToLbs(ex.weight) + ' lbs' : ex.weight + ' kg'}` : ''}
                                              </p>
                                            </div>
                                          </div>
                                          {completedSets > 0 && (
                                            <div className="flex gap-1">
                                              {Array.from({ length: completedSets }, (_, si) => (
                                                <div key={si} className="w-5 h-5 rounded-md flex items-center justify-center" style={{ background: 'rgba(200,224,0,0.15)' }}>
                                                  <Check size={10} style={{ color: ACCENT_DARK }} />
                                                </div>
                                              ))}
                                            </div>
                                          )}
                                        </div>
                                      );
                                    })}
                                  </div>
                                </div>
                              )}
                              <div className="grid grid-cols-3 gap-px mx-4 mb-3 mt-1 rounded-xl overflow-hidden" style={{ background: '#f2efe7' }}>
                                {[
                                  { label: 'Duration', value: duration || '—' },
                                  { label: 'Sets done', value: log.sets_completed || '—' },
                                  { label: 'Calories', value: log.estimated_calories_burned ? `~${log.estimated_calories_burned}` : '—' },
                                ].map(stat => (
                                  <div key={stat.label} className="text-center py-3" style={{ background: '#ffffff' }}>
                                    <p className="text-sm font-bold" style={{ color: '#141613' }}>{stat.value}</p>
                                    <p className="text-[10px]" style={{ color: '#91968e' }}>{stat.label}</p>
                                  </div>
                                ))}
                              </div>
                            </div>
                          </motion.div>
                        )}
                      </AnimatePresence>
                    </motion.div>
                  );
                })
              )}
            </motion.div>
          )}

        </div>
      </div>
    </div>
  );
}
