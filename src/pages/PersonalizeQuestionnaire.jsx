import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { motion, AnimatePresence } from 'framer-motion';
import { ChevronLeft, ChevronRight, Check, Upload, X, Loader2, Sparkles } from 'lucide-react';
import { backend } from '@/api/backendClient';
import { saveUserProfile, saveWorkoutProfile } from '@/lib/personalizationSync';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

const SPORTS = [
  'Running', 'Cycling', 'Swimming', 'Weightlifting', 'CrossFit',
  'Football', 'Basketball', 'Tennis', 'Martial Arts', 'Yoga',
  'Triathlon', 'Rowing', 'Climbing', 'Golf', 'General Fitness',
];

const GOALS = [
  { id: 'lose_fat', label: 'Lose body fat' },
  { id: 'build_muscle', label: 'Build muscle' },
  { id: 'get_stronger', label: 'Get stronger' },
  { id: 'improve_fitness', label: 'Improve fitness' },
  { id: 'improve_endurance', label: 'Build endurance' },
  { id: 'feel_better', label: 'Feel more energetic' },
];

const STEPS = [
  'basics',
  'body',
  'sport',
  'goals',
  'extra',
];

function OptionChip({ label, selected, onClick }) {
  return (
    <button
      onClick={onClick}
      className="px-4 py-2.5 rounded-2xl border text-sm font-medium transition-all"
      style={{
        background: selected ? 'rgba(200,224,0,0.12)' : '#ffffff',
        borderColor: selected ? 'rgba(200,224,0,0.5)' : '#e8e1d4',
        color: selected ? ACCENT_DARK : '#5d635d',
      }}
    >
      {label}
    </button>
  );
}

