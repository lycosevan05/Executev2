import { useState, useRef } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { X, Camera, Upload, Sparkles, Loader2, AlertTriangle, RotateCcw, Check } from 'lucide-react';
import { backend } from '@/api/backendClient';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

const MEAL_TYPES = ['breakfast', 'lunch', 'dinner', 'snack', 'pre_workout', 'post_workout'];

const CONFIDENCE_META = {
  High:   { color: ACCENT_DARK,   bg: 'rgba(142,164,0,0.1)',   label: 'High confidence' },
  Medium: { color: '#b05a3a',     bg: 'rgba(176,90,58,0.08)',  label: 'Medium confidence' },
  Low:    { color: '#b05a3a',     bg: 'rgba(176,90,58,0.08)',  label: 'Low confidence' },
};

function MacroInput({ label, value, onChange, unit = 'g' }) {
  return (
    <div>
      <p className="text-[10px] font-semibold mb-1" style={{ color: '#91968e' }}>{label}</p>
      <div className="relative">
        <input
          type="number"
          value={value}
          onChange={e => onChange(e.target.value)}
          className="w-full px-3 py-2.5 rounded-xl border text-sm outline-none pr-7"
          style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
        />
        <span className="absolute right-2.5 top-1/2 -translate-y-1/2 text-[10px] font-semibold" style={{ color: '#91968e' }}>
          {unit}
        </span>
      </div>
    </div>
  );
}

