// @ts-nocheck
import { createClient } from '@supabase/supabase-js';
import { getPlatform } from '@/lib/platform';

// Custom URL scheme registered in ios/App/App/Info.plist. Must also be
// allow-listed in Supabase Dashboard → Authentication → URL Configuration.
const IOS_OAUTH_REDIRECT = 'com.executelabs.execute://login-callback';

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL || '';
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY || '';
const uploadBucket = import.meta.env.VITE_SUPABASE_UPLOAD_BUCKET || 'uploads';

function getSupabaseConfigError() {
  if (!supabaseUrl || !supabaseAnonKey) {
    return 'Set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY.';
  }
  if (supabaseUrl.includes('supabase.com/dashboard')) {
    return 'VITE_SUPABASE_URL must be the project API URL, not the Supabase dashboard URL.';
  }
  try {
    const url = new URL(supabaseUrl);
    if (url.protocol !== 'https:' || !url.hostname.endsWith('.supabase.co')) {
      return 'VITE_SUPABASE_URL should look like https://your-project-ref.supabase.co.';
    }
  } catch {
    return 'VITE_SUPABASE_URL is not a valid URL.';
  }
  return '';
}

export const supabaseConfigError = getSupabaseConfigError();
export const isSupabaseConfigured = !supabaseConfigError;

export const supabase = isSupabaseConfigured
  ? createClient(supabaseUrl, supabaseAnonKey, {
      auth: {
        autoRefreshToken: true,
        detectSessionInUrl: true,
        persistSession: true,
      },
      realtime: {
        params: {
          eventsPerSecond: 10,
        },
      },
    })
  : null;

const TABLES = {
  AIPlan: 'ai_plans',
  CustomChecklistItem: 'custom_checklist_items',
  DailyLog: 'daily_logs',
  FoodLog: 'food_logs',
  Goal: 'goals',
  GoalProgressEntry: 'goal_progress_entries',
  InjuryProfile: 'injury_profiles',
  MealPlan: 'meal_plans',
  NutritionProfile: 'nutrition_profiles',
  ReadinessCheckIn: 'readiness_check_ins',
  SavedRecipe: 'saved_recipes',
  User: 'app_users',
  UserAIContext: 'user_ai_contexts',
  UserPageLayout: 'user_page_layouts',
  UserProfile: 'user_profiles',
  UserSubscription: 'user_subscriptions',
  WorkoutLog: 'workout_logs',
  WorkoutPlan: 'workout_plans',
  WorkoutProfile: 'workout_profiles',
};

const MAX_ROWS_PER_QUERY = 2000;

function requireSupabase() {
  if (!supabase) {
    throw new Error(supabaseConfigError || 'Supabase is not configured.');
  }
  return supabase;
}

function toBackendError(error, status = 500) {
  const next = new Error(error?.message || String(error || 'Unknown backend error'));
  next.status = error?.status || error?.code || status;
  next.data = error;
  return next;
}

function normalizeUser(user) {
  if (!user) return null;
  const metadata = user.user_metadata || {};
  return {
    ...metadata,
    id: user.id,
    email: user.email || '',
    full_name: metadata.full_name || metadata.name || user.email || '',
    role: metadata.role || 'user',
    created_date: user.created_at,
    updated_date: user.updated_at || user.last_sign_in_at,
  };
}

function flattenRecord(row) {
  if (!row) return row;
  const data = row.data && typeof row.data === 'object' ? row.data : {};
  return {
    ...data,
    id: row.id,
    created_by: row.created_by || data.created_by || row.owner_email || data.user_email || '',
    user_email: data.user_email || row.user_email || row.owner_email || '',
    created_date: row.created_date,
    updated_date: row.updated_date,
  };
}

function recordPayload(data = {}, user = null) {
  const now = new Date().toISOString();
  const email = user?.email || data.user_email || data.created_by || data.user_id || '';
  return {
    owner_id: user?.id || null,
    owner_email: email || null,
    created_by: data.created_by || email || null,
    user_email: data.user_email || email || null,
    data: {
      ...data,
      created_by: data.created_by || email || undefined,
      user_email: data.user_email || email || undefined,
    },
    created_date: data.created_date || now,
    updated_date: data.updated_date || now,
  };
}

function mergeUpdate(data = {}) {
  return {
    user_email: data.user_email || undefined,
    created_by: data.created_by || undefined,
    updated_date: new Date().toISOString(),
    data,
  };
}

