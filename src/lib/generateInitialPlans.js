/**
 * Legacy helper module.
 *
 * The old generateInitialPlans flow has been disabled.
 *
 * Current architecture:
 * Plan Questionnaire -> generateInitialPlanBundle -> master AIPlan -> linked projections.
 *
 * This file only preserves helper functions still imported by generateInitialPlanBundle:
 * - buildAnswerContext
 * - calcTDEE
 */

// Build a rich text summary of questionnaire answers for the AI.

const GOAL_LABELS = {
  lose_fat: 'Lose body fat',
  build_muscle: 'Build muscle',
  get_stronger: 'Get stronger',
  improve_fitness: 'Improve overall fitness',
  improve_flexibility: 'Improve flexibility & mobility',
  sport_specific: 'Sport-specific training & performance',
  feel_better: 'Feel more energetic & healthy',
};

const PLAN_TYPE_LABELS = {
  workout: 'Training plan only',
  nutrition: 'Nutrition plan only',
  daily_performance: 'Complete performance plan (training + nutrition + recovery)',
};

const OPTIMIZE_LABELS = {
  fastest: 'Fastest progress — push hard for results',
  consistent: 'Easiest consistency — habits the user can stick to',
  balanced: 'Balanced — progress without burning out',
  injury_safe: 'Injury-safe / low stress — protect the body first',
};

const CURRENT_TRAINING_LABELS = {
  never: 'Never / rarely (getting started or restarting)',
  '1_2_days': '1–2 days a week (some activity, inconsistent)',
  '3_4_days': '3–4 days a week (fairly consistent)',
  '5_plus': '5+ days a week (very active)',
};

const ACTIVITY_LABELS = {
  monthly: 'Mostly sedentary (desk job, minimal movement)',
  '2x_week': 'Lightly active (occasional walks, some activity)',
  '4x_week': 'Moderately active (active job or regular walks)',
  daily: 'Very active (trains 3+ times/week or active job)',
};

const DESIRED_ACTIVITY_LABELS = {
  light: 'Light: 1–2 workouts per week',
  moderate: 'Moderate: about 3 workouts per week',
  high: 'High: 4–5 workouts per week',
  full: 'Very high: 5–6 workouts per week',
};

const LOCATION_LABELS = {
  gym: 'Commercial gym',
  home: 'Home setup',
  outdoors: 'Outdoors (parks, trails)',
  mixed: 'Mixed locations',
};

const EQUIPMENT_LABELS = {
  full_gym: 'Full commercial gym',
  dumbbells: 'Dumbbells',
  barbell: 'Barbell',
  machines: 'Machines',
  cables: 'Cable machine',
  cable_machine: 'Cable machine',
  kettlebells: 'Kettlebells',
  free_weights: 'Free weights (dumbbells & kettlebells)',
  resistance_bands: 'Resistance bands',
  pullup_bar: 'Pull-up bar',
  cardio_machines: 'Cardio machines (bike / treadmill)',
  bodyweight_only: 'Bodyweight only',
  calisthenics: 'Calisthenics (bodyweight training)',
  sport_facility: 'Sport-specific facility (court, field, track, dojo, climbing gym, etc.)',
  home: 'Home gym',
};

const DAY_ORDER = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
const DAY_LABELS = { mon: 'Monday', tue: 'Tuesday', wed: 'Wednesday', thu: 'Thursday', fri: 'Friday', sat: 'Saturday', sun: 'Sunday' };
const SESSION_TYPE_LABELS = {
  solo: 'solo technical/skill (low-moderate load)',
  team: 'team practice (moderate-high load)',
  game: 'game/competition (highest load)',
};

function formatSportSchedule(schedule) {
  if (!schedule || typeof schedule !== 'object') return '  (no schedule provided)';
  const lines = DAY_ORDER.map(day => {
    const types = Array.isArray(schedule[day]) ? schedule[day] : [];
    if (types.length === 0) return `  • ${DAY_LABELS[day]}: nothing scheduled`;
    const labels = types.map(t => SESSION_TYPE_LABELS[t] || t).join(' + ');
    return `  • ${DAY_LABELS[day]}: ${labels}`;
  });
  return lines.join('\n');
}

const DIET_STYLE_LABELS = {
  keto: 'Keto',
  vegan: 'Vegan',
  vegetarian: 'Vegetarian',
  pescatarian: 'Pescatarian',
  paleo: 'Paleo',
  mediterranean: 'Mediterranean',
  gluten_free: 'Gluten-free',
  dairy_free: 'Dairy-free',
  high_protein: 'High-protein',
  intermittent_fasting: 'Intermittent fasting',
};

