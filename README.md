# TradeX 📊🤖

TradeX Terminal is a high-performance, minimalist iOS paper-trading and quantitative analysis application designed for the Indian stock market. It combines clean, data-dense terminal design aesthetics with local data persistence and direct AI-powered portfolio orchestration.

All trading is simulated. Nothing in the app is investment advice.

---

## 🚀 Features

* **SwiftData Portfolio Tracking:** Complete, persistent structural accounting for live equity holdings, average buy costs, current market valuations, and real-time Profit & Loss (PnL) metrics.
* **Trade Journal:** Every buy and sell is recorded with its size, price, realised P&L, and an optional written reason — so past decisions can be reviewed against how they actually turned out.
* **Performance vs Benchmark:** Time-weighted return charted against the NIFTY 50, with deposits factored out so paying money in is never mistaken for making money.
* **Partial Position Management:** Sell all or part of a holding at the live market price, with average cost preserved across the remainder.
* **Live Market Data:** Real-time quotes, historical price charts, and live NIFTY 50 / SENSEX index levels.
* **AI Assistant Integration:** A direct, zero-dependency REST HTTP network implementation connecting seamlessly to the frontier-class **Groq API**, with the user's holdings, cash position, and full trade history supplied as context for risk analysis and decision review.
* **Intelligent Keyboard Management:** A localized layout offering an advanced interactive input bar with a responsive keyboard dismissal toolbar for an unhindered user experience.
* **Minimalist Terminal UI:** Dark-mode optimized, performance-first interface built entirely natively using SwiftUI.

---

## 🛠️ Architecture & Tech Stack

* **Framework:** SwiftUI (iOS 18.6+)
* **Database & Persistence:** SwiftData
* **Charts:** Swift Charts
* **Network Layer:** Native `URLSession` (no external SDK bloat for AI or market endpoints)
* **Market Data:** Yahoo Finance chart endpoints (unofficial)
* **AI Engine:** Groq (`llama-3.3-70b-versatile` endpoint)
* **Language:** Swift 5

### Project Structure
```text
TradeX/
├── Core/          # Constants and shared formatting helpers
├── Models/        # SwiftData schemas (PortfolioHolding, UserSettings, Trade,
│                  # CashAdjustment, PortfolioSnapshot), plus market and AI services
├── ViewModels/    # State management, search, and debouncing
├── Views/         # Dashboard, MarketExplorer, StockDetail, Portfolio,
│                  # TradeHistory, Performance, AIAssistant
```

---

### 🔑 Setup & API Configuration

The Groq API key is injected at build time from a local config file that is **never committed**. It reaches the app through the `INFOPLIST_FILE` build setting, so no key is ever written into source.

1. Obtain a free API key from <https://console.groq.com/keys> (it starts with `gsk_`).

2. Copy the template to create your local config:

```bash
cp Secrets.example.xcconfig Secrets.xcconfig
```

3. Open `Secrets.xcconfig` and set your key:

```text
GROQ_API_KEY = gsk_your_key_here
```

`Secrets.xcconfig` is listed in `.gitignore`, so it stays on your machine. Build and run as normal — the key flows into `Info.plist` as `GroqAPIKey` and is read at runtime.

If the key is missing or malformed, the app still builds and runs; only the AI Assistant tab will report that the key needs configuring.

> **Note:** a key supplied this way is embedded in the built app bundle and can be extracted from any distributed build. For anything beyond local use, put a server-side proxy in front of the Groq endpoint so the key never ships to clients.

---

## 👨‍💻 Installation & Deployment

To clone and run TradeX Terminal locally on your machine:

**Step 1:** Clone the repository

```bash
git clone https://github.com/VedantJagdale1/TradeX.git
```

**Step 2:** Open the project root

```bash
cd TradeX
```

**Step 3:** Configure your API key — see [Setup & API Configuration](#-setup--api-configuration) above

**Step 4:** Launch via Xcode

```bash
open TradeX.xcodeproj
```

Select a target simulator profile (e.g., iPhone 17 Pro) and hit ⌘ + R to compile and launch.

**Requirements:** Xcode 16+, iOS 18.6 or later.

---

## 📄 License
This project is proprietary and built for personal quantitative research and portfolio monitoring.
