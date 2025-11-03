import SwiftUI
import Vision
import EventKit
import Combine
import FoundationModels

struct ScannedEventDetails {
    let title: String
    let date: Date?
    let startTime: Date?
    let endTime: Date?
    let venue: String?
    let notes: String
}

@Generable(description: "Extracted event details from arbitrary text")
struct ExtractedEventInfo {
    @Guide(description: "The event name/title. Prefer concise, human-friendly titles without dates or times.")
    var title: String

    @Guide(description: "The venue or location name if present. Avoid including dates or times.")
    var venue: String?

    @Guide(description: "The event start date and time if explicitly mentioned. Use ISO 8601 format (e.g., 2025-11-03T18:30:00Z). Leave empty if not present.")
    var startISO8601: String?

    @Guide(description: "The event start date if explicitly mentioned. Use ISO 8601 date-only format (e.g., 2025-11-03). Leave empty if not present.")
    var startDateISO8601: String?

    @Guide(description: "The event end date and time if explicitly mentioned. Use ISO 8601 format. Leave empty if not present.")
    var endISO8601: String?
}

@MainActor
class EventScannerViewModel: ObservableObject {
    @Published var selectedImage: UIImage?
    @Published var recognizedText: String = ""
    @Published var parsedEvent: ScannedEventDetails?
    
    private let eventStore = EKEventStore()
    
    @Published var calendarAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var isSaving = false
    @Published var saveError: String?
    @Published var saveSuccess = false
    
    private var lmSession: LanguageModelSession? = {
        let session = LanguageModelSession(instructions: "You extract event details from OCR text. Return the event title, event date and venue. Only include a start time if it is explicitly present in the text. Titles should be concise and omit dates/times. Venues should be names or addresses without extra words.")
        return session
    }()
    
