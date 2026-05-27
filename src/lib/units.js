// Unit system preference — stored in localStorage
const UNITS_KEY = 'app_units_preference';

export const UNIT_SYSTEMS = {
  imperial: { label: 'Imperial', height: 'ft/in', weight: 'lbs', distance: 'miles' },
  metric:   { label: 'Metric',   height: 'cm',    weight: 'kg',  distance: 'km'    },
};

export function getUnitSystem() {
  try {
    return localStorage.getItem(UNITS_KEY) || 'imperial';
  } catch { return 'imperial'; }
}

export function setUnitSystem(system) {
  try { localStorage.setItem(UNITS_KEY, system); } catch {}
}

// Conversions
export function kgToLbs(kg) { return Math.round(kg * 2.20462 * 10) / 10; }
export function lbsToKg(lbs) { return Math.round(lbs / 2.20462 * 10) / 10; }

export function cmToFtIn(cm) {
  const totalInches = cm / 2.54;
  const ft = Math.floor(totalInches / 12);
  const inches = Math.round(totalInches % 12);
  return { ft, inches };
}

export function ftInToCm(ft, inches) {
  return Math.round(((Number(ft) * 12) + Number(inches)) * 2.54);
}

export function formatHeight(cm, system) {
  if (!cm) return '';
  if (system === 'metric') return `${cm} cm`;
  const { ft, inches } = cmToFtIn(cm);
  return `${ft}'${inches}"`;
}

export function formatWeight(kg, system) {
  if (!kg) return '';
  if (system === 'metric') return `${kg} kg`;
  return `${kgToLbs(kg)} lbs`;
}