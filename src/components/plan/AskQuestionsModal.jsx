import { useState, useRef, useEffect } from 'react';
import { createPortal } from 'react-dom';
import { motion } from 'framer-motion';
import { X, Send, Loader2, Sparkles } from 'lucide-react';
import { backend } from '@/api/backendClient';
import { getUserAIContext } from '@/lib/aiContext';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';

export default function AskQuestionsModal({ onClose, planContext }) {
  const [messages, setMessages] = useState([
    {
      role: 'assistant',
      content: "Hey! I'm your personal coach. Ask me anything about your training, nutrition, recovery, or health — I have your full profile and data.",
    },
  ]);
  const [input, setInput] = useState('');
  const [loading, setLoading] = useState(false);
  const [aiCtx, setAiCtx] = useState('');
  const bottomRef = useRef(null);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages]);

  useEffect(() => {
    getUserAIContext().then(ctx => setAiCtx(ctx)).catch(() => {});
  }, []);

  const sendMessage = async () => {
    const text = input.trim();
    if (!text || loading) return;

    const userMsg = { role: 'user', content: text };
    setMessages(prev => [...prev, userMsg]);
    setInput('');
    setLoading(true);

    const history = [...messages, userMsg]
      .map(m => `${m.role === 'user' ? 'User' : 'Coach'}: ${m.content}`)
      .join('\n');

    const result = await backend.integrations.Core.InvokeLLM({
      prompt: `You are an elite personal fitness and nutrition coach with full access to this user's profile, history, and goals. Answer their question with hyper-specific, personalized advice that ONLY applies to them — not generic fitness copy.

${aiCtx}

${planContext ? `Active Plan:\nTraining: ${planContext.training || ''}\nNutrition: ${planContext.nutrition || ''}\nRecovery: ${planContext.recovery || ''}\n` : ''}

RULES:
- Reference the user's specific goals, limitations, recent logs, and preferences in your answer.
- Be direct and practical. 2-4 sentences max unless detail is needed.
- Never give medical diagnosis. Use "recommendation", "guidance", "consider".
- If pain or concerning symptoms are mentioned, advise consulting a qualified professional.

Conversation:
${history}

Answer the user's latest question now.`,
    });

    setMessages(prev => [...prev, { role: 'assistant', content: result }]);
    setLoading(false);
  };

  const handleKeyDown = (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      sendMessage();
    }
  };

  const modal = (
    <motion.div
      initial={{ y: '100%' }}
      animate={{ y: 0 }}
      exit={{ y: '100%' }}
      transition={{ type: 'spring', damping: 28, stiffness: 300 }}
      style={{
        position: 'fixed',
        inset: 0,
        zIndex: 9999,
        display: 'flex',
        flexDirection: 'column',
        background: '#f6f2e8',
      }}
    >
      {/* Header */}
      <div style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        padding: '48px 20px 16px',
        borderBottom: '1px solid #e8e1d4',
        background: 'rgba(251,248,241,0.97)',
        flexShrink: 0,
      }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <Sparkles size={15} style={{ color: ACCENT_DARK }} />
          <div>
            <h2 style={{ fontSize: 16, fontWeight: 700, color: '#141613', margin: 0 }}>Ask a Question</h2>
            <p style={{ fontSize: 12, color: '#91968e', margin: 0 }}>Fitness & nutrition coach</p>
          </div>
        </div>
        <button onClick={onClose} style={{
          width: 36, height: 36, borderRadius: 12, border: '1px solid #e8e1d4',
          background: '#ffffff', display: 'flex', alignItems: 'center', justifyContent: 'center', cursor: 'pointer',
        }}>
          <X size={16} style={{ color: '#5d635d' }} />
        </button>
      </div>

      {/* Messages */}
      <div style={{ flex: 1, overflowY: 'auto', padding: '16px 20px', display: 'flex', flexDirection: 'column', gap: 12 }}>
        {messages.map((msg, i) => (
          <div key={i} style={{ display: 'flex', justifyContent: msg.role === 'user' ? 'flex-end' : 'flex-start' }}>
            <div style={{
              maxWidth: '85%',
              padding: '12px 16px',
              borderRadius: msg.role === 'user' ? '20px 20px 6px 20px' : '20px 20px 20px 6px',
              fontSize: 14,
              lineHeight: 1.6,
              background: msg.role === 'user' ? ACCENT : '#ffffff',
              color: msg.role === 'user' ? '#141613' : '#2d2f2c',
              border: msg.role === 'assistant' ? '1px solid #e8e1d4' : 'none',
            }}>
              {msg.content}
            </div>
          </div>
        ))}
        {loading && (
          <div style={{ display: 'flex', justifyContent: 'flex-start' }}>
            <div style={{
              padding: '12px 16px', borderRadius: '20px 20px 20px 6px',
              background: '#ffffff', border: '1px solid #e8e1d4',
              display: 'flex', alignItems: 'center', gap: 8,
            }}>
              <Loader2 size={13} className="animate-spin" style={{ color: ACCENT_DARK }} />
              <span style={{ fontSize: 12, color: '#91968e' }}>Thinking…</span>
            </div>
          </div>
        )}
        <div ref={bottomRef} />
      </div>

      {/* Input */}
      <div style={{
        padding: '12px 20px 32px',
        borderTop: '1px solid #e8e1d4',
        background: 'rgba(251,248,241,0.97)',
        flexShrink: 0,
      }}>
        <div style={{ display: 'flex', gap: 8, alignItems: 'flex-end' }}>
          <textarea
            value={input}
            onChange={e => setInput(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="Ask anything about fitness, nutrition, recovery…"
            rows={2}
            style={{
              flex: 1,
              padding: '12px 16px',
              borderRadius: 20,
              border: '1px solid #e8e1d4',
              background: '#ffffff',
              color: '#141613',
              fontSize: 14,
              outline: 'none',
              resize: 'none',
              fontFamily: 'inherit',
            }}
          />
          <button
            onClick={sendMessage}
            disabled={!input.trim() || loading}
            style={{
              width: 44, height: 44, borderRadius: 14, border: 'none',
              background: (!input.trim() || loading) ? 'rgba(200,224,0,0.4)' : ACCENT,
              color: '#141613', cursor: 'pointer',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              flexShrink: 0,
            }}
          >
            <Send size={15} />
          </button>
        </div>
      </div>
    </motion.div>
  );

  return createPortal(modal, document.body);
}