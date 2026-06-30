class LastLocation {
  final double latitude;
  final double longitude;
  final int timestamp;

  const LastLocation({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
  });

  factory LastLocation.fromMap(Map<Object?, Object?> map) {
    return LastLocation(
      latitude: (map['latitude'] as num).toDouble(),
      longitude: (map['longitude'] as num).toDouble(),
      timestamp: (map['timestamp'] as num).toInt(),
    );
  }

  Map<String, dynamic> toMap() => {
        'latitude': latitude,
        'longitude': longitude,
        'timestamp': timestamp,
      };

  DateTime get dateTime =>
      DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: false);

  bool get isValid => latitude != 0.0 || longitude != 0.0;

  @override
  String toString() =>
      'LastLocation(lat=$latitude, lon=$longitude, ts=$timestamp)';
}
