// Run from repository root: node ios-native/scripts/generate-recovery-readiness-cases.cjs
// Synthetic, fixed-clock expectations executed directly from the read-only behavioral reference.
const fs = require('fs');
const vm = require('vm');
let source = fs.readFileSync('src/lib/readinessScore.js', 'utf8')
  .replace(/^import .*;$/gm, '').replace(/export /g, '');
const output = [];
const clocks = ['2026-11-01T01:30:00Z', '2026-10-31T05:00:00Z', '2026-10-31T06:59:00Z',
  '2026-10-31T07:00:00Z', '2026-10-31T09:59:00Z', '2026-10-31T10:00:00Z',
  '2026-10-31T14:00:00Z', '2026-10-31T14:01:00Z', '2026-10-31T18:00:00Z',
  '2026-10-31T18:01:00Z', '2026-10-31T21:00:00Z', '2026-10-31T21:01:00Z', '2026-10-31T23:30:00Z'];
const signals = [
 {},
 {checkIn:{energy:7,soreness:3,sleep:7,stress:3,motivation:7}},
 ...[0, 4, 5, 6, 7, 8, 10].map(sleep => ({dailyLog:{sleep_hours:sleep}})),
 ...[0, 1, 2499, 2500, 5000, 7500, 10000].map(steps => ({dailyLog:{steps}})),
 ...[900, 1000, 1399, 1400, 1700, 2300, 2600, 3001].map(calories => ({dailyLog:{calories_consumed:calories,protein_consumed_g:100},nutritionProfile:{protein_target_g:150}})),
 ...['Energized','Good','Tired','Drained','Sore','Pain or discomfort'].map(feeling => ({dailyLog:{workout_done:true},workoutLog:{post_workout_feeling:feeling,session_rpe:9,pain_flag:'Yes, concerning'}})),
 {dailyLog:{calories_consumed:2100,protein_consumed_g:150},activePlan:{plan_payload:{nutrition_targets:{calories:2100,protein_g:150}}}},
 {dailyLog:{steps:5000,calories_consumed:1800},userProfile:{step_goal_daily:5000,calorie_goal:1800}},
];
for (const zone of ['UTC', 'America/Vancouver']) {
 process.env.TZ = zone;
 for (let i=0; i<signals.length; i++) {
  const now = clocks[i % clocks.length];
  class FixedDate extends Date { constructor(...args) { super(...(args.length ? args : [now])); } }
  const sandbox = {Date:FixedDate};
  vm.createContext(sandbox); vm.runInContext(source, sandbox);
  const inputs = signals[i];
  const result = sandbox.computeDynamicReadiness(inputs);
  output.push({now,zone,inputs,result,drivers:sandbox.getReadinessDrivers(result.breakdown,inputs.dailyLog,inputs.workoutLog)});
 }
 for (const now of clocks) {
  class FixedDate extends Date { constructor(...args) { super(...(args.length ? args : [now])); } }
  const sandbox={Date:FixedDate}; vm.createContext(sandbox); vm.runInContext(source,sandbox);
  const inputs={dailyLog:{sleep_hours:8}};
  const result=sandbox.computeDynamicReadiness(inputs);
  output.push({now,zone,inputs,result,drivers:sandbox.getReadinessDrivers(result.breakdown,inputs.dailyLog,null)});
 }
}
// Exercise the real Recovery.jsx selectors, including legacy source masking and
// cross-row precedence. Keep these in the existing test resource.
const recovery = fs.readFileSync('src/pages/Recovery.jsx', 'utf8');
const selectors = recovery.slice(recovery.indexOf('function sameValue('), recovery.indexOf('async function loadLinkedDailyLogForDate('));
const sandbox = {backend:{entities:{AIPlan:{filter:async () => sandbox.plans}}}};
vm.createContext(sandbox); vm.runInContext(selectors, sandbox);
const overview = 'plan_questionnaire_overview', initial = 'plan_questionnaire_initial';
const id = n => `00000000-0000-0000-0000-${String(n).padStart(12, '0')}`;
const row = (n, data) => ({id:id(n), generated_at:`2026-10-${String(30-n).padStart(2, '0')}T12:00:00Z`, ...data});
const kinds = [{source:overview},{source:'legacy',plan_payload:{source:overview}},
               {source:initial},{source:'legacy',plan_payload:{source:initial}}];
const scenarios = [];
for (const left of kinds) for (const right of kinds) scenarios.push({rows:[row(1,left),row(2,right)]});
for (const legacy of ['legacy', '', initial]) {
 scenarios.push({rows:[row(1,{source:'manual'}),row(2,{source:legacy,plan_payload:{source:overview}})]});
}
scenarios.push({rows:[]}, {rows:[row(1,{source:'manual'}),row(2,{source:'legacy'})]});
const plan = {id:id(9),generation_batch_id:'batch'};
scenarios.push({plan,rows:[row(1,{source:overview}),row(2,{source_plan_id:id(9),generation_batch_id:'old'}),row(3,{source_plan_id:id(9),generation_batch_id:'batch'})]},
 {plan,rows:[row(1,{source:overview}),row(2,{source_plan_id:id(9)})]});
(async () => {
 for (const item of scenarios) {
  sandbox.plans = item.rows;
  output.push({kind:'selection', ...item,
    expectedPlanID:(await sandbox.loadActiveCanonicalMasterPlan())?.id ?? null,
    expectedDailyID:sandbox.chooseBestLinkedRecord(item.rows,item.plan)?.id ?? null});
 }
 const path = 'ios-native/ExecuteNativeTests/RecoveryReadinessCases.json';
 const generated = JSON.stringify(output,null,2)+'\n';
 if (process.argv.includes('--check')) {
  require('node:assert/strict').equal(fs.readFileSync(path,'utf8'),generated,'Saved fixtures differ from web reference');
 } else { fs.writeFileSync(path,generated); }
 console.log(`90 readiness + ${scenarios.length} selection fixtures ${process.argv.includes('--check') ? 'verified' : 'generated'} from the web reference (not native test execution)`);
})().catch(error => {console.error(error);process.exitCode=1;});
