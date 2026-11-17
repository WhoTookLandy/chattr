import Testing
@testable import Features

/// `TimeoutPresets`: the per-device chip list's storage format and labels.
@Suite("TimeoutPresets")
struct TimeoutPresetsTests {

    @Test("Defaults are 1m, 10m, 1h, 1d")
    func defaults() {
        #expect(TimeoutPresets.decode(TimeoutPresets.defaultRaw) == [60, 600, 3_600, 86_400])
        #expect(TimeoutPresets.defaults.map(TimeoutPresets.label(forSeconds:)) == ["1m", "10m", "1h", "1d"])
    }

    @Test("Decode drops garbage, duplicates and out-of-range values, and sorts")
    func decodeCleans() {
        #expect(TimeoutPresets.decode("600, 60,abc,60,-5,0,9999999,30") == [30, 60, 600])
    }

    @Test("An empty or all-garbage list falls back to the defaults")
    func decodeFallsBack() {
        #expect(TimeoutPresets.decode("") == TimeoutPresets.defaults)
        #expect(TimeoutPresets.decode("x,y") == TimeoutPresets.defaults)
    }

    @Test("Encode round-trips and caps the count")
    func encodeRoundTrip() {
        let many = Array(1...20).map { $0 * 60 }
        let decoded = TimeoutPresets.decode(TimeoutPresets.encode(many))
        #expect(decoded.count == TimeoutPresets.maxCount)
        #expect(decoded == Array(many.prefix(TimeoutPresets.maxCount)))
    }

    @Test("Labels use the largest unit that divides evenly")
    func labels() {
        #expect(TimeoutPresets.label(forSeconds: 30) == "30s")
        #expect(TimeoutPresets.label(forSeconds: 5_400) == "90m")
        #expect(TimeoutPresets.label(forSeconds: 1_209_600) == "2w")
        #expect(TimeoutPresets.spokenLabel(forSeconds: 60) == "1 minute")
        #expect(TimeoutPresets.spokenLabel(forSeconds: 172_800) == "2 days")
    }
}
