@testable import Yap

/// The report examples pFlow 0.3.20 and older put in, as saved templates of a
/// person updating.
extension DictationTemplate {
    static var policeReport: DictationTemplate { legacyReportExamples[0] }
    static var supplement: DictationTemplate { legacyReportExamples[1] }
    static var followUp: DictationTemplate { legacyReportExamples[2] }
}
