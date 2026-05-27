import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders } from './cors.ts';

export const ENTITY_TABLES = [
  'ai_plans',
  'custom_checklist_items',
  'daily_logs',
  'food_logs',
  'goals',
  'goal_progress_entries',
  'injury_profiles',
  'meal_plans',
  'nutrition_profiles',
  'readiness_check_ins',
  'saved_recipes',
  'app_users',
  'user_ai_contexts',
  'user_page_layouts',
  'user_profiles',
  'user_subscriptions',
  'workout_logs',
  'workout_plans',
  'workout_profiles',
];

function env(name: string) {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`${name} is not configured.`);
  return value;
}

function envAny(names: string[]) {
  for (const name of names) {
    const value = Deno.env.get(name);
    if (value) return value;
  }
  throw new Error(`${names[0]} is not configured.`);
}

export function createUserClient(req: Request) {
  return createClient(env('SUPABASE_URL'), env('SUPABASE_ANON_KEY'), {
    global: {
      headers: {
        Authorization: req.headers.get('Authorization') || '',
      },
    },
  });
}

export function createServiceClient() {
  return createClient(env('SUPABASE_URL'), envAny(['SERVICE_ROLE_KEY', 'SUPABASE_SERVICE_ROLE_KEY']));
}

export async function getUser(req: Request) {
  const client = createUserClient(req);
  const { data, error } = await client.auth.getUser();
  if (error || !data?.user) {
    throw new Response(JSON.stringify({ error: 'Unauthorized' }), {
      status: 401,
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json',
      },
    });
  }
  return data.user;
}

export function flattenRecord(row: Record<string, unknown> | null) {
  if (!row) return null;
  const data = row.data && typeof row.data === 'object' ? row.data as Record<string, unknown> : {};
  return {
    ...data,
    id: row.id,
    created_by: row.created_by || data.created_by || row.owner_email || data.user_email || '',
    user_email: data.user_email || row.user_email || row.owner_email || '',
    created_date: row.created_date,
    updated_date: row.updated_date,
  };
}

function dataPath(key: string) {
  return `data->>${key}`;
}

export async function findRecords(
  client: ReturnType<typeof createClient>,
  table: string,
  criteria: Record<string, unknown>,
  options: { limit?: number; orderBy?: string; ascending?: boolean } = {},
) {
  let query = client.from(table).select('*');

  for (const [key, value] of Object.entries(criteria)) {
    if (value === undefined || value === null || Array.isArray(value) || typeof value === 'object') continue;
    if (key === 'id' || key === 'created_by' || key === 'user_email' || key === 'owner_email') {
      query = query.eq(key, value);
    } else {
      query = query.eq(dataPath(key), String(value));
    }
  }

  query = query.order(options.orderBy || 'updated_date', { ascending: options.ascending ?? false });
  if (options.limit) query = query.limit(options.limit);

  const { data, error } = await query;
  if (error) throw error;
  return (data || []).map(flattenRecord).filter(Boolean);
}

export async function createRecord(
  client: ReturnType<typeof createClient>,
  table: string,
  data: Record<string, unknown>,
  ownerEmail: string,
  ownerId?: string,
) {
  const now = new Date().toISOString();
  const payload = {
    owner_id: ownerId || null,
    owner_email: ownerEmail,
    created_by: String(data.created_by || ownerEmail),
    user_email: String(data.user_email || ownerEmail),
    data: {
      ...data,
      created_by: data.created_by || ownerEmail,
      user_email: data.user_email || ownerEmail,
    },
    created_date: data.created_date || now,
    updated_date: data.updated_date || now,
  };

  const { data: inserted, error } = await client.from(table).insert(payload).select('*').single();
  if (error) throw error;
  return flattenRecord(inserted);
}

export async function updateRecord(
  client: ReturnType<typeof createClient>,
  table: string,
  id: string,
  data: Record<string, unknown>,
) {
  const { data: updated, error } = await client
    .from(table)
    .update({
      created_by: data.created_by,
      user_email: data.user_email,
      data,
      updated_date: new Date().toISOString(),
    })
    .eq('id', id)
    .select('*')
    .single();

  if (error) throw error;
  return flattenRecord(updated);
}

export async function upsertRecordBy(
  client: ReturnType<typeof createClient>,
  table: string,
  criteria: Record<string, unknown>,
  data: Record<string, unknown>,
  ownerEmail: string,
) {
  const existing = await findRecords(client, table, criteria, { limit: 1 });
  if (existing[0]?.id) {
    return updateRecord(client, table, String(existing[0].id), { ...existing[0], ...data });
  }
  return createRecord(client, table, data, ownerEmail);
}
