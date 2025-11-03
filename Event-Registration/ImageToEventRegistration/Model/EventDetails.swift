import Foundation

struct CalendarEventDetails: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var date: Date?
    var startTime: Date?
    var endTime: Date?
    var venue: String?
    var notes: String?

    init(
        id: UUID = UUID(),
        title: String = "",
        date: Date? = nil,
        startTime: Date? = nil,
        endTime: Date? = nil,
        venue: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.venue = venue
        self.notes = notes
    }

    var dateInterval: DateInterval? {
        guard let date = date else { return nil }
        guard let start = startTime, let end = endTime else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df
    }()

    private static let timeFormatter: DateFormatter = {
        let tf = DateFormatter()
        tf.dateStyle = .none
        tf.timeStyle = .short
        return tf
    }()

    func displaySummary() -> String {
        var components = [String]()

        if !title.isEmpty {
            components.append(title)
        }

        if let date = date {
            components.append(Self.dateFormatter.string(from: date))
        }

        if let start = startTime {
            var timeString = Self.timeFormatter.string(from: start)
            if let end = endTime {
                timeString += " - \(Self.timeFormatter.string(from: end))"
            }
            components.append(timeString)
        }

        if let venue = venue, !venue.isEmpty {
            components.append("Venue: \(venue)")
        }

        if let notes = notes, !notes.isEmpty {
            components.append("Notes: \(notes)")
        }

        return components.joined(separator: "\n")
    }
}
