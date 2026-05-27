import { useState } from 'react';
import { motion } from 'framer-motion';
import { useNavigate } from 'react-router-dom';
import { CheckCircle2, Zap, ChevronRight } from 'lucide-react';
import { backend } from '@/api/backendClient';
import { estimateCalorieGoal, estimateMacroTargets } from '@/lib/calorieGoal';
import EditableNutritionTargets from '@/components/profile/EditableNutritionTargets';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

const GOAL_LABEL = {
  lose_fat: 'Moderate fat loss',
  build_muscle: 'Lean muscle gain',
  maintain_weight: 'Maintain & perform',
};

const ACTIVITY_LABEL = {
  sedentary: 'Never / rarely',
  lightly_active: '1–2x per week',
  moderately_active: '3–4x per week',
  very_active: '5–6x per week',
  athlete: 'Daily / 2x per day',
};

const COMMITMENT_LABEL = {
  commit_2: '2x per week',
  commit_3: '3x per week',
  commit_4: '4x per week',
  commit_5: '5x per week',
};

function InfoCard({ label, value }) {
  if (!value) return null;
  return (
    <div className="rounded-2xl border p-3 mb-2" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
      <p className="text-[9px] font-bold uppercase tracking-widest mb-0.5" style={{ color: '#91968e' }}>{label}</p>
      <p className="text-base font-black" style={{ color: '#141613' }}>{value}</p>
    </div>
  );
}

