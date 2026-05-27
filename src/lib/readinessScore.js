/**
 * Dynamic Readiness Score Engine
 *
 * Base score from morning check-in, then adjusted throughout the day by:
 * - Workout completion + post-workout feeling/RPE
 * - Sleep hours logged
 * - Steps completed vs. goal
 * - Nutrition quality (calories vs. goal, protein hit)
 *
 * Final score is 0–100.
 */

import { backend } from '@/api/backendClient';
import { upsertReadinessCheckIn, getTodayISODate } from '@/lib/personalizationSync';

/**
 * Score nutrition quality: 0–20 points
 * - Good: hitting calorie target ±15% → +12–20
 * - Good: hitting protein target (≥80%) → +5–8
 * - Poor: way over or way under calories → deduction
 * - Missing data → neutral (10)
 */
function scoreNutrition({ caloriesConsumed, calorieGoal, proteinConsumed, proteinGoal }) {
  if (!caloriesConsumed || !calorieGoal) return 10; // neutral if no data

  const calRatio = caloriesConsumed / calorieGoal;
  let calScore = 10;

  if (calRatio >= 0.85 && calRatio <= 1.15) {
    calScore = 14; // on target
  } else if (calRatio >= 0.70 && calRatio <= 1.30) {
    calScore = 11; // slightly off
  } else if (calRatio < 0.50) {
    calScore = 4; // severe under-eating hurts recovery
  } else if (calRatio > 1.50) {
    calScore = 6; // large overage hurts readiness (sluggish)
  } else {
    calScore = 8;
  }

  // Protein bonus
  let proteinBonus = 0;
  if (proteinConsumed && proteinGoal) {
    const proteinRatio = proteinConsumed / proteinGoal;
    if (proteinRatio >= 0.9) proteinBonus = 6;
    else if (proteinRatio >= 0.7) proteinBonus = 3;
    else if (proteinRatio < 0.4) proteinBonus = -2; // low protein = poor recovery
  }

  return Math.min(20, Math.max(0, calScore + proteinBonus));
}

/**
 * Score sleep hours: 0–20 points
 * Optimal 7–9 hrs = 20 pts, falls off sharply below 6
 */
function scoreSleep(sleepHours) {
  if (!sleepHours || sleepHours <= 0) return 10; // neutral if no data
  if (sleepHours >= 8) return 20;
  if (sleepHours >= 7) return 18;
  if (sleepHours >= 6) return 13;
  if (sleepHours >= 5) return 7;
  return 3; // very poor sleep
}

/**
 * Score time-of-day / hours-awake adjustment: -10 to +5 points
 *
 * Peak human performance window is roughly 10am–2pm (2–6h after waking).
 * Early morning (<6am) and late night (>10pm) = reduced readiness.
 * Long hours awake (>14h) = progressive fatigue penalty.
 *
 * @param sleepHours  - hours slept last night (0 if unknown)
 * @returns { points, hoursAwake, timeOfDayLabel }
 */
