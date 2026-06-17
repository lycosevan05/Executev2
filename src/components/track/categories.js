import { Moon, Flame, Droplets, Heart, Weight, SmilePlus, CheckSquare, Footprints } from 'lucide-react';

export const ACCENT = '#c8e000';
export const ACCENT_DARK = '#8ea400';

export const ALL_CATEGORIES = [
  { id: 'sleep',          icon: Moon,        label: 'Sleep',         unit: 'hours',  desc: 'Track nightly sleep duration' },
  { id: 'water',          icon: Droplets,    label: 'Water',         unit: 'liters', desc: 'Daily hydration' },
  { id: 'steps',          icon: Footprints,  label: 'Steps',         unit: 'steps',  desc: 'Daily step count' },
  { id: 'cals_burned',    icon: Flame,       label: 'Cals Burned',   unit: 'kcal',   desc: 'Calories burned from exercise' },
  { id: 'mood',           icon: Heart,       label: 'Mood',          unit: '/ 5',    desc: 'Emotional wellbeing check-in' },
  { id: 'weight',         icon: Weight,      label: 'Weight',        unit: 'kg',     desc: 'Body weight logging' },
  { id: 'energy',         icon: SmilePlus,   label: 'Energy',        unit: '/ 10',   desc: 'Subjective energy level' },
  { id: 'habits',         icon: CheckSquare, label: 'Habits',        unit: 'done',   desc: 'Daily habit completion' },
];

export const DEFAULT_ACTIVE = ['sleep', 'water', 'steps', 'cals_burned', 'mood', 'weight', 'energy', 'habits'];

export const habits = ['Morning hydration', 'No phone in bed', 'Stretch 10min', 'Read 15min', 'Cold shower', 'Meditation'];
