// Shared localStorage store for custom trackers
const STORAGE_KEY = 'execute_custom_trackers';

export function loadCustomTrackers() {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY));
    if (Array.isArray(saved)) return saved;
    // Migrate from old key
    const legacy = JSON.parse(localStorage.getItem('evanlog_custom_trackers'));
    if (Array.isArray(legacy)) {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(legacy));
      return legacy;
    }
  } catch {}
  return [];
}

export function saveCustomTrackers(trackers) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(trackers));
  } catch {}
}