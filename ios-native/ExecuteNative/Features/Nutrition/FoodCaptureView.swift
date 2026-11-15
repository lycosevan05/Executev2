import SwiftUI
import PhotosUI
import VisionKit
import Vision
import AVFoundation

struct FoodCaptureSheet: View {
    let kind: FoodCaptureKind
    private let captureDate: String
    private let captureDateLabel: String
    @ObservedObject private var appState: AppState
    @StateObject private var capture: FoodCaptureModel
    @ObservedObject private var nutrition: NutritionViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var photoItem: PhotosPickerItem?
    @State private var jpeg: Data?
    @State private var photoRequest = UUID()
    @State private var operation: Task<Void, Never>?
    @State private var photoLoad: Task<Void, Never>?
    @State private var camera = false
    @State private var scanner = false
    @State private var cameraError: String?
    @State private var code = ""
    @State private var name = ""
    @State private var portion = ""
    @State private var calories = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fats = ""
    @State private var meal = NutritionMealType.snack

    init(kind: FoodCaptureKind, nutrition: NutritionViewModel, environment: AppEnvironment) {
        self.kind = kind; self.nutrition = nutrition
        captureDate = nutrition.dateString; captureDateLabel = nutrition.dateLabel
        _appState = ObservedObject(wrappedValue: environment.appState)
        _capture = StateObject(wrappedValue: FoodCaptureModel(data: environment.dataService, ai: environment.aiService,
            canUsePhoto: { environment.appState.premiumState.isPremium },
            canAct: { environment.appState.allowsDraftWrites(for: $0) }))
    }

