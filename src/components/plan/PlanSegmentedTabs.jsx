const TABS = [
  { id: 'week', label: 'This Week', icon: '📅' },
  { id: 'longterm', label: 'Long-Term', icon: '📈' },
  { id: 'adjustments', label: 'Adjustments', icon: '⚙️' },
];

export default function PlanSegmentedTabs({ activeTab, onChange }) {
  return (
    <div className="flex gap-1 p-1 rounded-2xl" style={{ background: '#ede9df' }}>
      {TABS.map(tab => (
        <button
          key={tab.id}
          onClick={() => onChange(tab.id)}
          className="flex-1 py-2.5 rounded-xl text-xs font-semibold transition-all"
          style={{
            background: activeTab === tab.id ? '#ffffff' : 'transparent',
            color: activeTab === tab.id ? '#141613' : '#91968e',
            boxShadow: activeTab === tab.id ? '0 1px 4px rgba(20,22,19,0.08)' : 'none',
          }}
        >
          {tab.label}
        </button>
      ))}
    </div>
  );
}