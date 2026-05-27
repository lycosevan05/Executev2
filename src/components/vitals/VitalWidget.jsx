import { motion } from 'framer-motion';
import { GripVertical, Minus } from 'lucide-react';

export default function VitalWidget({ widget, editMode, onRemove, dragHandleProps, isDragging }) {
  const { icon: Icon, label, value, unit, trend, trendDir, progress, color, context } = widget;

  return (
    <motion.div
      layout
      animate={editMode ? { rotate: [0, -1, 1, -1, 0] } : { rotate: 0 }}
      transition={editMode
        ? { duration: 0.4, repeat: Infinity, repeatType: 'loop', ease: 'easeInOut' }
        : { duration: 0.2 }
      }
      className={`relative rounded-2xl p-4 border select-none ${isDragging ? 'opacity-70 scale-105 z-50' : ''}`}
      style={{ background: '#ffffff', borderColor: '#e8e1d4', boxShadow: isDragging ? '0 20px 60px rgba(20,22,19,0.15)' : undefined }}
    >
      {/* Edit controls */}
      {editMode && (
        <>
          <button
            onClick={onRemove}
            className="absolute -top-2 -left-2 w-6 h-6 rounded-full flex items-center justify-center z-10 shadow-lg"
            style={{ background: '#b05a3a', border: '2px solid #f6f2e8' }}
          >
            <Minus size={12} className="text-white" />
          </button>
          <div
            {...dragHandleProps}
            className="absolute -top-2 -right-2 w-6 h-6 rounded-full flex items-center justify-center cursor-grab active:cursor-grabbing z-10 shadow-lg"
            style={{ background: '#f2efe7', border: '1px solid #e8e1d4' }}
          >
            <GripVertical size={12} className="text-slate-mist" />
          </div>
        </>
      )}

      {/* Icon */}
      <div className="w-8 h-8 rounded-xl flex items-center justify-center mb-3" style={{ background: 'rgba(200,224,0,0.1)' }}>
        <Icon size={16} style={{ color: '#8ea400' }} />
      </div>

      {/* Value */}
      <div className="flex items-end gap-1 mb-0.5">
        <span className="text-xl font-bold" style={{ color: '#141613' }}>{value}</span>
        {unit && <span className="text-xs mb-0.5" style={{ color: '#91968e' }}>{unit}</span>}
      </div>

      {/* Label */}
      <span className="text-xs" style={{ color: '#91968e' }}>{label}</span>

      {/* Trend */}
      {trend && (
        <div className="flex items-center gap-1 mt-1.5">
          <span className="text-[10px] font-semibold" style={{ color: trendDir === 'up' ? '#4a7c59' : trendDir === 'down' ? '#b05a3a' : '#91968e' }}>
            {trendDir === 'up' ? '↑' : trendDir === 'down' ? '↓' : '→'} {trend}
          </span>
        </div>
      )}

      {/* Progress bar */}
      {progress !== undefined && (
        <div className="mt-2.5 h-1 rounded-full overflow-hidden" style={{ background: '#e8e1d4' }}>
          <motion.div
            className="h-full rounded-full"
            style={{ background: '#c8e000' }}
            initial={{ width: 0 }}
            animate={{ width: `${Math.min(progress * 100, 100)}%` }}
            transition={{ duration: 1, ease: [0.4, 0, 0.2, 1] }}
          />
        </div>
      )}

      {/* Context label */}
      {context && (
        <p className="text-[10px] mt-1.5 leading-snug" style={{ color: '#91968e' }}>{context}</p>
      )}
    </motion.div>
  );
}