function scoreTimeOfDay(sleepHours) {
  const now = new Date();
  const hourOfDay = now.getHours() + now.getMinutes() / 60; // 0–24 float

  // Estimate hours awake: assume wake time = ~7am if no sleep data, else midnight - sleepHours
  // Simple heuristic: woke up = current time minus hours awake
  // We estimate wake time as midnight of today + (24 - sleepHours) — capped sensibly
  let estimatedWakeHour = 7; // default 7am
  if (sleepHours && sleepHours > 0) {
    // If they logged 8h sleep and it's currently 3pm (hour 15), they likely woke ~7am
    // Use current hour minus hours awake is rough; default to 24 - sleepHours as bedtime,
    // so wake = bedtime + sleepHours. Simplest: just assume they woke (24-sleepHours) hours
    // before midnight, meaning wake = 24 - sleepHours if bedtime was midnight — clamp 5–9am.
    estimatedWakeHour = Math.min(9, Math.max(5, 24 - sleepHours));
  }

  const hoursAwake = Math.max(0, hourOfDay - estimatedWakeHour);

  // Time-of-day score: bell curve peaking ~10am–2pm
  let timePoints = 0;
  if (hourOfDay >= 10 && hourOfDay <= 14) {
    timePoints = 5; // peak performance window
  } else if (hourOfDay >= 7 && hourOfDay < 10) {
    timePoints = 3; // morning ramp-up
  } else if (hourOfDay > 14 && hourOfDay <= 18) {
    timePoints = 4; // afternoon is still good
  } else if (hourOfDay > 18 && hourOfDay <= 21) {
    timePoints = 1; // evening wind-down
  } else if (hourOfDay > 21 || hourOfDay < 5) {
    timePoints = -5; // late night / very early
  } else {
    timePoints = 0; // 5am–7am, just woke
  }

  // Hours-awake fatigue penalty: after 12h awake, progressive deduction
  let awakePenalty = 0;
  if (hoursAwake >= 16) awakePenalty = -10;
  else if (hoursAwake >= 14) awakePenalty = -6;
  else if (hoursAwake >= 12) awakePenalty = -3;

  const points = Math.max(-10, Math.min(5, timePoints + awakePenalty));

  const timeOfDayLabel =
    hourOfDay >= 10 && hourOfDay <= 14 ? 'Peak window' :
    hourOfDay >= 7 && hourOfDay < 10 ? 'Morning warm-up' :
    hourOfDay > 14 && hourOfDay <= 18 ? 'Afternoon' :
    hourOfDay > 18 && hourOfDay <= 21 ? 'Evening wind-down' :
    'Off-hours';

  return { points, hoursAwake: Math.round(hoursAwake * 10) / 10, timeOfDayLabel };
}

/**
 * Score steps: 0–10 points
 * Hitting step goal = full 10, below = proportional
 */
function scoreSteps(steps, stepGoal = 10000) {
  if (!steps || !stepGoal) return 5; // neutral
  const ratio = steps / stepGoal;
  if (ratio >= 1.0) return 10;
  if (ratio >= 0.75) return 8;
  if (ratio >= 0.5) return 6;
  if (ratio >= 0.25) return 4;
  return 2;
}

/**
 * Workout adjustment: -15 to +15 points
 * - Completing workout = base +10
 * - Post-workout feeling adjusts up/down
 * - High RPE (>8) = slight deduction (fatigue signal)
 * - Pain flag = deduction
 */
function scoreWorkout({ workoutDone, exertionLevel, feeling, rpe, painFlag }) {
  if (!workoutDone) return 0; // neutral if no workout done yet

  let adj = 10; // base for completing workout

  // Feeling modifier
  const feelingMap = {
    'Energized': 5,
    'Good': 3,
    'Tired': -2,
    'Drained': -6,
    'Sore': -3,
    'Pain or discomfort': -8,
  };
  if (feeling && feelingMap[feeling] !== undefined) {
    adj += feelingMap[feeling];
  }

  // RPE: very high effort signals accumulated fatigue
  if (rpe >= 9) adj -= 3;
  else if (rpe >= 8) adj -= 1;

  // Pain flag
  if (painFlag === 'Yes, concerning') adj -= 5;
  else if (painFlag === 'Yes, minor') adj -= 2;

  return Math.min(15, Math.max(-15, adj));
}

/**
 * Calculate the dynamic readiness score (0–100) from all available day data.
 *
 * Base: morning check-in score (50% weight, 0–50 range)
 * Dynamic adjustments (remaining 50):
 *   - Sleep: 0–20 pts
 *   - Nutrition: 0–20 pts
 *   - Steps: 0–10 pts
 *   - Workout feeling: -15 to +15 pts
 *
 * If no check-in data exists yet, estimate from daily log signals only.
 */
