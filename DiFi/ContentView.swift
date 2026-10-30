import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case income = "Income"
    case expenses = "Expenses"
    case debts = "Debts"
    case crypto = "Crypto"
    case allocation = "Allocation"
    case taxVault = "Tax Vault"
    case vat = "VAT / ΦΠΑ"
    case reports = "Reports"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "house.fill"
        case .income: return "arrow.down.circle.fill"
        case .expenses: return "arrow.up.circle.fill"
        case .debts: return "creditcard.fill"
        case .crypto: return "bitcoinsign.circle.fill"
        case .allocation: return "chart.pie.fill"
        case .taxVault: return "building.columns.fill"
        case .vat: return "percent"
        case .reports: return "doc.text.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct ContentView: View {
    @State private var selection: SidebarItem? = .crypto
    @State private var showQuickAdd = false

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                // App title in sidebar header
                HStack {
                    Text("DiFi")
                        .font(.title2.bold())
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                List(SidebarItem.allCases, selection: $selection) { item in
                    Label(item.rawValue, systemImage: item.icon)
                        .tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
            .toolbar {
                ToolbarItem {
                    Button(action: { showQuickAdd = true }) {
                        Image(systemName: "plus.circle.fill")
                    }
                    .help("Quick Add")
                }
            }
        } detail: {
            switch selection {
            case .dashboard, .none: DashboardView()
            case .income: IncomeView()
            case .expenses: ExpensesView()
            case .debts: DebtsView()
            case .crypto: CryptoView()
            case .allocation: AllocationView()
            case .taxVault: TaxVaultView()
            case .vat: VatView()
            case .reports: ReportsView()
            case .settings: SettingsView()
            }
        }
        .sheet(isPresented: $showQuickAdd) {
            QuickAddSheet()
        }
    }
}
