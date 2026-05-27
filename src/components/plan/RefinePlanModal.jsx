import { useState, useRef, useEffect } from 'react';
import { createPortal } from 'react-dom';
import { useNavigate } from 'react-router-dom';
import { motion } from 'framer-motion';
import { X, Send, Loader2, SlidersHorizontal, Trash2, RefreshCw, Wand2, Check, AlertTriangle } from 'lucide-react';
import { backend } from '@/api/backendClient';
import { getUserAIContext } from '@/lib/aiContext';
import { loadActivePlan } from '@/lib/personalizationSync';
import { refinePlanFromChat } from '@/lib/refinePlanFromChat';

const ACCENT = '#c8e000';
const ACCENT_DARK = '#8ea400';
const STORAGE_KEY = 'execute_refine_chat';
const ONE_DAY_MS = 24 * 60 * 60 * 1000;

const INITIAL_MESSAGE = {
  role: 'assistant',
  content: "What's on your mind about the plan? I can answer questions OR apply changes directly to your active plan — fewer training days, different focus, swap meals, adjust calories, anything. Just tell me what you want to change.",
  intent: 'idle',
};

function loadChat() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY) || localStorage.getItem('evanlog_refine_chat');
    const saved = JSON.parse(raw);
    if (saved && Date.now() - saved.timestamp < ONE_DAY_MS && saved.messages?.length > 0) {
      return saved.messages;
    }
  } catch {
    // Ignore malformed saved chat and start fresh.
  }
  return [INITIAL_MESSAGE];
}

function saveChat(messages) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ messages, timestamp: Date.now() }));
  } catch {
    // Storage can be unavailable in private or restricted contexts.
  }
}

function clearChat() {
  try {
    localStorage.removeItem(STORAGE_KEY);
  } catch {
    // Storage can be unavailable in private or restricted contexts.
  }
}

