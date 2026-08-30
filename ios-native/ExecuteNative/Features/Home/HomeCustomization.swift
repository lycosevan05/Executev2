import SwiftUI

struct HomeCustomizationSheet: View {
    @ObservedObject var model: HomeViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Visible widgets") {
                    ForEach(model.widgetOrder) { widget in
                        HStack {
                            Image(systemName: "line.3.horizontal").foregroundStyle(ExecuteColor.mist)
                            Text(widget.title)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { !model.hiddenWidgets.contains(widget) },
                                set: { model.setWidget(widget, isVisible: $0) }
                            ))
                            .labelsHidden()
                            .tint(ExecuteColor.chartreuseDark)
                        }
                    }
                    .onMove(perform: model.moveWidgets)
                }

                if !model.hiddenWidgets.isEmpty {
                    Section("Hidden widgets") {
                        ForEach(HomeWidget.defaultOrder.filter { model.hiddenWidgets.contains($0) }) { widget in
                            Toggle(widget.title, isOn: Binding(
                                get: { false },
                                set: { model.setWidget(widget, isVisible: $0) }
                            ))
                            .tint(ExecuteColor.chartreuseDark)
                        }
                    }
                }

                Section("Daily vitals") {
                    ForEach(HomeVital.allCases) { vital in
                        Toggle(vital.title, isOn: Binding(
                            get: { model.selectedVitals.contains(vital) },
                            set: { _ in model.toggleVital(vital) }
                        ))
                        .tint(ExecuteColor.chartreuseDark)
                    }
                    Text("Choose 1 to 12 vitals to show on Home.")
                        .font(ExecuteTypography.caption(11))
                        .foregroundStyle(ExecuteColor.mist)
                }

                Section {
                    Button("Reset Home layout", role: .destructive) { model.resetLayout() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ExecuteColor.parchment)
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Customize Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Task {
                            await model.saveLayout()
                            dismiss()
                        }
                    }
                    .font(ExecuteTypography.label(15).weight(.bold))
                    .foregroundStyle(ExecuteColor.chartreuseDark)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

struct HomeChecklistCustomizationSheet: View {
    @ObservedObject var model: HomeViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isAddingItem = false
    @State private var label = ""
    @State private var selectedDays = Set(0...6)
    @State private var recurrence = ChecklistRecurrence.forever
    @State private var customEndDate = Date()

