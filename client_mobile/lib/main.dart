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

class WebShortcutItem {
  final String name;
  final String url;
  final IconData icon;

  const WebShortcutItem({required this.name, required this.url, required this.icon});

  Map<String, dynamic> toJson() => {'name': name, 'url': url};

  factory WebShortcutItem.fromJson(Map<String, dynamic> json) {
    return WebShortcutItem(
      name: json['name'] ?? '',
      url: json['url'] ?? '',
      icon: Icons.language,
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
  final TextEditingController _customAppController = TextEditingController();
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

  // Display Mode: Aspect Ratio Fit vs Full Screen Stretch
  bool _isFitScreen = true;

  // Control Mode: Direct Touch Screen vs Laptop Trackpad
  bool _isDirectTouchMode = true;
  bool _isDragLocked = false;
  final double _trackpadSensitivity = 1.35;

  // Custom Websites & Shortcuts
  final List<WebShortcutItem> _webShortcuts = [
    const WebShortcutItem(name: 'YouTube', url: 'https://youtube.com', icon: Icons.play_circle_fill),
    const WebShortcutItem(name: 'Google', url: 'https://google.com', icon: Icons.search),
    const WebShortcutItem(name: 'ChatGPT', url: 'https://chatgpt.com', icon: Icons.smart_toy),
    const WebShortcutItem(name: 'Netflix', url: 'https://netflix.com', icon: Icons.movie),
    const WebShortcutItem(name: 'Twitch', url: 'https://twitch.tv', icon: Icons.live_tv),
    const WebShortcutItem(name: 'Reddit', url: 'https://reddit.com', icon: Icons.forum),
    const WebShortcutItem(name: 'GitHub', url: 'https://github.com', icon: Icons.code),
  ];

  @override
  void dispose() {
    _disconnect();
    _ipController.dispose();
    _textController.dispose();
    _customAppController.dispose();
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

      socket.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket?.receive();
          if (datagram != null) {
            final reply = utf8.decode(datagram.data);
            if (reply.startsWith('REMOTE_PC_HOST:')) {
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
                  _connect();
                }
              }
            }
          }
        }
      });

      final pingBytes = utf8.encode('DISCOVER_REMOTE_PC');
      socket.send(pingBytes, InternetAddress('255.255.255.255'), 8766);

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

  Offset? _getNormalizedCoordinates(Offset localPosition) {
    final RenderBox? box =
        _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;

    final Size widgetSize = box.size;
    if (widgetSize.width <= 0 || widgetSize.height <= 0) return null;

    if (!_isFitScreen) {
      return Offset(
        (localPosition.dx / widgetSize.width).clamp(0.0, 1.0),
        (localPosition.dy / widgetSize.height).clamp(0.0, 1.0),
      );
    }

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

    return Offset(
      (touchInsideX / renderedWidth).clamp(0.0, 1.0),
      (touchInsideY / renderedHeight).clamp(0.0, 1.0),
    );
  }

  void _handleDirectTouchTap(Offset localPosition) {
    final coords = _getNormalizedCoordinates(localPosition);
    if (coords == null) return;

    _sendJson({'type': 'move', 'x': coords.dx, 'y': coords.dy});
    _sendJson({'type': 'click', 'button': 'left'});
  }

  void _handleDirectTouchDoubleTap(Offset localPosition) {
    final coords = _getNormalizedCoordinates(localPosition);
    if (coords == null) return;

    _sendJson({'type': 'move', 'x': coords.dx, 'y': coords.dy});
    _sendJson({'type': 'double_click', 'button': 'left'});
  }

  void _handleDirectTouchLongPress(Offset localPosition) {
    final coords = _getNormalizedCoordinates(localPosition);
    if (coords == null) return;

    _sendJson({'type': 'move', 'x': coords.dx, 'y': coords.dy});
    _sendJson({'type': 'click', 'button': 'right'});
    HapticFeedback.mediumImpact();
    _showToast('Right clicked');
  }

  void _handleDirectTouchPanStart(DragStartDetails details) {
    if (_isDirectTouchMode) {
      final coords = _getNormalizedCoordinates(details.localPosition);
      if (coords != null) {
        _sendJson({'type': 'move', 'x': coords.dx, 'y': coords.dy});
        _sendJson({'type': 'mouse_down', 'button': 'left'});
      }
    }
  }

  void _handleDirectTouchPanUpdate(DragUpdateDetails details) {
    if (_isDirectTouchMode) {
      final coords = _getNormalizedCoordinates(details.localPosition);
      if (coords != null) {
        _sendJson({'type': 'move', 'x': coords.dx, 'y': coords.dy});
      }
    } else {
      // Precision Trackpad relative movement
      final dx = details.delta.dx * _trackpadSensitivity;
      final dy = details.delta.dy * _trackpadSensitivity;
      _sendJson({'type': 'move_relative', 'dx': dx, 'dy': dy});
    }
  }

  void _handleDirectTouchPanEnd(DragEndDetails details) {
    if (_isDirectTouchMode) {
      _sendJson({'type': 'mouse_up', 'button': 'left'});
    }
  }

  void _sendTypingText() {
    final text = _textController.text;
    if (text.isEmpty) return;

    _sendJson({'type': 'type', 'text': text});
    _textController.clear();
  }

  void _sendKey(String key) {
    _sendJson({'type': 'key', 'key': key});
    if (key == 'win') {
      _showToast('Toggled Windows Start Menu');
    }
  }

  void _openWebUrl(String url) {
    _sendJson({'type': 'open_url', 'url': url});
    _showToast('Opening $url on PC');
  }

  void _launchApp(String app) {
    if (app.trim().isEmpty) return;
    _sendJson({'type': 'launch_app', 'app': app.trim()});
    _showToast('Launching $app on PC');
  }

  void _showAddShortcutDialog() {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController(text: 'https://');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Add Custom Website Shortcut', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: 'Shortcut Name (e.g. My Anime Site, Work Jira)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: 'Website URL (e.g. https://...)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF94A3B8))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0284C7)),
            onPressed: () {
              final name = nameCtrl.text.trim();
              final url = urlCtrl.text.trim();
              if (name.isNotEmpty && url.isNotEmpty) {
                setState(() {
                  _webShortcuts.add(WebShortcutItem(name: name, url: url, icon: Icons.bookmark));
                });
                Navigator.pop(ctx);
                _showToast('Added shortcut: $name');
              }
            },
            child: const Text('Add', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showShortcutsAndAppsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => DefaultTabController(
        length: 2,
        child: Container(
          height: MediaQuery.of(context).size.height * 0.7,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(color: const Color(0xFF475569), borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(height: 12),
              const TabBar(
                indicatorColor: Color(0xFF38BDF8),
                labelColor: Color(0xFF38BDF8),
                unselectedLabelColor: Color(0xFF94A3B8),
                tabs: [
                  Tab(icon: Icon(Icons.language), text: 'Websites & Shortcuts'),
                  Tab(icon: Icon(Icons.apps), text: 'PC & Desktop Apps'),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: TabBarView(
                  children: [
                    // Tab 1: Websites & Custom Shortcuts
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('QUICK WEB SHORTCUTS', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.bold)),
                            TextButton.icon(
                              onPressed: _showAddShortcutDialog,
                              icon: const Icon(Icons.add, size: 16, color: Color(0xFF38BDF8)),
                              label: const Text('Add Custom Site', style: TextStyle(color: Color(0xFF38BDF8), fontSize: 12)),
                            ),
                          ],
                        ),
                        Expanded(
                          child: GridView.builder(
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              childAspectRatio: 2.2,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                            ),
                            itemCount: _webShortcuts.length,
                            itemBuilder: (context, index) {
                              final item = _webShortcuts[index];
                              return InkWell(
                                onTap: () {
                                  Navigator.pop(ctx);
                                  _openWebUrl(item.url);
                                },
                                borderRadius: BorderRadius.circular(8),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1E293B),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: const Color(0xFF334155)),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(item.icon, size: 20, color: const Color(0xFF38BDF8)),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          item.name,
                                          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),

                    // Tab 2: Apps & Desktop Launcher
                    SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('LAUNCH ANY APP OR DESKTOP SHORTCUT', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _customAppController,
                                  style: const TextStyle(color: Colors.white, fontSize: 13),
                                  decoration: const InputDecoration(
                                    hintText: 'e.g. chrome, steam, discord, calc, notepad',
                                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF0284C7),
                                  foregroundColor: Colors.white,
                                ),
                                onPressed: () {
                                  Navigator.pop(ctx);
                                  _launchApp(_customAppController.text);
                                },
                                child: const Text('Launch'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          const Text('POPULAR PC APPLICATIONS', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _buildAppLaunchChip(ctx, 'File Explorer', 'explorer', Icons.folder),
                              _buildAppLaunchChip(ctx, 'Desktop Folder', 'explorer shell:Desktop', Icons.desktop_windows),
                              _buildAppLaunchChip(ctx, 'Task Manager', 'taskmgr', Icons.analytics),
                              _buildAppLaunchChip(ctx, 'Chrome', 'chrome', Icons.public),
                              _buildAppLaunchChip(ctx, 'Command Prompt', 'cmd', Icons.terminal),
                              _buildAppLaunchChip(ctx, 'PowerShell', 'powershell', Icons.code),
                              _buildAppLaunchChip(ctx, 'Notepad', 'notepad', Icons.description),
                              _buildAppLaunchChip(ctx, 'Calculator', 'calc', Icons.calculate),
                              _buildAppLaunchChip(ctx, 'Settings', 'ms-settings:', Icons.settings),
                              _buildAppLaunchChip(ctx, 'Steam', 'steam', Icons.sports_esports),
                              _buildAppLaunchChip(ctx, 'Spotify', 'spotify', Icons.music_note),
                              _buildAppLaunchChip(ctx, 'Discord', 'discord', Icons.chat),
                              _buildAppLaunchChip(ctx, 'VS Code', 'code', Icons.integration_instructions),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAppLaunchChip(BuildContext ctx, String label, String cmd, IconData icon) {
    return ActionChip(
      backgroundColor: const Color(0xFF1E293B),
      side: const BorderSide(color: Color(0xFF334155)),
      avatar: Icon(icon, size: 16, color: const Color(0xFF38BDF8)),
      label: Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
      onPressed: () {
        Navigator.pop(ctx);
        _launchApp(cmd);
      },
    );
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
            _buildQuickMouseControlBar(),
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
          // Connection status indicator
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

          // 1-Click Auto-Detect PC Button
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
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF38BDF8)),
                        )
                      : const Icon(Icons.wifi_find, size: 16),
                  label: Text(_isScanning ? 'Scanning...' : 'Auto-Detect PC', style: const TextStyle(fontSize: 12)),
                ),
              ),
            ),

          // Target IP TextField
          Expanded(
            child: SizedBox(
              height: 38,
              child: TextField(
                controller: _ipController,
                enabled: !_isConnected && !_isConnecting,
                style: const TextStyle(fontSize: 13, color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'IP:Port (e.g. 192.168.1.45:8765)',
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                  suffixIcon: _isConnected
                      ? const Icon(Icons.lock_open, size: 16, color: Color(0xFF22C55E))
                      : null,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),

          // Connect / Disconnect button
          SizedBox(
            height: 38,
            child: ElevatedButton(
              onPressed: _isConnecting
                  ? null
                  : (_isConnected ? _disconnect : _connect),
              style: ElevatedButton.styleFrom(
                backgroundColor: _isConnected
                    ? const Color(0xFFDC2626)
                    : const Color(0xFF0284C7),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(_isConnected ? 'Disconnect' : 'Connect', style: const TextStyle(fontSize: 12)),
            ),
          ),
          const SizedBox(width: 6),

          // Aspect Ratio Fit / Fill Toggle
          IconButton(
            onPressed: () => setState(() => _isFitScreen = !_isFitScreen),
            icon: Icon(
              _isFitScreen ? Icons.aspect_ratio : Icons.fullscreen,
              color: const Color(0xFF38BDF8),
              size: 20,
            ),
            tooltip: _isFitScreen ? 'Switch to Stretch Fill' : 'Switch to Aspect Ratio Fit',
          ),

          // Shortcuts & Apps Sheet Trigger
          IconButton(
            onPressed: _showShortcutsAndAppsSheet,
            icon: const Icon(Icons.rocket_launch, color: Color(0xFF38BDF8), size: 20),
            tooltip: 'Websites & Apps Launcher',
          ),
        ],
      ),
    );
  }

  Widget _buildScreenViewport() {
    return Container(
      key: _viewportKey,
      color: Colors.black,
      child: _latestFrameBytes != null
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              // Direct Touch Screen Handlers
              onTapDown: (details) {
                if (_isDirectTouchMode) {
                  _handleDirectTouchTap(details.localPosition);
                } else {
                  _sendJson({'type': 'click', 'button': 'left'});
                }
              },
              onDoubleTapDown: (details) {
                if (_isDirectTouchMode) {
                  _handleDirectTouchDoubleTap(details.localPosition);
                } else {
                  _sendJson({'type': 'double_click', 'button': 'left'});
                }
              },
              onLongPressStart: (details) {
                if (_isDirectTouchMode) {
                  _handleDirectTouchLongPress(details.localPosition);
                } else {
                  _sendJson({'type': 'click', 'button': 'right'});
                }
              },
              onPanStart: _handleDirectTouchPanStart,
              onPanUpdate: _handleDirectTouchPanUpdate,
              onPanEnd: _handleDirectTouchPanEnd,
              child: Center(
                child: _isFitScreen
                    ? AspectRatio(
                        aspectRatio: _remoteWidth / _remoteHeight,
                        child: Image.memory(
                          _latestFrameBytes!,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.low,
                        ),
                      )
                    : SizedBox.expand(
                        child: Image.memory(
                          _latestFrameBytes!,
                          fit: BoxFit.fill,
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
                    _isConnected ? 'Waiting for screen frames from PC...' : _statusMessage,
                    style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
                  ),
                  if (_isConnected) ...[
                    const SizedBox(height: 12),
                    const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF38BDF8)),
                    ),
                  ],
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

  /// Toolbar for switching between Touch Screen and Trackpad Mouse Modes, with mouse buttons
  Widget _buildQuickMouseControlBar() {
    return Container(
      color: const Color(0xFF0F172A),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          // Mode Toggle: Touch Screen vs Trackpad
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  onTap: () => setState(() => _isDirectTouchMode = true),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: _isDirectTouchMode ? const Color(0xFF0284C7) : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      children: const [
                        Icon(Icons.touch_app, size: 14, color: Colors.white),
                        SizedBox(width: 4),
                        Text('Touch Screen', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
                      ],
                    ),
                  ),
                ),
                InkWell(
                  onTap: () => setState(() => _isDirectTouchMode = false),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: !_isDirectTouchMode ? const Color(0xFF0284C7) : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      children: const [
                        Icon(Icons.mouse, size: 14, color: Colors.white),
                        SizedBox(width: 4),
                        Text('Trackpad', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Live stats badge
          if (_isConnected) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '$_renderedFps FPS | ${_latencyMs}ms',
                style: const TextStyle(fontSize: 10, color: Color(0xFF38BDF8), fontWeight: FontWeight.bold),
              ),
            ),
          ],

          const Spacer(),

          // Mouse Action Buttons
          _buildQuickActionButton('Left Click', Icons.mouse, () => _sendJson({'type': 'click', 'button': 'left'})),
          const SizedBox(width: 6),
          _buildQuickActionButton('Right Click', Icons.mouse_outlined, () => _sendJson({'type': 'click', 'button': 'right'})),
          const SizedBox(width: 6),
          _buildQuickActionButton('Double', Icons.filter_2, () => _sendJson({'type': 'double_click', 'button': 'left'})),
          const SizedBox(width: 6),
          _buildQuickActionButton('Scroll ▲', Icons.arrow_upward, () => _sendJson({'type': 'scroll', 'dy': -3})),
          const SizedBox(width: 6),
          _buildQuickActionButton('Scroll ▼', Icons.arrow_downward, () => _sendJson({'type': 'scroll', 'dy': 3})),
        ],
      ),
    );
  }

  Widget _buildQuickActionButton(String label, IconData icon, VoidCallback onPressed) {
    return InkWell(
      onTap: _isConnected ? onPressed : null,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF334155)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: const Color(0xFF38BDF8)),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(fontSize: 11, color: Colors.white70)),
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
                      hintText: 'Type text to send to PC...',
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
                // Prominent Windows Start Menu Key
                ElevatedButton.icon(
                  onPressed: _isConnected ? () => _sendKey('win') : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0284C7),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  icon: const Icon(Icons.window, size: 16),
                  label: const Text('Win (Start)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 6),
                _buildKeyButton('Win+D (Desktop)', 'desktop', Icons.desktop_windows),
                const SizedBox(width: 6),
                _buildKeyButton('TaskMgr', 'taskmgr', Icons.analytics_outlined),
                const SizedBox(width: 6),
                _buildKeyButton('Alt+Tab', 'alt+tab', Icons.switch_access_shortcut),
                const SizedBox(width: 6),
                _buildKeyButton('Enter', 'enter', Icons.keyboard_return),
                const SizedBox(width: 6),
                _buildKeyButton('Backspace', 'backspace', Icons.backspace_outlined),
                const SizedBox(width: 6),
                _buildKeyButton('Esc', 'escape', Icons.close),
                const SizedBox(width: 6),
                _buildKeyButton('Tab', 'tab', Icons.keyboard_tab),
                const SizedBox(width: 6),
                _buildKeyButton('Space', 'space', Icons.space_bar),
                const SizedBox(width: 6),
                _buildKeyButton('Copy', 'ctrl+c', Icons.copy),
                const SizedBox(width: 6),
                _buildKeyButton('Paste', 'ctrl+v', Icons.paste),
                const SizedBox(width: 6),
                _buildKeyButton('Undo', 'ctrl+z', Icons.undo),
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
}
