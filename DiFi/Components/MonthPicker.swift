import SwiftUI

struct MonthPicker: View {
    @Binding var selected: Date

    var body: some View {
        HStack(spacing: 4) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
            Text(selected.formatted(.dateTime.month(.wide).year()))
                .frame(width: 140)
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
                .disabled(Calendar.current.isDate(selected, equalTo: Calendar.current.startOfMonth(for: .now), toGranularity: .month))
        }
    }

    private func step(_ months: Int) {
        if let d = Calendar.current.date(byAdding: .month, value: months, to: selected) {
            selected = d
        }
    }
}
