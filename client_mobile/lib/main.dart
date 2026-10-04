import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
    DeviceOrientation.portraitUp,
  ]);
  runApp(const RemotePcApp());
}

class RemotePcApp extends StatelessWidget {
  const RemotePcApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Remote PC Controller',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8),
          secondary: Color(0xFF818CF8),
          surface: Color(0xFF1E293B),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF1E293B),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8.0),
            borderSide: const BorderSide(color: Color(0xFF334155)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8.0),
            borderSide: const BorderSide(color: Color(0xFF38BDF8), width: 1.5),
          ),
        ),
      ),
      home: const RemoteControllerScreen(),
    );
  }
}

class RemoteControllerScreen extends StatefulWidget {
  const RemoteControllerScreen({super.key});

  @override
  State<RemoteControllerScreen> createState() => _RemoteControllerScreenState();
}

class _RemoteControllerScreenState extends State<RemoteControllerScreen> {
  final TextEditingController _ipController =
      TextEditingController(text: '192.168.1.100:8765');
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocusNode = FocusNode();
  final GlobalKey _viewportKey = GlobalKey();

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _pingTimer;

  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isScanning = false;
  String _statusMessage = 'Tap "Auto-Detect PC" or enter IP';
  Uint8List? _latestFrameBytes;

  int _latencyMs = 0;
  int _fpsCount = 0;
  int _renderedFps = 0;
  DateTime _lastFpsCheck = DateTime.now();

  double _remoteWidth = 1920;
  double _remoteHeight = 1080;
  String _hostPcName = '';

  @override
  void dispose() {
    _disconnect();
    _ipController.dispose();
    _textController.dispose();
    _textFocusNode.dispose();
    super.dispose();
  }

