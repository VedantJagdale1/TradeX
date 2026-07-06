# TradeX Terminal 📊🤖

TradeX Terminal is a high-performance, minimalist iOS portfolio management and quantitative analysis application designed for the Indian stock market. It combines clean, data-dense terminal design aesthetics with local data persistence and direct AI-powered portfolio orchestration.

---

## 🚀 Features

* **SwiftData Portfolio Tracking:** Complete, persistent structural accounting for live equity holdings, average buy costs, current market valuations, and real-time Profit & Loss (PnL) metrics.
* **AI Assistant Integration:** A direct, zero-dependency REST HTTP network implementation connecting seamlessly to the frontier-class **Gemini API** for deep risk analysis, asset distribution audits, and strategic financial advice.
* **Intelligent Keyboard Management:** A localized layout offering an advanced interactive input bar with a responsive keyboard dismissal toolbar for an unhindered user experience.
* **Minimalist Terminal UI:** Dark-mode optimized, performance-first interface built entirely natively using SwiftUI.

---

## 🛠️ Architecture & Tech Stack

* **Framework:** SwiftUI (iOS 17+)
* **Database & Persistence:** SwiftData
* **Network Layer:** Native `URLSession` (no external SDK bloat for AI endpoints)
* **AI Engine:** Google Gemini API (`gemini-2.5-flash` endpoint)
* **Language:** Swift 5.10+

### Project Structure
```text
TradeX/
├── Core/          # App entry point, scene configurations, and global assets
├── Models/        # SwiftData persistent schemas (Holdings, UserSettings, ChatMessage)
├── ViewModels/    # State management, calculations, and mathematical models
├── Views/         # Modular SwiftUI Interfaces (Dashboard, AIAssistantView, AppIconPreview)