    func requestCalendarAccess() async {
        if #available(iOS 17.0, *) {
            do {
                let status = try await eventStore.requestFullAccessToEvents()
                calendarAuthorizationStatus = status ? .authorized : .denied
            } catch {
                calendarAuthorizationStatus = .denied
            }
        } else {
            await withCheckedContinuation { continuation in
                eventStore.requestAccess(to: .event) { granted, _ in
                    DispatchQueue.main.async {
                        self.calendarAuthorizationStatus = granted ? .authorized : .denied
                        continuation.resume()
                    }
                }
            }
        }
    }
    
    func recognizeText() async throws {
        guard let image = selectedImage else { return }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en_US"]
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.0
        request.usesCPUOnly = false
        
        let handler = VNImageRequestHandler(cgImage: image.cgImage!, options: [:])
        
        try handler.perform([request])
        
        let lines = request.results?
            .compactMap { $0 as? VNRecognizedTextObservation }
            .compactMap { $0.topCandidates(1).first?.string } ?? []
        
        let recognized = lines.joined(separator: "\n")
        recognizedText = recognized
        
        // Try Apple Intelligence extraction first, fall back to heuristic parser
        if let extracted = try? await extractWithFoundationModel(from: recognized) {
            self.parsedEvent = extracted
        } else {
            self.parsedEvent = parseEvent(from: recognized)
        }
    }
    
    private func extractWithFoundationModel(from text: String) async throws -> ScannedEventDetails? {
        guard let session = lmSession else { return nil }
        // Proceed and rely on error handling; if the session isn't usable, we'll catch and return nil

        let prompt = """
        Extract the event title, venue, start date, and optional start/end times from the following text.
        Requirements:
        - title: concise, omit dates/times
        - venue: name or address only
        - startDateISO8601: date-only if a date is present
        - startISO8601: datetime only if an  time is present; otherwise leave empty
        - endISO8601: datetime only if an  end time/duration is present; otherwise leave empty        
        Text:\n\n\(text)
        """

        let response = try await session.respond(to: prompt, generating: ExtractedEventInfo.self)
        let info = response.content

        // Build ScannedEventDetails with optional date/time
        let isoDateFormatter = ISO8601DateFormatter()
        isoDateFormatter.formatOptions = [.withFullDate]
        isoDateFormatter.timeZone = .current

        let isoDateTimeFormatterStrict = ISO8601DateFormatter()
        isoDateTimeFormatterStrict.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoDateTimeFormatterStrict.timeZone = .current

        func parseISODateTime(_ s: String) -> Date? {
            // Try strict first (local timezone)
            if let d = isoDateTimeFormatterStrict.date(from: s) { return d }
            // Try a standard ISO parser but in local timezone
            let fallback = ISO8601DateFormatter()
            fallback.formatOptions = [.withInternetDateTime]
            fallback.timeZone = .current
            if let d = fallback.date(from: s) { return d }
            // If the string has no timezone, DateFormatter fallback assuming local
            if !s.contains("Z") && !s.contains("+") && !s.contains("-") {
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.timeZone = .current
                df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                if let d = df.date(from: s) { return d }
                df.dateFormat = "yyyy-MM-dd'T'HH:mm"
                if let d = df.date(from: s) { return d }
            }
            return nil
        }

        var parsedDateOnly: Date? = nil
        if let dateStr = info.startDateISO8601?.trimmingCharacters(in: .whitespacesAndNewlines), !dateStr.isEmpty {
            parsedDateOnly = isoDateFormatter.date(from: dateStr)
        }

        var parsedStartDateTime: Date? = nil
        if let startStr = info.startISO8601?.trimmingCharacters(in: .whitespacesAndNewlines), !startStr.isEmpty {
            parsedStartDateTime = parseISODateTime(startStr)
        }

        var parsedEndDateTime: Date? = nil
        if let endStr = info.endISO8601?.trimmingCharacters(in: .whitespacesAndNewlines), !endStr.isEmpty {
            parsedEndDateTime = parseISODateTime(endStr)
        }

        // If we have both a date-only and a time-only, combine later in addToCalendar.
        // Here we store date in `date`, and the full start/end times if provided.
        return ScannedEventDetails(
            title: info.title.isEmpty ? "New Event" : info.title,
            date: parsedDateOnly,
            startTime: parsedStartDateTime,
            endTime: parsedEndDateTime,
            venue: info.venue,
            notes: text
        )
    }
    
    func parseEvent(from text: String) -> ScannedEventDetails? {
        let fullText = text
        let nsText = text as NSString
        
        var foundDate: Date?
        var foundStartTime: Date?
        var foundEndTime: Date?
        var venue: String?
        
        // Detect date/time using NSDataDetector
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
            if let firstDateMatch = matches.first, let date = firstDateMatch.date {
                foundStartTime = date
                
                if firstDateMatch.duration > 0 {
                    foundEndTime = date.addingTimeInterval(firstDateMatch.duration)
                }
            }
        }
        
        // Extract venue using regex: venue|at|location|place|address (case insensitive)
        // followed by whitespace and capture until newline or period.
        let venuePattern = "(?i)(?:venue|at|location|place|address)[:\\s]*([^\n\\.]+)"
        if let regex = try? NSRegularExpression(pattern: venuePattern, options: []) {
            let range = NSRange(location: 0, length: nsText.length)
            if let match = regex.firstMatch(in: text, options: [], range: range) {
                if match.numberOfRanges > 1 {
                    let venueRange = match.range(at: 1)
                    if venueRange.location != NSNotFound {
                        let venueString = nsText.substring(with: venueRange).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !venueString.isEmpty {
                            venue = venueString
                        }
                    }
                }
            }
        }
        
        // Infer title as first non-empty line that isn't date/time or venue keywords
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let dateAndVenueKeywords = ["venue", "at", "location", "place", "address"]
        var title: String?
        for line in lines {
            if line.isEmpty { continue }
            let lower = line.lowercased()
            if dateAndVenueKeywords.contains(where: { lower.contains($0) }) { continue }
            if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
                detector.firstMatch(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count)) != nil {
                continue
            }
            title = line
            break
        }
        if title == nil {
            title = "New Event"
        }
        
        // Extract date only from foundStartTime by zeroing time components for date property
        var dateOnly: Date? = nil
        if let start = foundStartTime {
            let calendar = Calendar.current
            let comps = calendar.dateComponents([.year, .month, .day], from: start)
            dateOnly = calendar.date(from: comps)
        }
        
        return ScannedEventDetails(
            title: title ?? "New Event",
            date: dateOnly,
            startTime: foundStartTime,
            endTime: foundEndTime,
            venue: venue,
            notes: fullText
        )
    }
    
    func addToCalendar() async {
        // Ensure we have calendar access; if not determined, request it on-demand
        if calendarAuthorizationStatus != .authorized {
            await requestCalendarAccess()
        }
        guard calendarAuthorizationStatus == .authorized else {
            switch calendarAuthorizationStatus {
            case .denied:
                saveError = "Calendar access denied. Enable access in Settings > Privacy > Calendars."
            case .restricted:
                saveError = "Calendar access is restricted on this device."
            case .notDetermined:
                saveError = "Calendar access not determined. Please try again."
            default:
                saveError = "Calendar access is not authorized."
            }
            return
        }
        guard let eventDetails = parsedEvent else {
            saveError = "No parsed event to save."
            return
        }

        isSaving = true
        saveError = nil
        saveSuccess = false
        
        let event = EKEvent(eventStore: eventStore)
        // Ensure the event has a calendar assigned
        if let defaultCal = eventStore.defaultCalendarForNewEvents {
            event.calendar = defaultCal
        } else {
            // Fallback: pick the first writable calendar
            let writableCalendars = eventStore.calendars(for: .event).filter { $0.allowsContentModifications }
            if let firstWritable = writableCalendars.first {
                event.calendar = firstWritable
            } else {
                saveError = "No writable calendars available. Create or enable a calendar in the Calendar app."
                return
            }
        }
        
        event.title = eventDetails.title
        event.notes = eventDetails.notes
        event.location = eventDetails.venue
        
        let calendar = Calendar.current
        
        // Determine startDate and endDate for EKEvent
        // Rules:
        // - If both date (no time) and startTime (time or datetime) are present, combine using makeDate(from:time:)
        // - If only startTime (datetime) is present, use it
        // - If only date is present, default to noon
        // - If endTime present, use it; otherwise default 1 hour after start
        var startDate: Date?
        var endDate: Date?

        let dateOnly = eventDetails.date
        let startTime = eventDetails.startTime
        let endTime = eventDetails.endTime

        if let dateOnly = dateOnly, let startTime = startTime {
            // If startTime is a full datetime (with date), prefer combining to ensure same day as dateOnly
            // Combine components: take Y-M-D from dateOnly and H:M:S from startTime
            startDate = makeDate(from: dateOnly, time: startTime)
        } else if let startTime = startTime {
            startDate = startTime
        } else if let dateOnly = dateOnly {
            var comps = calendar.dateComponents([.year, .month, .day], from: dateOnly)
            comps.hour = 12
            comps.minute = 0
            startDate = calendar.date(from: comps)
        }

        if let endTime = endTime {
            if let dateOnly = dateOnly, let combinedStart = startDate, combinedStart != endTime {
                // If endTime likely lacks date alignment, align it to the same date as the start
                endDate = makeDate(from: dateOnly, time: endTime) ?? endTime
            } else {
                endDate = endTime
            }
        } else if let start = startDate {
            endDate = calendar.date(byAdding: .hour, value: 1, to: start)
        }
        
        guard let start = startDate, let end = endDate else {
            saveError = "Could not determine event start and end times."
            isSaving = false
            return
        }
        
        event.startDate = start
        event.endDate = end
        
        do {
            try eventStore.save(event, span: .thisEvent)
            saveSuccess = true
        } catch {
            saveError = error.localizedDescription
        }
        
        isSaving = false
    }
    
    /// Combine separate date and time components into one Date object
    func makeDate(from date: Date?, time: Date?) -> Date? {
        guard let date = date else { return time }
        guard let time = time else { return date }
        let calendar = Calendar.current
        let dateComps = calendar.dateComponents([.year, .month, .day], from: date)
        let timeComps = calendar.dateComponents([.hour, .minute, .second], from: time)
        var combined = DateComponents()
        combined.year = dateComps.year
        combined.month = dateComps.month
        combined.day = dateComps.day
        combined.hour = timeComps.hour
        combined.minute = timeComps.minute
        combined.second = timeComps.second
        return calendar.date(from: combined)
    }
}

