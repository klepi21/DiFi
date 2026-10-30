# DiFi

**A personal finance app for Greek freelancers, built for macOS with SwiftUI and SwiftData.**

DiFi tracks your income, expenses, debts and crypto. It also works out how much of each payment you should set aside for **income tax + προκαταβολή**, **ΕΦΚΑ** and **ΦΠΑ (VAT)**, so you know how much of the money is actually yours to spend.

Everything runs locally on your Mac. There is no account, no backend and no analytics. The only network calls are optional, read-only syncs with Kraken and a public Ethereum address.

---

## Table of contents

- [Features](#features)
- [How it works](#how-it-works)
- [Where your data is stored](#where-your-data-is-stored)
- [Requirements & build](#requirements--build)
- [Configuration (in-app)](#configuration-in-app)
- [Customising for your fork](#customising-for-your-fork)
- [Project structure](#project-structure)
- [Privacy & security](#privacy--security)
- [Disclaimer](#disclaimer)
- [License](#license)

---

## Features

| Tab | What it does |
|---|---|
| **Dashboard** | Shows this month at a glance: net income, tax reserve, ΕΦΚΑ, the total to set aside, what's left for you, expenses logged and the crypto portfolio total. |
| **Income** | Lets you log payments as *Recurring* or *One-time*. You enter the **net** amount and 24% VAT is added on top automatically. Each month has a ΕΦΚΑ status card where you mark ΕΦΚΑ as paid, or turn it into a debt if it wasn't paid. |
| **Expenses** | Holds one-time expenses by category (Housing, Food, Transport, Health, Entertainment, Business, Other) and **recurring expense templates** that appear every month. You mark each recurring item paid or unpaid per month. Includes a donut chart by category. |
| **Debts** | Tracks balance, monthly payment and interest rate, with months-to-payoff and total-interest calculations. Payments reduce the balance and are logged as expenses. Unpaid ΕΦΚΑ and the prior year's tax can be closed into a debt here. |
| **Crypto** | Shows **Kraken** balances, EUR prices, open orders and **cost basis / unrealised P&L** (average-cost method, from your ledger), plus per-asset trade history. It also shows a **read-only Ethereum wallet** (ETH + ERC-20 tokens worth more than $1). |
| **Allocation** | A pie chart of how one payment, or the whole month, splits across tax, ΕΦΚΑ, expenses, debt payments, investing and free money. You can set an investment amount per payment. |
| **Tax Vault** | Shows the yearly tax obligation compared with what you've already paid to the ΔΟΥ, and lets you log tax payments. |
| **VAT / ΦΠΑ** | Shows the VAT collected per month from income entries, lets you mark each month as remitted, and keeps a history. |
| **Reports** | Monthly income and expense breakdown, the annual tax estimate with a per-bracket breakdown, closing out last year's tax into Debts, and copying the report to the clipboard. |
| **Settings** | ΕΦΚΑ monthly amount, Kraken API credentials and the Ethereum wallet address. |

A **Quick Add** button (➕ in the toolbar) logs an income entry from anywhere in the app.

---

## How it works

### Money flow for every payment

```
Net income (what you invoiced, before VAT)
 ├─ VAT 24% ............ collected on top, tracked only in the VAT tab (never counted as your income)
 ├─ Tax reserve ........ net × live tax-reserve rate  (income tax + 55% προκαταβολή)
 ├─ ΕΦΚΑ ............... fixed monthly amount from Settings
 └─ Yours .............. net − tax reserve − ΕΦΚΑ
                          └─ then split into expenses / debts / investing / free (Allocation tab)
```

### Income tax calculation

`calculateGreekIncomeTax` in `Views/Reports/ReportsView.swift` applies the progressive brackets for natural persons with business income:

| Taxable income | Rate |
|---|---|
| 0 – 10.000 € | 9% |
| 10.000 – 20.000 € | 20% |
| 20.000 – 30.000 € | 26% |
| 30.000 – 40.000 € | 34% |
| 40.000 – 60.000 € | 39% |
| 60.000 € + | 44% |

- **Taxable income** = gross yearly net income − (ΕΦΚΑ monthly × 12). ΕΦΚΑ is the only deduction applied.
- **Total obligation** = income tax + **55% προκαταβολή** (the advance tax payment for next year).

### Live tax-reserve rate

You don't set a fixed percentage. `projectedTaxReservePct` in `Extensions.swift` works it out:

1. It takes the income you've logged so far this year and extrapolates it to a full year (run rate). The first few days of January are clamped so the projection doesn't jump to extreme values.
2. It runs that projected annual income through the brackets above, adds the 55% προκαταβολή, and divides by the projected income to get a blended rate.
3. It repeats this as of **every date you logged income** and keeps the **highest rate seen so far** (a high-water mark). One large early invoice therefore keeps you reserving conservatively, so you don't end up short later in the year.
4. The rate stays between **9% and 60%** and resets to a **22% floor** each new calendar year.

### Crypto

- **Kraken.** Requests to Kraken's private REST API are signed with HMAC-SHA512 and use only read endpoints: `Balance`, `OpenOrders` and `Ledgers`. Prices come from Kraken's public `Ticker` in EUR. Cost basis is rebuilt from ledger entries with the average-cost method. Coins you deposited (rather than bought on Kraken) have no cost basis and show "—".
- **Ethereum wallet.** This uses a public address only. Token balances come from [Blockscout](https://eth.blockscout.com) (free, no key needed) and EUR/USD prices come from [CoinGecko](https://www.coingecko.com)'s free API. CoinGecko's free tier is rate-limited, so a token that fails to price on one sync keeps its last cached value instead of disappearing.
- Results are cached as `CryptoHolding` rows, so the Dashboard and Allocation tabs don't need the network.
- Coin logos come from the [atomiclabs/cryptocurrency-icons](https://github.com/atomiclabs/cryptocurrency-icons) CDN. If a logo isn't available, the app shows a coloured letter instead.

---

## Where your data is stored

| Data | Storage | Location |
|---|---|---|
| Income, expenses, debts, tax/VAT/ΕΦΚΑ payments, settings, cached crypto | **SwiftData** (SQLite) | `~/Library/Containers/com.difi.app/Data/Library/Application Support/default.store` |
| Kraken API key + secret | **macOS Keychain** (service `com.difi.app.kraken`) | Keychain Access → search "com.difi.app.kraken" |
| Ethereum wallet address (public) | **UserDefaults** (key `wallet.address`) | `~/Library/Containers/com.difi.app/Data/Library/Preferences/com.difi.app.plist` |

- The app is **sandboxed**. Its only entitlements are outgoing network and read access to files you pick.
- **Backup:** quit the app and copy the whole `Application Support` folder (`default.store`, `default.store-shm` and `default.store-wal`).
- **Reset:** quit the app and delete those files. The app creates a fresh database on its next launch.
- **Inspect:** `sqlite3 ~/Library/Containers/com.difi.app/Data/Library/Application\ Support/default.store ".tables"`. SwiftData tables are prefixed with `Z`, for example `ZINCOMEENTRY`.
- If you change the bundle ID, the `com.difi.app` part of these paths changes with it.

### Data model (`Models/Models.swift`)

| Model | Purpose |
|---|---|
| `IncomeEntry` | date, net amount, source, type, notes, `vatRate` (nil = no VAT), optional `investmentAmount` |
| `ExpenseEntry` | one-time expense: date, amount, category, Fixed/Extra, notes |
| `RecurringExpense` | monthly template (name, amount, category, active/paused); not copied into each month |
| `RecurringExpensePayment` | paid/unpaid status for one recurring expense in one month |
| `Debt` | total, current balance, monthly payment, annual interest % |
| `TaxPayment` | payments made to the ΔΟΥ |
| `VatPayment` | VAT due vs. paid, per month |
| `EfkaMonthStatus` | ΕΦΚΑ paid / unpaid / moved to debt, per month |
| `CryptoHolding` | cached Kraken or wallet balance (`source` = `"kraken"` / `"wallet"`) |
| `AppSettings` | single row holding `efkaMonthly` |
| `EmergencyFund` | single row: target months, balance, monthly allocation target |

> **Schema changes:** SwiftData migrates automatically only when a **new property is Optional or has an inline default value**. If you add a required property without a default, existing users' stores will fail to open and the app will crash on launch.

---

## Requirements & build

- macOS **14 (Sonoma)** or later
- **Xcode 15+** (Swift 5, SwiftUI, SwiftData, Swift Charts)
- No third-party dependencies or package managers

```bash
git clone https://github.com/<you>/DiFi.git
cd DiFi
open DiFi.xcodeproj
```

In Xcode, go to **DiFi target → Signing & Capabilities** and choose **your own Team** (the project uses the original author's team ID). If needed, change the bundle identifier as well. Then press **⌘R**.

From the command line:

```bash
xcodebuild -project DiFi.xcodeproj -scheme DiFi -configuration Release -destination 'platform=macOS' build
```

---

## Configuration (in-app)

Everything you need day to day is in **Settings**.

### 1. ΕΦΚΑ monthly (€)
Your fixed monthly social-insurance contribution. It is deducted from taxable income (× 12) and from each month's "yours" figure.

### 2. Kraken API (optional)
1. On Kraken, go to **Settings → API → Create API key**.
2. Enable **read-only** permissions:
   - **Query Funds** for balances
   - **Query Open Orders & Trades** for open orders
   - **Query Ledger Entries** for cost basis and trade history (without it, cost basis shows "—")
3. **Never enable Withdraw, Deposit or Trade permissions.**
4. Paste the key and the secret into Settings and click **Save**. They are stored in the Keychain.

### 3. Ethereum wallet (optional)
Paste a **public** `0x…` address. Leave the field empty to turn the wallet section off. The app never asks for private keys or seed phrases.

---

## Customising for your fork

These are hardcoded in the source. Change them to match your situation:

| What | Where | Default |
|---|---|---|
| **Tax brackets** | `calculateGreekIncomeTax` in `Views/Reports/ReportsView.swift` | Greek 2024+ freelancer brackets |
| **Προκαταβολή %** | `result.tax * 0.55` in `Extensions.swift` (`annualTaxObligation`, `instantaneousProjectedRate`) | 55% |
| **Tax-reserve floor / min / max** | `projectedTaxReservePct` / `instantaneousProjectedRate` in `Extensions.swift` | 22% floor, clamped 9%–60% |
| **VAT rate** | `vatRate: 24` in `Views/Income/IncomeView.swift` and `Components/QuickAddSheet.swift` | 24% (other Greek rates: 13%, 6%) |
| **Expense categories** | `ExpenseCategory` enum in `Models/Models.swift` | 7 categories |
| **Currency** | currency formatting helpers in `Extensions.swift` | EUR |
| **Wallet dust threshold** | `minUSD` in `Services/EthWalletService.swift` | $1 |
| **Wallet chain / indexer** | `blockscoutBaseURL` in `Services/EthWalletService.swift` | Ethereum mainnet Blockscout. Other Blockscout instances (Base, Arbitrum, etc.) use the same API. |
| **Price source** | `coingeckoBaseURL` in `Services/EthWalletService.swift` | CoinGecko free API |
| **Sidebar tabs / default tab** | `SidebarItem` and `selection` in `ContentView.swift` | starts on Crypto |
| **Bundle ID / Keychain service** | Xcode build settings / `KeychainHelper.service` | `com.difi.app` / `com.difi.app.kraken` |

**Using it outside Greece:** replace the brackets and the 55% προκαταβολή with your country's rules, set ΕΦΚΑ to your social-insurance amount (or 0), and change the VAT rate. The rest of the app doesn't depend on Greek rules.

---

## Project structure

```
DiFi.xcodeproj/
DiFi/
├── DiFiApp.swift            # App entry; builds the SwiftData container, seeds AppSettings
├── ContentView.swift        # Sidebar navigation (SidebarItem enum)
├── Extensions.swift         # Formatting helpers + tax projection logic
├── DiFi.entitlements        # Sandbox, network client, user-selected read-only files
├── Models/Models.swift      # All SwiftData @Model types
├── Services/
│   ├── KrakenService.swift      # Signed Kraken REST client, cost-basis calculation
│   ├── EthWalletService.swift   # Blockscout + CoinGecko read-only wallet client
│   └── KeychainHelper.swift     # Keychain wrapper for the Kraken credentials
├── Components/              # QuickAddSheet, SummaryCard, MonthPicker, CryptoLogoView
├── Views/                   # One folder per sidebar tab
└── Assets.xcassets/         # App icon
```

---

## Privacy & security

- No telemetry, no accounts, no servers of our own.
- Outgoing requests go only to `api.kraken.com`, `eth.blockscout.com`, `api.coingecko.com` and `cdn.jsdelivr.net` (logos), and only for the features you've turned on.
- Kraken secrets are kept only in the Keychain and are never written to the database or to disk in plain text.
- **Before you push your fork, check that you haven't hardcoded any API keys, wallet addresses or personal data.**

---

## Disclaimer

DiFi is a personal budgeting tool, **not tax or financial advice**. Tax rules change; check the figures with your accountant (λογιστής) before paying anything to the ΔΟΥ or ΕΦΚΑ.

## License

[MIT](LICENSE). Fork it and change it as you like.
