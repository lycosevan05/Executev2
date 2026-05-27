import { useState, useEffect } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { Plus, Search, Heart, BookOpen, Loader2 } from 'lucide-react';
import { backend } from '@/api/backendClient';
import RecipeCard from './RecipeCard';
import RecipeEditorModal from './RecipeEditorModal';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';
const MEAL_TYPES = ['all', 'breakfast', 'lunch', 'dinner', 'snack'];

export default function RecipesTab() {
  const [recipes, setRecipes] = useState([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [filterType, setFilterType] = useState('all');
  const [filterLiked, setFilterLiked] = useState(false);
  const [editingRecipe, setEditingRecipe] = useState(null);
  const [showEditor, setShowEditor] = useState(false);

  useEffect(() => {
    loadRecipes();
  }, []);

  async function loadRecipes() {
    setLoading(true);
    const data = await backend.entities.SavedRecipe.list('-created_date', 100).catch(() => []);
    setRecipes(data || []);
    setLoading(false);
  }

  async function handleLike(recipe) {
    const newLiked = !recipe.is_liked;
    setRecipes(prev => prev.map(r => r.id === recipe.id ? { ...r, is_liked: newLiked } : r));
    await backend.entities.SavedRecipe.update(recipe.id, { is_liked: newLiked });
  }

  async function handleDelete(recipe) {
    await backend.entities.SavedRecipe.delete(recipe.id);
    setRecipes(prev => prev.filter(r => r.id !== recipe.id));
  }

  function handleEdit(recipe) {
    setEditingRecipe(recipe);
    setShowEditor(true);
  }

  function handleNew() {
    setEditingRecipe(null);
    setShowEditor(true);
  }

  function handleSaved(saved) {
    setRecipes(prev => {
      const exists = prev.find(r => r.id === saved.id);
      if (exists) return prev.map(r => r.id === saved.id ? saved : r);
      return [saved, ...prev];
    });
    setShowEditor(false);
  }

  const filtered = recipes.filter(r => {
    if (filterLiked && !r.is_liked) return false;
    if (filterType !== 'all' && r.meal_type !== filterType) return false;
    if (search && !r.name.toLowerCase().includes(search.toLowerCase())) return false;
    return true;
  });

  const likedCount = recipes.filter(r => r.is_liked).length;

  return (
    <>
      <AnimatePresence>
        {showEditor && (
          <RecipeEditorModal
            recipe={editingRecipe}
            onClose={() => setShowEditor(false)}
            onSaved={handleSaved}
          />
        )}
      </AnimatePresence>

      <div className="space-y-4">
        {/* Header row */}
        <div className="flex items-center justify-between">
          <div>
            <p className="text-xs font-bold uppercase tracking-widest" style={{ color: '#91968e' }}>My Cookbook</p>
            <p className="text-sm font-semibold mt-0.5" style={{ color: '#141613' }}>
              {recipes.length} recipe{recipes.length !== 1 ? 's' : ''}
              {likedCount > 0 && <span style={{ color: ACCENT_DARK }}> · {likedCount} ❤️</span>}
            </p>
          </div>
          <motion.button
            whileTap={{ scale: 0.95 }}
            onClick={handleNew}
            className="flex items-center gap-1.5 px-4 py-2.5 rounded-xl text-xs font-bold"
            style={{ background: ACCENT, color: '#141613', boxShadow: '0 3px 12px rgba(200,224,0,0.3)' }}
          >
            <Plus size={13} /> New Recipe
          </motion.button>
        </div>

        {/* Search */}
        <div className="relative">
          <Search size={14} className="absolute left-3.5 top-1/2 -translate-y-1/2" style={{ color: '#91968e' }} />
          <input
            value={search}
            onChange={e => setSearch(e.target.value)}
            placeholder="Search recipes…"
            className="w-full pl-9 pr-4 py-3 rounded-2xl border text-sm outline-none"
            style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
          />
        </div>

        {/* Filter pills */}
        <div className="flex gap-2 overflow-x-auto pb-1">
          {/* Liked toggle */}
          <button
            onClick={() => setFilterLiked(f => !f)}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-full text-xs font-semibold flex-shrink-0 transition-all"
            style={{
              background: filterLiked ? 'rgba(200,224,0,0.15)' : '#ffffff',
              border: `1px solid ${filterLiked ? 'rgba(200,224,0,0.4)' : '#e8e1d4'}`,
              color: filterLiked ? ACCENT_DARK : '#5d635d',
            }}
          >
            <Heart size={11} fill={filterLiked ? ACCENT_DARK : 'none'} style={{ color: filterLiked ? ACCENT_DARK : '#91968e' }} />
            Liked
          </button>
          {MEAL_TYPES.map(t => (
            <button
              key={t}
              onClick={() => setFilterType(t)}
              className="px-3 py-1.5 rounded-full text-xs font-semibold flex-shrink-0 capitalize transition-all"
              style={{
                background: filterType === t ? 'rgba(200,224,0,0.15)' : '#ffffff',
                border: `1px solid ${filterType === t ? 'rgba(200,224,0,0.4)' : '#e8e1d4'}`,
                color: filterType === t ? ACCENT_DARK : '#5d635d',
              }}
            >{t === 'all' ? 'All meals' : t}</button>
          ))}
        </div>

        {/* Content */}
        {loading ? (
          <div className="flex items-center justify-center py-16">
            <Loader2 size={20} className="animate-spin" style={{ color: ACCENT_DARK }} />
          </div>
        ) : recipes.length === 0 ? (
          <motion.div
            initial={{ opacity: 0, y: 8 }}
            animate={{ opacity: 1, y: 0 }}
            className="flex flex-col items-center py-16 text-center"
          >
            <div className="w-16 h-16 rounded-2xl flex items-center justify-center mb-4"
              style={{ background: 'rgba(200,224,0,0.1)', border: '1px solid rgba(200,224,0,0.2)' }}>
              <BookOpen size={24} style={{ color: ACCENT_DARK }} />
            </div>
            <p className="text-base font-bold mb-1" style={{ color: '#141613' }}>Your cookbook is empty</p>
            <p className="text-sm mb-5 max-w-xs leading-relaxed" style={{ color: '#91968e' }}>
              Add custom recipes, save your AI-generated meals, and heart your favourites.
            </p>
            <motion.button
              whileTap={{ scale: 0.97 }}
              onClick={handleNew}
              className="flex items-center gap-2 px-5 py-3 rounded-2xl text-sm font-bold"
              style={{ background: ACCENT, color: '#141613' }}
            >
              <Plus size={14} /> Add your first recipe
            </motion.button>
          </motion.div>
        ) : filtered.length === 0 ? (
          <div className="flex flex-col items-center py-12 text-center">
            <p className="text-sm font-semibold mb-1" style={{ color: '#141613' }}>
              {filterLiked && likedCount === 0 ? 'No liked recipes yet' : 'No recipes match'}
            </p>
            <p className="text-xs" style={{ color: '#91968e' }}>
              {filterLiked && likedCount === 0
                ? 'Tap the ❤️ on any recipe or meal to save it here.'
                : 'Try adjusting your filters or search.'}
            </p>
          </div>
        ) : (
          <div className="space-y-3">
            {filtered.map(recipe => (
              <RecipeCard
                key={recipe.id}
                recipe={recipe}
                onLike={handleLike}
                onEdit={handleEdit}
                onDelete={handleDelete}
              />
            ))}
          </div>
        )}
      </div>
    </>
  );
}