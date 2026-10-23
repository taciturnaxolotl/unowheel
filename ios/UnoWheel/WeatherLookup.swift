import CoreLocation
import Foundation
import OnewheelKit

/// Looks up past weather from Open-Meteo, which needs no key for
/// non-commercial use and keeps hourly history for about three months.
enum WeatherLookup {
    static let historyDays = 90

    private struct Response: Decodable {
        struct Hourly: Decodable {
            let time: [Double]
            let temperature_2m: [Double?]
            let wind_speed_10m: [Double?]
            let precipitation: [Double?]
            let relative_humidity_2m: [Double?]
        }
        let hourly: Hourly
    }

    /// The hour closest to `date` at `coordinate`.
    static func weather(at coordinate: CLLocationCoordinate2D, on date: Date) async -> Weather? {
        guard Date.now.timeIntervalSince(date) < Double(historyDays) * 86_400 else { return nil }
        let day = date.formatted(.iso8601.year().month().day())
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            URLQueryItem(name: "hourly", value: "temperature_2m,wind_speed_10m,precipitation,relative_humidity_2m"),
            URLQueryItem(name: "start_date", value: day),
            URLQueryItem(name: "end_date", value: day),
            URLQueryItem(name: "timezone", value: "GMT"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
        ]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let hourly = try? JSONDecoder().decode(Response.self, from: data).hourly,
              let hour = hourly.time.indices.min(by: {
                  abs(hourly.time[$0] - date.timeIntervalSince1970) < abs(hourly.time[$1] - date.timeIntervalSince1970)
              }),
              let temperature = hourly.temperature_2m[hour]
        else { return nil }
        return Weather(temperatureC: temperature, windKPH: hourly.wind_speed_10m[hour] ?? 0,
                       precipitationMM: hourly.precipitation[hour] ?? 0,
                       humidityPercent: hourly.relative_humidity_2m[hour])
    }
}
