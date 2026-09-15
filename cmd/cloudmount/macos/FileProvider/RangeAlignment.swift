import Foundation

enum RangeAlignmentError: Error { case invalidRange }

func strictVersionMismatch(requested: Data, current: String, strict: Bool) -> Bool {
    strict && requested != Data(current.utf8)
}

func versionChanged(before: String, after: String) -> Bool { before != after }

func minimalAlignedRange(requested: NSRange, alignment: Int, fileSize: Int64) throws -> NSRange {
    guard alignment > 0, alignment & (alignment - 1) == 0,
          requested.location >= 0, requested.length > 0,
          let size = Int(exactly: fileSize), size >= 0 else { throw RangeAlignmentError.invalidRange }
    let (requestedEnd, endOverflow) = requested.location.addingReportingOverflow(requested.length)
    guard !endOverflow, requested.location < size else { throw RangeAlignmentError.invalidRange }
    let effectiveEnd = min(requestedEnd, size)
    let alignedStart = requested.location & ~(alignment - 1)
    let (roundedInput, roundingOverflow) = effectiveEnd.addingReportingOverflow(alignment - 1)
    guard !roundingOverflow else { throw RangeAlignmentError.invalidRange }
    let alignedEnd = min(roundedInput & ~(alignment - 1), size)
    guard alignedEnd >= effectiveEnd, alignedEnd >= alignedStart else { throw RangeAlignmentError.invalidRange }
    return NSRange(location: alignedStart, length: alignedEnd - alignedStart)
}
