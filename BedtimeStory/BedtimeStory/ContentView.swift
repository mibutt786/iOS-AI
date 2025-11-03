//
//  ContentView.swift
//  BedtimeStory
//
//  Created by Muddsar Butt on 2025-11-03.
//

import SwiftUI
import AVFoundation
import Combine
#if canImport(FoundationModels)
import FoundationModels
#endif

struct ContentView: View {
    @State private var childAge: Int = 5
    @State private var genre: Genre = .fantasy
    @State private var story: String = ""
    @State private var isGenerating: Bool = false
    @State private var generationError: String?

    // Use a persistent speech manager so the AVSpeechSynthesizer and delegate
    // live across SwiftUI view updates and callbacks reliably.
    @StateObject private var speechManager = SpeechManager()

    var body: some View {
        NavigationStack {
            Form {
                Section("Child Info") {
                    Stepper(value: $childAge, in: 1...12) {
                        HStack {
                            Text("Child Age")
                            Spacer()
                            Text("\(childAge)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Picker("Genre", selection: $genre) {
                        ForEach(Genre.allCases, id: \.self) { g in
                            Text(g.displayName).tag(g)
                        }
                    }
                }

                Section("Story") {
                    if story.isEmpty {
                        Text("No story yet. Tap Generate to create a bedtime story.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(story)
                            .textSelection(.enabled)
                            .animation(.default, value: story)
                    }
                }

                if let generationError {
                    Section("Notice") {
                        Text(generationError)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    HStack {
                        Button(action: generateStory) {
                            if isGenerating {
                                ProgressView()
                            } else {
                                Label("Generate Story", systemImage: "sparkles")
                            }
                        }
                        .disabled(isGenerating)
                    }
                }
                
                Section {
                    HStack {
                        Button(action: toggleSpeech) {
                            Label(speechManager.isSpeaking ? "Stop" : "Read Aloud", systemImage: speechManager.isSpeaking ? "stop.fill" : "speaker.wave.2.fill")
                        }
                        .disabled(story.isEmpty && !speechManager.isSpeaking)
                    }
                }
            }
            .navigationTitle("Bedtime Story")
        }
        .onAppear {
            // Nothing special required here; SpeechManager sets up the synthesizer
            // and delegate during its init so speech callbacks work reliably.
        }
    }

    // MARK: - Actions

    private func generateStory() {
        // If something is currently being read aloud, stop it so the new story
        // doesn't overlap with the old one.
        speechManager.stop()
        generationError = nil
        isGenerating = true
        story = ""

        Task {
            do {
                #if canImport(FoundationModels)
                // Prefer the AI path when available; if the AI path returns nil,
                // fall back to the always-available local generator.
                if let generated = try await StoryGenerator.generateStoryUsingAI(age: childAge, genre: genre) {
                    await MainActor.run { self.story = generated }
                } else {
                    await MainActor.run { self.story = StoryGenerator.localStory(age: childAge, genre: genre) }
                }
                #else
                // No FoundationModels available in this build; always use local generator.
                await MainActor.run { self.story = StoryGenerator.localStory(age: childAge, genre: genre) }
                #endif
            } catch {
                await MainActor.run {
                    self.generationError = error.localizedDescription
                }
            }
            await MainActor.run { self.isGenerating = false }
        }
    }

    private func toggleSpeech() {
        if speechManager.isSpeaking {
            speechManager.stop()
        } else {
            speechManager.speak(story)
        }
    }
}

// MARK: - Genre

enum Genre: String, CaseIterable, Hashable {
    case fantasy, adventure, animals, space, mystery, bedtime

    var displayName: String {
        switch self {
        case .fantasy: return "Fantasy"
        case .adventure: return "Adventure"
        case .animals: return "Animals"
        case .space: return "Space"
        case .mystery: return "Mystery"
        case .bedtime: return "Gentle Bedtime"
        }
    }
}

// MARK: - Speech Delegate wrapper

// Persistent speech manager that owns AVSpeechSynthesizer and exposes a simple API.
private final class SpeechManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @MainActor @Published var isSpeaking: Bool = false

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        // Ensure audio is configured for spoken playback so speech is audible on device.
        // Use try? so we don't throw in init; if audio setup fails we'll still attempt to speak.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Non-fatal: if audio session configuration fails, speech may still work depending on system defaults.
        }
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        synthesizer.speak(utterance)
        Task { @MainActor in
            self.isSpeaking = true
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    // AVSpeechSynthesizerDelegate
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}

// MARK: - Story Generation (local fallback + optional FoundationModels integration)

enum StoryGenerator {
    // Always-available local generator to ensure a new, randomized story each time.
    static func localStory(age: Int, genre: Genre) -> String {
        let names = ["Ava", "Liam", "Noah", "Emma", "Olivia", "Mason", "Sophia", "Lucas", "Isla", "Ethan"]
        let comforts = ["cozy blanket", "teddy bear", "soft pillow", "glowing nightlight", "warm quilt"]
        let animals = ["bunny", "kitten", "puppy", "owl", "firefly", "little fox"]
        let extras = ["a friendly star", "a tiny sparkle", "a whispering breeze", "a glowing lantern", "a sleepy moonbeam"]
        let name = names.randomElement() ?? "Friend"
        let comfort = comforts.randomElement() ?? "blanket"
        let animal = animals.randomElement() ?? "friend"
        let extra = extras.randomElement() ?? "a sparkle"

        let title = "A \(genre.displayName) Goodnight"

        let paragraphs = [
            "Once upon a time, there was a \(age)-year-old named \(name) who loved \(genre.displayName.lowercased()) adventures.",
            "Every evening, \(name) would tuck the \(comfort) close and say goodnight to the \(animal).",
            "Tonight felt especially peaceful: \(extra) drifted through the window and settled like a tiny friend.",
            "With a warm, cozy blanket and a deep breath, a quiet journey began—slow and kind, just right for bedtime.",
            "Along the way, friendly faces appeared, each one smiling and wishing sweet dreams.",
            "The path was safe and peaceful, with soft colors and slow whispers of the night.",
            "A gentle glow guided the way home, like a lantern showing the heart the way to rest.",
            "At last, the room felt extra cozy, and the night hummed a lullaby just for you.",
            "Eyes grew heavy, breaths grew slow, and everything felt safe and loved.",
            "Goodnight, little dreamer. Tomorrow will be bright. Sleep well, you are loved."
        ]

        let closings = [
            "May your dreams be full of playful adventures.",
            "Wake with a smile and a new story to tell.",
            "The stars guard your sleep until morning comes.",
            "Snuggle deep and drift gently into soft dreams."
        ]
        let closing = closings.randomElement() ?? "Sleep well."

        var body = paragraphs
        if Bool.random() {
            let whimsical = "Somewhere nearby, a friendly \(animal) hummed a tiny tune just for \(name)."
            body.insert(whimsical, at: min(3, body.count))
        }

        return ([title, ""]) .joined(separator: "\n") + body.joined(separator: "\n\n") + "\n\n" + closing
    }
}

#if canImport(FoundationModels)
// Minimal facade to reference FoundationModels cleanly
enum FM {
    // In a real integration, check runtime availability of Apple Intelligence here.
    static var isAvailable: Bool { true }
}

extension StoryGenerator {
    // If FoundationModels is available at runtime, you could implement an async
    // call here to Apple's model and return text. For this sample, prefer the
    // AI path when available, otherwise the calling code will fall back to
    // `localStory`.
    static func generateStoryUsingAI(age: Int, genre: Genre) async throws -> String? {
        // Real AI integration would go here; return nil to signal unavailability
        // when FM isn't usable at runtime.
        guard FM.isAvailable else { return nil }

        // For now, return a locally-generated story even if FM is present so
        // behavior is deterministic in sample builds. Replace with real model
        // calls when integrating FoundationModels.
        return localStory(age: age, genre: genre)
    }
}
#endif

#Preview {
    ContentView()
}
