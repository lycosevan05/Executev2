import { motion, AnimatePresence } from 'framer-motion';
import { RotateCcw, Check, X, Plus } from 'lucide-react';
import { PAGE_LAYOUTS } from './pageLayouts';

export default function CustomizePanel({
  pageKey,
  hiddenWidgets,
  onShowWidget,
  onReset,
  onDone,
  onCancel,
}) {
  const allWidgets = PAGE_LAYOUTS[pageKey]?.widgets || [];
  const hiddenMeta = allWidgets.filter(w => hiddenWidgets.includes(w.id));

  return (
    <AnimatePresence>
      <motion.div
        key="customize-panel-backdrop"
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        exit={{ opacity: 0 }}
        className="fixed inset-0 z-50 flex items-end justify-center"
        style={{ background: 'rgba(20,22,19,0.5)' }}
        onClick={onCancel}
      >
        <motion.div
          key="customize-panel-sheet"
          initial={{ y: '100%' }}
          animate={{ y: 0 }}
          exit={{ y: '100%' }}
          transition={{ type: 'spring', damping: 28, stiffness: 320 }}
          className="w-full max-w-md rounded-t-3xl"
          style={{ background: '#fbf8f1', border: '1px solid #e8e1d4', borderBottom: 'none' }}
          onClick={e => e.stopPropagation()}
        >
          {/* Handle */}
          <div className="w-10 h-1 rounded-full mx-auto mt-3 mb-4" style={{ background: '#d9d1c2' }} />

          <div className="px-5 pb-8">
            {/* Header */}
            <div className="flex items-center justify-between mb-5">
              <div>
                <h3 className="text-base font-bold" style={{ color: '#141613' }}>Add Widgets</h3>
                <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>Tap to restore hidden sections</p>
              </div>
              <button
                onClick={onCancel}
                className="w-8 h-8 rounded-xl flex items-center justify-center border"
                style={{ background: '#f2efe7', borderColor: '#e8e1d4' }}
              >
                <X size={14} style={{ color: '#5d635d' }} />
              </button>
            </div>

            {/* Hidden widgets to restore */}
            {hiddenMeta.length > 0 ? (
              <div className="space-y-2 mb-5">
                {hiddenMeta.map(w => (
                  <motion.button
                    key={w.id}
                    whileTap={{ scale: 0.97 }}
                    onClick={() => onShowWidget(w.id)}
                    className="w-full flex items-center gap-3 px-4 py-3.5 rounded-2xl border text-left transition-all"
                    style={{ background: '#ffffff', borderColor: '#e8e1d4' }}
                  >
                    <div className="w-8 h-8 rounded-xl flex items-center justify-center flex-shrink-0"
                      style={{ background: 'rgba(200,224,0,0.12)', border: '1px solid rgba(200,224,0,0.25)' }}>
                      <Plus size={14} style={{ color: '#8ea400' }} />
                    </div>
                    <div className="flex-1 min-w-0">
                      <p className="text-sm font-semibold" style={{ color: '#141613' }}>{w.label}</p>
                      <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>{w.description}</p>
                    </div>
                    <div className="px-2.5 py-1 rounded-lg"
                      style={{ background: 'rgba(200,224,0,0.12)', border: '1px solid rgba(200,224,0,0.3)' }}>
                      <span className="text-[10px] font-bold" style={{ color: '#8ea400' }}>Add</span>
                    </div>
                  </motion.button>
                ))}
              </div>
            ) : (
              <div className="mb-5 p-4 rounded-2xl border text-center" style={{ background: '#f9f7f3', borderColor: '#e8e1d4' }}>
                <p className="text-sm" style={{ color: '#91968e' }}>All sections are visible</p>
                <p className="text-xs mt-1" style={{ color: '#d9d1c2' }}>Use the × button on a section to hide it</p>
              </div>
            )}

            {/* Actions */}
            <div className="flex gap-3">
              <button
                onClick={onReset}
                className="flex items-center justify-center gap-2 flex-1 py-3 rounded-2xl border text-sm font-semibold transition-all active:scale-95"
                style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}
              >
                <RotateCcw size={13} />
                Reset
              </button>
              <button
                onClick={onDone}
                className="flex items-center justify-center gap-2 flex-1 py-3 rounded-2xl text-sm font-bold transition-all active:scale-95"
                style={{ background: '#c8e000', color: '#141613' }}
              >
                <Check size={13} />
                Done
              </button>
            </div>
          </div>
        </motion.div>
      </motion.div>
    </AnimatePresence>
  );
}