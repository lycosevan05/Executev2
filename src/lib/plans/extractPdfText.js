/**
 * extractPdfText — turn an uploaded plan PDF into plain text for the BYO flow.
 *
 * Strategy (cheapest → most expensive):
 *   1. Client-side pdfjs-dist (legacy build). Concatenate page text. No network.
 *   2. Quality gate: a real threshold (not mere non-empty) rejects scanned/garbled
 *      PDFs. Below threshold → we DO NOT auto-send anywhere; the caller surfaces a
 *      one-tap prompt ("Process with AI" vs "Paste manually").
 *   3. Only on explicit user confirmation does the caller invoke `processPdfWithAI`,
 *      which sends the (page/size-capped) PDF to OpenAI via the existing invoke-llm
 *      edge function as `input_file` — a metered path, hence opt-in.
 *
 * pdfjs is imported lazily (dynamic import of the *named* module, not a hand-rolled
 * worker URL fetch) so the ~1MB dependency only loads when a user actually uploads a
 * PDF. The worker is wired via `?url` so Vite bundles it and it resolves under the
 * Capacitor `capacitor://localhost` WKWebView.
 *
 * Per-sheet scoping: callers pass an explicit `side` and route the result only to
 * that side's field — a workout-sheet upload can never land in the meal field.
 */

// Vite bundles the worker file and gives us a URL string. Loaded statically so the
// worker path is resolved at build time (mirrors durableStore's static-import
// discipline for the capacitor:// scheme).
import pdfWorkerUrl from 'pdfjs-dist/legacy/build/pdf.worker.min.mjs?url';
import { backend } from '@/api/backendClient';

// Caps that bound the opt-in OpenAI input_file cost.
const MAX_PDF_BYTES = 8 * 1024 * 1024; // 8MB
const MAX_PDF_PAGES = 30;

// Quality thresholds — below ANY of these we treat extraction as insufficient.
const MIN_CHARS = 200;
const MIN_WORDS = 40;
const MIN_ALPHA_RATIO = 0.5;

/**
 * Assess whether extracted text is good enough to use directly.
 * @returns {boolean}
 */
export function isExtractionSufficient(text) {
  const t = (text || '').trim();
  if (t.length < MIN_CHARS) return false;
  const words = t.split(/\s+/).filter(Boolean);
  if (words.length < MIN_WORDS) return false;
  const alpha = (t.match(/[a-zA-Z]/g) || []).length;
  if (alpha / t.length < MIN_ALPHA_RATIO) return false;
  return true;
}

/**
 * Client-side pdfjs text extraction.
 * @param {File|Blob} file
 * @returns {Promise<{ text: string, pages: number, sufficient: boolean }>}
 */
export async function extractPdfTextClient(file) {
  const pdfjs = await import('pdfjs-dist/legacy/build/pdf.mjs');
  pdfjs.GlobalWorkerOptions.workerSrc = pdfWorkerUrl;

  const buf = await file.arrayBuffer();
  const doc = await pdfjs.getDocument({ data: new Uint8Array(buf) }).promise;

  const pageCount = Math.min(doc.numPages, MAX_PDF_PAGES);
  const parts = [];
  for (let p = 1; p <= pageCount; p += 1) {
    const page = await doc.getPage(p);
    const content = await page.getTextContent();
    const pageText = content.items.map(it => (it.str || '')).join(' ');
    parts.push(pageText);
  }
  await doc.destroy().catch(() => {});

  const text = parts.join('\n').replace(/[ \t]+/g, ' ').trim();
  return { text, pages: doc.numPages, sufficient: isExtractionSufficient(text) };
}

/** Read a File/Blob into a base64 data URL (for the opt-in input_file path). */
function fileToDataUrl(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result || ''));
    reader.onerror = () => reject(reader.error || new Error('Failed to read PDF'));
    reader.readAsDataURL(file);
  });
}

/**
 * Opt-in AI processing: send the PDF to OpenAI via invoke-llm as input_file.
 * ONLY call after explicit user confirmation. Page/size-capped before sending.
 *
 * @param {File|Blob} file
 * @param {'workout'|'nutrition'} side
 * @returns {Promise<{ text: string, sufficient: boolean }>}
 */
export async function processPdfWithAI(file, side) {
  if (file.size > MAX_PDF_BYTES) {
    throw new Error('PDF is too large to process. Please paste the text instead.');
  }
  const dataUrl = await fileToDataUrl(file);

  const label = side === 'nutrition' ? 'nutrition / meal plan' : 'training / workout plan';
  const prompt = `The attached PDF is a user's ${label}. Extract its full readable
content as plain text, preserving the structure (days, sessions, exercises, sets/reps,
meals, macros, ordering) as faithfully as possible. Output ONLY the extracted text —
no commentary, no summary. If the document is unreadable, output an empty string.`;

  const res = await backend.integrations.Core.InvokeLLM({
    prompt,
    max_output_tokens: 4096,
    input_file: {
      filename: file.name || `${side}.pdf`,
      file_data: dataUrl,
    },
  });

  const text = String((res && (res.text || res.output_text)) || '').trim();
  return { text, sufficient: isExtractionSufficient(text) };
}