export default function RefinePlanModal({ onClose, plan, onPlanUpdated }) {
  const navigate = useNavigate();
  const [messages, setMessages] = useState(loadChat);
  const [input, setInput] = useState('');
  const [loading, setLoading] = useState(false);
  const [applying, setApplying] = useState(false);
  const [aiCtx, setAiCtx] = useState('');
  const bottomRef = useRef(null);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages]);

  useEffect(() => {
    getUserAIContext({ forceRefresh: true }).then(ctx => setAiCtx(ctx)).catch(() => {});
  }, []);

  const handleDeleteChat = () => {
    clearChat();
    setMessages([INITIAL_MESSAGE]);
  };

  const goToFullRegenerate = () => {
    clearChat();
    onClose?.();
    navigate('/plan?generate=true');
  };

  const sendMessage = async () => {
    const text = input.trim();
    if (!text || loading) return;

    const userMsg = { role: 'user', content: text, intent: 'idle' };
    const updatedMessages = [...messages, userMsg];

    setMessages(updatedMessages);
    saveChat(updatedMessages);
    setInput('');
    setLoading(true);

    const history = updatedMessages
      .map(m => `${m.role === 'user' ? 'User' : 'Coach'}: ${m.content}`)
      .join('\n');

    try {
      const result = await backend.integrations.Core.InvokeLLM({
        prompt: `You are Execute's plan refinement coach. The user can ask questions OR request changes to their active plan. You have TWO jobs:

1. CLASSIFY the user's latest message:
   - "question": user is asking for advice, info, or clarification → just answer.
   - "change": user wants to change their plan in some way (training days, intensity, focus, meals, calories, schedule, swap exercises, add/remove things, etc.) → answer briefly and propose applying it.
   - "full_regenerate": user wants to start over entirely or change something so fundamental (new primary goal, new sport, completely different program) that re-running the full questionnaire is the right path.

2. RESPOND clearly.

${aiCtx}

CURRENT PLAN HIGH-LEVEL VIEW:
Training: ${plan?.training || 'Not set'}
Nutrition: ${plan?.nutrition || 'Not set'}
Recovery: ${plan?.recovery || 'Not set'}

CONVERSATION:
${history}

RULES:
- If pain, injury symptoms, medical concerns, dizziness, chest pain, or severe discomfort come up, recommend consulting a qualified professional and classify as "question".
- Use "guidance", "recommendation", "suggestion" — never diagnose or treat.
- Keep responses 1–4 sentences.
- For "change", briefly confirm what you'll change so the user can hit Apply with confidence. Do NOT claim you already applied anything — that happens after they confirm.
- For "full_regenerate", recommend re-running the full plan flow.
- Execute is the product name.

Return JSON:
{
  "message": "1-4 sentence response",
  "intent": "question | change | full_regenerate",
  "change_request": "if intent=change, restate the user's change as a clear actionable instruction the refinement engine can execute; otherwise empty string"
}`,
        response_json_schema: {
          type: 'object',
          properties: {
            message: { type: 'string' },
            intent: { type: 'string' },
            change_request: { type: 'string' },
          },
          required: ['message', 'intent'],
        },
      });

      const intent = result?.intent === 'change' || result?.intent === 'full_regenerate'
        ? result.intent
        : 'question';

      const assistantMsg = {
        role: 'assistant',
        content: result.message,
        intent,
        changeRequest: result.change_request || '',
      };

      const finalMessages = [...updatedMessages, assistantMsg];
      setMessages(finalMessages);
      saveChat(finalMessages);
    } catch (err) {
      console.warn('[RefinePlanModal] AI response failed', err);
      const assistantMsg = {
        role: 'assistant',
        content: 'I could not process that request right now. Please try again.',
        intent: 'question',
      };
      const finalMessages = [...updatedMessages, assistantMsg];
      setMessages(finalMessages);
      saveChat(finalMessages);
    } finally {
      setLoading(false);
    }
  };

  const applyChange = async (changeRequest, msgIndex) => {
    if (!changeRequest || applying) return;
    setApplying(true);

    // Optimistic: mark the message as applying
    const working = messages.map((m, i) => i === msgIndex ? { ...m, applying: true } : m);
    setMessages(working);

    try {
      // Always load the freshest active plan in case other tabs updated it
      const currentPlan = (await loadActivePlan('daily').catch(() => null)) || plan?._raw || plan;
      if (!currentPlan?.id) {
        throw new Error('No active plan found to refine. Please generate a plan first.');
      }

      const { changeSummary, newPlan } = await refinePlanFromChat({
        changeRequest,
        currentPlan,
      });

      const successMsg = {
        role: 'assistant',
        content: `✓ Done. ${changeSummary}\n\nYour workouts, meals, and dashboard will use the updated plan from now on.`,
        intent: 'applied',
      };

      const finalMessages = messages
        .map((m, i) => i === msgIndex ? { ...m, intent: 'change_applied', applying: false } : m)
        .concat(successMsg);

      setMessages(finalMessages);
      saveChat(finalMessages);
      onPlanUpdated?.(newPlan);
    } catch (err) {
      console.warn('[RefinePlanModal] apply change failed', err);
      const errMsg = {
        role: 'assistant',
        content: `I couldn't apply that change: ${err.message || 'unknown error'}. You can try rephrasing or use Full plan update.`,
        intent: 'error',
      };
      const finalMessages = messages
        .map((m, i) => i === msgIndex ? { ...m, applying: false } : m)
        .concat(errMsg);
      setMessages(finalMessages);
      saveChat(finalMessages);
    } finally {
      setApplying(false);
    }
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
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          padding: '48px 20px 16px',
          borderBottom: '1px solid #e8e1d4',
          background: 'rgba(251,248,241,0.97)',
          flexShrink: 0,
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <SlidersHorizontal size={15} style={{ color: ACCENT_DARK }} />
          <div>
            <h2 style={{ fontSize: 16, fontWeight: 700, color: '#141613', margin: 0 }}>
              Refine Your Plan
            </h2>
            <p style={{ fontSize: 12, color: '#91968e', margin: 0 }}>
              Ask anything — or tell me what to change
            </p>
          </div>
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <button
            onClick={handleDeleteChat}
            title="Clear chat history"
            style={{
              height: 36,
              borderRadius: 12,
              border: '1px solid #e8e1d4',
              background: '#ffffff',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              cursor: 'pointer',
              gap: 6,
              padding: '0 12px',
            }}
          >
            <Trash2 size={13} style={{ color: '#b05a3a' }} />
            <span style={{ fontSize: 11, fontWeight: 600, color: '#b05a3a' }}>Clear chat</span>
          </button>

          <button
            onClick={onClose}
            style={{
              width: 36,
              height: 36,
              borderRadius: 12,
              border: '1px solid #e8e1d4',
              background: '#ffffff',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              cursor: 'pointer',
            }}
          >
            <X size={16} style={{ color: '#5d635d' }} />
          </button>
        </div>
      </div>

      <div
        style={{
          flex: 1,
          overflowY: 'auto',
          padding: '16px 20px',
          display: 'flex',
          flexDirection: 'column',
          gap: 12,
        }}
      >
        {messages.map((msg, i) => {
          const isUser = msg.role === 'user';
          const showApply = !isUser && msg.intent === 'change' && msg.changeRequest && !msg.applying;
          const showFullRegen = !isUser && msg.intent === 'full_regenerate';
          const isApplying = !isUser && msg.applying;

          return (
            <div key={i} style={{ display: 'flex', justifyContent: isUser ? 'flex-end' : 'flex-start' }}>
              <div
                style={{
                  maxWidth: '85%',
                  padding: '12px 16px',
                  borderRadius: isUser ? '20px 20px 6px 20px' : '20px 20px 20px 6px',
                  fontSize: 14,
                  lineHeight: 1.6,
                  whiteSpace: 'pre-wrap',
                  background: isUser ? ACCENT : '#ffffff',
                  color: '#141613',
                  border: isUser ? 'none' : '1px solid #e8e1d4',
                }}
              >
                {msg.content}

                {showApply && (
                  <button
                    onClick={() => applyChange(msg.changeRequest, i)}
                    disabled={applying}
                    style={{
                      marginTop: 10,
                      height: 36,
                      padding: '0 14px',
                      borderRadius: 12,
                      border: 'none',
                      background: ACCENT,
                      color: '#141613',
                      fontSize: 12,
                      fontWeight: 800,
                      display: 'inline-flex',
                      alignItems: 'center',
                      gap: 6,
                      cursor: applying ? 'not-allowed' : 'pointer',
                      opacity: applying ? 0.6 : 1,
                    }}
                  >
                    <Wand2 size={13} /> Apply this change
                  </button>
                )}

                {isApplying && (
                  <div style={{ marginTop: 10, display: 'inline-flex', alignItems: 'center', gap: 6, fontSize: 12, color: ACCENT_DARK, fontWeight: 600 }}>
                    <Loader2 size={13} className="animate-spin" /> Updating your plan…
                  </div>
                )}

                {msg.intent === 'change_applied' && (
                  <div style={{ marginTop: 8, display: 'inline-flex', alignItems: 'center', gap: 6, fontSize: 11, color: ACCENT_DARK, fontWeight: 700 }}>
                    <Check size={12} /> Applied
                  </div>
                )}

                {msg.intent === 'error' && (
                  <div style={{ marginTop: 4, display: 'inline-flex', alignItems: 'center', gap: 6, fontSize: 11, color: '#b05a3a', fontWeight: 700 }}>
                    <AlertTriangle size={12} /> Not applied
                  </div>
                )}

                {showFullRegen && (
                  <button
                    onClick={goToFullRegenerate}
                    style={{
                      marginTop: 10,
                      height: 36,
                      padding: '0 14px',
                      borderRadius: 12,
                      border: 'none',
                      background: ACCENT,
                      color: '#141613',
                      fontSize: 12,
                      fontWeight: 800,
                      display: 'inline-flex',
                      alignItems: 'center',
                      gap: 6,
                      cursor: 'pointer',
                    }}
                  >
                    <RefreshCw size={13} /> Re-run full plan
                  </button>
                )}
              </div>
            </div>
          );
        })}

        {loading && (
          <div style={{ display: 'flex', justifyContent: 'flex-start' }}>
            <div
              style={{
                padding: '12px 16px',
                borderRadius: '20px 20px 20px 6px',
                background: '#ffffff',
                border: '1px solid #e8e1d4',
              }}
            >
              <Loader2 size={16} className="animate-spin" style={{ color: ACCENT_DARK }} />
            </div>
          </div>
        )}

        <div ref={bottomRef} />
      </div>

      <div
        style={{
          padding: '12px 20px 24px',
          borderTop: '1px solid #e8e1d4',
          background: 'rgba(251,248,241,0.97)',
          flexShrink: 0,
        }}
      >
        <div style={{ display: 'flex', gap: 8 }}>
          <textarea
            value={input}
            onChange={e => setInput(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="Ask a question or describe what you want to change..."
            rows={1}
            disabled={applying}
            style={{
              flex: 1,
              resize: 'none',
              border: '1px solid #e8e1d4',
              borderRadius: 16,
              padding: '12px 14px',
              fontSize: 14,
              background: '#ffffff',
              color: '#141613',
              outline: 'none',
              minHeight: 44,
              maxHeight: 120,
              opacity: applying ? 0.6 : 1,
            }}
          />

          <button
            onClick={sendMessage}
            disabled={!input.trim() || loading || applying}
            style={{
              width: 44,
              height: 44,
              borderRadius: 16,
              border: 'none',
              background: !input.trim() || loading || applying ? '#e8e1d4' : ACCENT,
              color: '#141613',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              cursor: !input.trim() || loading || applying ? 'not-allowed' : 'pointer',
              flexShrink: 0,
            }}
          >
            {loading ? <Loader2 size={17} className="animate-spin" /> : <Send size={17} />}
          </button>
        </div>
      </div>
    </motion.div>
  );

  return createPortal(modal, document.body);
}
