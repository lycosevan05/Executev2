import { useEffect, useRef, useState } from 'react';

export function usePullToRefresh() {
  const [isRefreshing] = useState(false);
  const containerRef = useRef(null);

  // Keep hook shape stable, but avoid custom touch interception that hurts iOS scrolling.
  useEffect(() => {}, []);

  return { containerRef, isRefreshing };
}