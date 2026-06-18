import { useState, useEffect, useRef } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { ChevronLeft, ChevronRight, Sparkles, Loader2, Plus, X, UtensilsCrossed, Camera, Barcode, Trash2 } from 'lucide-react';
import { backend } from '@/api/backendClient';
import { appCache } from '@/lib/appCache';
import PhotoLogModal from '@/components/food/PhotoLogModal';
import BarcodeLogModal from '@/components/food/BarcodeLogModal';
import PremiumPaywall from '@/components/premium/PremiumPaywall';
import { useSubscription } from '@/hooks/useSubscription';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

// ---- Date helpers ----
function toDateStr(date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

function formatDateLabel(date) {
  const today = toDateStr(new Date());
  const yesterday = toDateStr(new Date(Date.now() - 86400000));
  const ds = toDateStr(date);
  if (ds === today) return `Today, ${date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}`;
  if (ds === yesterday) return `Yesterday, ${date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}`;
  return date.toLocaleDateString('en-US', { weekday: 'long', month: 'short', day: 'numeric' });
}

// ---- Date Navigator ----
function DateNav({ selectedDate, onChange }) {
  const isToday = toDateStr(selectedDate) === toDateStr(new Date());
  const prev = () => onChange(new Date(selectedDate.getTime() - 86400000));
  const next = () => onChange(new Date(selectedDate.getTime() + 86400000));
  const goToday = () => onChange(new Date());

  return (
    <div className="flex items-center justify-between gap-2 px-1 py-2">
      <button onClick={prev}
        className="w-9 h-9 rounded-xl flex items-center justify-center border transition-opacity hover:opacity-70"
        style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
        <ChevronLeft size={16} style={{ color: '#5d635d' }} />
      </button>

      <div className="flex-1 flex items-center justify-center gap-2">
        <span className="text-sm font-semibold" style={{ color: '#141613' }}>
          {formatDateLabel(selectedDate)}
        </span>
        {!isToday && (
          <button onClick={goToday}
            className="text-[10px] font-bold px-2 py-0.5 rounded-full"
            style={{ background: 'rgba(200,224,0,0.15)', color: ACCENT_DARK }}>
            Today
          </button>
        )}
      </div>

      <button onClick={next} disabled={isToday}
        className="w-9 h-9 rounded-xl flex items-center justify-center border transition-opacity hover:opacity-70 disabled:opacity-30"
        style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
        <ChevronRight size={16} style={{ color: '#5d635d' }} />
      </button>
    </div>
  );
}

// ---- AI Log Modal ----
function AILogModal({ onClose, onSave, selectedDate }) {
  const [text, setText] = useState('');
  const [analyzing, setAnalyzing] = useState(false);
  const [result, setResult] = useState(null);
  const textareaRef = useRef(null);

  const handleTextareaFocus = () => {
    setTimeout(() => {
      textareaRef.current?.scrollIntoView({ block: 'center', behavior: 'smooth' });
    }, 250);
  };

  const analyze = async () => {
    if (!text.trim()) return;
    setAnalyzing(true);
    const res = await backend.integrations.Core.InvokeLLM({
      prompt: `A fitness app user ate: "${text}". Identify each distinct food item or dish. For each item, write a short clean human-readable title (e.g. "Mini brownie", "Glass of whole milk", "Safeway sourdough loaf"), estimate realistic portion, and macros (calories, protein, carbs, fat). Each entry should represent ONE food/dish — do not group multiple different foods into one entry. Then sum up totals across all items.`,
      response_json_schema: {
        type: 'object',
        properties: {
          foods: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                name: { type: 'string' },
                portion: { type: 'string' },
                calories: { type: 'number' },
                protein: { type: 'number' },
                carbs: { type: 'number' },
                fats: { type: 'number' },
              }
            }
          },
          total_calories: { type: 'number' },
          total_protein: { type: 'number' },
          total_carbs: { type: 'number' },
          total_fats: { type: 'number' },
        }
      }
    });
    setResult(res);
    setAnalyzing(false);
  };

  const handleSave = () => {
    const time = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    const date = toDateStr(selectedDate);
    const foods = result?.foods || [];

    if (foods.length > 1) {
      // Split into one entry per food item — each becomes its own log record
      onSave(foods.map((food) => ({
        label: food.name,
        date,
        time,
        method: 'ai',
        foods: [food],
        total_calories: Number(food.calories) || 0,
        total_protein: Number(food.protein) || 0,
        total_carbs: Number(food.carbs) || 0,
        total_fats: Number(food.fats) || 0,
      })));
    } else {
      const single = foods[0];
      onSave({
        label: single?.name || text,
        date,
        time,
        method: 'ai',
        foods,
        total_calories: result?.total_calories || 0,
        total_protein: result?.total_protein || 0,
        total_carbs: result?.total_carbs || 0,
        total_fats: result?.total_fats || 0,
      });
    }
    onClose();
  };

  return (
    <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
      className="fixed inset-0 z-[80] flex items-end justify-center"
      style={{ background: 'rgba(20,22,19,0.5)' }}
      onClick={onClose}>
      <motion.div
        initial={{ y: '100%' }} animate={{ y: 0 }} exit={{ y: '100%' }}
        transition={{ type: 'spring', damping: 26, stiffness: 320 }}
        className="w-full max-w-lg rounded-t-3xl border-t border-l border-r flex flex-col shadow-warm-lg"
        style={{
          background: '#fbf8f1',
          borderColor: '#e8e1d4',
          height: 'min(460px, 58dvh)',
          maxHeight: '58dvh'
        }}
        onClick={e => e.stopPropagation()}>

        <div className="w-12 h-1 rounded-full mx-auto mt-4 mb-5 flex-shrink-0" style={{ background: '#d9d1c2' }} />

        <div className="px-6 overflow-y-auto flex-1" style={{ paddingBottom: 'max(2rem, calc(env(safe-area-inset-bottom) + 1rem))' }}>
          <div className="flex items-center justify-between mb-4">
            <div>
              <h3 className="text-base font-bold" style={{ color: '#141613' }}>Log with AI</h3>
              <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>
                {formatDateLabel(selectedDate)}
              </p>
            </div>
            <button onClick={onClose} className="w-8 h-8 rounded-xl flex items-center justify-center border"
              style={{ background: '#f2efe7', borderColor: '#e8e1d4' }}>
              <X size={15} style={{ color: '#5d635d' }} />
            </button>
          </div>

          {!result ? (
            <div className="space-y-3">
              <textarea
                ref={textareaRef}
                value={text}
                onChange={e => setText(e.target.value)}
                onFocus={handleTextareaFocus}
                placeholder="e.g. 2 scrambled eggs, toast with butter, and a black coffee"
                rows={4}
                className="w-full p-4 rounded-2xl border text-base resize-none outline-none"
                style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613', minHeight: 124 }}
                onKeyDown={e => { if (e.key === 'Enter' && e.metaKey) analyze(); }}
              />
              <button onClick={analyze} disabled={!text.trim() || analyzing}
                className="w-full py-3.5 rounded-2xl text-sm font-bold flex items-center justify-center gap-2 transition-all"
                style={{ background: text.trim() && !analyzing ? ACCENT : '#e8e1d4', color: '#141613' }}>
                {analyzing ? <><Loader2 size={14} className="animate-spin" /> Analysing...</> : <><Sparkles size={14} /> Estimate Nutrition</>}
              </button>
            </div>
          ) : (
            <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} className="space-y-3">
              <div className="rounded-2xl border overflow-hidden" style={{ borderColor: '#e8e1d4' }}>
                <div className="px-4 pt-4 pb-1">
                  {result.foods?.map((food, i) => (
                    <div key={i} className="flex items-center justify-between py-2.5 border-b last:border-0" style={{ borderColor: '#f2efe7' }}>
                      <div>
                        <p className="text-sm font-medium" style={{ color: '#141613' }}>{food.name}</p>
                        <p className="text-[11px] mt-0.5" style={{ color: '#91968e' }}>{food.portion}</p>
                      </div>
                      <div className="text-right">
                        <p className="text-sm font-bold" style={{ color: '#141613' }}>{food.calories} kcal</p>
                        <p className="text-[10px]" style={{ color: '#91968e' }}>{food.protein}g P</p>
                      </div>
                    </div>
                  ))}
                </div>
                <div className="flex items-center justify-between px-4 py-3" style={{ background: '#f9f7f3' }}>
                  <p className="text-xs font-bold uppercase tracking-wider" style={{ color: '#91968e' }}>Total</p>
                  <div className="flex items-center gap-3">
                    <span className="text-sm font-black" style={{ color: ACCENT_DARK }}>{result.total_calories} kcal</span>
                    <span className="text-xs" style={{ color: '#91968e' }}>{result.total_protein}g P · {result.total_carbs}g C · {result.total_fats}g F</span>
                  </div>
                </div>
              </div>
              <div className="flex gap-2">
                <button onClick={() => { setResult(null); }}
                  className="flex-1 py-3 rounded-xl text-sm font-semibold border"
                  style={{ borderColor: '#e8e1d4', color: '#5d635d', background: '#ffffff' }}>
                  Re-enter
                </button>
                <button onClick={handleSave}
                  className="flex-1 py-3 rounded-xl text-sm font-bold"
                  style={{ background: ACCENT, color: '#141613' }}>
                  Save Log
                </button>
              </div>
            </motion.div>
          )}
        </div>
      </motion.div>
    </motion.div>
  );
}

