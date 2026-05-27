import { useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { Heart, ChevronDown, ChevronUp, Clock, Pencil, Trash2 } from 'lucide-react';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

const MEAL_COLORS = {
  breakfast: '#a07030',
  lunch: '#5d8a5d',
  dinner: '#5d8aa8',
  snack: '#8a5d8a',
};

export default function RecipeCard({ recipe, onLike, onEdit, onDelete }) {
  const [expanded, setExpanded] = useState(false);
  const color = MEAL_COLORS[recipe.meal_type] || '#91968e';

  return (
    <motion.div
      layout
      initial={{ opacity: 0, y: 8 }}
      animate={{ opacity: 1, y: 0 }}
      className="rounded-2xl border overflow-hidden"
      style={{ background: '#ffffff', borderColor: recipe.is_liked ? 'rgba(200,224,0,0.4)' : '#e8e1d4' }}
    >
      {/* Header row */}
      <div className="px-4 pt-4 pb-3">
        <div className="flex items-start justify-between gap-2">
          <div className="flex-1 min-w-0">
            <div className="flex items-center gap-2 mb-1">
              <span
                className="text-[10px] font-bold uppercase tracking-widest px-2 py-0.5 rounded-full"
                style={{ background: `${color}18`, color }}
              >
                {recipe.meal_type}
              </span>
              {recipe.source === 'ai_generated' && (
                <span className="text-[10px] font-semibold px-2 py-0.5 rounded-full" style={{ background: 'rgba(200,224,0,0.12)', color: ACCENT_DARK }}>AI</span>
              )}
            </div>
            <h3 className="text-sm font-bold leading-tight" style={{ color: '#141613' }}>{recipe.name}</h3>
            <div className="flex items-center gap-3 mt-1.5">
              <span className="text-xs font-semibold" style={{ color: '#141613' }}>{recipe.calories} kcal</span>
              <span className="text-xs" style={{ color: '#91968e' }}>
                {recipe.protein}g P · {recipe.carbs}g C · {recipe.fats}g F
              </span>
            </div>
          </div>
          {/* Actions */}
          <div className="flex items-center gap-1.5 flex-shrink-0">
            <button
              onClick={() => onLike(recipe)}
              className="w-8 h-8 rounded-xl flex items-center justify-center transition-all"
              style={{ background: recipe.is_liked ? 'rgba(200,224,0,0.12)' : '#f2efe7' }}
            >
              <Heart
                size={14}
                fill={recipe.is_liked ? ACCENT_DARK : 'none'}
                style={{ color: recipe.is_liked ? ACCENT_DARK : '#91968e' }}
              />
            </button>
            <button
              onClick={() => onEdit(recipe)}
              className="w-8 h-8 rounded-xl flex items-center justify-center"
              style={{ background: '#f2efe7' }}
            >
              <Pencil size={13} style={{ color: '#5d635d' }} />
            </button>
            <button
              onClick={() => setExpanded(e => !e)}
              className="w-8 h-8 rounded-xl flex items-center justify-center"
              style={{ background: '#f2efe7' }}
            >
              {expanded ? <ChevronUp size={14} style={{ color: '#91968e' }} /> : <ChevronDown size={14} style={{ color: '#91968e' }} />}
            </button>
          </div>
        </div>

        {/* Time + tags */}
        <div className="flex items-center gap-3 mt-2 flex-wrap">
          {(recipe.prep_time_min || recipe.cook_time_min) && (
            <div className="flex items-center gap-1">
              <Clock size={11} style={{ color: '#91968e' }} />
              <span className="text-[10px]" style={{ color: '#91968e' }}>
                {(recipe.prep_time_min || 0) + (recipe.cook_time_min || 0)} min
              </span>
            </div>
          )}
          {recipe.tags?.map(tag => (
            <span key={tag} className="text-[10px] px-2 py-0.5 rounded-full" style={{ background: '#f2efe7', color: '#5d635d' }}>
              {tag}
            </span>
          ))}
        </div>
      </div>

      {/* Expanded detail */}
      <AnimatePresence>
        {expanded && (
          <motion.div
            initial={{ height: 0, opacity: 0 }}
            animate={{ height: 'auto', opacity: 1 }}
            exit={{ height: 0, opacity: 0 }}
            className="overflow-hidden"
          >
            <div className="px-4 pb-4 space-y-3 border-t" style={{ borderColor: '#f2efe7' }}>
              {recipe.ingredients?.length > 0 && (
                <div className="pt-3">
                  <p className="text-[10px] font-bold uppercase tracking-widest mb-1.5" style={{ color: '#91968e' }}>Ingredients</p>
                  <div className="space-y-1">
                    {recipe.ingredients.map((ing, i) => (
                      <div key={i} className="flex items-start gap-2">
                        <div className="w-1 h-1 rounded-full mt-1.5 flex-shrink-0" style={{ background: ACCENT_DARK }} />
                        <span className="text-xs" style={{ color: '#5d635d' }}>{ing}</span>
                      </div>
                    ))}
                  </div>
                </div>
              )}
              {recipe.instructions && (
                <div>
                  <p className="text-[10px] font-bold uppercase tracking-widest mb-1.5" style={{ color: '#91968e' }}>Instructions</p>
                  <p className="text-xs leading-relaxed" style={{ color: '#5d635d' }}>{recipe.instructions}</p>
                </div>
              )}
              {recipe.notes && (
                <p className="text-xs italic" style={{ color: '#91968e' }}>{recipe.notes}</p>
              )}
              <button
                onClick={() => onDelete(recipe)}
                className="flex items-center gap-1.5 text-xs font-medium pt-1"
                style={{ color: '#b05a3a' }}
              >
                <Trash2 size={11} /> Delete recipe
              </button>
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </motion.div>
  );
}