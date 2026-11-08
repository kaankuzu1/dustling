import Testing
@testable import DustlingAppModel

struct BytesTests {
    @Test func smallValues() {
        #expect(Bytes.format(UInt64(0)) == "0 bytes")
        #expect(Bytes.format(UInt64(1)) == "1 byte")
        #expect(Bytes.format(UInt64(999)) == "999 bytes")
        #expect(Bytes.format(Int64(-5)) == "0 bytes")
    }

    @Test func decimalUnitsAndPrecision() {
        #expect(Bytes.format(UInt64(1000)) == "1 KB")
        #expect(Bytes.format(UInt64(1500)) == "2 KB")
        #expect(Bytes.format(UInt64(1_500_000)) == "1.5 MB")
        #expect(Bytes.format(UInt64(1_230_000_000)) == "1.23 GB")
        #expect(Bytes.format(Int64(2_000_000_000_000)) == "2 TB")
    }

    @Test func boundariesRoundUpToNextUnit() {
        #expect(Bytes.format(UInt64(999_999)) == "1 MB")
        #expect(Bytes.format(UInt64(999_960_000)) == "1 GB")
        #expect(Bytes.format(UInt64(999_996_000_000)) == "1 TB")
        #expect(Bytes.format(UInt64(999_499)) == "999 KB")
        #expect(Bytes.format(UInt64(1_000_000)) == "1 MB")
    }

    @Test func hugeValuesDoNotCrash() {
        #expect(Bytes.format(UInt64.max).hasSuffix("PB"))
    }
}
