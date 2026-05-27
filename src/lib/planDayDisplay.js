const GENERIC_EXACT_TITLES = new Set([
  'training',
  'workout',
  'workout scheduled',
  'build workout',
  'build this workout',
  'sport practice',
  'sports practice',
  'practice',
  'team practice',
  'solo technical',
  'skill session',
  'game',
  'match',
  'rest',
  'rest day',
  'recovery',
  'recovery day',
  'mobility',
  'mobility day',
]);

function cleanText(value) {
  return typeof value === 'string' ? value.trim().replace(/\s+/g, ' ') : '';
}

function normalizeTitle(value) {
  return cleanText(value)
    .toLowerCase()
    .replace(/[—–]/g, '-')
    .replace(/[^a-z0-9+\-\s]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

export function isGenericPlanDayTitle(value) {
  const normalized = normalizeTitle(value);
  if (!normalized) return true;
  if (GENERIC_EXACT_TITLES.has(normalized)) return true;
  if (/^(sport|sports)\s+(practice|training|session)$/.test(normalized)) return true;
  if (/^[a-z0-9 ]+\s*-\s*(practice|team practice|solo technical|solo skill|game|match|competition)$/.test(normalized)) return true;
  if (/^[a-z0-9 ]+\s+(practice|team practice|game|match)$/.test(normalized)) return true;
  return false;
}

function parseSportLabel(trainingType) {
  const normalized = cleanText(trainingType).replace(/[—–]/g, '-');
  if (!normalized) return null;

  const dashed = normalized.match(/^(.+?)\s*-\s*(team practice|practice|solo technical|solo skill|skill|game|match|competition|class)$/i);
  if (dashed) return { sport: cleanText(dashed[1]), kind: cleanText(dashed[2]).toLowerCase() };

  const plain = normalized.match(/^(.+?)\s+(team practice|practice|game|match|competition|class)$/i);
  if (plain) return { sport: cleanText(plain[1]), kind: cleanText(plain[2]).toLowerCase() };

  return null;
}

function textIncludesAny(value, needles) {
  const text = normalizeTitle(value);
  return needles.some(needle => text.includes(needle));
}

function deriveSportTitle(day, trainingType) {
  const sportLabel = parseSportLabel(trainingType);
  if (!sportLabel?.sport) return '';

  const { sport, kind } = sportLabel;
  const nutrition = day?.nutrition_focus || '';
  const recovery = day?.recovery_focus || '';

  if (/game|match|competition/.test(kind)) {
    return `${sport} Match Day Readiness`;
  }

  if (/solo|skill|technical/.test(kind)) {
    return `${sport} Skill + Mobility Session`;
  }

  if (/team|practice|class/.test(kind)) {
    if (
      textIncludesAny(nutrition, ['carb', 'fuel', 'protein', 'hydrate']) ||
      textIncludesAny(recovery, ['mobility', 'recovery', 'hips', 'stretch'])
    ) {
      return `${sport} Practice Fuel + Recovery`;
    }
    return `${sport} Team Practice Load`;
  }

  return `${sport} Performance Session`;
}

export function getPlanDaySessionTitle(day, fallback = 'Training') {
  const safeDay = day || {};
  const explicitTitle = cleanText(
    safeDay.session_title ||
    safeDay.display_name ||
    safeDay.session_name ||
    safeDay.title
  );
  if (explicitTitle && !isGenericPlanDayTitle(explicitTitle)) return explicitTitle;

  const trainingType = cleanText(safeDay.training_type);
  const sportTitle = deriveSportTitle(safeDay, trainingType);
  if (sportTitle) return sportTitle;

  if (trainingType && !isGenericPlanDayTitle(trainingType)) return trainingType;

  const priority = cleanText(safeDay.priority || safeDay.day_focus || safeDay.dayFocus);
  if (priority && !isGenericPlanDayTitle(priority) && priority.length <= 72) {
    return priority;
  }

  return cleanText(fallback) || 'Training';
}
