import Foundation

/// Retained mounted catalog from src/pages/Workouts.jsx; static browsing never writes activity.
struct TrainLibraryExercise: Identifiable {
    let id: Int
    let name: String
    let muscles: String
    let category: String
    let equipment: String
    let difficulty: String
    let notes: String

    static let all: [TrainLibraryExercise] = [
        .init(id: 1, name: "Barbell Bench Press", muscles: "Chest, Triceps, Shoulders", category: "Push", equipment: "Barbell", difficulty: "intermediate", notes: "Retract shoulder blades. Controlled descent. Touch chest lightly."),
        .init(id: 2, name: "Overhead Press", muscles: "Shoulders, Triceps, Core", category: "Push", equipment: "Barbell", difficulty: "intermediate", notes: "Tight core. Press bar in a slight arc over head. Lock out at top."),
        .init(id: 3, name: "Incline Dumbbell Press", muscles: "Upper Chest, Front Delts", category: "Push", equipment: "Dumbbells", difficulty: "intermediate", notes: "30–45° incline. Elbows at 45° to body. Full range of motion."),
        .init(id: 4, name: "Dumbbell Shoulder Press", muscles: "Shoulders, Triceps", category: "Push", equipment: "Dumbbells", difficulty: "beginner", notes: "Neutral grip or pronated. Press overhead, slight forward lean is fine."),
        .init(id: 5, name: "Lateral Raise", muscles: "Lateral Delts", category: "Push", equipment: "Dumbbells", difficulty: "beginner", notes: "Slight forward lean. Raise to shoulder height. Control descent."),
        .init(id: 6, name: "Cable Fly", muscles: "Chest, Anterior Delts", category: "Push", equipment: "Cable", difficulty: "beginner", notes: "Slight elbow bend throughout. Think hugging a tree."),
        .init(id: 7, name: "Tricep Pushdown", muscles: "Triceps", category: "Push", equipment: "Cable", difficulty: "beginner", notes: "Elbows tucked at sides. Full extension at bottom."),
        .init(id: 8, name: "Close-Grip Bench Press", muscles: "Triceps, Chest", category: "Push", equipment: "Barbell", difficulty: "intermediate", notes: "Hands shoulder-width apart. Keep elbows close to body."),
        .init(id: 9, name: "Dips", muscles: "Chest, Triceps, Shoulders", category: "Push", equipment: "Dip bars", difficulty: "intermediate", notes: "Lean forward slightly for chest emphasis. Full lockout at top."),
        .init(id: 10, name: "Arnold Press", muscles: "Shoulders, Triceps", category: "Push", equipment: "Dumbbells", difficulty: "intermediate", notes: "Rotate wrists from palms-in to palms-out as you press."),
        .init(id: 11, name: "Push-Up", muscles: "Chest, Triceps, Shoulders", category: "Push", equipment: "None", difficulty: "beginner", notes: "Hands slightly wider than shoulders. Core tight. Full depth."),
        .init(id: 12, name: "Overhead Tricep Extension", muscles: "Triceps Long Head", category: "Push", equipment: "Dumbbell or Cable", difficulty: "beginner", notes: "Keep elbows close to ears. Full stretch at bottom."),
        .init(id: 13, name: "Deadlift", muscles: "Hamstrings, Glutes, Back", category: "Pull", equipment: "Barbell", difficulty: "advanced", notes: "Neutral spine throughout. Hinge at hips first, then knees."),
        .init(id: 14, name: "Pull-Up", muscles: "Lats, Biceps, Rear Delts", category: "Pull", equipment: "Pull-up bar", difficulty: "intermediate", notes: "Full hang at bottom. Drive elbows down and back to chest."),
        .init(id: 15, name: "Barbell Row", muscles: "Lats, Rhomboids, Biceps", category: "Pull", equipment: "Barbell", difficulty: "intermediate", notes: "Hinge to ~45°. Pull bar to lower chest. Squeeze scapula."),
        .init(id: 16, name: "Dumbbell Row", muscles: "Lats, Rhomboids, Biceps", category: "Pull", equipment: "Dumbbell", difficulty: "beginner", notes: "Stable base. Pull elbow toward hip. Full stretch at bottom."),
        .init(id: 17, name: "Face Pull", muscles: "Rear Delts, Rotator Cuff", category: "Pull", equipment: "Cable", difficulty: "beginner", notes: "Pull toward face with external rotation. Great for shoulder health."),
        .init(id: 18, name: "Lat Pulldown", muscles: "Lats, Biceps", category: "Pull", equipment: "Cable", difficulty: "beginner", notes: "Slight lean back. Pull bar to upper chest. Full stretch at top."),
        .init(id: 19, name: "Bicep Curl", muscles: "Biceps, Brachialis", category: "Pull", equipment: "Dumbbells or Barbell", difficulty: "beginner", notes: "No swinging. Supinate wrist at top of movement."),
        .init(id: 20, name: "Hammer Curl", muscles: "Brachialis, Brachioradialis", category: "Pull", equipment: "Dumbbells", difficulty: "beginner", notes: "Neutral grip throughout. Elbows stay at sides."),
        .init(id: 21, name: "Seated Cable Row", muscles: "Mid Back, Lats, Biceps", category: "Pull", equipment: "Cable", difficulty: "beginner", notes: "Tall posture. Drive elbows back. Squeeze mid-back at peak."),
        .init(id: 22, name: "T-Bar Row", muscles: "Lats, Rhomboids, Lower Traps", category: "Pull", equipment: "Barbell", difficulty: "intermediate", notes: "Chest against pad if available. Pull to sternum. Controlled negative."),
        .init(id: 23, name: "Chest-Supported Row", muscles: "Upper Back, Rear Delts", category: "Pull", equipment: "Dumbbells", difficulty: "beginner", notes: "Eliminates lower back involvement. Pull elbows wide for upper back."),
        .init(id: 24, name: "Chin-Up", muscles: "Lats, Biceps", category: "Pull", equipment: "Pull-up bar", difficulty: "intermediate", notes: "Supinated grip. Initiate with scapula retraction, then pull."),
        .init(id: 25, name: "Barbell Squat", muscles: "Quads, Glutes, Core", category: "Legs", equipment: "Barbell", difficulty: "intermediate", notes: "Keep chest up, knees tracking over toes. Drive through heels."),
        .init(id: 26, name: "Romanian Deadlift", muscles: "Hamstrings, Glutes", category: "Legs", equipment: "Barbell or Dumbbells", difficulty: "beginner", notes: "Slight knee bend. Push hips back. Feel stretch in hamstrings."),
        .init(id: 27, name: "Hip Thrust", muscles: "Glutes, Hamstrings", category: "Legs", equipment: "Barbell", difficulty: "beginner", notes: "Drive through heels. Squeeze glutes hard at the top."),
        .init(id: 28, name: "Bulgarian Split Squat", muscles: "Quads, Glutes", category: "Legs", equipment: "Dumbbells", difficulty: "intermediate", notes: "Front foot does the work. Rear foot for balance only."),
        .init(id: 29, name: "Leg Press", muscles: "Quads, Glutes, Hamstrings", category: "Legs", equipment: "Machine", difficulty: "beginner", notes: "Feet shoulder-width. Do not lock knees at top. Full depth."),
        .init(id: 30, name: "Leg Curl", muscles: "Hamstrings", category: "Legs", equipment: "Machine", difficulty: "beginner", notes: "Slow eccentric. Avoid hip rise. Squeeze at full contraction."),
        .init(id: 31, name: "Leg Extension", muscles: "Quadriceps", category: "Legs", equipment: "Machine", difficulty: "beginner", notes: "Full range. Pause briefly at top. Control the descent."),
        .init(id: 32, name: "Walking Lunge", muscles: "Quads, Glutes, Hamstrings", category: "Legs", equipment: "Dumbbells or Barbell", difficulty: "beginner", notes: "Long stride. Front knee tracks over toe. Tall torso."),
        .init(id: 33, name: "Sumo Deadlift", muscles: "Glutes, Adductors, Hamstrings", category: "Legs", equipment: "Barbell", difficulty: "intermediate", notes: "Wide stance, toes out. Hips close to bar. Drive knees out."),
        .init(id: 34, name: "Hack Squat", muscles: "Quads, Glutes", category: "Legs", equipment: "Machine", difficulty: "intermediate", notes: "Feet low on platform for more quad. Control descent fully."),
        .init(id: 35, name: "Calf Raise", muscles: "Gastrocnemius, Soleus", category: "Legs", equipment: "Machine or Dumbbell", difficulty: "beginner", notes: "Full stretch at bottom. Full contraction at top. Slow tempo."),
        .init(id: 36, name: "Goblet Squat", muscles: "Quads, Glutes, Core", category: "Legs", equipment: "Dumbbell or Kettlebell", difficulty: "beginner", notes: "Hold weight at chest. Deep squat. Elbows inside knees at bottom."),
        .init(id: 37, name: "Plank", muscles: "Core, Shoulders", category: "Core", equipment: "None", difficulty: "beginner", notes: "Neutral spine. Breathe steadily. Don't let hips drop or rise."),
        .init(id: 38, name: "Cable Crunch", muscles: "Rectus Abdominis", category: "Core", equipment: "Cable", difficulty: "beginner", notes: "Kneel and crunch through the abs — not the hip flexors."),
        .init(id: 39, name: "Hanging Leg Raise", muscles: "Lower Abs, Hip Flexors", category: "Core", equipment: "Pull-up bar", difficulty: "intermediate", notes: "Tuck chin. Control the swing. Exhale at the top of the movement."),
        .init(id: 40, name: "Ab Rollout", muscles: "Core, Lats, Shoulders", category: "Core", equipment: "Ab wheel", difficulty: "intermediate", notes: "Keep lower back neutral. Roll out slowly. Pull back with lats."),
        .init(id: 41, name: "Pallof Press", muscles: "Anti-Rotation Core", category: "Core", equipment: "Cable", difficulty: "beginner", notes: "Stand sideways to cable. Press out and hold. Resist rotation."),
        .init(id: 42, name: "Dead Bug", muscles: "Deep Core, Transverse Abs", category: "Core", equipment: "None", difficulty: "beginner", notes: "Lower back pressed to floor. Extend opposite arm and leg. Breathe."),
        .init(id: 43, name: "Russian Twist", muscles: "Obliques, Core", category: "Core", equipment: "Weight plate or Dumbbell", difficulty: "beginner", notes: "Lean back 45°. Rotate slowly. Keep feet elevated for more challenge."),
        .init(id: 44, name: "Box Jump", muscles: "Quads, Glutes, Calves", category: "Cardio", equipment: "Plyo box", difficulty: "intermediate", notes: "Soft landing. Absorb with hips and knees. Step down — don't jump."),
        .init(id: 45, name: "Kettlebell Swing", muscles: "Glutes, Hamstrings, Core", category: "Cardio", equipment: "Kettlebell", difficulty: "intermediate", notes: "Hip hinge — not a squat. Drive hips forward explosively. Neutral spine."),
        .init(id: 46, name: "Battle Ropes", muscles: "Shoulders, Core, Full Body", category: "Cardio", equipment: "Battle ropes", difficulty: "beginner", notes: "Maintain slight squat. Alternate or double waves. Stay in a rhythm."),
        .init(id: 47, name: "Sled Push", muscles: "Quads, Glutes, Core", category: "Cardio", equipment: "Sled", difficulty: "intermediate", notes: "Lean into the sled. Drive through full foot. Short fast steps."),
        .init(id: 48, name: "Rowing Machine", muscles: "Full Body, Back, Legs", category: "Cardio", equipment: "Rowing machine", difficulty: "beginner", notes: "Drive with legs first, then lean back, then pull arms. Reverse on return."),
        .init(id: 49, name: "Burpee", muscles: "Full Body", category: "Cardio", equipment: "None", difficulty: "beginner", notes: "Maintain consistent pace. Land soft. Jump with arms overhead."),
        .init(id: 50, name: "Jump Rope", muscles: "Calves, Shoulders, Coordination", category: "Cardio", equipment: "Jump rope", difficulty: "beginner", notes: "Stay on balls of feet. Small jumps. Wrists do most of the rotation."),
        .init(id: 51, name: "Mountain Climbers", muscles: "Core, Shoulders, Hip Flexors", category: "Cardio", equipment: "None", difficulty: "beginner", notes: "Keep hips level. Drive knees toward chest in a running motion."),
        .init(id: 52, name: "Assault Bike Sprint", muscles: "Full Body, Cardiovascular", category: "Cardio", equipment: "Assault bike", difficulty: "intermediate", notes: "Push and pull handles while pedaling. All-out effort for short intervals."),
    ]
    static let categories = ["All", "Push", "Pull", "Legs", "Core", "Cardio"]
}
