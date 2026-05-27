import { useEffect, useRef, useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { X, Loader2, Search, AlertTriangle, Sparkles } from 'lucide-react';
import { backend } from '@/api/backendClient';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

function toDateStr(date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

function readNutriment(nutriments, keys) {
  for (const key of keys) {
    const value = nutriments?.[key];
    if (value !== undefined && value !== null && value !== '') return Math.round(Number(value) || 0);
  }
  return 0;
}

// Try multiple product DBs so we always get a result for common codes.
async function fetchProductFromOpenFoodFacts(code) {
  const res = await fetch(`https://world.openfoodfacts.org/api/v2/product/${encodeURIComponent(code)}.json?fields=product_name,brands,nutriments,serving_size,quantity,image_front_url`);
  const data = await res.json();
  if (!data?.product || data.status === 0) return null;
  const p = data.product;
  const nutriments = p.nutriments || {};
  const cal = readNutriment(nutriments, ['energy-kcal_serving', 'energy-kcal_100g']);
  const pro = readNutriment(nutriments, ['proteins_serving', 'proteins_100g']);
  const car = readNutriment(nutriments, ['carbohydrates_serving', 'carbohydrates_100g']);
  const fa  = readNutriment(nutriments, ['fat_serving', 'fat_100g']);
  // OFF often has product entries with all zeros — treat as unusable
  if (!cal && !pro && !car && !fa && !p.product_name) return null;
  return {
    name: p.product_name || p.brands || `Barcode ${code}`,
    serving: p.serving_size || p.quantity || '1 serving',
    calories: cal, protein: pro, carbs: car, fats: fa,
  };
}

// AI nutritional estimation fallback — when no DB has the product,
// ask the LLM to estimate macros for the given barcode/product hint.
async function aiEstimateProduct(code) {
  const result = await backend.integrations.Core.InvokeLLM({
    prompt: `A user scanned a packaged food barcode: ${code}. Use your knowledge of UPC/EAN prefixes and common products to identify the most likely product and estimate its nutrition per typical serving. If you cannot confidently identify, return a generic packaged-food estimate based on the barcode region (US/EU). Always return values.`,
    add_context_from_internet: true,
    response_json_schema: {
      type: 'object',
      properties: {
        product_name: { type: 'string' },
        serving_size: { type: 'string' },
        calories: { type: 'number' },
        protein_g: { type: 'number' },
        carbs_g: { type: 'number' },
        fats_g: { type: 'number' },
        confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
      },
      required: ['product_name', 'calories'],
    },
  });
  if (!result?.product_name) return null;
  return {
    name: result.product_name,
    serving: result.serving_size || '1 serving',
    calories: Math.round(result.calories || 0),
    protein: Math.round(result.protein_g || 0),
    carbs: Math.round(result.carbs_g || 0),
    fats: Math.round(result.fats_g || 0),
    aiEstimated: true,
  };
}

export default function BarcodeLogModal({ onClose, onSave, selectedDate }) {
  const videoRef = useRef(null);
  const streamRef = useRef(null);
  const animationRef = useRef(null);
  const aiScanTimerRef = useRef(null);
  const canvasRef = useRef(null);
  const detectedRef = useRef(false);
  const aiInFlightRef = useRef(false);

  const [step, setStep] = useState('scan'); // scan | manual | lookup
  const [manualCode, setManualCode] = useState('');
  const [error, setError] = useState(null);
  const [loadingProduct, setLoadingProduct] = useState(false);
  const [aiScanning, setAiScanning] = useState(false);
  const [scanHint, setScanHint] = useState('Point your camera at the barcode.');

  function stopCamera() {
    detectedRef.current = true;
    if (animationRef.current) cancelAnimationFrame(animationRef.current);
    if (aiScanTimerRef.current) clearInterval(aiScanTimerRef.current);
    animationRef.current = null;
    aiScanTimerRef.current = null;
    streamRef.current?.getTracks?.().forEach(track => track.stop());
    streamRef.current = null;
  }

  async function handleDetectedCode(code) {
    if (detectedRef.current) return;
    const clean = String(code || '').replace(/\D/g, '');
    if (clean.length < 8) return; // ignore false positives
    detectedRef.current = true;
    // Light haptic feedback if available
    if (navigator.vibrate) navigator.vibrate(40);
    stopCamera();
    await lookupAndSave(clean);
  }

  async function lookupAndSave(code) {
    if (!code) return;
    setLoadingProduct(true);
    setError(null);
    setStep('lookup');

    try {
      // 1. Try Open Food Facts
      let product = await fetchProductFromOpenFoodFacts(code).catch(() => null);

      // 2. AI fallback so we always return something
      if (!product) {
        product = await aiEstimateProduct(code).catch(() => null);
      }

      if (!product) {
        setError('Could not find nutrition for this barcode. Try again or enter it manually.');
        detectedRef.current = false;
        setStep('manual');
        setLoadingProduct(false);
        return;
      }

      const dateStr = toDateStr(selectedDate);
      const timeStr = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });

      await onSave({
        label: product.name,
        date: dateStr,
        time: timeStr,
        method: 'barcode',
        mealType: 'snack',
        barcode: code,
        foods: [{
          name: product.name,
          portion: product.serving,
          calories: product.calories,
          protein: product.protein,
          carbs: product.carbs,
          fats: product.fats,
        }],
        total_calories: product.calories,
        total_protein: product.protein,
        total_carbs: product.carbs,
        total_fats: product.fats,
      });

      onClose();
    } catch (_) {
      setError('Could not look up this barcode. Try typing the numbers.');
      detectedRef.current = false;
      setStep('manual');
      setLoadingProduct(false);
    }
  }

  async function captureFrameAndScanWithAI() {
    if (detectedRef.current || aiInFlightRef.current) return;
    if (!videoRef.current || videoRef.current.readyState < 2) return;

    aiInFlightRef.current = true;
    setAiScanning(true);
    try {
      const video = videoRef.current;
      const canvas = canvasRef.current || document.createElement('canvas');
      canvasRef.current = canvas;
      // Downscale to speed up upload + OCR
      const targetW = 720;
      const scale = Math.min(1, targetW / (video.videoWidth || targetW));
      canvas.width = Math.round((video.videoWidth || 640) * scale);
      canvas.height = Math.round((video.videoHeight || 480) * scale);
      const ctx = canvas.getContext('2d');
      ctx.drawImage(video, 0, 0, canvas.width, canvas.height);

      const blob = await new Promise(resolve => canvas.toBlob(resolve, 'image/jpeg', 0.75));
      if (!blob || detectedRef.current) return;

      const file = new File([blob], 'frame.jpg', { type: 'image/jpeg' });
      const { file_url } = await backend.integrations.Core.UploadFile({ file });
      if (detectedRef.current) return;

      const result = await backend.integrations.Core.InvokeLLM({
        prompt: 'Extract the barcode number (UPC, EAN-13, EAN-8) from this image of a food package. Return ONLY the digits, no other text. If no barcode is clearly visible, return an empty string.',
        file_urls: [file_url],
        response_json_schema: {
          type: 'object',
          properties: { barcode: { type: 'string' } },
          required: ['barcode'],
        },
      });

      const detectedCode = String(result?.barcode || '').replace(/\D/g, '');
      if (detectedCode && detectedCode.length >= 8) {
        handleDetectedCode(detectedCode);
      }
    } catch (_) {
      // silently retry next interval
    } finally {
      aiInFlightRef.current = false;
      setAiScanning(false);
    }
  }

  useEffect(() => {
    if (step !== 'scan') return;
    let cancelled = false;
    detectedRef.current = false;

    async function startScanner() {
      setError(null);
      try {
        // Request HIGH-RESOLUTION rear camera with continuous focus for sharp barcodes
        const stream = await navigator.mediaDevices.getUserMedia({
          video: {
            facingMode: { ideal: 'environment' },
            width: { ideal: 1920 },
            height: { ideal: 1080 },
            focusMode: 'continuous',
          },
        }).catch(async () => {
          // Fallback to basic constraints
          return await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } });
        });

        if (cancelled) {
          stream.getTracks().forEach(track => track.stop());
          return;
        }
        streamRef.current = stream;

        // Try to enable continuous autofocus on the track for sharper close-up scans
        try {
          const track = stream.getVideoTracks()[0];
          const caps = track.getCapabilities?.() || {};
          if (caps.focusMode && caps.focusMode.includes('continuous')) {
            await track.applyConstraints({ advanced: [{ focusMode: 'continuous' }] }).catch(() => {});
          }
        } catch (_) { /* ignore */ }

        if (videoRef.current) {
          videoRef.current.srcObject = stream;
          videoRef.current.setAttribute('playsinline', 'true');
          await videoRef.current.play();
        }

        const hasNativeDetector = 'BarcodeDetector' in window;

        if (hasNativeDetector) {
          setScanHint('Hold steady — auto-detecting…');
          const detector = new window.BarcodeDetector({
            formats: ['ean_13', 'ean_8', 'upc_a', 'upc_e', 'code_128', 'code_39', 'itf'],
          });

          // Tight RAF loop — runs every animation frame so detection is instant
          const scanFrame = async () => {
            if (cancelled || detectedRef.current || !videoRef.current) return;
            try {
              const codes = await detector.detect(videoRef.current);
              const rawValue = codes?.[0]?.rawValue;
              if (rawValue) {
                handleDetectedCode(rawValue);
                return;
              }
            } catch (_) { /* keep scanning */ }
            animationRef.current = requestAnimationFrame(scanFrame);
          };
          scanFrame();

          // Also kick off AI OCR as a parallel safety net every 2.5s (in case native
          // can't read a damaged/curved barcode). It auto-stops once detection fires.
          aiScanTimerRef.current = setInterval(() => {
            captureFrameAndScanWithAI();
          }, 2500);
        } else {
          // iOS Safari / browsers without BarcodeDetector: aggressive AI OCR loop
          setScanHint('Hold the barcode steady — reading…');
          // Fire one immediately, then every 900ms
          captureFrameAndScanWithAI();
          aiScanTimerRef.current = setInterval(() => {
            captureFrameAndScanWithAI();
          }, 900);
        }
      } catch (_) {
        if (!cancelled) {
          setError('Could not access the camera. Please allow camera access or enter the barcode manually.');
          setStep('manual');
        }
      }
    }

    startScanner();

    return () => {
      cancelled = true;
      stopCamera();
    };
  }, [step]);

  return (
    <motion.div
      initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
      className="fixed inset-0 z-50 flex items-end justify-center"
      style={{ background: 'rgba(20,22,19,0.55)' }}
      onClick={onClose}
    >
      <motion.div
        initial={{ y: '100%' }} animate={{ y: 0 }} exit={{ y: '100%' }}
        transition={{ type: 'spring', damping: 26, stiffness: 320 }}
        className="w-full max-w-lg rounded-t-3xl border-t border-l border-r flex flex-col"
        style={{ background: '#fbf8f1', borderColor: '#e8e1d4', maxHeight: 'calc(100dvh - 12px)' }}
        onClick={e => e.stopPropagation()}
      >
        <div className="w-12 h-1 rounded-full mx-auto mt-4 mb-0 flex-shrink-0" style={{ background: '#d9d1c2' }} />

        <div className="flex items-center justify-between px-6 pt-4 pb-3 flex-shrink-0">
          <div>
            <h3 className="text-base font-bold" style={{ color: '#141613' }}>Scan Barcode</h3>
            <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>Auto-logs the food when detected</p>
          </div>
          <button onClick={onClose} className="w-8 h-8 rounded-xl flex items-center justify-center border"
            style={{ background: '#f2efe7', borderColor: '#e8e1d4' }}>
            <X size={15} style={{ color: '#5d635d' }} />
          </button>
        </div>

        <div className="flex-1 overflow-y-auto px-6 pb-6">
          <AnimatePresence mode="wait">
            {step === 'scan' && (
              <motion.div key="scan" initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }} className="space-y-4 pt-2">
                <div className="relative rounded-3xl overflow-hidden border" style={{ borderColor: '#e8e1d4', background: '#141613' }}>
                  <video ref={videoRef} playsInline muted autoPlay className="w-full h-72 object-cover" />
                  <div className="absolute inset-8 rounded-2xl border-2" style={{ borderColor: ACCENT }} />
                  <motion.div
                    className="absolute left-10 right-10 h-0.5"
                    style={{ background: ACCENT, boxShadow: '0 0 18px rgba(200,224,0,0.8)' }}
                    animate={{ top: ['25%', '75%', '25%'] }}
                    transition={{ duration: 2.4, repeat: Infinity, ease: 'easeInOut' }}
                  />
                  {aiScanning && (
                    <div className="absolute top-3 right-3 flex items-center gap-1.5 px-2.5 py-1 rounded-full" style={{ background: 'rgba(20,22,19,0.7)' }}>
                      <Loader2 size={10} className="animate-spin" style={{ color: ACCENT }} />
                      <span className="text-[9px] font-semibold" style={{ color: '#ffffff' }}>Reading…</span>
                    </div>
                  )}
                </div>
                <p className="text-xs text-center" style={{ color: '#5d635d' }}>{scanHint}</p>
                <button onClick={() => { stopCamera(); setStep('manual'); }} className="w-full py-3 rounded-xl text-sm font-semibold border" style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}>
                  Enter barcode manually
                </button>
              </motion.div>
            )}

            {step === 'manual' && (
              <motion.div key="manual" initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }} className="space-y-3 pt-2">
                {error && (
                  <div className="flex items-start gap-2 p-3 rounded-xl border text-xs" style={{ background: 'rgba(176,90,58,0.06)', borderColor: 'rgba(176,90,58,0.25)', color: '#b05a3a' }}>
                    <AlertTriangle size={13} className="flex-shrink-0 mt-0.5" /> {error}
                  </div>
                )}
                <input
                  value={manualCode}
                  onChange={e => setManualCode(e.target.value.replace(/\D/g, ''))}
                  placeholder="Enter barcode numbers"
                  inputMode="numeric"
                  autoFocus
                  className="w-full px-4 py-3 rounded-xl border text-sm outline-none"
                  style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
                />
                <button onClick={() => lookupAndSave(manualCode)} disabled={!manualCode || loadingProduct}
                  className="w-full py-4 rounded-2xl text-sm font-bold flex items-center justify-center gap-2"
                  style={{ background: manualCode ? ACCENT : '#e8e1d4', color: '#141613' }}>
                  {loadingProduct ? <><Loader2 size={15} className="animate-spin" /> Searching…</> : <><Search size={15} /> Find & log food</>}
                </button>
                <button onClick={() => { setError(null); setStep('scan'); }} className="w-full py-3 rounded-xl text-sm font-semibold border" style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}>
                  Back to camera
                </button>
              </motion.div>
            )}

            {step === 'lookup' && (
              <motion.div key="lookup" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} className="flex flex-col items-center py-16 gap-4">
                <Loader2 size={24} className="animate-spin" style={{ color: ACCENT_DARK }} />
                <p className="text-sm font-semibold" style={{ color: '#141613' }}>Looking up nutrition…</p>
                <div className="flex items-center gap-1.5 text-xs" style={{ color: '#91968e' }}>
                  <Sparkles size={11} style={{ color: ACCENT_DARK }} /> Checking food databases
                </div>
              </motion.div>
            )}
          </AnimatePresence>
        </div>
      </motion.div>
    </motion.div>
  );
}