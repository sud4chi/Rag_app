import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import "./styles.css";

class ErrorBoundary extends React.Component {
  constructor(props) {
    super(props);
    this.state = { hasError: false, errorMessage: "" };
  }

  static getDerivedStateFromError(error) {
    return {
      hasError: true,
      errorMessage: error instanceof Error ? error.message : String(error)
    };
  }

  render() {
    if (this.state.hasError) {
      return (
        <div
          style={{
            minHeight: "100vh",
            display: "grid",
            placeItems: "center",
            padding: "24px",
            background: "#fff7ed",
            color: "#7c2d12"
          }}
        >
          <div
            style={{
              width: "min(100%, 720px)",
              padding: "24px",
              borderRadius: "20px",
              border: "1px solid rgba(194, 65, 12, 0.2)",
              background: "#ffffff"
            }}
          >
            <h1 style={{ marginTop: 0 }}>フロントエンドでエラーが発生しました</h1>
            <p style={{ marginBottom: "8px" }}>
              画面が真っ白になる代わりに、ここへエラー内容を表示します。
            </p>
            <pre
              style={{
                margin: 0,
                whiteSpace: "pre-wrap",
                wordBreak: "break-word",
                fontFamily: "monospace"
              }}
            >
              {this.state.errorMessage}
            </pre>
          </div>
        </div>
      );
    }

    return this.props.children;
  }
}

ReactDOM.createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <ErrorBoundary>
      <App />
    </ErrorBoundary>
  </React.StrictMode>
);
