import CoreLocation
import OnewheelKit
import SwiftUI

/// Where home is, when you have to be back, and whether to be told.
struct CurfewView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @State private var draft = Curfew()
    @State private var locating = false
    @State private var locationProblem: String?

    private static let weekdays = Calendar.current.weekdaySymbols

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Warn me during a ride", isOn: $draft.enabled)
                } footer: {
                    Text("While you're riding within \(Measurement(value: Curfew.campusRadiusMeters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))) of home, UnoWheel works out how long the way back takes and sounds an alarm when it's time to turn around.")
                }

                Section {
                    if let home = draft.home {
                        Label {
                            VStack(alignment: .leading) {
                                Text(home.name ?? "Home")
                                Text(verbatim: String(format: "%.5f, %.5f", home.latitude, home.longitude))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "house.fill")
                        }
                    }
                    Button {
                        Task { await useCurrentLocation() }
                    } label: {
                        HStack {
                            Label(draft.home == nil ? "Use where I am now" : "Move home to where I am now", systemImage: "location.fill")
                            if locating {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(locating)
                } header: {
                    Text("Home")
                } footer: {
                    if let locationProblem {
                        Text(locationProblem)
                    } else {
                        Text("Stand at the door you'll come in through.")
                    }
                }

                Section {
                    ForEach(1...7, id: \.self) { weekday in
                        CurfewNightRow(name: Self.weekdays[weekday - 1], minutes: binding(for: weekday))
                    }
                } header: {
                    Text("Curfew")
                } footer: {
                    Text("Each night's time. A time before noon means the small hours of the next morning.")
                }

                Section {
                    Stepper(value: $draft.bufferSeconds, in: 0...600, step: 30) {
                        Text("Arrive \(Duration.seconds(draft.bufferSeconds).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))) early")
                    }
                } footer: {
                    Text("The warning allows this much on top of the ride, for walking in and swiping through.")
                }
            }
            .navigationTitle("Curfew")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        connection.curfew.save(draft)
                        dismiss()
                    }
                }
            }
            .onAppear { draft = connection.curfew.settings }
        }
    }

    private func binding(for weekday: Int) -> Binding<Int?> {
        Binding(get: { draft.minutesByWeekday[weekday] }, set: { draft.minutesByWeekday[weekday] = $0 })
    }

    private func useCurrentLocation() async {
        locating = true
        locationProblem = nil
        defer { locating = false }
        do {
            let location = try await Self.currentFix()
            let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
            let name = placemark?.areasOfInterest?.first ?? placemark?.name
            draft.home = Curfew.Place(location)
            draft.home?.name = name
        } catch {
            locationProblem = "Couldn't get a fix: \(error.localizedDescription)"
        }
    }

    private static func currentFix() async throws -> CLLocation {
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        for try await update in CLLocationUpdate.liveUpdates() {
            if update.authorizationDenied { throw CLError(.denied) }
            if let location = update.location, location.horizontalAccuracy <= 20 { return location }
        }
        throw CLError(.locationUnknown)
    }
}

/// One night's curfew: off, or a time. Times before noon count as the next
/// morning, so midnight and 1 am land where you'd expect.
private struct CurfewNightRow: View {
    let name: String
    @Binding var minutes: Int?

    private static let noon = 12 * 60

    var body: some View {
        HStack {
            Toggle(name, isOn: Binding(get: { minutes != nil }, set: { minutes = $0 ? 24 * 60 : nil }))
            if minutes != nil {
                DatePicker("", selection: time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
        }
    }

    private var time: Binding<Date> {
        Binding(
            get: {
                let clock = (minutes ?? 0) % (24 * 60)
                return Calendar.current.date(bySettingHour: clock / 60, minute: clock % 60, second: 0, of: .now) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                let clock = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                minutes = clock < Self.noon ? clock + 24 * 60 : clock
            }
        )
    }
}
