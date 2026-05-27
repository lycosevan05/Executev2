import { useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { X, Plus, Settings2, Moon, Droplets, Flame, Heart, Footprints, Activity, Scale, Zap, Battery, Wind } from 'lucide-react';
import { DragDropContext, Droppable, Draggable } from '@hello-pangea/dnd';
import VitalWidget from './VitalWidget';
import AICoachCard from '../home/AICoachCard';

const ALL_WIDGETS = [
  { id: 'sleep', label: 'Sleep', icon: Moon, color: '#8ea400', group: 'core' },
  { id: 'energy', label: 'Energy', icon: Battery, color: '#8ea400', group: 'core' },
  { id: 'calories_in', label: 'Calories In', icon: Flame, color: '#8ea400', group: 'core' },
  { id: 'calories_out', label: 'Calories Out', icon: Zap, color: '#8ea400', group: 'core' },
  { id: 'water', label: 'Water', icon: Droplets, color: '#8ea400', group: 'core' },
  { id: 'heart_rate', label: 'Heart Rate', icon: Heart, color: '#8ea400', group: 'core' },
  { id: 'resting_hr', label: 'Resting HR', icon: Activity, color: '#8ea400', group: 'core' },
  { id: 'steps', label: 'Steps', icon: Footprints, color: '#8ea400', group: 'activity' },
  { id: 'weight', label: 'Weight', icon: Scale, color: '#8ea400', group: 'activity' },
  { id: 'recovery', label: 'Recovery', icon: Wind, color: '#8ea400', group: 'activity' },
];

function buildWidgetData(id, data) {
  const d = data;
  switch (id) {
    case 'sleep': return {
      value: d.sleep.hours, unit: 'hrs',
      trend: `${d.sleep.hours >= d.sleep.prevHours ? '+' : ''}${(d.sleep.hours - d.sleep.prevHours).toFixed(1)}h from yesterday`,
      trendDir: d.sleep.hours >= d.sleep.prevHours ? 'up' : 'down',
      progress: d.sleep.hours / d.sleep.goal,
      context: `Goal: ${d.sleep.goal}h`,
    };
    case 'energy': return {
      value: d.recovery.score, unit: '%',
      trend: 'Based on sleep + recovery',
      trendDir: d.recovery.score >= 75 ? 'up' : 'down',
      progress: d.recovery.score / 100,
      context: 'Calculated from last 7 days',
    };
    case 'calories_in': return {
      value: d.calories.consumed, unit: 'kcal',
      trend: `${d.calories.consumed < d.calories.goal ? 'Under' : 'Over'} goal by ${Math.abs(d.calories.consumed - d.calories.goal)}`,
      trendDir: d.calories.consumed <= d.calories.goal ? 'up' : 'down',
      progress: d.calories.consumed / d.calories.goal,
      context: `Goal: ${d.calories.goal} kcal`,
    };
    case 'calories_out': return {
      value: d.calories.burned, unit: 'kcal',
      trend: '+18% vs weekly avg',
      trendDir: 'up',
      progress: d.calories.burned / 600,
      context: 'Active + resting burn',
    };
    case 'water': return {
      value: d.water.liters, unit: 'L',
      trend: `${d.water.liters >= 2 ? 'On track' : 'Behind target'}`,
      trendDir: d.water.liters >= 2 ? 'up' : 'down',
      progress: d.water.liters / d.water.goal,
      context: `Goal: ${d.water.goal}L`,
    };
    case 'heart_rate': return {
      value: 68, unit: 'bpm',
      trend: '↓ from 72 yesterday',
      trendDir: 'up',
      context: 'Current reading',
    };
    case 'resting_hr': return {
      value: 58, unit: 'bpm',
      trend: 'Within normal range',
      trendDir: 'neutral',
      context: '7-day average',
    };
    case 'steps': return {
      value: d.steps.current.toLocaleString(), unit: 'steps',
      trend: `${d.steps.goal - d.steps.current > 0 ? (d.steps.goal - d.steps.current).toLocaleString() + ' to go' : 'Goal hit!'}`,
      trendDir: d.steps.current / d.steps.goal >= 0.8 ? 'up' : 'down',
      progress: d.steps.current / d.steps.goal,
      context: `Goal: ${d.steps.goal.toLocaleString()} steps`,
    };
    case 'weight': return {
      value: d.weight.current, unit: 'kg',
      trend: `${(d.weight.current - d.weight.previous) > 0 ? '+' : ''}${(d.weight.current - d.weight.previous).toFixed(1)} kg`,
      trendDir: d.weight.current <= d.weight.previous ? 'up' : 'down',
      context: 'Trending down this week',
    };
    case 'recovery': return {
      value: d.recovery.score, unit: '/100',
      trend: d.recovery.score >= 75 ? 'High readiness' : 'Moderate readiness',
      trendDir: d.recovery.score >= 75 ? 'up' : 'neutral',
      progress: d.recovery.score / 100,
      context: 'Weekly pace avg: 78',
    };
    default: return { value: '—', unit: '' };
  }
}

const DEFAULT_LAYOUT = ['sleep', 'energy', 'calories_in', 'calories_out', 'water', 'heart_rate', 'resting_hr', 'steps', 'weight', 'recovery'];

export default function VitalsSheet({ open, onClose, data, insights }) {
  const [layout, setLayout] = useState(DEFAULT_LAYOUT);
  const [editMode, setEditMode] = useState(false);
  const [showAddPanel, setShowAddPanel] = useState(false);

  const coreWidgets = layout.filter(id => ALL_WIDGETS.find(w => w.id === id)?.group === 'core');
  const activityWidgets = layout.filter(id => ALL_WIDGETS.find(w => w.id === id)?.group === 'activity');
  const removedIds = ALL_WIDGETS.map(w => w.id).filter(id => !layout.includes(id));

  const handleDragEnd = (result) => {
    if (!result.destination) return;
    const items = Array.from(layout);
    const [removed] = items.splice(result.source.index, 1);
    items.splice(result.destination.index, 0, removed);
    setLayout(items);
  };

  const removeWidget = (id) => setLayout(prev => prev.filter(w => w !== id));
  const addWidget = (id) => { setLayout(prev => [...prev, id]); setShowAddPanel(false); };

  if (!open) return null;

  return (
    <AnimatePresence>
      <motion.div
        className="fixed inset-0 z-50 flex flex-col"
        style={{ background: '#fbf8f1' }}
        initial={{ y: '100%' }}
        animate={{ y: 0 }}
        exit={{ y: '100%' }}
        transition={{ type: 'spring', damping: 30, stiffness: 300 }}
      >
        {/* Header */}
        <div
          className="flex items-center justify-between px-5 pt-12 pb-4 flex-shrink-0"
          style={{ background: 'rgba(251,248,241,0.97)', backdropFilter: 'blur(20px)', borderBottom: '1px solid #e8e1d4' }}
        >
          <div>
            <h2 className="text-xl font-bold" style={{ color: '#141613' }}>Today's Vitals</h2>
            <p className="text-xs mt-0.5" style={{ color: '#91968e' }}>Detailed health snapshot</p>
          </div>
          <div className="flex items-center gap-2">
            <button
              onClick={() => { setEditMode(e => !e); setShowAddPanel(false); }}
              className="w-9 h-9 rounded-xl flex items-center justify-center border border-white/8"
              style={{ background: editMode ? 'rgba(200,224,0,0.12)' : '#f2efe7', outline: 'none' }}
            >
              <Settings2 size={16} style={{ color: editMode ? '#8ea400' : '#91968e' }} />
            </button>
            <button
              onClick={onClose}
              className="w-9 h-9 rounded-xl flex items-center justify-center"
              style={{ background: '#f2efe7', border: '1px solid #e8e1d4', outline: 'none' }}
            >
              <X size={16} style={{ color: '#91968e' }} />
            </button>
          </div>
        </div>

        {/* Scrollable content */}
        <div className="flex-1 overflow-y-auto px-5 py-4 pb-24 space-y-6">
          {editMode && (
            <motion.div
              initial={{ opacity: 0, y: -8 }}
              animate={{ opacity: 1, y: 0 }}
              className="p-3 rounded-2xl text-center text-xs border"
              style={{ background: 'rgba(200,224,0,0.06)', borderColor: 'rgba(200,224,0,0.2)', color: '#91968e' }}
            >
              Long press a widget to reorder · tap <span style={{ color: '#b05a3a' }}>–</span> to remove
            </motion.div>
          )}

          {/* CORE HEALTH */}
          <section>
            <div className="flex items-center justify-between mb-3">
              <div>
                <h3 className="text-sm font-semibold" style={{ color: '#141613' }}>Core Health</h3>
                <p className="text-[10px] mt-0.5" style={{ color: '#91968e' }}>Sleep · Energy · Nutrition · Hydration</p>
              </div>
            </div>

            <DragDropContext onDragEnd={handleDragEnd}>
              <Droppable droppableId="widgets" direction="horizontal">
                {(provided) => (
                  <div
                    ref={provided.innerRef}
                    {...provided.droppableProps}
                    className="grid grid-cols-2 gap-3"
                  >
                    {layout.map((id, index) => {
                      const meta = ALL_WIDGETS.find(w => w.id === id);
                      if (!meta || meta.group !== 'core') return null;
                      const widgetData = buildWidgetData(id, data);
                      return (
                        <Draggable key={id} draggableId={id} index={index} isDragDisabled={!editMode}>
                          {(prov, snap) => (
                            <div ref={prov.innerRef} {...prov.draggableProps}>
                              <VitalWidget
                                widget={{ ...meta, ...widgetData }}
                                editMode={editMode}
                                onRemove={() => removeWidget(id)}
                                dragHandleProps={prov.dragHandleProps}
                                isDragging={snap.isDragging}
                              />
                            </div>
                          )}
                        </Draggable>
                      );
                    })}
                    {provided.placeholder}
                  </div>
                )}
              </Droppable>
            </DragDropContext>
          </section>

          {/* ACTIVITY & BODY */}
          <section>
            <div className="mb-3">
              <h3 className="text-sm font-semibold" style={{ color: '#141613' }}>Activity & Body</h3>
              <p className="text-[10px] mt-0.5" style={{ color: '#91968e' }}>Steps · Weight · Recovery</p>
            </div>
            <div className="grid grid-cols-2 gap-3">
              {activityWidgets.map(id => {
                const meta = ALL_WIDGETS.find(w => w.id === id);
                if (!meta) return null;
                const widgetData = buildWidgetData(id, data);
                return (
                  <div key={id} className="relative">
                    {editMode && (
                      <button
                        onClick={() => removeWidget(id)}
                        className="absolute -top-2 -left-2 w-6 h-6 rounded-full flex items-center justify-center z-10"
                        style={{ background: '#b05a3a', border: '2px solid #fbf8f1' }}
                      >
                        <span className="text-white text-xs font-bold">–</span>
                      </button>
                    )}
                    <VitalWidget
                      widget={{ ...meta, ...widgetData }}
                      editMode={false}
                      onRemove={() => removeWidget(id)}
                    />
                  </div>
                );
              })}
            </div>
          </section>

          {/* Add Widget Button */}
          {editMode && (
            <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }}>
              <button
                onClick={() => setShowAddPanel(p => !p)}
                className="w-full flex items-center justify-center gap-2 py-3.5 rounded-2xl border border-dashed text-sm font-medium transition-colors"
                style={{ background: 'rgba(200,224,0,0.04)', borderColor: 'rgba(200,224,0,0.25)', color: '#8ea400' }}
              >
                <Plus size={16} />
                Add Widget
              </button>

              {showAddPanel && removedIds.length > 0 && (
                <motion.div
                  initial={{ opacity: 0, y: -8 }}
                  animate={{ opacity: 1, y: 0 }}
                  className="mt-3 p-4 rounded-2xl border"
                  style={{ background: '#ffffff', borderColor: '#e8e1d4' }}
                >
                  <p className="text-xs mb-3" style={{ color: '#91968e' }}>Available widgets</p>
                  <div className="grid grid-cols-2 gap-2">
                    {removedIds.map(id => {
                      const meta = ALL_WIDGETS.find(w => w.id === id);
                      if (!meta) return null;
                      return (
                        <button
                          key={id}
                          onClick={() => addWidget(id)}
                          className="flex items-center gap-2 p-3 rounded-xl border text-left transition-colors hover:opacity-80"
                          style={{ background: '#f2efe7', borderColor: '#e8e1d4' }}
                        >
                          <meta.icon size={14} style={{ color: '#8ea400' }} />
                          <span className="text-xs" style={{ color: '#141613' }}>{meta.label}</span>
                        </button>
                      );
                    })}
                  </div>
                </motion.div>
              )}
            </motion.div>
          )}

          {/* AI Coach Insights */}
          <section>
            <div className="mb-3">
              <h3 className="text-sm font-semibold" style={{ color: '#141613' }}>Coach Insights</h3>
              <p className="text-[10px] mt-0.5" style={{ color: '#91968e' }}>Synthesized from all your vitals</p>
            </div>
            <AICoachCard insights={insights} />
          </section>
        </div>

        {/* Bottom swipe indicator */}
        <div className="flex justify-center py-3 border-t flex-shrink-0" style={{ background: 'rgba(251,248,241,0.97)', borderColor: '#e8e1d4' }}>
          <button onClick={onClose} className="flex flex-col items-center gap-1">
            <div className="w-10 h-1 rounded-full" style={{ background: '#d9d1c2' }} />
            <span className="text-[10px] mt-1" style={{ color: '#91968e' }}>Swipe down to close</span>
          </button>
        </div>
      </motion.div>
    </AnimatePresence>
  );
}