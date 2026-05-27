import { useState, useEffect } from 'react';
import { DragDropContext, Droppable, Draggable } from '@hello-pangea/dnd';
import { motion, AnimatePresence } from 'framer-motion';
import { GripVertical, X, Plus } from 'lucide-react';
import CustomizableWidget from './CustomizableWidget';
import CustomizePanel from './CustomizePanel';
import { getWidgetMeta } from './pageLayouts';

export default function CustomizeWrapper({
  pageKey,
  layout,
  isCustomizing,
  onDone,
  onCancel,
  onStartCustomizing,
  widgetContent,
  className = '',
}) {
  const [showPanel, setShowPanel] = useState(false);

  // Safety net: always restore body styles if the drag was interrupted
  // (unmount, route change, error). Without this, touchAction:'none' can
  // get stuck on <body> and block every tap in the app, including the nav.
  useEffect(() => {
    return () => {
      document.body.style.overflow = '';
      document.body.style.touchAction = '';
    };
  }, []);

  const handleDone = () => {
    layout.commitSave();
    onDone();
  };

  const handleDragStart = () => {
    document.body.style.overflow = 'hidden';
    document.body.style.touchAction = 'none';
  };

  const handleDragEnd = (result) => {
    document.body.style.overflow = '';
    document.body.style.touchAction = '';
    if (!result.destination) return;
    const from = result.source.index;
    const to = result.destination.index;
    if (from !== to) layout.reorder(from, to);
  };

  if (!isCustomizing) {
    return (
      <div className={className}>
        {layout.widgetOrder.map((widgetId) => {
          const content = widgetContent[widgetId];
          if (!content) return null;
          return (
            <CustomizableWidget
              key={widgetId}
              widgetId={widgetId}
              isCustomizing={false}
              onStartCustomizing={onStartCustomizing}
            >
              {content}
            </CustomizableWidget>
          );
        })}
      </div>
    );
  }

  return (
    <>
      <DragDropContext onDragStart={handleDragStart} onDragEnd={handleDragEnd}>
        <Droppable droppableId="widgets">
          {(provided) => (
            <div
              className={className}
              ref={provided.innerRef}
              {...provided.droppableProps}
            >
              {layout.widgetOrder.map((widgetId, index) => {
                const content = widgetContent[widgetId];
                if (!content) return null;
                const meta = getWidgetMeta(pageKey, widgetId);
                return (
                  <Draggable key={widgetId} draggableId={widgetId} index={index}>
                    {(dragProvided, dragSnapshot) => (
                      <div
                        ref={dragProvided.innerRef}
                        {...dragProvided.draggableProps}
                        style={{
                          ...dragProvided.draggableProps.style,
                          marginBottom: 16,
                        }}
                      >
                        <EditWidget
                          widgetId={widgetId}
                          label={meta?.label || widgetId}
                          isDragging={dragSnapshot.isDragging}
                          onHide={layout.hideWidget}
                          dragHandleProps={dragProvided.dragHandleProps}
                        >
                          {content}
                        </EditWidget>
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

      {layout.hiddenWidgets.length > 0 && (
        <motion.button
          initial={{ opacity: 0, y: 8 }}
          animate={{ opacity: 1, y: 0 }}
          whileTap={{ scale: 0.96 }}
          onClick={() => setShowPanel(true)}
          className="w-full flex items-center justify-center gap-2 py-3.5 rounded-2xl border-2 border-dashed text-sm font-semibold mt-2"
          style={{ borderColor: 'rgba(200,224,0,0.4)', color: '#8ea400', background: 'rgba(200,224,0,0.04)' }}
        >
          <Plus size={15} />
          Add Widget
        </motion.button>
      )}

      <div className="flex items-center justify-between gap-3 mt-4 pb-2">
        <button
          onClick={layout.resetLayout}
          className="flex-1 py-3 rounded-2xl border text-sm font-semibold"
          style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#5d635d' }}
        >
          Reset
        </button>
        <button
          onClick={handleDone}
          className="flex-1 py-3 rounded-2xl text-sm font-bold"
          style={{ background: '#c8e000', color: '#141613' }}
        >
          Done
        </button>
      </div>

      <AnimatePresence>
        {showPanel && (
          <CustomizePanel
            pageKey={pageKey}
            hiddenWidgets={layout.hiddenWidgets}
            onShowWidget={layout.showWidget}
            onReset={layout.resetLayout}
            onDone={() => { setShowPanel(false); handleDone(); }}
            onCancel={() => setShowPanel(false)}
          />
        )}
      </AnimatePresence>
    </>
  );
}

function EditWidget({ widgetId, label, isDragging, onHide, dragHandleProps, children }) {
  return (
    <div
      className="relative rounded-2xl overflow-hidden"
      style={{
        background: '#ffffff',
        border: isDragging ? '2px solid rgba(200,224,0,0.6)' : '1px solid #e8e1d4',
        boxShadow: isDragging
          ? '0 16px 48px rgba(20,22,19,0.18), 0 4px 16px rgba(20,22,19,0.12)'
          : '0 2px 8px rgba(20,22,19,0.06)',
      }}
    >
      {/* Drag handle bar */}
      <div
        {...dragHandleProps}
        className="flex items-center justify-between px-3 py-2.5 cursor-grab active:cursor-grabbing"
        style={{
          background: 'rgba(200,224,0,0.1)',
          borderBottom: '1px solid rgba(200,224,0,0.18)',
          userSelect: 'none',
          WebkitUserSelect: 'none',
        }}
      >
        <div className="flex items-center gap-2">
          <GripVertical size={14} style={{ color: '#8ea400' }} />
          <span className="text-[10px] font-bold uppercase tracking-widest" style={{ color: '#8ea400' }}>
            {label}
          </span>
        </div>
        <button
          onMouseDown={e => e.stopPropagation()}
          onTouchStart={e => e.stopPropagation()}
          onClick={() => onHide(widgetId)}
          className="w-6 h-6 rounded-full flex items-center justify-center"
          style={{ background: 'rgba(176,90,58,0.12)', border: '1px solid rgba(176,90,58,0.25)' }}
        >
          <X size={10} style={{ color: '#b05a3a' }} />
        </button>
      </div>

      <div className="pointer-events-none select-none opacity-80 p-1">
        {children}
      </div>
    </div>
  );
}