    private var user: ExecuteUser? {
        guard case .signedIn(let user) = appState.launchState else { return nil }; return user
    }
    var body: some View {
        NavigationStack {
            Form {
                Section { Text("\(captureDateLabel) · Review nutrition before saving.") }
                if let error = cameraError { Section { Text(error).foregroundStyle(ExecuteColor.destructive) } }
                if let error = capture.error { Section { Text(error.message).foregroundStyle(ExecuteColor.destructive) } }
                if capture.hasAttempt {
                    Section { Text("A previous save needs verification. Retry checks the same entry and synchronizes its daily totals.") }
                }
                if capture.review == nil {
                    if kind == .photo { photoInput } else { barcodeInput }
                } else { reviewInput }
                if capture.isWorking { Section { ProgressView(capture.hasAttempt ? "Checking saved food…" : "Preparing review…") } }
            }
            .scrollContentBackground(.hidden)
            .background(ExecuteColor.parchment)
            .navigationTitle(kind == .photo ? "Photo Food Log" : "Barcode Food Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .interactiveDismissDisabled(capture.isWorking)
        .task(id: user?.id) {
            operation?.cancel(); photoLoad?.cancel()
            photoRequest = UUID(); jpeg = nil; photoItem = nil; code = ""
            if let user { capture.start(user: user, date: captureDate) }
            else { capture.stop(); dismiss() }
        }
        .onChange(of: capture.review) { value in
            guard let value else { return }
            name = value.draft.name; portion = value.portion; meal = value.draft.mealType
            calories = String(value.draft.calories); protein = String(value.draft.protein)
            carbs = String(value.draft.carbs); fats = String(value.draft.fats)
        }
        .onChange(of: photoItem) { item in
            photoLoad?.cancel()
            let request = UUID(); photoRequest = request
            photoLoad = Task {
                do {
                    guard let data = try await item?.loadTransferable(type: Data.self), request == photoRequest, !Task.isCancelled else { return }
                    let prepared = try FoodPhoto.jpeg(data)
                    guard request == photoRequest else { return }; jpeg = prepared; cameraError = nil
                } catch { if request == photoRequest { cameraError = "The photo could not be opened. Try another image under 20 MB." } }
            }
        }
        .onChange(of: scenePhase) { phase in if phase != .active { scanner = false; camera = false } }
        .onDisappear { operation?.cancel(); photoLoad?.cancel(); photoRequest = UUID(); jpeg = nil; capture.stop() }
        .sheet(isPresented: $camera) {
            FoodCamera { data in
                camera = false
                do { jpeg = try FoodPhoto.jpeg(data); cameraError = nil }
                catch { cameraError = "The photo could not be prepared. Try a smaller image or manual entry." }
            } cancel: { camera = false }
        }
        .sheet(isPresented: $scanner) {
            NavigationStack {
                FoodBarcodeScanner { value in
                    scanner = false; code = value
                    lookUp(value)
                } failed: { message in scanner = false; cameraError = message }
                .navigationTitle("Scan product barcode")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanner = false } } }
            }
        }
    }

    private var photoInput: some View {
        Section("Selected food photo") {
            Text("Choose a meal photo or take one. Only the selected image is sent for AI analysis when you tap Estimate. Location and camera metadata are removed, and the photo is not kept in your food log.")
                .font(.footnote)
            if let jpeg, let image = UIImage(data: jpeg) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240).accessibilityLabel("Selected food photo")
            }
            PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) { Label("Choose food photo", systemImage: "photo") }
            Button { Task { await openCamera(forBarcode: false) } } label: { Label("Take food photo", systemImage: "camera") }
            Button("Estimate selected photo") { if let jpeg { operation = Task { await capture.estimatePhoto(jpeg) } } }
                .disabled(jpeg == nil || capture.isWorking || !appState.premiumState.isPremium)
            if !appState.premiumState.isPremium { Text("Photo estimates require Premium.").font(.footnote) }
            Text("Photo nutrition is an estimate. Check portions and ingredients before logging.").font(.footnote)
        }.disabled(capture.isWorking)
    }

    private var barcodeInput: some View {
        Section("Product barcode") {
            TextField("8, 12, 13 or 14 digit barcode", text: $code).keyboardType(.numberPad).accessibilityIdentifier("capture.barcode")
            Button("Look up barcode") { lookUp(code) }.disabled(FoodBarcode.normalized(code) == nil || capture.isWorking)
            Button { Task { await openCamera(forBarcode: true) } } label: { Label("Scan with camera", systemImage: "barcode.viewfinder") }
            Text("Product lookup uses Open Food Facts community data. Check the package and serving basis. Missing product details can be entered with Add food manually.").font(.footnote)
            Link("Open Food Facts · Open Database License", destination: URL(string: "https://world.openfoodfacts.org/data")!)
        }.disabled(capture.isWorking)
    }

    private var reviewInput: some View {
        Group {
            Section("Review food") {
                Text(capture.review?.source ?? "").font(.footnote)
                if let barcode = capture.review?.barcode { Text("Barcode: \(barcode)").font(.footnote) }
                TextField("Food name", text: $name).accessibilityLabel("Food name")
                TextField("Portion", text: $portion).accessibilityLabel("Portion")
                Text("Nutrition values below are for the displayed portion. If you change the portion, adjust the values to match.").font(.footnote)
                Picker("Meal", selection: $meal) { ForEach(NutritionMealType.allCases) { Text($0.title).tag($0) } }
                numberField("Calories", unit: "kcal", value: $calories)
                numberField("Protein", unit: "g", value: $protein)
                numberField("Carbs", unit: "g", value: $carbs)
                numberField("Fats", unit: "g", value: $fats)
            }.disabled(capture.isWorking || capture.hasAttempt)
            Section {
                Button(capture.hasAttempt ? "Retry saved food" : "Save reviewed food") {
                    guard let review = editedReview, let user else { return }
                    operation = Task {
                        let date = captureDate
                        if await capture.save(review, synchronize: {
                            await nutrition.synchronizeCapturedFood(ownerID: user.id, date: date, canWrite: { appState.allowsDraftWrites(for: user.id) })
                        }) { dismiss() }
                    }
                }.disabled(editedReview == nil || capture.isWorking)
                if !capture.hasAttempt { Button("Choose another") { capture.clearReview(); jpeg = nil; photoItem = nil } }
            }
        }
    }

    private func numberField(_ title: String, unit: String, value: Binding<String>) -> some View {
        HStack { Text("\(title) (\(unit))"); TextField(title, text: value).keyboardType(.decimalPad).multilineTextAlignment(.trailing).accessibilityLabel(title) }
    }
    private func lookUp(_ value: String) { operation?.cancel(); operation = Task { await capture.findProduct(value) } }
    private var editedReview: FoodCaptureReview? {
        func number(_ value: String) -> Double? { Double(value.replacingOccurrences(of: ",", with: ".")) }
        guard var review = capture.review, let calories = number(calories), let protein = number(protein), let carbs = number(carbs), let fats = number(fats),
              !portion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        review.portion = portion
        review.draft = NutritionEntryDraft(name: name, mealType: meal, calories: calories, protein: protein, carbs: carbs, fats: fats, method: review.draft.method)
        return NutritionEntryFactory.payload(from: review.draft, date: captureDate) == nil ? nil : review
    }
    private func openCamera(forBarcode: Bool) async {
        guard let requestingUser = user, appState.allowsDraftWrites(for: requestingUser.id) else { return }
        guard forBarcode ? DataScannerViewController.isSupported : UIImagePickerController.isSourceTypeAvailable(.camera) else {
            cameraError = forBarcode ? "Camera scanning is unavailable here. Type the barcode instead." : "The camera is unavailable here. Choose a food photo instead."
            return
        }
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        default: allowed = false
        }
        guard allowed else { cameraError = "Camera access is unavailable. You can choose a photo or type the barcode, or allow Camera in Settings."; return }
        guard user?.id == requestingUser.id, appState.allowsDraftWrites(for: requestingUser.id), scenePhase == .active else { return }
        cameraError = nil
        if forBarcode {
            guard DataScannerViewController.isAvailable else { cameraError = "Camera scanning is currently unavailable. Type the barcode instead."; return }
            scanner = true
        } else { camera = true }
    }
}