// ---- Manual Log Modal ----
function ManualLogModal({ onClose, onSave, selectedDate }) {
  const [name, setName] = useState('');
  const [calories, setCalories] = useState('');
  const [protein, setProtein] = useState('');
  const [carbs, setCarbs] = useState('');
  const [fats, setFats] = useState('');

  const handleSave = () => {
    if (!name.trim()) return;
    onSave({
      label: name,
      date: toDateStr(selectedDate),
      time: new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }),
      method: 'manual',
      foods: [{ name, portion: '', calories: Number(calories) || 0, protein: Number(protein) || 0 }],
      total_calories: Number(calories) || 0,
      total_protein: Number(protein) || 0,
      total_carbs: Number(carbs) || 0,
      total_fats: Number(fats) || 0,
    });
    onClose();
  };

  return (
    <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
      className="fixed inset-0 z-[80] flex items-end justify-center"
      style={{ background: 'rgba(20,22,19,0.5)' }}
      onClick={onClose}>
      <motion.div
        initial={{ y: '100%' }} animate={{ y: 0 }} exit={{ y: '100%' }}
        transition={{ type: 'spring', damping: 26, stiffness: 320 }}
        className="w-full max-w-lg rounded-t-3xl border-t border-l border-r flex flex-col shadow-warm-lg"
        style={{
          background: '#fbf8f1',
          borderColor: '#e8e1d4',
          height: 'min(460px, 58dvh)',
          maxHeight: '58dvh'
        }}
        onClick={e => e.stopPropagation()}>

        <div className="w-12 h-1 rounded-full mx-auto mt-4 mb-5 flex-shrink-0" style={{ background: '#d9d1c2' }} />

        <div className="px-6 overflow-y-auto flex-1" style={{ paddingBottom: 'max(2rem, calc(env(safe-area-inset-bottom) + 1rem))' }}>
          <div className="flex items-center justify-between mb-4">
            <div>
              <h3 className="text-base font-bold" style={{ color: '#141613' }}>Add Food Manually</h3>
              <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>
                {formatDateLabel(selectedDate)}
              </p>
            </div>
            <button onClick={onClose} className="w-8 h-8 rounded-xl flex items-center justify-center border"
              style={{ background: '#f2efe7', borderColor: '#e8e1d4' }}>
              <X size={15} style={{ color: '#5d635d' }} />
            </button>
          </div>

          <div className="space-y-3">
            <input value={name} onChange={e => setName(e.target.value)}
              placeholder="Food name or meal description"
              autoFocus
              className="w-full px-4 py-3 rounded-2xl border text-base outline-none"
              style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }} />
            <div className="grid grid-cols-2 gap-2">
              {[
                { label: 'Calories (kcal)', val: calories, set: setCalories },
                { label: 'Protein (g)', val: protein, set: setProtein },
                { label: 'Carbs (g)', val: carbs, set: setCarbs },
                { label: 'Fat (g)', val: fats, set: setFats },
              ].map(f => (
                <div key={f.label}>
                  <p className="text-[10px] font-semibold mb-1" style={{ color: '#91968e' }}>{f.label}</p>
                  <input type="number" value={f.val} onChange={e => f.set(e.target.value)}
                    placeholder="0"
                    className="w-full px-3 py-2.5 rounded-xl border text-sm outline-none"
                    style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }} />
                </div>
              ))}
            </div>
            <button onClick={handleSave} disabled={!name.trim()}
              className="w-full py-3.5 rounded-2xl text-sm font-bold transition-all"
              style={{ background: name.trim() ? ACCENT : '#e8e1d4', color: name.trim() ? '#141613' : '#91968e' }}>
              Save Entry
            </button>
          </div>
        </div>
      </motion.div>
    </motion.div>
  );
}