function StepBasics({ data, onChange }) {
  return (
    <div className="space-y-5">
      <div>
        <label className="text-xs font-bold uppercase tracking-widest block mb-2" style={{ color: '#91968e' }}>Your name</label>
        <input
          type="text"
          value={data.name || ''}
          onChange={e => onChange({ name: e.target.value })}
          placeholder="First name"
          className="w-full px-4 py-3.5 rounded-2xl border text-sm outline-none"
          style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
        />
      </div>
      <div>
        <label className="text-xs font-bold uppercase tracking-widest block mb-2" style={{ color: '#91968e' }}>What should we call you?</label>
        <input
          type="text"
          value={data.nickname || ''}
          onChange={e => onChange({ nickname: e.target.value })}
          placeholder="e.g. Ev, Coach, Big E…"
          className="w-full px-4 py-3.5 rounded-2xl border text-sm outline-none"
          style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
        />
        <p className="text-xs mt-1.5" style={{ color: '#91968e' }}>This is how Execute will address you in coaching messages.</p>
      </div>
      <div className="grid grid-cols-2 gap-3">
        <div>
          <label className="text-xs font-bold uppercase tracking-widest block mb-2" style={{ color: '#91968e' }}>Age</label>
          <input
            type="number"
            value={data.age || ''}
            onChange={e => onChange({ age: e.target.value })}
            placeholder="e.g. 28"
            className="w-full px-4 py-3.5 rounded-2xl border text-sm outline-none"
            style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
          />
        </div>
        <div>
          <label className="text-xs font-bold uppercase tracking-widest block mb-2" style={{ color: '#91968e' }}>Sex</label>
          <div className="flex gap-2">
            {['Male', 'Female', 'Other'].map(s => (
              <button
                key={s}
                onClick={() => onChange({ sex: s.toLowerCase() })}
                className="flex-1 py-3.5 rounded-2xl border text-xs font-semibold transition-all"
                style={{
                  background: data.sex === s.toLowerCase() ? 'rgba(200,224,0,0.12)' : '#ffffff',
                  borderColor: data.sex === s.toLowerCase() ? 'rgba(200,224,0,0.5)' : '#e8e1d4',
                  color: data.sex === s.toLowerCase() ? ACCENT_DARK : '#5d635d',
                }}
              >
                {s}
              </button>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

function StepBody({ data, onChange }) {
  return (
    <div className="space-y-5">
      <div>
        <label className="text-xs font-bold uppercase tracking-widest block mb-2" style={{ color: '#91968e' }}>Your name</label>
        <input
          type="text"
          value={data.name || ''}
          onChange={e => onChange({ name: e.target.value })}
          placeholder="First name"
          className="w-full px-4 py-3.5 rounded-2xl border text-sm outline-none"
          style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
        />
      </div>
      <div className="grid grid-cols-2 gap-3">
        <div>
          <label className="text-xs font-bold uppercase tracking-widest block mb-2" style={{ color: '#91968e' }}>Height (cm)</label>
          <input
            type="number"
            value={data.height_cm || ''}
            onChange={e => onChange({ height_cm: e.target.value })}
            placeholder="e.g. 178"
            className="w-full px-4 py-3.5 rounded-2xl border text-sm outline-none"
            style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
          />
        </div>
        <div>
          <label className="text-xs font-bold uppercase tracking-widest block mb-2" style={{ color: '#91968e' }}>Weight (kg)</label>
          <input
            type="number"
            value={data.weight_kg || ''}
            onChange={e => onChange({ weight_kg: e.target.value })}
            placeholder="e.g. 80"
            className="w-full px-4 py-3.5 rounded-2xl border text-sm outline-none"
            style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613' }}
          />
        </div>
      </div>
      <div>
        <label className="text-xs font-bold uppercase tracking-widest block mb-2" style={{ color: '#91968e' }}>Fitness level</label>
        <div className="flex gap-2">
          {['Beginner', 'Intermediate', 'Advanced'].map(l => (
            <button
              key={l}
              onClick={() => onChange({ fitness_level: l.toLowerCase() })}
              className="flex-1 py-3.5 rounded-2xl border text-xs font-semibold transition-all"
              style={{
                background: data.fitness_level === l.toLowerCase() ? 'rgba(200,224,0,0.12)' : '#ffffff',
                borderColor: data.fitness_level === l.toLowerCase() ? 'rgba(200,224,0,0.5)' : '#e8e1d4',
                color: data.fitness_level === l.toLowerCase() ? ACCENT_DARK : '#5d635d',
              }}
            >
              {l}
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

function StepSport({ data, onChange }) {
  const selected = data.sports || [];
  const toggle = (sport) => {
    const next = selected.includes(sport)
      ? selected.filter(s => s !== sport)
      : [...selected, sport];
    onChange({ sports: next });
  };

  return (
    <div className="space-y-4">
      <p className="text-sm" style={{ color: '#91968e' }}>Select all that apply — this helps us tailor workouts and recovery.</p>
      <div className="flex flex-wrap gap-2">
        {SPORTS.map(sport => (
          <OptionChip
            key={sport}
            label={sport}
            selected={selected.includes(sport)}
            onClick={() => toggle(sport)}
          />
        ))}
      </div>
    </div>
  );
}

function StepGoals({ data, onChange }) {
  const selected = data.goals || [];
  const toggle = (id) => {
    const next = selected.includes(id)
      ? selected.filter(g => g !== id)
      : [...selected, id];
    onChange({ goals: next });
  };

  return (
    <div className="space-y-3">
      <p className="text-sm" style={{ color: '#91968e' }}>Pick your top priorities.</p>
      {GOALS.map(g => (
        <button
          key={g.id}
          onClick={() => toggle(g.id)}
          className="w-full flex items-center justify-between px-4 py-4 rounded-2xl border text-left transition-all"
          style={{
            background: selected.includes(g.id) ? 'rgba(200,224,0,0.08)' : '#ffffff',
            borderColor: selected.includes(g.id) ? 'rgba(200,224,0,0.45)' : '#e8e1d4',
          }}
        >
          <span className="text-sm font-medium" style={{ color: '#141613' }}>{g.label}</span>
          {selected.includes(g.id) && (
            <div className="w-5 h-5 rounded-full flex items-center justify-center flex-shrink-0" style={{ background: ACCENT }}>
              <Check size={11} style={{ color: '#141613' }} />
            </div>
          )}
        </button>
      ))}
    </div>
  );
}

function StepExtra({ data, onChange }) {
  const [uploading, setUploading] = useState(false);

  const handleFileUpload = async (e) => {
    const file = e.target.files?.[0];
    if (!file) return;
    setUploading(true);
    try {
      const { file_url } = await backend.integrations.Core.UploadFile({ file });
      onChange({ file_url, file_name: file.name });
    } catch (err) {
      console.warn('Upload failed', err);
    } finally {
      setUploading(false);
    }
  };

  return (
    <div className="space-y-5">
      <div>
        <label className="text-xs font-bold uppercase tracking-widest block mb-2" style={{ color: '#91968e' }}>
          Add context for Execute
        </label>
        <textarea
          value={data.extra_notes || ''}
          onChange={e => onChange({ extra_notes: e.target.value })}
          placeholder="e.g. I have a lower back issue, I train in the morning, I'm prepping for a race in June, I'm vegetarian..."
          rows={5}
          className="w-full px-4 py-3.5 rounded-2xl border text-sm outline-none resize-none"
          style={{ background: '#ffffff', borderColor: '#e8e1d4', color: '#141613', lineHeight: 1.6 }}
        />
      </div>

      <div>
        <label className="text-xs font-bold uppercase tracking-widest block mb-2" style={{ color: '#91968e' }}>
          Upload a file (optional)
        </label>
        <p className="text-xs mb-3" style={{ color: '#91968e' }}>
          DEXA scan, blood work, injury report, training plan, or anything that helps Execute tailor your plan more precisely.
        </p>

        {data.file_url ? (
          <div className="flex items-center gap-3 px-4 py-3.5 rounded-2xl border"
            style={{ background: 'rgba(200,224,0,0.06)', borderColor: 'rgba(200,224,0,0.35)' }}>
            <Check size={14} style={{ color: ACCENT_DARK }} />
            <span className="text-sm font-medium flex-1 truncate" style={{ color: '#141613' }}>{data.file_name}</span>
            <button onClick={() => onChange({ file_url: null, file_name: null })}>
              <X size={14} style={{ color: '#91968e' }} />
            </button>
          </div>
        ) : (
          <label className="flex flex-col items-center justify-center gap-2 py-8 rounded-2xl border-2 border-dashed cursor-pointer transition-all hover:border-[#c8e000]"
            style={{ borderColor: '#d9d1c2', background: '#ffffff' }}>
            {uploading
              ? <Loader2 size={20} className="animate-spin" style={{ color: ACCENT_DARK }} />
              : <Upload size={20} style={{ color: '#91968e' }} />}
            <span className="text-sm font-medium" style={{ color: '#91968e' }}>
              {uploading ? 'Uploading…' : 'Tap to upload'}
            </span>
            <span className="text-xs" style={{ color: '#b8b4ac' }}>PDF, PNG, JPG, CSV</span>
            <input type="file" className="hidden" accept=".pdf,.png,.jpg,.jpeg,.csv,.xlsx"
              onChange={handleFileUpload} disabled={uploading} />
          </label>
        )}
      </div>
    </div>
  );
}

const STEP_CONFIG = {
  basics: { title: 'Tell us about you', subtitle: 'Basic info to personalize your experience.' },
  body: { title: 'Your body stats', subtitle: 'Used to calculate targets and recommendations.' },
  sport: { title: 'What do you do?', subtitle: 'Choose your sports or activities.' },
  goals: { title: 'What do you want?', subtitle: 'Your goals drive every recommendation.' },
  extra: { title: 'Anything else?', subtitle: 'Add more context for better recommendations.' },
};

export default function PersonalizeQuestionnaire() {
  const navigate = useNavigate();
  const [stepIndex, setStepIndex] = useState(0);
  const [saving, setSaving] = useState(false);
  const [data, setData] = useState({
    name: '', nickname: '', age: '', sex: '',
    height_cm: '', weight_kg: '', fitness_level: '',
    sports: [], goals: [],
    extra_notes: '', file_url: null, file_name: null,
  });

  const step = STEPS[stepIndex];
  const config = STEP_CONFIG[step];
  const isLast = stepIndex === STEPS.length - 1;

  const update = (partial) => setData(prev => ({ ...prev, ...partial }));

  const handleNext = async () => {
    if (!isLast) {
      setStepIndex(i => i + 1);
      return;
    }
    // Save on final step
    setSaving(true);
    try {
      const profileUpdates = {
        onboarding_complete: true,
        plan_questionnaire_completed: true,
        plan_questionnaire_completed_at: new Date().toISOString(),
      };
      if (data.name) profileUpdates.display_name = data.name;
      if (data.nickname) profileUpdates.display_name = data.nickname;
      if (data.age) profileUpdates.age = Number(data.age);
      if (data.sex) profileUpdates.sex = data.sex;
      if (data.height_cm) profileUpdates.height_cm = Number(data.height_cm);
      if (data.weight_kg) profileUpdates.weight_kg = Number(data.weight_kg);
      if (data.fitness_level) profileUpdates.fitness_level = data.fitness_level;

      await saveUserProfile(profileUpdates);

      if (data.sports.length > 0 || data.extra_notes) {
        await saveWorkoutProfile({
          workout_styles: data.sports,
          limitations_summary: data.extra_notes || '',
        });
      }

      if (data.goals.length > 0) {
        const GOAL_LABEL = {
          lose_fat: 'Lose body fat', build_muscle: 'Build muscle',
          get_stronger: 'Get stronger', improve_fitness: 'Improve fitness',
          improve_endurance: 'Build endurance', feel_better: 'Feel more energetic',
        };
        for (const gId of data.goals) {
          await backend.entities.Goal.create({
            title: GOAL_LABEL[gId] || gId,
            category: 'fitness',
            status: 'active',
            source: 'personalize_questionnaire',
          }).catch(() => {});
        }
      }

      // Navigate to plan creation
      navigate('/plan?generate=true');
    } catch (err) {
      console.error('Save failed', err);
    } finally {
      setSaving(false);
    }
  };

  const progress = ((stepIndex + 1) / STEPS.length) * 100;

  return (
    <div className="min-h-screen flex flex-col" style={{ background: '#f6f2e8' }}>
      {/* Header */}
      <div className="flex items-center justify-between px-5 pb-4" style={{ paddingTop: 'max(3.5rem, calc(env(safe-area-inset-top) + 1.25rem))' }}>
        <button
          onClick={() => stepIndex === 0 ? navigate('/home') : setStepIndex(i => i - 1)}
          className="w-9 h-9 rounded-xl flex items-center justify-center border"
          style={{ background: '#ffffff', borderColor: '#e8e1d4' }}
        >
          <ChevronLeft size={16} style={{ color: '#5d635d' }} />
        </button>
        <span className="text-xs font-semibold" style={{ color: '#91968e' }}>
          {stepIndex + 1} of {STEPS.length}
        </span>
        <div style={{ width: 36 }} />
      </div>

      {/* Progress bar */}
      <div className="px-5 mb-6">
        <div className="h-1.5 rounded-full overflow-hidden" style={{ background: '#e8e1d4' }}>
          <motion.div
            className="h-full rounded-full"
            style={{ background: ACCENT }}
            animate={{ width: `${progress}%` }}
            transition={{ duration: 0.4 }}
          />
        </div>
      </div>

      {/* Content */}
      <div className="flex-1 px-5 overflow-y-auto pb-32">
        <AnimatePresence mode="wait">
          <motion.div
            key={step}
            initial={{ opacity: 0, x: 20 }}
            animate={{ opacity: 1, x: 0 }}
            exit={{ opacity: 0, x: -20 }}
            transition={{ duration: 0.22 }}
          >
            <div className="mb-7">
              <h1 className="text-2xl font-black tracking-tight mb-1" style={{ color: '#141613' }}>
                {config.title}
              </h1>
              <p className="text-sm" style={{ color: '#91968e' }}>{config.subtitle}</p>
            </div>

            {step === 'basics' && <StepBasics data={data} onChange={update} />}
            {step === 'body' && <StepBody data={data} onChange={update} />}
            {step === 'sport' && <StepSport data={data} onChange={update} />}
            {step === 'goals' && <StepGoals data={data} onChange={update} />}
            {step === 'extra' && <StepExtra data={data} onChange={update} />}
          </motion.div>
        </AnimatePresence>
      </div>

      {/* Footer CTA */}
      <div className="fixed bottom-0 left-0 right-0 px-5 py-4"
        style={{ background: 'rgba(246,242,232,0.96)', backdropFilter: 'blur(20px)', borderTop: '1px solid #e8e1d4', paddingBottom: 'max(1rem, env(safe-area-inset-bottom))' }}>
        <button
          onClick={handleNext}
          disabled={saving}
          className="w-full py-4 rounded-2xl text-sm font-bold flex items-center justify-center gap-2 transition-all"
          style={{ background: saving ? 'rgba(200,224,0,0.5)' : ACCENT, color: '#141613' }}
        >
          {saving ? (
            <><Loader2 size={15} className="animate-spin" /> Saving…</>
          ) : isLast ? (
            <><Sparkles size={15} /> Build my plan</>
          ) : (
            <>Continue <ChevronRight size={15} /></>
          )}
        </button>
      </div>
    </div>
  );
}