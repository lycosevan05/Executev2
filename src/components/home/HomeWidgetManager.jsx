import { GripVertical, CheckCircle2, Circle } from 'lucide-react';
import { DragDropContext, Droppable, Draggable } from '@hello-pangea/dnd';

export const ALL_HOME_WIDGETS = [
  { id: 'rings',     label: 'Today\'s Stats',   desc: 'Energy, calories & step rings', emoji: '⚡' },
  { id: 'steps',     label: 'Step Target',       desc: 'Daily step goal & progress',   emoji: '👟' },
  { id: 'missions',  label: 'Daily Missions',    desc: 'Exercise, sleep & nutrition',  emoji: '🎯' },
  { id: 'ai_coach',  label: 'Coach Insight',  desc: 'Personalised advice for today',emoji: '🧠' },
];

export const DEFAULT_HOME_LAYOUT = ['rings', 'missions'];

export default function HomeWidgetManager({ layout, onChange }) {
  const hiddenWidgets = ALL_HOME_WIDGETS.filter(w => !layout.includes(w.id));

  const handleDragEnd = (result) => {
    if (!result.destination) return;
    const items = [...layout];
    const [removed] = items.splice(result.source.index, 1);
    items.splice(result.destination.index, 0, removed);
    onChange(items);
  };

  const toggle = (id) => {
    if (layout.includes(id)) {
      onChange(layout.filter(w => w !== id));
    } else {
      onChange([...layout, id]);
    }
  };

  return (
    <div className="px-5 py-3">
      <p className="text-[11px] uppercase tracking-widest mb-3 font-semibold" style={{ color: '#91968e' }}>Visible · drag to reorder</p>

      <DragDropContext onDragEnd={handleDragEnd}>
        <Droppable droppableId="home-widgets">
          {(provided) => (
            <div ref={provided.innerRef} {...provided.droppableProps} className="space-y-2 mb-5">
              {layout.map((id, index) => {
                const meta = ALL_HOME_WIDGETS.find(w => w.id === id);
                if (!meta) return null;
                return (
                  <Draggable key={id} draggableId={id} index={index}>
                    {(prov, snap) => (
                      <div
                        ref={prov.innerRef}
                        {...prov.draggableProps}
                        className="flex items-center gap-3 p-3.5 rounded-2xl border border-white/5 select-none"
                        style={{
                          background: snap.isDragging ? 'rgba(200,224,0,0.06)' : '#ffffff',
                          borderColor: snap.isDragging ? 'rgba(200,224,0,0.25)' : '#e8e1d4',
                          ...prov.draggableProps.style,
                        }}
                      >
                        {/* Drag handle */}
                        <div {...prov.dragHandleProps} className="cursor-grab active:cursor-grabbing p-1">
                          <GripVertical size={14} style={{ color: '#d9d1c2' }} />
                        </div>
                        <span className="text-lg">{meta.emoji}</span>
                        <div className="flex-1 min-w-0">
                          <p className="text-sm font-semibold" style={{ color: '#141613' }}>{meta.label}</p>
                          <p className="text-[11px]" style={{ color: '#91968e' }}>{meta.desc}</p>
                        </div>
                        {/* Remove */}
                        <button onClick={() => toggle(id)} className="flex-shrink-0">
                          <CheckCircle2 size={20} style={{ color: '#8ea400' }} />
                        </button>
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

      {hiddenWidgets.length > 0 && (
        <>
          <p className="text-[11px] uppercase tracking-widest mb-3 font-semibold" style={{ color: '#91968e' }}>Hidden · tap to add</p>
          <div className="space-y-2">
            {hiddenWidgets.map(meta => (
              <button
                key={meta.id}
                onClick={() => toggle(meta.id)}
                className="flex items-center gap-3 w-full p-3.5 rounded-2xl border text-left"
                style={{ background: '#f2efe7', borderColor: '#e8e1d4' }}
              >
                <span className="text-lg">{meta.emoji}</span>
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-semibold" style={{ color: '#5d635d' }}>{meta.label}</p>
                  <p className="text-[11px]" style={{ color: '#91968e' }}>{meta.desc}</p>
                </div>
                <Circle size={20} style={{ color: '#d9d1c2' }} className="flex-shrink-0" />
              </button>
            ))}
          </div>
        </>
      )}
    </div>
  );
}