// ---- Main Page ----
export default function LogFood() {
  const [selectedDate, setSelectedDate] = useState(new Date());
  const [foodLogs, setFoodLogs] = useState([]);
  const [loading, setLoading] = useState(true);
  const [showAI, setShowAI] = useState(false);
  const [showManual, setShowManual] = useState(false);
  const [showPhotoLog, setShowPhotoLog] = useState(false);
  const [showBarcodeLog, setShowBarcodeLog] = useState(false);
  const [showPremiumPaywall, setShowPremiumPaywall] = useState(false);
  const { isPremium } = useSubscription();

  const dateStr = toDateStr(selectedDate);

  useEffect(() => {
    const isCameraOverlayOpen = showPhotoLog || showBarcodeLog;
    window.dispatchEvent(new CustomEvent('execute:blocking-overlay', { detail: { open: isCameraOverlayOpen } }));
    return () => window.dispatchEvent(new CustomEvent('execute:blocking-overlay', { detail: { open: false } }));
  }, [showPhotoLog, showBarcodeLog]);

  // Load FoodLog records for the selected date from backend
  useEffect(() => {
    setLoading(true);
    backend.entities.FoodLog.filter({ date: dateStr })
      .then(records => {
        // Normalise entity records to match local shape
        const normalised = records.map(r => ({
          id: r.id,
          label: r.notes || (r.foods?.[0]?.name) || 'Meal',
          date: r.date,
          time: r.time_logged || '',
          method: r.log_method || 'manual',
          foods: r.foods || [],
          total_calories: r.total_calories || 0,
          total_protein: r.total_protein_g || 0,
          total_carbs: r.total_carbs_g || 0,
          total_fats: r.total_fats_g || 0,
        }));
        setFoodLogs(normalised);
      })
      .catch(() => {})
      .finally(() => setLoading(false));
  }, [dateStr]);

  const todayLogs = foodLogs;
  const totalCal = todayLogs.reduce((s, l) => s + (l.total_calories || 0), 0);
  const totalProtein = todayLogs.reduce((s, l) => s + (l.total_protein || 0), 0);
  const totalCarbs = todayLogs.reduce((s, l) => s + (l.total_carbs || 0), 0);
  const totalFats = todayLogs.reduce((s, l) => s + (l.total_fats || 0), 0);

  const deleteLog = async (log) => {
    if (log.id) {
      await backend.entities.FoodLog.delete(log.id).catch(() => {});
    }
    const remaining = foodLogs.filter(l => l !== log);
    setFoodLogs(remaining);

    const { upsertDailyLog } = await import('@/lib/personalizationSync');
    const totalCalories = remaining.reduce((s, l) => s + (l.total_calories || 0), 0);
    const totalProtein = remaining.reduce((s, l) => s + (l.total_protein || 0), 0);
    const totalCarbs = remaining.reduce((s, l) => s + (l.total_carbs || 0), 0);
    const totalFats = remaining.reduce((s, l) => s + (l.total_fats || 0), 0);
    upsertDailyLog(dateStr, {
      calories_consumed: totalCalories,
      protein_consumed_g: totalProtein,
      carbs_consumed_g: totalCarbs,
      fats_consumed_g: totalFats,
    }).catch(() => {});

    appCache.invalidate('home-dashboard');
    appCache.invalidate('nutrition-today-');
  };

  const addLog = async (entryOrEntries) => {
    const entries = Array.isArray(entryOrEntries) ? entryOrEntries : [entryOrEntries];
    if (entries.length === 0) return;

    // Persist all entries to FoodLog entity
    const savedEntries = await Promise.all(entries.map(entry =>
      backend.entities.FoodLog.create({
        date: entry.date,
        log_method: entry.method === 'ai_photo' ? 'photo' : 'manual',
        meal_type: entry.mealType || null,
        foods: entry.foods || [],
        total_calories: entry.total_calories || 0,
        total_protein_g: entry.total_protein || 0,
        total_carbs_g: entry.total_carbs || 0,
        total_fats_g: entry.total_fats || 0,
        time_logged: entry.time,
        notes: entry.label,
      }).catch(() => null)
    ));

    const localEntries = entries.map((entry, i) => ({ ...entry, id: savedEntries[i]?.id }));
    setFoodLogs(prev => [...prev, ...localEntries]);

    const dateKey = entries[0].date;
    const { upsertDailyLog } = await import('@/lib/personalizationSync');
    const allLogsForDay = [...foodLogs, ...localEntries].filter(l => l.date === dateKey);
    const totalCalories = allLogsForDay.reduce((s, l) => s + (l.total_calories || 0), 0);
    const totalProtein = allLogsForDay.reduce((s, l) => s + (l.total_protein || 0), 0);
    const totalCarbs = allLogsForDay.reduce((s, l) => s + (l.total_carbs || 0), 0);
    const totalFats = allLogsForDay.reduce((s, l) => s + (l.total_fats || 0), 0);

    upsertDailyLog(dateKey, {
      calories_consumed: totalCalories,
      protein_consumed_g: totalProtein,
      carbs_consumed_g: totalCarbs,
      fats_consumed_g: totalFats,
    }).catch(() => {});

    appCache.invalidate('home-dashboard');
    appCache.invalidate('nutrition-today-');
  };

  const macros = [
    { label: 'Protein', value: totalProtein, unit: 'g', color: ACCENT_DARK },
    { label: 'Carbs', value: totalCarbs, unit: 'g', color: '#b05a3a' },
    { label: 'Fat', value: totalFats, unit: 'g', color: '#5d635d' },
  ];

  return (
    <div className="min-h-screen" style={{ background: '#f6f2e8' }}>
      {/* Header */}
      <div className="sticky top-0 z-40 px-5 pt-safe-header pb-4" style={{ background: 'rgba(251,248,241,0.95)', backdropFilter: 'blur(24px)', borderBottom: '1px solid #e8e1d4' }}>
        <h1 className="text-lg font-bold tracking-tight" style={{ color: '#141613' }}>Log Food</h1>
        <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>Track meals and see how today supports your goals.</p>
      </div>

      <div className="px-4 pb-32 pt-4 max-w-xl mx-auto space-y-4">

        {/* 1. Date navigator */}
        <div className="rounded-2xl border px-3" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
          <DateNav selectedDate={selectedDate} onChange={setSelectedDate} />
        </div>

        {/* 2. Daily nutrition summary */}
        <div className="p-4 rounded-2xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
          <p className="text-[10px] font-bold uppercase tracking-widest mb-3" style={{ color: '#91968e' }}>Daily Summary</p>
          <div className="flex items-end gap-1.5 mb-3">
            <span className="text-3xl font-black" style={{ color: '#141613' }}>{totalCal}</span>
            <span className="text-sm mb-0.5" style={{ color: '#91968e' }}>kcal</span>
          </div>
          <div className="grid grid-cols-3 gap-2">
            {macros.map(m => (
              <div key={m.label} className="text-center p-2.5 rounded-xl" style={{ background: '#f9f7f3' }}>
                <p className="text-base font-black" style={{ color: m.color }}>{m.value}<span className="text-xs font-normal">{m.unit}</span></p>
                <p className="text-[10px] mt-0.5" style={{ color: '#91968e' }}>{m.label}</p>
              </div>
            ))}
          </div>
        </div>

        {/* 3. Photo scan — primary action */}
        <motion.button
          whileTap={{ scale: 0.98 }}
          onClick={() => isPremium ? setShowPhotoLog(true) : setShowPremiumPaywall(true)}
          className="w-full flex items-center gap-4 p-5 rounded-2xl border text-left"
          style={{ background: 'rgba(200,224,0,0.08)', borderColor: 'rgba(200,224,0,0.35)' }}>
          <div className="w-12 h-12 rounded-2xl flex items-center justify-center flex-shrink-0"
            style={{ background: ACCENT }}>
            <Camera size={22} style={{ color: '#141613' }} />
          </div>
          <div className="flex-1">
            <p className="text-sm font-bold" style={{ color: '#141613' }}>Scan Food with Camera</p>
            <p className="text-xs mt-0.5" style={{ color: '#5d635d' }}>Snap your meal — AI estimates macros from the photo</p>
          </div>
          <ChevronRight size={16} style={{ color: '#91968e' }} />
        </motion.button>

        {/* 4. Barcode scanner */}
        <motion.button
          whileTap={{ scale: 0.97 }}
          onClick={() => setShowBarcodeLog(true)}
          className="w-full flex items-center gap-3 px-4 py-3.5 rounded-xl border text-left"
          style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
          <div className="w-8 h-8 rounded-xl flex items-center justify-center flex-shrink-0"
            style={{ background: 'rgba(200,224,0,0.1)' }}>
            <Barcode size={16} style={{ color: ACCENT_DARK }} />
          </div>
          <span className="text-sm font-medium" style={{ color: '#141613' }}>Scan packaged food barcode</span>
        </motion.button>

        {/* 5. AI text log */}
        <motion.button
          whileTap={{ scale: 0.97 }}
          onClick={() => isPremium ? setShowAI(true) : setShowPremiumPaywall(true)}
          className="w-full flex items-center gap-3 px-4 py-3.5 rounded-xl border text-left"
          style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
          <div className="w-8 h-8 rounded-xl flex items-center justify-center flex-shrink-0"
            style={{ background: 'rgba(200,224,0,0.1)' }}>
            <Sparkles size={16} style={{ color: ACCENT_DARK }} />
          </div>
          <span className="text-sm font-medium" style={{ color: '#141613' }}>Describe your meal with AI</span>
        </motion.button>

        {/* 5. Manual entry — secondary */}
        <button
          onClick={() => setShowManual(true)}
          className="w-full flex items-center gap-3 px-4 py-3.5 rounded-xl border"
          style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
          <div className="w-8 h-8 rounded-xl flex items-center justify-center flex-shrink-0"
            style={{ background: 'rgba(200,224,0,0.1)' }}>
            <Plus size={16} style={{ color: ACCENT_DARK }} />
          </div>
          <span className="text-sm font-medium" style={{ color: '#141613' }}>Add food manually</span>
        </button>

        {/* 5. Meals logged for the selected day */}
        <div>
          <p className="text-[10px] font-bold uppercase tracking-widest mb-3 px-1" style={{ color: '#91968e' }}>
            Logged — {formatDateLabel(selectedDate)}
          </p>

          {loading ? (
            <div className="flex items-center justify-center py-12 rounded-2xl border" style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
              <Loader2 size={18} className="animate-spin" style={{ color: ACCENT_DARK }} />
            </div>
          ) : todayLogs.length === 0 ? (
            <div className="flex flex-col items-center text-center py-12 rounded-2xl border"
              style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
              <div className="w-12 h-12 rounded-2xl flex items-center justify-center mb-3"
                style={{ background: '#f2efe7' }}>
                <UtensilsCrossed size={20} style={{ color: '#d9d1c2' }} />
              </div>
              <p className="text-sm font-semibold mb-1" style={{ color: '#141613' }}>No food logged for this day yet.</p>
              <p className="text-xs max-w-xs leading-relaxed" style={{ color: '#91968e' }}>
                Add a meal manually or use AI to estimate it quickly.
              </p>
            </div>
          ) : (
            <div className="space-y-2">
              {todayLogs.map((log, i) => (
                <motion.div key={i} initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: i * 0.05 }}
                  className="flex items-center gap-3 p-4 rounded-xl border"
                  style={{ background: '#ffffff', borderColor: '#e8e1d4' }}>
                  <div className="w-9 h-9 rounded-xl flex items-center justify-center flex-shrink-0"
                    style={{ background: log.method === 'ai_photo' ? 'rgba(200,224,0,0.12)' : log.method === 'ai' ? 'rgba(200,224,0,0.08)' : '#f2efe7' }}>
                    {log.method === 'ai_photo'
                      ? <Camera size={15} style={{ color: ACCENT_DARK }} />
                      : log.method === 'ai'
                        ? <Sparkles size={15} style={{ color: ACCENT_DARK }} />
                        : <Plus size={15} style={{ color: '#91968e' }} />
                    }
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-1.5">
                      <p className="text-sm font-medium truncate" style={{ color: '#141613' }}>{log.label}</p>
                      {log.method === 'ai_photo' && (
                        <span className="text-[9px] font-semibold px-1.5 py-0.5 rounded-full flex-shrink-0"
                          style={{ background: 'rgba(200,224,0,0.12)', color: ACCENT_DARK }}>
                          Photo estimate
                        </span>
                      )}
                    </div>
                    <p className="text-[10px] mt-0.5" style={{ color: '#91968e' }}>{log.time} · {log.total_protein}g P · {log.total_carbs}g C · {log.total_fats}g F</p>
                  </div>
                  <div className="flex items-center gap-2 flex-shrink-0">
                    <p className="text-sm font-bold" style={{ color: ACCENT_DARK }}>{log.total_calories} kcal</p>
                    <button
                      onClick={() => deleteLog(log)}
                      className="w-7 h-7 rounded-lg flex items-center justify-center flex-shrink-0"
                      style={{ background: '#f2efe7' }}
                    >
                      <Trash2 size={12} style={{ color: '#b05a3a' }} />
                    </button>
                  </div>
                </motion.div>
              ))}
            </div>
          )}
        </div>
      </div>

      <AnimatePresence>
        {showPremiumPaywall && <PremiumPaywall onClose={() => setShowPremiumPaywall(false)} context="AI food logging requires Execute Premium" />}
        {showPhotoLog && <PhotoLogModal onClose={() => setShowPhotoLog(false)} onSave={addLog} selectedDate={selectedDate} />}
        {showBarcodeLog && <BarcodeLogModal onClose={() => setShowBarcodeLog(false)} onSave={addLog} selectedDate={selectedDate} />}
        {showAI && <AILogModal onClose={() => setShowAI(false)} onSave={addLog} selectedDate={selectedDate} />}
        {showManual && <ManualLogModal onClose={() => setShowManual(false)} onSave={addLog} selectedDate={selectedDate} />}
      </AnimatePresence>
    </div>
  );
}