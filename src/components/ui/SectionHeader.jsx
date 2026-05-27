import { motion } from 'framer-motion';

export default function SectionHeader({ title, subtitle, action, actionLabel }) {
  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      className="flex items-end justify-between mb-4"
    >
      <div>
        <h3 className="text-base font-semibold text-ice-white">{title}</h3>
        {subtitle && <p className="text-xs text-slate-mist mt-0.5">{subtitle}</p>}
      </div>
      {action && actionLabel && (
        <button onClick={action} className="text-xs text-electric-oxygen font-medium hover:opacity-80 transition-opacity">
          {actionLabel}
        </button>
      )}
    </motion.div>
  );
}