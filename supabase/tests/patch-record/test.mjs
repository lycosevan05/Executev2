const { PGlite } = await import(process.env.PGLITE_MODULE_PATH ?? '@electric-sql/pglite');
const repo = new URL('../../../', import.meta.url);
import { readFile, writeFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
const db = new PGlite();
const A='11111111-1111-1111-1111-111111111111', B='22222222-2222-2222-2222-222222222222';
const own='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', other='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role BYPASSRLS;
CREATE SCHEMA auth; GRANT USAGE ON SCHEMA public,auth TO anon,authenticated,service_role;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid PRIMARY KEY,owner_id uuid NOT NULL,owner_email text,user_email text,created_by text,data jsonb NOT NULL DEFAULT '{}',created_date timestamptz DEFAULT now(),updated_date timestamptz DEFAULT '2020-01-01');
CREATE TABLE public.readiness_check_ins(LIKE public.user_profiles INCLUDING ALL);
CREATE TABLE public.user_subscriptions(LIKE public.user_profiles INCLUDING ALL);
ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.readiness_check_ins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_subscriptions ENABLE ROW LEVEL SECURITY;
CREATE POLICY own_row ON public.user_profiles TO authenticated USING(owner_id=auth.uid()) WITH CHECK(owner_id=auth.uid());
CREATE POLICY own_row ON public.readiness_check_ins TO authenticated USING(owner_id=auth.uid()) WITH CHECK(owner_id=auth.uid());
CREATE POLICY own_row ON public.user_subscriptions TO authenticated USING(owner_id=auth.uid()) WITH CHECK(owner_id=auth.uid());
GRANT SELECT,INSERT,UPDATE ON public.user_profiles,public.readiness_check_ins,public.user_subscriptions TO authenticated,service_role;
INSERT INTO public.user_profiles(id,owner_id,owner_email,user_email,created_by,data) VALUES
 ('${own}','${A}','qa-a@example.invalid','qa-a@example.invalid','qa-a@example.invalid','{"retained":true,"nested":{"old":1}}'),
 ('${other}','${B}','qa-b@example.invalid','qa-b@example.invalid','qa-b@example.invalid','{"private":"B"}');
