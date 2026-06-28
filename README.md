# AGP Wear Hub – SDK Integration Guide

This document describes how to plug your native SDK (Android / iOS) into the Flutter app via platform channels.

## Channels

- **MethodChannel:** `agp_sdk`
- **EventChannel (optional, HR live):** `agp_sdk/hr_stream`

## Methods (MethodChannel)

- `scan() -> List<Map>`
  - Returns: `[{ "id": String, "name": String, "rssi": int? }]`

- `connect({ "id": String }) -> bool`
  - Returns `true` on success

- `readMetrics({ "id": String }) -> Map`
  - Returns: `{ "heartRate": int, "steps": int, "battery": int }` (fill what you can)

- `startHeartRateNotifications({ "id": String }) -> void`
  - Start streaming HR via EventChannel (if implemented)
  
- `stopHeartRateNotifications({ "id": String }) -> void`
  - Stop streaming

## Event Stream (optional)

- **EventChannel:** `agp_sdk/hr_stream`
- **Payload:** plain integer BPM (`int`), e.g. `72`

## Android

- File: `android/app/src/main/kotlin/.../MainActivity.kt`
- Replace TODOs with your SDK calls:
  - Resolve device by ID (your SDK).
  - Start/stop HR notifications; on each BPM, call `hrSink?.success(bpm)`.
- Permissions declared in `AndroidManifest.xml` (already provided).

## iOS

- File: `ios/Runner/AppDelegate.swift`
- Replace TODOs with your SDK calls:
  - Resolve device/session by ID.
  - Start/stop HR notifications; emit BPM with `hrEventSink?(bpm)`.
- Add usage descriptions in `Info.plist` (already provided).

## Flutter Side

- The app already contains a `MethodChannelWearSdk` Dart adapter compatible with the methods above.
- BLE fallback remains available via `flutter_blue_plus`.

## Data Types

```json
// Device
{ "id": "string", "name": "string", "rssi": -65 }

// Metrics
{ "heartRate": 72, "steps": 1234, "battery": 87 }
