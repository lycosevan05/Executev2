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
fs.writeFileSync('ios-native/ExecuteNativeTests/RecoveryReadinessCases.json',JSON.stringify(output,null,2)+'\n');
console.log(`${output.length} cases generated from src/lib/readinessScore.js`);
