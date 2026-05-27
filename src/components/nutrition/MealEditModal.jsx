import { useState } from 'react';
import { motion } from 'framer-motion';
import { X, Plus, Trash2, Loader2 } from 'lucide-react';
import { backend } from '@/api/backendClient';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

export default function MealEditModal({ meal, mealType, mealPlanId, onClose, onSaved }) {
  const [form, setForm] = useState({
    name: meal?.name || '',
    calories: meal?.calories ?? '',
    protein: meal?.protein ?? '',
    carbs: meal?.carbs ?? '',
    fats: meal?.fats ?? meal?.fat ?? '',
    ingredients: meal?.ingredients?.length ? [...meal.ingredients] : [''],
    notes: meal?.notes || '',
  });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');

  const update = (key, val) => setForm(prev => ({ ...prev, [key]: val }));

  const updateIngredient = (i, val) => {
    const updated = [...form.ingredients];
    updated[i] = val;
    setForm(prev => ({ ...prev, ingredients: updated }));
  };

  const handleSave = async () => {
    if (!form.name.trim()) return;
    setSaving(true);
    setError('');
    try {
      // Load current MealPlan, patch the specific meal, save back
      const plans = await backend.entities.MealPlan.filter({ id: mealPlanId });
      const plan = plans?.[0];
      if (!plan) throw new Error('Meal plan not found');

      const updatedMeal = {
        ...(plan.meals?.[mealType] || {}),
        name: form.name.trim(),
        calories: Number(form.calories) || 0,
        protein: Number(form.protein) || 0,
        carbs: Number(form.carbs) || 0,
        fats: Number(form.fats) || 0,
        ingredients: form.ingredients.filter(i => i.trim()),
        notes: form.notes,
      };

      const updatedMeals = {
        ...(typeof plan.meals === 'object' && !Array.isArray(plan.meals) ? plan.meals : {}),
        [mealType]: updatedMeal,
      };

      // If meals is an array, rebuild it properly
      if (Array.isArray(plan.meals)) {
        const order = ['breakfast', 'lunch', 'dinner', 'snack'];
        const mealsObj = {};
        plan.meals.forEach((m, idx) => {
          const key = m?.meal_type || m?.type || order[idx] || `meal_${idx}`;
          mealsObj[key] = m;
        });
        mealsObj[mealType] = updatedMeal;
        // Recalculate totals
        const allMeals = Object.values(mealsObj);
        const totalCalories = allMeals.reduce((s, m) => s + (m?.calories || 0), 0);
        const totalProtein = allMeals.reduce((s, m) => s + (m?.protein || 0), 0);
        const totalCarbs = allMeals.reduce((s, m) => s + (m?.carbs || 0), 0);
        const totalFats = allMeals.reduce((s, m) => s + (m?.fats || m?.fat || 0), 0);
        await backend.entities.MealPlan.update(plan.id, {
          meals: mealsObj,
          total_calories: totalCalories,
          total_protein_g: totalProtein,
          total_carbs_g: totalCarbs,
          total_fats_g: totalFats,
        });
      } else {
        // Recalculate totals
        const allMeals = Object.values(updatedMeals);
        const totalCalories = allMeals.reduce((s, m) => s + (m?.calories || 0), 0);
        const totalProtein = allMeals.reduce((s, m) => s + (m?.protein || 0), 0);
        const totalCarbs = allMeals.reduce((s, m) => s + (m?.carbs || 0), 0);
        const totalFats = allMeals.reduce((s, m) => s + (m?.fats || m?.fat || 0), 0);
        await backend.entities.MealPlan.update(plan.id, {
          meals: updatedMeals,
          total_calories: totalCalories,
          total_protein_g: totalProtein,
          total_carbs_g: totalCarbs,
          total_fats_g: totalFats,
        });
      }

      onSaved(mealType, updatedMeal);
    } catch (err) {
      setError(err?.message || 'Could not save. Please try again.');
    } finally {
      setSaving(false);
    }
  };

  const MEAL_LABELS = { breakfast: 'Breakfast', lunch: 'Lunch', dinner: 'Dinner', snack: 'Snack' };

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      className="fixed inset-0 z-50 flex flex-col"
      style={{ background: '#f6f2e8' }}
    >
      {/* Header */}
      <div
        className="flex-shrink-0 px-5 pb-4 border-b flex items-center justify-between"
        style={{ paddingTop: 'max(3rem, calc(env(safe-area-inset-top) + 1rem))', borderColor: '#e8e1d4', background: 'rgba(251,248,241,0.97)', backdropFilter: 'blur(20px)' }}
      >
        <div>
          <h2 className="text-base font-black" style={{ color: '#141613' }}>
            Edit {MEAL_LABELS[mealType] || mealType}
          </h2>
          <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>Update this meal in your plan</p>
        </div>
        <button onClick={onClose} className="w-9 h-9 rounded-full flex items-center justify-center border" style={{ background: '#f2efe7', borderColor: '#e8e1d4' }}>
          <X size={15} style={{ color: '#5d635d' }} />
        </button>
      </div>

      {/* Body */}
      <div className="flex-1 overflow-y-auto px-5 py-5 space-y-5" style={{ paddingBottom: '100px' }}>

        {/* Name */}
        <div>
          <label className="text-[10px] font-bold uppercase tracking-widest block mb-1.5" style={{ color: '#91968e' }}>Meal Name *</label>
          <input
            value={form.name}
            onChange={e => update('name', e.target.value)}
            placeholder="e.g. Grilled Chicken Bowl"
            className="w-full px-4 py-3 rounded-2xl border text-sm outline-none font-semibold"
            style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
          />
        </div>

        {/* Macros */}
        <div>
          <label className="text-[10px] font-bold uppercase tracking-widest block mb-2" style={{ color: '#91968e' }}>Macros</label>
          <div className="grid grid-cols-2 gap-2">
            {[
              { key: 'calories', label: 'Calories', unit: 'kcal' },
              { key: 'protein', label: 'Protein', unit: 'g' },
              { key: 'carbs', label: 'Carbs', unit: 'g' },
              { key: 'fats', label: 'Fats', unit: 'g' },
            ].map(f => (
              <div key={f.key}>
                <label className="text-[10px] font-semibold mb-1 block" style={{ color: '#91968e' }}>{f.label}</label>
                <div className="relative">
                  <input
                    type="number"
                    value={form[f.key]}
                    onChange={e => update(f.key, e.target.value)}
                    placeholder="0"
                    className="w-full px-3 py-2.5 rounded-xl border text-sm font-bold outline-none pr-10"
                    style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
                  />
                  <span className="absolute right-3 top-1/2 -translate-y-1/2 text-xs" style={{ color: '#91968e' }}>{f.unit}</span>
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* Ingredients */}
        <div>
          <label className="text-[10px] font-bold uppercase tracking-widest block mb-2" style={{ color: '#91968e' }}>Ingredients</label>
          <div className="space-y-2">
            {form.ingredients.map((ing, i) => (
              <div key={i} className="flex gap-2">
                <input
                  value={ing}
                  onChange={e => updateIngredient(i, e.target.value)}
                  placeholder="e.g. 150g chicken breast"
                  className="flex-1 px-3 py-2.5 rounded-xl border text-sm outline-none"
                  style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
                />
                {form.ingredients.length > 1 && (
                  <button
                    onClick={() => setForm(prev => ({ ...prev, ingredients: prev.ingredients.filter((_, idx) => idx !== i) }))}
                    className="w-10 flex items-center justify-center rounded-xl"
                    style={{ background: '#f2efe7' }}
                  >
                    <Trash2 size={12} style={{ color: '#b05a3a' }} />
                  </button>
                )}
              </div>
            ))}
          </div>
          <button
            onClick={() => setForm(prev => ({ ...prev, ingredients: [...prev.ingredients, ''] }))}
            className="flex items-center gap-1.5 mt-2 text-xs font-semibold px-3 py-2 rounded-xl"
            style={{ background: '#f2efe7', color: '#5d635d' }}
          >
            <Plus size={12} /> Add ingredient
          </button>
        </div>

        {/* Notes */}
        <div>
          <label className="text-[10px] font-bold uppercase tracking-widest block mb-1.5" style={{ color: '#91968e' }}>Notes <span className="font-normal normal-case" style={{ color: '#b8b4ac' }}>(optional)</span></label>
          <input
            value={form.notes}
            onChange={e => update('notes', e.target.value)}
            placeholder="e.g. swap chicken for tofu..."
            className="w-full px-4 py-3 rounded-2xl border text-sm outline-none"
            style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
          />
        </div>

        {/* Error */}
        {error && (
          <div className="px-4 py-3 rounded-2xl border text-xs" style={{ background: 'rgba(176,90,58,0.07)', borderColor: 'rgba(176,90,58,0.25)', color: '#b05a3a' }}>
            {error}
          </div>
        )}
      </div>

      {/* Save button */}
      <div
        className="flex-shrink-0 px-5 pt-3 border-t"
        style={{ paddingBottom: 'calc(16px + env(safe-area-inset-bottom))', borderColor: '#e8e1d4', background: '#f6f2e8' }}
      >
        <button
          onClick={handleSave}
          disabled={saving || !form.name.trim()}
          className="w-full py-4 rounded-2xl text-sm font-bold flex items-center justify-center gap-2"
          style={{ background: saving || !form.name.trim() ? 'rgba(200,224,0,0.4)' : ACCENT, color: '#141613' }}
        >
          {saving ? <><Loader2 size={14} className="animate-spin" /> Saving…</> : 'Save Changes'}
        </button>
      </div>
    </motion.div>
  );
}