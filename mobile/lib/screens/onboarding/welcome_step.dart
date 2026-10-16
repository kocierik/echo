import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/echo_device_mark.dart';

/// The first screen: Echo catching a few spoken words and turning them into
/// memories, and the ways in. Always on the graphite ground, whatever the theme.
final class WelcomeStep extends StatefulWidget {
  const WelcomeStep({
    required this.onEmail,
    this.notice,
    super.key,
  });

  final VoidCallback onEmail;

  /// Why the phone is here again ("This phone was signed out.").
  final String? notice;

  @override
  State<WelcomeStep> createState() => _WelcomeStepState();
}

/// One loop of the welcome, in seconds.
const _loop = 8.0;

final class _WelcomeStepState extends State<WelcomeStep>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.disableAnimationsOf(context);
    if (still && _clock.isAnimating) {
      _clock.stop();
    } else if (!still && !_clock.isAnimating) {
      _clock.repeat();
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  Future<void> _comingSoon(String provider) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Sign in with $provider is coming soon. For now, continue with email.',
                style: Theme.of(sheetContext).textTheme.bodyLarge,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  widget.onEmail();
                },
                child: const Text('Continue with email'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The graphite ground and its colours, in light mode too
    return Theme(
      data: AppTheme.dark,
      child: Builder(builder: (context) {
        final palette = EchoPalette.of(context);
        final textTheme = Theme.of(context).textTheme;
        return Scaffold(
          backgroundColor: palette.background,
          body: SafeArea(
            child: LayoutBuilder(builder: (context, viewport) {
              // On a small screen the stage shrinks first, then the page scrolls
              final stage = (viewport.maxHeight - 430).clamp(170.0, 300.0);
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight:
                        (viewport.maxHeight - 44).clamp(0.0, double.infinity),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Echo', style: textTheme.titleLarge),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: stage,
                        child: AnimatedBuilder(
                          animation: _clock,
                          builder: (context, _) => _Stage(
                            seconds: _clock.isAnimating
                                ? _clock.value * _loop
                                : null,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      AnimatedBuilder(
                        animation: _clock,
                        builder: (context, _) => _Memories(
                          seconds:
                              _clock.isAnimating ? _clock.value * _loop : null,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Semantics(
                        header: true,
                        child: Text(
                          'Your day,\nremembered.',
                          style: textTheme.displayLarge
                              ?.copyWith(fontSize: 34, height: 1.06),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Say it once. Echo keeps it, and what you promised.',
                        style: textTheme.bodyMedium
                            ?.copyWith(color: palette.text2),
                      ),
                      if (widget.notice case final notice?) ...[
                        const SizedBox(height: 16),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            notice,
                            style: textTheme.bodyMedium?.copyWith(
                              color: palette.onAttention,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      _SignInButton(
                        key: const Key('welcome-apple'),
                        label: 'Continue with Apple',
                        background: palette.onChrome,
                        foreground: const Color(0xFF1F2326),
                        icon: const Icon(Icons.apple,
                            size: 22, color: Color(0xFF1F2326)),
                        onPressed: () => _comingSoon('Apple'),
                      ),
                      const SizedBox(height: 10),
                      _SignInButton(
                        key: const Key('welcome-google'),
                        label: 'Continue with Google',
                        background: palette.chrome,
                        foreground: palette.text,
                        icon: const SizedBox.square(
                          dimension: 20,
                          child: CustomPaint(painter: _GoogleMark()),
                        ),
                        onPressed: () => _comingSoon('Google'),
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        height: 48,
                        child: TextButton(
                          key: const Key('welcome-email'),
                          onPressed: widget.onEmail,
                          style: TextButton.styleFrom(
                              foregroundColor: palette.text),
                          child: const Text('Continue with email'),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        );
      }),
    );
  }
}

/// Where a moment of the loop falls: 0 before [from], 1 after [to], eased between.
double _ramp(double t, double from, double to) {
  if (t <= from) return 0;
  if (t >= to) return 1;
  return Curves.easeInOut.transform((t - from) / (to - from));
}

/// The device, its rings, and the phrases it catches. [seconds] is the moment of
/// the loop, null when still.
final class _Stage extends StatelessWidget {
  const _Stage({required this.seconds});

  final double? seconds;

  static const _phrases = [
    ('"Both options by Friday?"', Alignment(-1, -0.95), 0.0),
    ('"Thursday night, sure."', Alignment(1, -0.2), 0.7),
    ('"Lunch Tuesday at one?"', Alignment(-0.95, 0.92), 1.4),
  ];

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final t = seconds;
    return LayoutBuilder(builder: (context, constraints) {
      final device = math.min(128.0, constraints.maxHeight * 0.45);
      final ring = device * 1.875;
      return Stack(
        alignment: Alignment.center,
        children: [
          for (var k = 0; k < 3; k++)
            if (t != null || k == 0)
              _Ring(
                size: ring,
                // Each ring widens over 3.6 s, a third of the way after the last
                phase: t == null ? 0.5 : ((t + k * 1.2) % 3.6) / 3.6,
                color: palette.live,
              ),
          EchoDeviceGlyph(
            size: device,
            glow: t == null
                ? 0.5
                : (1 - math.cos(2 * math.pi * (t % 2.4) / 2.4)) / 2,
          ),
          if (t != null)
            for (final (text, start, delay) in _phrases)
              _Phrase(text: text, start: start, moment: (t - delay) % _loop),
        ],
      );
    });
  }
}

final class _Ring extends StatelessWidget {
  const _Ring({required this.size, required this.phase, required this.color});

  final double size;

  /// 0 → 1 as it widens and fades.
  final double phase;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Opacity(
        opacity: (0.5 * (1 - phase)).clamp(0.0, 1.0),
        child: Transform.scale(
          scale: 0.5 + 0.8 * phase,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: color, width: 1.5),
            ),
          ),
        ),
      ),
    );
  }
}

/// A spoken phrase: it appears where it was said, waits, then flies into Echo.
final class _Phrase extends StatelessWidget {
  const _Phrase(
      {required this.text, required this.start, required this.moment});

  final String text;
  final Alignment start;

  /// Seconds since this phrase's turn began.
  final double moment;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final shown = _ramp(moment, 0, 0.64);
    final caught = _ramp(moment, 2.56, 3.84);
    final opacity = shown * (1 - caught);
    if (opacity <= 0) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.lerp(start, Alignment.center, caught)!,
      child: ExcludeSemantics(
        child: Opacity(
          opacity: opacity,
          child: Transform.scale(
            scale: 1 - 0.7 * caught,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                text,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontSize: 14,
                      color: palette.text2,
                    ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What Echo kept: a promise and a lunch. Always shown when still.
final class _Memories extends StatelessWidget {
  const _Memories({required this.seconds});

  final double? seconds;

  double _visible(double delay) {
    final t = seconds;
    if (t == null) return 1;
    final u = (t - delay) % _loop;
    return _ramp(u, 4.0, 4.8) * (1 - _ramp(u, 7.36, 8.0));
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _Memory(
            label: 'Promise to Marco',
            text: 'Both options, Thu',
            background: palette.attention,
            accent: palette.onAttention,
            visible: _visible(0),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _Memory(
            label: 'Calendar',
            text: 'Lunch, Tue 13:00',
            background: palette.accentSoft,
            accent: palette.onAccentSoft,
            visible: _visible(0.4),
          ),
        ),
      ],
    );
  }
}

final class _Memory extends StatelessWidget {
  const _Memory({
    required this.label,
    required this.text,
    required this.background,
    required this.accent,
    required this.visible,
  });

  final String label;
  final String text;
  final Color background;
  final Color accent;
  final double visible;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Opacity(
      opacity: visible,
      child: Transform.translate(
        offset: Offset(0, 12 * (1 - visible)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelSmall
                    ?.copyWith(color: accent, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelLarge?.copyWith(fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _SignInButton extends StatelessWidget {
  const _SignInButton({
    required this.label,
    required this.background,
    required this.foreground,
    required this.icon,
    required this.onPressed,
    super.key,
  });

  final String label;
  final Color background;
  final Color foreground;
  final Widget icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 54,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: background,
          foregroundColor: foreground,
          shape: const StadiumBorder(),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            icon,
            const SizedBox(width: 10),
            Flexible(
                child:
                    Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
    );
  }
}

/// Google's "G", in its four colours.
final class _GoogleMark extends CustomPainter {
  const _GoogleMark();

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.2;
    final rect = Offset.zero & size;
    final arc = rect.deflate(stroke / 2);
    Paint paint(int color) => Paint()
      ..color = Color(color)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas
      ..drawArc(arc, -2.45, 1.75, false, paint(0xFFEA4335))
      ..drawArc(arc, 2.3, 1.1, false, paint(0xFFFBBC05))
      ..drawArc(arc, 0.75, 1.6, false, paint(0xFF34A853))
      ..drawArc(arc, -0.05, 0.85, false, paint(0xFF4285F4))
      ..drawRect(
        Rect.fromLTWH(size.width / 2, size.height / 2 - stroke / 2,
            size.width / 2, stroke),
        Paint()..color = const Color(0xFF4285F4),
      );
  }

  @override
  bool shouldRepaint(covariant _GoogleMark oldDelegate) => false;
}
