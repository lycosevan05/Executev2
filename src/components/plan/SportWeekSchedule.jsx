import { motion } from 'framer-motion';

const DAYS = [
  { key: 'mon', label: 'Mon' },
  { key: 'tue', label: 'Tue' },
  { key: 'wed', label: 'Wed' },
  { key: 'thu', label: 'Thu' },
  { key: 'fri', label: 'Fri' },
  { key: 'sat', label: 'Sat' },
  { key: 'sun', label: 'Sun' },
];

const SESSION_TYPES = [
  { id: 'solo',  label: 'Solo',  emoji: '🎯', desc: 'Skill / technical' },
  { id: 'team',  label: 'Team',  emoji: '👥', desc: 'Practice' },
  { id: 'game',  label: 'Game',  emoji: '🏆', desc: 'Match / comp' },
];

/**
 * Per-day picker. Each weekday can have any combination of: solo, team, game.
 * Value shape: { mon: ['solo'], tue: ['team','solo'], wed: [], ... }
 */
export default function SportWeekSchedule({ value = {}, onChange, accent = '#c8e000', accentDark = '#8ea400' }) {
  const schedule = value || {};

  const toggle = (dayKey, typeId) => {
    const current = Array.isArray(schedule[dayKey]) ? schedule[dayKey] : [];
    const next = current.includes(typeId)
      ? current.filter(t => t !== typeId)
      : [...current, typeId];
    onChange({ ...schedule, [dayKey]: next });
  };

  return (
    <div className="space-y-2">
      {DAYS.map(day => {
        const selected = Array.isArray(schedule[day.key]) ? schedule[day.key] : [];
        const hasAny = selected.length > 0;
        return (
          <div
            key={day.key}
            className="flex items-center gap-2 p-2.5 rounded-xl border"
            style={{
              background: hasAny ? 'rgba(200,224,0,0.06)' : '#ffffff',
              borderColor: hasAny ? 'rgba(200,224,0,0.35)' : '#e8e1d4',
            }}
          >
            <div className="w-10 flex-shrink-0">
              <p className="text-xs font-bold" style={{ color: hasAny ? accentDark : '#5d635d' }}>{day.label}</p>
            </div>
            <div className="flex-1 grid grid-cols-3 gap-1.5">
              {SESSION_TYPES.map(t => {
                const on = selected.includes(t.id);
                return (
                  <motion.button
                    key={t.id}
                    whileTap={{ scale: 0.94 }}
                    onClick={() => toggle(day.key, t.id)}
                    className="flex items-center justify-center gap-1 py-2 rounded-lg border text-xs font-semibold transition-all"
                    style={{
                      background: on ? accent : '#f9f7f3',
                      borderColor: on ? accent : '#e8e1d4',
                      color: on ? '#141613' : '#91968e',
                    }}
                  >
                    <span>{t.emoji}</span>
                    <span>{t.label}</span>
                  </motion.button>
                );
              })}
            </div>
          </div>
        );
      })}
      <p className="text-[11px] leading-relaxed pt-1" style={{ color: '#91968e' }}>
        Tap any combination per day. Your plan will balance gym, recovery, and fueling around these sessions.
      </p>
    </div>
  );
}