INSERT INTO public.readiness_check_ins(id,owner_id,data) VALUES('${own}','${A}','{"energy":8}');
INSERT INTO public.user_subscriptions(id,owner_id,data) VALUES('${own}','${A}','{"plan":"free"}');
`);
// Also verify replacing the legacy helper removes its broader default/anon ACL.
await db.exec(await readFile(new URL('supabase/migrations/20260711000000_patch_record.sql', repo),'utf8'));
const migration = await readFile(new URL('supabase/migrations/20261109000000_patch_record_native_updates.sql', repo),'utf8');
await db.exec(migration);
const results=[];
async function test(name, fn) { await fn(); results.push({name,result:'pass'}); console.log('PASS',name); }
async function asRole(role, user, fn) {
 await db.exec(`SET ROLE ${role}; SELECT set_config('request.jwt.claim.sub','${user}',false);`);
 try { return await fn(); } finally { await db.exec('RESET ROLE'); }
}
async function patch(table,id,data) { return (await db.query('SELECT public.patch_record($1,$2,$3) AS result',[table,id,data === null ? null : JSON.stringify(data)])).rows; }
async function rejected(table,id,data,role='authenticated',code='22023') {
 let error;
 try { await asRole(role,A,()=>patch(table,id,data)); } catch(e) { error=e; }
 assert.equal(error?.code,code);
}
await test('security invoker and fixed search path',async()=>{
 const r=(await db.query("SELECT prosecdef,proconfig FROM pg_proc WHERE oid='public.patch_record(text,uuid,jsonb)'::regprocedure")).rows[0];
 assert.equal(r.prosecdef,false); assert.ok(r.proconfig.includes('search_path=pg_catalog'));
});
await test('authenticated own-row merge returns complete JSON envelope',async()=>{
 const r=await asRole('authenticated',A,()=>patch('user_profiles',own,{display_name:'QA'}));
 assert.equal(r.length,1); assert.equal(r[0].result.id,own); assert.equal(r[0].result.data.display_name,'QA'); assert.equal(r[0].result.data.retained,true);
});
await test('timestamp advances and creation timestamp remains intact',async()=>{
 const r=(await db.query('SELECT created_date,updated_date FROM public.user_profiles WHERE id=$1',[own])).rows[0];
 assert.ok(new Date(r.updated_date)>new Date('2020-01-01')); assert.ok(r.created_date);
});
await test('shallow nested replacement preserves unrelated top-level data',async()=>{
 const r=await asRole('authenticated',A,()=>patch('user_profiles',own,{nested:{new:2}}));
 assert.deepEqual(r[0].result.data.nested,{new:2}); assert.equal(r[0].result.data.display_name,'QA');
});
await test('separate atomic patches do not lose unrelated fields',async()=>{
 await asRole('authenticated',A,()=>Promise.all([patch('user_profiles',own,{left:1}),patch('user_profiles',own,{right:2})]));
 const r=(await db.query('SELECT data FROM public.user_profiles WHERE id=$1',[own])).rows[0].data;
 assert.equal(r.left,1); assert.equal(r.right,2);
});
await test('RLS prevents another account row from being patched or returned',async()=>{
 assert.equal((await asRole('authenticated',A,()=>patch('user_profiles',other,{private:'changed'}))).length,0);
 assert.equal((await db.query('SELECT data FROM public.user_profiles WHERE id=$1',[other])).rows[0].data.private,'B');
});
await test('ownership and legacy attribution columns cannot be reassigned',async()=>{
 const r=await asRole('authenticated',A,()=>patch('user_profiles',own,{owner_id:B,owner_email:'qa-b@example.invalid',user_email:'qa-b@example.invalid',created_by:'qa-b@example.invalid'}));
 assert.equal(r[0].result.owner_id,A); assert.equal(r[0].result.owner_email,'qa-a@example.invalid'); assert.equal(r[0].result.user_email,'qa-a@example.invalid'); assert.equal(r[0].result.created_by,'qa-a@example.invalid');
});
await test('anonymous execution denied even after legacy migration grant',async()=>{await rejected('user_profiles',own,{},'anon','42501');});
await test('provider subscription table denied even with permissive table policy',async()=>{
 await rejected('user_subscriptions',own,{plan:'premium'});
 assert.equal((await db.query('SELECT data FROM public.user_subscriptions WHERE id=$1',[own])).rows[0].data.plan,'free');
});
await test('injected table identifier rejected without executing SQL',async()=>{
 await rejected('user_profiles; DROP TABLE public.user_profiles; --',own,{});
 assert.equal((await db.query("SELECT to_regclass('public.user_profiles') IS NOT NULL AS ok")).rows[0].ok,true);
});
for(const [name,table,id,value] of [
 ['null table',null,own,{}],['null ID','user_profiles',null,{}],['SQL null patch','user_profiles',own,null],
 ['array patch','user_profiles',own,[]],['string patch','user_profiles',own,'bad'],['number patch','user_profiles',own,1]
]) await test(name+' rejected',()=>rejected(table,id,value));
await test('readiness guidance merge keeps the acknowledged check-in',async()=>{
 const r=await asRole('authenticated',A,()=>patch('readiness_check_ins',own,{guidance:{training_recommendation:'QA only'}}));
 assert.equal(r[0].result.data.energy,8); assert.equal(r[0].result.data.guidance.training_recommendation,'QA only');
 assert.equal((await db.query('SELECT count(*)::int AS n FROM public.readiness_check_ins')).rows[0].n,1);
});
await test('service role retains normal non-billing maintenance access',async()=>{
 assert.equal((await asRole('service_role',A,()=>patch('user_profiles',other,{maintenance:true}))).length,1);
});
await test('missing record never creates a new row',async()=>{
 assert.equal((await asRole('authenticated',A,()=>patch('user_profiles','cccccccc-cccc-cccc-cccc-cccccccccccc',{}))).length,0);
 assert.equal((await db.query('SELECT count(*)::int AS n FROM public.user_profiles')).rows[0].n,2);
});
await test('rollback drops only helper and preserves entity records/RLS',async()=>{
 await db.exec('DROP FUNCTION public.patch_record(text,uuid,jsonb)');
 assert.equal((await db.query("SELECT to_regprocedure('public.patch_record(text,uuid,jsonb)') IS NULL AS gone")).rows[0].gone,true);
 assert.equal((await db.query('SELECT count(*)::int AS n FROM public.user_profiles')).rows[0].n,2);
 assert.equal((await db.query("SELECT relrowsecurity FROM pg_class WHERE oid='public.user_profiles'::regclass")).rows[0].relrowsecurity,true);
});
await writeFile(process.env.PATCH_RECORD_RESULTS_PATH ?? new URL('results.json', import.meta.url),JSON.stringify({scope:'local PGlite PostgreSQL/RLS fixtures, not remote deployment acceptance',passed:results.length,results},null,2)+'\n');
console.log('SUMMARY',results.length,'PostgreSQL/RLS groups passed');
await db.close();
