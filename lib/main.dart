import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kAppUrl = 'https://alifmeta.vercel.app';
const Color kBrandBg = Color(0xFFF4F7F5); // matches site theme-color
const Color kBrandDark = Color(0xFF1A1A1A);
const Color kAccent = Color(0xFF4FB6DE); // sampled from the ALIF mark

const String _kPrefHasLoadedOnce = 'has_loaded_once';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Force fullscreen: hide the status bar and the Android nav bar.
  // "immersiveSticky" means a swipe from the edge briefly reveals them,
  // then they auto-hide again — the standard behavior for fullscreen apps.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const AlifMedApp());
}

class AlifMedApp extends StatelessWidget {
  const AlifMedApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Alif Med',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: kBrandBg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: kBrandDark,
          background: kBrandBg,
        ),
        fontFamily: 'Roboto',
      ),
      home: const WebViewHome(),
    );
  }
}

class WebViewHome extends StatefulWidget {
  const WebViewHome({super.key});

  @override
  State<WebViewHome> createState() => _WebViewHomeState();
}

class _WebViewHomeState extends State<WebViewHome>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  late final WebViewController _controller;
  late final AnimationController _pulseController;
  late final AnimationController _sweepController;

  double _loadProgress = 0;

  // Full-screen branded overlay — only ever shown for the very first cold
  // load of the session, so the app doesn't look "stuck" on every reload.
  bool _isFirstLoad = true;
  bool _isLoading = true;

  // Slim top progress bar — used for every navigation *after* the first one
  // (pull-to-refresh, in-site links, and SPA route changes).
  bool _isNavigating = false;

  bool _hasError = false;

  // Raw signal from the OS: is there a network connection right now?
  // This alone must NEVER hide the currently-loaded page — a page that's
  // already rendered in the WebView keeps working fine after data is
  // switched off, exactly like a normal browser tab does.
  bool _networkOffline = false;

  // What actually drives the offline screen in the UI. Only set to true
  // when a real navigation attempt has nothing to fall back on — never
  // just because the network dropped while a page was already showing.
  bool _showOfflineScreen = false;

  bool _showSlowHint = false;

  bool _controllerLoaded = false; // has loadRequest ever actually fired?
  bool _hasLoadedOnce = false; // persisted: has the site ever loaded fully?

  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Timer? _connDebounce;
  Timer? _slowLoadTimer;
  Timer? _offlineFallbackTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pulseController =
        AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
          ..repeat(reverse: true);
    _sweepController =
        AnimationController(vsync: this, duration: const Duration(milliseconds: 950))
          ..repeat();
    _initWebView();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    _hasLoadedOnce = prefs.getBool(_kPrefHasLoadedOnce) ?? false;

    final results = await Connectivity().checkConnectivity();
    _networkOffline = results.every((r) => r == ConnectivityResult.none);

    _connSub = Connectivity().onConnectivityChanged.listen(_onConnectivityChanged);

    if (_networkOffline && !_hasLoadedOnce) {
      // Nothing has ever been cached and there's no network right now —
      // don't waste time spinning, go straight to the offline screen.
      if (mounted) {
        setState(() {
          _isLoading = false;
          _showOfflineScreen = true;
        });
      }
      return;
    }

    await _startLoadIfNeeded();
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final offline = results.every((r) => r == ConnectivityResult.none);
    _connDebounce?.cancel();
    _connDebounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      // Just record the raw signal — do NOT touch the UI here. A page
      // that's already loaded and on screen keeps working fine; there is
      // nothing to "go offline" from. This only matters the next time a
      // navigation is attempted, and for auto-retrying below.
      final wasOffline = _networkOffline;
      _networkOffline = offline;
      if (wasOffline && !offline && _showOfflineScreen) {
        // We were genuinely showing the offline screen and the connection
        // just came back — bring the app back to life automatically.
        _startLoadIfNeeded();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Android restores the system bars when the app resumes from the
    // background, so re-apply fullscreen each time we come back.
    if (state == AppLifecycleState.resumed) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  void _initWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(kBrandBg)
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/120.0.0.0 Mobile Safari/537.36 AlifMedApp/1.0',
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) setState(() => _loadProgress = progress / 100);
          },
          onPageStarted: (url) {
            if (!mounted) return;
            setState(() {
              _hasError = false;
              // A real navigation is happening and about to either succeed
              // or fail on its own merits — clear any previous offline
              // screen so it doesn't linger under/behind the new attempt.
              _showOfflineScreen = false;
              if (_isFirstLoad) {
                _isLoading = true;
              } else {
                _isNavigating = true;
                _loadProgress = 0;
              }
            });
            _armLoadTimers();
          },
          onPageFinished: (url) async {
            _slowLoadTimer?.cancel();
            _offlineFallbackTimer?.cancel();
            if (!mounted) return;
            setState(() {
              _isLoading = false;
              _isNavigating = false;
              _showSlowHint = false;
              _showOfflineScreen = false;
            });
            _isFirstLoad = false;
            if (!_hasLoadedOnce) {
              _hasLoadedOnce = true;
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool(_kPrefHasLoadedOnce, true);
            }
          },
          onWebResourceError: (error) {
            // Only react to main-frame failures; ignore failing sub-resources
            // (trackers, fonts, etc.) so a single blocked asset can't trigger
            // a full error screen.
            if (!mounted || error.isForMainFrame == false) return;
            _slowLoadTimer?.cancel();
            _offlineFallbackTimer?.cancel();
            setState(() {
              _isLoading = false;
              _isNavigating = false;
              _showSlowHint = false;
              // A navigation just genuinely failed. If there's no network,
              // that's the offline state — and it means this particular
              // page/request has nothing usable cached for it. If we think
              // we're online, it's a real app error instead.
              if (_networkOffline) {
                _showOfflineScreen = true;
              } else {
                _hasError = true;
              }
            });
          },
          onUrlChange: (change) {
            // Client-side (SPA) route changes don't fire onPageStarted /
            // onPageFinished, so give a quick, tasteful sweep on the top
            // bar to acknowledge the navigation happened.
            if (!_isFirstLoad && !_isNavigating) {
              _flashRouteChangeIndicator();
            }
          },
          onNavigationRequest: (request) {
            // Keep navigation inside the webview for the same site;
            // external links (mailto, tel, other domains) open natively.
            final uri = Uri.tryParse(request.url);
            if (uri != null &&
                (uri.scheme == 'mailto' ||
                    uri.scheme == 'tel' ||
                    uri.scheme == 'sms')) {
              _launchExternal(request.url);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );
  }

  void _armLoadTimers() {
    _slowLoadTimer?.cancel();
    _offlineFallbackTimer?.cancel();

    // If a first load is taking a while, let the person know we're still
    // trying rather than leaving the animation looking frozen.
    _slowLoadTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && _isLoading) setState(() => _showSlowHint = true);
    });

    // If we're offline but attempting to load anyway (because something may
    // be cached), and nothing renders in a reasonable time, fall back to the
    // offline screen instead of spinning forever.
    if (_networkOffline) {
      _offlineFallbackTimer = Timer(const Duration(seconds: 6), () {
        if (mounted && (_isLoading || _isNavigating)) {
          setState(() {
            _isLoading = false;
            _isNavigating = false;
            _showOfflineScreen = true;
          });
        }
      });
    }
  }

  void _flashRouteChangeIndicator() {
    if (!mounted) return;
    setState(() => _isNavigating = true);
    Future.delayed(const Duration(milliseconds: 550), () {
      if (mounted) setState(() => _isNavigating = false);
    });
  }

  Future<void> _launchExternal(String url) async {
    // Placeholder for url_launcher if you add it later.
    // For now these schemes are simply ignored inside the webview.
  }

  /// Starts the very first load, or reloads if a load has already happened.
  Future<void> _startLoadIfNeeded() async {
    if (!_controllerLoaded) {
      _controllerLoaded = true;
      if (mounted) {
        setState(() {
          _isLoading = true;
          _hasError = false;
        });
      }
      _armLoadTimers();
      await _controller.loadRequest(Uri.parse(kAppUrl));
    } else {
      await _reload();
    }
  }

  Future<void> _reload() async {
    if (mounted) {
      setState(() => _hasError = false);
    }
    if (!_controllerLoaded) {
      await _startLoadIfNeeded();
      return;
    }
    await _controller.reload();
  }

  /// Retry button on the offline screen: re-check real connectivity first
  /// rather than blindly hammering the webview against a dead network.
  Future<void> _retryFromOffline() async {
    final results = await Connectivity().checkConnectivity();
    final offline = results.every((r) => r == ConnectivityResult.none);
    _networkOffline = offline;
    if (!offline) {
      if (mounted) setState(() => _showOfflineScreen = false);
      await _startLoadIfNeeded();
    } else if (mounted) {
      // Still genuinely offline — nudge the UI so the button feels
      // responsive even though nothing changed yet.
      setState(() {});
    }
  }

  Future<bool> _onWillPop() async {
    if (await _controller.canGoBack()) {
      _controller.goBack();
      return false;
    }
    return true;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connSub?.cancel();
    _connDebounce?.cancel();
    _slowLoadTimer?.cancel();
    _offlineFallbackTimer?.cancel();
    _pulseController.dispose();
    _sweepController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showFullOverlay =
        _isFirstLoad && _isLoading && !_hasError && !_showOfflineScreen;

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && mounted) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: kBrandBg,
        body: Stack(
          children: [
            // Base layer: connectivity/error state, or the live site.
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: _showOfflineScreen
                  ? _OfflineView(key: const ValueKey('offline'), onRetry: _retryFromOffline)
                  : _hasError
                      ? _ErrorView(key: const ValueKey('error'), onRetry: _reload)
                      : KeyedSubtree(
                          key: const ValueKey('web'),
                          child: RefreshIndicator(
                            color: kAccent,
                            backgroundColor: kBrandBg,
                            onRefresh: _reload,
                            child: WebViewWidget(controller: _controller),
                          ),
                        ),
            ),

            // Slim top progress bar for every navigation after the first.
            _TopProgressBar(
              visible: _isNavigating,
              progress: _loadProgress,
              sweep: _sweepController,
            ),

            // Full branded overlay — first cold load only, crossfades out.
            if (_isFirstLoad)
              IgnorePointer(
                ignoring: !showFullOverlay,
                child: AnimatedOpacity(
                  opacity: showFullOverlay ? 1 : 0,
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOut,
                  child: _LoadingOverlay(
                    pulse: _pulseController,
                    showSlowHint: _showSlowHint,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Slim animated bar pinned to the top of the screen used for in-app
/// navigation. Shows real progress when the webview reports it, and a
/// gentle indeterminate sweep for SPA route changes that report none.
class _TopProgressBar extends StatelessWidget {
  final bool visible;
  final double progress;
  final Animation<double> sweep;

  const _TopProgressBar({
    required this.visible,
    required this.progress,
    required this.sweep,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: SizedBox(
            height: 3,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                return Stack(
                  children: [
                    Container(color: kBrandDark.withOpacity(0.05)),
                    if (progress > 0.03 && progress < 1)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        width: width * progress,
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [kAccent, kBrandDark],
                          ),
                        ),
                      )
                    else
                      AnimatedBuilder(
                        animation: sweep,
                        builder: (context, _) {
                          final barWidth = width * 0.32;
                          final x = (sweep.value * (width + barWidth)) - barWidth;
                          return Transform.translate(
                            offset: Offset(x, 0),
                            child: Container(
                              width: barWidth,
                              height: 3,
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Color(0x004FB6DE),
                                    kAccent,
                                    Color(0x004FB6DE),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// A small, centered, quick ECG (heartbeat) trace that draws itself in a
/// continuous loop — one beat after another — instead of a plain loading
/// bar. Purely decorative/indeterminate; it doesn't track real progress.
class _EcgLoader extends StatefulWidget {
  const _EcgLoader({this.width = 150, this.height = 46});

  final double width;
  final double height;

  @override
  State<_EcgLoader> createState() => _EcgLoaderState();
}

class _EcgLoaderState extends State<_EcgLoader> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          size: Size(widget.width, widget.height),
          painter: _EcgPainter(progress: _controller.value),
        ),
      ),
    );
  }
}

class _EcgPainter extends CustomPainter {
  final double progress; // 0..1, loops continuously

  _EcgPainter({required this.progress});

  // A single stylised PQRST heartbeat cycle, as fractions of the drawing
  // box (x: 0..1 across one beat, y: -1..1 where positive is "up").
  static const List<List<double>> _beat = [
    [0.00, 0.0],
    [0.10, 0.0],
    [0.13, 0.22], // P wave
    [0.16, 0.0],
    [0.32, 0.0],
    [0.35, -0.12], // Q dip
    [0.37, 1.0], // R spike
    [0.39, -0.5], // S dip
    [0.42, 0.0],
    [0.56, 0.0],
    [0.60, 0.40], // T wave
    [0.64, 0.0],
    [1.00, 0.0],
  ];

  static const int _beatsAcross = 2;

  Path _buildPath(Size size) {
    final path = Path();
    double xAt(double f) => f * size.width;
    double yAt(double up) => size.height * 0.62 - up * size.height * 0.46;

    for (int b = 0; b < _beatsAcross; b++) {
      final offset = b / _beatsAcross;
      const scale = 1 / _beatsAcross;
      for (int i = 0; i < _beat.length; i++) {
        final px = xAt(offset + _beat[i][0] * scale);
        final py = yAt(_beat[i][1]);
        if (b == 0 && i == 0) {
          path.moveTo(px, py);
        } else {
          path.lineTo(px, py);
        }
      }
    }
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = _buildPath(size);

    // Reveal the trace left-to-right as progress goes 0 -> 1, then it
    // snaps back and draws again — "one beat after another".
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width * progress, size.height));

    final glowPaint = Paint()
      ..color = kAccent.withOpacity(0.32)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawPath(path, glowPaint);

    final linePaint = Paint()
      ..color = kAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, linePaint);
    canvas.restore();

    // A small glowing tip at the leading edge, like a monitor's pen.
    final metrics = path.computeMetrics().toList();
    if (metrics.isNotEmpty && progress > 0.01 && progress < 1) {
      final metric = metrics.first;
      final tangent = metric.getTangentForOffset(metric.length * progress);
      if (tangent != null) {
        canvas.drawCircle(tangent.position, 6, Paint()..color = kAccent.withOpacity(0.20));
        canvas.drawCircle(tangent.position, 2.4, Paint()..color = kAccent);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _EcgPainter oldDelegate) => oldDelegate.progress != progress;
}

class _LoadingOverlay extends StatelessWidget {
  final Animation<double> pulse;
  final bool showSlowHint;

  const _LoadingOverlay({
    required this.pulse,
    required this.showSlowHint,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBrandBg,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: pulse,
              builder: (context, child) {
                final t = pulse.value; // 0..1
                final scale = 0.94 + (t * 0.08);
                final glow = 0.10 + (t * 0.10);
                return SizedBox(
                  width: 160,
                  height: 160,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: 140 * (0.9 + t * 0.2),
                        height: 140 * (0.9 + t * 0.2),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: kAccent.withOpacity(glow),
                        ),
                      ),
                      Transform.scale(scale: scale, child: child),
                    ],
                  ),
                );
              },
              child: Image.asset('assets/splash_logo.png', width: 108, height: 108),
            ),
            const SizedBox(height: 22),
            const _EcgLoader(),
            const SizedBox(height: 18),
            AnimatedOpacity(
              opacity: showSlowHint ? 1 : 0,
              duration: const Duration(milliseconds: 400),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  'Still on it — this can take a little longer on a slow connection.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, color: kBrandDark, height: 1.4),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorView({super.key, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return _MessageView(
      icon: Icons.error_outline_rounded,
      title: 'Something went wrong',
      subtitle: "We couldn't load Alif Med. Please try again.",
      onRetry: onRetry,
    );
  }
}

class _OfflineView extends StatelessWidget {
  final VoidCallback onRetry;
  const _OfflineView({super.key, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return _MessageView(
      icon: Icons.wifi_off_rounded,
      title: 'No internet connection',
      subtitle:
          "You'll be reconnected automatically once you're back online — or check your connection and retry.",
      onRetry: onRetry,
    );
  }
}

class _MessageView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onRetry;

  const _MessageView({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBrandBg,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: kAccent.withOpacity(0.10),
                ),
                child: Icon(icon, size: 38, color: kBrandDark.withOpacity(0.65)),
              ),
              const SizedBox(height: 22),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: kBrandDark,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 14,
                  color: kBrandDark.withOpacity(0.6),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: onRetry,
                style: ElevatedButton.styleFrom(
                  backgroundColor: kBrandDark,
                  foregroundColor: kBrandBg,
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
