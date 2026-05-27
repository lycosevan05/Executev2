import { useState, useCallback } from 'react';
import { loadCustomTrackers } from '@/lib/customTrackers';

const STORAGE_KEY = 'execute_vitals_layout';

export const BASE_VITALS = [
  { id: 'sleep',    label: 'Sleep',    unit: 'h',   icon: 'Moon',       dataKey: 'sleep_hours',          goalKey: null,            goalFixed: 8 },
  { id: 'steps',    label: 'Steps',    unit: 'k',   icon: 'Footprints', dataKey: 'steps',                goalKey: 'steps_goal',    goalFixed: null },
  { id: 'calories', label: 'Cals',     unit: '',    icon: 'Flame',      dataKey: 'calories_consumed',    goalKey: 'calories_goal', goalFixed: null },
  { id: 'water',    label: 'Water',    unit: 'L',   icon: 'Droplets',   dataKey: 'water_liters',         goalKey: 'water_goal',    goalFixed: null },
  { id: 'mood',     label: 'Mood',     unit: '/5',  icon: 'Smile',      dataKey: 'mood',                 goalKey: null,            goalFixed: 5 },
  { id: 'energy',   label: 'Energy',   unit: '/10', icon: 'Zap',        dataKey: 'energy',               goalKey: null,            goalFixed: 10 },
  { id: 'workout',  label: 'Workout',  unit: 'min', icon: 'Dumbbell',   dataKey: 'workout_duration_min', goalKey: null,            goalFixed: 60 },
  { id: 'weight',   label: 'Weight',   unit: 'kg',  icon: 'Scale',      dataKey: 'weight_kg',            goalKey: null,            goalFixed: null },
];

// Merge base vitals with any custom trackers the user has created
export function getAllVitals() {
  const custom = loadCustomTrackers();
  const customVitals = custom.map(c => ({
    id: c.id,
    label: c.label,
    unit: c.unit,
    icon: 'Pencil',
    dataKey: c.id,
    goalKey: null,
    goalFixed: null,
    custom: true,
  }));
  return [...BASE_VITALS, ...customVitals];
}

const DEFAULT_VITALS = ['sleep', 'steps', 'water'];

function loadSelectedIds() {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY));
    if (Array.isArray(saved) && saved.length > 0) return saved;
    // Migrate from old key
    const legacy = JSON.parse(localStorage.getItem('evanlog_vitals_layout'));
    if (Array.isArray(legacy) && legacy.length > 0) {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(legacy));
      return legacy;
    }
  } catch {
    // Ignore malformed saved layout and fall back to defaults.
  }
  return DEFAULT_VITALS;
}

function saveSelectedIds(ids) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(ids));
  } catch {
    // Storage can be unavailable in private or restricted contexts.
  }
}

export function useVitalsLayout() {
  const [selectedIds, setSelectedIds] = useState(loadSelectedIds);
  // Re-read custom trackers each render so new ones appear immediately
  const allVitals = getAllVitals();

  const toggle = useCallback((id) => {
    setSelectedIds(prev => {
      let next;
      if (prev.includes(id)) {
        if (prev.length <= 1) return prev; // keep at least 1
        next = prev.filter(x => x !== id);
      } else {
        if (prev.length >= 12) return prev; // max 12
        next = [...prev, id];
      }
      saveSelectedIds(next);
      return next;
    });
  }, []);

  const activeVitals = allVitals.filter(v => selectedIds.includes(v.id));

  return { selectedIds, activeVitals, toggle, allVitals };
}
