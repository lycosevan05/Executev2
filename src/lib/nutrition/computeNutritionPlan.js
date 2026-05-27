/**
 * computeNutritionPlan.js
 *
 * Evidence-based daily calorie + macronutrient target calculator.
 *
 * Pure computation module — no UI, no entity writes, no side effects.
 *
 * Model layers (applied in order):
 *   1. BMR via Mifflin–St Jeor
 *   2. baseTdee = BMR * activityFactor  (typical weekly activity, NOT today's session)
 *   3. baseGoalCalories = baseTdee * goalMultiplier
 *   4. baseGoalCaloriesDay = baseGoalCalories * dayTypeCalorieMultiplier
 *   5. caloriesBeforeCarbs = baseGoalCaloriesDay + (exerciseCaloriesExtra * eatBackFactor)
 *   6. Macros computed from caloriesBeforeCarbs:
 *        - protein g/kg by exerciseLevel + goal (+ optional dayType bump)
 *        - fat % of calories by goal
 *        - carbs = remainder, then floored by sport + dayType demands
 *   7. If carb floor raises totals above caloriesBeforeCarbs → caloriesTarget rises,
 *      and performanceOverrideWarning is set.
 *
 * @typedef {"male"|"female"} Sex
 * @typedef {"sedentary"|"light"|"moderate"|"heavy"|"athlete_endurance"|"athlete_strength"} ExerciseLevel
 * @typedef {"build_muscle"|"build_strength"|"lose_fat"|"recomp"|"optimize_performance"|"maintenance"} PrimaryGoal
 * @typedef {"rest"|"easy_training"|"hard_training"|"game"|"competition_peak"} DayType
 * @typedef {"same_calories"|"day_cycling"} WeeklyMode
 *
 * @typedef {Object} NutritionInput
 * @property {number} ageYears
 * @property {Sex} sex
 * @property {number} weightKg
 * @property {number} heightCm
 * @property {ExerciseLevel} exerciseLevel
 * @property {string} sportType
 * @property {PrimaryGoal} primaryGoal
 * @property {DayType} dayType
 * @property {number} exerciseCaloriesExtra
 * @property {number} [activityFactorOverride]
 * @property {number} [proteinGPerKgOverride]
 * @property {number} [fatPercentCaloriesOverride]
 * @property {number} [exerciseCaloriesEatBackFactor]
 * @property {number} [dayTypeCalorieMultiplierOverride]
 */

// ─── CONFIG ──────────────────────────────────────────────────────────────────
// Centralized constants for easy tuning.

export const CONFIG = {
  weeklyMode: /** @type {WeeklyMode} */ ('day_cycling'),

  // Activity factor by exerciseLevel (multiplied by BMR → baseTdee)
  activityFactors: {
    sedentary: 1.2,
    light: 1.4,
    moderate: 1.6,
    heavy: 1.8,
    athlete_endurance: 1.7,
    athlete_strength: 1.8,
  },

  // Goal multiplier applied to baseTdee → baseGoalCalories
  goalCalorieMultipliers: {
    maintenance: 1.00,
    lose_fat: 0.80,
    recomp: 0.95,
    build_muscle: 1.12,
    build_strength: 1.12,
    optimize_performance: 1.03,
  },

  // dayType multiplier applied to baseGoalCalories → baseGoalCaloriesDay
  dayTypeCalorieMultipliers: {
    day_cycling: {
      rest: 0.95,
      easy_training: 1.00,
      hard_training: 1.05,
      game: 1.08,
      competition_peak: 1.10,
    },
    // In same_calories mode, swings are clamped near 1.00 — periodization is mostly via macros.
    same_calories: {
      rest: 0.98,
      easy_training: 1.00,
      hard_training: 1.03,
      game: 1.04,
      competition_peak: 1.05,
    },
  },

  // Protein g/kg ranges [low, high] by exerciseLevel
  proteinRangesGPerKg: {
    sedentary: [1.2, 1.6],
    light: [1.4, 1.8],
    moderate: [1.6, 2.0],
    heavy: [1.8, 2.2],
    athlete_endurance: [1.6, 2.0],
    athlete_strength: [1.8, 2.4],
  },

  // Protein adjustments by goal (added to both ends of the range)
  proteinGoalAdjustment: {
    lose_fat: 0.2,
    recomp: 0.2,
    build_muscle: 0.1,
    build_strength: 0.1,
    optimize_performance: 0.0,
    maintenance: 0.0,
  },

  // Small optional protein bump on demanding days
  proteinDayTypeBump: {
    hard_training: 0.1,
    game: 0.1,
    competition_peak: 0.1,
    easy_training: 0.0,
    rest: 0.0,
  },

  // Fat % of calories by goal
  fatPercentCaloriesByGoal: {
    lose_fat: 0.20,
    recomp: 0.20,
    build_muscle: 0.25,
    build_strength: 0.25,
    optimize_performance: 0.25,
    maintenance: 0.25,
  },

  defaultExerciseCaloriesEatBackFactor: 1.0,

  // Sport type keyword matchers for endurance/field vs strength/power classification
  endurancePatterns: [
    'run', 'jog', 'cycle', 'cycling', 'bike', 'row', 'swim', 'triathlon',
    'soccer', 'football', 'basketball', 'hockey', 'rugby', 'lacrosse',
    'tennis', 'squash', 'badminton', 'volleyball', 'handball', 'ultimate',
    'crossfit', 'hyrox', 'endurance', 'cardio', 'mma', 'jiu-jitsu', 'jiu jitsu',
    'bjj', 'boxing', 'kickboxing', 'wrestling', 'martial', 'ski', 'climb',
  ],
  strengthPatterns: [
    'powerlift', 'olympic lifting', 'weightlifting', 'strongman',
    'bodybuilding', 'strength', 'lift',
  ],

  // Carb floors (g/kg) by sport family × dayType demand
  carbFloors: {
    endurance: { hard: 5.0, easy: 3.0 },
    strength: { hard: 3.0, easy: 2.0 },
  },
};