const SUPPLEMENT_CATEGORY_LABELS = {
  protein: 'Protein powders (whey, casein, plant, collagen)',
  performance: 'Performance & strength (creatine, beta-alanine, EAAs)',
  energy: 'Energy & focus (caffeine, NAD+, intra-workout carbs)',
  health: 'Health & recovery (omega-3, probiotics, joint support)',
  vitamins: 'Vitamins & minerals (multivitamin, vitamin D, magnesium, electrolytes)',
};

// answers.goal arrives as a comma-joined string of IDs (lose_fat, build_muscle…)
// OR — when the user picked "other" — as their free-text. Normalize both.
function formatGoals(goal) {
  if (!goal) return 'Not specified';
  return String(goal)
    .split(',')
    .map(s => s.trim())
    .filter(Boolean)
    .map(g => GOAL_LABELS[g] || g)
    .join(', ');
}

export function buildAnswerContext(answers = {}) {
  const goals = formatGoals(answers.goal);
  const equipment = (answers.equipment || [])
    .map(e => EQUIPMENT_LABELS[e] || e)
    .join(', ') || 'Not specified';
  const dietStyles = (answers.dietStyles || [])
    .map(d => DIET_STYLE_LABELS[d] || d)
    .join(', ') || 'No specific dietary style';

  const bmi = answers.weightKg && answers.heightCm
    ? (Number(answers.weightKg) / Math.pow(Number(answers.heightCm) / 100, 2)).toFixed(1)
    : null;

  const planType = PLAN_TYPE_LABELS[answers.planType] || answers.planType || 'Not specified';
  const optimize = OPTIMIZE_LABELS[answers.optimize] || answers.optimize || 'Balanced';

  const currentTraining = CURRENT_TRAINING_LABELS[answers.currentTraining]
    || ACTIVITY_LABELS[answers.currentActivity]
    || 'Not specified';
  const desiredActivity = DESIRED_ACTIVITY_LABELS[answers.desiredActivity] || answers.desiredActivity || 'Not specified';
  const trainingDays = answers.trainingDays ? `${answers.trainingDays} days per week` : 'Not specified';
  const sessionLength = answers.sessionDurationMin
    ? `${answers.sessionDurationMin} minutes per session`
    : (answers.sessionLength ? `${answers.sessionLength === 'best' ? 'Flexible — recommend best fit' : answers.sessionLength + ' minutes'}` : 'Not specified');
  const location = LOCATION_LABELS[answers.trainingLocation] || answers.trainingLocation || 'Not specified';

  return `
=== USER PROFILE ===
${answers.name ? `Name: ${answers.name}` : ''}
Plan type requested: ${planType}
Optimization priority: ${optimize}
Goals: ${goals}
Age: ${answers.age || 'Not specified'}
Sex: ${answers.sex || 'Not specified'}
Weight: ${answers.weightKg ? `${answers.weightKg} kg` : 'Not specified'}
Height: ${answers.heightCm ? `${answers.heightCm} cm` : 'Not specified'}
${bmi ? `BMI: ${bmi}` : ''}

=== TRAINING ===
Current training frequency: ${currentTraining}
Current exercise type: ${answers.activityDetail || 'Not specified'}
Desired training frequency: ${desiredActivity}
Target training days: ${trainingDays}
Target session length: ${sessionLength}
Training location: ${location}
Plan aggressiveness: ${answers.aggressiveness || 'balanced'}
Available equipment: ${equipment}
Primary sport: ${answers.primarySport?.trim() || 'None — general fitness'}
${answers.primarySport?.trim() && answers.primarySportSchedule ? `Primary sport WEEKLY SCHEDULE (fixed days the user already has booked):
${formatSportSchedule(answers.primarySportSchedule)}` : ''}
${answers.sportFocus?.trim() ? `Primary sport performance focus: ${answers.sportFocus.trim()}` : ''}
${answers.secondSport?.trim() ? `Second sport: ${answers.secondSport.trim()}` : ''}
${answers.secondSport?.trim() && answers.secondSportSchedule ? `Second sport WEEKLY SCHEDULE:
${formatSportSchedule(answers.secondSportSchedule)}` : ''}
${answers.secondSportFocus?.trim() ? `Second sport focus: ${answers.secondSportFocus.trim()}` : ''}
Physical limitations or injuries: ${answers.hasLimitations ? (answers.limitationsDetail || 'Has limitations, unspecified') : 'None'}

=== NUTRITION ===
Meals per day: ${answers.mealsPerDay || 'Not specified'}
Dietary style / preferences: ${dietStyles}
${answers.noFoodPreference ? 'Food preference: No preference — open to anything sensible' : `Preferred proteins: ${answers.favoriteProteins?.trim() || 'Not specified'}
Preferred carbs: ${answers.favoriteCarbs?.trim() || 'Not specified'}
Preferred fats: ${answers.favoriteFats?.trim() || 'Not specified'}`}
Aggregated preferred foods: ${(answers.selectedFoods || []).join(', ') || 'No specific preferences'}
Allergies: ${answers.allergies?.trim() || 'None reported'}
Foods to avoid / dislikes: ${answers.foodsToAvoid?.trim() || 'None'}
Nutrition struggles: ${(answers.struggles || []).join(', ') || 'None'}

=== SUPPLEMENTS ===
${answers.noSupplements
  ? 'User prefers food-only — do NOT recommend any supplements.'
  : (Array.isArray(answers.supplements) && answers.supplements.length > 0
      ? `Open to these categories: ${answers.supplements.map(s => SUPPLEMENT_CATEGORY_LABELS[s] || s).join('; ')}`
      : 'No specific supplement preferences stated')}
${answers.supplementsNotes?.trim() ? `Supplements to avoid / notes: ${answers.supplementsNotes.trim()}` : ''}

=== NOTES ===
${answers.additionalNotes?.trim() || 'None'}
`.trim();
}