  /// Automatically discovers PC on the local Wi-Fi network using UDP broadcast beacon
  Future<void> _autoDiscoverPc() async {
    if (_isScanning || _isConnected) return;

    setState(() {
      _isScanning = true;
      _statusMessage = 'Searching Wi-Fi network for PC...';
    });

    RawDatagramSocket? socket;
    Timer? timeoutTimer;

    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;

      // Listen for UDP response from Windows PC host
      socket.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket?.receive();
          if (datagram != null) {
            final reply = utf8.decode(datagram.data);
            if (reply.startsWith('REMOTE_PC_HOST:')) {
              // Expected format: REMOTE_PC_HOST:<HOSTNAME>:<IP>:8765
              final parts = reply.split(':');
              if (parts.length >= 4) {
                final hostName = parts[1];
                final hostIp = parts[2];
                final hostPort = parts[3];
                final fullAddress = '$hostIp:$hostPort';

                timeoutTimer?.cancel();
                socket?.close();

                if (mounted) {
                  setState(() {
                    _ipController.text = fullAddress;
                    _hostPcName = hostName;
                    _isScanning = false;
                    _statusMessage = 'Found $hostName ($fullAddress)! Connecting...';
                  });
                  _showToast('Found $hostName ($fullAddress)');
                  // Automatically connect once found!
                  _connect();
                }
              }
            }
          }
        }
      });

      // Send discovery broadcast beacon to port 8766
      final pingBytes = utf8.encode('DISCOVER_REMOTE_PC');
      socket.send(pingBytes, InternetAddress('255.255.255.255'), 8766);

      // Stop scanning after 3.5 seconds if no response
      timeoutTimer = Timer(const Duration(milliseconds: 3500), () {
        socket?.close();
        if (mounted && _isScanning) {
          setState(() {
            _isScanning = false;
            _statusMessage = 'No PC found automatically. Enter IP manually.';
          });
          _showToast('No PC found. Enter IP manually or verify same Wi-Fi.');
        }
      });
    } catch (e) {
      socket?.close();
      if (mounted) {
        setState(() {
          _isScanning = false;
          _statusMessage = 'Auto-detect unavailable. Enter PC IP from host window and tap Connect.';
        });
        _showToast('Enter PC IP directly from your PC host window');
      }
    }
  }

  void _connect() {
    if (_isConnected || _isConnecting) return;

    final target = _ipController.text.trim();
    if (target.isEmpty) {
      _showToast('Please specify Host IP and port');
      return;
    }

    final wsUrl = target.startsWith('ws://') || target.startsWith('wss://')
        ? target
        : 'ws://$target';

    setState(() {
      _isConnecting = true;
      _statusMessage = 'Connecting to $wsUrl...';
    });

    try {
      final uri = Uri.parse(wsUrl);
      _channel = WebSocketChannel.connect(uri);

      _subscription = _channel!.stream.listen(
        (data) {
          if (!_isConnected) {
            setState(() {
              _isConnected = true;
              _isConnecting = false;
              _statusMessage = 'Connected to ${_hostPcName.isNotEmpty ? _hostPcName : wsUrl}';
            });
            _startPingLoop();
          }

          if (data is Uint8List) {
            _onFrameReceived(data);
          } else if (data is List<int>) {
            _onFrameReceived(Uint8List.fromList(data));
          } else if (data is String) {
            _onTextMessageReceived(data);
          }
        },
        onError: (error) {
          _disconnect();
          setState(() {
            _statusMessage = 'Connection error: $error';
          });
        },
        onDone: () {
          _disconnect();
          setState(() {
            _statusMessage = 'Disconnected by host';
          });
        },
      );
    } catch (e) {
      _disconnect();
      setState(() {
        _statusMessage = 'Failed to connect: $e';
      });
    }
  }

  void _disconnect() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;

    if (mounted) {
      setState(() {
        _isConnected = false;
        _isConnecting = false;
        _latencyMs = 0;
        _renderedFps = 0;
        _statusMessage = 'Disconnected';
      });
    }
  }

  void _startPingLoop() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!_isConnected || _channel == null) {
        timer.cancel();
        return;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      _sendJson({
        'type': 'ping',
        'timestamp': now,
      });
    });
  }

  void _onFrameReceived(Uint8List frameBytes) {
    _fpsCount++;
    final now = DateTime.now();
    if (now.difference(_lastFpsCheck).inMilliseconds >= 1000) {
      setState(() {
        _renderedFps = _fpsCount;
        _fpsCount = 0;
        _lastFpsCheck = now;
      });
    }

    setState(() {
      _latestFrameBytes = frameBytes;
    });
  }

  void _onTextMessageReceived(String text) {
    try {
      final dynamic decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        final type = decoded['type'];
        if (type == 'pong') {
          final sentTs = decoded['timestamp'];
          if (sentTs is num) {
            final now = DateTime.now().millisecondsSinceEpoch;
            setState(() {
              _latencyMs = (now - sentTs.toInt()).clamp(0, 9999);
            });
          }
        } else if (type == 'info') {
          setState(() {
            _remoteWidth = (decoded['width'] as num?)?.toDouble() ?? 1920;
            _remoteHeight = (decoded['height'] as num?)?.toDouble() ?? 1080;
            if (decoded['host_name'] != null) {
              _hostPcName = decoded['host_name'].toString();
            }
          });
        }
      }
    } catch (_) {}
  }

  void _sendJson(Map<String, dynamic> payload) {
    if (!_isConnected || _channel == null) return;
    try {
      _channel!.sink.add(jsonEncode(payload));
    } catch (_) {}
  }

  void _handleTouch(Offset localPosition, {bool isClick = false, String button = 'left'}) {
    final RenderBox? box =
        _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;

    final Size widgetSize = box.size;
    if (widgetSize.width <= 0 || widgetSize.height <= 0) return;

    final double hostAspect = _remoteWidth / _remoteHeight;
    final double viewAspect = widgetSize.width / widgetSize.height;

    double renderedWidth;
    double renderedHeight;
    double offsetX = 0;
    double offsetY = 0;

    if (viewAspect > hostAspect) {
      renderedHeight = widgetSize.height;
      renderedWidth = widgetSize.height * hostAspect;
      offsetX = (widgetSize.width - renderedWidth) / 2;
    } else {
      renderedWidth = widgetSize.width;
      renderedHeight = widgetSize.width / hostAspect;
      offsetY = (widgetSize.height - renderedHeight) / 2;
    }

    final double touchInsideX = localPosition.dx - offsetX;
    final double touchInsideY = localPosition.dy - offsetY;

    if (touchInsideX < 0 ||
        touchInsideX > renderedWidth ||
        touchInsideY < 0 ||
        touchInsideY > renderedHeight) {
      return;
    }

    final double normalizedX = (touchInsideX / renderedWidth).clamp(0.0, 1.0);
    final double normalizedY = (touchInsideY / renderedHeight).clamp(0.0, 1.0);

    _sendJson({
      'type': 'move',
      'x': normalizedX,
      'y': normalizedY,
    });

    if (isClick) {
      _sendJson({
        'type': 'click',
        'button': button,
      });
    }
  }

  void _sendTypingText() {
    final text = _textController.text;
    if (text.isEmpty) return;

    _sendJson({
      'type': 'type',
      'text': text,
    });

    _textController.clear();
  }

  void _sendKey(String key) {
    _sendJson({
      'type': 'key',
      'key': key,
    });
  }

  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(child: _buildScreenViewport()),
            _buildActionBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 8.0),
      decoration: const BoxDecoration(
        color: Color(0xFF1E293B),
        border: Border(bottom: BorderSide(color: Color(0xFF334155))),
      ),
      child: Row(
        children: [
          // Connection status dot
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _isConnected
                  ? const Color(0xFF22C55E)
                  : (_isConnecting || _isScanning
                      ? const Color(0xFFEAB308)
                      : const Color(0xFFEF4444)),
            ),
          ),
          const SizedBox(width: 8),

          // 1-Click Auto-Detect PC Button (No typing needed!)
          if (!_isConnected)
            Padding(
              padding: const EdgeInsets.only(right: 6.0),
              child: SizedBox(
                height: 38,
                child: OutlinedButton.icon(
                  onPressed: _isScanning || _isConnecting ? null : _autoDiscoverPc,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF38BDF8),
                    side: const BorderSide(color: Color(0xFF0284C7)),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: _isScanning
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF38BDF8)),
                        )
                      : const Icon(Icons.wifi_find, size: 16),
                  label: Text(_isScanning ? 'Scanning...' : 'Auto-Detect PC',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ),
            ),

          // Host IP / Port Input
          Expanded(
            child: SizedBox(
              height: 38,
              child: TextField(
                controller: _ipController,
                enabled: !_isConnected && !_isConnecting && !_isScanning,
                style: const TextStyle(fontSize: 13, color: Colors.white),
                decoration: const InputDecoration(
                  hintText: '192.168.1.100:8765',
                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                  prefixIcon: Icon(Icons.computer, size: 16, color: Color(0xFF94A3B8)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),

          // Connect / Disconnect button
          SizedBox(
            height: 38,
            child: ElevatedButton(
              onPressed: _isConnecting || _isScanning
                  ? null
                  : (_isConnected ? _disconnect : _connect),
              style: ElevatedButton.styleFrom(
                backgroundColor: _isConnected ? const Color(0xFFDC2626) : const Color(0xFF0284C7),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(
                _isConnected ? 'Disconnect' : 'Connect',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(width: 10),

          // Latency & FPS indicators
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_latencyMs}ms',
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: _latencyMs < 50
                      ? const Color(0xFF22C55E)
                      : (_latencyMs < 120 ? const Color(0xFFEAB308) : const Color(0xFFEF4444)),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${_renderedFps}fps',
                style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: Color(0xFF38BDF8),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildScreenViewport() {
    return Container(
      key: _viewportKey,
      color: Colors.black,
      width: double.infinity,
      height: double.infinity,
      child: _isConnected && _latestFrameBytes != null
          ? GestureDetector(
              onTapDown: (details) =>
                  _handleTouch(details.localPosition, isClick: true, button: 'left'),
              onSecondaryTapDown: (details) =>
                  _handleTouch(details.localPosition, isClick: true, button: 'right'),
              onLongPressStart: (details) =>
                  _handleTouch(details.localPosition, isClick: true, button: 'right'),
              onPanUpdate: (details) =>
                  _handleTouch(details.localPosition, isClick: false),
              child: Center(
                child: AspectRatio(
                  aspectRatio: _remoteWidth / _remoteHeight,
                  child: Image.memory(
                    _latestFrameBytes!,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.low,
                  ),
                ),
              ),
            )
          : Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _isConnected ? Icons.videocam : Icons.screen_share_outlined,
                    size: 48,
                    color: const Color(0xFF64748B),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _statusMessage,
                    style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
                  ),
                  if (!_isConnected && !_isScanning)
                    Padding(
                      padding: const EdgeInsets.only(top: 14.0),
                      child: ElevatedButton.icon(
                        onPressed: _autoDiscoverPc,
                        icon: const Icon(Icons.wifi_find, size: 16),
                        label: const Text('Auto-Detect PC on Wi-Fi'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0369A1),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _buildActionBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 8.0),
      decoration: const BoxDecoration(
        color: Color(0xFF1E293B),
        border: Border(top: BorderSide(color: Color(0xFF334155))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 38,
                  child: TextField(
                    controller: _textController,
                    focusNode: _textFocusNode,
                    enabled: _isConnected,
                    onSubmitted: (_) => _sendTypingText(),
                    style: const TextStyle(fontSize: 13, color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: 'Type text to send to host...',
                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 38,
                child: ElevatedButton.icon(
                  onPressed: _isConnected ? _sendTypingText : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF38BDF8),
                    foregroundColor: const Color(0xFF0F172A),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.send, size: 16),
                  label: const Text('Send'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildKeyButton('Enter', 'enter', Icons.keyboard_return),
                const SizedBox(width: 6),
                _buildKeyButton('Backspace', 'backspace', Icons.backspace_outlined),
                const SizedBox(width: 6),
                _buildKeyButton('Escape', 'escape', Icons.close),
                const SizedBox(width: 6),
                _buildKeyButton('Space', 'space', Icons.space_bar),
                const SizedBox(width: 6),
                _buildKeyButton('Tab', 'tab', Icons.keyboard_tab),
                const SizedBox(width: 6),
                _buildKeyButton('Win', 'win', Icons.window),
                const SizedBox(width: 6),
                _buildClickButton('Right Click', 'right', Icons.mouse),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKeyButton(String label, String keyVal, IconData icon) {
    return OutlinedButton.icon(
      onPressed: _isConnected ? () => _sendKey(keyVal) : null,
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white70,
        side: const BorderSide(color: Color(0xFF475569)),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      icon: Icon(icon, size: 14),
      label: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  Widget _buildClickButton(String label, String button, IconData icon) {
    return OutlinedButton.icon(
      onPressed: _isConnected ? () => _sendJson({'type': 'click', 'button': button}) : null,
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFF38BDF8),
        side: const BorderSide(color: Color(0xFF0284C7)),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      icon: Icon(icon, size: 14),
      label: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}
