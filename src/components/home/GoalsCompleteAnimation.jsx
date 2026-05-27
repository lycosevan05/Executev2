import { useEffect } from 'react';
import { motion } from 'framer-motion';
import confetti from 'canvas-confetti';

export default function GoalsCompleteAnimation({ onDismiss }) {
  useEffect(() => {
    // Fire confetti burst
    confetti({
      particleCount: 120,
      spread: 80,
      origin: { y: 0.55 },
      colors: ['#c8e000', '#8ea400', '#d4ef1f', '#ffffff', '#f6f2e8'],
    });
    setTimeout(() => {
      confetti({
        particleCount: 60,
        spread: 100,
        origin: { y: 0.4, x: 0.3 },
        colors: ['#c8e000', '#8ea400'],
      });
    }, 200);
    setTimeout(() => {
      confetti({
        particleCount: 60,
        spread: 100,
        origin: { y: 0.4, x: 0.7 },
        colors: ['#c8e000', '#d4ef1f'],
      });
    }, 350);

    const timer = setTimeout(onDismiss, 4000);
    return () => clearTimeout(timer);
  }, []);

  return (
    <motion.div
      initial={{ opacity: 0, scale: 0.85 }}
      animate={{ opacity: 1, scale: 1 }}
      exit={{ opacity: 0, scale: 0.9 }}
      transition={{ type: 'spring', damping: 18, stiffness: 250 }}
      className="fixed inset-0 z-50 flex items-center justify-center px-8"
      style={{ background: 'rgba(20,22,19,0.6)', backdropFilter: 'blur(8px)' }}
      onClick={onDismiss}
    >
      <motion.div
        className="rounded-3xl p-8 text-center max-w-xs w-full"
        style={{ background: '#ffffff', border: '2px solid rgba(200,224,0,0.4)', boxShadow: '0 24px 64px rgba(20,22,19,0.25)' }}
        onClick={e => e.stopPropagation()}
      >
        {/* Animated checkmark */}
        <motion.div
          className="w-20 h-20 rounded-full flex items-center justify-center mx-auto mb-5"
          style={{ background: 'rgba(200,224,0,0.15)', border: '3px solid #c8e000' }}
          animate={{ scale: [1, 1.12, 1], boxShadow: ['0 0 0px rgba(200,224,0,0)', '0 0 32px rgba(200,224,0,0.5)', '0 0 8px rgba(200,224,0,0.2)'] }}
          transition={{ duration: 1.2, repeat: 1, ease: 'easeInOut' }}
        >
          <motion.div
            initial={{ scale: 0, rotate: -30 }}
            animate={{ scale: 1, rotate: 0 }}
            transition={{ delay: 0.1, type: 'spring', damping: 12 }}
            style={{ fontSize: 36 }}
          >
            🏆
          </motion.div>
        </motion.div>

        <motion.h2
          initial={{ opacity: 0, y: 10 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.2 }}
          className="text-xl font-black mb-2"
          style={{ color: '#141613', letterSpacing: '-0.03em' }}
        >
          All done today!
        </motion.h2>

        <motion.p
          initial={{ opacity: 0, y: 10 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.3 }}
          className="text-sm leading-relaxed mb-6"
          style={{ color: '#5d635d' }}
        >
          You completed every task on your plan. That's how progress compounds.
        </motion.p>

        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ delay: 0.45 }}
          className="flex flex-wrap justify-center gap-2 mb-6"
        >
          {['💪 Strength', '😴 Sleep', '🥗 Nutrition', '💧 Hydration'].map((tag, i) => (
            <motion.span
              key={tag}
              initial={{ opacity: 0, scale: 0.7 }}
              animate={{ opacity: 1, scale: 1 }}
              transition={{ delay: 0.5 + i * 0.08 }}
              className="px-3 py-1.5 rounded-full text-xs font-semibold"
              style={{ background: 'rgba(200,224,0,0.12)', color: '#8ea400' }}
            >
              {tag}
            </motion.span>
          ))}
        </motion.div>

        <motion.button
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ delay: 0.6 }}
          whileTap={{ scale: 0.96 }}
          onClick={onDismiss}
          className="w-full py-3.5 rounded-2xl text-sm font-bold"
          style={{ background: '#c8e000', color: '#141613' }}
        >
          Keep it going 🔥
        </motion.button>
      </motion.div>
    </motion.div>
  );
}