// ─── HELPERS ─────────────────────────────────────────────────────────────────

const HARD_DAY_TYPES = new Set(['hard_training', 'game', 'competition_peak']);
const EASY_DAY_TYPES = new Set(['easy_training', 'rest']);

function clampPositive(n) {
  return Math.max(0, Number.isFinite(n) ? n : 0);
}

function round(n) {
  return Math.round(n);
}

function midpoint([lo, hi]) {
  return (lo + hi) / 2;
}

function classifySport(sportType = '', exerciseLevel = '') {
  const s = String(sportType).toLowerCase();
  if (CONFIG.strengthPatterns.some(p => s.includes(p))) return 'strength';
  if (CONFIG.endurancePatterns.some(p => s.includes(p))) return 'endurance';
  if (exerciseLevel === 'athlete_strength') return 'strength';
  if (exerciseLevel === 'athlete_endurance') return 'endurance';
  // Default: treat moderate/heavy mixed training as endurance for carb floor purposes
  return 'endurance';
}

// ─── CORE FUNCTIONS ──────────────────────────────────────────────────────────

/**
 * Mifflin–St Jeor BMR.
 * Male:   10*kg + 6.25*cm − 5*age + 5
 * Female: 10*kg + 6.25*cm − 5*age − 161
 */
export function estimateBmrMifflinStJeor(weightKg, heightCm, ageYears, sex) {
  const w = clampPositive(weightKg);
  const h = clampPositive(heightCm);
  const a = clampPositive(ageYears);
  const base = 10 * w + 6.25 * h - 5 * a;
  return sex === 'male' ? base + 5 : base - 161;
}

/** Resolve activity factor from exerciseLevel (or override). */
export function deriveActivityFactor(exerciseLevel, activityFactorOverride) {
  if (Number.isFinite(activityFactorOverride) && activityFactorOverride > 0) {
    return activityFactorOverride;
  }
  return CONFIG.activityFactors[exerciseLevel] ?? 1.6;
}

/** baseTdee × goalMultiplier */
export function computeBaseGoalCalories(baseTdee, primaryGoal) {
  const mult = CONFIG.goalCalorieMultipliers[primaryGoal] ?? 1.0;
  return baseTdee * mult;
}

/** baseGoalCalories × dayTypeMultiplier (override wins). */
export function applyDayTypeModifiers(baseGoalCalories, dayType, override) {
  const multiplier = Number.isFinite(override) && override > 0
    ? override
    : (CONFIG.dayTypeCalorieMultipliers[CONFIG.weeklyMode]?.[dayType] ?? 1.0);
  return {
    dayTypeCalorieMultiplierUsed: multiplier,
    baseGoalCaloriesDay: baseGoalCalories * multiplier,
  };
}

/** exerciseCaloriesExtra × eatBackFactor */
export function applyExerciseCalories(exerciseCaloriesExtra, eatBackFactor) {
  const factor = Number.isFinite(eatBackFactor) && eatBackFactor >= 0
    ? eatBackFactor
    : CONFIG.defaultExerciseCaloriesEatBackFactor;
  return {
    exerciseCaloriesEatBackFactorUsed: factor,
    exerciseCaloriesEffective: clampPositive(exerciseCaloriesExtra) * factor,
  };
}