// Calculate TDEE.
// Uses Mifflin-St Jeor BMR + an activity multiplier that prioritizes the user's
// CURRENT training frequency (truth) and uses desired/legacy fields as fallback.

export function calcTDEE(answers = {}) {
  const w = Number(answers.weightKg) || 80;
  const h = Number(answers.heightCm) || 175;
  const a = Number(answers.age) || 30;
  const isMale = answers.sex === 'male';

  const bmr = isMale
    ? 10 * w + 6.25 * h - 5 * a + 5
    : 10 * w + 6.25 * h - 5 * a - 161;

  // currentTraining (new questionnaire key) is the most accurate signal
  const currentTrainingMultiplier = {
    never: 1.25,
    '1_2_days': 1.4,
    '3_4_days': 1.55,
    '5_plus': 1.725,
  };
  const desiredActivityMultiplier = { light: 1.3, moderate: 1.45, high: 1.6, full: 1.75 };
  const currentActivityMultiplier = { monthly: 1.2, '2x_week': 1.375, '4x_week': 1.55, daily: 1.725 };

  const activityMultiplier =
    currentTrainingMultiplier[answers.currentTraining] ||
    desiredActivityMultiplier[answers.desiredActivity] ||
    currentActivityMultiplier[answers.currentActivity] ||
    1.45;

  const tdee = Math.round(bmr * activityMultiplier);

  // answers.goal can be a comma-joined string of IDs OR free text — first ID wins.
  const primaryGoal = String(answers.goal || '').split(',').map(s => s.trim()).filter(Boolean)[0] || '';
  let calories = tdee;

  if (primaryGoal === 'lose_fat') calories = Math.round(tdee * 0.82);
  else if (primaryGoal === 'build_muscle') calories = Math.round(tdee * 1.12);
  else if (primaryGoal === 'get_stronger') calories = Math.round(tdee * 1.05);

  // "fastest" optimization → slightly more aggressive deficit/surplus;
  // "injury_safe" / "consistent" → milder adjustment.
  if (answers.optimize === 'fastest') {
    if (primaryGoal === 'lose_fat') calories = Math.round(tdee * 0.78);
    else if (primaryGoal === 'build_muscle') calories = Math.round(tdee * 1.15);
  } else if (answers.optimize === 'injury_safe' || answers.optimize === 'consistent') {
    if (primaryGoal === 'lose_fat') calories = Math.round(tdee * 0.88);
    else if (primaryGoal === 'build_muscle') calories = Math.round(tdee * 1.08);
  }

  const proteinMultiplier = ['build_muscle', 'get_stronger'].includes(primaryGoal) ? 2.4 : 2.0;
  const protein = Math.round(w * proteinMultiplier);
  const proteinCals = protein * 4;
  const remaining = calories - proteinCals;
  const fats = Math.round(w * 1.0);
  const fatCals = fats * 9;
  const carbs = Math.round((remaining - fatCals) / 4);

  return {
    calories,
    protein,
    carbs: Math.max(carbs, 50),
    fats,
  };
}

export async function generateInitialPlans() {
  throw new Error(
    'generateInitialPlans is disabled. Use generateInitialPlanBundle so the Plan Questionnaire creates one canonical master AIPlan and linked WorkoutPlan, MealPlan, weekly AIPlan, and DailyLog projections.'
  );
}