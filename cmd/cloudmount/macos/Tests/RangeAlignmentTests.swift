import Foundation

@main enum RangeAlignmentTests {
    static func expect(_ requested: NSRange, _ alignment: Int, _ size: Int64, _ expected: NSRange) throws {
        let actual = try minimalAlignedRange(requested: requested, alignment: alignment, fileSize: size)
        precondition(actual == expected, "\(requested), \(alignment), \(size): \(actual) != \(expected)")
    }

    static func reject(_ requested: NSRange, _ alignment: Int, _ size: Int64) {
        do { _ = try minimalAlignedRange(requested: requested, alignment: alignment, fileSize: size); fatalError("invalid range accepted") }
        catch { }
    }

    static func main() throws {
        try expect(NSRange(location: 4096, length: 4096), 4096, 16384, NSRange(location: 4096, length: 4096))
        try expect(NSRange(location: 4100, length: 4092), 4096, 16384, NSRange(location: 4096, length: 4096))
        try expect(NSRange(location: 4096, length: 4097), 4096, 16384, NSRange(location: 4096, length: 8192))
        try expect(NSRange(location: 4100, length: 5000), 4096, 16384, NSRange(location: 4096, length: 8192))
        try expect(NSRange(location: 15000, length: 1384), 4096, 16384, NSRange(location: 12288, length: 4096))
        try expect(NSRange(location: 10, length: 90), 4096, 100, NSRange(location: 0, length: 100))
        try expect(NSRange(location: 0, length: 524288), 16384, 94, NSRange(location: 0, length: 94))
        try expect(NSRange(location: 16380, length: 4), 4096, 16384, NSRange(location: 12288, length: 4096))
        reject(NSRange(location: 0, length: 1), 0, 100)
        reject(NSRange(location: Int.max - 1, length: 8), 4096, Int64.max)
        precondition(!strictVersionMismatch(requested: Data("one".utf8), current: "two", strict: false))
        precondition(strictVersionMismatch(requested: Data("one".utf8), current: "two", strict: true))
        precondition(!strictVersionMismatch(requested: Data("one".utf8), current: "one", strict: true))
        precondition(versionChanged(before: "one", after: "two"))
        precondition(!versionChanged(before: "one", after: "one"))
        print("RangeAlignment tests passed")
    }
}