private struct FoodCamera: UIViewControllerRepresentable {
    let selected: (Data) -> Void
    let cancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController(); controller.sourceType = .camera; controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: FoodCamera
        init(parent: FoodCamera) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.cancel() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.85) else { parent.cancel(); return }
            parent.selected(data)
        }
    }
}

private struct FoodBarcodeScanner: UIViewControllerRepresentable {
    let selected: (String) -> Void
    let failed: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.ean8, .ean13, .upce])], qualityLevel: .balanced,
            recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        do { try controller.startScanning() } catch { Task { failed("Scanning could not start. Type the barcode instead.") } }
        return controller
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { coordinator.cancel(); controller.stopScanning() }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let parent: FoodBarcodeScanner
        private var delivered = false
        init(parent: FoodBarcodeScanner) { self.parent = parent }
        func cancel() { delivered = true }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            consume(addedItems, controller: dataScanner)
        }
        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            consume(updatedItems, controller: dataScanner)
        }
        private func consume(_ items: [RecognizedItem], controller: DataScannerViewController) {
            guard !delivered else { return }
            for item in items {
                if case .barcode(let barcode) = item, let raw = barcode.payloadStringValue {
                    let code = barcode.observation.symbology == .upce ? (FoodBarcode.expandedUPCE(raw) ?? (raw.count == 12 ? FoodBarcode.normalized(raw) : nil)) : FoodBarcode.normalized(raw)
                    guard let code else { continue }
                    delivered = true; controller.stopScanning(); parent.selected(code); return
                }
            }
        }
        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            guard !delivered else { return }; delivered = true; dataScanner.stopScanning(); parent.failed("Scanning is unavailable. Type the barcode instead.")
        }
    }
}
