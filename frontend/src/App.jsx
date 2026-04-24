import { useEffect, useState } from "react";

const API_BASE = import.meta.env.VITE_API_BASE_URL || "";
const TABS = {
  chat: "chat",
  list: "list",
  create: "create"
};

export default function App() {
  const [activeTab, setActiveTab] = useState(TABS.chat);
  const [messages, setMessages] = useState([
    { role: "assistant", content: "こんにちは。何を手伝いましょうか。" }
  ]);
  const [input, setInput] = useState("");
  const [loading, setLoading] = useState(false);
  const [selectedPromptId, setSelectedPromptId] = useState("");

  const [prompts, setPrompts] = useState([]);
  const [promptsLoading, setPromptsLoading] = useState(false);
  const [promptsError, setPromptsError] = useState("");
  const [deletingPromptId, setDeletingPromptId] = useState(null);

  const [form, setForm] = useState({
    title: "",
    body: "",
    tag: ""
  });
  const [savingPrompt, setSavingPrompt] = useState(false);
  const [saveMessage, setSaveMessage] = useState("");
  const [saveError, setSaveError] = useState("");

  useEffect(() => {
    fetchPrompts();
  }, []);

  useEffect(() => {
    if (activeTab === TABS.list) {
      fetchPrompts();
    }
  }, [activeTab]);

  async function handleSubmit(event) {
    event.preventDefault();
    const trimmed = input.trim();
    if (!trimmed || loading) return;

    const nextMessages = [...messages, { role: "user", content: trimmed }];
    setMessages(nextMessages);
    setInput("");
    setLoading(true);

    try {
      const response = await fetch(`${API_BASE}/api/chat`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json"
        },
        body: JSON.stringify({ messages: nextMessages })
      });

      const data = await response.json();

      if (!response.ok) {
        throw new Error(data.error || "リクエストに失敗しました。");
      }

      setMessages((current) => [
        ...current,
        { role: "assistant", content: data.message }
      ]);
    } catch (error) {
      setMessages((current) => [
        ...current,
        { role: "assistant", content: `エラー: ${error.message}` }
      ]);
    } finally {
      setLoading(false);
    }
  }

  async function fetchPrompts() {
    setPromptsLoading(true);
    setPromptsError("");

    try {
      const response = await fetch(`${API_BASE}/api/prompts`);
      const data = await response.json();

      if (!response.ok) {
        throw new Error(data.error || "一覧の取得に失敗しました。");
      }

      setPrompts(data.prompts || []);
    } catch (error) {
      setPromptsError(error.message);
    } finally {
      setPromptsLoading(false);
    }
  }

  function handleFormChange(event) {
    const { name, value } = event.target;
    setForm((current) => ({ ...current, [name]: value }));
  }

  function handlePromptSelect(event) {
    const nextId = event.target.value;
    setSelectedPromptId(nextId);

    if (!nextId) return;

    const selectedPrompt = prompts.find((prompt) => String(prompt.id) === nextId);
    if (selectedPrompt) {
      setInput(selectedPrompt.body);
    }
  }

  async function handlePromptSave(event) {
    event.preventDefault();
    if (savingPrompt) return;

    setSaveMessage("");
    setSaveError("");
    setSavingPrompt(true);

    try {
      const response = await fetch(`${API_BASE}/api/prompts`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json"
        },
        body: JSON.stringify({
          title: form.title,
          body: form.body,
          tag: form.tag
        })
      });

      const data = await response.json();

      if (!response.ok) {
        throw new Error(data.error || "保存に失敗しました。");
      }

      setForm({
        title: "",
        body: "",
        tag: ""
      });
      setSaveMessage("プロンプトを保存しました。");
      await fetchPrompts();
      setActiveTab(TABS.list);
    } catch (error) {
      setSaveError(error.message);
    } finally {
      setSavingPrompt(false);
    }
  }

  async function handlePromptDelete(promptId) {
    if (deletingPromptId) return;

    const prompt = prompts.find((item) => item.id === promptId);
    const confirmed = window.confirm(
      `「${prompt?.title || "このプロンプト"}」を削除します。`
    );
    if (!confirmed) return;

    setPromptsError("");
    setDeletingPromptId(promptId);

    try {
      const response = await fetch(`${API_BASE}/api/prompts/${promptId}`, {
        method: "DELETE"
      });

      if (!response.ok) {
        let message = "削除に失敗しました。";

        try {
          const data = await response.json();
          message = data.error || message;
        } catch {
          // DELETE 204 responses do not have a JSON body.
        }

        throw new Error(message);
      }

      setPrompts((current) => current.filter((item) => item.id !== promptId));

      if (selectedPromptId === String(promptId)) {
        setSelectedPromptId("");
        setInput("");
      }
    } catch (error) {
      setPromptsError(error.message);
    } finally {
      setDeletingPromptId(null);
    }
  }

  return (
    <div className="app-shell">
      <main className="chat-card">
        <header className="chat-header">
          <p className="eyebrow">Ruby + React + Ollama</p>
          <h1>Local LLM Chat</h1>
          <div className="tab-bar" role="tablist" aria-label="画面切り替え">
            <button
              type="button"
              className={activeTab === TABS.chat ? "tab active" : "tab"}
              onClick={() => setActiveTab(TABS.chat)}
            >
              Chat
            </button>
            <button
              type="button"
              className={activeTab === TABS.list ? "tab active" : "tab"}
              onClick={() => setActiveTab(TABS.list)}
            >
              Prompt List
            </button>
            <button
              type="button"
              className={activeTab === TABS.create ? "tab active" : "tab"}
              onClick={() => setActiveTab(TABS.create)}
            >
              Save Prompt
            </button>
          </div>
        </header>

        {activeTab === TABS.chat && (
          <>
            <section className="messages">
              {messages.map((message, index) => (
                <div key={index} className={`message ${message.role}`}>
                  <span className="role">{message.role}</span>
                  <p>{message.content}</p>
                </div>
              ))}
              {loading && (
                <div className="message assistant">
                  <span className="role">assistant</span>
                  <p>考えています...</p>
                </div>
              )}
            </section>

            <form className="composer" onSubmit={handleSubmit}>
              <div className="prompt-picker">
                <label className="field">
                  <span>Saved Prompt</span>
                  <select
                    value={selectedPromptId}
                    onChange={handlePromptSelect}
                    disabled={promptsLoading || prompts.length === 0}
                  >
                    <option value="">
                      {promptsLoading
                        ? "プロンプトを読み込み中..."
                        : prompts.length === 0
                          ? "保存済みプロンプトはありません"
                          : "保存済みプロンプトを選択"}
                    </option>
                    {prompts.map((prompt) => (
                      <option key={prompt.id} value={String(prompt.id)}>
                        {prompt.title}
                        {prompt.tag ? ` (${prompt.tag})` : ""}
                      </option>
                    ))}
                  </select>
                </label>
                {promptsError && <p className="status-text error">{promptsError}</p>}
              </div>
              <textarea
                value={input}
                onChange={(event) => setInput(event.target.value)}
                placeholder="メッセージを入力"
                rows={3}
              />
              <button type="submit" disabled={loading}>
                送信
              </button>
            </form>
          </>
        )}

        {activeTab === TABS.list && (
          <section className="panel">
            <div className="panel-header">
              <div>
                <p className="panel-title">Saved Prompts</p>
                <p className="panel-copy">保存済みプロンプトの一覧です。</p>
              </div>
              <button type="button" className="secondary-button" onClick={fetchPrompts}>
                再読み込み
              </button>
            </div>

            {promptsLoading && <p className="status-text">読み込み中...</p>}
            {promptsError && <p className="status-text error">{promptsError}</p>}

            {!promptsLoading && !promptsError && prompts.length === 0 && (
              <p className="status-text">保存されたプロンプトはまだありません。</p>
            )}

            {!promptsLoading && !promptsError && prompts.length > 0 && (
              <div className="prompt-list">
                {prompts.map((prompt) => (
                  <article key={prompt.id} className="prompt-item">
                    <div className="prompt-item-header">
                      <div className="prompt-item-title-group">
                        <h2>{prompt.title}</h2>
                        {prompt.tag && <span className="tag-chip">{prompt.tag}</span>}
                      </div>
                      <button
                        type="button"
                        className="danger-button"
                        onClick={() => handlePromptDelete(prompt.id)}
                        disabled={deletingPromptId === prompt.id}
                      >
                        {deletingPromptId === prompt.id ? "削除中..." : "削除"}
                      </button>
                    </div>
                    <p className="prompt-body">{prompt.body}</p>
                    <p className="prompt-meta">
                      Created: {formatDate(prompt.created_at)} / Updated: {formatDate(prompt.updated_at)}
                    </p>
                  </article>
                ))}
              </div>
            )}
          </section>
        )}

        {activeTab === TABS.create && (
          <section className="panel">
            <div className="panel-header">
              <div>
                <p className="panel-title">Save Prompt</p>
                <p className="panel-copy">再利用したいプロンプトを保存します。</p>
              </div>
            </div>

            <form className="prompt-form" onSubmit={handlePromptSave}>
              <label className="field">
                <span>Title</span>
                <input
                  type="text"
                  name="title"
                  value={form.title}
                  onChange={handleFormChange}
                  placeholder="例: 要約用プロンプト"
                  required
                />
              </label>

              <label className="field">
                <span>Tag</span>
                <input
                  type="text"
                  name="tag"
                  value={form.tag}
                  onChange={handleFormChange}
                  placeholder="例: summary"
                />
              </label>

              <label className="field">
                <span>Body</span>
                <textarea
                  name="body"
                  value={form.body}
                  onChange={handleFormChange}
                  placeholder="保存したいプロンプト本文"
                  rows={10}
                  required
                />
              </label>

              {saveMessage && <p className="status-text success">{saveMessage}</p>}
              {saveError && <p className="status-text error">{saveError}</p>}

              <div className="form-actions">
                <button type="submit" disabled={savingPrompt}>
                  {savingPrompt ? "保存中..." : "保存する"}
                </button>
              </div>
            </form>
          </section>
        )}
      </main>
    </div>
  );
}

function formatDate(value) {
  if (!value) return "-";

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;

  return new Intl.DateTimeFormat("ja-JP", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit"
  }).format(date);
}
