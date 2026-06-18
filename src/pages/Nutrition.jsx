import { useState, useEffect, useRef, useCallback } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { Sparkles, Loader2, ChevronDown, ChevronUp, Droplets, UtensilsCrossed, Check, Heart, Pencil } from 'lucide-react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { backend } from '@/api/backendClient';
import { getOrCreateMealPlanForDate } from '@/lib/plans/getOrCreateMealPlanForDate';
import { buildMealPlansForDates } from '@/lib/plans/buildMealPlansForDates';
import { loadActiveAIPlan, upsertDailyLog, getTodayISODate } from '@/lib/personalizationSync';
import PremiumPaywall from '@/components/premium/PremiumPaywall';
import MealIngredients from '@/components/nutrition/MealIngredients';
import RecipesTab from '@/components/nutrition/RecipesTab';
import MealEditModal from '@/components/nutrition/MealEditModal';
import { useSubscription } from '@/hooks/useSubscription';
import { appCache } from '@/lib/appCache';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

const TABS = [
  { id: 'plan', label: 'Today' },
  { id: 'week', label: 'My Week' },
  { id: 'grocery', label: 'Grocery' },
  { id: 'recipes', label: 'Recipes' },
  { id: 'history', label: 'History' },
];

const MEAL_META = {
  breakfast: { label: 'Breakfast', time: '7–8 AM' },
  lunch: { label: 'Lunch', time: '12–1 PM' },
  dinner: { label: 'Dinner', time: '6–7 PM' },
  snack: { label: 'Snack', time: '3–4 PM' },
};

const PANTRY_STAPLES = [
  'Olive oil', 'Salt & pepper', 'Garlic', 'Onion', 'Eggs', 'Oats', 'Rice',
  'Canned tomatoes', 'Protein powder', 'Soy sauce', 'Honey', 'Lemon',
];

// ─── Helpers ──────────────────────────────────────────────────────────────────

function extractNutritionTargets(masterPlan, mealPlan = null) {
  const raw =
    masterPlan?.nutrition_targets ||
    masterPlan?.plan_payload?.nutrition_targets ||
    {};

  return {
    calories: mealPlan?.total_calories || raw.calories || raw.calorie_target || null,
    protein: mealPlan?.total_protein_g || raw.protein_g || raw.protein || raw.protein_target_g || null,
    carbs: mealPlan?.total_carbs_g || raw.carbs_g || raw.carbs || raw.carbs_target_g || null,
    fats: mealPlan?.total_fats_g || raw.fat_g || raw.fats_g || raw.fats || raw.fat || raw.fats_target_g || null,
  };
}

function normalizeMeal(meal) {
  if (!meal) return null;
  return { ...meal, fats: meal.fats ?? meal.fat ?? 0 };
}

function normalizeMealsForDisplay(meals) {
  const empty = { breakfast: null, lunch: null, dinner: null, snack: null };
  if (!meals) return empty;

  if (Array.isArray(meals)) {
    const order = ['breakfast', 'lunch', 'dinner', 'snack'];
    const normalized = { ...empty };
    meals.forEach((meal, index) => {
      const rawType = meal?.meal_type || meal?.type || order[index] || 'snack';
      const type = String(rawType).toLowerCase();
      if (['breakfast', 'lunch', 'dinner', 'snack'].includes(type)) {
        normalized[type] = normalizeMeal(meal);
      } else {
        normalized[order[index] || 'snack'] = normalizeMeal(meal);
      }
    });
    return normalized;
  }

  if (typeof meals === 'object') {
    return {
      breakfast: normalizeMeal(meals.breakfast),
      lunch: normalizeMeal(meals.lunch),
      dinner: normalizeMeal(meals.dinner),
      snack: normalizeMeal(meals.snack),
    };
  }

  return empty;
}

function groupByAisle(ingredients) {
  const aisleMap = {
    'Produce': ['spinach', 'cherry tomatoes', 'broccoli', 'sweet potato', 'lemon', 'banana', 'blueberries', 'herbs', 'garlic', 'onion'],
    'Protein': ['chicken breast', 'salmon fillet', 'whey protein', 'greek yogurt', 'eggs', 'tuna'],
    'Grains & Carbs': ['quinoa', 'granola', 'rice', 'oats', 'bread', 'pasta'],
    'Dairy & Alternatives': ['milk', 'cheese', 'butter', 'yogurt'],
    'Pantry': ['olive oil', 'honey', 'almonds', 'soy sauce', 'canned tomatoes'],
  };
  const grouped = {};
  ingredients.forEach(ing => {
    const lower = ing.toLowerCase();
    let placed = false;
    for (const [aisle, keywords] of Object.entries(aisleMap)) {
      if (keywords.some(k => lower.includes(k))) {
        if (!grouped[aisle]) grouped[aisle] = [];
        grouped[aisle].push(ing);
        placed = true;
        break;
      }
    }
    if (!placed) {
      if (!grouped['Other']) grouped['Other'] = [];
      grouped['Other'].push(ing);
    }
  });
  return grouped;
}

// ─── Grocery List ─────────────────────────────────────────────────────────────