    var body: some View {
        NavigationStack {
            List {
                Section("Default items") {
                    checklistToggle("workout", title: "Today's Workout")
                    checklistToggle("nutrition", title: "Nutrition Plan")
                    checklistToggle("recovery", title: "Recovery Routine")
                }

                Section("Your custom items") {
                    if model.snapshot.customChecklistItems.isEmpty {
                        Text("No custom items yet.").foregroundStyle(ExecuteColor.mist)
                    } else {
                        ForEach(model.snapshot.customChecklistItems) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.label ?? "Custom item")
                                Text(itemSchedule(item)).font(ExecuteTypography.caption(11)).foregroundStyle(ExecuteColor.mist)
                            }
                            .swipeActions {
                                Button(role: .destructive) { Task { await model.deactivateCustomChecklistItem(item) } } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }
                    Button { isAddingItem.toggle() } label: {
                        Label("Add custom item", systemImage: "plus")
                    }
                    .foregroundStyle(ExecuteColor.chartreuseDark)
                }

                if isAddingItem {
                    Section("New item") {
                        TextField("e.g. Take a 20-min walk", text: $label)
                        VStack(alignment: .leading, spacing: ExecuteSpacing.xs) {
                            Text("Active on").font(ExecuteTypography.caption(11)).foregroundStyle(ExecuteColor.mist)
                            HStack(spacing: 5) {
                                ForEach(Array(dayLabels.enumerated()), id: \.offset) { index, day in
                                    Button(day) {
                                        if selectedDays.contains(index) { selectedDays.remove(index) } else { selectedDays.insert(index) }
                                    }
                                    .font(ExecuteTypography.caption(10).weight(.bold))
                                    .frame(width: 34, height: 34)
                                    .background(selectedDays.contains(index) ? ExecuteColor.chartreuse : ExecuteColor.parchmentLight)
                                    .foregroundStyle(selectedDays.contains(index) ? ExecuteColor.charcoal : ExecuteColor.olive)
                                    .clipShape(RoundedRectangle(cornerRadius: ExecuteRadius.small, style: .continuous))
                                }
                            }
                        }
                        Picker("Recur for", selection: $recurrence) {
                            ForEach(ChecklistRecurrence.allCases) { option in Text(option.title).tag(option) }
                        }
                        if recurrence == .custom {
                            DatePicker("End date", selection: $customEndDate, displayedComponents: .date)
                        }
                        Button("Add item") {
                            let endDate = recurrence.endDate(custom: customEndDate)
                            Task { await model.addCustomChecklistItem(label: label, days: selectedDays.sorted(), endsOn: endDate) }
                            label = ""
                            selectedDays = Set(0...6)
                            recurrence = .forever
                            isAddingItem = false
                        }
                        .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ExecuteColor.parchment)
            .navigationTitle("Customize Checklist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(ExecuteTypography.label(15).weight(.bold))
                        .foregroundStyle(ExecuteColor.chartreuseDark)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func checklistToggle(_ type: String, title: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { !model.hiddenChecklistDefaults.contains(type) },
            set: { model.setChecklistDefaultVisible(type, isVisible: $0) }
        ))
        .tint(ExecuteColor.chartreuseDark)
    }

    private func itemSchedule(_ item: HomeCustomChecklistItem) -> String {
        let days = item.days ?? []
        let dayText = days.count == 7 || days.isEmpty ? "Every day" : days.compactMap { dayLabels.indices.contains($0) ? dayLabels[$0] : nil }.joined(separator: ", ")
        return item.endsOn.map { "\(dayText) · Until \($0)" } ?? "\(dayText) · Forever"
    }

    private let dayLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
}

struct HomeVitalLogSheet: View {
    let vital: HomeVital
    let currentValue: Double
    let save: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value: Double

    init(vital: HomeVital, currentValue: Double, save: @escaping (Double) -> Void) {
        self.vital = vital
        self.currentValue = currentValue
        self.save = save
        _value = State(initialValue: currentValue)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: ExecuteSpacing.lg) {
                Image(systemName: vital.symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(ExecuteColor.chartreuseDark)
                    .frame(width: 64, height: 64)
                    .background(ExecuteColor.chartreuse.opacity(0.13))
                    .clipShape(Circle())
                Text(vital.title).font(ExecuteTypography.title(22))
                Text(displayValue).font(ExecuteTypography.display(36)).foregroundStyle(ExecuteColor.charcoal)
                Stepper("", value: $value, in: range, step: step)
                    .labelsHidden()
                    .scaleEffect(1.2)
                    .padding(.horizontal, ExecuteSpacing.xxl)
                Spacer()
            }
            .padding(ExecuteSpacing.xl)
            .executeScreen()
            .navigationTitle("Log \(vital.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(value)
                        dismiss()
                    }
                    .font(ExecuteTypography.label(15).weight(.bold))
                    .foregroundStyle(ExecuteColor.chartreuseDark)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var range: ClosedRange<Double> {
        switch vital {
        case .sleep: 0...18
        case .steps: 0...50_000
        case .calories: 0...10_000
        case .water: 0...10
        case .mood: 0...5
        case .energy: 0...10
        case .workout: 0...360
        case .weight: 0...350
        }
    }

    private var step: Double {
        switch vital {
        case .steps: 500
        case .calories: 50
        case .workout: 5
        case .sleep, .water, .weight: 0.1
        case .mood, .energy: 1
        }
    }

    private var displayValue: String {
        switch vital {
        case .sleep: String(format: "%.1f h", value)
        case .steps: "\(Int(value)) steps"
        case .calories: "\(Int(value)) kcal"
        case .water: String(format: "%.1f L", value)
        case .mood: "\(Int(value)) / 5"
        case .energy: "\(Int(value)) / 10"
        case .workout: "\(Int(value)) min"
        case .weight: String(format: "%.1f kg", value)
        }
    }
}

private enum ChecklistRecurrence: String, CaseIterable, Identifiable {
    case forever, sevenDays, fourteenDays, thirtyDays, custom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .forever: "Forever"
        case .sevenDays: "7 days"
        case .fourteenDays: "14 days"
        case .thirtyDays: "30 days"
        case .custom: "Custom end date"
        }
    }

    func endDate(custom: Date) -> String? {
        let calendar = Calendar.current
        let date: Date?
        switch self {
        case .forever: return nil
        case .sevenDays: date = calendar.date(byAdding: .day, value: 7, to: Date())
        case .fourteenDays: date = calendar.date(byAdding: .day, value: 14, to: Date())
        case .thirtyDays: date = calendar.date(byAdding: .day, value: 30, to: Date())
        case .custom: date = custom
        }
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