export function computeDynamicReadiness({
  checkIn,       // { energy, soreness, sleep, stress, motivation } — morning check-in values (1–10)
  dailyLog,      // DailyLog record for today
  workoutLog,    // WorkoutLog record (latest completed) for today
  userProfile,   // UserProfile for goals
  nutritionProfile, // NutritionProfile for macro targets
  activePlan,    // AIPlan for nutrition targets fallback
}) {
  // ── 1. Base score from morning check-in ────────────────────────────────────
  let baseScore = 50; // default if no check-in
  let hasCheckIn = false;

  if (checkIn && checkIn.energy) {
    const energy = checkIn.energy;
    const soreness = 11 - checkIn.soreness; // inverted
    const sleep = checkIn.sleep;
    const stress = 11 - checkIn.stress; // inverted
    const motivation = checkIn.motivation;
    const rawAvg = (energy + soreness + sleep + stress + motivation) / 5; // 1–10
    baseScore = Math.round(rawAvg * 5); // scale to 0–50
    hasCheckIn = true;
  }

  // ── 2. Sleep hours adjustment ───────────────────────────────────────────────
  const sleepHours = dailyLog?.sleep_hours || 0;
  const sleepPoints = scoreSleep(sleepHours); // 0–20

  // ── 3. Steps adjustment ────────────────────────────────────────────────────
  const steps = dailyLog?.steps || 0;
  const stepGoal = userProfile?.step_goal_daily || 10000;
  const stepPoints = scoreSteps(steps, stepGoal); // 0–10

  // ── 4. Nutrition adjustment ────────────────────────────────────────────────
  const caloriesConsumed = dailyLog?.calories_consumed || 0;
  const proteinConsumed = dailyLog?.protein_consumed_g || 0;

  // Resolve calorie + protein goals
  const nutritionTargets = activePlan?.nutrition_targets || activePlan?.plan_payload?.nutrition_targets || {};
  const calorieGoal =
    nutritionProfile?.calorie_target ||
    userProfile?.calorie_goal ||
    nutritionTargets?.calories ||
    2000;
  const proteinGoal =
    nutritionProfile?.protein_target_g ||
    nutritionTargets?.protein_g ||
    null;

  const nutritionPoints = scoreNutrition({
    caloriesConsumed,
    calorieGoal,
    proteinConsumed,
    proteinGoal,
  }); // 0–20

  // ── 5. Workout adjustment ──────────────────────────────────────────────────
  const workoutDone = dailyLog?.workout_done || false;
  const workoutAdj = scoreWorkout({
    workoutDone,
    exertionLevel: workoutLog?.exertion_level || '',
    feeling: workoutLog?.post_workout_feeling || '',
    rpe: workoutLog?.session_rpe || 0,
    painFlag: workoutLog?.pain_flag || '',
  }); // -15 to +15

  // ── 6. Time-of-day / hours-awake adjustment ────────────────────────────────
  const timeOfDay = scoreTimeOfDay(sleepHours); // -10 to +5

  // ── 7. Combine ──────────────────────────────────────────────────────────────
  // Dynamic portion: sleep + steps + nutrition + workout + time-of-day
  const dynamicTotal = sleepPoints + stepPoints + nutritionPoints + workoutAdj + timeOfDay.points;
  // Normalize: max dynamic possible = 20+10+20+15+5 = 70; scale to 50
  const dynamicScaled = Math.round((dynamicTotal / 70) * 50);

  let finalScore = baseScore + dynamicScaled;
  finalScore = Math.min(100, Math.max(5, finalScore));

  return {
    score: finalScore,
    breakdown: {
      baseFromCheckin: baseScore,
      sleepPoints,
      stepPoints,
      nutritionPoints,
      workoutAdj,
      timeOfDayPoints: timeOfDay.points,
      hoursAwake: timeOfDay.hoursAwake,
      timeOfDayLabel: timeOfDay.timeOfDayLabel,
      dynamicScaled,
    },
    hasCheckIn,
  };
}

/**
 * Load all data needed for today's dynamic readiness and compute the score.
 * Saves the updated score back to ReadinessCheckIn.
 * Returns { score, breakdown, hasCheckIn }
 */
