import { useLocation, useNavigate } from 'react-router-dom';
import { Home, UtensilsCrossed, Plus, Dumbbell, Sparkles } from 'lucide-react';
import { motion } from 'framer-motion';
import { useRef, useEffect, useCallback, useState } from 'react';

const TAB_ROOTS = ['/home', '/workouts', '/track', '/nutrition', '/plan'];

const navItems = [
  { path: '/home', icon: Home, label: 'Home' },
  { path: '/workouts', icon: Dumbbell, label: 'Train' },
  { path: '/track', icon: Plus, label: 'Track', isCenter: true },
  { path: '/nutrition', icon: UtensilsCrossed, label: 'Nutrition' },
  { path: '/plan', icon: Sparkles, label: 'Plan' },
];

const APP_ROUTES = [
  '/home', '/plan', '/track', '/insights', '/goals', '/profile', '/meals',
  '/workouts', '/recovery', '/nutrition', '/customize', '/log-food', '/my-week',
  '/tracking-history', '/personalize', '/onboarding', '/workout-session', '/progress', '/billing',
];

function getTabRoot(pathname) {
  if (pathname === '/') return '/home';
  return TAB_ROOTS.find(r => pathname.startsWith(r)) || null;
}

export default function AppShell({ children }) {
  const location = useLocation();
  const navigate = useNavigate();

  // scrollPositions[tabRoot] = scrollTop
  const scrollPositions = useRef({});
  // Per-tab history stacks: { [tabRoot]: string[] }
  const tabHistories = useRef({});
  const mainRef = useRef(null);
  const prevTabRef = useRef(null);
  const lastNavAtRef = useRef(0);

  const isAppRoute = location.pathname === '/' || APP_ROUTES.some(r => location.pathname.startsWith(r));
  const [hasBlockingOverlay, setHasBlockingOverlay] = useState(false);
  const [isCustomizing, setIsCustomizing] = useState(false);
  const hideNav = location.pathname.startsWith('/workout-session');
  const hideNavForModals = hasBlockingOverlay;
  const hideNavForCustomize = isCustomizing;
  const currentTab = getTabRoot(location.pathname);

  useEffect(() => {
    const handleOverlayChange = (event) => {
      setHasBlockingOverlay(Boolean(event.detail?.open));
    };

    window.addEventListener('execute:blocking-overlay', handleOverlayChange);
    return () => window.removeEventListener('execute:blocking-overlay', handleOverlayChange);
  }, []);

  useEffect(() => {
    const handleCustomizeChange = (event) => {
      const active = Boolean(event.detail?.active);
      setIsCustomizing(active);
      // Safety net: if customize mode ends, ensure body touch/overflow are
      // never left stuck from an interrupted drag (which would freeze all taps).
      if (!active) {
        document.body.style.overflow = '';
        document.body.style.touchAction = '';
      }
    };
    window.addEventListener('execute:customize-mode', handleCustomizeChange);
    return () => window.removeEventListener('execute:customize-mode', handleCustomizeChange);
  }, []);

  // Save scroll position of outgoing tab, restore for incoming tab
  useEffect(() => {
    const el = mainRef.current;
    if (!el) return;

    const prevTab = prevTabRef.current;

    // Save outgoing tab scroll
    if (prevTab && prevTab !== currentTab) {
      scrollPositions.current[prevTab] = el.scrollTop;
    }

    // Restore incoming tab scroll
    if (currentTab) {
      const saved = scrollPositions.current[currentTab] ?? 0;
      // Use rAF to ensure DOM has painted before restoring
      requestAnimationFrame(() => { el.scrollTop = saved; });
    }

    prevTabRef.current = currentTab;
  }, [location.pathname, currentTab]);

  // Track per-tab history so tapping an active tab pops back to root
  useEffect(() => {
    if (!currentTab) return;
    const stack = tabHistories.current[currentTab] || [];
    // Push if it's a new path
    if (stack[stack.length - 1] !== location.pathname) {
      tabHistories.current[currentTab] = [...stack, location.pathname];
    }
  }, [location.pathname, currentTab]);

  const handleTabPress = useCallback((path) => {
    const now = Date.now();
    if (now - lastNavAtRef.current < 450) return;
    lastNavAtRef.current = now;

    const isActive = location.pathname === path || location.pathname.startsWith(path + '/');

    if (isActive) {
      // Tap active tab → go back to root of this tab
      const stack = tabHistories.current[path] || [];
      if (stack.length > 1) {
        // Reset stack and navigate to root
        tabHistories.current[path] = [path];
        scrollPositions.current[path] = 0;
        navigate(path, { replace: true });
      } else {
        // Already at root — scroll to top
        if (mainRef.current) mainRef.current.scrollTop = 0;
        scrollPositions.current[path] = 0;
      }
    } else {
      navigate(path);
    }
  }, [location.pathname, navigate]);

  if (!isAppRoute) return children;

  return (
    <div className="min-h-screen font-inter flex flex-col max-w-md mx-auto relative" style={{ background: '#f6f2e8' }}>
      <main ref={mainRef} className={`ios-scroll flex-1 ${hideNav ? 'safe-bottom' : 'pb-20'}`}>
        {children}
      </main>

      {/* Bottom Navigation */}
      {!hideNav && !hideNavForModals && !hideNavForCustomize && (
        <nav className="fixed bottom-0 left-1/2 -translate-x-1/2 z-50 pb-safe pt-1">
          <div className="flex items-center justify-center pb-0 px-5 w-screen">
            <div className="flex items-center justify-around px-2.5 py-2 rounded-full w-full max-w-sm" style={{ background: '#ffffff', boxShadow: '0 8px 32px rgba(20,22,19,0.15), 0 2px 8px rgba(20,22,19,0.08)', border: '1px solid rgba(200,224,0,0.08)' }}>
              {navItems.map(({ path, icon: Icon, label, isCenter }) => {
              const isActive = location.pathname === path || (!isCenter && location.pathname.startsWith(path + '/'));

              if (isCenter) {
                return (
                  <button key={path} onClick={() => handleTabPress(path)} className="relative flex flex-col items-center">
                    <motion.div
                      whileTap={{ scale: 0.92 }}
                      className="w-10 h-10 rounded-full flex items-center justify-center"
                      style={{
                        background: '#c8e000',
                        boxShadow: '0 4px 16px rgba(200,224,0,0.4)',
                      }}
                    >
                      <Icon size={18} style={{ color: '#141613' }} />
                    </motion.div>
                    <span className="text-[8.5px] mt-0.5 font-medium leading-none" style={{ color: '#91968e' }}>{label}</span>
                  </button>
                );
              }

              return (
                <button key={path} onClick={() => handleTabPress(path)} className="relative flex flex-col items-center min-w-[46px] justify-center">
                  <motion.div whileTap={{ scale: 0.85 }} className="flex flex-col items-center justify-center">
                    <Icon size={18} style={{ color: isActive ? '#c8e000' : '#a09a90' }} />
                    <span className="text-[8.5px] mt-0.5 font-medium leading-none" style={{ color: isActive ? '#c8e000' : '#a09a90' }}>
                      {label}
                    </span>
                  </motion.div>
                </button>
              );
              })}
              </div>
              </div>
              </nav>
              )}
    </div>
  );
}