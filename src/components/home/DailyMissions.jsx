import { motion } from 'framer-motion';
import { Link } from 'react-router-dom';
import { Dumbbell, Moon, Apple, ChevronRight, CheckCircle2 } from 'lucide-react';

const missions = [
  { icon: Dumbbell, label: 'Exercise', color: '#8ea400', bg: 'rgba(200,224,0,0.1)', to: '/track' },
  { icon: Moon, label: 'Sleep', color: '#8ea400', bg: 'rgba(200,224,0,0.1)', to: '/track' },
  { icon: Apple, label: 'Nutrition', color: '#8ea400', bg: 'rgba(200,224,0,0.1)', to: '/track' },
];

export default function DailyMissions({ data }) {
  const { workout, sleep, nutrition } = data;

  const items = [
    { ...missions[0], desc: workout.done ? `${workout.duration}min ${workout.type}` : workout.rec, done: workout.done },
    { ...missions[1], desc: sleep.done ? `${sleep.hours}h logged` : sleep.rec, done: sleep.done },
    { ...missions[2], desc: nutrition.onTrack ? `${nutrition.calories} kcal on track` : nutrition.rec, done: nutrition.onTrack },
  ];

  return (
    <div>
      <div className="flex items-center justify-between mb-3">
        <div>
          <h3 className="text-base font-semibold" style={{ color: '#141613' }}>Daily Missions</h3>
          <p className="text-[11px] mt-0.5" style={{ color: '#91968e' }}>Calculated from your 7-day trend</p>
        </div>
        <span className="text-xs font-medium" style={{ color: '#8ea400' }}>
          {items.filter(i => i.done).length}/{items.length} done
        </span>
      </div>

      <div className="space-y-2.5">
        {items.map((item, i) => (
          <motion.div
            key={item.label}
            initial={{ opacity: 0, x: -12 }}
            animate={{ opacity: 1, x: 0 }}
            transition={{ delay: i * 0.08 + 0.2 }}
          >
            <Link
              to={item.to}
              className="flex items-center gap-3 p-4 rounded-2xl border active:scale-98 transition-transform"
              style={{ background: item.done ? 'rgba(200,224,0,0.06)' : '#ffffff', borderColor: item.done ? 'rgba(200,224,0,0.25)' : '#e8e1d4' }}
            >
              <div className="w-10 h-10 rounded-2xl flex items-center justify-center flex-shrink-0" style={{ background: 'rgba(200,224,0,0.1)' }}>
                <item.icon size={18} style={{ color: '#8ea400' }} />
              </div>
              <div className="flex-1 min-w-0">
                <p className="text-sm font-semibold" style={{ color: '#141613' }}>{item.label}</p>
                <p className="text-xs mt-0.5 truncate" style={{ color: '#91968e' }}>{item.desc}</p>
              </div>
              {item.done
                ? <CheckCircle2 size={18} style={{ color: '#8ea400' }} className="flex-shrink-0" />
                : <ChevronRight size={16} style={{ color: '#d9d1c2' }} className="flex-shrink-0" />
              }
            </Link>
          </motion.div>
        ))}
      </div>
    </div>
  );
}