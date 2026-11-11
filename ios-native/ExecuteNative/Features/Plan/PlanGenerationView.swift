import SwiftUI

struct PlanGenerationView: View {
    @ObservedObject var model: PlanViewModel
    let isPremium: Bool
    @FocusState private var focusedField: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Build your performance plan").font(ExecuteTypography.title(20))
            Text("Tell Execute what you want to achieve. Review your first week before saving.")
                .foregroundStyle(ExecuteColor.olive)
            if !isPremium {
                Text("Personalized plans are included with Execute Premium.")
                Button("View Premium options") { model.openBilling() }
            } else if model.revisedOverview != nil {
                PlanOverviewPreview(model: model)
            } else {
                questionnaire.disabled(model.isRefining || model.isSaving || model.isInitialLoading)
                Button("Generate plan preview") { Task { await model.generateInitialPlan() } }
                    .buttonStyle(.borderedProminent).tint(ExecuteColor.chartreuseDark)
                    .disabled(!model.canGenerate).accessibilityIdentifier("plan.generate")
            }
            if model.isRefining || model.isSaving { ProgressView(model.isSaving ? "Saving plan…" : "Building your first week…") }
            if let error = model.editError { Text(error.message).foregroundStyle(ExecuteColor.destructive).accessibilityIdentifier("plan.generation.error") }
            if let status = model.editStatus { Text(status) }
        }
        .font(ExecuteTypography.body(14))
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(ExecuteColor.parchmentLight)
        .clipShape(RoundedRectangle(cornerRadius: ExecuteHomeStyle.cardRadius))
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focusedField = nil } } }
    }

    private var questionnaire: some View {
        VStack(alignment: .leading, spacing: 20) {
            Group {
                picker("Plan focus", value: $model.questionnaire.planType, options: [("daily_performance", "Complete performance"), ("workout", "Training"), ("nutrition", "Nutrition")])
                picker("Primary goal", value: $model.questionnaire.goal, options: [("feel_better", "Feel better"), ("get_stronger", "Get stronger"), ("build_muscle", "Build muscle"), ("lose_fat", "Lose fat"), ("improve_flexibility", "Improve flexibility"), ("sport_specific", "Sport performance")])
                picker("Approach", value: $model.questionnaire.optimize, options: [("balanced", "Balanced"), ("consistent", "Consistency"), ("injury_safe", "Low stress"), ("fastest", "Fastest progress")])
                Text("Starting details").font(.headline)
                field("Age", value: $model.questionnaire.age, numeric: true)
                picker("Sex for starting targets", value: $model.questionnaire.sex, options: [("", "Choose"), ("male", "Male"), ("female", "Female")])
                field("Weight (kg)", value: $model.questionnaire.weightKg, numeric: true)
                field("Height (cm)", value: $model.questionnaire.heightCm, numeric: true)
                picker("Current training", value: $model.questionnaire.currentTraining, options: [("never", "Never / rarely"), ("1_2_days", "1–2 days a week"), ("3_4_days", "3–4 days a week"), ("5_plus", "5+ days a week")])
            }
            if model.questionnaire.planType != "nutrition" {
                Group {
                    Text("Training & recovery").font(.headline)
                    picker("Target training days", value: $model.questionnaire.trainingDays, options: [("2_or_less", "2 or less"), ("3_5", "3–5"), ("5_7", "5–7")])
                    picker("Session length", value: $model.questionnaire.sessionLength, options: [("20", "20 minutes"), ("30", "30 minutes"), ("45", "45 minutes"), ("60", "60 minutes"), ("75", "75+ minutes"), ("best", "Flexible")])
                    picker("Training location", value: $model.questionnaire.trainingLocation, options: [("home", "Home"), ("gym", "Gym"), ("outdoors", "Outdoors"), ("mixed", "Mixed")])
                    field("Available equipment", value: $model.questionnaire.equipment)
                    field("Limitations to consider (optional)", value: $model.questionnaire.limitations)
                    field("Sport, goals and weekly schedule (optional)", value: $model.questionnaire.sportSchedule)
                }
            }
            Group {
                Text("Nutrition preferences").font(.headline)
                picker("Meals per day", value: $model.questionnaire.mealsPerDay, options: [("2", "2"), ("3", "3"), ("4", "4"), ("5", "5+")])
                field("Dietary style (optional)", value: $model.questionnaire.diet)
                field("Food allergies (optional)", value: $model.questionnaire.allergies)
                field("Foods to avoid (optional)", value: $model.questionnaire.foodsToAvoid)
                field("Favorite foods (optional)", value: $model.questionnaire.favoriteFoods)
                field("Supplements (optional)", value: $model.questionnaire.supplements)
            }
            Group {
                Text("Make it work for you").font(.headline)
                field("Desired outcome", value: $model.questionnaire.desiredOutcome)
                field("Main barrier", value: $model.questionnaire.mainBarrier)
                picker("Coaching style", value: $model.questionnaire.coachingStyle, options: [("supportive", "Supportive"), ("direct", "Direct"), ("educational", "Explain the why")])
                field("Anything else? (optional)", value: $model.questionnaire.additionalNotes)
            }
        }
    }

    private func field(_ title: String, value: Binding<String>, numeric: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout)
            TextField(title, text: value, axis: .vertical)
                .keyboardType(numeric ? .decimalPad : .default)
                .focused($focusedField, equals: title)
                .textFieldStyle(.roundedBorder).accessibilityLabel(title)
        }
    }
    private func picker(_ title: String, value: Binding<String>, options: [(String, String)]) -> some View {
        let selected = options.first { $0.0 == value.wrappedValue }?.1 ?? "Choose"
        return Picker(selection: value) {
            ForEach(options, id: \.0) { value, label in Text(label).tag(value) }
        } label: {
            HStack { Text(title); Spacer(); Text(selected).foregroundStyle(ExecuteColor.olive) }
        }.pickerStyle(.menu).accessibilityLabel(title).accessibilityValue(selected)
    }
}

struct PlanOverviewPreview: View {
    @ObservedObject var model: PlanViewModel
    var body: some View {
        if let revised = model.revisedOverview {
            VStack(alignment: .leading, spacing: 12) {
                Text("Review your week").font(.headline)
                Text(revised["plan_summary"]?["primary_goal"]?.stringValue ?? "Your personalized overview")
                if let targets = revised["nutrition_targets"] {
                    Text("Daily targets: \(Int(targets["calories"]?.doubleValue ?? 0)) kcal · \(Int(targets["protein_g"]?.doubleValue ?? 0)) g protein · \(Int(targets["carbs_g"]?.doubleValue ?? 0)) g carbs · \(Int(targets["fat_g"]?.doubleValue ?? 0)) g fat")
                }
                if case .array(let days) = revised["weekly_overview"]?["days"] {
                    ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(day["date"]?.stringValue ?? "") · \(day["day_type"]?.stringValue ?? "")").font(.caption)
                            Text(day["session_title"]?.stringValue ?? "").font(.headline)
                            Text(day["priority"]?.stringValue ?? "")
                        }.padding(.vertical, 4)
                    }
                }
                Button("Save plan") { Task { await model.saveRevision() } }
                    .buttonStyle(.borderedProminent).tint(ExecuteColor.chartreuseDark)
                    .disabled(model.isSaving).accessibilityIdentifier("plan.saveInitial")
                Button("Back to answers") { model.discardRevision() }.disabled(model.isSaving)
            }.accessibilityIdentifier("plan.initialPreview")
        }
    }
}