function parseOrder(orderBy) {
  if (!orderBy || typeof orderBy !== 'string') {
    return { field: 'created_date', ascending: false };
  }
  const ascending = !orderBy.startsWith('-');
  const field = ascending ? orderBy : orderBy.slice(1);
  return { field, ascending };
}

function valueMatches(actual, expected) {
  if (expected === undefined) return true;
  if (expected === null) return actual === null || actual === undefined;
  if (Array.isArray(expected)) {
    return expected.some(item => valueMatches(actual, item));
  }
  return String(actual) === String(expected);
}

function matchesCriteria(record, criteria = {}) {
  return Object.entries(criteria || {}).every(([key, expected]) => valueMatches(record?.[key], expected));
}

function sortRecords(records, orderBy) {
  const { field, ascending } = parseOrder(orderBy);
  const direction = ascending ? 1 : -1;
  return [...records].sort((a, b) => {
    const av = a?.[field] ?? '';
    const bv = b?.[field] ?? '';
    if (av === bv) return 0;
    return String(av).localeCompare(String(bv), undefined, { numeric: true }) * direction;
  });
}

function applyLimit(records, limit) {
  const parsedLimit = Number(limit);
  if (!Number.isFinite(parsedLimit) || parsedLimit <= 0) return records;
  return records.slice(0, parsedLimit);
}

function jsonPath(column) {
  return `data->>${column}`;
}

function canServerFilter(key, value) {
  return value !== undefined && value !== null && !Array.isArray(value) && typeof value !== 'object';
}

async function currentSupabaseUser() {
  const client = requireSupabase();
  const { data, error } = await client.auth.getUser();
  if (error) throw toBackendError(error, 401);
  return data?.user || null;
}

class EntityClient {
  constructor(name, table) {
    this.name = name;
    this.table = table;
  }

  async _select(criteria = {}) {
    const client = requireSupabase();
    let query = client.from(this.table).select('*').limit(MAX_ROWS_PER_QUERY);

    for (const [key, value] of Object.entries(criteria || {})) {
      if (!canServerFilter(key, value)) continue;
      if (key === 'id') {
        query = query.eq('id', value);
      } else if (key === 'created_by' || key === 'user_email') {
        query = query.eq(key, value);
      } else {
        query = query.eq(jsonPath(key), String(value));
      }
    }

    const { data, error } = await query;
    if (error) {
      const fallback = await client.from(this.table).select('*').limit(MAX_ROWS_PER_QUERY);
      if (fallback.error) throw toBackendError(error);
      return (fallback.data || []).map(flattenRecord);
    }
    return (data || []).map(flattenRecord);
  }

  async list(orderBy = '-created_date', limit = 100) {
    const records = await this._select();
    return applyLimit(sortRecords(records, orderBy), limit);
  }

  async filter(criteria = {}, orderBy = null, limit = 100) {
    const records = await this._select(criteria);
    const filtered = records.filter(record => matchesCriteria(record, criteria));
    return applyLimit(sortRecords(filtered, orderBy), limit);
  }

  async create(data = {}) {
    const client = requireSupabase();
    const user = await currentSupabaseUser().catch(() => null);
    const payload = recordPayload(data, user);
    const { data: inserted, error } = await client
      .from(this.table)
      .insert(payload)
      .select('*')
      .single();
    if (error) throw toBackendError(error);
    return flattenRecord(inserted);
  }

  async update(id, updates = {}) {
    const client = requireSupabase();
    const existing = await this.filter({ id }, null, 1);
    const nextData = { ...(existing?.[0] || {}), ...updates };
    delete nextData.id;
    delete nextData.created_date;
    delete nextData.updated_date;

    const { data, error } = await client
      .from(this.table)
      .update(mergeUpdate(nextData))
      .eq('id', id)
      .select('*')
      .single();
    if (error) throw toBackendError(error);
    return flattenRecord(data);
  }

  async delete(id) {
    const client = requireSupabase();
    const { error } = await client.from(this.table).delete().eq('id', id);
    if (error) throw toBackendError(error);
    return { id };
  }

  subscribe(callback) {
    const client = requireSupabase();
    const channelName = `${this.table}:${globalThis.crypto?.randomUUID?.() || Date.now()}`;
    const channel = client
      .channel(channelName)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: this.table },
        payload => {
          const eventType = payload.eventType === 'INSERT'
            ? 'create'
            : payload.eventType === 'UPDATE'
              ? 'update'
              : 'delete';
          callback({
            type: eventType,
            data: flattenRecord(payload.new || payload.old),
            raw: payload,
          });
        }
      )
      .subscribe();

    return () => {
      client.removeChannel(channel);
    };
  }
}

