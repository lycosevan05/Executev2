import SwiftUI
import UniformTypeIdentifiers

struct TrackPendingCard: View {
    @ObservedObject var model: TrackViewModel
    var body: some View {
        if let pending = model.pending {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(pending.title) change awaiting confirmation").font(.headline)
                Text("Date: \(pending.date). Check the saved value before adding another entry.").font(.callout)
                if let summary = model.reviewSummary { Text(summary).font(.caption).textSelection(.enabled) }
                Button("Check saved change") { Task { await model.reviewPending() } }.frame(minHeight: 44)
                Button("Retry pending change") { Task { await model.retryPending() } }.frame(minHeight: 44)
                if model.reviewedPending {
                    Button("Keep saved data and discard pending change", role: .destructive) { Task { await model.keepReviewedSavedData() } }
                        .frame(minHeight: 44)
                }
            }
            .padding().background(ExecuteColor.parchmentLight).clipShape(RoundedRectangle(cornerRadius: 16))
            .disabled(model.working)
        }
    }
}

struct TrackCustomCard: View {
    let definition: CustomTrackerDefinition
    let value: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Label(definition.label, systemImage: definition.symbol).font(.headline)
                Text(value).font(.title2).monospacedDigit()
                Text(definition.unit).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            .padding().background(ExecuteColor.parchmentLight).clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain).accessibilityLabel("\(definition.label), \(value) \(definition.unit). Log value")
    }
}

struct TrackCustomLogSheet: View {
    let definition: CustomTrackerDefinition
    let save: (Double) -> Void
    @State private var text: String
    @Environment(\.dismiss) private var dismiss
    init(definition: CustomTrackerDefinition, value: Double?, save: @escaping (Double) -> Void) {
        self.definition = definition; self.save = save
        _text = State(initialValue: value.map { String($0) } ?? "")
    }
    private var number: Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite, abs(value) <= 1_000_000_000 else { return nil }
        return value
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(definition.label) {
                    TextField("Value in \(definition.unit)", text: $text).keyboardType(.numbersAndPunctuation)
                        .accessibilityLabel("\(definition.label) in \(definition.unit)")
                    Text("Saving replaces today's value. Zero is a saved value.").font(.caption)
                }
                Button("Save value") { if let number { save(number); dismiss() } }.disabled(number == nil)
            }
            .navigationTitle("Log \(definition.label)")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct TrackCustomManagement: View {
    @ObservedObject var model: TrackViewModel
    @State private var name = ""
    @State private var unit = ""
    @State private var symbol = "pencil"
    @State private var message: String?
    let onRemove: (CustomTrackerDefinition) -> Void
    let onTransfer: () -> Void
    var body: some View {
        Section("Custom trackers") {
            if let settingsError = model.settingsError { Text(settingsError).foregroundStyle(.red) }
            ForEach(model.customTrackers) { item in
                VStack(alignment: .leading) {
                    Toggle(isOn: Binding(get: { !item.hidden }, set: { _ in model.toggleCustom(item.id) })) {
                        Label("\(item.label) · \(item.unit)", systemImage: item.symbol)
                    }
                    Button("Remove \(item.label)", role: .destructive) { onRemove(item) }.frame(minHeight: 44)
                }
            }
            TextField("Tracker name", text: $name)
            TextField("Unit (optional)", text: $unit)
            Picker("Icon", selection: $symbol) {
                ForEach(CustomTrackerDefinition.symbols, id: \.self) { item in Label(item, systemImage: item).tag(item) }
            }
            Button("Create tracker") {
                do { try model.addCustom(label: name, unit: unit, symbol: symbol); name = ""; unit = ""; message = nil }
                catch { message = error.localizedDescription }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.settingsError != nil)
            if let message { Text(message).foregroundStyle(.red) }
            Button("Import or export tracker definitions", action: onTransfer)
            Text("Definitions and visibility are saved on this device for \(model.accountLabel). Recorded values stay with your account.").font(.caption)
        }
    }
}

struct TrackDefinitionTransfer: View {
    @ObservedObject var model: TrackViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var preview: [CustomTrackerDefinition] = []
    @State private var previewOwner: UUID?
    @State private var confirmed = false
    @State private var message: String?
    @State private var choosingFile = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Export") {
                    ShareLink("Export this account's definitions", item: model.exportJSON)
                    Text("This transfers names, units and icons. Saved log values remain in your account.").font(.caption)
                }
                Section("Import") {
                    Text("Choose or paste a tracker JSON export from your previous app. Old exports do not identify an account; only import definitions you recognize as yours.").font(.callout)
                    Button("Choose JSON file") { choosingFile = true }
                    TextEditor(text: $text).frame(minHeight: 140).accessibilityLabel("Tracker JSON export")
                    Button("Review import") {
                        do { preview = try model.previewImport(text); previewOwner = model.currentOwner; confirmed = false; message = nil }
                        catch { preview = []; previewOwner = nil; message = error.localizedDescription }
                    }
                    ForEach(preview) { item in Label("\(item.label) · \(item.unit)", systemImage: item.symbol) }
                    if previewOwner != nil {
                        Toggle("These definitions belong to \(model.accountLabel)", isOn: $confirmed)
                        Button("Import reviewed definitions") {
                            do {
                                guard let previewOwner else { return }
                                try model.importCustom(text, confirmedOwner: previewOwner); dismiss()
                            } catch { message = error.localizedDescription }
                        }.disabled(!confirmed || model.currentOwner != previewOwner)
                    }
                    if let message { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Transfer trackers")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .onChange(of: text) { _ in preview = []; previewOwner = nil; confirmed = false }
            .onChange(of: model.currentOwner) { _ in preview = []; previewOwner = nil; confirmed = false; text = "" }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get(), scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 100_000 else { throw TrackPersistence.invalid("Choose an export under 100 KB.") }
                    text = try String(contentsOf: url, encoding: .utf8)
                } catch { message = "The file could not be imported. Choose a readable JSON tracker export under 100 KB." }
            }
        }
    }
}
