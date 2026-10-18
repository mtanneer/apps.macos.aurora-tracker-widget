# AuroraTracker

A native macOS app and widget that displays live NOAA geomagnetic Kp index data, real-time aurora probability, and a combined "tonight's outlook" for your location.

## Features

### Widget
- **Small**: Current Kp index with color-coded activity level badge
- **Medium**: Current Kp index + 8-bar mini chart showing today's 3-hour forecast slots (current slot highlighted); badge shows the combined outlook verdict when available
- Refreshes every 30 minutes
- Click to open the full dashboard app

### App Dashboard
- **Tonight's Outlook card**: Combined verdict (e.g. "Good Chance Tonight", "Active Alert — Check Now") built from observed Kp, forecast Kp, active NOAA alerts, and — with location permission — your local aurora probability from the Ovation grid
- **Current Kp card**: Live forecast Kp reading tied to the current UTC 3-hour window, plus the latest *observed* (actual, not forecast) Kp side by side, today's peak and average
- **Active Alerts card**: Real NOAA geomagnetic K-index alert messages issued in the last 24 hours (only shown when present)
- **3-day forecast chart**: Bar chart for all 8 time slots per day; switch between days with a segmented picker; G1/G2/G3 storm thresholds overlaid
- **Aurora Maps**: Three NOAA image feeds — Tonight's Viewline Forecast, Ovation Aurora Map, and K-Index Station readings
- **Map detail view**: Click any map to open a full-screen view with pinch-to-zoom, pan, double-tap to zoom, zoom buttons, and a share option
- **Kp / G-Scale legend** for quick reference
- Stale-data banner (tappable to retry) when a fetch fails but prior data is still shown; auto-retries once in the background

### Location (optional)
The app can use your coarse location (rounded to the nearest degree, matching the Ovation grid's resolution) to compute a location-specific aurora probability. Requires location permission — the app degrades gracefully to a Kp-only outlook if permission isn't granted. The last-known location is shared with the widget via an App Group so the widget can compute the same outlook without prompting for permission itself.

## Data Source

All data is fetched from [NOAA Space Weather Prediction Center (SWPC)](https://www.swpc.noaa.gov/):

| Feed | URL | Used for |
|---|---|---|
| 3-day Kp forecast (text) | `services.swpc.noaa.gov/text/3-day-geomag-forecast.txt` | Forecast chart, current Kp |
| Observed Kp (JSON) | `services.swpc.noaa.gov/products/noaa-planetary-k-index.json` | Actual measured Kp vs. forecast |
| Ovation aurora probability grid (JSON) | `services.swpc.noaa.gov/json/ovation_aurora_latest.json` | Location-based aurora chance |
| Space weather alerts (JSON) | `services.swpc.noaa.gov/products/alerts.json` | Active Alerts card, outlook verdict |
| Tonight's viewline forecast (image) | `services.swpc.noaa.gov/experimental/images/aurora_dashboard/...` | Aurora Maps |
| Ovation aurora map (image) | `services.swpc.noaa.gov/images/animations/ovation/north/latest.jpg` | Aurora Maps |
| K-index station chart (image) | `services.swpc.noaa.gov/images/station-k-index.png` | Aurora Maps |

All fetches use a 15s timeout with one automatic retry on transient failure.

## Kp / G-Scale Reference

| Kp | G-Scale | Activity |
|---|---|---|
| 0–1 | — | Very Quiet |
| 1–3 | — | Quiet |
| 3–5 | — | Active |
| 5–6 | G1 | Minor storm |
| 6–8 | G2–G3 | Strong storm |
| 8–9 | G4+ | Extreme storm |

## Requirements

- macOS 26.0+
- Xcode 26+
- Internet connection (NOAA data)
- A signed-in Apple ID in Xcode (Settings → Accounts) — required for the App Group capability used to share location/outlook state with the widget

## Adding the Widget

1. Right-click the Desktop → **Edit Widgets**
2. Click **+** and search for **Aurora Tracker**
3. Choose Small or Medium and click **Add Widget**

The widget also works in Notification Center (right-hand panel).

## Building

Open `AuroraTracker.xcodeproj` in Xcode and run the **AuroraTracker** scheme. No additional dependencies or package managers required.

On first build, confirm both the `AuroraTracker` and `AuroraWidgetExtension` targets' **Signing & Capabilities** tab shows your Team selected and the `B768V573Z6.group.manas.projects.AuroraTracker` App Group checked — Xcode needs to register the device and generate provisioning profiles for this once, which requires an interactive build from the Xcode GUI (not just `xcodebuild` from the CLI).

## Testing

Run the `AuroraTrackerTests` scheme (`Cmd+U`) — covers NOAA forecast/observed-Kp/alerts JSON parsing (including malformed-input handling) and the outlook scoring logic.

## Project Structure

- `AuroraTracker/` — macOS app (SwiftUI)
- `AuroraWidget/` — WidgetKit extension
- `Shared/` — code compiled into both targets: NOAA fetchers (`NOAAForecast.swift`, `SpaceWeatherService.swift`), the combined assessment (`AuroraOutlook.swift`), location (`LocationService.swift`), and App Group helpers (`AppGroup.swift`)
- `AuroraTrackerTests/` — unit tests for the shared parsing/scoring logic
- `icon-source/` — original art and the conversion script used to generate app icons (not part of the shipped app)
