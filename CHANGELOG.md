# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [SemVer](https://semver.org/).

## [2.0.0] - 2026-10-18

Ground-up redesign built around one question: *will I see aurora?* Kp is no longer the headline.

### Added
- **Sidebar navigation** with four pages: Tonight, Forecast, Maps, What is Kp?. Active alert count shows as a badge on Tonight.
- **% chance of aurora overhead** (NOAA OVATION, per your location) as the hero number in the app and both widgets.
- **Cloud cover** at your location (Open-Meteo, no API key) in the app and widgets, with a new "Likely Hidden by Clouds" verdict at 85% or more.
- **Plain-language activity levels** (Calm, Quiet, Active, Minor storm, Strong storm, Extreme storm), each with a sentence on where aurora can be seen. One shared table (`KpBand`) drives app and widget.
- **Kp gauge**: a 0-9 colored meter (`KpMeter`) showing how stormy the sky is.
- **"What is Kp?" page** explaining Kp, the G-scale, and why location matters.

### Changed
- Tonight page: the outlook is now the hero card; active alerts moved to a banner at the top instead of sitting under the Kp card.
- Forecast page: the Kp/G-scale legend now sits directly under the chart it explains.
- Maps page: all tiles share one fixed size (images fit, never cropped) and the grid adapts to window width.
- Widgets (small and medium) lead with the % chance and verdict; Kp is a footnote. Medium chart retitled "Today's activity" with the day's peak in words.
- Verdicts reworded from "Tonight" to "Now" (e.g. "Good Chance Now", "Unlikely Now"): OVATION is a roughly one-hour nowcast, not a nightly forecast.
- Outlook reasoning now reads in plain words ("Sky activity is quiet right now; forecast says active") instead of raw Kp numbers.
- NOAA credit and last-updated time moved to the sidebar footer; Open-Meteo credited alongside.
- Minimum macOS window width raised from 680 to 820 to fit the sidebar.

### Fixed
- Stale code comment claiming OVATION grid values were 0-9; they are percentages (0-100).

### Notes
- Cloud cover is a third-party, non-NOAA source: your location, rounded to the nearest degree, is sent to Open-Meteo to fetch it.
- Open-Meteo is credited as "Weather data by Open-Meteo.com" (CC BY 4.0) in the app sidebar and README. Open-Meteo's free tier is non-commercial and requires attribution.
- The widget gallery may cache the old layout; remove and re-add the widget after upgrading.

## [1.0.0]

Initial release: NOAA Kp forecast and observed Kp, active alerts, location-based outlook, aurora maps, and a macOS widget.
