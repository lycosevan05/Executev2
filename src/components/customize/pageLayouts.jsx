// Default widget definitions per page
// Each widget has: id, label, description

export const PAGE_LAYOUTS = {
  home: {
    label: 'Home',
    widgets: [
      { id: 'ai_summary', label: 'Coach Insight', description: 'Personalized coaching summary' },
      { id: 'macro_tracker', label: 'Macro Tracker', description: 'Protein, carbs, and fat progress' },
      { id: 'calorie_balance', label: 'Calorie Balance', description: 'Calories eaten vs burned' },
      { id: 'quick_links', label: 'Quick Links', description: 'Plan and Recovery shortcuts' },
      { id: 'vitals_row', label: 'Daily Vitals', description: 'Sleep, steps, water row' },
      { id: 'score_row', label: 'Recovery & Energy', description: 'Recovery and energy score cards' },
      { id: 'today_plan', label: "Today's Plan", description: 'Daily task checklist' },
      { id: 'progress_snapshot', label: 'Progress Snapshot', description: 'Quick summary of goal progress' },
      { id: 'top_action', label: 'Best Action', description: 'Top recommended action right now' },
    ],
  },
  track: {
    label: 'Track',
    widgets: [
      { id: 'food_logger', label: 'Food Logger', description: 'Quick link to describe food and estimate macros' },
      { id: 'date_header', label: 'Date Header', description: 'Current date display' },
      { id: 'category_grid', label: 'Tracking Categories', description: 'All tracking category tiles' },
      { id: 'completion', label: 'Logging Progress', description: "Today's logging completion bar" },
    ],
  },
  workouts: {
    label: 'Workouts',
    widgets: [
      { id: 'today_workout', label: "Today's Workout", description: 'Current planned workout' },
      { id: 'exercise_library', label: 'Exercise Library', description: 'Browse all exercises' },
      { id: 'workout_history', label: 'Workout History', description: 'Recent workout logs' },
    ],
  },
  nutrition: {
    label: 'Nutrition',
    widgets: [
      { id: 'macro_targets', label: 'Macro Targets', description: 'Daily calorie and macro progress' },
      { id: 'meal_cards', label: 'Meal Cards', description: 'Breakfast, lunch, dinner, snack' },
    ],
  },
  meals: {
    label: 'Meals',
    widgets: [
      { id: 'meal_plan', label: 'Meal Plan', description: 'Personalized daily meal plan' },
      { id: 'grocery_list', label: 'Grocery List', description: 'Shopping list from meal plan' },
    ],
  },
  recovery: {
    label: 'Recovery',
    widgets: [
      { id: 'checkin', label: 'Readiness Check-in', description: 'Daily readiness metrics' },
      { id: 'limitations', label: 'Injury & Limitations', description: 'Manage physical limitations' },
    ],
  },
  plan: {
    label: 'Plan',
    widgets: [
      { id: 'guidance_sections', label: 'Guidance Sections', description: 'Nutrition, workout, recovery, sleep guidance' },
      { id: 'goal_progress', label: 'Goal Progress', description: 'Active goals overview' },
    ],
  },
  insights: {
    label: 'Insights',
    widgets: [
      { id: 'summary_tiles', label: 'Summary Tiles', description: 'Steps, sleep, recovery, energy tiles' },
      { id: 'ai_insights', label: 'Performance Insights', description: 'Personalized pattern analysis' },
      { id: 'nutrient_tracking', label: 'Nutrient Tracking', description: '20-nutrient progress tracking' },
      { id: 'steps_chart', label: 'Steps Chart', description: 'Weekly steps bar chart' },
      { id: 'sleep_chart', label: 'Sleep Chart', description: 'Sleep duration area chart' },
      { id: 'energy_chart', label: 'Energy Chart', description: 'Energy score area chart' },
      { id: 'forecast', label: 'Forecast', description: 'At current pace projection' },
    ],
  },
  goals: {
    label: 'Goals',
    widgets: [
      { id: 'goals_list', label: 'Goals List', description: 'All active and completed goals' },
    ],
  },
  profile: {
    label: 'Profile',
    widgets: [
      { id: 'avatar_card', label: 'Profile Card', description: 'Avatar, name, stats' },
      { id: 'active_goals_preview', label: 'Active Goals', description: 'Active goals preview' },
      { id: 'customize_sections', label: 'Customization Menu', description: 'Goals, nutrition, workout, coaching settings' },
    ],
  },
};

export function getDefaultOrder(pageKey) {
  return (PAGE_LAYOUTS[pageKey]?.widgets || []).map(w => w.id);
}

export function getWidgetMeta(pageKey, widgetId) {
  return (PAGE_LAYOUTS[pageKey]?.widgets || []).find(w => w.id === widgetId);
}