import SwiftUI

/// Drop-in saved-plan entry point; its sheet owns only ephemeral conversation state.
struct PlanQuestionsButton: View {
    @State private var presented = false
    var body: some View {
        Button("Ask questions about your plan") { presented = true }
            .accessibilityIdentifier("plan.askQuestions")
            .sheet(isPresented: $presented) { PlanQuestionsView() }
    }
}

struct PlanQuestionsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    var body: some View { PlanQuestionsScreen(environment: environment) }
}

private struct PlanQuestionsScreen: View {
    @ObservedObject private var appState: AppState
    @StateObject private var model: PlanQuestionsModel
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    init(environment: AppEnvironment) {
        _appState = ObservedObject(wrappedValue: environment.appState)
        _model = StateObject(wrappedValue: PlanQuestionsModel(repository: environment.makeRecoveryRepository(), ai: environment.aiService, active: { environment.appState.allowsDraftWrites(for: $0) }))
    }
    private var user: ExecuteUser? { guard case .signedIn(let user) = appState.launchState else { return nil }; return user }
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: ExecuteSpacing.md) {
                        Text("Ask about training, nutrition or recovery. Answers use your current plan and logs. This conversation does not change saved data and clears when closed.").font(ExecuteTypography.body(14))
                        ForEach(model.messages) { message in
                            ExecuteCard {
                                VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
                                    Text(message.isUser ? "You" : "Coach").font(ExecuteTypography.caption(12))
                                    Text(message.text).font(ExecuteTypography.body(15)).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(ExecuteSpacing.md)
                            }.id(message.id)
                        }
                        if model.isSending { ProgressView("Preparing an answer…"); Button("Cancel answer") { model.cancel() } }
                        if let error = model.error { Text(error.message).foregroundStyle(ExecuteColor.destructive) }
                    }.padding(ExecuteSpacing.md)
                }
                .onChange(of: model.messages.count) { _ in if let id = model.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
                    TextField("Ask a question", text: $question, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("plan.questionInput")
                    Button(model.isSending ? "Sending…" : "Send question") {
                        let submitted = question
                        Task { if await model.send(submitted), question == submitted { question = "" } }
                    }.disabled(model.isSending || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("plan.sendQuestion")
                }.padding(ExecuteSpacing.md).background(ExecuteColor.parchment)
            }
            .navigationTitle("Ask a question")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { model.stop(); question = ""; dismiss() } } }
            .task(id: user?.id) { question = ""; if let user { model.start(user) } else { model.stop() } }
            .onDisappear { model.stop(); question = "" }
            .executeScreen()
        }
    }
}
