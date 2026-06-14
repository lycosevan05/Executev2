import { handleCors, json } from '../_shared/cors.ts';
import { getUser } from '../_shared/records.ts';

// Backoff tuning for transient OpenAI 429 (TPM) / 5xx responses.
const LLM_MAX_ATTEMPTS = 5;
const LLM_BASE_MS = 500;
const LLM_PER_WAIT_CAP_MS = 20_000;
const LLM_DEADLINE_MS = 45_000;

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/** Parse Retry-After (seconds) / retry-after-ms (ms) from OpenAI response headers. */
function parseRetryAfterMs(headers: Headers): number {
  const ms = headers.get('retry-after-ms');
  if (ms && !Number.isNaN(Number(ms))) return Number(ms);
  const secs = headers.get('retry-after');
  if (secs && !Number.isNaN(Number(secs))) return Number(secs) * 1000;
  return 0;
}

/**
 * POST to OpenAI with full-jitter backoff. Retries on 429 and >=500.
 * Honors Retry-After as a minimum wait. Returns the final Response (which may
 * still be an error after exhausting attempts).
 * `forceFailures` returns a synthetic 429 for the first N attempts (testing).
 */
async function fetchOpenAIWithBackoff(
  url: string,
  init: RequestInit,
  forceFailures = 0,
): Promise<Response> {
  const start = Date.now();
  let lastResponse: Response | null = null;

  for (let attempt = 1; attempt <= LLM_MAX_ATTEMPTS; attempt++) {
    if (attempt <= forceFailures) {
      lastResponse = new Response(
        JSON.stringify({ error: { message: `Synthetic 429 (attempt ${attempt})` } }),
        { status: 429, headers: { 'Content-Type': 'application/json', 'retry-after': '0' } },
      );
    } else {
      lastResponse = await fetch(url, init);
    }

    const status = lastResponse.status;
    const retryable = status === 429 || status >= 500;
    if (!retryable) return lastResponse;

    const elapsed = Date.now() - start;
    if (attempt >= LLM_MAX_ATTEMPTS || elapsed >= LLM_DEADLINE_MS) return lastResponse;

    const expo = Math.min(LLM_PER_WAIT_CAP_MS, LLM_BASE_MS * 2 ** (attempt - 1));
    const jittered = Math.random() * expo;
    let wait = Math.max(parseRetryAfterMs(lastResponse.headers), jittered);
    wait = Math.min(wait, Math.max(0, LLM_DEADLINE_MS - elapsed));
    console.warn(`[invoke-llm] ${status} on attempt ${attempt}; backing off ${Math.round(wait)}ms`);
    // Drain the body so the connection can be reused.
    await lastResponse.body?.cancel().catch(() => {});
    await sleep(wait);
  }

  return lastResponse as Response;
}

function extractOutputText(response: Record<string, unknown>) {
  if (typeof response.output_text === 'string') return response.output_text;

  const output = Array.isArray(response.output) ? response.output : [];
  const chunks: string[] = [];
  for (const item of output as Array<Record<string, unknown>>) {
    const content = Array.isArray(item.content) ? item.content : [];
    for (const part of content as Array<Record<string, unknown>>) {
      if (typeof part.text === 'string') chunks.push(part.text);
    }
  }
  return chunks.join('\n').trim();
}

Deno.serve(async (req) => {
  const cors = handleCors(req);
  if (cors) return cors;

  try {
    await getUser(req);

    const apiKey = Deno.env.get('OPENAI_API_KEY');
    if (!apiKey) {
      return json({ error: 'OPENAI_API_KEY is not configured.' }, 500);
    }

    const payload = await req.json().catch(() => ({}));
    const prompt = String(payload.prompt || '');
    const fileUrls = Array.isArray(payload.file_urls) ? payload.file_urls.filter(Boolean) : [];
    const model = payload.model || Deno.env.get('OPENAI_MODEL') || 'gpt-4.1-mini';
    const maxOutputTokens = payload.max_output_tokens || payload.max_tokens || 4096;

    const content = [
      { type: 'input_text', text: prompt },
      ...fileUrls.map((imageUrl: string) => ({
        type: 'input_image',
        image_url: imageUrl,
        detail: payload.image_detail || 'auto',
      })),
    ];

    const requestBody: Record<string, unknown> = {
      model,
      input: [{ role: 'user', content }],
      max_output_tokens: maxOutputTokens,
    };

    if (payload.temperature !== undefined) {
      requestBody.temperature = payload.temperature;
    }

    if (payload.response_json_schema) {
      requestBody.text = {
        format: {
          type: 'json_schema',
          name: String(payload.schema_name || 'execute_response').replace(/[^a-zA-Z0-9_-]/g, '_').slice(0, 64),
          schema: payload.response_json_schema,
          strict: false,
        },
      };
    }

    const forceFailures = Number(Deno.env.get('FORCE_LLM_429') || 0) || 0;
    const openaiResponse = await fetchOpenAIWithBackoff('https://api.openai.com/v1/responses', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(requestBody),
    }, forceFailures);

    const responseJson = await openaiResponse.json().catch(() => ({}));
    if (!openaiResponse.ok) {
      return json({
        error: responseJson?.error?.message || 'OpenAI request failed.',
        details: responseJson?.error || responseJson,
      }, openaiResponse.status);
    }

    const outputText = extractOutputText(responseJson);
    if (payload.response_json_schema) {
      try {
        return json(JSON.parse(outputText));
      } catch {
        return json({ error: 'OpenAI returned non-JSON output.', output_text: outputText }, 502);
      }
    }

    return json({ text: outputText, output_text: outputText });
  } catch (error) {
    if (error instanceof Response) return error;
    return json({ error: error.message || 'invoke-llm failed.' }, 500);
  }
});
