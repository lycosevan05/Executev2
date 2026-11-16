import SwiftUI

struct SplitDayEditorView: View {
    let date: String
    private let environment: AppEnvironment
    init(date: String, environment: AppEnvironment) { self.date = date; self.environment = environment }
    var body: some View { SplitDayEditorScreen(date: date, environment: environment) }
}

private struct SplitDayEditorScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appState: AppState
    @StateObject private var model: SplitDayEditorModel
    init(date: String, environment: AppEnvironment) {
        _appState = ObservedObject(wrappedValue: environment.appState)
        _model = StateObject(wrappedValue: SplitDayEditorModel(date: date, repository: environment.makeRecoveryRepository(), cache: environment.cache,
            active: { environment.appState.allowsDraftWrites(for: $0) }))
    }
    private var user: ExecuteUser? { if case .signedIn(let user) = appState.launchState { return user }; return nil }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ExecuteSpacing.md) {
                Text("Edit \(model.weekday)").font(ExecuteTypography.title(24)).accessibilityAddTraits(.isHeader)
                Text("This is a weekly template: changes apply to every \(model.weekday). Existing activity, meals and past workout records stay intact.")
                    .font(ExecuteTypography.body(14))
                if let status = model.status { Text(status).font(ExecuteTypography.body(14)).accessibilityIdentifier("split-day.status") }
                if let error = model.error { Text(error).font(ExecuteTypography.body(14)).foregroundStyle(.red).accessibilityIdentifier("split-day.error") }
                if model.busy { ProgressView(model.saving ? "Saving split…" : "Checking plan and activity…") }
                if let preview = model.preview {
                    review(preview)
                    Button(model.masterAcknowledged ? "Retry remaining changes" : "Save weekly template") { Task { await model.save() } }
                        .buttonStyle(.borderedProminent).frame(minHeight: 44).disabled(model.busy)
                        .accessibilityIdentifier("split-day.save")
                    if !model.mutationSubmitted {
                        Button("Back to editing") { model.discardReview() }.frame(minHeight: 44).disabled(model.busy)
                    }
                    if model.canReviewLocalRecovery {
                        Button("Review local retry recovery") { Task { await model.reviewLocalRecovery() } }.frame(minHeight: 44).disabled(model.busy)
                    }
                    if let recovery = model.localRecoveryReview {
                        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
                            Text("Saved changes will stay as they are").font(ExecuteTypography.label(16).weight(.bold))
                            Text(recovery.previousTemplateAcknowledged ? "The earlier template save is confirmed. Its remaining reconciliation will be left as it is." : "No matching earlier template save is currently confirmed.")
                            ForEach(recovery.affectedWorkouts) { row in
                                Text("\(row.data["date"]?.stringValue ?? "Saved date"): \(row.data["status"]?.stringValue ?? "status not recorded")")
                            }
                            if !recovery.missingWorkoutDates.isEmpty { Text("Saved workout no longer present: " + recovery.missingWorkoutDates.joined(separator: ", ")) }
                            Text("This removes only the pending retry on this device. It does not roll back or delete any saved plan, workout, meal or activity.")
                            Button("Leave saved changes and discard local retry") { Task { await model.discardLocalRetryAfterReview() } }
                                .frame(minHeight: 44).disabled(model.busy).accessibilityIdentifier("split-day.discard-local-retry")
                        }
                        .font(ExecuteTypography.body(14))
                    }
                } else if model.canEdit {
                    Toggle("Rest day", isOn: $model.draft.isRest)
                        .onChange(of: model.draft.isRest) { rest in
                            if rest { model.draft.label = "Rest" }
                            else if model.draft.label == "Rest" { model.draft.label = "" }
                        }
                        .accessibilityIdentifier("split-day.rest")
                    TextField("Workout type or focus", text: $model.draft.label).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("split-day.label")
                    if !model.draft.isRest {
                        Text("Exercises").font(ExecuteTypography.label(16).weight(.bold)).accessibilityAddTraits(.isHeader)
                        Text("Leave empty to request an AI-built workout for this type. Added exercises are used exactly as entered, without AI replacement.")
                            .font(ExecuteTypography.body(13))
                        ForEach($model.draft.exercises) { $exercise in
                            VStack(alignment: .leading, spacing: ExecuteSpacing.xs) {
                                TextField("Exercise name", text: $exercise.name).textFieldStyle(.roundedBorder)
                                HStack {
                                    TextField("Sets", text: $exercise.sets).keyboardType(.numberPad).textFieldStyle(.roundedBorder).accessibilityLabel("Sets for \(exercise.name)")
                                    TextField("Reps or timed target", text: $exercise.reps).textFieldStyle(.roundedBorder).accessibilityLabel("Rep target for \(exercise.name)")
                                    Button("Remove", role: .destructive) { model.draft.exercises.removeAll { $0.id == exercise.id } }.frame(minHeight: 44)
                                }
                            }
                            .padding(.vertical, ExecuteSpacing.xs)
                        }
                        Button("Add exercise") { model.draft.exercises.append(SplitDayExerciseDraft()) }.frame(minHeight: 44)
                            .disabled(model.draft.exercises.count >= 40).accessibilityIdentifier("split-day.add-exercise")
                    }
                    Button("Review changes") { Task { await model.review() } }.buttonStyle(.borderedProminent).frame(minHeight: 44)
                        .accessibilityIdentifier("split-day.review")
                    if model.hasOverride {
                        Button("Review reset to AI plan") { Task { await model.review(reset: true) } }.frame(minHeight: 44)
                            .accessibilityIdentifier("split-day.reset")
                    }
                } else if model.saved {
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent).frame(minHeight: 44)
                }
                if model.error != nil && model.preview == nil, let user {
                    Button("Reload split") { Task { await model.load(user: user) } }.frame(minHeight: 44).disabled(model.busy)
                }
                Button("Close") { dismiss() }.frame(minHeight: 44).disabled(model.saving)
            }
            .padding(ExecuteSpacing.md)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Weekly split")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: user?.id) { model.stop(); if let user { await model.load(user: user) } }
        .onChange(of: user?.id) { _ in model.stop() }
        .onDisappear { model.stop() }
    }
    private func review(_ preview: SplitDayEditIntent) -> some View {
        VStack(alignment: .leading, spacing: ExecuteSpacing.sm) {
            Text("Review weekly template").font(ExecuteTypography.label(17).weight(.bold)).accessibilityAddTraits(.isHeader)
            if let draft = preview.draft {
                Text(draft.isRest ? "Rest day: \(draft.label)" : "Training: \(draft.label)")
                ForEach(draft.exercises.filter { _ in !draft.isRest }) { exercise in Text("\(exercise.name): \(exercise.sets) sets · \(exercise.reps)") }
            } else { Text("Reset \(preview.weekday) to its original AI recommendation.") }
            Text("Future saved workouts to reconcile: \(preview.changes.count)")
            ForEach(preview.changes) { change in
                Text("\(change.date): \(change.archives ? "archive the incomplete plan; rebuild when needed" : "update the same plan with your exercises")")
            }
            Text("Started/completed workouts preserved: \(preview.protectedCount)")
            Text("Existing personalization caches to invalidate: \(preview.contexts.count)")
            Text("Workout logs, intake logs and meal plans are not changed. Saving updates this master plan’s weekly template; it does not start or complete a workout.")
        }
        .font(ExecuteTypography.body(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ExecuteSpacing.md)
        .background(ExecuteColor.chartreuse.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("split-day.review-impact")
    }
}
