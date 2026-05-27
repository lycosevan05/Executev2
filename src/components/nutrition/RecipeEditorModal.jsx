import { useState } from 'react';
import { motion } from 'framer-motion';
import { X, Plus, Trash2, Loader2, Sparkles } from 'lucide-react';
import { backend } from '@/api/backendClient';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

const MEAL_TYPES = ['breakfast', 'lunch', 'dinner', 'snack'];
const TAGS = ['high-protein', 'quick', 'meal-prep', 'low-carb', 'vegetarian', 'vegan', 'dairy-free', 'gluten-free'];

const EMPTY = {
  name: '',
  meal_type: 'breakfast',
  calories: '',
  protein: '',
  carbs: '',
  fats: '',
  ingredients: [''],
  instructions: '',
  prep_time_min: '',
  cook_time_min: '',
  notes: '',
  tags: [],
  source: 'custom',
  is_liked: false,
};

export default function RecipeEditorModal({ recipe, onClose, onSaved }) {
  const [form, setForm] = useState(recipe ? {
    ...recipe,
    calories: recipe.calories ?? '',
    protein: recipe.protein ?? '',
    carbs: recipe.carbs ?? '',
    fats: recipe.fats ?? '',
    prep_time_min: recipe.prep_time_min ?? '',
    cook_time_min: recipe.cook_time_min ?? '',
    ingredients: recipe.ingredients?.length ? recipe.ingredients : [''],
    tags: recipe.tags || [],
  } : { ...EMPTY });
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState('');
  const [aiGenerating, setAiGenerating] = useState(false);

  const update = (key, val) => setForm(prev => ({ ...prev, [key]: val }));

  const updateIngredient = (i, val) => {
    const updated = [...form.ingredients];
    updated[i] = val;
    setForm(prev => ({ ...prev, ingredients: updated }));
  };
  const addIngredient = () => setForm(prev => ({ ...prev, ingredients: [...prev.ingredients, ''] }));
  const removeIngredient = (i) => setForm(prev => ({ ...prev, ingredients: prev.ingredients.filter((_, idx) => idx !== i) }));
  const toggleTag = (tag) => setForm(prev => ({
    ...prev,
    tags: prev.tags.includes(tag) ? prev.tags.filter(t => t !== tag) : [...prev.tags, tag],
  }));

  const handleAIFill = async () => {
    if (!form.name) return;
    setAiGenerating(true);
    try {
      const result = await backend.integrations.Core.InvokeLLM({
        prompt: `Generate a detailed healthy recipe called "${form.name}" for a ${form.meal_type}.
Return a JSON object with: calories (number), protein (number, grams), carbs (number, grams), fats (number, grams), prep_time_min (number), cook_time_min (number), ingredients (array of strings like "200g chicken breast"), instructions (string, step-by-step), tags (array from: high-protein, quick, meal-prep, low-carb, vegetarian, vegan, dairy-free, gluten-free), notes (optional tip string).
Keep it practical, healthy, and delicious. Focus on accuracy of macros.`,
        response_json_schema: {
          type: 'object',
          properties: {
            calories: { type: 'number' },
            protein: { type: 'number' },
            carbs: { type: 'number' },
            fats: { type: 'number' },
            prep_time_min: { type: 'number' },
            cook_time_min: { type: 'number' },
            ingredients: { type: 'array', items: { type: 'string' } },
            instructions: { type: 'string' },
            tags: { type: 'array', items: { type: 'string' } },
            notes: { type: 'string' },
          },
        },
      });
      if (result) {
        setForm(prev => ({
          ...prev,
          calories: result.calories ?? prev.calories,
          protein: result.protein ?? prev.protein,
          carbs: result.carbs ?? prev.carbs,
          fats: result.fats ?? prev.fats,
          prep_time_min: result.prep_time_min ?? prev.prep_time_min,
          cook_time_min: result.cook_time_min ?? prev.cook_time_min,
          ingredients: result.ingredients?.length ? result.ingredients : prev.ingredients,
          instructions: result.instructions || prev.instructions,
          notes: result.notes || prev.notes,
          tags: result.tags?.length ? result.tags : prev.tags,
        }));
      }
    } catch (e) {
      // silent fail
    } finally {
      setAiGenerating(false);
    }
  };

  const handleSave = async () => {
    if (!form.name.trim()) return;
    setSaving(true);
    setSaveError('');
    try {
      const payload = {
        ...form,
        calories: Number(form.calories) || 0,
        protein: Number(form.protein) || 0,
        carbs: Number(form.carbs) || 0,
        fats: Number(form.fats) || 0,
        prep_time_min: Number(form.prep_time_min) || 0,
        cook_time_min: Number(form.cook_time_min) || 0,
        ingredients: form.ingredients.filter(i => i.trim()),
      };
      let saved;
      if (recipe?.id) {
        saved = await backend.entities.SavedRecipe.update(recipe.id, payload);
      } else {
        saved = await backend.entities.SavedRecipe.create(payload);
      }
      onSaved(saved);
    } catch (err) {
      setSaveError(err?.message || 'Could not save. Please try again.');
    } finally {
      setSaving(false);
    }
  };

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
            {recipe ? 'Edit Recipe' : 'New Recipe'}
          </h2>
          <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>Build your personal cookbook</p>
        </div>
        <div className="flex items-center gap-2">
          {form.name && (
            <button
              onClick={handleAIFill}
              disabled={aiGenerating}
              className="flex items-center gap-1.5 px-3 py-2 rounded-xl text-xs font-semibold"
              style={{ background: 'rgba(200,224,0,0.15)', color: ACCENT_DARK, border: '1px solid rgba(200,224,0,0.3)' }}
            >
              {aiGenerating ? <Loader2 size={11} className="animate-spin" /> : <Sparkles size={11} />}
              AI Fill
            </button>
          )}
          <button onClick={onClose} className="w-9 h-9 rounded-full flex items-center justify-center border" style={{ background: '#f2efe7', borderColor: '#e8e1d4' }}>
            <X size={15} style={{ color: '#5d635d' }} />
          </button>
        </div>
      </div>

      {/* Scrollable body */}
      <div className="flex-1 overflow-y-auto px-5 py-5 space-y-5" style={{ paddingBottom: '100px' }}>

        {/* Name + Meal type */}
        <div className="space-y-3">
          <div>
            <label className="text-[10px] font-bold uppercase tracking-widest block mb-1.5" style={{ color: '#91968e' }}>Recipe Name *</label>
            <input
              value={form.name}
              onChange={e => update('name', e.target.value)}
              placeholder="e.g. High-Protein Overnight Oats"
              className="w-full px-4 py-3 rounded-2xl border text-sm outline-none font-semibold"
              style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
            />
          </div>
          <div>
            <label className="text-[10px] font-bold uppercase tracking-widest block mb-1.5" style={{ color: '#91968e' }}>Meal Type</label>
            <div className="grid grid-cols-4 gap-2">
              {MEAL_TYPES.map(t => (
                <button
                  key={t}
                  onClick={() => update('meal_type', t)}
                  className="py-2.5 rounded-xl text-xs font-semibold capitalize transition-all"
                  style={{
                    background: form.meal_type === t ? 'rgba(200,224,0,0.12)' : '#ffffff',
                    borderColor: form.meal_type === t ? 'rgba(200,224,0,0.5)' : '#e8e1d4',
                    border: '1px solid',
                    color: form.meal_type === t ? ACCENT_DARK : '#5d635d',
                  }}
                >{t}</button>
              ))}
            </div>
          </div>
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
              <div key={f.key} className="relative">
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

        {/* Time */}
        <div>
          <label className="text-[10px] font-bold uppercase tracking-widest block mb-2" style={{ color: '#91968e' }}>Time</label>
          <div className="grid grid-cols-2 gap-2">
            {[{ key: 'prep_time_min', label: 'Prep time' }, { key: 'cook_time_min', label: 'Cook time' }].map(f => (
              <div key={f.key} className="relative">
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
                  <span className="absolute right-3 top-1/2 -translate-y-1/2 text-xs" style={{ color: '#91968e' }}>min</span>
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
                  placeholder={`e.g. 100g rolled oats`}
                  className="flex-1 px-3 py-2.5 rounded-xl border text-sm outline-none"
                  style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
                />
                {form.ingredients.length > 1 && (
                  <button onClick={() => removeIngredient(i)} className="w-10 flex items-center justify-center rounded-xl" style={{ background: '#f2efe7' }}>
                    <Trash2 size={12} style={{ color: '#b05a3a' }} />
                  </button>
                )}
              </div>
            ))}
          </div>
          <button onClick={addIngredient} className="flex items-center gap-1.5 mt-2 text-xs font-semibold px-3 py-2 rounded-xl" style={{ background: '#f2efe7', color: '#5d635d' }}>
            <Plus size={12} /> Add ingredient
          </button>
        </div>

        {/* Instructions */}
        <div>
          <label className="text-[10px] font-bold uppercase tracking-widest block mb-1.5" style={{ color: '#91968e' }}>Instructions</label>
          <textarea
            value={form.instructions}
            onChange={e => update('instructions', e.target.value)}
            placeholder="Step-by-step cooking instructions..."
            rows={4}
            className="w-full px-4 py-3 rounded-2xl border text-sm outline-none resize-none"
            style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
          />
        </div>

        {/* Notes */}
        <div>
          <label className="text-[10px] font-bold uppercase tracking-widest block mb-1.5" style={{ color: '#91968e' }}>Notes <span className="font-normal normal-case" style={{ color: '#b8b4ac' }}>(optional)</span></label>
          <input
            value={form.notes}
            onChange={e => update('notes', e.target.value)}
            placeholder="e.g. great for meal prep, swap chicken for tofu..."
            className="w-full px-4 py-3 rounded-2xl border text-sm outline-none"
            style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
          />
        </div>

        {/* Tags */}
        <div>
          <label className="text-[10px] font-bold uppercase tracking-widest block mb-2" style={{ color: '#91968e' }}>Tags</label>
          <div className="flex flex-wrap gap-2">
            {TAGS.map(tag => (
              <button
                key={tag}
                onClick={() => toggleTag(tag)}
                className="px-3 py-1.5 rounded-full text-xs font-semibold transition-all"
                style={{
                  background: form.tags.includes(tag) ? 'rgba(200,224,0,0.15)' : '#f2efe7',
                  borderColor: form.tags.includes(tag) ? 'rgba(200,224,0,0.4)' : '#e8e1d4',
                  border: '1px solid',
                  color: form.tags.includes(tag) ? ACCENT_DARK : '#5d635d',
                }}
              >{tag}</button>
            ))}
          </div>
        </div>
      </div>

      {/* Save button */}
      <div
        className="flex-shrink-0 px-5 pt-3 border-t space-y-3"
        style={{ paddingBottom: 'calc(16px + env(safe-area-inset-bottom))', borderColor: '#e8e1d4', background: '#f6f2e8' }}
      >
        {saveError && (
          <div className="px-4 py-3 rounded-2xl border text-xs" style={{ background: 'rgba(176,90,58,0.07)', borderColor: 'rgba(176,90,58,0.25)', color: '#b05a3a' }}>
            {saveError}
          </div>
        )}
        <button
          onClick={handleSave}
          disabled={saving || !form.name.trim()}
          className="w-full py-4 rounded-2xl text-sm font-bold flex items-center justify-center gap-2"
          style={{ background: saving || !form.name.trim() ? 'rgba(200,224,0,0.4)' : ACCENT, color: '#141613' }}
        >
          {saving ? <><Loader2 size={14} className="animate-spin" /> Saving…</> : 'Save Recipe'}
        </button>
      </div>
    </motion.div>
  );
}