export async function refreshDynamicReadiness(date) {
  const today = date || getTodayISODate();

  const [
    checkIns,
    dailyLogs,
    workoutLogs,
    userProfiles,
    nutritionProfiles,
    aiPlans,
  ] = await Promise.all([
    backend.entities.ReadinessCheckIn.filter({ date: today }).catch(() => []),
    backend.entities.DailyLog.filter({ date: today }).catch(() => []),
    backend.entities.WorkoutLog.filter({ date: today, status: 'completed' }).catch(() => []),
    backend.entities.UserProfile.list('-updated_date', 1).catch(() => []),
    backend.entities.NutritionProfile.list('-updated_date', 1).catch(() => []),
    backend.entities.AIPlan.filter({ plan_type: 'daily', status: 'active' }, '-generated_at', 1).catch(() => []),
  ]);

  const checkInRecord = checkIns[0] || null;
  const dailyLog = dailyLogs[0] || null;
  const workoutLog = workoutLogs.sort((a, b) => (b.completed_at || '').localeCompare(a.completed_at || ''))[0] || null;
  const userProfile = userProfiles[0] || null;
  const nutritionProfile = nutritionProfiles[0] || null;
  const activePlan = aiPlans[0] || null;

  // Map check-in record to the format computeDynamicReadiness expects
  const checkIn = checkInRecord ? {
    energy: checkInRecord.energy,
    soreness: checkInRecord.soreness,
    sleep: checkInRecord.sleep_quality,
    stress: checkInRecord.stress,
    motivation: checkInRecord.motivation,
  } : null;

  const result = computeDynamicReadiness({
    checkIn,
    dailyLog,
    workoutLog,
    userProfile,
    nutritionProfile,
    activePlan,
  });

  // Save updated score back to ReadinessCheckIn
  if (checkInRecord?.id) {
    await backend.entities.ReadinessCheckIn.update(checkInRecord.id, {
      readiness_score: result.score,
      energy: checkInRecord.energy,
    }).catch(() => {});
  } else if (result.score !== 50) {
    // Only create a stub record if we have meaningful dynamic data
    await upsertReadinessCheckIn(today, {
      readiness_score: result.score,
    }).catch(() => {});
  }

  return result;
}

/**
 * Get a human-readable label from the dynamic readiness score (0–100)
 */
export function getReadinessLabel(score) {
  if (score >= 80) return { label: 'High readiness — push today', color: '#8ea400', emoji: '💪' };
  if (score >= 65) return { label: 'Good readiness — train as planned', color: '#8ea400', emoji: '🙂' };
  if (score >= 45) return { label: 'Moderate — adjust intensity down', color: '#b05a3a', emoji: '😐' };
  return { label: 'Low readiness — rest or easy movement', color: '#b05a3a', emoji: '😴' };
}

/**
 * Returns a short explanation of what's driving the current score adjustment
 */
export function getReadinessDrivers(breakdown, dailyLog, workoutLog) {
  const drivers = [];

  if (breakdown.workoutAdj > 5) drivers.push('Workout completed — good recovery response');
  else if (breakdown.workoutAdj < -3) drivers.push('Post-workout fatigue detected');

  if (breakdown.sleepPoints >= 18) drivers.push('Good sleep last night');
  else if (breakdown.sleepPoints <= 7 && dailyLog?.sleep_hours > 0) drivers.push('Sleep was short — recovery affected');

  if (breakdown.nutritionPoints >= 16) drivers.push('Nutrition on point — fuelling recovery');
  else if (breakdown.nutritionPoints <= 6 && dailyLog?.calories_consumed > 0) drivers.push('Nutrition off target — readiness reduced');

  if (breakdown.stepPoints >= 8) drivers.push('Step goal nearly reached');

  if (breakdown.timeOfDayPoints !== undefined) {
    if (breakdown.timeOfDayLabel === 'Peak window') drivers.push('Peak performance window (10am–2pm)');
    else if (breakdown.timeOfDayPoints <= -5) drivers.push('Late night / early hours — readiness naturally lower');
    else if (breakdown.hoursAwake >= 14) drivers.push(`${breakdown.hoursAwake}h awake — fatigue building`);
  }

  return drivers;
}