import { handleCors, json } from '../_shared/cors.ts';
import { getUser } from '../_shared/records.ts';

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

    const openaiResponse = await fetch('https://api.openai.com/v1/responses', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(requestBody),
    });

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
