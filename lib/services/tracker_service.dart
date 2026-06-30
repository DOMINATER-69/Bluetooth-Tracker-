import 'package:flutter/services.dart';
import '../models/last_location.dart';

/// Single point of contact for the native "tracker" MethodChannel.
///
/// Push events from native (e.g. "locationUpdated") are forwarded to any
/// registered [onLocationUpdated] callback so the UI can refresh without
/// polling.
class TrackerService {
  static const String _channelName = 'com.example.bt_tracker/tracker';
  static const MethodChannel _channel = MethodChannel(_channelName);

  static TrackerService? _instance;
  TrackerService._() {
    _channel.setMethodCallHandler(_handleNativeCall);
  }
  static TrackerService get instance => _instance ??= TrackerService._();

  /// Called by the UI when a new location has been saved natively.
  void Function()? onLocationUpdated;

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'locationUpdated') {
      onLocationUpdated?.call();
    }
  }

  // ── Reads ──────────────────────────────────────────────────────────────────

  /// Load from disk (and populate native in-memory state).
  Future<LastLocation?> loadLastLocation() async {
    try {
      final result = await _channel
          .invokeMethod<Map<Object?, Object?>>('loadLastLocation');
      if (result == null) return null;
      final loc = LastLocation.fromMap(result);
      return loc.isValid ? loc : null;
    } on PlatformException {
      return null;
    }
  }

  /// Read from native in-memory state (no disk I/O).
  Future<LastLocation?> getLastLocation() async {
    try {
      final result = await _channel
          .invokeMethod<Map<Object?, Object?>>('getLastLocation');
      if (result == null) return null;
      final loc = LastLocation.fromMap(result);
      return loc.isValid ? loc : null;
    } on PlatformException {
      return null;
    }
  }

  Future<double> getDistance(
      double lat1, double lon1, double lat2, double lon2) async {
    try {
      final result = await _channel.invokeMethod<double>('getDistance', {
        'lat1': lat1,
        'lon1': lon1,
        'lat2': lat2,
        'lon2': lon2,
      });
      return result ?? 0.0;
    } on PlatformException {
      return 0.0;
    }
  }

  Future<double> getBearing(
      double lat1, double lon1, double lat2, double lon2) async {
    try {
      final result = await _channel.invokeMethod<double>('getBearing', {
        'lat1': lat1,
        'lon1': lon1,
        'lat2': lat2,
        'lon2': lon2,
      });
      return result ?? 0.0;
    } on PlatformException {
      return 0.0;
    }
  }

  Future<void> clearBreadcrumbs() async {
    try {
      await _channel.invokeMethod<void>('clearBreadcrumbs');
    } on PlatformException {
      // ignore
    }
  }

  Future<int> getBreadcrumbCount() async {
    try {
      final result = await _channel.invokeMethod<int>('getBreadcrumbCount');
      return result ?? 0;
    } on PlatformException {
      return 0;
    }
  }

  Future<bool> isBluetoothConnected() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('isBluetoothConnected');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }
}
