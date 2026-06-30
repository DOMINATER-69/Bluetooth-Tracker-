import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';

import '../models/last_location.dart';
import '../services/tracker_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final TrackerService _tracker = TrackerService.instance;

  // ── State ──────────────────────────────────────────────────────────────────
  LastLocation? _lastLocation;
  double _distance    = 0.0;
  double _bearing     = 0.0;
  double _deviceHeading = 0.0;
  bool   _btConnected = false;
  bool   _loading     = true;
  String _statusMessage = 'Loading…';

  // ── Compass animation ──────────────────────────────────────────────────────
  // We track an "unwrapped" target angle that grows or shrinks continuously,
  // so we never suffer a 359°→0° discontinuity that makes the arrow spin
  // the wrong way.
  late final AnimationController _arrowCtrl;
  late Animation<double>         _arrowAnim;

  // The last raw target (in radians, wrapped to [-π, π]) for delta calculation.
  double _lastRawTarget    = 0.0;
  // The accumulated unwrapped target fed to the Tween.
  double _unwrappedTarget  = 0.0;
  bool   _compassFirstUpdate = true;

  // ── Listeners ──────────────────────────────────────────────────────────────
  StreamSubscription<CompassEvent>? _compassSub;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();

    _arrowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _arrowAnim = Tween<double>(begin: 0, end: 0).animate(
      CurvedAnimation(parent: _arrowCtrl, curve: Curves.easeOut),
    );

    WidgetsBinding.instance.addObserver(this);

    // Native push: location was saved → refresh immediately.
    _tracker.onLocationUpdated = () {
      if (mounted) _loadData();
    };

    _startCompass();
    _loadData();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tracker.onLocationUpdated = null;
    _compassSub?.cancel();
    _arrowCtrl.dispose();
    super.dispose();
  }

  /// Refresh when the user brings the app back to the foreground.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _loadData();
    }
  }

  // ── Compass ────────────────────────────────────────────────────────────────

  void _startCompass() {
    _compassSub = FlutterCompass.events?.listen((event) {
      final heading = event.heading;
      if (!mounted || heading == null) return;

      setState(() => _deviceHeading = heading);
      _updateArrowAngle();
    });
  }

  void _updateArrowAngle() {
    // Raw target in [-π, π] for the current bearing/heading combination.
    final rawTarget = (_bearing - _deviceHeading) * math.pi / 180.0;

    if (_compassFirstUpdate) {
      _compassFirstUpdate  = false;
      _lastRawTarget       = rawTarget;
      _unwrappedTarget     = rawTarget;
    } else {
      // Delta from the last raw target, normalised to [-π, π] for shortest path.
      double delta = rawTarget - _lastRawTarget;
      if (delta >  math.pi) delta -= 2 * math.pi;
      if (delta < -math.pi) delta += 2 * math.pi;
      _unwrappedTarget += delta;
      _lastRawTarget    = rawTarget;
    }

    // Read the animation's ACTUAL current value so interrupted animations
    // continue from the right angle rather than snapping.
    final currentValue = _arrowAnim.value;

    _arrowAnim = Tween<double>(
      begin: currentValue,
      end:   _unwrappedTarget,
    ).animate(CurvedAnimation(parent: _arrowCtrl, curve: Curves.easeOut));

    _arrowCtrl.forward(from: 0);
  }

  /// Call after bearing changes (not just heading) to re-sync the arrow.
  void _resetArrowToBearing() {
    _compassFirstUpdate = true;
    _updateArrowAngle();
  }

  // ── Data loading ───────────────────────────────────────────────────────────

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() => _loading = true);

    try {
      final results = await Future.wait([
        _tracker.loadLastLocation(),
        _tracker.isBluetoothConnected(),
      ]);

      final loc         = results[0] as LastLocation?;
      final btConnected = results[1] as bool;

      if (!mounted) return;

      if (loc != null && loc.isValid) {
        final currentPos = await _getCurrentPosition();
        double dist = 0.0;
        double bear = 0.0;

        if (currentPos != null) {
          final calc = await Future.wait([
            _tracker.getDistance(currentPos.latitude, currentPos.longitude,
                                 loc.latitude,         loc.longitude),
            _tracker.getBearing( currentPos.latitude, currentPos.longitude,
                                 loc.latitude,         loc.longitude),
          ]);
          dist = calc[0];
          bear = calc[1];
        }

        if (!mounted) return;
        final bearingChanged = (bear - _bearing).abs() > 0.5;
        setState(() {
          _lastLocation  = loc;
          _distance      = dist;
          _bearing       = bear;
          _btConnected   = btConnected;
          _loading       = false;
          _statusMessage = btConnected ? 'Connected' : 'Disconnected';
        });

        if (bearingChanged) _resetArrowToBearing();
      } else {
        setState(() {
          _lastLocation  = null;
          _btConnected   = btConnected;
          _loading       = false;
          _statusMessage = 'No location saved yet';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading       = false;
        _statusMessage = 'Error loading data';
      });
    }
  }

  Future<Position?> _getCurrentPosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) return null;

      return await Geolocator.getLastKnownPosition() ??
             await Geolocator.getCurrentPosition(
               locationSettings: const LocationSettings(
                 accuracy: LocationAccuracy.medium,
                 timeLimit: Duration(seconds: 8),
               ),
             );
    } catch (_) {
      return null;
    }
  }

  // ── Formatting helpers ─────────────────────────────────────────────────────

  String _formatDistance(double metres) {
    if (metres < 1000) return '${metres.toStringAsFixed(0)} m';
    return '${(metres / 1000).toStringAsFixed(2)} km';
  }

  String _formatAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60)  return 'Just now';
    if (diff.inMinutes < 60)  return '${diff.inMinutes}m ago';
    if (diff.inHours   < 24)  return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  String _bearingToDir(double b) {
    const dirs = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    return dirs[((b + 22.5) / 45).floor() % 8];
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0F),
        elevation: 0,
        centerTitle: true,
        title: Text(
          'BT Tracker',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: cs.primary,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            color: cs.primary,
            tooltip: 'Refresh',
            onPressed: _loadData,
          ),
        ],
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: cs.primary))
          : RefreshIndicator(
              onRefresh: _loadData,
              color: cs.primary,
              backgroundColor: const Color(0xFF12121A),
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 16),
                child: Column(
                  children: [
                    _BtStatusCard(
                        connected: _btConnected, message: _statusMessage),
                    const SizedBox(height: 20),
                    if (_lastLocation != null && _lastLocation!.isValid) ...[
                      _CompassCard(
                        arrowAnim:     _arrowAnim,
                        arrowCtrl:     _arrowCtrl,
                        deviceHeading: _deviceHeading,
                      ),
                      const SizedBox(height: 20),
                      _InfoGrid(
                        distance:      _formatDistance(_distance),
                        direction:     _bearingToDir(_bearing),
                        bearing:       _bearing,
                        ago:           _formatAgo(_lastLocation!.dateTime),
                        fullTimestamp: _lastLocation!.dateTime
                            .toLocal()
                            .toString()
                            .split('.')
                            .first,
                      ),
                    ] else ...[
                      const SizedBox(height: 40),
                      const _NoDataCard(),
                    ],
                    const SizedBox(height: 20),
                    _ClearButton(
                      enabled: _lastLocation != null,
                      onPressed: () async {
                        await _tracker.clearBreadcrumbs();
                        await _loadData();
                      },
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _BtStatusCard extends StatelessWidget {
  final bool   connected;
  final String message;
  const _BtStatusCard({required this.connected, required this.message});

  @override
  Widget build(BuildContext context) {
    final color =
        connected ? const Color(0xFF00C853) : const Color(0xFFFF1744);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1.5),
      ),
      child: Row(children: [
        Icon(connected
            ? Icons.bluetooth_connected
            : Icons.bluetooth_disabled,
            color: color, size: 26),
        const SizedBox(width: 14),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Bluetooth',
              style: TextStyle(
                  color: color.withValues(alpha: 0.8),
                  fontSize: 12,
                  letterSpacing: 1.0,
                  fontWeight: FontWeight.w600)),
          Text(message,
              style: TextStyle(
                  color: color, fontSize: 16, fontWeight: FontWeight.w700)),
        ]),
        const Spacer(),
        Container(
          width: 10, height: 10,
          decoration: BoxDecoration(
            color: color, shape: BoxShape.circle,
            boxShadow: [BoxShadow(
                color: color.withValues(alpha: 0.6),
                blurRadius: 8, spreadRadius: 2)],
          ),
        ),
      ]),
    );
  }
}

