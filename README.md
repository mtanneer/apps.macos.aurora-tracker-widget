# AuroraTracker

A native macOS app and widget that displays live NOAA geomagnetic Kp index data and aurora forecasts.

## Features

### Widget
- **Small**: Current Kp index with color-coded activity level badge
- **Medium**: Current Kp index + 8-bar mini chart showing today's 3-hour forecast slots (current slot highlighted)
- Refreshes every 30 minutes
- Click to open the full dashboard app

### App Dashboard
- **Current Kp card**: Live Kp reading tied to the current UTC 3-hour window, with today's peak and average
- **3-day forecast chart**: Bar chart for all 8 time slots per day; switch between days with a segmented picker; G1/G2/G3 storm thresholds overlaid
- **Aurora Maps**: Three NOAA image feeds — Tonight's Viewline Forecast, Ovation Aurora Map, and K-Index Station readings
- **Map detail view**: Click any map to open a full-screen view with pinch-to-zoom, pan, double-tap to zoom, zoom buttons, and a share option
- **Kp / G-Scale legend** for quick reference

## Data Source

All data is fetched from [NOAA Space Weather Prediction Center (SWPC)](https://www.swpc.noaa.gov/):

| Feed | URL |
|---|---|
| 3-day Kp forecast (text) | `services.swpc.noaa.gov/text/3-day-geomag-forecast.txt` |
| Tonight's viewline forecast | `services.swpc.noaa.gov/experimental/images/aurora_dashboard/...` |
| Ovation aurora map | `services.swpc.noaa.gov/images/animations/ovation/north/latest.jpg` |
| K-index station chart | `services.swpc.noaa.gov/images/station-k-index.png` |

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

## Adding the Widget

1. Right-click the Desktop → **Edit Widgets**
2. Click **+** and search for **Aurora Tracker**
3. Choose Small or Medium and click **Add Widget**

The widget also works in Notification Center (right-hand panel).

## Building

Open `AuroraTracker.xcodeproj` in Xcode and run the **AuroraTracker** scheme. No additional dependencies or package managers required.
