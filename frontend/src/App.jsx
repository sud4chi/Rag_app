import { useState } from "react";

const API_BASE = "http://localhost:4567";

export default function App() {
  const [messages, setMessages] = useState([
    { role: "assistant", content: "こんにちは。何を手伝いましょうか。" }
  ]);
  const [input, setInput] = useState("");
  const [loading, setLoading] = useState(false);

  async function handleSubmit(event) {
    event.preventDefault();
    const trimmed = input.trim();
    if (!trimmed || loading) return;

    const nextMessages = [...messages, { role: "user", content: trimmed }];
    setMessages(nextMessages);
    setInput("");
    setLoading(true);

    try {
      const response = await fetch(`${API_BASE}/chat`, {
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

  return (
    <div className="app-shell">
      <main className="chat-card">
        <header className="chat-header">
          <p className="eyebrow">Ruby + React + Ollama</p>
          <h1>Local LLM Chat</h1>
        </header>

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
      </main>
    </div>
  );
}
