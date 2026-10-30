import SwiftUI
import SwiftData

@main
struct DiFiApp: App {
    // Pre-build the container so we can seed default AppSettings on first launch
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for:
                IncomeEntry.self,
                ExpenseEntry.self,
                RecurringExpense.self,
                Debt.self,
                CryptoHolding.self,
                TaxPayment.self,
                AppSettings.self,
                EfkaMonthStatus.self,
                VatPayment.self,
                RecurringExpensePayment.self,
                EmergencyFund.self
            )
            // Seed default settings singleton if none exists yet
            let context = container.mainContext
            let count = (try? context.fetchCount(FetchDescriptor<AppSettings>())) ?? 0
            if count == 0 {
                context.insert(AppSettings())
                try? context.save()
            }
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