class _CompassCard extends StatelessWidget {
  final Animation<double>     arrowAnim;
  final AnimationController   arrowCtrl;
  final double                deviceHeading;

  const _CompassCard({
    required this.arrowAnim,
    required this.arrowCtrl,
    required this.deviceHeading,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF12121A),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: cs.primary.withValues(alpha: 0.2), width: 1),
      ),
      child: Column(children: [
        Text('Direction to Earbuds',
            style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.5),
                fontSize: 12, letterSpacing: 1.2,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 24),
        SizedBox(
          width: 180, height: 180,
          child: Stack(alignment: Alignment.center, children: [
            _ring(180, cs.primary, 0.15),
            _ring(120, cs.primary, 0.08),
            _ring(60,  cs.primary, 0.05),
            AnimatedBuilder(
              animation: arrowAnim,
              builder: (_, child) =>
                  Transform.rotate(angle: arrowAnim.value, child: child),
              child: CustomPaint(
                size: const Size(50, 80),
                painter: _ArrowPainter(color: cs.primary),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        Text('Heading ${deviceHeading.toStringAsFixed(0)}°',
            style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.35),
                fontSize: 11, letterSpacing: 0.8)),
      ]),
    );
  }

  Widget _ring(double size, Color color, double opacity) => Container(
        width: size, height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
              color: color.withValues(alpha: opacity), width: 1),
        ),
      );
}