/**
 * Compute protein, fat, carb grams from caloriesBeforeCarbs.
 * Carbs are calculated as a remainder; floors are applied in a separate step.
 */
export function computeMacros({
  caloriesBeforeCarbs,
  weightKg,
  exerciseLevel,
  primaryGoal,
  dayType,
  proteinGPerKgOverride,
  fatPercentCaloriesOverride,
}) {
  const range = CONFIG.proteinRangesGPerKg[exerciseLevel] ?? [1.6, 2.0];
  const goalAdj = CONFIG.proteinGoalAdjustment[primaryGoal] ?? 0;
  const dayBump = CONFIG.proteinDayTypeBump[dayType] ?? 0;
  const adjustedRange = [range[0] + goalAdj + dayBump, range[1] + goalAdj + dayBump];

  const proteinGPerKgUsed = Number.isFinite(proteinGPerKgOverride) && proteinGPerKgOverride > 0
    ? proteinGPerKgOverride
    : midpoint(adjustedRange);

  const proteinGrams = proteinGPerKgUsed * weightKg;

  const fatPercentCaloriesUsed = Number.isFinite(fatPercentCaloriesOverride) && fatPercentCaloriesOverride > 0
    ? fatPercentCaloriesOverride
    : (CONFIG.fatPercentCaloriesByGoal[primaryGoal] ?? 0.25);

  const fatCalories = caloriesBeforeCarbs * fatPercentCaloriesUsed;
  const fatGrams = fatCalories / 9;

  const remaining = caloriesBeforeCarbs - (proteinGrams * 4 + fatGrams * 9);
  const carbGrams = Math.max(remaining / 4, 0);

  return {
    proteinGPerKgUsed,
    fatPercentCaloriesUsed,
    proteinGrams,
    fatGrams,
    carbGrams,
  };
}

/**
 * Apply sport + dayType carb floors. If the floor raises carbs above the
 * provisional remainder, total daily calories rise and we flag the override.
 */
export function enforceCarbFloors({
  carbGrams,
  proteinGrams,
  fatGrams,
  caloriesBeforeCarbs,
  weightKg,
  sportType,
  exerciseLevel,
  dayType,
}) {
  const family = classifySport(sportType, exerciseLevel);
  const demand = HARD_DAY_TYPES.has(dayType) ? 'hard' : 'easy';
  const carbMinGPerKg = CONFIG.carbFloors[family]?.[demand] ?? 0;
  const carbMinGrams = carbMinGPerKg * weightKg;

  let finalCarbGrams = carbGrams;
  let performanceOverrideWarning = false;

  if (carbMinGrams > carbGrams) {
    finalCarbGrams = carbMinGrams;
  }

  const caloriesTarget = proteinGrams * 4 + fatGrams * 9 + finalCarbGrams * 4;
  if (caloriesTarget > caloriesBeforeCarbs + 1) {
    performanceOverrideWarning = true;
  }

  return {
    carbGrams: finalCarbGrams,
    caloriesTarget,
    performanceOverrideWarning,
    carbMinGPerKgUsed: carbMinGPerKg,
    sportFamily: family,
  };
}

// ─── SUMMARY GENERATOR ───────────────────────────────────────────────────────

function buildSummary({
  primaryGoal, dayType, sportFamily, sportType,
  caloriesTarget, proteinGrams, carbGrams, fatGrams,
  performanceOverrideWarning, weightKg, exerciseCaloriesEffective,
}) {
  const goalText = {
    maintenance: 'maintain your weight',
    lose_fat: 'lose body fat',
    recomp: 'recomp (lean gain with minimal fat)',
    build_muscle: 'build muscle',
    build_strength: 'build strength',
    optimize_performance: 'optimize performance',
  }[primaryGoal] || 'support your training';

  const dayText = {
    rest: 'rest day',
    easy_training: 'easy training day',
    hard_training: 'hard training day',
    game: 'game/match day',
    competition_peak: 'competition day',
  }[dayType] || 'training day';

  const sportLabel = sportType ? ` (${sportType})` : '';
  const carbsPerKg = (carbGrams / weightKg).toFixed(1);
  const exerciseLine = exerciseCaloriesEffective > 0
    ? ` Today's session adds ~${round(exerciseCaloriesEffective)} kcal on top of your base intake.`
    : '';
  const overrideLine = performanceOverrideWarning
    ? ` Carbs were raised to meet ${sportFamily}-day demands, so total calories sit above your base goal — this is intentional fuel for performance.`
    : '';

  return [
    `Plan built for a ${dayText} to ${goalText}${sportLabel}.`,
    `Targets: ${round(caloriesTarget)} kcal / ${round(proteinGrams)}g protein / ${round(carbGrams)}g carbs (${carbsPerKg} g/kg) / ${round(fatGrams)}g fat.`,
    exerciseLine + overrideLine,
  ].join(' ').trim();
}