export default function PhotoLogModal({ onClose, onSave, selectedDate }) {
  const fileInputRef = useRef(null);
  const cameraInputRef = useRef(null);

  const [step, setStep] = useState('pick'); // pick | preview | estimating | review
  const [imageFile, setImageFile] = useState(null);
  const [imagePreview, setImagePreview] = useState(null);
  const [estimating, setEstimating] = useState(false);
  const [aiResult, setAiResult] = useState(null);
  const [error, setError] = useState(null);

  // Editable review fields
  const [mealName, setMealName] = useState('');
  const [mealType, setMealType] = useState('lunch');
  const [calories, setCalories] = useState('');
  const [protein, setProtein] = useState('');
  const [carbs, setCarbs] = useState('');
  const [fat, setFat] = useState('');
  const [fiber, setFiber] = useState('');
  const [saving, setSaving] = useState(false);

  // Compress large photos on-device before upload — most of the slowness comes
  // from uploading 5–10MB iPhone photos. We downscale to ~1280px JPEG @ 0.82q.
  async function compressImage(file) {
    if (!file || !file.type?.startsWith('image/')) return file;
    if (file.size < 600 * 1024) return file; // already small enough

    try {
      const dataUrl = await new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = e => resolve(e.target.result);
        reader.onerror = reject;
        reader.readAsDataURL(file);
      });
      const img = await new Promise((resolve, reject) => {
        const image = new Image();
        image.onload = () => resolve(image);
        image.onerror = reject;
        image.src = dataUrl;
      });

      const maxDim = 1280;
      const scale = Math.min(1, maxDim / Math.max(img.width, img.height));
      const w = Math.round(img.width * scale);
      const h = Math.round(img.height * scale);
      const canvas = document.createElement('canvas');
      canvas.width = w;
      canvas.height = h;
      canvas.getContext('2d').drawImage(img, 0, 0, w, h);
      const blob = await new Promise(resolve => canvas.toBlob(resolve, 'image/jpeg', 0.82));
      if (!blob) return file;
      return new File([blob], 'meal.jpg', { type: 'image/jpeg' });
    } catch {
      return file;
    }
  }

  function handleFileSelect(file) {
    if (!file) return;
    setImageFile(file);
    const reader = new FileReader();
    reader.onload = e => {
      setImagePreview(e.target.result);
      setStep('preview');
    };
    reader.readAsDataURL(file);
  }

  async function callAIEstimate(file_url) {
    return backend.integrations.Core.InvokeLLM({
      prompt: `Analyze this food photo. Identify each visible food item, estimate realistic portions, and return calories and macros. Be honest about uncertainty.`,
      file_urls: [file_url],
      response_json_schema: {
        type: 'object',
        properties: {
          detected_items: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                name: { type: 'string' },
                portion_description: { type: 'string' },
                calories: { type: 'number' },
                protein_g: { type: 'number' },
                carbs_g: { type: 'number' },
                fat_g: { type: 'number' },
                fiber_g: { type: 'number' },
              }
            }
          },
          portion_assumptions: { type: 'string' },
          total_calories: { type: 'number' },
          total_protein_g: { type: 'number' },
          total_carbs_g: { type: 'number' },
          total_fat_g: { type: 'number' },
          total_fiber_g: { type: 'number' },
          confidence_level: { type: 'string' },
          uncertainty_notes: { type: 'string' },
          meal_name_suggestion: { type: 'string' },
        }
      }
    });
  }

  async function handleEstimate() {
    if (!imageFile) return;
    setEstimating(true);
    setError(null);
    setStep('estimating');

    try {
      // 1. Compress on-device (drops 5–10MB photos to ~300KB)
      const compressed = await compressImage(imageFile);

      // 2. Upload compressed image
      const { file_url } = await backend.integrations.Core.UploadFile({ file: compressed });

      // 3. Call AI with one automatic retry on failure
      let result;
      try {
        result = await callAIEstimate(file_url);
      } catch {
        result = await callAIEstimate(file_url);
      }

      setAiResult({ ...result, image_url: file_url });
      setMealName(result.meal_name_suggestion || 'Photo meal');
      setCalories(String(Math.round(result.total_calories || 0)));
      setProtein(String(Math.round(result.total_protein_g || 0)));
      setCarbs(String(Math.round(result.total_carbs_g || 0)));
      setFat(String(Math.round(result.total_fat_g || 0)));
      setFiber(String(Math.round(result.total_fiber_g || 0)));
      setStep('review');
    } catch (err) {
      setError("Couldn't analyze the photo. Please retake or log manually.");
      setStep('preview');
    } finally {
      setEstimating(false);
    }
  }

  async function handleLog() {
    if (!aiResult) return;
    setSaving(true);
    const cal = Number(calories) || 0;
    const pro = Number(protein) || 0;
    const car = Number(carbs) || 0;
    const fa = Number(fat) || 0;
    const fi = Number(fiber) || 0;

    const toDateStr = d => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
    const dateStr = toDateStr(selectedDate);
    const timeStr = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });

    await onSave({
      label: mealName,
      date: dateStr,
      time: timeStr,
      method: 'ai_photo',
      mealType,
      imageUrl: aiResult.image_url,
      aiDetectedItems: aiResult.detected_items,
      confidenceLevel: aiResult.confidence_level,
      portionAssumptions: aiResult.portion_assumptions,
      foods: (aiResult.detected_items || []).map(item => ({
        name: item.name,
        portion: item.portion_description,
        calories: item.calories,
        protein: item.protein_g,
        carbs: item.carbs_g,
        fats: item.fat_g,
      })),
      total_calories: cal,
      total_protein: pro,
      total_carbs: car,
      total_fats: fa,
      total_fiber: fi,
    });
    setSaving(false);
    onClose();
  }

  function reset() {
    setStep('pick');
    setImageFile(null);
    setImagePreview(null);
    setAiResult(null);
    setError(null);
  }

  const confidence = aiResult?.confidence_level;
  const confidenceMeta = CONFIDENCE_META[confidence] || CONFIDENCE_META.Medium;
  const showLowWarning = confidence === 'Low';

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      className="fixed inset-0 z-50 flex items-end justify-center"
      style={{ background: 'rgba(20,22,19,0.55)' }}
      onClick={onClose}
    >
      <motion.div
        initial={{ y: '100%' }}
        animate={{ y: 0 }}
        exit={{ y: '100%' }}
        transition={{ type: 'spring', damping: 26, stiffness: 320 }}
        className="w-full max-w-lg rounded-t-3xl border-t border-l border-r flex flex-col"
        style={{
          background: '#fbf8f1',
          borderColor: '#e8e1d4',
          maxHeight: 'calc(100dvh - 12px)',
        }}
        onClick={e => e.stopPropagation()}
      >
        {/* Handle */}
        <div className="w-12 h-1 rounded-full mx-auto mt-4 mb-0 flex-shrink-0" style={{ background: '#d9d1c2' }} />

        {/* Header */}
        <div className="flex items-center justify-between px-6 pt-4 pb-3 flex-shrink-0">
          <div>
            <h3 className="text-base font-bold" style={{ color: '#141613' }}>Scan Food with Camera</h3>
            <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>AI estimates macros from your photo</p>
          </div>
          <button onClick={onClose} className="w-8 h-8 rounded-xl flex items-center justify-center border"
            style={{ background: '#f2efe7', borderColor: '#e8e1d4' }}>
            <X size={15} style={{ color: '#5d635d' }} />
          </button>
        </div>

        {/* Scrollable body */}
        <div className="flex-1 overflow-y-auto px-6 pb-2">

          {/* Hidden file inputs */}
          <input ref={fileInputRef} type="file" accept="image/*" className="hidden"
            onChange={e => handleFileSelect(e.target.files?.[0])} />
          <input ref={cameraInputRef} type="file" accept="image/*" capture="environment" className="hidden"
            onChange={e => handleFileSelect(e.target.files?.[0])} />

          {/* ── Step: Pick ── */}
          <AnimatePresence mode="wait">
            {step === 'pick' && (
              <motion.div key="pick" initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }}
                className="space-y-3 pb-6 pt-2">
                <button
                  onClick={() => cameraInputRef.current?.click()}
                  className="w-full flex items-center gap-4 p-5 rounded-2xl border"
                  style={{ background: 'rgba(200,224,0,0.07)', borderColor: 'rgba(200,224,0,0.3)' }}
                >
                  <div className="w-12 h-12 rounded-2xl flex items-center justify-center flex-shrink-0"
                    style={{ background: ACCENT }}>
                    <Camera size={22} style={{ color: '#141613' }} />
                  </div>
                  <div className="text-left">
                    <p className="text-sm font-bold" style={{ color: '#141613' }}>Take a photo</p>
                    <p className="text-xs mt-0.5" style={{ color: '#5d635d' }}>Open camera and snap your meal</p>
                  </div>
                </button>
                <button
                  onClick={() => fileInputRef.current?.click()}
                  className="w-full flex items-center gap-4 p-5 rounded-2xl border"
                  style={{ background: '#ffffff', borderColor: '#e8e1d4' }}
                >
                  <div className="w-12 h-12 rounded-2xl flex items-center justify-center flex-shrink-0"
                    style={{ background: '#f2efe7' }}>
                    <Upload size={20} style={{ color: '#5d635d' }} />
                  </div>
                  <div className="text-left">
                    <p className="text-sm font-bold" style={{ color: '#141613' }}>Upload from gallery</p>
                    <p className="text-xs mt-0.5" style={{ color: '#5d635d' }}>Choose an existing food photo</p>
                  </div>
                </button>
                {error && (
                  <div className="flex items-start gap-2 p-3 rounded-xl border text-xs"
                    style={{ background: 'rgba(176,90,58,0.06)', borderColor: 'rgba(176,90,58,0.25)', color: '#b05a3a' }}>
                    <AlertTriangle size={13} className="flex-shrink-0 mt-0.5" />
                    {error}
                  </div>
                )}
                <p className="text-[10px] text-center leading-relaxed pt-1" style={{ color: '#b8b4ac' }}>
                  AI macro estimates are approximations only. Always review before saving.
                </p>
              </motion.div>
            )}

            {/* ── Step: Preview ── */}
            {step === 'preview' && (
              <motion.div key="preview" initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }}
                className="space-y-4 pb-6 pt-2">
                {imagePreview && (
                  <div className="rounded-2xl overflow-hidden" style={{ maxHeight: 260 }}>
                    <img src={imagePreview} alt="Food preview" className="w-full object-cover" style={{ maxHeight: 260 }} />
                  </div>
                )}
                {error && (
                  <div className="flex items-start gap-2 p-3 rounded-xl border text-xs"
                    style={{ background: 'rgba(176,90,58,0.06)', borderColor: 'rgba(176,90,58,0.25)', color: '#b05a3a' }}>
                    <AlertTriangle size={13} className="flex-shrink-0 mt-0.5" />
                    {error}
                  </div>
                )}
                <button onClick={handleEstimate} disabled={estimating}
                  className="w-full py-4 rounded-2xl text-sm font-bold flex items-center justify-center gap-2"
                  style={{ background: ACCENT, color: '#141613' }}>
                  <Sparkles size={15} /> Estimate macros
                </button>
                <button onClick={reset}
                  className="w-full py-3 rounded-xl text-sm font-semibold flex items-center justify-center gap-2 border"
                  style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}>
                  <RotateCcw size={13} /> Retake / change photo
                </button>
              </motion.div>
            )}

            {/* ── Step: Estimating ── */}
            {step === 'estimating' && (
              <motion.div key="estimating" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
                className="flex flex-col items-center py-14 gap-4">
                {imagePreview && (
                  <div className="w-24 h-24 rounded-2xl overflow-hidden border" style={{ borderColor: '#e8e1d4' }}>
                    <img src={imagePreview} alt="Food" className="w-full h-full object-cover" />
                  </div>
                )}
                <motion.div animate={{ rotate: 360 }} transition={{ duration: 1.2, repeat: Infinity, ease: 'linear' }}>
                  <Loader2 size={24} style={{ color: ACCENT_DARK }} />
                </motion.div>
                <div className="text-center">
                  <p className="text-sm font-semibold" style={{ color: '#141613' }}>Analyzing your meal…</p>
                  <p className="text-xs mt-1" style={{ color: '#91968e' }}>AI is identifying food items and estimating macros</p>
                </div>
              </motion.div>
            )}

            {/* ── Step: Review ── */}
            {step === 'review' && aiResult && (
              <motion.div key="review" initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }}
                className="space-y-4 pb-6 pt-2">

                {/* Photo thumbnail + confidence */}
                <div className="flex items-start gap-3">
                  {imagePreview && (
                    <div className="w-20 h-20 rounded-2xl overflow-hidden flex-shrink-0 border" style={{ borderColor: '#e8e1d4' }}>
                      <img src={imagePreview} alt="Food" className="w-full h-full object-cover" />
                    </div>
                  )}
                  <div className="flex-1 min-w-0">
                    <div className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-[10px] font-bold mb-1.5"
                      style={{ background: confidenceMeta.bg, color: confidenceMeta.color }}>
                      <div className="w-1.5 h-1.5 rounded-full" style={{ background: confidenceMeta.color }} />
                      {confidenceMeta.label} estimate
                    </div>
                    {aiResult.detected_items?.length > 0 && (
                      <p className="text-xs leading-relaxed" style={{ color: '#5d635d' }}>
                        {aiResult.detected_items.map(i => i.name).join(', ')}
                      </p>
                    )}
                    {aiResult.portion_assumptions && (
                      <p className="text-[10px] mt-1 leading-relaxed" style={{ color: '#91968e' }}>
                        {aiResult.portion_assumptions}
                      </p>
                    )}
                  </div>
                </div>

                {/* Low confidence warning */}
                {showLowWarning && (
                  <div className="flex items-start gap-2 p-3 rounded-xl border text-xs"
                    style={{ background: 'rgba(176,90,58,0.06)', borderColor: 'rgba(176,90,58,0.25)', color: '#b05a3a' }}>
                    <AlertTriangle size={13} className="flex-shrink-0 mt-0.5" />
                    <span>Photo estimates can be inaccurate. Adjust portions before logging.</span>
                  </div>
                )}
                {aiResult.uncertainty_notes && (
                  <p className="text-[10px] leading-relaxed px-1" style={{ color: '#91968e' }}>
                    ⚠ {aiResult.uncertainty_notes}
                  </p>
                )}

                {/* Meal name */}
                <div>
                  <p className="text-[10px] font-semibold mb-1" style={{ color: '#91968e' }}>Meal name</p>
                  <input value={mealName} onChange={e => setMealName(e.target.value)}
                    className="w-full px-4 py-3 rounded-xl border text-sm outline-none"
                    style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }} />
                </div>

                {/* Meal type */}
                <div>
                  <p className="text-[10px] font-semibold mb-1.5" style={{ color: '#91968e' }}>Meal type</p>
                  <div className="flex gap-1.5 flex-wrap">
                    {MEAL_TYPES.map(t => (
                      <button key={t} onClick={() => setMealType(t)}
                        className="px-3 py-1.5 rounded-xl border text-xs font-medium capitalize transition-all"
                        style={{
                          background: mealType === t ? 'rgba(200,224,0,0.12)' : '#ffffff',
                          borderColor: mealType === t ? 'rgba(200,224,0,0.5)' : '#e8e1d4',
                          color: mealType === t ? ACCENT_DARK : '#5d635d',
                        }}>
                        {t.replace('_', ' ')}
                      </button>
                    ))}
                  </div>
                </div>

                {/* Macro inputs */}
                <div className="grid grid-cols-2 gap-2.5">
                  <div className="col-span-2">
                    <MacroInput label="Calories" value={calories} onChange={setCalories} unit="kcal" />
                  </div>
                  <MacroInput label="Protein" value={protein} onChange={setProtein} />
                  <MacroInput label="Carbs" value={carbs} onChange={setCarbs} />
                  <MacroInput label="Fat" value={fat} onChange={setFat} />
                  <MacroInput label="Fiber" value={fiber} onChange={setFiber} />
                </div>

                <p className="text-[10px] text-center" style={{ color: '#b8b4ac' }}>
                  All values are estimates. Edit before saving for best accuracy.
                </p>

                {/* Actions */}
                <button onClick={reset}
                  className="w-full py-3 rounded-xl text-sm font-semibold flex items-center justify-center gap-2 border"
                  style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}>
                  <RotateCcw size={13} /> Retake photo
                </button>
              </motion.div>
            )}
          </AnimatePresence>
        </div>

        {/* Sticky footer CTA — only on review step */}
        {step === 'review' && (
          <div className="flex-shrink-0 px-6 pt-3 border-t" style={{ borderColor: '#e8e1d4', background: '#fbf8f1', paddingBottom: 'max(1.5rem, env(safe-area-inset-bottom))' }}>
            <button
              onClick={handleLog}
              disabled={saving || !mealName.trim()}
              className="w-full py-4 rounded-2xl text-sm font-black flex items-center justify-center gap-2"
              style={{
                background: saving || !mealName.trim() ? '#e8e1d4' : ACCENT,
                color: saving || !mealName.trim() ? '#91968e' : '#141613',
              }}
            >
              {saving
                ? <><Loader2 size={15} className="animate-spin" /> Saving…</>
                : <><Check size={15} /> Log meal</>}
            </button>
          </div>
        )}
      </motion.div>
    </motion.div>
  );
}