import { QueryClient } from '@tanstack/react-query';

/**
 * Global React Query cache config.
 *
 * Previously every page-navigation refetched all data from scratch (staleTime
 * defaults to 0). That made the app feel like it "forgot" context every time
 * the user switched tabs. We now:
 *  - Keep data fresh for 60s (no refetch on remount within that window)
 *  - Keep cached data in memory for 30 minutes after unmount (instant return)
 *  - Disable refetch on window focus (avoids redundant loads when returning to the tab)
 *  - Disable refetch on reconnect (we still serve cached data immediately)
 */
export const queryClientInstance = new QueryClient({
	defaultOptions: {
		queries: {
			staleTime: 60 * 1000,           // 1 minute — pages reusing the same query won't refetch
			gcTime: 30 * 60 * 1000,         // 30 minutes — keep in memory across navigation
			refetchOnWindowFocus: false,
			refetchOnReconnect: false,
			refetchOnMount: false,          // use cache when remounting if still fresh
			retry: 1,
		},
	},
});