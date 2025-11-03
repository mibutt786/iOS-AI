import SwiftUI
import PhotosUI
import VisionKit
import EventKit

struct EventScannerView: View {
    @StateObject var viewModel = EventScannerViewModel()
    @State private var photoPickerItem: PhotosPickerItem? = nil
    
    var body: some View {
        VStack(spacing: 16) {
            PhotosPicker(
                selection: $photoPickerItem,
                matching: .images,
                photoLibrary: .shared()) {
                    Text("Select Image")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            if let image = viewModel.selectedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 300)
                    .cornerRadius(8)
                    .shadow(radius: 4)
            }
            
            Button("Fetch Event Details") {
                Task {
                    do {
                        try await viewModel.recognizeText()
                    } catch {
                        await MainActor.run {
                            viewModel.saveError = error.localizedDescription
                        }
                    }
                }
            }
            .disabled(viewModel.selectedImage == nil)
            .buttonStyle(.borderedProminent)
            
            if !viewModel.recognizedText.isEmpty {
                DisclosureGroup("Recognized Text") {
                    ScrollView {
                        Text(viewModel.recognizedText)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(8)
                }
                .padding(.horizontal)
            }
            
            if let event = viewModel.parsedEvent {
                VStack(alignment: .leading, spacing: 8) {
                    Text(event.title)
                        .font(.title2)
                        .bold()
                    if let date = event.date ?? event.startTime {
                        Text(getFormattedDate(date: date))
                    }
                    if let location = event.venue, !location.isEmpty {
                        Text(location)
                    }
                    
                    Button("Add to Calendar") {
                        Task {
                            await viewModel.addToCalendar()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(Color(UIColor.systemGroupedBackground))
                .cornerRadius(8)
                .padding(.horizontal)
            }
            
            Spacer()
        }
        .padding()
        .onChange(of: photoPickerItem) { newItem in
            guard let newItem = newItem else {
                viewModel.selectedImage = nil
                return
            }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    await MainActor.run {
                        viewModel.selectedImage = uiImage
                        viewModel.recognizedText = ""
                        viewModel.parsedEvent = nil
                    }
                }
            }
        }
        .task {
            await viewModel.requestCalendarAccess()
        }
        .alert("Success", isPresented: $viewModel.saveSuccess) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Event was added to your calendar successfully.")
        }
        .alert("Error", isPresented: Binding<Bool>(
            get: { viewModel.saveError != nil },
            set: { newValue in
                if !newValue { viewModel.saveError = nil }
            }
        )) {
            Button("OK", role: .cancel) {
                viewModel.saveError = nil
            }
        } message: {
            Text(viewModel.saveError ?? "An unknown error occurred.")
        }
    }
    
    func getFormattedDate(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

#Preview {
    EventScannerView()
}