const entities = Object.fromEntries(
  Object.entries(TABLES).map(([name, table]) => [name, new EntityClient(name, table)])
);

async function invokeFunction(name, body = {}) {
  const client = requireSupabase();
  const { data, error } = await client.functions.invoke(name, { body });
  if (error) throw toBackendError(error, error?.context?.status || 500);
  if (data?.error) throw toBackendError(data, 500);
  return data;
}

export const backend = {
  auth: {
    async me() {
      const user = await currentSupabaseUser();
      if (!user) throw toBackendError({ message: 'Authentication required', status: 401 }, 401);
      return normalizeUser(user);
    },
    async loginWithOtp(email, redirectTo = window.location.href) {
      const client = requireSupabase();
      const { error } = await client.auth.signInWithOtp({
        email,
        options: { emailRedirectTo: redirectTo },
      });
      if (error?.message === 'Failed to fetch') {
        throw toBackendError({
          message: 'Could not reach Supabase Auth. Check that VITE_SUPABASE_URL is the project API URL and restart npm run dev.',
          cause: error,
        }, 400);
      }
      if (error) throw toBackendError(error, 400);
      return { ok: true };
    },
    async loginWithOAuth(provider, redirectTo) {
      const client = requireSupabase();
      const isIOS = getPlatform() === 'ios';

      if (isIOS) {
        // On iOS we can't let Supabase navigate window.location to a Google
        // URL — that lands in Safari with no way back into the app. Instead
        // we ask Supabase to build the URL, open it in an in-app browser,
        // and rely on the appUrlOpen deep-link listener (AuthContext) to
        // catch the callback and exchange the code for a session.
        const { data, error } = await client.auth.signInWithOAuth({
          provider,
          options: {
            redirectTo: IOS_OAUTH_REDIRECT,
            skipBrowserRedirect: true,
          },
        });
        if (error) throw toBackendError(error, 400);
        if (!data?.url) throw toBackendError({ message: 'No OAuth URL returned by Supabase.' }, 500);
        const { Browser } = await import('@capacitor/browser');
        await Browser.open({ url: data.url, presentationStyle: 'popover' });
        return { ok: true };
      }

      const { error } = await client.auth.signInWithOAuth({
        provider,
        options: { redirectTo: redirectTo || window.location.origin },
      });
      if (error) throw toBackendError(error, 400);
      return { ok: true };
    },
    async logout(redirectTo) {
      const client = requireSupabase();
      await client.auth.signOut();
      if (redirectTo && typeof window !== 'undefined') {
        window.location.href = redirectTo === true ? '/' : redirectTo;
      }
    },
    redirectToLogin() {
      window.dispatchEvent(new CustomEvent('execute:show-login'));
    },
    async updateMe(data = {}) {
      const client = requireSupabase();
      const { data: result, error } = await client.auth.updateUser({ data });
      if (error) throw toBackendError(error, 400);
      return normalizeUser(result?.user);
    },
  },
  entities,
  functions: {
    invoke: invokeFunction,
  },
  integrations: {
    Core: {
      async InvokeLLM(payload = {}) {
        return invokeFunction('invoke-llm', payload);
      },
      async UploadFile(options = {}) {
        const { file, bucket = uploadBucket, path } = options;
        if (!file) throw new Error('UploadFile requires a file.');
        const client = requireSupabase();
        const user = await currentSupabaseUser();
        const safeName = file.name?.replace(/[^a-zA-Z0-9._-]/g, '_') || 'upload';
        const objectPath = path || `${user.id}/${globalThis.crypto?.randomUUID?.() || Date.now()}-${safeName}`;
        const { error } = await client.storage
          .from(bucket)
          .upload(objectPath, file, {
            contentType: file.type || 'application/octet-stream',
            upsert: false,
          });
        if (error) throw toBackendError(error, 400);

        const publicUrl = client.storage.from(bucket).getPublicUrl(objectPath)?.data?.publicUrl;
        return {
          file_url: publicUrl,
          path: objectPath,
          bucket,
        };
      },
    },
  },
  analytics: {
    track(..._args) {},
  },
  supabase,
};
