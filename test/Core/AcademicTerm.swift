import Foundation

/// Term labels for the semester picker. The SICAU academic year splits into
/// two terms: "1" (autumn) and "2" (spring). The picker offers a fixed
/// generated range so users can select future semesters long before any
/// preset start date exists for them.
enum AcademicTerm {
    /// Generates `startYear-(startYear+1)-1` … `endYear-(endYear+1)-2`
    /// for every academic year in the inclusive `startYear...endYear` range,
    /// ascending by academic year and term within the year.
    ///
    /// The default range ends at academic year 2035, so the last generated
    /// label is `2035-2036-2`.
    static func availableTerms(from startYear: Int = 2025, to endYear: Int = 2035) -> [String] {
        guard startYear <= endYear else { return [] }
        var terms: [String] = []
        for year in startYear...endYear {
            terms.append("\(year)-\(year + 1)-1")
            terms.append("\(year)-\(year + 1)-2")
        }
        return terms
    }
}