class _ArrowPainter extends CustomPainter {
  final Color color;
  const _ArrowPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..style = PaintingStyle.fill;
    final glow  = Paint()
      ..color = color.withValues(alpha: 0.3)
      ..style = PaintingStyle.fill
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);

    final tip = Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width,     size.height * 0.6)
      ..lineTo(size.width / 2, size.height * 0.45)
      ..lineTo(0,              size.height * 0.6)
      ..close();

    final tail = Path()
      ..moveTo(size.width / 2,      size.height * 0.45)
      ..lineTo(size.width * 0.65,   size.height)
      ..lineTo(size.width / 2,      size.height * 0.75)
      ..lineTo(size.width * 0.35,   size.height)
      ..close();

    canvas.drawPath(tip, glow);
    canvas.drawPath(tip, paint);
    canvas.drawPath(tail,
        Paint()..color = color.withValues(alpha: 0.4)..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.color != color;
}

class _InfoGrid extends StatelessWidget {
  final String distance, direction, ago, fullTimestamp;
  final double bearing;

  const _InfoGrid({
    required this.distance,
    required this.direction,
    required this.bearing,
    required this.ago,
    required this.fullTimestamp,
  });

  @override
  Widget build(BuildContext context) => Column(children: [
        Row(children: [
          Expanded(child: _Tile(label: 'Distance', value: distance, icon: Icons.social_distance)),
          const SizedBox(width: 12),
          Expanded(child: _Tile(label: 'Direction', value: direction, icon: Icons.explore)),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _Tile(
              label: 'Bearing',
              value: '${bearing.toStringAsFixed(1)}°',
              icon: Icons.navigation)),
          const SizedBox(width: 12),
          Expanded(child: _Tile(
              label: 'Last Seen',
              value: ago,
              sub: fullTimestamp,
              icon: Icons.access_time)),
        ]),
      ]);
}

class _Tile extends StatelessWidget {
  final String label, value;
  final String? sub;
  final IconData icon;
  const _Tile({required this.label, required this.value,
               this.sub, required this.icon});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF12121A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: cs.primary.withValues(alpha: 0.15), width: 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 14, color: cs.primary.withValues(alpha: 0.6)),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.45),
                  fontSize: 11, letterSpacing: 1.0,
                  fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 8),
        Text(value,
            style: TextStyle(
                color: cs.onSurface,
                fontSize: 18, fontWeight: FontWeight.w700)),
        if (sub != null) ...[
          const SizedBox(height: 2),
          Text(sub!,
              style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.35),
                  fontSize: 10)),
        ],
      ]),
    );
  }
}

class _NoDataCard extends StatelessWidget {
  const _NoDataCard();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      decoration: BoxDecoration(
        color: const Color(0xFF12121A),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: cs.primary.withValues(alpha: 0.1), width: 1),
      ),
      child: Column(children: [
        Icon(Icons.headphones_outlined,
            size: 64, color: cs.primary.withValues(alpha: 0.3)),
        const SizedBox(height: 20),
        Text('No Location Saved',
            style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.7),
                fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Text('Disconnect your earbuds to save\nyour location automatically.',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.4),
                fontSize: 14, height: 1.5)),
      ]),
    );
  }
}

class _ClearButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onPressed;
  const _ClearButton({required this.enabled, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final borderColor = enabled
        ? Colors.redAccent.withValues(alpha: 0.5)
        : Colors.redAccent.withValues(alpha: 0.2);
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: enabled ? onPressed : null,
        icon: const Icon(Icons.delete_outline, size: 18),
        label: const Text('Clear Saved Location'),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.redAccent,
          side: BorderSide(color: borderColor),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }
}
