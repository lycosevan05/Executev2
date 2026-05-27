import { useRef } from 'react';

export default function CustomizableWidget({
  widgetId,
  isCustomizing,
  onStartCustomizing,
  children,
}) {
  const longPressTimer = useRef(null);

  const handlePointerDown = () => {
    if (isCustomizing || !onStartCustomizing) return;
    longPressTimer.current = setTimeout(() => {
      onStartCustomizing();
    }, 600);
  };

  const handlePointerUp = () => {
    clearTimeout(longPressTimer.current);
  };

  return (
    <div
      onPointerDown={handlePointerDown}
      onPointerUp={handlePointerUp}
      onPointerLeave={handlePointerUp}
      onPointerCancel={handlePointerUp}
      style={{ touchAction: 'pan-y' }}
    >
      {children}
    </div>
  );
}