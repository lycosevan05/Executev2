import { useState, useEffect, useCallback } from 'react';
import { backend } from '@/api/backendClient';
import { getDefaultOrder } from './pageLayouts';

// Simple in-memory cache to avoid redundant fetches
const layoutCache = {};

export function usePageLayout(pageKey) {
  const [widgetOrder, setWidgetOrder] = useState(() => getDefaultOrder(pageKey));
  const [hiddenWidgets, setHiddenWidgets] = useState([]);
  const [recordId, setRecordId] = useState(null);
  const [loading, setLoading] = useState(true);

  // Load saved layout on mount
  useEffect(() => {
    let cancelled = false;
    async function load() {
      try {
        const user = await backend.auth.me();
        if (!user || cancelled) return;

        const cacheKey = `${user.id}_${pageKey}`;
        if (layoutCache[cacheKey]) {
          const cached = layoutCache[cacheKey];
          setWidgetOrder(cached.widgetOrder);
          setHiddenWidgets(cached.hiddenWidgets);
          setRecordId(cached.recordId);
          setLoading(false);
          return;
        }

        const records = await backend.entities.UserPageLayout.filter({
          user_id: user.id,
          page_key: pageKey,
        });

        if (!cancelled && records.length > 0) {
          const rec = records[0];
          const defaultOrder = getDefaultOrder(pageKey);

          // Merge saved order with defaults (handle new widgets added later)
          const savedOrder = (rec.widget_order || []).filter(id => defaultOrder.includes(id));
          const newWidgets = defaultOrder.filter(
            id => !savedOrder.includes(id) && !(rec.hidden_widgets || []).includes(id)
          );
          const mergedOrder = [...savedOrder, ...newWidgets];

          const finalOrder = mergedOrder.length > 0 ? mergedOrder : defaultOrder;
          const finalHidden = (rec.hidden_widgets || []).filter(id => defaultOrder.includes(id));

          setWidgetOrder(finalOrder);
          setHiddenWidgets(finalHidden);
          setRecordId(rec.id);

          layoutCache[cacheKey] = {
            widgetOrder: finalOrder,
            hiddenWidgets: finalHidden,
            recordId: rec.id,
          };
        }
      } catch (e) {
        // silently fall back to defaults
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    load();
    return () => { cancelled = true; };
  }, [pageKey]);

  const saveLayout = useCallback(async (newOrder, newHidden) => {
    try {
      const user = await backend.auth.me();
      if (!user) return;

      const cacheKey = `${user.id}_${pageKey}`;
      layoutCache[cacheKey] = { widgetOrder: newOrder, hiddenWidgets: newHidden, recordId };

      const payload = {
        user_id: user.id,
        page_key: pageKey,
        widget_order: newOrder,
        hidden_widgets: newHidden,
      };

      if (recordId) {
        await backend.entities.UserPageLayout.update(recordId, payload);
      } else {
        const created = await backend.entities.UserPageLayout.create(payload);
        setRecordId(created.id);
        layoutCache[cacheKey].recordId = created.id;
      }
    } catch (e) {
      // fail silently — layout is still correct in memory
    }
  }, [pageKey, recordId]);

  // Drag-and-drop reorder
  const reorder = useCallback((fromIndex, toIndex) => {
    setWidgetOrder(prev => {
      const next = [...prev];
      const [moved] = next.splice(fromIndex, 1);
      next.splice(toIndex, 0, moved);
      return next;
    });
  }, []);

  const moveUp = useCallback((widgetId) => {
    setWidgetOrder(prev => {
      const idx = prev.indexOf(widgetId);
      if (idx <= 0) return prev;
      const next = [...prev];
      [next[idx - 1], next[idx]] = [next[idx], next[idx - 1]];
      return next;
    });
  }, []);

  const moveDown = useCallback((widgetId) => {
    setWidgetOrder(prev => {
      const idx = prev.indexOf(widgetId);
      if (idx < 0 || idx >= prev.length - 1) return prev;
      const next = [...prev];
      [next[idx], next[idx + 1]] = [next[idx + 1], next[idx]];
      return next;
    });
  }, []);

  const hideWidget = useCallback((widgetId) => {
    setWidgetOrder(prev => prev.filter(id => id !== widgetId));
    setHiddenWidgets(prev => prev.includes(widgetId) ? prev : [...prev, widgetId]);
  }, []);

  const showWidget = useCallback((widgetId) => {
    setHiddenWidgets(prev => prev.filter(id => id !== widgetId));
    setWidgetOrder(prev => prev.includes(widgetId) ? prev : [...prev, widgetId]);
  }, []);

  const resetLayout = useCallback(() => {
    const defaultOrder = getDefaultOrder(pageKey);
    setWidgetOrder(defaultOrder);
    setHiddenWidgets([]);
  }, [pageKey]);

  const commitSave = useCallback(() => {
    saveLayout(widgetOrder, hiddenWidgets);
  }, [saveLayout, widgetOrder, hiddenWidgets]);

  return {
    widgetOrder,
    hiddenWidgets,
    loading,
    reorder,
    moveUp,
    moveDown,
    hideWidget,
    showWidget,
    resetLayout,
    commitSave,
  };
}