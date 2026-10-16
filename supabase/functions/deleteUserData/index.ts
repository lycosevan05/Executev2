import Stripe from 'npm:stripe@14.21.0';
import { handleCors, json } from '../_shared/cors.ts';
import { createServiceClient, ENTITY_TABLES, findRecords, getUser } from '../_shared/records.ts';

/**
 * Cancel any live Stripe subscription BEFORE deleting the user's rows.
 * Otherwise the user "deletes their account" and keeps getting billed —
 * and once the user_subscriptions row is gone, stripeCreatePortal can no
 * longer even open the cancel portal. Throws on a real Stripe failure so
 * the rows are NOT deleted (deletion can be retried); "already gone"
 * errors are swallowed. App Store subscriptions cannot be cancelled
 * server-side — the client shows a "cancel via App Store" note.
 */
async function cancelStripeSubscriptions(service: ReturnType<typeof createServiceClient>, email: string) {
  const rows = await findRecords(service, 'user_subscriptions', { user_id: email }, { limit: 10 });
  const subIds = [...new Set(
    rows
      .map((row) => String((row as Record<string, unknown>).stripe_subscription_id || ''))
      .filter(Boolean),
  )];
  if (subIds.length === 0) return;

  const secretKey = Deno.env.get('STRIPE_SECRET_KEY');
  if (!secretKey) {
    throw new Error('Account has a Stripe subscription but STRIPE_SECRET_KEY is not configured; refusing to delete billing records.');
  }
  const stripe = new Stripe(secretKey, { apiVersion: '2024-04-10' });

  for (const subId of subIds) {
    try {
      await stripe.subscriptions.cancel(subId);
    } catch (err) {
      const code = (err as { code?: string })?.code || '';
      const message = (err as Error)?.message || '';
      // Already canceled / no longer exists — safe to proceed with deletion.
      if (code === 'resource_missing' || /canceled subscription/i.test(message)) continue;
      throw new Error(`Could not cancel Stripe subscription ${subId}: ${message}`);
    }
  }
}

async function deleteUserUploads(service: ReturnType<typeof createServiceClient>, userId: string) {
  const bucket = Deno.env.get('SUPABASE_UPLOAD_BUCKET') || 'uploads';
  let deleted = 0;

  while (true) {
    const { data, error } = await service.storage.from(bucket).list(userId, { limit: 100, offset: 0 });
    if (error) {
      if (/bucket not found/i.test(error.message || '')) return { bucket, deleted };
      throw new Error(`Could not list uploaded files: ${error.message}`);
    }

    const paths = (data || [])
      .filter((entry) => entry.name && entry.name !== '.emptyFolderPlaceholder')
      .map((entry) => `${userId}/${entry.name}`);
    if (paths.length === 0) return { bucket, deleted };

    const { error: removeError } = await service.storage.from(bucket).remove(paths);
    if (removeError) throw new Error(`Could not delete uploaded files: ${removeError.message}`);
    deleted += paths.length;
  }
}

Deno.serve(async (req) => {
  const cors = handleCors(req);
  if (cors) return cors;

  try {
    const user = await getUser(req);
    const service = createServiceClient();
    const results: Record<string, string> = {};

    if (user.email) {
      await cancelStripeSubscriptions(service, user.email);
    }

    const uploads = await deleteUserUploads(service, user.id);
    results.storage = `deleted ${uploads.deleted} from ${uploads.bucket}`;

    for (const table of ENTITY_TABLES) {
      const byOwner = await service
        .from(table)
        .delete({ count: 'exact' })
        .eq('owner_id', user.id);

      if (byOwner.error) {
        results[table] = `error: ${byOwner.error.message}`;
        continue;
      }

      const byEmail = await service
        .from(table)
        .delete({ count: 'exact' })
        .or(`owner_email.eq.${user.email},created_by.eq.${user.email},user_email.eq.${user.email}`);

      if (byEmail.error) {
        results[table] = `error: ${byEmail.error.message}`;
        continue;
      }

      results[table] = `deleted ${(byOwner.count || 0) + (byEmail.count || 0)}`;
    }

    const failedTables = Object.entries(results)
      .filter(([, value]) => value.startsWith('error:'))
      .map(([table, value]) => `${table}: ${value.slice(7)}`);
    if (failedTables.length > 0) {
      throw new Error(`Account data could not be fully deleted (${failedTables.join('; ')}).`);
    }

    const { error: authError } = await service.auth.admin.deleteUser(user.id);
    if (authError) throw new Error(`Account data was deleted, but authentication removal failed: ${authError.message}`);
    results.authentication = 'deleted';

    return json({ success: true, results });
  } catch (error) {
    if (error instanceof Response) return error;
    return json({ error: error.message || 'deleteUserData failed.' }, 500);
  }
});