function GroceryList({ weekMealPlans = [] }) {
  // Aggregate ingredients across all ready days in the week
  const allIngredients = [...new Set(
    weekMealPlans
      .filter(e => e.result?.status === 'ready' && e.result?.mealPlan)
      .flatMap(e => {
        const meals = normalizeMealsForDisplay(e.result.mealPlan.meals);
        return Object.values(meals).flatMap(m => m?.ingredients || []);
      })
  )];
  const grouped = groupByAisle(allIngredients);
  const [checked, setChecked] = useState({});
  const [extras, setExtras] = useState([]);
  const [newItem, setNewItem] = useState('');
  const [openAisles, setOpenAisles] = useState(Object.keys(grouped).reduce((a, k) => ({ ...a, [k]: true }), {}));

  const toggle = (item) => setChecked(prev => ({ ...prev, [item]: !prev[item] }));
  const toggleAisle = (aisle) => setOpenAisles(prev => ({ ...prev, [aisle]: !prev[aisle] }));
  const addExtra = () => {
    if (!newItem.trim()) return;
    setExtras(prev => [...prev, newItem.trim()]);
    setNewItem('');
  };

  const totalItems = allIngredients.length + extras.length;
  const checkedCount = Object.values(checked).filter(Boolean).length;

  return (
    <div className="space-y-4">
      <div className="p-4 rounded-2xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
        <div className="flex items-center justify-between mb-2">
          <p className="text-xs font-bold uppercase tracking-widest" style={{ color: '#91968e' }}>Shopping Progress</p>
          <span className="text-sm font-bold" style={{ color: ACCENT_DARK }}>{checkedCount} / {totalItems}</span>
        </div>
        <div className="h-2 rounded-full overflow-hidden" style={{ background: '#e8e1d4' }}>
          <motion.div className="h-full rounded-full" style={{ background: ACCENT }} animate={{ width: `${totalItems > 0 ? (checkedCount / totalItems) * 100 : 0}%` }} transition={{ duration: 0.4 }} />
        </div>
      </div>

      {Object.entries(grouped).map(([aisle, items]) => (
        <div key={aisle} className="rounded-2xl border overflow-hidden" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
          <button className="w-full flex items-center justify-between px-4 py-3.5" onClick={() => toggleAisle(aisle)}>
            <div className="flex items-center gap-2">
              <span className="text-sm font-semibold" style={{ color: '#141613' }}>{aisle}</span>
              <span className="text-[10px] px-2 py-0.5 rounded-full" style={{ background: '#f2efe7', color: '#91968e' }}>{items.length} items</span>
            </div>
            {openAisles[aisle] ? <ChevronUp size={14} style={{ color: '#91968e' }} /> : <ChevronDown size={14} style={{ color: '#91968e' }} />}
          </button>
          <AnimatePresence>
            {openAisles[aisle] && (
              <motion.div initial={{ height: 0 }} animate={{ height: 'auto' }} exit={{ height: 0 }} className="overflow-hidden">
                <div className="px-4 pb-3 space-y-2">
                  {items.map(item => (
                    <button key={item} onClick={() => toggle(item)}
                      className="w-full flex items-center gap-3 py-2.5 border-b last:border-0"
                      style={{ borderColor: '#f2efe7' }}>
                      <div className="w-5 h-5 rounded-full border-2 flex items-center justify-center flex-shrink-0"
                        style={{ borderColor: checked[item] ? ACCENT_DARK : '#d9d1c2', background: checked[item] ? 'rgba(200,224,0,0.15)' : 'transparent' }} />
                      <span className="text-sm text-left" style={{ color: checked[item] ? '#91968e' : '#141613', textDecoration: checked[item] ? 'line-through' : 'none' }}>{item}</span>
                    </button>
                  ))}
                </div>
              </motion.div>
            )}
          </AnimatePresence>
        </div>
      ))}

      <div className="p-4 rounded-2xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
        <p className="text-xs font-bold uppercase tracking-widest mb-3" style={{ color: '#91968e' }}>Add Extra Items</p>
        {extras.map(item => (
          <button key={item} onClick={() => toggle('extra_' + item)}
            className="flex items-center gap-3 w-full py-2 border-b last:border-0"
            style={{ borderColor: '#f2efe7' }}>
            <div className="w-5 h-5 rounded-full border-2 flex items-center justify-center flex-shrink-0"
              style={{ borderColor: checked['extra_' + item] ? ACCENT_DARK : '#d9d1c2', background: checked['extra_' + item] ? 'rgba(200,224,0,0.15)' : 'transparent' }} />
            <span className="text-sm" style={{ color: '#141613' }}>{item}</span>
          </button>
        ))}
        <div className="flex gap-2 mt-3">
          <input value={newItem} onChange={e => setNewItem(e.target.value)} onKeyDown={e => e.key === 'Enter' && addExtra()}
            placeholder="Add item..." className="flex-1 px-3 py-2.5 rounded-xl border text-sm outline-none"
            style={{ background: '#f2efe7', borderColor: '#e8e1d4', color: '#141613' }} />
          <button onClick={addExtra} className="px-3.5 py-2.5 rounded-xl" style={{ background: ACCENT, color: '#141613' }}>+</button>
        </div>
      </div>

      <div className="p-4 rounded-2xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
        <p className="text-xs font-bold uppercase tracking-widest mb-3" style={{ color: '#91968e' }}>Pantry Staples to Check</p>
        <div className="flex flex-wrap gap-2">
          {PANTRY_STAPLES.map(item => (
            <button key={item} onClick={() => toggle('pantry_' + item)}
              className="px-3 py-1.5 rounded-full text-xs border transition-all"
              style={{ background: checked['pantry_' + item] ? 'rgba(200,224,0,0.1)' : '#f2efe7', borderColor: checked['pantry_' + item] ? 'rgba(200,224,0,0.3)' : '#e8e1d4', color: checked['pantry_' + item] ? ACCENT_DARK : '#5d635d', textDecoration: checked['pantry_' + item] ? 'line-through' : 'none' }}>
              {item}
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

// ─── Session-persisted completed meals helpers ────────────────────────────────
function getSessionCompletedMeals(date) {
  try { return JSON.parse(sessionStorage.getItem(`completedMeals-${date}`) || 'null'); } catch { return null; }
}
function setSessionCompletedMeals(date, meals) {
  try {
    sessionStorage.setItem(`completedMeals-${date}`, JSON.stringify(meals));
  } catch {
    // Session storage can be unavailable in private or restricted contexts.
  }
}
function clearSessionCompletedMeals(date) {
  try {
    sessionStorage.removeItem(`completedMeals-${date}`);
  } catch {
    // Session storage can be unavailable in private or restricted contexts.
  }
}

// ─── Nutrition History ────────────────────────────────────────────────────────

function formatHistoryDateLabel(dateStr) {
  const today = getTodayISODate();
  const y = new Date();
  y.setDate(y.getDate() - 1);
  const yStr = `${y.getFullYear()}-${String(y.getMonth() + 1).padStart(2, '0')}-${String(y.getDate()).padStart(2, '0')}`;
  if (dateStr === today) return 'Today';
  if (dateStr === yStr) return 'Yesterday';
  return new Date(dateStr + 'T12:00:00').toLocaleDateString('en-US', { weekday: 'long', month: 'short', day: 'numeric' });
}

function hasNutritionData(log) {
  return (Number(log?.calories_consumed) || 0) > 0
    || (Number(log?.protein_consumed_g) || 0) > 0
    || (Number(log?.carbs_consumed_g) || 0) > 0
    || (Number(log?.fats_consumed_g) || 0) > 0
    || (Number(log?.water_liters) || 0) > 0
    || (Array.isArray(log?.meals_completed) && log.meals_completed.length > 0);
}

function NutritionHistory() {
  const [logs, setLogs] = useState([]);
  const [foodLogsByDate, setFoodLogsByDate] = useState({});
  const [loading, setLoading] = useState(true);
  const [openDate, setOpenDate] = useState(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    const today = getTodayISODate();
    Promise.all([
      backend.entities.DailyLog.list('-date', 60).catch(() => []),
      backend.entities.FoodLog.list('-date', 200).catch(() => []),
    ]).then(([dailyLogs, foodLogs]) => {
      if (cancelled) return;
      const seen = new Set();
      const past = (dailyLogs || [])
        .filter(l => l.date && l.date < today)
        .sort((a, b) => b.date.localeCompare(a.date))
        .filter(l => { if (seen.has(l.date)) return false; seen.add(l.date); return true; })
        .filter(hasNutritionData);
      setLogs(past);

      const byDate = {};
      (foodLogs || []).forEach(f => {
        if (!f.date) return;
        if (!byDate[f.date]) byDate[f.date] = [];
        byDate[f.date].push(f);
      });
      setFoodLogsByDate(byDate);
    }).finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, []);

  if (loading) {
    return (
      <div className="flex items-center justify-center py-20">
        <Loader2 size={20} className="animate-spin" style={{ color: ACCENT_DARK }} />
      </div>
    );
  }

  if (logs.length === 0) {
    return (
      <div className="flex flex-col items-center py-20 text-center">
        <div className="w-14 h-14 rounded-2xl flex items-center justify-center mb-4"
          style={{ background: 'rgba(200,224,0,0.1)', border: '1px solid rgba(200,224,0,0.2)' }}>
          <UtensilsCrossed size={22} style={{ color: ACCENT_DARK }} />
        </div>
        <p className="text-base font-bold mb-1" style={{ color: '#141613' }}>No nutrition history yet</p>
        <p className="text-sm" style={{ color: '#91968e' }}>Log a meal today and it will appear here tomorrow.</p>
      </div>
    );
  }

  return (
    <div className="space-y-2">
      <p className="text-xs font-bold uppercase tracking-widest px-1 mb-1" style={{ color: '#91968e' }}>
        Previous Days
      </p>
      {logs.map(log => {
        const isOpen = openDate === log.date;
        const cals = Number(log.calories_consumed) || 0;
        const protein = Number(log.protein_consumed_g) || 0;
        const carbs = Number(log.carbs_consumed_g) || 0;
        const fats = Number(log.fats_consumed_g) || 0;
        const water = Number(log.water_liters) || 0;
        const mealsDone = Array.isArray(log.meals_completed) ? log.meals_completed.length : 0;
        const foodLogs = foodLogsByDate[log.date] || [];

        return (
          <div key={log.id || log.date} className="rounded-2xl border overflow-hidden"
            style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
            <button
              className="w-full flex items-center justify-between px-4 py-3 text-left"
              onClick={() => setOpenDate(isOpen ? null : log.date)}
            >
              <div className="min-w-0">
                <p className="text-sm font-bold" style={{ color: '#141613' }}>{formatHistoryDateLabel(log.date)}</p>
                <p className="text-[11px] mt-0.5" style={{ color: '#91968e' }}>
                  {Math.round(cals)} kcal · {Math.round(protein)}g P · {Math.round(carbs)}g C · {Math.round(fats)}g F
                </p>
              </div>
              {isOpen
                ? <ChevronUp size={14} style={{ color: '#91968e' }} />
                : <ChevronDown size={14} style={{ color: '#91968e' }} />}
            </button>
            <AnimatePresence>
              {isOpen && (
                <motion.div
                  initial={{ height: 0, opacity: 0 }} animate={{ height: 'auto', opacity: 1 }}
                  exit={{ height: 0, opacity: 0 }} transition={{ duration: 0.2 }}
                  className="overflow-hidden"
                >
                  <div className="px-4 pb-4 pt-1 space-y-3" style={{ borderTop: '1px solid #f2efe7' }}>
                    <p className="text-[11px] pt-3" style={{ color: '#91968e' }}>
                      {new Date(log.date + 'T12:00:00').toLocaleDateString('en-US', { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' })}
                    </p>

                    {/* Macro grid */}
                    <div className="grid grid-cols-4 gap-2">
                      {[
                        { label: 'Calories', val: cals, unit: 'kcal', color: ACCENT_DARK },
                        { label: 'Protein',  val: protein, unit: 'g', color: '#8ea400' },
                        { label: 'Carbs',    val: carbs,   unit: 'g', color: '#b05a3a' },
                        { label: 'Fats',     val: fats,    unit: 'g', color: '#5d635d' },
                      ].map(m => (
                        <div key={m.label} className="text-center p-2 rounded-xl"
                          style={{ background: '#f9f7f3', border: '1px solid #e8e1d4' }}>
                          <div className="text-sm font-black" style={{ color: m.color }}>
                            {Math.round(m.val)}<span className="text-[9px] font-normal">{m.unit === 'kcal' ? '' : m.unit}</span>
                          </div>
                          <div className="text-[9px]" style={{ color: '#91968e' }}>{m.label}</div>
                        </div>
                      ))}
                    </div>

                    {/* Water + meals completed */}
                    {(water > 0 || mealsDone > 0) && (
                      <div className="flex flex-wrap gap-2">
                        {water > 0 && (
                          <div className="flex items-center gap-1.5 px-3 py-1.5 rounded-xl text-xs font-semibold"
                            style={{ background: 'rgba(74,144,217,0.08)', border: '1px solid rgba(74,144,217,0.2)' }}>
                            <Droplets size={11} style={{ color: '#4a90d9' }} />
                            <span style={{ color: '#141613', fontWeight: 700 }}>{water.toFixed(1)}</span>
                            <span style={{ color: '#91968e', fontWeight: 400 }}>L water</span>
                          </div>
                        )}
                        {mealsDone > 0 && (
                          <div className="flex items-center gap-1.5 px-3 py-1.5 rounded-xl text-xs font-semibold"
                            style={{ background: 'rgba(200,224,0,0.1)', border: '1px solid rgba(200,224,0,0.25)' }}>
                            <Check size={11} style={{ color: ACCENT_DARK }} />
                            <span style={{ color: '#141613', fontWeight: 700 }}>{mealsDone}</span>
                            <span style={{ color: '#91968e', fontWeight: 400 }}>meal{mealsDone !== 1 ? 's' : ''} eaten</span>
                          </div>
                        )}
                      </div>
                    )}

                    {/* Logged food list */}
                    {foodLogs.length > 0 && (
                      <div>
                        <p className="text-[10px] font-bold uppercase tracking-widest mb-2" style={{ color: '#91968e' }}>
                          Logged Foods
                        </p>
                        <div className="space-y-1.5">
                          {foodLogs.map(f => {
                            const label = f.notes || f.foods?.[0]?.name || 'Meal';
                            return (
                              <div key={f.id} className="flex items-center justify-between py-1.5 px-3 rounded-xl"
                                style={{ background: '#f9f7f3', border: '1px solid #e8e1d4' }}>
                                <div className="min-w-0 flex-1">
                                  <p className="text-xs font-medium truncate" style={{ color: '#141613' }}>{label}</p>
                                  {f.time_logged && (
                                    <p className="text-[10px]" style={{ color: '#91968e' }}>{f.time_logged}</p>
                                  )}
                                </div>
                                <p className="text-xs font-bold ml-2 flex-shrink-0" style={{ color: ACCENT_DARK }}>
                                  {Math.round(f.total_calories || 0)} kcal
                                </p>
                              </div>
                            );
                          })}
                        </div>
                      </div>
                    )}
                  </div>
                </motion.div>
              )}
            </AnimatePresence>
          </div>
        );
      })}
    </div>
  );
}

// ─── Main page ────────────────────────────────────────────────────────────────

export default function Nutrition() {
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const { isPremium } = useSubscription();
  const [showPremiumPaywall, setShowPremiumPaywall] = useState(false);
  const dateParam = searchParams.get('date');
  const planIdParam = searchParams.get('planId');
  const targetDate = dateParam || getTodayISODate();
  const todayStr = getTodayISODate();

  // Hydrate instantly from in-memory cache so navigating back to Nutrition is instant.
  const cacheKey = `nutrition-today-${targetDate}`;
  const cachedToday = appCache.get(cacheKey) || {};
  const cachedWeek = appCache.get(`nutrition-week-${targetDate}`) || {};

  const [activeTab, setActiveTab] = useState('plan');
  const [mealPlan, setMealPlan] = useState(cachedToday.mealPlan || null);
  const [mealStatus, setMealStatus] = useState(cachedToday.mealStatus || 'loading');
  const [masterPlan, setMasterPlan] = useState(cachedToday.masterPlan || null);
  const [overviewDay, setOverviewDay] = useState(cachedToday.overviewDay || null);
  const [nutritionTargets, setNutritionTargets] = useState(cachedToday.nutritionTargets || { calories: null, protein: null, carbs: null, fats: null });
  const [completedMeals, setCompletedMeals] = useState(() => getSessionCompletedMeals(getTodayISODate()) || []);
  const completedMealsUserSetRef = useRef(getSessionCompletedMeals(getTodayISODate()) !== null);
  const [mealPlanRaw, setMealPlanRaw] = useState(cachedToday.mealPlanRaw || null); // raw MealPlan record for calorie writes
  const [generatingMeal, setGeneratingMeal] = useState(false);
  const [generationError, setGenerationError] = useState('');
  const [weekMealPlans, setWeekMealPlans] = useState(cachedWeek.entries || []);
  const [loadingWeek, setLoadingWeek] = useState(false);
  const [waterGoal, setWaterGoal] = useState(cachedToday.waterGoal ?? null);
  const [waterLiters, setWaterLiters] = useState(cachedToday.waterLiters ?? 0);
  // Totals from logged food (DailyLog.calories_consumed etc. — populated by /log-food and meal-ticks)
  const [loggedTotals, setLoggedTotals] = useState(cachedToday.loggedTotals || { cals: 0, protein: 0, carbs: 0, fats: 0 });
  // Rolling 7-day build state
  const [buildingWeek, setBuildingWeek] = useState(false);
  const [weekBuildResult, setWeekBuildResult] = useState(null);
  const [weekBuildError, setWeekBuildError] = useState('');
  const [missingDaysCount, setMissingDaysCount] = useState(0);
  const [editingMeal, setEditingMeal] = useState(null); // { meal, mealType, mealPlanId }
  const [likedMeals, setLikedMeals] = useState({}); // { [mealType]: true } tracks liked state for today's meals

  // ── Helpers ───────────────────────────────────────────────────────────────────

  function getRollingSevenDates(startDate) {
    const dates = [];
    const start = new Date(startDate + 'T12:00:00');
    for (let i = 0; i < 7; i++) {
      const d = new Date(start);
      d.setDate(start.getDate() + i);
      dates.push(`${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`);
    }
    return dates;
  }

  async function loadRollingMealPlanStatus(startDate, activePlan = null) {
    const dates = getRollingSevenDates(startDate);
    const results = await Promise.all(
      dates.map(async (date) => {
        const result = await getOrCreateMealPlanForDate(date, {
          generate: false,
          masterPlan: activePlan || masterPlan,
        }).catch(() => ({
          status: 'error', mealPlan: null, masterPlan: null, overviewDay: null,
        }));
        return { date, result };
      })
    );
    return results;
  }

  // Single unified build function — builds all missing days, updating the list live
  async function handleBuildAllMissingDays(forceAll = false) {
    if (buildingWeek) return;
    setBuildingWeek(true);
    setWeekBuildError('');
    setWeekBuildResult(null);

    try {
      // Load current rolling status first
      const rolling = await loadRollingMealPlanStatus(targetDate, masterPlan);
      const toProcess = forceAll
        ? rolling
        : rolling.filter(e => e.result?.status !== 'ready');

      if (!toProcess.length) {
        setWeekMealPlans(rolling);
        setMissingDaysCount(0);
        setBuildingWeek(false);
        return;
      }

      // Seed week list with loading indicators only for days we're building
      setWeekMealPlans(rolling.map(e =>
        toProcess.find(t => t.date === e.date)
          ? { ...e, result: { ...e.result, status: 'loading' } }
          : e
      ));

      const built = [];
      const failed = [];

      // Concurrent, rate-limit-safe build: invariant context is fetched once and
      // per-day generation runs under a bounded pool inside the orchestrator.
      const results = await buildMealPlansForDates(toProcess.map(t => t.date), { masterPlan });

      for (const { date, status, mealPlan } of results) {
        const generated = { status, mealPlan, masterPlan, overviewDay: null };

        // Update this day's entry in the list
        setWeekMealPlans(prev => prev.map(e =>
          e.date === date ? { ...e, result: generated } : e
        ));

        if (status === 'ready') {
          built.push(date);
          // If it's today, also update the Today tab
          if (date === targetDate && mealPlan) {
            setMealStatus('ready');
            setMealPlanRaw(mealPlan);
            setMealPlan(normalizeMealsForDisplay(mealPlan.meals));
            setNutritionTargets(extractNutritionTargets(masterPlan, mealPlan));
            appCache.invalidate(cacheKey);
          }
        } else {
          failed.push({ date });
        }
      }

      setWeekBuildResult({ built, failed });
      setMissingDaysCount(failed.length);
    } catch (err) {
      setWeekBuildError(err?.message || 'Could not build meal plan.');
    } finally {
      setBuildingWeek(false);
    }
  }

  // ── Always-on DailyLog fetch — independent of meal-plan cache freshness ──────
  // Critical: loggedTotals (calories_consumed etc.) must refresh on every mount
  // because LogFood/Track can write DailyLog without invalidating the meal-plan
  // cache, and they're separate concerns.
  useEffect(() => {
    let cancelled = false;
    Promise.all([
      backend.entities.UserProfile.list('-updated_date', 1).catch(() => []),
      backend.entities.DailyLog.filter({ date: todayStr }).catch(() => []),
    ]).then(([userProfiles, dailyLogs]) => {
      if (cancelled) return;
      const userProfile = userProfiles?.[0] || null;
      const dailyLog = dailyLogs?.[0] || null;
      if (userProfile?.water_goal_liters) setWaterGoal(userProfile.water_goal_liters);
      if (dailyLog?.water_liters != null) setWaterLiters(dailyLog.water_liters);
      const nextLoggedTotals = {
        cals: Number(dailyLog?.calories_consumed) || 0,
        protein: Number(dailyLog?.protein_consumed_g) || 0,
        carbs: Number(dailyLog?.carbs_consumed_g) || 0,
        fats: Number(dailyLog?.fats_consumed_g) || 0,
      };
      setLoggedTotals(nextLoggedTotals);
      if (!completedMealsUserSetRef.current && Array.isArray(dailyLog?.meals_completed)) {
        setCompletedMeals(dailyLog.meals_completed);
      }
      // Merge into the meal-plan cache so a subsequent mount hydrates instantly
      // with the correct totals (instead of zeroes).
      const existing = appCache.get(cacheKey) || {};
      appCache.set(cacheKey, {
        ...existing,
        loggedTotals: nextLoggedTotals,
        waterLiters: dailyLog?.water_liters ?? 0,
        waterGoal: userProfile?.water_goal_liters ?? existing.waterGoal ?? null,
      });
    });
    return () => { cancelled = true; };
  }, [todayStr, cacheKey]);

  // ── Load today's meal plan — self-hydrating (loads activePlan independently) ──
  useEffect(() => {
    let cancelled = false;
    // Skip meal-plan network if cached today is fresh AND already ready.
    // (DailyLog/loggedTotals are handled by the always-on effect above.)
    if (appCache.isFresh(cacheKey) && cachedToday.mealStatus === 'ready') {
      return;
    }
    // Don't wipe existing data on reload — only show loading if we have nothing yet
    setMealStatus(prev => prev === 'ready' ? 'ready' : 'loading');
    setGenerationError('');

    async function loadData() {
      const activePlan = await loadActiveAIPlan('daily').catch(() => null);
      if (cancelled) return;

      // 2. If no active plan, only show no-plan if we don't already have one loaded
      if (!activePlan) {
        setMealStatus(prev => prev === 'ready' ? 'ready' : 'no_plan');
        return;
      }

      // 3. Active plan exists — update master plan + nutrition targets
      setMasterPlan(activePlan);
      setNutritionTargets(t => t.calories ? t : extractNutritionTargets(activePlan, null));

      // 4. Check for existing MealPlan (in parallel with nothing blocking it now)
      const result = await getOrCreateMealPlanForDate(targetDate, {
        planId: planIdParam,
        generate: false,
        masterPlan: activePlan,
      }).catch(() => null);
      if (cancelled) return;

      if (!result || result.status === 'error') {
        setMealStatus(prev => prev === 'ready' ? 'ready' : 'error');
        setGenerationError(result?.error || 'Could not load meal data.');
        return;
      }

      // 6. Resolve status — never downgrade from 'ready' to 'needs_generation' on re-mount
      const resolvedStatus = (result.status === 'no_plan') ? 'needs_generation' : result.status;
      setMealStatus(resolvedStatus);
      setOverviewDay(result.overviewDay || null);

      if (result.status === 'ready' && result.mealPlan) {
        const normalizedMeals = normalizeMealsForDisplay(result.mealPlan.meals);
        const targets = extractNutritionTargets(activePlan, result.mealPlan);
        setMealPlanRaw(result.mealPlan);
        setMealPlan(normalizedMeals);
        setNutritionTargets(targets);
        // Persist to cache so next mount is instant (preserve loggedTotals from sibling effect)
        const existing = appCache.get(cacheKey) || {};
        appCache.set(cacheKey, {
          ...existing,
          mealStatus: 'ready',
          mealPlan: normalizedMeals,
          mealPlanRaw: result.mealPlan,
          masterPlan: activePlan,
          overviewDay: result.overviewDay || null,
          nutritionTargets: targets,
        });
      }

      // 7. Rolling 7-day missing count (non-blocking)
      loadRollingMealPlanStatus(targetDate, activePlan).then(rolling => {
        const missing = rolling.filter(e => e.result?.status === 'needs_generation').length;
        setMissingDaysCount(missing);
      }).catch(() => {});
    }

    loadData().catch(err => {
      if (!cancelled) {
        setMealStatus(prev => prev === 'ready' ? 'ready' : 'error');
        setGenerationError(err?.message || 'Failed to load meal plan.');
      }
    });

    return () => { cancelled = true; };
  }, [targetDate, planIdParam]);

  // ── Build meals on demand ────────────────────────────────────────────────────
  async function handleBuildMeals() {
    setGeneratingMeal(true);
    setGenerationError('');

    try {
      const result = await getOrCreateMealPlanForDate(targetDate, { generate: true, masterPlan });

      if (result.status !== 'ready' || !result.mealPlan) {
        throw new Error(result.error || 'Could not build meals for this date.');
      }

      setMealStatus('ready');
      setMasterPlan(result.masterPlan || null);
      setOverviewDay(result.overviewDay || null);
      setMealPlanRaw(result.mealPlan);
      setMealPlan(normalizeMealsForDisplay(result.mealPlan.meals));
      setNutritionTargets(extractNutritionTargets(result.masterPlan, result.mealPlan));
    } catch (err) {
      console.error('[Nutrition] build meals error:', err);
      setGenerationError(err?.message || 'Could not build meals for this date.');
      setMealStatus('error');
    } finally {
      setGeneratingMeal(false);
    }
  }

  // ── Week + Grocery tabs — load rolling week ───────────────────────────────────
  useEffect(() => {
    if (activeTab !== 'week' && activeTab !== 'grocery') return;
    const weekKey = `nutrition-week-${targetDate}`;
    // Skip refetch if fresh cache exists with data
    if (appCache.isFresh(weekKey) && weekMealPlans.length > 0) return;
    setLoadingWeek(true);
    loadRollingMealPlanStatus(targetDate)
      .then(entries => {
        setWeekMealPlans(entries);
        setMissingDaysCount(entries.filter(e => e.result?.status === 'needs_generation').length);
        appCache.set(weekKey, { entries });
      })
      .catch(() => {})
      .finally(() => setLoadingWeek(false));
   
  }, [activeTab, targetDate]);

  // ── Water tracking ────────────────────────────────────────────────────────────
  const waterSaveTimer = useRef(null);
  const updateWater = useCallback((newVal) => {
    const clamped = Math.max(0, +newVal.toFixed(2));
    setWaterLiters(clamped);
    // Debounce the DB write — only save 800ms after the last tap
    if (waterSaveTimer.current) clearTimeout(waterSaveTimer.current);
    waterSaveTimer.current = setTimeout(() => {
      upsertDailyLog(todayStr, { water_liters: clamped }).catch(() => {});
    }, 800);
  }, [todayStr]);

  // ── Derived values ────────────────────────────────────────────────────────────
  const CALORIE_GOAL = nutritionTargets.calories;
  const PROTEIN_GOAL = nutritionTargets.protein;
  const CARBS_GOAL = nutritionTargets.carbs;
  const FATS_GOAL = nutritionTargets.fats;

  // Calories/macros from planned meals the user has ticked as eaten
  const completedMealEntries = mealPlan ? Object.entries(mealPlan).filter(([type]) => completedMeals.includes(type)) : [];
  const tickedCals = completedMealEntries.reduce((s, [, m]) => s + (m?.calories || 0), 0);
  const tickedProtein = completedMealEntries.reduce((s, [, m]) => s + (m?.protein || 0), 0);
  const tickedCarbs = completedMealEntries.reduce((s, [, m]) => s + (m?.carbs || 0), 0);
  const tickedFats = completedMealEntries.reduce((s, [, m]) => s + (m?.fats ?? m?.fat ?? 0), 0);

  // Totals displayed = the larger of (DailyLog.calories_consumed) and (ticked meal sums).
  // DailyLog is updated by both /log-food and meal-ticks, so this naturally reflects all sources.
  const totalCals = Math.max(loggedTotals.cals, tickedCals);
  const totalProtein = Math.max(loggedTotals.protein, tickedProtein);
  const totalCarbs = Math.max(loggedTotals.carbs, tickedCarbs);
  const totalFats = Math.max(loggedTotals.fats, tickedFats);

  const weekHasAnyPlan = weekMealPlans.some(e => e.result?.status === 'ready' || e.result?.status === 'needs_generation');

  return (
    <div className="min-h-screen" style={{ background: '#f6f2e8' }}>
      <AnimatePresence>
        {showPremiumPaywall && <PremiumPaywall onClose={() => setShowPremiumPaywall(false)} context="AI meal planning requires Execute Premium" />}
      </AnimatePresence>
      <AnimatePresence>
        {editingMeal && (
          <MealEditModal
            meal={editingMeal.meal}
            mealType={editingMeal.mealType}
            mealPlanId={editingMeal.mealPlanId}
            onClose={() => setEditingMeal(null)}
            onSaved={(mealType, updatedMeal) => {
            setMealPlan(prev => ({ ...prev, [mealType]: updatedMeal }));
            setEditingMeal(null);
            appCache.invalidate(cacheKey);
            }}
          />
        )}
      </AnimatePresence>
      <div className="sticky top-0 z-40 px-5 pb-3 pt-safe-header" style={{ background: 'rgba(251,248,241,0.97)', backdropFilter: 'blur(24px)', borderBottom: '1px solid #ddd6c8', boxShadow: '0 2px 12px rgba(20,22,19,0.06)' }}>
        <div className="flex items-center justify-between mb-3">
          <div>
            <h1 className="text-lg font-bold tracking-tight" style={{ color: '#141613' }}>Nutrition</h1>
            <p className="text-xs" style={{ color: '#91968e' }}>
              {new Date(targetDate + 'T12:00:00').toLocaleDateString('en-US', { weekday: 'long', month: 'short', day: 'numeric' })}
            </p>
          </div>
        </div>
        <div className="flex gap-0.5">
          {TABS.map(tab => (
            <button key={tab.id} onClick={() => setActiveTab(tab.id)}
              className="flex-1 py-1.5 rounded-lg text-[10px] font-medium transition-all"
              style={{ background: activeTab === tab.id ? '#ffffff' : 'transparent', color: activeTab === tab.id ? '#141613' : '#a09a90', border: activeTab === tab.id ? '1px solid #ddd6c8' : '1px solid transparent', boxShadow: activeTab === tab.id ? '0 2px 8px rgba(20,22,19,0.09)' : 'none' }}>
              {tab.label}
            </button>
          ))}
        </div>
      </div>

      <div className="px-5 pb-32 pt-4">
        <div>

          {/* ── TODAY TAB ── */}
          <div style={{ display: activeTab === 'plan' ? 'block' : 'none' }}>
            <div className="space-y-4">

              {mealStatus === 'loading' && (
                <div className="flex items-center justify-center py-24">
                  <Loader2 size={22} className="animate-spin" style={{ color: ACCENT_DARK }} />
                </div>
              )}

              {mealStatus === 'no_plan' && (
                <div className="flex flex-col items-center py-20 text-center">
                  <div className="w-16 h-16 rounded-2xl flex items-center justify-center mb-5"
                    style={{ background: 'rgba(200,224,0,0.1)', border: '1px solid rgba(200,224,0,0.2)' }}>
                    <Sparkles size={26} style={{ color: ACCENT_DARK }} />
                  </div>
                  <p className="text-base font-bold mb-2" style={{ color: '#141613' }}>No performance plan yet</p>
                  <p className="text-sm leading-relaxed max-w-xs mb-6" style={{ color: '#91968e' }}>
                    Complete the Plan Questionnaire to create your first training, nutrition, and recovery week.
                  </p>
                  <Link to="/plan?generate=true"
                    className="flex items-center gap-2 px-6 py-3.5 rounded-2xl text-sm font-bold"
                    style={{ background: ACCENT, color: '#141613' }}>
                    <Sparkles size={14} /> Create my plan
                  </Link>
                </div>
              )}

              {mealStatus === 'needs_generation' && (
                <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} className="space-y-4">
                  <div className="p-5 rounded-3xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                    <div className="w-14 h-14 rounded-2xl flex items-center justify-center mb-4"
                      style={{ background: 'rgba(200,224,0,0.1)', border: '1px solid rgba(200,224,0,0.2)' }}>
                      <UtensilsCrossed size={24} style={{ color: ACCENT_DARK }} />
                    </div>
                    <h2 className="text-lg font-black tracking-tight mb-1" style={{ color: '#141613' }}>Build your 7-day meal plan</h2>
                    <p className="text-sm leading-relaxed mb-5" style={{ color: '#91968e' }}>
                      Start with today, then we'll fill the next 6 days so your week is ready.
                    </p>

                    {/* Context pills */}
                    <div className="space-y-2 mb-5">
                      {overviewDay?.nutrition_focus && (
                        <div className="px-3 py-2 rounded-xl border" style={{ background: '#f9f7f3', borderColor: '#e8e1d4' }}>
                          <p className="text-[10px] font-bold uppercase tracking-widest mb-0.5" style={{ color: '#91968e' }}>Nutrition focus</p>
                          <p className="text-xs font-medium" style={{ color: '#5d635d' }}>{overviewDay.nutrition_focus}</p>
                        </div>
                      )}
                      {(CALORIE_GOAL || PROTEIN_GOAL) && (
                        <div className="flex gap-2">
                          {CALORIE_GOAL && (
                            <div className="flex-1 px-3 py-2 rounded-xl border text-center" style={{ background: '#f9f7f3', borderColor: '#e8e1d4' }}>
                              <p className="text-sm font-black" style={{ color: '#141613' }}>{Math.round(CALORIE_GOAL)}</p>
                              <p className="text-[10px]" style={{ color: '#91968e' }}>kcal target</p>
                            </div>
                          )}
                          {PROTEIN_GOAL && (
                            <div className="flex-1 px-3 py-2 rounded-xl border text-center" style={{ background: '#f9f7f3', borderColor: '#e8e1d4' }}>
                              <p className="text-sm font-black" style={{ color: '#141613' }}>{Math.round(PROTEIN_GOAL)}g</p>
                              <p className="text-[10px]" style={{ color: '#91968e' }}>protein target</p>
                            </div>
                          )}
                        </div>
                      )}
                    </div>

                    {(generationError || weekBuildError) && (
                      <p className="text-xs mb-4 px-3 py-2 rounded-xl border" style={{ color: '#b05a3a', background: 'rgba(176,90,58,0.06)', borderColor: 'rgba(176,90,58,0.2)' }}>
                        {generationError || weekBuildError}
                      </p>
                    )}

                    {weekBuildResult && (
                      <div className="mb-4 px-3 py-2.5 rounded-xl border text-xs" style={{ background: 'rgba(200,224,0,0.07)', borderColor: 'rgba(200,224,0,0.25)', color: '#5d635d' }}>
                        {weekBuildResult.failed.length === 0
                          ? 'Your next 7 days are planned.'
                          : `Some days are ready. A few need another try.`}
                        {weekBuildResult.built.length > 0 && <span className="ml-1">Built {weekBuildResult.built.length} · </span>}
                        {weekBuildResult.skipped.length > 0 && <span>Already had {weekBuildResult.skipped.length} · </span>}
                        {weekBuildResult.failed.length > 0 && <span style={{ color: '#b05a3a' }}>Failed {weekBuildResult.failed.length}</span>}
                      </div>
                    )}

                    {/* Primary: Build 7 days */}
                    <motion.button whileTap={{ scale: 0.97 }} onClick={() => isPremium ? handleBuildAllMissingDays(true) : setShowPremiumPaywall(true)}
                      disabled={buildingWeek}
                      className="w-full py-4 rounded-2xl text-sm font-bold flex items-center justify-center gap-2 mb-3"
                      style={{ background: buildingWeek ? 'rgba(200,224,0,0.5)' : ACCENT, color: '#141613', boxShadow: buildingWeek ? 'none' : '0 5px 20px rgba(200,224,0,0.38)' }}>
                      {buildingWeek
                        ? <><Loader2 size={15} className="animate-spin" /> Building weekly nutrition plan…</>
                        : <><Sparkles size={15} /> Build 7 days</>}
                    </motion.button>

                    {/* Secondary: Build today only */}
                    <button onClick={() => isPremium ? handleBuildMeals() : setShowPremiumPaywall(true)} disabled={generatingMeal || buildingWeek}
                      className="w-full py-2.5 text-sm font-semibold text-center"
                      style={{ color: '#91968e' }}>
                      {generatingMeal ? 'Building today…' : 'Build today only'}
                    </button>
                  </div>
                </motion.div>
              )}

              {mealStatus === 'error' && !generatingMeal && (
                <div className="flex flex-col items-center py-20 text-center">
                  <div className="w-16 h-16 rounded-2xl flex items-center justify-center mb-5"
                    style={{ background: 'rgba(176,90,58,0.08)', border: '1px solid rgba(176,90,58,0.2)' }}>
                    <UtensilsCrossed size={26} style={{ color: '#b05a3a' }} />
                  </div>
                  <p className="text-base font-bold mb-2" style={{ color: '#141613' }}>We couldn't build your meals</p>
                  <p className="text-sm leading-relaxed max-w-xs mb-6" style={{ color: '#91968e' }}>
                    {generationError || 'Please try again.'}
                  </p>
                  <button onClick={handleBuildMeals}
                    className="flex items-center gap-2 px-6 py-3.5 rounded-2xl text-sm font-bold"
                    style={{ background: ACCENT, color: '#141613' }}>
                    <Sparkles size={14} /> Try again
                  </button>
                </div>
              )}

              {mealStatus === 'ready' && mealPlan && (
                <>
                  {/* Missing days banner */}
                  {missingDaysCount > 0 && !buildingWeek && (
                    <div className="flex items-center justify-between px-4 py-3 rounded-2xl border"
                      style={{ background: 'rgba(200,224,0,0.07)', borderColor: 'rgba(200,224,0,0.25)' }}>
                      <p className="text-xs font-semibold" style={{ color: '#5d635d' }}>
                        {missingDaysCount} day{missingDaysCount > 1 ? 's' : ''} still need meals.
                      </p>
                      <button onClick={() => isPremium ? handleBuildAllMissingDays() : setShowPremiumPaywall(true)}
                        className="text-xs font-bold px-3 py-1.5 rounded-xl flex-shrink-0 ml-3"
                        style={{ background: ACCENT, color: '#141613' }}>
                        Build missing
                      </button>
                    </div>
                  )}
                  {buildingWeek && (
                    <div className="flex items-center gap-2 px-4 py-3 rounded-2xl border"
                      style={{ background: 'rgba(200,224,0,0.07)', borderColor: 'rgba(200,224,0,0.25)' }}>
                      <Loader2 size={13} className="animate-spin" style={{ color: ACCENT_DARK }} />
                      <p className="text-xs font-semibold" style={{ color: '#5d635d' }}>
                        Building weekly nutrition plan…
                      </p>
                    </div>
                  )}
                  {weekBuildResult && !buildingWeek && (
                    <div className="px-4 py-3 rounded-2xl border text-xs"
                      style={{ background: 'rgba(200,224,0,0.07)', borderColor: 'rgba(200,224,0,0.25)', color: '#5d635d' }}>
                      {weekBuildResult.failed.length === 0 ? 'Your next 7 days are planned.' : 'Some days are ready. A few need another try.'}
                    </div>
                  )}

                  {/* Macro targets bar */}
                  <div className="p-4 rounded-2xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                    <div className="flex items-center justify-between mb-2">
                      <p className="text-xs font-bold uppercase tracking-widest" style={{ color: '#91968e' }}>Today's Targets</p>
                      <span className="text-xs font-bold" style={{ color: ACCENT_DARK }}>
                        {Math.round(totalCals)}{CALORIE_GOAL ? ` / ${Math.round(CALORIE_GOAL)}` : ''} kcal
                      </span>
                    </div>
                    <div className="h-2 rounded-full overflow-hidden mb-3" style={{ background: '#e8e1d4' }}>
                      <motion.div className="h-full rounded-full" style={{ background: ACCENT }} initial={{ width: 0 }}
                        animate={{ width: CALORIE_GOAL ? `${Math.min((totalCals / CALORIE_GOAL) * 100, 100)}%` : '0%' }}
                        transition={{ duration: 1 }} />
                    </div>
                    <div className="grid grid-cols-3 gap-2">
                      {[{ label: 'Protein', v: totalProtein, g: PROTEIN_GOAL }, { label: 'Carbs', v: totalCarbs, g: CARBS_GOAL }, { label: 'Fats', v: totalFats, g: FATS_GOAL }].map(m => (
                        <div key={m.label} className="text-center">
                          <div className="text-sm font-bold" style={{ color: '#141613' }}>{Math.round(m.v)}<span className="text-[10px] font-normal">g</span></div>
                          <div className="text-[10px]" style={{ color: '#91968e' }}>{m.label}{m.g ? ` · ${Math.round(m.g)}g` : ''}</div>
                          <div className="h-1 rounded-full mt-1 overflow-hidden" style={{ background: '#e8e1d4' }}>
                            <div className="h-full rounded-full" style={{ width: m.g ? `${Math.min((m.v / m.g) * 100, 100)}%` : '0%', background: ACCENT_DARK }} />
                          </div>
                        </div>
                      ))}
                    </div>
                  </div>

                  {/* Water tracker */}
                  <div className="p-4 rounded-2xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                    <div className="flex items-center justify-between mb-3">
                      <div className="flex items-center gap-2">
                        <Droplets size={14} style={{ color: '#5d8aa8' }} />
                        <p className="text-xs font-bold uppercase tracking-widest" style={{ color: '#91968e' }}>Water Intake</p>
                      </div>
                      <span className="text-sm font-bold" style={{ color: waterGoal && waterLiters >= waterGoal ? '#8ea400' : '#141613' }}>
                        {waterLiters.toFixed(1)}{waterGoal ? ` / ${waterGoal}L` : 'L logged'}
                      </span>
                    </div>
                    <div className="h-2 rounded-full overflow-hidden mb-3" style={{ background: '#e8e1d4' }}>
                      <div className="h-full rounded-full transition-all duration-300"
                        style={{ width: waterGoal ? `${Math.min((waterLiters / waterGoal) * 100, 100)}%` : '0%', background: '#5d8aa8' }} />
                    </div>
                    <div className="flex items-center gap-2 flex-wrap">
                      {[0.25, 0.33, 0.5].map(amt => (
                        <button key={amt} onClick={() => updateWater(Math.min(waterLiters + amt, (waterGoal || 5) * 2))}
                          className="flex-1 py-2.5 rounded-xl text-xs font-bold border transition-all"
                          style={{ background: '#f2efe7', borderColor: '#e8e1d4', color: '#5d635d' }}>
                          +{amt === 0.33 ? '330ml' : `${amt * 1000}ml`}
                        </button>
                      ))}
                      <button onClick={() => updateWater(waterLiters - 0.25)}
                        className="px-4 py-2.5 rounded-xl text-xs font-bold border"
                        style={{ background: '#f2efe7', borderColor: '#e8e1d4', color: '#b05a3a' }}>
                        −
                      </button>
                    </div>
                    {waterGoal && waterLiters >= waterGoal && (
                      <p className="text-[10px] mt-2 font-semibold" style={{ color: '#8ea400' }}>✓ Daily water goal reached</p>
                    )}
                  </div>

                  {/* Meal cards */}
                  {Object.entries(mealPlan).map(([type, meal], i) => {
                    if (!meal) return null;
                    const meta = MEAL_META[type] || { label: type, time: '' };
                    const isDone = completedMeals.includes(type);
                    return (
                      <motion.div key={type} initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: i * 0.07 }}
                        className="p-4 rounded-2xl border" style={{ background: isDone ? 'rgba(200,224,0,0.07)' : '#ffffff', borderColor: isDone ? 'rgba(200,224,0,0.4)' : '#e0d9cc', boxShadow: '0 1px 6px rgba(20,22,19,0.06)' }}>
                        <div className="flex items-start justify-between mb-2">
                          <div>
                            <div className="flex items-center gap-2 mb-0.5">
                              <span className="text-[10px] font-bold uppercase tracking-widest" style={{ color: '#91968e' }}>{meta.label}</span>
                              <span className="text-[10px]" style={{ color: '#d9d1c2' }}>· {meta.time}</span>
                            </div>
                            <h3 className="text-sm font-bold" style={{ color: '#141613' }}>{meal?.name}</h3>
                          </div>
                          <div className="flex items-center gap-1.5 flex-shrink-0 ml-2">
                            {/* Edit meal */}
                            <button
                              title="Edit meal"
                              onClick={() => setEditingMeal({ meal, mealType: type, mealPlanId: mealPlanRaw?.id })}
                              className="w-8 h-8 rounded-xl flex items-center justify-center flex-shrink-0"
                              style={{ background: '#f2efe7', border: '1px solid #e8e1d4' }}
                            >
                              <Pencil size={12} style={{ color: '#5d635d' }} />
                            </button>
                            {/* Like & save to cookbook */}
                            <button
                              title={likedMeals[type] ? 'Saved to recipes' : 'Save to recipes'}
                              onClick={async () => {
                                if (likedMeals[type]) return; // already liked
                                setLikedMeals(prev => ({ ...prev, [type]: true }));
                                backend.entities.SavedRecipe.create({
                                  name: meal.name,
                                  meal_type: type,
                                  calories: meal.calories || 0,
                                  protein: meal.protein || 0,
                                  carbs: meal.carbs || 0,
                                  fats: meal.fats ?? meal.fat ?? 0,
                                  ingredients: meal.ingredients || [],
                                  notes: meal.notes || '',
                                  source: 'ai_generated',
                                  is_liked: true,
                                }).catch(() => setLikedMeals(prev => ({ ...prev, [type]: false })));
                              }}
                              className="w-8 h-8 rounded-xl flex items-center justify-center flex-shrink-0 transition-all"
                              style={{
                                background: likedMeals[type] ? 'rgba(176,90,58,0.12)' : '#f2efe7',
                                border: `1px solid ${likedMeals[type] ? 'rgba(176,90,58,0.3)' : '#e8e1d4'}`,
                              }}
                            >
                              <Heart size={13} fill={likedMeals[type] ? '#b05a3a' : 'none'} style={{ color: '#b05a3a' }} />
                            </button>
                          <button onClick={async () => {
                            const newCompleted = isDone ? completedMeals.filter(m => m !== type) : [...completedMeals, type];
                            completedMealsUserSetRef.current = true; // lock against fetch override
                            setSessionCompletedMeals(todayStr, newCompleted);
                            setCompletedMeals(newCompleted);
                            // Persist completed state + sum calories/protein to DailyLog
                            if (mealPlan) {
                              const consumed = Object.entries(mealPlan).reduce((sum, [t, m]) => {
                                return sum + (newCompleted.includes(t) ? (m?.calories || 0) : 0);
                              }, 0);
                              const protein = Object.entries(mealPlan).reduce((sum, [t, m]) => {
                                return sum + (newCompleted.includes(t) ? (m?.protein || 0) : 0);
                              }, 0);
                              upsertDailyLog(todayStr, {
                                meals_completed: newCompleted,
                                calories_consumed: consumed,
                                protein_consumed_g: protein,
                              }).catch(() => {});
                            }
                          }}
                            className="w-8 h-8 rounded-xl flex items-center justify-center flex-shrink-0"
                              style={{ background: isDone ? 'rgba(200,224,0,0.15)' : '#f2efe7', border: `1px solid ${isDone ? 'rgba(200,224,0,0.4)' : '#e8e1d4'}` }}>
                              {isDone && <Check size={13} style={{ color: ACCENT_DARK }} />}
                            </button>
                            </div>
                        </div>
                        <div className="flex gap-3 mb-2.5">
                          <span className="text-xs font-semibold" style={{ color: '#141613' }}>{Math.round(meal?.calories || 0)} kcal</span>
                          <span className="text-xs" style={{ color: '#91968e' }}>{Math.round(meal?.protein || 0)}g P · {Math.round(meal?.carbs || 0)}g C · {Math.round(meal?.fats || meal?.fat || 0)}g F</span>
                        </div>
                        <MealIngredients ingredients={meal?.ingredients} />
                        {meal?.notes && <p className="text-xs leading-relaxed" style={{ color: '#91968e' }}>{meal.notes}</p>}
                      </motion.div>
                    );
                  })}
                </>
              )}
            </div>
          </div>

          {/* ── WEEK TAB ── */}
          <div style={{ display: activeTab === 'week' ? 'block' : 'none' }}>
            <div className="space-y-4">
              {loadingWeek ? (
                <div className="flex items-center justify-center py-16">
                  <Loader2 size={20} className="animate-spin" style={{ color: ACCENT_DARK }} />
                </div>
              ) : !weekHasAnyPlan ? (
                <div className="flex flex-col items-center py-20 text-center">
                  <div className="w-16 h-16 rounded-2xl flex items-center justify-center mb-5"
                    style={{ background: 'rgba(200,224,0,0.1)', border: '1px solid rgba(200,224,0,0.2)' }}>
                    <Sparkles size={26} style={{ color: ACCENT_DARK }} />
                  </div>
                  <p className="text-base font-bold mb-2" style={{ color: '#141613' }}>No performance plan yet</p>
                  <p className="text-sm leading-relaxed max-w-xs mb-6" style={{ color: '#91968e' }}>
                    Complete the Plan Questionnaire to generate your first personalized performance week.
                  </p>
                  <Link to="/plan?generate=true"
                    className="flex items-center gap-2 px-6 py-3.5 rounded-2xl text-sm font-bold"
                    style={{ background: ACCENT, color: '#141613' }}>
                    <Sparkles size={14} /> Create my plan
                  </Link>
                </div>
              ) : (
                <div className="space-y-3">
                  <p className="text-xs font-bold uppercase tracking-widest px-1" style={{ color: '#91968e' }}>Next 7 Days</p>
                  {/* Missing days banner in week tab */}
                  {missingDaysCount > 0 && !buildingWeek && (
                    <div className="flex items-center justify-between px-4 py-3 rounded-2xl border"
                      style={{ background: 'rgba(200,224,0,0.07)', borderColor: 'rgba(200,224,0,0.25)' }}>
                      <p className="text-xs font-semibold" style={{ color: '#5d635d' }}>
                        {missingDaysCount} day{missingDaysCount > 1 ? 's' : ''} still need meals.
                      </p>
                      <button onClick={() => isPremium ? handleBuildAllMissingDays() : setShowPremiumPaywall(true)}
                        className="text-xs font-bold px-3 py-1.5 rounded-xl flex-shrink-0 ml-3"
                        style={{ background: ACCENT, color: '#141613' }}>
                        Build missing
                      </button>
                    </div>
                  )}
                  {buildingWeek && (
                    <div className="flex items-center gap-2 px-4 py-3 rounded-2xl border"
                      style={{ background: 'rgba(200,224,0,0.07)', borderColor: 'rgba(200,224,0,0.25)' }}>
                      <Loader2 size={13} className="animate-spin" style={{ color: ACCENT_DARK }} />
                      <p className="text-xs font-semibold" style={{ color: '#5d635d' }}>
                        Building weekly nutrition plan…
                      </p>
                    </div>
                  )}

                  {weekMealPlans.map(({ date, result }) => {
                    const dateLabel = new Date(date + 'T12:00:00').toLocaleDateString('en-US', { weekday: 'long', month: 'short', day: 'numeric' });
                    const isToday = date === todayStr;
                    const status = result?.status;
                    const plan = result?.mealPlan;

                    if (status === 'loading') {
                      return (
                        <div key={date} className="rounded-2xl border px-4 py-3.5 flex items-center gap-3"
                          style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                          <Loader2 size={14} className="animate-spin flex-shrink-0" style={{ color: ACCENT_DARK }} />
                          <p className="text-sm font-semibold" style={{ color: '#91968e' }}>{dateLabel}</p>
                        </div>
                      );
                    }

                    if (status === 'ready' && plan) {
                      const meals = normalizeMealsForDisplay(plan.meals || {});
                      const hasMeals = Object.values(meals).some(Boolean);
                      return (
                        <div key={date} className="rounded-2xl border overflow-hidden"
                          style={{ background: '#ffffff', borderColor: isToday ? 'rgba(200,224,0,0.5)' : '#e8e1d4' }}>
                          <div className="px-4 pt-4 pb-3 flex items-center justify-between"
                            style={{ borderBottom: '1px solid #f2efe7', background: isToday ? 'rgba(200,224,0,0.05)' : 'transparent' }}>
                            <div>
                              <div className="flex items-center gap-2">
                                {isToday && <span className="text-[10px] font-bold px-2 py-0.5 rounded-full" style={{ background: ACCENT, color: '#141613' }}>TODAY</span>}
                                <p className="text-[10px] font-semibold uppercase tracking-wider" style={{ color: '#91968e' }}>{dateLabel}</p>
                              </div>
                              {plan.total_calories && (
                                <p className="text-sm font-bold mt-0.5" style={{ color: '#141613' }}>{Math.round(plan.total_calories)} kcal · {Math.round(plan.total_protein_g || 0)}g protein</p>
                              )}
                            </div>
                            <button onClick={() => { navigate(`/nutrition?date=${date}`); setActiveTab('plan'); }}
                              className="px-3 py-1.5 rounded-xl text-xs font-semibold border"
                              style={{ borderColor: '#e8e1d4', color: '#5d635d', background: '#f9f7f3' }}>
                              {isToday ? 'View Detail' : 'Switch Day'}
                            </button>
                          </div>
                          {hasMeals ? (
                            <div className="px-4 py-3 space-y-2">
                              {Object.entries(meals).filter(([, meal]) => meal).map(([type, meal]) => (
                                <div key={type} className="flex items-center justify-between py-1.5 border-b last:border-0" style={{ borderColor: '#f9f7f3' }}>
                                  <div>
                                    <p className="text-[10px] font-bold uppercase tracking-widest" style={{ color: '#91968e' }}>{type}</p>
                                    <p className="text-sm font-medium" style={{ color: '#141613' }}>{meal?.name}</p>
                                  </div>
                                  <p className="text-xs font-semibold" style={{ color: '#5d635d' }}>{Math.round(meal?.calories || 0)} kcal</p>
                                </div>
                              ))}
                            </div>
                          ) : (
                            <div className="px-4 py-3">
                              <p className="text-xs" style={{ color: '#91968e' }}>Open day to view meals</p>
                            </div>
                          )}
                        </div>
                      );
                    }

                    // needs_generation — placeholder
                    if (status === 'needs_generation') {
                      return (
                        <div key={date} className="rounded-2xl border px-4 py-3.5 flex items-center justify-between"
                          style={{ background: '#ffffff', borderColor: isToday ? 'rgba(200,224,0,0.4)' : '#e8e1d4' }}>
                          <div>
                            <div className="flex items-center gap-2 mb-0.5">
                              {isToday && <span className="text-[10px] font-bold px-2 py-0.5 rounded-full" style={{ background: ACCENT, color: '#141613' }}>TODAY</span>}
                              <p className="text-[10px] font-semibold uppercase tracking-wider" style={{ color: '#91968e' }}>{dateLabel}</p>
                            </div>
                            <p className="text-sm font-semibold" style={{ color: '#5d635d' }}>Ready to build</p>
                          </div>
                          <button
                            disabled={buildingWeek}
                            onClick={async () => {
                              if (!isPremium) { setShowPremiumPaywall(true); return; }
                              setWeekMealPlans(prev => prev.map(e => e.date === date ? { ...e, result: { status: 'loading' } } : e));
                              const generated = await getOrCreateMealPlanForDate(date, { generate: true, masterPlan });
                              setWeekMealPlans(prev => prev.map(e => e.date === date ? { ...e, result: generated } : e));
                              if (generated.status === 'ready') {
                                setMissingDaysCount(c => Math.max(0, c - 1));
                                if (date === targetDate && generated.mealPlan) {
                                  setMealStatus('ready');
                                  setMealPlanRaw(generated.mealPlan);
                                  setMealPlan(normalizeMealsForDisplay(generated.mealPlan.meals));
                                  setNutritionTargets(extractNutritionTargets(generated.masterPlan, generated.mealPlan));
                                  appCache.invalidate(cacheKey);
                                }
                              }
                            }}
                            className="px-3 py-1.5 rounded-xl text-xs font-bold ml-3 flex-shrink-0 flex items-center gap-1.5"
                            style={{ background: ACCENT, color: '#141613' }}>
                            <Sparkles size={11} /> Build this day
                          </button>
                        </div>
                      );
                    }

                    // no_plan or error
                    return (
                      <div key={date} className="rounded-2xl border px-4 py-3.5 flex items-center justify-between"
                        style={{ background: '#f9f7f3', borderColor: '#e8e1d4' }}>
                        <div className="flex items-center gap-3">
                          {isToday && <span className="text-[10px] font-bold px-2 py-0.5 rounded-full" style={{ background: ACCENT, color: '#141613' }}>TODAY</span>}
                          <p className="text-sm font-semibold" style={{ color: '#91968e' }}>{dateLabel}</p>
                        </div>
                        <span className="text-xs font-semibold px-3 py-1 rounded-full" style={{ background: '#e8e1d4', color: '#91968e' }}>No plan</span>
                      </div>
                    );
                  })}
                </div>
              )}
            </div>
          </div>

          {/* ── RECIPES TAB ── */}
          <div style={{ display: activeTab === 'recipes' ? 'block' : 'none' }}>
            <RecipesTab />
          </div>

          {/* ── HISTORY TAB ── */}
          <div style={{ display: activeTab === 'history' ? 'block' : 'none' }}>
            <NutritionHistory />
          </div>

          {/* ── GROCERY TAB ── */}
          <div style={{ display: activeTab === 'grocery' ? 'block' : 'none' }}>
            {weekMealPlans.some(e => e.result?.status === 'ready') ? (
              <>
                <p className="text-xs font-bold uppercase tracking-widest px-1 mb-3" style={{ color: '#91968e' }}>
                  Weekly Grocery List · {weekMealPlans.filter(e => e.result?.status === 'ready').length} days planned
                </p>
                <GroceryList weekMealPlans={weekMealPlans} />
              </>
            ) : (
              <div className="flex flex-col items-center py-20 text-center">
                <div className="w-14 h-14 rounded-2xl flex items-center justify-center mb-4"
                  style={{ background: '#f2efe7', border: '1px solid #e8e1d4' }}>
                  <UtensilsCrossed size={22} style={{ color: '#d9d1c2' }} />
                </div>
                <p className="text-sm font-semibold mb-1" style={{ color: '#141613' }}>No meals built yet</p>
                <p className="text-sm" style={{ color: '#91968e' }}>Build your week's meals first to see your grocery list.</p>
              </div>
            )}
          </div>

        </div>
      </div>
    </div>
  );
}
