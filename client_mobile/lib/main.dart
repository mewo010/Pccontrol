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
}

class ConnectedPhoneClient {
  final int id;
  final String ip;
  final String deviceName;
  final String deviceId;
  final int connectedAt;
  final bool isLocked;
  final int lockedUntil;
  final bool isAdmin;

  ConnectedPhoneClient({
    required this.id,
    required this.ip,
    required this.deviceName,
    required this.deviceId,
    required this.connectedAt,
    required this.isLocked,
    required this.lockedUntil,
    required this.isAdmin,
  });

  factory ConnectedPhoneClient.fromJson(Map<String, dynamic> json) {
    return ConnectedPhoneClient(
      id: (json['id'] as num?)?.toInt() ?? 0,
      ip: json['ip']?.toString() ?? '',
      deviceName: json['device_name']?.toString() ?? 'Phone',
      deviceId: json['device_id']?.toString() ?? '',
      connectedAt: (json['connected_at'] as num?)?.toInt() ?? 0,
      isLocked: json['is_locked'] == true,
      lockedUntil: (json['locked_until'] as num?)?.toInt() ?? 0,
      isAdmin: json['is_admin'] == true,
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
  final TextEditingController _adminPasswordController = TextEditingController();
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

  int _myClientId = 0;
  String _myPersistentDeviceId = '';
  int _latencyMs = 0;
  int _fpsCount = 0;
  int _renderedFps = 0;
  DateTime _lastFpsCheck = DateTime.now();

  double _remoteWidth = 1920;
  double _remoteHeight = 1080;
  String _hostPcName = '';

  // Active Navigation Tab: 0 = Touchpad, 1 = Screen Mirror, 2 = Apps & Web, 3 = Admin
  int _currentTabIndex = 0;

  // Trackpad Settings
  double _trackpadSensitivity = 1.5;
  bool _isDragLocked = false;

  // Screen View Fit/Stretch
  bool _isFitScreen = true;

  // --- Admin Portal State ---
  bool _isAdminAuthenticated = false;
  bool _isAdminAuthenticating = false;
  bool _obscureAdminPassword = true;
  List<ConnectedPhoneClient> _connectedPhones = [];

  // --- Persistent Client Lock State ---
  bool _isThisPhoneLocked = false;
  int _thisPhoneLockedUntil = 0;
  int _remainingLockSeconds = 0;
  Timer? _lockCountdownTimer;

  // Local storage files for persistence across app restarts
  File get _localLockFile => File('${Directory.systemTemp.path}/remote_pc_persistent_lock.json');
  File get _localDeviceIdFile => File('${Directory.systemTemp.path}/remote_pc_persistent_device_id.txt');

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
  void initState() {
    super.initState();
    _initPersistentState();
  }

  /// Initialize persistent device ID and check if previously locked
  void _initPersistentState() {
    try {
      // 1. Get or create persistent device ID
      if (_localDeviceIdFile.existsSync()) {
        _myPersistentDeviceId = _localDeviceIdFile.readAsStringSync().trim();
      }
      if (_myPersistentDeviceId.isEmpty) {
        _myPersistentDeviceId = 'phone_${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecond % 10000}';
        _localDeviceIdFile.writeAsStringSync(_myPersistentDeviceId);
      }

      // 2. Check persistent lock file
      if (_localLockFile.existsSync()) {
        final content = _localLockFile.readAsStringSync();
        final dynamic data = jsonDecode(content);
        if (data is Map<String, dynamic> && data['is_locked'] == true) {
          final int lockedUntil = (data['locked_until'] as num?)?.toInt() ?? 0;
          final int nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

          if (lockedUntil == 0 || lockedUntil > nowSec) {
            _isThisPhoneLocked = true;
            _thisPhoneLockedUntil = lockedUntil;
            _remainingLockSeconds = lockedUntil > 0 ? (lockedUntil - nowSec) : 0;
            _startLockCountdown();
          } else {
            // Lock expired
            _localLockFile.deleteSync();
          }
        }
      }
    } catch (_) {}
  }

  void _persistLockState(bool locked, int lockedUntil) {
    try {
      if (locked) {
        _localLockFile.writeAsStringSync(jsonEncode({
          'is_locked': true,
          'locked_until': lockedUntil,
        }));
      } else {
        if (_localLockFile.existsSync()) {
          _localLockFile.deleteSync();
        }
      }
    } catch (_) {}
  }

  void _startLockCountdown() {
    _lockCountdownTimer?.cancel();
    if (_thisPhoneLockedUntil > 0) {
      _lockCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted || !_isThisPhoneLocked) {
          timer.cancel();
          return;
        }
        setState(() {
          final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          if (_thisPhoneLockedUntil > nowSec) {
            _remainingLockSeconds = _thisPhoneLockedUntil - nowSec;
          } else {
            _isThisPhoneLocked = false;
            _persistLockState(false, 0);
            timer.cancel();
          }
        });
      });
    }
  }

  @override
  void dispose() {
    _disconnect();
    _lockCountdownTimer?.cancel();
    _ipController.dispose();
    _textController.dispose();
    _customAppController.dispose();
    _adminPasswordController.dispose();
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
          _showToast('No PC found. Enter IP manually or check same Wi-Fi.');
        }
      });
    } catch (e) {
      socket?.close();
      if (mounted) {
        setState(() {
          _isScanning = false;
          _statusMessage = 'Enter PC IP from host window and tap Connect.';
        });
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

            // Send handshake with persistent device ID
            _sendJson({
              'type': 'client_hello',
              'device_name': 'Android Phone',
              'device_id': _myPersistentDeviceId,
            });
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
        _isAdminAuthenticated = false;
        _latencyMs = 0;
        _renderedFps = 0;
        _latestFrameBytes = null;
        _connectedPhones = [];
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
    if (_isThisPhoneLocked) return;

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
            if (decoded['client_id'] != null) {
              _myClientId = (decoded['client_id'] as num).toInt();
            }
          });
        } else if (type == 'admin_auth_result') {
          final success = decoded['success'] == true;
          final msg = decoded['message']?.toString() ?? '';
          setState(() {
            _isAdminAuthenticating = false;
            _isAdminAuthenticated = success;
          });
          _showToast(msg);
        } else if (type == 'admin_clients_list') {
          final listRaw = decoded['clients'] as List<dynamic>? ?? [];
          setState(() {
            _connectedPhones = listRaw
                .map((e) => ConnectedPhoneClient.fromJson(e as Map<String, dynamic>))
                .toList();
          });
        } else if (type == 'lock_status') {
          final locked = decoded['is_locked'] == true;
          final lockedUntil = (decoded['locked_until'] as num?)?.toInt() ?? 0;
          final remSec = (decoded['remaining_seconds'] as num?)?.toInt() ?? 0;

          setState(() {
            _isThisPhoneLocked = locked;
            _thisPhoneLockedUntil = lockedUntil;
            _remainingLockSeconds = remSec;
          });

          // Save to local file so reopening app keeps the lock
          _persistLockState(locked, lockedUntil);

          if (locked) {
            _startLockCountdown();
          } else {
            _lockCountdownTimer?.cancel();
          }
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

  // --- Mouse & Keyboard Actions ---

  void _handleTrackpadMove(DragUpdateDetails details) {
    if (_isThisPhoneLocked) return;
    final dx = details.delta.dx * _trackpadSensitivity;
    final dy = details.delta.dy * _trackpadSensitivity;
    _sendJson({'type': 'move_relative', 'dx': dx, 'dy': dy});
  }

  void _handleLeftClick() {
    if (_isThisPhoneLocked) return;
    _sendJson({'type': 'click', 'button': 'left'});
    HapticFeedback.lightImpact();
  }

  void _handleRightClick() {
    if (_isThisPhoneLocked) return;
    _sendJson({'type': 'click', 'button': 'right'});
    HapticFeedback.mediumImpact();
    _showToast('Right clicked');
  }

  void _handleDoubleClick() {
    if (_isThisPhoneLocked) return;
    _sendJson({'type': 'double_click', 'button': 'left'});
    HapticFeedback.selectionClick();
  }

  void _handleScroll(int dy) {
    if (_isThisPhoneLocked) return;
    _sendJson({'type': 'scroll', 'dy': dy});
  }

  void _toggleDragLock() {
    if (_isThisPhoneLocked) return;
    setState(() {
      _isDragLocked = !_isDragLocked;
    });
    if (_isDragLocked) {
      _sendJson({'type': 'mouse_down', 'button': 'left'});
      _showToast('Drag locked (mouse held down)');
    } else {
      _sendJson({'type': 'mouse_up', 'button': 'left'});
      _showToast('Drag released');
    }
    HapticFeedback.mediumImpact();
  }

  void _sendTypingText() {
    if (_isThisPhoneLocked) return;
    final text = _textController.text;
    if (text.isEmpty) return;
    _sendJson({'type': 'type', 'text': text});
    _textController.clear();
  }

  void _sendKey(String key) {
    if (_isThisPhoneLocked) return;
    _sendJson({'type': 'key', 'key': key});
    if (key == 'win') {
      _showToast('Toggled Windows Start Menu');
    }
  }

  void _openWebUrl(String url) {
    if (_isThisPhoneLocked) return;
    _sendJson({'type': 'open_url', 'url': url});
    _showToast('Opening $url on PC');
  }

  void _launchApp(String app) {
    if (_isThisPhoneLocked || app.trim().isEmpty) return;
    _sendJson({'type': 'launch_app', 'app': app.trim()});
    _showToast('Launching $app on PC');
  }

  // --- Administrator Operations ---

  void _authenticateAdmin() {
    final password = _adminPasswordController.text.trim();
    if (password.isEmpty) {
      _showToast('Please enter admin password');
      return;
    }
    setState(() {
      _isAdminAuthenticating = true;
    });
    _sendJson({
      'type': 'admin_auth',
      'password': password,
    });
  }

  void _adminDisconnectPhone(int targetId, String name) {
    _sendJson({
      'type': 'admin_disconnect_client',
      'target_id': targetId,
    });
    _showToast('Disconnected $name');
  }

  void _adminUnlockPhone(int targetId, String name) {
    _sendJson({
      'type': 'admin_unlock_client',
      'target_id': targetId,
    });
    _showToast('Unlocked $name');
  }

  void _showLockDurationDialog(int targetId, String phoneName) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.lock, color: Color(0xFFF59E0B), size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Lock Access: $phoneName',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Choose lock duration. Even if the app is restarted, it stays locked until expired or unlocked.',
                style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
              ),
              const SizedBox(height: 14),

              _buildLockOption(ctx, targetId, 'Until I Unlock It (Indefinite)', 0, Icons.lock_clock),
              _buildLockOption(ctx, targetId, '1 Minute (Quick Test)', 60, Icons.timer_10),
              _buildLockOption(ctx, targetId, '5 Minutes', 300, Icons.timer),
              _buildLockOption(ctx, targetId, '15 Minutes', 900, Icons.timer),
              _buildLockOption(ctx, targetId, '30 Minutes', 1800, Icons.hourglass_bottom),
              _buildLockOption(ctx, targetId, '1 Hour', 3600, Icons.hourglass_full),

              const SizedBox(height: 10),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel', style: TextStyle(color: Color(0xFF94A3B8))),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLockOption(BuildContext ctx, int targetId, String label, int seconds, IconData icon) {
    return ListTile(
      dense: true,
      leading: Icon(icon, color: const Color(0xFF38BDF8), size: 20),
      title: Text(label, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
      onTap: () {
        Navigator.pop(ctx);
        _sendJson({
          'type': 'admin_lock_client',
          'target_id': targetId,
          'duration_seconds': seconds,
        });
        _showToast('Lock applied: $label');
      },
    );
  }

  // --- Screen Tap Handlers ---

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

    if (touchInsideX < 0 ||
        touchInsideX > renderedWidth ||
        touchInsideY < 0 ||
        touchInsideY > renderedHeight) {
      return null;
    }

    return Offset(
      (touchInsideX / renderedWidth).clamp(0.0, 1.0),
      (touchInsideY / renderedHeight).clamp(0.0, 1.0),
    );
  }

  void _handleScreenTap(Offset localPosition) {
    if (_isThisPhoneLocked) return;
    final coords = _getNormalizedCoordinates(localPosition);
    if (coords == null) return;
    _sendJson({'type': 'move', 'x': coords.dx, 'y': coords.dy});
    _sendJson({'type': 'click', 'button': 'left'});
  }

  void _handleScreenLongPress(Offset localPosition) {
    if (_isThisPhoneLocked) return;
    final coords = _getNormalizedCoordinates(localPosition);
    if (coords == null) return;
    _sendJson({'type': 'move', 'x': coords.dx, 'y': coords.dy});
    _sendJson({'type': 'click', 'button': 'right'});
    HapticFeedback.mediumImpact();
    _showToast('Right clicked');
  }

  void _handleScreenPanStart(DragStartDetails details) {
    if (_isThisPhoneLocked) return;
    final coords = _getNormalizedCoordinates(details.localPosition);
    if (coords != null) {
      _sendJson({'type': 'move', 'x': coords.dx, 'y': coords.dy});
      _sendJson({'type': 'mouse_down', 'button': 'left'});
    }
  }

  void _handleScreenPanUpdate(DragUpdateDetails details) {
    if (_isThisPhoneLocked) return;
    final coords = _getNormalizedCoordinates(details.localPosition);
    if (coords != null) {
      _sendJson({'type': 'move', 'x': coords.dx, 'y': coords.dy});
    }
  }

  void _handleScreenPanEnd(DragEndDetails details) {
    if (_isThisPhoneLocked) return;
    _sendJson({'type': 'mouse_up', 'button': 'left'});
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
              decoration: const InputDecoration(labelText: 'Shortcut Name (e.g. My Anime Site)'),
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

  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _buildHeader(),
                Expanded(child: _buildCurrentTabBody()),
                _buildBottomNavigationBar(),
              ],
            ),

            // Persistent Full-Screen Lock Overlay if this phone is locked
            if (_isThisPhoneLocked) _buildPhoneLockedOverlay(),
          ],
        ),
      ),
    );
  }

  /// Lock screen overlay when this device is locked by PC Admin
  Widget _buildPhoneLockedOverlay() {
    final minutes = _remainingLockSeconds ~/ 60;
    final seconds = _remainingLockSeconds % 60;
    final timeStr = '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';

    return Container(
      color: Colors.black.withOpacity(0.95),
      width: double.infinity,
      height: double.infinity,
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFF59E0B).withOpacity(0.2),
                border: Border.all(color: const Color(0xFFF59E0B), width: 3),
              ),
              child: const Icon(Icons.lock, size: 64, color: Color(0xFFF59E0B)),
            ),
            const SizedBox(height: 20),
            const Text(
              'DEVICE LOCKED BY ADMIN',
              style: TextStyle(
                color: Color(0xFFF59E0B),
                fontSize: 20,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Your access to the PC has been locked by the Administrator.\nClosing or restarting this app will not bypass this lock.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 13),
            ),
            const SizedBox(height: 20),

            if (_thisPhoneLockedUntil > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFF59E0B).withOpacity(0.5)),
                ),
                child: Column(
                  children: [
                    const Text('TIME REMAINING', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(
                      timeStr,
                      style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 26, fontWeight: FontWeight.bold, letterSpacing: 2),
                    ),
                  ],
                ),
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'Locked until unlocked by PC Administrator',
                  style: TextStyle(color: Color(0xFFF59E0B), fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
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

          if (_isConnected) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: Text(
                '${_renderedFps} FPS | ${_latencyMs}ms',
                style: const TextStyle(fontSize: 11, color: Color(0xFF38BDF8), fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCurrentTabBody() {
    switch (_currentTabIndex) {
      case 0:
        return _buildDedicatedTouchpadTab();
      case 1:
        return _buildScreenMirrorTab();
      case 2:
        return _buildShortcutsAndAppsTab();
      case 3:
        return _buildAdminTab();
      default:
        return _buildDedicatedTouchpadTab();
    }
  }

  /// TAB 0: Dedicated Laptop Touchpad UI
  Widget _buildDedicatedTouchpadTab() {
    return Container(
      color: const Color(0xFF0B1120),
      padding: const EdgeInsets.all(12.0),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.speed, size: 16, color: Color(0xFF94A3B8)),
              const SizedBox(width: 6),
              const Text('Cursor Speed:', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
              const SizedBox(width: 8),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  ),
                  child: Slider(
                    value: _trackpadSensitivity,
                    min: 0.8,
                    max: 2.8,
                    divisions: 10,
                    activeColor: const Color(0xFF38BDF8),
                    onChanged: (val) => setState(() => _trackpadSensitivity = val),
                  ),
                ),
              ),
              Text(
                '${_trackpadSensitivity.toStringAsFixed(1)}x',
                style: const TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 8),

          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: _handleTrackpadMove,
                    onTap: _handleLeftClick,
                    onDoubleTap: _handleDoubleClick,
                    onLongPress: _handleRightClick,
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: _isDragLocked ? const Color(0xFFF59E0B) : const Color(0xFF38BDF8).withOpacity(0.5),
                          width: 2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.4),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _isDragLocked ? Icons.lock : Icons.touch_app,
                                size: 54,
                                color: _isDragLocked
                                    ? const Color(0xFFF59E0B)
                                    : const Color(0xFF38BDF8).withOpacity(0.6),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _isDragLocked ? 'DRAG LOCK ACTIVE (MOUSE DOWN)' : 'LAPTOP TOUCHPAD',
                                style: TextStyle(
                                  color: _isDragLocked ? const Color(0xFFF59E0B) : const Color(0xFFF8FAFC),
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.2,
                                ),
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                'Slide finger to glide PC mouse\nTap to Left Click • Long press to Right Click',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                const SizedBox(width: 10),

                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (details) {
                    final int scrollStep = details.delta.dy > 0 ? 3 : -3;
                    _handleScroll(scrollStep);
                  },
                  child: Container(
                    width: 54,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF334155)),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.arrow_drop_up, color: Color(0xFF38BDF8), size: 28),
                        RotatedBox(
                          quarterTurns: 3,
                          child: Text(
                            'SCROLL',
                            style: TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 2,
                            ),
                          ),
                        ),
                        Icon(Icons.arrow_drop_down, color: Color(0xFF38BDF8), size: 28),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          SizedBox(
            height: 62,
            child: Row(
              children: [
                Expanded(
                  flex: 5,
                  child: ElevatedButton.icon(
                    onPressed: _isConnected ? _handleLeftClick : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 4,
                    ),
                    icon: const Icon(Icons.mouse, size: 22),
                    label: const Text(
                      'LEFT CLICK',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, letterSpacing: 1),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 58,
                  height: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isConnected ? _toggleDragLock : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isDragLocked ? const Color(0xFFF59E0B) : const Color(0xFF334155),
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Icon(_isDragLocked ? Icons.lock : Icons.lock_open, size: 22),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 5,
                  child: ElevatedButton.icon(
                    onPressed: _isConnected ? _handleRightClick : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1E293B),
                      foregroundColor: const Color(0xFF38BDF8),
                      side: const BorderSide(color: Color(0xFF0284C7), width: 1.5),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 4,
                    ),
                    icon: const Icon(Icons.mouse_outlined, size: 22),
                    label: const Text(
                      'RIGHT CLICK',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, letterSpacing: 1),
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),

          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildQuickPill('Win (Start)', 'win', Icons.window, isPrimary: true),
                const SizedBox(width: 6),
                _buildQuickPill('Show Desktop', 'desktop', Icons.desktop_windows),
                const SizedBox(width: 6),
                _buildQuickPill('Task Manager', 'taskmgr', Icons.analytics),
                const SizedBox(width: 6),
                _buildQuickPill('Alt+Tab', 'alt+tab', Icons.switch_access_shortcut),
                const SizedBox(width: 6),
                _buildQuickPill('Double Click', 'double_click', Icons.filter_2, isAction: true),
                const SizedBox(width: 6),
                _buildQuickPill('Esc', 'escape', Icons.close),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickPill(String label, String keyVal, IconData icon, {bool isPrimary = false, bool isAction = false}) {
    return ElevatedButton.icon(
      onPressed: _isConnected
          ? () {
              if (isAction && keyVal == 'double_click') {
                _handleDoubleClick();
              } else {
                _sendKey(keyVal);
              }
            }
          : null,
      style: ElevatedButton.styleFrom(
        backgroundColor: isPrimary ? const Color(0xFF0284C7) : const Color(0xFF1E293B),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      icon: Icon(icon, size: 14),
      label: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  /// TAB 1: Live Screen Mirroring View (NEVER jumps back to touchpad!)
  Widget _buildScreenMirrorTab() {
    return Container(
      key: _viewportKey,
      color: Colors.black,
      child: Stack(
        children: [
          _latestFrameBytes != null
              ? GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) => _handleScreenTap(details.localPosition),
                  onLongPressStart: (details) => _handleScreenLongPress(details.localPosition),
                  onPanStart: _handleScreenPanStart,
                  onPanUpdate: _handleScreenPanUpdate,
                  onPanEnd: _handleScreenPanEnd,
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
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 48,
                          height: 48,
                          child: CircularProgressIndicator(strokeWidth: 3, color: Color(0xFF38BDF8)),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          _isConnected
                              ? 'Streaming PC Desktop Screen...'
                              : _statusMessage,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Receiving video frames at 60 FPS from host server.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),

          // Floating Fit/Stretch Button
          if (_latestFrameBytes != null)
            Positioned(
              top: 10,
              right: 10,
              child: FloatingActionButton.small(
                backgroundColor: const Color(0xFF1E293B).withOpacity(0.85),
                foregroundColor: const Color(0xFF38BDF8),
                onPressed: () => setState(() => _isFitScreen = !_isFitScreen),
                tooltip: _isFitScreen ? 'Switch to Stretch Fill' : 'Switch to Aspect Ratio Fit',
                child: Icon(_isFitScreen ? Icons.aspect_ratio : Icons.fullscreen),
              ),
            ),
        ],
      ),
    );
  }

  /// TAB 2: Websites, Custom Shortcuts & PC App Launcher
  Widget _buildShortcutsAndAppsTab() {
    return Container(
      color: const Color(0xFF0B1120),
      padding: const EdgeInsets.all(14.0),
      child: DefaultTabController(
        length: 2,
        child: Column(
          children: [
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
                              onTap: () => _openWebUrl(item.url),
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
                              onPressed: () => _launchApp(_customAppController.text),
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
                            _buildAppLaunchChip('File Explorer', 'explorer', Icons.folder),
                            _buildAppLaunchChip('Desktop Folder', 'explorer shell:Desktop', Icons.desktop_windows),
                            _buildAppLaunchChip('Task Manager', 'taskmgr', Icons.analytics),
                            _buildAppLaunchChip('Chrome', 'chrome', Icons.public),
                            _buildAppLaunchChip('Command Prompt', 'cmd', Icons.terminal),
                            _buildAppLaunchChip('PowerShell', 'powershell', Icons.code),
                            _buildAppLaunchChip('Notepad', 'notepad', Icons.description),
                            _buildAppLaunchChip('Calculator', 'calc', Icons.calculate),
                            _buildAppLaunchChip('Settings', 'ms-settings:', Icons.settings),
                            _buildAppLaunchChip('Steam', 'steam', Icons.sports_esports),
                            _buildAppLaunchChip('Spotify', 'spotify', Icons.music_note),
                            _buildAppLaunchChip('Discord', 'discord', Icons.chat),
                            _buildAppLaunchChip('VS Code', 'code', Icons.integration_instructions),
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
    );
  }

  Widget _buildAppLaunchChip(String label, String cmd, IconData icon) {
    return ActionChip(
      backgroundColor: const Color(0xFF1E293B),
      side: const BorderSide(color: Color(0xFF334155)),
      avatar: Icon(icon, size: 16, color: const Color(0xFF38BDF8)),
      label: Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
      onPressed: () => _launchApp(cmd),
    );
  }

  /// TAB 3: Administrator Portal with Password Gate (Sagiv_2311)
  Widget _buildAdminTab() {
    if (!_isConnected) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.link_off, size: 48, color: Color(0xFF64748B)),
              SizedBox(height: 12),
              Text(
                'Connect to PC First',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              SizedBox(height: 6),
              Text(
                'Connect to your PC host server above before accessing the Administrator Portal.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    if (!_isAdminAuthenticated) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 420),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF0284C7).withOpacity(0.5), width: 1.5),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 16, offset: const Offset(0, 6)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0284C7).withOpacity(0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.admin_panel_settings, size: 42, color: Color(0xFF38BDF8)),
                ),
                const SizedBox(height: 16),
                const Text(
                  'ADMINISTRATOR ACCESS',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Enter password to manage connected phones, disconnect devices, and apply persistent remote locks.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                ),
                const SizedBox(height: 20),

                TextField(
                  controller: _adminPasswordController,
                  obscureText: _obscureAdminPassword,
                  autofocus: false,
                  style: const TextStyle(color: Colors.white),
                  onSubmitted: (_) => _authenticateAdmin(),
                  decoration: InputDecoration(
                    labelText: 'Admin Password',
                    prefixIcon: const Icon(Icons.vpn_key, color: Color(0xFF38BDF8), size: 18),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureAdminPassword ? Icons.visibility : Icons.visibility_off,
                        color: const Color(0xFF94A3B8),
                        size: 18,
                      ),
                      onPressed: () => setState(() => _obscureAdminPassword = !_obscureAdminPassword),
                    ),
                  ),
                ),
                const SizedBox(height: 18),

                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: ElevatedButton(
                    onPressed: _isAdminAuthenticating ? null : _authenticateAdmin,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: _isAdminAuthenticating
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Unlock Admin Console', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Authenticated Admin Dashboard
    return Container(
      color: const Color(0xFF0B1120),
      padding: const EdgeInsets.all(14.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFF22C55E).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.verified_user, color: Color(0xFF22C55E), size: 20),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('ADMIN CONSOLE ACTIVE', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                    Text(
                      '${_connectedPhones.length} Phone(s) connected to PC',
                      style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, color: Color(0xFF38BDF8), size: 20),
                tooltip: 'Refresh Clients List',
                onPressed: () => _sendJson({'type': 'admin_get_clients'}),
              ),
              OutlinedButton.icon(
                onPressed: () => setState(() => _isAdminAuthenticated = false),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFEF4444),
                  side: const BorderSide(color: Color(0xFFEF4444)),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.lock, size: 14),
                label: const Text('Lock', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(color: Color(0xFF334155), height: 1),
          const SizedBox(height: 12),

          Expanded(
            child: _connectedPhones.isEmpty
                ? const Center(
                    child: Text(
                      'No clients detected yet.\nTap refresh or wait for phone connections.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                    ),
                  )
                : ListView.separated(
                    itemCount: _connectedPhones.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final phone = _connectedPhones[index];
                      final isCurrentPhone = phone.id == _myClientId;

                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: phone.isLocked
                                ? const Color(0xFFF59E0B)
                                : (isCurrentPhone
                                    ? const Color(0xFF38BDF8)
                                    : const Color(0xFF334155)),
                            width: phone.isLocked ? 1.5 : 1,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.phone_android,
                                  size: 22,
                                  color: phone.isLocked ? const Color(0xFFF59E0B) : const Color(0xFF38BDF8),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(
                                            phone.deviceName,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 14,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          if (isCurrentPhone) ...[
                                            const SizedBox(width: 6),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF0284C7).withOpacity(0.3),
                                                borderRadius: BorderRadius.circular(4),
                                                border: Border.all(color: const Color(0xFF0284C7)),
                                              ),
                                              child: const Text('THIS DEVICE (ADMIN)', style: TextStyle(fontSize: 9, color: Color(0xFF38BDF8), fontWeight: FontWeight.bold)),
                                            ),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'IP: ${phone.ip}  •  Client #${phone.id}',
                                        style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                                      ),
                                    ],
                                  ),
                                ),

                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: phone.isLocked
                                        ? const Color(0xFFF59E0B).withOpacity(0.2)
                                        : const Color(0xFF22C55E).withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    phone.isLocked
                                        ? (phone.lockedUntil > 0 ? 'LOCKED (TIMED)' : 'LOCKED (INDEFINITE)')
                                        : 'ACTIVE',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: phone.isLocked ? const Color(0xFFF59E0B) : const Color(0xFF22C55E),
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 10),

                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: () => _adminDisconnectPhone(phone.id, phone.deviceName),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: const Color(0xFFEF4444),
                                    side: const BorderSide(color: Color(0xFFEF4444)),
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    minimumSize: Size.zero,
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  icon: const Icon(Icons.link_off, size: 14),
                                  label: const Text('Disconnect', style: TextStyle(fontSize: 12)),
                                ),

                                const SizedBox(width: 8),

                                if (phone.isLocked)
                                  ElevatedButton.icon(
                                    onPressed: () => _adminUnlockPhone(phone.id, phone.deviceName),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF16A34A),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                      minimumSize: Size.zero,
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                    icon: const Icon(Icons.lock_open, size: 14),
                                    label: const Text('Unlock Device', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                  )
                                else
                                  ElevatedButton.icon(
                                    onPressed: () => _showLockDurationDialog(phone.id, phone.deviceName),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFFD97706),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                      minimumSize: Size.zero,
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                    icon: const Icon(Icons.lock, size: 14),
                                    label: const Text('Lock Phone', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// Bottom Navigation Bar with 4 Tabs: Touchpad, Screen Mirror, Apps & Web, Admin
  Widget _buildBottomNavigationBar() {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1E293B),
        border: Border(top: BorderSide(color: Color(0xFF334155))),
      ),
      child: BottomNavigationBar(
        currentIndex: _currentTabIndex,
        onTap: (idx) => setState(() => _currentTabIndex = idx),
        backgroundColor: const Color(0xFF1E293B),
        selectedItemColor: const Color(0xFF38BDF8),
        unselectedItemColor: const Color(0xFF94A3B8),
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.mouse),
            label: 'Touchpad',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.screen_share),
            label: 'Screen Mirror',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.rocket_launch),
            label: 'Apps & Web',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.admin_panel_settings),
            label: 'Admin',
          ),
        ],
      ),
    );
  }
}