// ─── MAIN ENTRY ──────────────────────────────────────────────────────────────

/**
 * Compute a full daily nutrition plan.
 * @param {NutritionInput} input
 */
export function computeNutritionPlan(input) {
  const {
    ageYears, sex, weightKg, heightCm,
    exerciseLevel, sportType, primaryGoal, dayType,
    exerciseCaloriesExtra = 0,
    activityFactorOverride,
    proteinGPerKgOverride,
    fatPercentCaloriesOverride,
    exerciseCaloriesEatBackFactor,
    dayTypeCalorieMultiplierOverride,
  } = input;

  // 1. BMR + base TDEE
  const bmr = estimateBmrMifflinStJeor(weightKg, heightCm, ageYears, sex);
  const activityFactorUsed = deriveActivityFactor(exerciseLevel, activityFactorOverride);
  const baseTdee = bmr * activityFactorUsed;

  // 2. Goal-adjusted base
  const baseGoalCalories = computeBaseGoalCalories(baseTdee, primaryGoal);

  // 3. Day-type adjustment
  const { dayTypeCalorieMultiplierUsed, baseGoalCaloriesDay } =
    applyDayTypeModifiers(baseGoalCalories, dayType, dayTypeCalorieMultiplierOverride);

  // 4. Add exercise calories on top
  const { exerciseCaloriesEatBackFactorUsed, exerciseCaloriesEffective } =
    applyExerciseCalories(exerciseCaloriesExtra, exerciseCaloriesEatBackFactor);

  const caloriesBeforeCarbs = baseGoalCaloriesDay + exerciseCaloriesEffective;

  // 5. Macros (protein + fat fixed; carbs = remainder)
  const macros = computeMacros({
    caloriesBeforeCarbs,
    weightKg,
    exerciseLevel,
    primaryGoal,
    dayType,
    proteinGPerKgOverride,
    fatPercentCaloriesOverride,
  });

  // 6. Carb floors (may raise total calories on demanding days)
  const floorResult = enforceCarbFloors({
    carbGrams: macros.carbGrams,
    proteinGrams: macros.proteinGrams,
    fatGrams: macros.fatGrams,
    caloriesBeforeCarbs,
    weightKg,
    sportType,
    exerciseLevel,
    dayType,
  });

  const proteinGrams = macros.proteinGrams;
  const fatGrams = macros.fatGrams;
  const carbGrams = floorResult.carbGrams;
  const caloriesTarget = floorResult.caloriesTarget;
  const carbGPerKg = weightKg > 0 ? carbGrams / weightKg : 0;

  // 7. Sanity flags
  const lowCalorieWarning = caloriesTarget < 20 * weightKg;
  const lowFatWarning = macros.fatPercentCaloriesUsed < 0.20 || fatGrams < 0.5 * weightKg;
  const lowCarbWarning = floorResult.sportFamily === 'endurance' && carbGPerKg < 3.0;

  const summary = buildSummary({
    primaryGoal, dayType,
    sportFamily: floorResult.sportFamily,
    sportType,
    caloriesTarget, proteinGrams, carbGrams, fatGrams,
    performanceOverrideWarning: floorResult.performanceOverrideWarning,
    weightKg,
    exerciseCaloriesEffective,
  });

  return {
    inputs: {
      ageYears, sex, weightKg, heightCm,
      exerciseLevel, sportType, primaryGoal, dayType,
      activityFactorUsed,
      exerciseCaloriesExtra: clampPositive(exerciseCaloriesExtra),
      exerciseCaloriesEatBackFactorUsed,
      dayTypeCalorieMultiplierUsed,
      proteinGPerKgUsed: macros.proteinGPerKgUsed,
      fatPercentCaloriesUsed: macros.fatPercentCaloriesUsed,
    },
    energy: {
      bmr: round(bmr),
      baseTdee: round(baseTdee),
      baseGoalCalories: round(baseGoalCalories),
      baseGoalCaloriesDay: round(baseGoalCaloriesDay),
      exerciseCaloriesEffective: round(exerciseCaloriesEffective),
      caloriesTarget: round(caloriesTarget),
    },
    macros: {
      proteinGrams: round(proteinGrams),
      fatGrams: round(fatGrams),
      carbGrams: round(carbGrams),
      carbGPerKg: Number(carbGPerKg.toFixed(2)),
    },
    flags: {
      lowCalorieWarning,
      lowFatWarning,
      lowCarbWarning,
      performanceOverrideWarning: floorResult.performanceOverrideWarning,
    },
    summary,
  };
}

export default computeNutritionPlan;