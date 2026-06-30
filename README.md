# BT Tracker

**Bluetooth Earphone Last Seen Tracker** — When your Bluetooth earbuds disconnect, the app saves your current location exactly once. Open the app later to see the last-seen time, distance, and a compass arrow pointing toward your earbuds.

---

## Features

- **Zero continuous GPS** — location captured once on disconnect, never polled
- **BroadcastReceiver** — listens for `BluetoothDevice.ACTION_ACL_DISCONNECTED`
- **Debounce** — duplicate disconnect events are ignored within a 3-second window
- **Location priority**: Passive provider → Last Known → Single high-accuracy request
- **Foreground Service** — starts only during capture, self-stops immediately after
- **Native C++17 engine** via Android NDK — Haversine distance, bearing calculation, binary breadcrumb file
- **Compass arrow** — rotates using `bearing − deviceHeading` via `flutter_compass`
- **Material 3 dark theme** — no Maps, no Firebase, no unnecessary packages
- **Extremely low battery usage** — no timers, no loops, no background polling

---

## Project Structure

```
bt_tracker/
├── .github/
│   └── workflows/
│       └── android.yml          # CI: Java 17, latest Flutter stable, APK artifact
├── android/
│   ├── app/
│   │   ├── build.gradle         # NDK, cmake, Kotlin 2, minSdk 23
│   │   ├── proguard-rules.pro
│   │   └── src/main/
│   │       ├── AndroidManifest.xml
│   │       ├── cpp/
│   │       │   ├── CMakeLists.txt     # C++17, -O2, no RTTI
│   │       │   └── tracker.cpp        # Haversine, bearing, binary save/load
│   │       ├── kotlin/com/example/bt_tracker/
│   │       │   ├── MainActivity.kt    # FlutterActivity + MethodChannel + JNI
│   │       │   ├── BluetoothReceiver.kt   # BroadcastReceiver (debounced)
│   │       │   └── LocationCaptureService.kt  # ForegroundService, single capture
│   │       └── res/
│   │           ├── drawable/          # Launch background, adaptive icon assets
│   │           ├── mipmap-anydpi-v26/ # Adaptive icons (API 26+)
│   │           └── values/            # Strings, styles
│   ├── build.gradle
│   ├── gradle.properties
│   ├── settings.gradle
│   └── gradle/wrapper/gradle-wrapper.properties
├── lib/
│   ├── main.dart
│   ├── models/
│   │   └── last_location.dart
│   ├── services/
│   │   └── tracker_service.dart  # MethodChannel wrapper
│   └── screens/
│       └── home_screen.dart      # Compass, distance, direction, timestamp
└── pubspec.yaml
```

---

## Getting Started

### Prerequisites

| Tool | Version |
|------|---------|
| Flutter | 3.22+ stable |
| Dart | 3.4+ |
| Android SDK | API 35 (compileSdk) |
| NDK | 27.2.12479018 |
| Java | 17 |
| CMake | 3.22.1+ |

### Setup

```bash
# 1. Clone / download the project
cd bt_tracker

# 2. Install Flutter dependencies
flutter pub get

# 3. Connect an Android device (minSdk 23 = Android 6.0+)
flutter devices

# 4. Run debug build
flutter run

# 5. Build release APK
flutter build apk --release --split-per-abi
```

> **Note:** The release APKs will be at `build/app/outputs/flutter-apk/`.

### Mipmap Icons

The adaptive icon XMLs are provided for API 26+. For API 23–25 devices, add PNG icons to:

```
android/app/src/main/res/mipmap-hdpi/ic_launcher.png    (72×72)
android/app/src/main/res/mipmap-mdpi/ic_launcher.png    (48×48)
android/app/src/main/res/mipmap-xhdpi/ic_launcher.png   (96×96)
android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png  (144×144)
android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png (192×192)
```

Or run:
```bash
flutter pub add --dev flutter_launcher_icons
# configure flutter_launcher_icons in pubspec.yaml, then:
dart run flutter_launcher_icons
```

### Permissions Required at Runtime

| Permission | When |
|-----------|------|
| `BLUETOOTH_CONNECT` | Android 12+ — reading device name/state |
| `ACCESS_FINE_LOCATION` | Location capture on disconnect |
| `POST_NOTIFICATIONS` | Foreground service notification (Android 13+) |

Request these in the UI before the first disconnect event, or handle them in `MainActivity.kt`.

---

## Architecture

### Bluetooth Flow

```
Device disconnects
       │
BluetoothReceiver.onReceive()
       │  (debounce 3s per device address)
       ▼
LocationCaptureService.startForegroundService()
       │
       ├─ Step 1: PASSIVE_PROVIDER.getLastKnown()  → fresh? → save & stop
       ├─ Step 2: GPS_PROVIDER.getLastKnown()       → fresh? → save & stop
       ├─ Step 3: NETWORK_PROVIDER.getLastKnown()   → fresh? → save & stop
       ├─ Step 4: best of above (any age)            → save & stop
       └─ Step 5: requestLocationUpdates() once → save & stop
       │
MainActivity.nativeSaveLastLocation() (JNI → tracker.cpp)
       │
binary write to files/last_location.bin
       │
stopForeground() + stopSelf()
```

### Native Engine (tracker.cpp)

| Function | Purpose |
|---------|---------|
| `nativeSaveLastLocation` | Append to breadcrumb vector, persist binary |
| `nativeLoadLastLocation` | Read binary file into memory |
| `nativeGetLastLocation` | Return in-memory last location |
| `nativeGetDistance` | Haversine formula (meters) |
| `nativeGetBearing` | Forward azimuth (0–360°) |
| `nativeClearBreadcrumbs` | Clear vector + overwrite file |
| `nativeGetBreadcrumbCount` | Vector size |

Binary file format:

```
[FileHeader: magic(4) + version(4) + count(4)]
[LocationRecord × count: lat(8) + lon(8) + ts(8)]
[last LocationRecord: lat(8) + lon(8) + ts(8)]
[bool locationValid: 1]
```

### UI (home_screen.dart)

- **Compass arrow** — `AnimatedBuilder` on `AnimationController`, angle = `(bearing − deviceHeading) × π/180`
- **Shortest-path rotation** — diff normalized to `[-π, π]` prevents 350° spin
- **Distance** — formatted as `m` or `km`
- **Direction** — 8-point compass rose (N, NE, E, …)
- **5-second refresh timer** — minimal polling only in foreground

---

## CI / GitHub Actions

`.github/workflows/android.yml`:
- Triggered on push/PR to `main`/`master`
- Java 17 (Temurin)
- Latest Flutter stable
- `flutter build apk --release --split-per-abi`
- Uploads all split APKs as `release-apks` artifact (30-day retention)

---

## Battery & Memory Design

| Goal | Mechanism |
|------|-----------|
| No continuous GPS | `requestLocationUpdates` called once, immediately removed after first fix |
| No background loops | No `WorkManager`, no `Timer`, no `ScheduledExecutorService` |
| No polling | `BroadcastReceiver` is event-driven |
| Foreground service lifecycle | `START_NOT_STICKY` — not restarted if killed |
| RAM < 20 MB | Native C++ holds only 1 `LocationRecord` + vector (capped at 200) |
| No Firebase, no Maps | Zero heavyweight SDKs |

---

## License

MIT
