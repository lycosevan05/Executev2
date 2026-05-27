import { handleCors, json } from '../_shared/cors.ts';
import { createServiceClient, ENTITY_TABLES, getUser } from '../_shared/records.ts';

Deno.serve(async (req) => {
  const cors = handleCors(req);
  if (cors) return cors;

  try {
    const user = await getUser(req);
    const service = createServiceClient();
    const results: Record<string, string> = {};

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

    return json({ success: true, results });
  } catch (error) {
    if (error instanceof Response) return error;
    return json({ error: error.message || 'deleteUserData failed.' }, 500);
  }
});
