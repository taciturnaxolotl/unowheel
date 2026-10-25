import Foundation

/// How far a cleaned route can be trusted.
public enum RouteQuality: Equatable, Sendable {
    case good
    /// GPS stopped reporting for a stretch; the map skips it or draws a straight line.
    case droppedOut
    /// Cleanup would have thrown out most fixes, so the raw track is shown.
    case lowSignal
}

extension Ride {
    /// The ride as worth showing: free-spinning wheel readings zeroed and
    /// GPS fixes that can't be part of the ride dropped. Files keep raw data.
    public func cleanedRoute() -> Ride {
        let ridden = zeroingUnriddenSamples()
        var cleaned = ridden.droppingCarriedFixes().droppingIndoorFixes().droppingFrozenFixes().droppingStrandedFixes()
        let rawFixes = points.filter(\.hasLocation).count
        let keptFixes = cleaned.points.filter(\.hasLocation).count
        if hasRoute, ridden.wheelKm >= Self.lowSignalMinimumKm, Double(keptFixes) < Double(rawFixes) * Self.trustedShare {
            var raw = ridden
            raw.routeQuality = .lowSignal
            return raw
        }
        cleaned.routeQuality = cleaned.hasGPSDropout ? .droppedOut : .good
        return cleaned
    }

    private static let carriedAfter: TimeInterval = 3
    private static let frozenRun = 4
    private static let trustedJumpGap: TimeInterval = 10
    private static let jumpSlack = 1.5
    private static let jumpToleranceKm = 0.05
    private static let strandedRun = 10
    private static let indoorWindow: TimeInterval = 30
    private static let indoorMinimumKm = 0.03
    /// Outdoors a fix arrives every second; indoors every three or four.
    private static let indoorFixInterval: TimeInterval = 2.5
    private static let indoorStallRatio = 0.5
    private static let dropoutSeconds: TimeInterval = 20
    private static let dropoutKm = 0.1
    private static let trustedShare = 0.2
    private static let lowSignalMinimumKm = 0.2

    /// Speed, power and pitch mean nothing while the wheel spins freely.
    private func zeroingUnriddenSamples() -> Ride {
        var copy = self
        for i in copy.points.indices where !copy.points[i].isRidden {
            copy.points[i].speedKPH = 0
            copy.points[i].watts = nil
            copy.points[i].pitch = nil
        }
        return copy
    }

    /// Once still for a few seconds the board is being carried; the first still fixes mark the stop.
    private func droppingCarriedFixes() -> Ride {
        var copy = self
        var stillSince: Date?
        for i in copy.points.indices {
            guard copy.points[i].speedKPH < Self.movingKPH else {
                stillSince = nil
                continue
            }
            let since = stillSince ?? copy.points[i].time
            stillSince = since
            if copy.points[i].time.timeIntervalSince(since) > Self.carriedAfter { copy.points[i].dropLocation() }
        }
        return copy
    }

    /// Indoor Wi-Fi fixes come seconds apart and wander in place; a stretch with none is a dropout, not indoors.
    private func droppingIndoorFixes() -> Ride {
        var copy = self
        var start = points.startIndex
        for end in points.indices {
            while points[end].time.timeIntervalSince(points[start].time) > Self.indoorWindow { start += 1 }
            guard points[end].time.timeIntervalSince(points[start].time) >= Self.indoorWindow - 1 else { continue }
            let located = points[start...end].indices.filter { points[$0].hasLocation }
            guard let first = located.first, let last = located.last, located.count >= 3 else { continue }
            let spanned = points[first...last]
            guard spanned.wheelKm >= Self.indoorMinimumKm else { continue }
            let intervals = zip(located, located.dropFirst()).map { points[$1].time.timeIntervalSince(points[$0].time) }.sorted()
            let sparse = intervals[intervals.count / 2] >= Self.indoorFixInterval
            let stalled = spanned.gpsKm < spanned.wheelKm * Self.indoorStallRatio
            if sparse || stalled {
                for i in start...end { copy.points[i].dropLocation() }
            }
        }
        return copy
    }

    /// A long stretch without fixes while the wheel turned, including before the first or after the last.
    var hasGPSDropout: Bool {
        let located = points.indices.filter { points[$0].hasLocation }
        guard let first = located.first, let last = located.last else { return false }
        let stretches = [(points.startIndex, first)] + Array(zip(located, located.dropFirst())) + [(last, points.endIndex - 1)]
        return stretches.contains { a, b in
            points[b].time.timeIntervalSince(points[a].time) > Self.dropoutSeconds && points[a...b].wheelKm > Self.dropoutKm
        }
    }

    /// iOS repeats the last fix when it loses the sky; a long repeat is stale throughout.
    private func droppingFrozenFixes() -> Ride {
        var copy = self
        let runs = locatedRuns { a, b in points[a].latitude != points[b].latitude || points[a].longitude != points[b].longitude }
        for run in runs {
            (run.count >= Self.frozenRun ? run[...] : run.dropFirst()).forEach { copy.points[$0].dropLocation() }
        }
        return copy
    }

    /// A short run cut off by a jump the board couldn't make, unless a long gap explains it.
    private func droppingStrandedFixes() -> Ride {
        let runs = locatedRuns { a, b in
            let seconds = points[b].time.timeIntervalSince(points[a].time)
            let fastest = points[a...b].map(\.speedKPH).max() ?? 0
            let reachableKm = fastest * max(seconds, 1) / 3600 * Self.jumpSlack + Self.jumpToleranceKm
            return seconds < Self.trustedJumpGap && Self.haversineKm(points[a], points[b]) > reachableKm
        }
        let longest = runs.map(\.count).max() ?? 0
        var copy = self
        for run in runs where run.count < longest && run.count < Self.strandedRun {
            run.forEach { copy.points[$0].dropLocation() }
        }
        return copy
    }

    /// Indices of located points, split into runs wherever `breaks(previous, next)`.
    private func locatedRuns(breakingWhere breaks: (Int, Int) -> Bool) -> [[Int]] {
        var runs: [[Int]] = []
        for i in points.indices where points[i].hasLocation {
            if let last = runs.last?.last, !breaks(last, i) {
                runs[runs.count - 1].append(i)
            } else {
                runs.append([i])
            }
        }
        return runs
    }
}
