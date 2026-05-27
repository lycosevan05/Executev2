import { SlidersHorizontal, Check } from 'lucide-react';
import { motion } from 'framer-motion';

export default function CustomizeButton({ onCustomize, isCustomizing }) {
  return (
    <motion.button
      whileTap={{ scale: 0.92 }}
      onClick={onCustomize}
      className="flex items-center gap-1 px-3 py-2 rounded-full text-xs font-semibold border transition-all"
      style={{
        background: isCustomizing ? '#c8e000' : '#ffffff',
        borderColor: isCustomizing ? '#c8e000' : '#e8e1d4',
        color: isCustomizing ? '#141613' : '#5d635d',
      }}
    >
      {isCustomizing ? <Check size={13} /> : <SlidersHorizontal size={13} />}
      <span>{isCustomizing ? 'Done' : 'Customize'}</span>
    </motion.button>
  );
}