export default function StarterResultScreen({ savedData, onClose }) {
  const navigate = useNavigate();

  // Reconstruct a minimal profile object from what was saved
  const userProfile = {
    age: savedData.age ? Number(savedData.age) : null,
    weight_kg: savedData.useMetric
      ? (savedData.weightKg ? Number(savedData.weightKg) : null)
      : (savedData.weightLbs ? Math.round(Number(savedData.weightLbs) / 2.20462 * 10) / 10 : null),
    height_cm: savedData.useMetric
      ? (savedData.heightCm ? Number(savedData.heightCm) : null)
      : ((() => {
          const totalIn = (Number(savedData.heightFt) || 0) * 12 + (Number(savedData.heightIn) || 0);
          return totalIn > 0 ? Math.round(totalIn * 2.54) : null;
        })()),
    sex: savedData.sex || null,
  };

  const nutritionProfile = {
    activity_level: savedData.activityLevel || null,
    primary_goal: savedData.primaryGoal || null,
    protein_target_g: savedData.setManualMacros && savedData.manualProtein ? Number(savedData.manualProtein) : null,
    carbs_target_g: savedData.setManualMacros && savedData.manualCarbs ? Number(savedData.manualCarbs) : null,
    fats_target_g: savedData.setManualMacros && savedData.manualFat ? Number(savedData.manualFat) : null,
  };

  const calories = savedData.setManualMacros && Number(savedData.manualCalories) > 0
    ? Number(savedData.manualCalories)
    : estimateCalorieGoal(userProfile, nutritionProfile);

  const macros = savedData.setManualMacros && Number(savedData.manualProtein) > 0
    ? {
        protein_g: Number(savedData.manualProtein),
        carbs_g: Number(savedData.manualCarbs) || null,
        fat_g: Number(savedData.manualFat) || null,
      }
    : estimateMacroTargets(calories, userProfile, nutritionProfile);

  const [targets, setTargets] = useState({
    calories: calories || 0,
    protein_g: macros?.protein_g || 0,
    carbs_g: macros?.carbs_g || 0,
    fat_g: macros?.fat_g || 0,
  });
  const [savingTargets, setSavingTargets] = useState(false);

  // Use commitment label if provided, otherwise fall back to activity label
  const trainingLabel = savedData.trainingCommitment
    ? COMMITMENT_LABEL[savedData.trainingCommitment]
    : (savedData.activityLevel ? ACTIVITY_LABEL[savedData.activityLevel] : null);
  const goalLabel = GOAL_LABEL[savedData.primaryGoal] || null;

  const saveTargets = async (nextTargets) => {
    setSavingTargets(true);
    const user = await backend.auth.me();
    const existing = await backend.entities.NutritionProfile.filter({ user_email: user.email }, '-updated_date', 1);
    const payload = {
      user_email: user.email,
      calorie_target: nextTargets.calories,
      calorie_target_source: 'manual',
      protein_target_g: nextTargets.protein_g,
      carbs_target_g: nextTargets.carbs_g,
      fats_target_g: nextTargets.fat_g,
      nutrition_targets_updated_at: new Date().toISOString(),
      updated_from_starter_profile: true,
    };
    if (existing?.[0]?.id) {
      await backend.entities.NutritionProfile.update(existing[0].id, payload);
    } else {
      await backend.entities.NutritionProfile.create(payload);
    }
    setSavingTargets(false);
  };

  const handleGeneratePlan = () => {
    onClose();
    navigate('/plan?generate=true');
  };

  return (
    <motion.div
      initial={{ opacity: 0, y: 20 }}
      animate={{ opacity: 1, y: 0 }}
      exit={{ opacity: 0 }}
      className="fixed inset-0 flex flex-col"
      style={{ background: '#f6f2e8', zIndex: 100 }}
    >
      {/* Header */}
      <div className="flex-shrink-0 px-5 pt-10 pb-3">
        <div className="flex items-center gap-3 mb-1">
          <div className="w-8 h-8 rounded-full flex items-center justify-center" style={{ background: 'rgba(200,224,0,0.15)' }}>
            <CheckCircle2 size={18} style={{ color: ACCENT_DARK }} />
          </div>
          <h2 className="text-lg font-black" style={{ color: '#141613' }}>Your starter targets are ready</h2>
        </div>
        <p className="text-xs ml-11" style={{ color: '#91968e' }}>Based on your profile, Execute estimates:</p>
      </div>

      {/* Stats */}
      <div className="flex-1 overflow-y-auto px-5" style={{ paddingBottom: '96px' }}>
        <EditableNutritionTargets
          targets={targets}
          onChange={setTargets}
          onSave={saveTargets}
          saving={savingTargets}
        />
        <InfoCard label="Training target" value={trainingLabel} />
        <InfoCard label="Goal" value={goalLabel} />

        {/* Upsell card */}
        <div className="rounded-2xl border p-3.5" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
          <div className="flex items-center gap-2 mb-2">
            <div className="w-6 h-6 rounded-lg flex items-center justify-center flex-shrink-0" style={{ background: 'rgba(200,224,0,0.15)' }}>
              <Zap size={13} style={{ color: ACCENT_DARK }} />
            </div>
            <p className="text-sm font-black" style={{ color: '#141613' }}>Want Execute to build the full plan?</p>
          </div>
          <p className="text-[11px] leading-relaxed mb-3" style={{ color: '#5d635d' }}>
            Unlock an adaptive plan that adjusts your workouts, nutrition, and recovery based on your readiness, schedule, and progress.
          </p>
          <button
            onClick={handleGeneratePlan}
            className="w-full flex items-center justify-center gap-2 py-3 rounded-2xl text-sm font-bold"
            style={{ background: ACCENT, color: '#141613' }}
          >
            Generate My Adaptive Plan <ChevronRight size={14} />
          </button>
        </div>
      </div>

      {/* Footer */}
      <div
        className="flex-shrink-0 px-5 pt-2 border-t"
        style={{
          paddingBottom: 'calc(16px + env(safe-area-inset-bottom))',
          borderColor: '#e8e1d4',
          background: '#f6f2e8',
        }}
      >
        <button
          onClick={onClose}
          className="w-full py-3 rounded-2xl text-sm font-semibold border"
          style={{ borderColor: '#e8e1d4', color: '#5d635d', background: '#ffffff' }}
        >
          Done
        </button>
      </div>
    </motion.div>
  );
}