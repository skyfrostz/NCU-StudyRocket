import Foundation

public struct TimetableCoursePresentation: Equatable, Sendable {
    public let kind: TimetableEntryKind
    public let title: String

    public init(kind: TimetableEntryKind, title: String) {
        self.kind = kind
        self.title = title
    }
}

/// A display-ready course title. English-side courses keep their English
/// teaching title prominent while exposing the Chinese translation as
/// secondary context; all other timetable titles remain a single line.
public struct TimetableDisplayTitle: Equatable, Sendable {
    public let primary: String
    public let secondary: String?

    public init(primary: String, secondary: String? = nil) {
        self.primary = primary
        self.secondary = secondary
    }
}

/// Keeps recognized English-side instructional titles consistent across
/// Markdown parsing and file import without treating every English label as a course.
public enum StudyRocketTimetableCourseCatalog {
    public static func presentation(
        kind: TimetableEntryKind,
        title: String
    ) -> TimetableCoursePresentation {
        guard kind == .course || kind == .support || kind == .officeHour,
              let canonicalTitle = canonicalTitle(for: title) else {
            return TimetableCoursePresentation(kind: kind, title: title)
        }
        return TimetableCoursePresentation(kind: .course, title: canonicalTitle)
    }

    /// Splits the canonical `English / 中文` form used by English-side courses.
    /// A plain Chinese title, a holiday label, or an arbitrary slash-delimited
    /// title deliberately stays intact so every client presents the same text.
    public static func displayTitle(for title: String) -> TimetableDisplayTitle {
        let segments = title.components(separatedBy: " / ")
        guard segments.count == 2 else {
            return TimetableDisplayTitle(primary: title)
        }

        let primary = segments[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let secondary = segments[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !primary.isEmpty,
              !secondary.isEmpty,
              containsLatin(primary),
              containsChinese(secondary) else {
            return TimetableDisplayTitle(primary: title)
        }
        return TimetableDisplayTitle(primary: primary, secondary: secondary)
    }

    private static func canonicalTitle(for title: String) -> String? {
        let key = normalizedTitle(title)

        if key.contains("academicandskillssupport1a") {
            return "Academic and Skills Support - 1A / 学术与技能支持（1A）"
        }
        if key.contains("academicandskillssupport1b") {
            return "Academic and Skills Support - 1B / 学术与技能支持（1B）"
        }
        if key.contains("academicandskillssupport") {
            return "Academic and Skills Support / 学术与技能支持"
        }
        if key.contains("academicskills") {
            if key.contains("practicingskills") || key.contains("practisingskills") {
                return "Academic Skills (Practising Skills) / 学术技能（技能练习）"
            }
            if key.contains("bothjeis") {
                return "Academic Skills (Both JEIs) / 学术技能（JEI 合班）"
            }
            return "Academic Skills / 学术技能"
        }
        if key.contains("learningunderthepavillion") || key.contains("learningunderthepavilion") {
            if key.contains("bothjeis") {
                return "Learning Under the Pavilion (Both JEIs) / 亭下学习（JEI 合班）"
            }
            return "Learning Under the Pavilion / 亭下学习"
        }
        if key.contains("officehour") {
            return "Office Hour / 教师答疑时间"
        }
        if key.contains("practiceforbasicmedicalgeneticsandcellbiology") {
            return "Practice for Basic Medical Genetics and Cell Biology / 基础医学遗传学和细胞生物学实验"
        }
        if key.contains("basicmedicalgeneticsandcellbiology") {
            return "Basic Medical Genetics and Cell Biology / 基础医学遗传学和细胞生物学"
        }
        if key.contains("medicalcellbiology") {
            return "Medical Cell Biology / 医学细胞生物学"
        }
        return nil
    }

    private static func normalizedTitle(_ title: String) -> String {
        String(title.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    private static func containsLatin(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
        }
    }

    private static func containsChinese(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }
    }
}
