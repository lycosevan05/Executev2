export default function MealIngredients({ ingredients = [] }) {
  const safeIngredients = Array.isArray(ingredients) ? ingredients.filter(Boolean) : [];

  if (safeIngredients.length === 0) return null;

  return (
    <div className="mb-2.5 rounded-2xl border px-3 py-3" style={{ background: '#fbf8f1', borderColor: '#e8e1d4' }}>
      <div className="flex items-center justify-between mb-2">
        <p className="text-[10px] font-bold uppercase tracking-widest" style={{ color: '#91968e' }}>Ingredients</p>
        <span className="text-[10px] font-semibold px-2 py-0.5 rounded-full" style={{ background: '#f2efe7', color: '#5d635d' }}>
          {safeIngredients.length} items
        </span>
      </div>
      <div className="flex flex-wrap gap-1.5">
        {safeIngredients.map((ingredient, index) => (
          <span
            key={`${ingredient}-${index}`}
            className="px-2.5 py-1 rounded-full text-[10px] leading-tight"
            style={{ background: '#ffffff', color: '#5d635d', border: '1px solid #e8e1d4' }}
          >
            {ingredient}
          </span>
        ))}
      </div>
    </div>
  );
}