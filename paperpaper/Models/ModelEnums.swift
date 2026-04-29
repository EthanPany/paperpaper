import Foundation

enum SpaceMode: String, Codable, CaseIterable, Sendable {
    case unified
    case perSpace
    case activeOnly
}

enum OverlayCorner: String, Codable, CaseIterable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

enum OverlayContent: String, Codable, CaseIterable, Sendable {
    case nameAndArchitect
    case blurb
    case exifOneLine
    case photographerAndArea
}

enum WidgetLayout: String, Codable, CaseIterable, Sendable {
    case blurb
    case exif
    case minimal
    case photographer
}

enum LogLevel: String, Codable, CaseIterable, Sendable {
    case error
    case warn
    case info
    case debug
}

enum DayNightMode: String, Codable, CaseIterable, Sendable {
    case off
    case separatePools
    case separateIntervals
}

enum ScheduleMode: String, Codable, CaseIterable, Sendable {
    case interval
    case specificTimes
}
