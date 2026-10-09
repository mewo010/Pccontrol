import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
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
          secondary: Color(0xFFA855F7),
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
  Timer? _frameWatchdogTimer;
  int _frameWatchdogAttempts = 0;

  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isScanning = false;
  String _statusMessage = 'Tap "Auto-Detect PC" or enter IP';
  Uint8List? _latestFrameBytes;
  bool _isScreenBlackDetected = false;

  int _myClientId = 0;
  String _myPersistentDeviceId = '';
  int _latencyMs = 0;
  int _fpsCount = 0;
  int _renderedFps = 0;
  DateTime _lastFpsCheck = DateTime.now();

  double _remoteWidth = 1920;
  double _remoteHeight = 1080;
  String _hostPcName = '';

  // --- Multi-Network State (Wi-Fi vs Outside-of-WiFi Internet) ---
  String _savedLocalIp = '';
  String _savedPublicIp = '';
  bool _isOutsideWifiMode = false;
  bool _autoSwitchToInternet = true;
  bool _isAutoReconnecting = false;
  int _autoReconnectAttempt = 0;
  Timer? _reconnectRetryTimer;

  // --- Live Stream Telemetry & Debug Diagnostics ---
  String _hostCaptureEngine = 'Detecting...';
  int _hostFrameCount = 0;
  int _hostLastBytes = 0;
  int _hostEncodeMs = 0;
  String _hostStatus = 'Connecting';
  String? _hostLastError;
  String _hostCaptureMode = 'gdi';
  int _hostFramesSent = 0;
  String? _hostPublicIp;

  int _totalBinaryFramesReceived = 0;
  int _totalJsonMessagesReceived = 0;
  int _totalBytesReceived = 0;
  int _lastFrameSizeBytes = 0;
  DateTime? _lastFrameReceivedTime;
  final List<String> _debugLogs = [];
  bool _showDebugHud = false;

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
  File get _savedProfilesFile => File('${Directory.systemTemp.path}/remote_pc_saved_profiles.json');
  File get _savedShortcutsFile => File('${Directory.systemTemp.path}/remote_pc_custom_shortcuts.json');

  // Default built-in shortcuts (not persisted, always present)
  static const List<WebShortcutItem> _defaultWebShortcuts = [
    WebShortcutItem(name: 'YouTube', url: 'https://youtube.com', icon: Icons.play_circle_fill),
    WebShortcutItem(name: 'Google', url: 'https://google.com', icon: Icons.search),
    WebShortcutItem(name: 'ChatGPT', url: 'https://chatgpt.com', icon: Icons.smart_toy),
    WebShortcutItem(name: 'Netflix', url: 'https://netflix.com', icon: Icons.movie),
    WebShortcutItem(name: 'Twitch', url: 'https://twitch.tv', icon: Icons.live_tv),
    WebShortcutItem(name: 'Reddit', url: 'https://reddit.com', icon: Icons.forum),
    WebShortcutItem(name: 'GitHub', url: 'https://github.com', icon: Icons.code),
  ];

  // Custom Websites & Shortcuts (defaults + user-added from disk)
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
    _addLog('App initialized. Device ID and Saved Network Profiles ready.');
  }

  void _addLog(String msg) {
    final now = DateTime.now();
    final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    if (_debugLogs.length >= 35) {
      _debugLogs.removeAt(0);
    }
    _debugLogs.add('[$timeStr] $msg');
    if (mounted) {
      setState(() {});
    }
  }

  /// Initialize persistent device ID, saved IP profiles, and persistent lock
  void _initPersistentState() {
    try {
      if (_localDeviceIdFile.existsSync()) {
        _myPersistentDeviceId = _localDeviceIdFile.readAsStringSync().trim();
      }
      if (_myPersistentDeviceId.isEmpty) {
        _myPersistentDeviceId = 'phone_${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecond % 10000}';
        _localDeviceIdFile.writeAsStringSync(_myPersistentDeviceId);
      }

      // Load saved profiles (Local IP and Outside-of-WiFi Public IP)
      if (_savedProfilesFile.existsSync()) {
        final content = _savedProfilesFile.readAsStringSync();
        final dynamic data = jsonDecode(content);
        if (data is Map<String, dynamic>) {
          _savedLocalIp = data['local_ip']?.toString() ?? '';
          _savedPublicIp = data['public_ip']?.toString() ?? '';
          _hostPcName = data['host_name']?.toString() ?? _hostPcName;
          if (_savedLocalIp.isNotEmpty && !_isOutsideWifiMode) {
            _ipController.text = _savedLocalIp;
          }
        }
      }

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
            _localLockFile.deleteSync();
          }
        }
      }

      // Load saved custom shortcuts from disk
      _loadSavedWebShortcuts();
    } catch (_) {}
  }

  void _loadSavedWebShortcuts() {
    try {
      if (_savedShortcutsFile.existsSync()) {
        final content = _savedShortcutsFile.readAsStringSync();
        final dynamic data = jsonDecode(content);
        if (data is List) {
          for (var item in data) {
            if (item is Map<String, dynamic>) {
              final name = item['name']?.toString() ?? '';
              final url = item['url']?.toString() ?? '';
              if (name.isNotEmpty && url.isNotEmpty) {
                if (!_webShortcuts.any((s) => s.url == url || s.name == name)) {
                  _webShortcuts.add(WebShortcutItem(name: name, url: url, icon: Icons.bookmark));
                }
              }
            }
          }
        }
      }
    } catch (_) {}
  }

  void _saveWebShortcuts() {
    try {
      final customItems = _webShortcuts
          .where((s) => !_defaultWebShortcuts.any((d) => d.url == s.url && d.name == s.name))
          .map((s) => {'name': s.name, 'url': s.url})
          .toList();
      _savedShortcutsFile.writeAsStringSync(jsonEncode(customItems));
    } catch (_) {}
  }

  void _persistSavedProfile(String hostName, String localIp, String publicIp) {
    try {
      _savedProfilesFile.writeAsStringSync(jsonEncode({
        'host_name': hostName,
        'local_ip': localIp,
        'public_ip': publicIp,
        'last_connected': DateTime.now().millisecondsSinceEpoch,
      }));
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
            _showToast('Device lock has expired. Reconnected.');
          }
        });
      });
    }
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    _reconnectRetryTimer?.cancel();
    _lockCountdownTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    _ipController.dispose();
    _textController.dispose();
    _customAppController.dispose();
    _adminPasswordController.dispose();
    _textFocusNode.dispose();
    super.dispose();
  }

  // --- UDP Auto-Discovery Beacon on Wi-Fi ---

  Future<void> _autoDiscoverPc() async {
    if (_isScanning) return;

    setState(() {
      _isScanning = true;
      _statusMessage = 'Searching for PC on local Wi-Fi...';
    });
    _addLog('Broadcasting UDP search on port 8766...');

    RawDatagramSocket? socket;
    Timer? timeoutTimer;

    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;

      socket.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final dg = socket?.receive();
          if (dg != null) {
            final message = utf8.decode(dg.data).trim();
            _addLog('Discovery reply received: $message');

            if (message.startsWith('REMOTE_PC_HOST:')) {
              final parts = message.split(':');
              if (parts.length >= 3) {
                final hostName = parts[1];
                final hostIp = parts[2];
                final hostPort = parts.length >= 4 ? parts[3] : '8765';
                final publicIpFromBeacon = parts.length >= 5 ? parts[4] : '';
                final fullLocalAddress = '$hostIp:$hostPort';

                timeoutTimer?.cancel();
                socket?.close();

                if (mounted) {
                  setState(() {
                    _ipController.text = fullLocalAddress;
                    _savedLocalIp = fullLocalAddress;
                    if (publicIpFromBeacon.isNotEmpty && publicIpFromBeacon != 'Detecting / Router IP') {
                      _savedPublicIp = '$publicIpFromBeacon:$hostPort';
                    }
                    _hostPcName = hostName;
                    _isScanning = false;
                    _isOutsideWifiMode = false;
                    _statusMessage = 'Found $hostName ($fullLocalAddress)! Connecting...';
                  });
                  _persistSavedProfile(hostName, fullLocalAddress, _savedPublicIp);
                  _addLog('Discovered host: $hostName (Local: $fullLocalAddress, Public: $_savedPublicIp)');
                  _showToast('Found $hostName ($fullLocalAddress)');
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
            _statusMessage = 'No PC found automatically. Enter IP manually or switch to Outside Wi-Fi mode.';
          });
          _addLog('Auto-discovery timed out. Enter IP manually.');
          _showToast('No PC found on local Wi-Fi. Try Outside Wi-Fi mode or enter IP.');
        }
      });
    } catch (e) {
      socket?.close();
      if (mounted) {
        setState(() {
          _isScanning = false;
          _statusMessage = 'Enter PC IP from host window and tap Connect.';
        });
        _addLog('Auto-discovery error: $e');
      }
    }
  }

  void _switchNetworkMode(bool outsideWifi) {
    setState(() {
      _isOutsideWifiMode = outsideWifi;
      if (outsideWifi) {
        if (_savedPublicIp.isNotEmpty) {
          _ipController.text = _savedPublicIp;
          _showToast('Switched to Outside Wi-Fi (Mobile Data: $_savedPublicIp)');
        } else {
          _showToast('No public IP saved yet. Connect on Wi-Fi once or enter Public IP.');
        }
      } else {
        if (_savedLocalIp.isNotEmpty) {
          _ipController.text = _savedLocalIp;
          _showToast('Switched to Home Wi-Fi mode');
        }
      }
    });
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
    _addLog('Opening WebSocket connection to $wsUrl...');

    try {
      final uri = Uri.parse(wsUrl);
      _channel = WebSocketChannel.connect(uri);

      _subscription = _channel!.stream.listen(
        (data) {
          if (!_isConnected) {
            setState(() {
              _isConnected = true;
              _isConnecting = false;
              _isAutoReconnecting = false;
              _autoReconnectAttempt = 0;
              _reconnectRetryTimer?.cancel();
              _statusMessage = 'Connected: ${_isOutsideWifiMode ? "Outside Wi-Fi / 4G" : "Local Wi-Fi"} (${_hostPcName.isNotEmpty ? _hostPcName : wsUrl})';
            });
            _addLog('WebSocket connected successfully.');
            _startPingLoop();
            _startFrameWatchdog();

            // Send handshake with persistent device ID
            _sendJson({
              'type': 'client_hello',
              'device_name': 'Android Phone',
              'device_id': _myPersistentDeviceId,
            });

            // Immediately request fresh screen frame upon connection
            _sendJson({'type': 'request_frame'});
          }

          if (data is Uint8List) {
            _totalBinaryFramesReceived++;
            _totalBytesReceived += data.length;
            _onFrameReceived(data);
          } else if (data is List<int>) {
            final bytes = Uint8List.fromList(data);
            _totalBinaryFramesReceived++;
            _totalBytesReceived += bytes.length;
            _onFrameReceived(bytes);
          } else if (data is ByteBuffer) {
            final bytes = data.asUint8List();
            _totalBinaryFramesReceived++;
            _totalBytesReceived += bytes.length;
            _onFrameReceived(bytes);
          } else if (data is String) {
            _totalJsonMessagesReceived++;
            _totalBytesReceived += data.length;
            _onTextMessageReceived(data);
          } else {
            _addLog('Unknown packet type: ${data.runtimeType}');
          }
        },
        onError: (error) {
          _addLog('WebSocket error: $error');
          _handleConnectionDrop('Connection error: $error');
        },
        onDone: () {
          _addLog('WebSocket closed by host server.');
          _handleConnectionDrop('Disconnected by host');
        },
      );
    } catch (e) {
      _addLog('Connect exception: $e');
      _handleConnectionDrop('Failed to connect: $e');
    }
  }

  void _handleConnectionDrop(String reason) {
    final wasConnected = _isConnected;
    _disconnect();

    final canReconnect = (wasConnected || _isAutoReconnecting) && _autoReconnectAttempt < 10;

    if (canReconnect) {
      _autoReconnectAttempt++;

      if (!_isOutsideWifiMode && _savedPublicIp.isNotEmpty) {
        _isOutsideWifiMode = true;
        _ipController.text = _savedPublicIp;
        _addLog('Auto-switching network mode to Outside Wi-Fi WAN IP: $_savedPublicIp');
      }

      final int delayMs = (1000 * math.pow(1.3, _autoReconnectAttempt - 1)).toInt().clamp(1000, 8000);

      setState(() {
        _isAutoReconnecting = true;
        _statusMessage = 'Network drop. Auto-reconnecting over Internet (Attempt $_autoReconnectAttempt/10 in ${delayMs ~/ 1000}s)...';
      });

      _addLog('Scheduling auto-reconnect attempt $_autoReconnectAttempt/10 in ${delayMs}ms to ${_ipController.text}...');
      _showToast('Auto-reconnecting (Attempt $_autoReconnectAttempt/10)...');

      _triggerAutoReconnectLoop(delayMs);
    } else {
      setState(() {
        _isAutoReconnecting = false;
        _autoReconnectAttempt = 0;
        _statusMessage = reason;
      });
      _showToast('Disconnected: $reason');
    }
  }

  void _triggerAutoReconnectLoop(int delayMs) {
    _reconnectRetryTimer?.cancel();
    _reconnectRetryTimer = Timer(Duration(milliseconds: delayMs), () {
      if (mounted && !_isConnected && !_isConnecting && _isAutoReconnecting) {
        _connect();
      }
    });
  }

  void _disconnect() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _stopFrameWatchdog();
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

  void _startFrameWatchdog() {
    _frameWatchdogTimer?.cancel();
    _frameWatchdogAttempts = 0;
    _frameWatchdogTimer = Timer.periodic(const Duration(milliseconds: 1500), (timer) {
      if (!_isConnected || _channel == null) {
        timer.cancel();
        return;
      }

      final now = DateTime.now();
      final noFrameYet = _latestFrameBytes == null;
      final frameStalled = _lastFrameReceivedTime != null &&
          now.difference(_lastFrameReceivedTime!).inMilliseconds > 2000;

      if (noFrameYet || frameStalled) {
        _frameWatchdogAttempts++;
        _addLog('Frame watchdog: re-requesting screen frame (attempt $_frameWatchdogAttempts)');
        _sendJson({'type': 'request_frame'});

        if (noFrameYet && _frameWatchdogAttempts == 2) {
          _sendJson({'type': 'set_capture_mode', 'mode': 'gdi'});
          _addLog('Frame watchdog: forcing GDI desktop capture mode');
        }
      }
    });
  }

  void _stopFrameWatchdog() {
    _frameWatchdogTimer?.cancel();
    _frameWatchdogTimer = null;
    _frameWatchdogAttempts = 0;
  }

  void _onFrameReceived(Uint8List frameBytes) {
    if (_isThisPhoneLocked) return;

    _fpsCount++;
    _lastFrameReceivedTime = DateTime.now();
    _lastFrameSizeBytes = frameBytes.length;
    _frameWatchdogAttempts = 0;

    // Check if frame bytes represent an all-black image
    bool isBlack = false;
    if (frameBytes.length > 500) {
      int zeroCount = 0;
      int testPoints = 50;
      int step = (frameBytes.length / testPoints).floor();
      for (int i = 100; i < frameBytes.length - 100; i += step) {
        if (frameBytes[i] == 0) zeroCount++;
      }
      if (zeroCount > 45) {
        isBlack = true;
      }
    }

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
      _isScreenBlackDetected = isBlack;
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
            final pubIp = decoded['public_ip']?.toString();
            if (pubIp != null && pubIp.isNotEmpty && pubIp != 'Detecting / Router IP') {
              _hostPublicIp = pubIp;
              _savedPublicIp = pubIp.contains(':') ? pubIp : '$pubIp:8765';
            }
            if (!_isOutsideWifiMode) {
              _savedLocalIp = _ipController.text;
            }
          });
          _persistSavedProfile(_hostPcName, _savedLocalIp, _savedPublicIp);
          _addLog('Host Info: $_hostPcName, ${_remoteWidth.toInt()}x${_remoteHeight.toInt()}, Client #$_myClientId (Public WAN: $_savedPublicIp)');
        } else if (type == 'capture_debug') {
          setState(() {
            _hostCaptureEngine = decoded['engine']?.toString() ?? _hostCaptureEngine;
            _hostFrameCount = (decoded['frame_count'] as num?)?.toInt() ?? _hostFrameCount;
            _hostLastBytes = (decoded['last_bytes'] as num?)?.toInt() ?? _hostLastBytes;
            _hostEncodeMs = (decoded['last_encode_ms'] as num?)?.toInt() ?? _hostEncodeMs;
            _hostStatus = decoded['status']?.toString() ?? _hostStatus;
            _hostLastError = decoded['last_error']?.toString();
            _hostCaptureMode = decoded['mode']?.toString() ?? _hostCaptureMode;
            _hostFramesSent = (decoded['frames_sent_to_client'] as num?)?.toInt() ?? _hostFramesSent;
            if (decoded['is_screen_black'] == true) {
              _isScreenBlackDetected = true;
            }
            final pubIp = decoded['public_ip']?.toString();
            if (pubIp != null && pubIp.isNotEmpty && pubIp != 'Detecting / Router IP') {
              _hostPublicIp = pubIp;
              _savedPublicIp = pubIp.contains(':') ? pubIp : '$pubIp:8765';
            }
            if (decoded['width'] != null && decoded['height'] != null) {
              _remoteWidth = (decoded['width'] as num).toDouble();
              _remoteHeight = (decoded['height'] as num).toDouble();
            }
          });
        } else if (type == 'admin_auth_result') {
          final success = decoded['success'] == true;
          final msg = decoded['message']?.toString() ?? '';
          setState(() {
            _isAdminAuthenticating = false;
            _isAdminAuthenticated = success;
          });
          _addLog('Admin Auth: $msg');
          _showToast(msg);
        } else if (type == 'admin_clients_list') {
          final listRaw = decoded['clients'] as List<dynamic>? ?? [];
          setState(() {
            _connectedPhones = listRaw
                .map((e) => ConnectedPhoneClient.fromJson(e as Map<String, dynamic>))
                .toList();
          });
          _addLog('Updated admin clients list (${_connectedPhones.length} connected)');
        } else if (type == 'lock_status') {
          final locked = decoded['is_locked'] == true;
          final lockedUntil = (decoded['locked_until'] as num?)?.toInt() ?? 0;
          final remSec = (decoded['remaining_seconds'] as num?)?.toInt() ?? 0;

          setState(() {
            _isThisPhoneLocked = locked;
            _thisPhoneLockedUntil = lockedUntil;
            _remainingLockSeconds = remSec;
          });

          _persistLockState(locked, lockedUntil);
          _addLog('Lock Status: locked=$locked, until=$lockedUntil');

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

  // --- Interactive Diagnostic & Auto-Repair Controls ---

  void _requestImmediateFrame() {
    _sendJson({'type': 'request_frame'});
    _addLog('Sent RequestFrame command to host.');
    _showToast('Requesting fresh screen frame...');
  }

  void _requestTestPattern() {
    _sendJson({'type': 'request_test_frame'});
    _addLog('Requested diagnostic Test Frame pattern.');
    _showToast('Showing color test pattern on phone...');
  }

  void _forceGdiCapture() {
    _sendJson({'type': 'set_capture_mode', 'mode': 'gdi'});
    _sendJson({'type': 'request_frame'});
    _addLog('Auto-Fix: Forced Windows GDI BitBlt desktop capture.');
    _showToast('Forced Windows GDI Direct desktop capture!');
  }

  void _forceDxgiCapture() {
    _sendJson({'type': 'set_capture_mode', 'mode': 'xcap'});
    _sendJson({'type': 'request_frame'});
    _addLog('Switched capture engine to XCap Hardware DXGI.');
    _showToast('Switched to XCap DXGI Hardware capture.');
  }

  void _cycleDisplay() {
    _sendJson({'type': 'cycle_display'});
    _sendJson({'type': 'request_frame'});
    _addLog('Toggled monitor between Primary and Virtual all-displays.');
    _showToast('Switched monitor display target!');
  }

  void _wakeDisplay() {
    _sendJson({'type': 'wake_display'});
    _sendJson({'type': 'request_frame'});
    _addLog('Sent display wake signal to PC.');
    _showToast('Sent wake signal to PC display!');
  }

  void _showDiagnosticsLogSheet() {
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Real-Time Event Logs',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.copy, size: 16, color: Color(0xFF38BDF8)),
                    label: const Text('Copy Logs', style: TextStyle(color: Color(0xFF38BDF8))),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _debugLogs.join('\n')));
                      _showToast('Copied logs to clipboard');
                    },
                  ),
                ],
              ),
              const Divider(color: Color(0xFF334155)),
              Expanded(
                child: ListView.builder(
                  itemCount: _debugLogs.length,
                  itemBuilder: (context, index) {
                    final log = _debugLogs[_debugLogs.length - 1 - index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2.0),
                      child: Text(
                        log,
                        style: const TextStyle(
                          color: Color(0xFF94A3B8),
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showOutsideWifiGuideDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: Row(
          children: const [
            Icon(Icons.public, color: Color(0xFFA855F7), size: 22),
            SizedBox(width: 8),
            Text('Connect Outside of Wi-Fi', style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'How to connect outside your house:',
              style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF38BDF8), fontSize: 13),
            ),
            const SizedBox(height: 6),
            const Text(
              '1. Connect once while on your Home Wi-Fi.\n'
              '   Your phone automatically learns your PC\'s Public WAN IP.\n\n'
              '2. Leave home or turn off Wi-Fi (switch to 4G/5G).\n'
              '   The app will automatically failover to your Mobile Data link!\n\n'
              '3. Or select "Outside Wi-Fi" tab and tap Connect.\n'
              '   Your router\'s Port 8765 TCP is auto-forwarded via UPnP by the PC host.',
              style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12),
            ),
            if (_savedPublicIp.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFFA855F7).withOpacity(0.5)),
                ),
                child: Text(
                  'Saved Public WAN IP: $_savedPublicIp',
                  style: const TextStyle(color: Color(0xFFA855F7), fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got it', style: TextStyle(color: Color(0xFF38BDF8))),
          ),
        ],
      ),
    );
  }

  void _showToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        backgroundColor: const Color(0xFF1E293B),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // --- Input and Mouse Event Handlers ---

  void _handleTrackpadMove(DragUpdateDetails details) {
    if (_isThisPhoneLocked) return;
    final double dx = details.delta.dx * _trackpadSensitivity;
    final double dy = details.delta.dy * _trackpadSensitivity;
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
  }

  void _handleDoubleClick() {
    if (_isThisPhoneLocked) return;
    _sendJson({'type': 'double_click', 'button': 'left'});
    HapticFeedback.heavyImpact();
  }

  void _toggleDragLock() {
    if (_isThisPhoneLocked) return;
    setState(() {
      _isDragLocked = !_isDragLocked;
    });
    if (_isDragLocked) {
      _sendJson({'type': 'mouse_down', 'button': 'left'});
      HapticFeedback.heavyImpact();
      _showToast('Drag Lock Active (Mouse Down)');
    } else {
      _sendJson({'type': 'mouse_up', 'button': 'left'});
      HapticFeedback.lightImpact();
      _showToast('Drag Lock Released');
    }
  }

  void _handleScroll(int dy) {
    if (_isThisPhoneLocked) return;
    _sendJson({'type': 'scroll', 'dy': dy});
    HapticFeedback.selectionClick();
  }

  void _sendKey(String key) {
    if (_isThisPhoneLocked) return;
    _sendJson({'type': 'key', 'key': key});
    HapticFeedback.selectionClick();
  }

  void _sendText(String text) {
    if (_isThisPhoneLocked || text.isEmpty) return;
    _sendJson({'type': 'type', 'text': text});
    _textController.clear();
  }

  void _openUrl(String url) {
    if (_isThisPhoneLocked) return;
    _sendJson({'type': 'open_url', 'url': url});
    _showToast('Opening $url on PC...');
  }

  void _launchApp(String app) {
    if (_isThisPhoneLocked) return;
    _sendJson({'type': 'launch_app', 'app': app});
    _showToast('Launching $app on PC...');
  }

  // --- Admin Dialogs ---

  void _showAdminLoginDialog() {
    _adminPasswordController.clear();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: Row(
          children: const [
            Icon(Icons.admin_panel_settings, color: Color(0xFF38BDF8), size: 24),
            SizedBox(width: 8),
            Text('Admin Portal Login', style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter administrator password to manage connected phones, disconnect devices, and apply locks.',
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _adminPasswordController,
              obscureText: _obscureAdminPassword,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Password',
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureAdminPassword ? Icons.visibility_off : Icons.visibility,
                    color: const Color(0xFF94A3B8),
                  ),
                  onPressed: () {
                    setState(() {
                      _obscureAdminPassword = !_obscureAdminPassword;
                    });
                  },
                ),
              ),
              onSubmitted: (_) {
                Navigator.pop(ctx);
                _submitAdminAuth();
              },
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
              Navigator.pop(ctx);
              _submitAdminAuth();
            },
            child: const Text('Unlock Admin'),
          ),
        ],
      ),
    );
  }

  void _submitAdminAuth() {
    final pass = _adminPasswordController.text.trim();
    if (pass.isEmpty) return;

    setState(() {
      _isAdminAuthenticating = true;
    });
    _sendJson({'type': 'admin_auth', 'password': pass});
  }

  void _showLockDurationDialog(int targetId, String phoneName) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
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
                _saveWebShortcuts();
                Navigator.pop(ctx);
                _showToast('Added shortcut: $name');
              }
            },
            child: const Text('Save Shortcut'),
          ),
        ],
      ),
    );
  }

  // --- Root Widget Tree ---

  @override
  Widget build(BuildContext context) {
    if (_isThisPhoneLocked) {
      return _buildLockedScreen();
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        title: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isConnected ? const Color(0xFF22C55E) : const Color(0xFFEF4444),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _hostPcName.isNotEmpty ? _hostPcName : 'Remote PC Control',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _statusMessage,
                    style: TextStyle(
                      fontSize: 10,
                      color: _isConnected ? const Color(0xFF38BDF8) : const Color(0xFF94A3B8),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (!_isOutsideWifiMode)
            TextButton.icon(
              onPressed: _isScanning ? null : _autoDiscoverPc,
              icon: _isScanning
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF38BDF8)),
                    )
                  : const Icon(Icons.wifi_find, size: 18, color: Color(0xFF38BDF8)),
              label: Text(
                _isScanning ? 'Searching...' : 'Auto-Detect',
                style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 13, fontWeight: FontWeight.bold),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.public, color: Color(0xFFA855F7)),
            tooltip: 'Outside Wi-Fi Guide',
            onPressed: _showOutsideWifiGuideDialog,
          ),
          IconButton(
            icon: Icon(_isConnected ? Icons.link_off : Icons.link, color: _isConnected ? const Color(0xFFEF4444) : const Color(0xFF38BDF8)),
            tooltip: _isConnected ? 'Disconnect' : 'Connect',
            onPressed: () {
              if (_isConnected) {
                _disconnect();
              } else {
                _connect();
              }
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildTopConnectionBar(),
            Expanded(
              child: _buildCurrentTabBody(),
            ),
          ],
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentTabIndex,
        onTap: (index) {
          setState(() {
            _currentTabIndex = index;
          });
          // When switching to Screen Mirror tab, immediately request a frame so it renders instantly
          if (index == 1 && _isConnected) {
            _sendJson({'type': 'request_frame'});
          }
        },
        backgroundColor: const Color(0xFF0F172A),
        selectedItemColor: const Color(0xFF38BDF8),
        unselectedItemColor: const Color(0xFF64748B),
        type: BottomNavigationBarType.fixed,
        selectedFontSize: 12,
        unselectedFontSize: 11,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.touch_app),
            label: 'Touchpad',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.screen_share),
            label: 'See Screen',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.apps),
            label: 'Apps & Web',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_remote),
            label: 'Media & Power',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.admin_panel_settings),
            label: 'Admin',
          ),
        ],
      ),
    );
  }

  Widget _buildTopConnectionBar() {
    return Container(
      color: const Color(0xFF1E293B),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 38,
                  child: TextField(
                    controller: _ipController,
                    style: const TextStyle(fontSize: 13, color: Colors.white),
                    decoration: InputDecoration(
                      hintText: _isOutsideWifiMode ? 'Enter Public IP (e.g. 84.110.x.x:8765)' : 'Enter PC IP (e.g. 192.168.1.5:8765)',
                      prefixIcon: Icon(_isOutsideWifiMode ? Icons.public : Icons.wifi, size: 16, color: _isOutsideWifiMode ? const Color(0xFFA855F7) : const Color(0xFF38BDF8)),
                      contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 8),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _isConnecting ? null : (_isConnected ? _disconnect : _connect),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isConnected ? const Color(0xFF334155) : (_isOutsideWifiMode ? const Color(0xFF7E22CE) : const Color(0xFF0284C7)),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                child: Text(
                  _isConnected ? 'Disconnect' : (_isConnecting ? 'Connecting...' : 'Connect'),
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
              if (_isConnected) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
          const SizedBox(height: 6),
          // Network Mode Switcher: Wi-Fi vs Outside Wi-Fi (Mobile Data)
          Row(
            children: [
              InkWell(
                onTap: () => _switchNetworkMode(false),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: !_isOutsideWifiMode ? const Color(0xFF0284C7).withOpacity(0.3) : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: !_isOutsideWifiMode ? const Color(0xFF38BDF8) : const Color(0xFF334155)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.wifi, size: 12, color: Color(0xFF38BDF8)),
                      SizedBox(width: 4),
                      Text('Home Wi-Fi', style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              InkWell(
                onTap: () => _switchNetworkMode(true),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _isOutsideWifiMode ? const Color(0xFF9333EA).withOpacity(0.3) : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: _isOutsideWifiMode ? const Color(0xFFA855F7) : const Color(0xFF334155)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.public, size: 12, color: Color(0xFFA855F7)),
                      const SizedBox(width: 4),
                      Text(
                        _savedPublicIp.isNotEmpty ? 'Outside Wi-Fi (Saved)' : 'Outside Wi-Fi',
                        style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              if (_isAutoReconnecting)
                Row(
                  children: [
                    const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFA855F7)),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Reconnecting (4G)...',
                      style: const TextStyle(color: Color(0xFFA855F7), fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                  ],
                )
              else if (_savedPublicIp.isNotEmpty)
                Text(
                  'Auto-reconnects on 4G/5G',
                  style: TextStyle(color: const Color(0xFF94A3B8).withOpacity(0.8), fontSize: 10),
                ),
            ],
          ),
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
        return _buildMediaAndPowerTab();
      case 4:
        return _buildAdminTab();
      default:
        return _buildDedicatedTouchpadTab();
    }
  }

  /// TAB 3: Media Remote & PC Power Control
  Widget _buildMediaAndPowerTab() {
    return Container(
      color: const Color(0xFF0F172A),
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          const Text(
            'MEDIA REMOTE & VOLUME CONTROL',
            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1),
          ),
          const SizedBox(height: 12),

          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF38BDF8).withOpacity(0.4)),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton.filledTonal(
                      iconSize: 32,
                      icon: const Icon(Icons.skip_previous, color: Color(0xFF38BDF8)),
                      onPressed: _isConnected ? () => _sendKey('media_prev') : null,
                    ),
                    IconButton.filled(
                      iconSize: 44,
                      style: IconButton.styleFrom(backgroundColor: const Color(0xFF0284C7)),
                      icon: const Icon(Icons.play_arrow, color: Colors.white),
                      onPressed: _isConnected ? () => _sendKey('media_play_pause') : null,
                    ),
                    IconButton.filledTonal(
                      iconSize: 32,
                      icon: const Icon(Icons.skip_next, color: Color(0xFF38BDF8)),
                      onPressed: _isConnected ? () => _sendKey('media_next') : null,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(color: Color(0xFF334155)),
                const SizedBox(height: 12),

                Row(
                  children: [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF334155),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                      onPressed: _isConnected ? () => _sendKey('volume_mute') : null,
                      icon: const Icon(Icons.volume_off, size: 18, color: Color(0xFFF59E0B)),
                      label: const Text('Mute'),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0284C7),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                        onPressed: _isConnected ? () => _sendKey('volume_down') : null,
                        icon: const Icon(Icons.volume_down, size: 18),
                        label: const Text('Vol -'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0284C7),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                        onPressed: _isConnected ? () => _sendKey('volume_up') : null,
                        icon: const Icon(Icons.volume_up, size: 18),
                        label: const Text('Vol +'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),
          const Text(
            'QUICK SHORTCUTS & WINDOW ACTIONS',
            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1),
          ),
          const SizedBox(height: 10),

          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildQuickPill('Copy (Ctrl+C)', 'ctrl+c', Icons.copy),
              _buildQuickPill('Paste (Ctrl+V)', 'ctrl+v', Icons.paste),
              _buildQuickPill('Select All (Ctrl+A)', 'ctrl+a', Icons.select_all),
              _buildQuickPill('Undo (Ctrl+Z)', 'ctrl+z', Icons.undo),
              _buildQuickPill('Close Window (Alt+F4)', 'alt+f4', Icons.close, isPrimary: true),
            ],
          ),

          const SizedBox(height: 24),
          const Text(
            'SYSTEM POWER & WORKSTATION CONTROL',
            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1),
          ),
          const SizedBox(height: 10),

          GridView.count(
            crossAxisCount: 2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 2.2,
            children: [
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1E293B),
                  foregroundColor: const Color(0xFF38BDF8),
                  side: const BorderSide(color: Color(0xFF38BDF8)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _isConnected ? () => _sendKey('lock_pc') : null,
                icon: const Icon(Icons.lock, size: 20),
                label: const Text('Lock PC (Win+L)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1E293B),
                  foregroundColor: const Color(0xFFA855F7),
                  side: const BorderSide(color: Color(0xFFA855F7)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _isConnected ? () => _sendKey('sleep_pc') : null,
                icon: const Icon(Icons.bedtime, size: 20),
                label: const Text('Sleep PC', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1E293B),
                  foregroundColor: const Color(0xFFF59E0B),
                  side: const BorderSide(color: Color(0xFFF59E0B)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _isConnected ? () => _confirmPowerAction('Restart PC', 'restart_pc') : null,
                icon: const Icon(Icons.restart_alt, size: 20),
                label: const Text('Restart PC', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1E293B),
                  foregroundColor: const Color(0xFFEF4444),
                  side: const BorderSide(color: Color(0xFFEF4444)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _isConnected ? () => _confirmPowerAction('Shutdown PC', 'shutdown_pc') : null,
                icon: const Icon(Icons.power_settings_new, size: 20),
                label: const Text('Shut Down PC', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _confirmPowerAction(String title, String keyCmd) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: Text('Confirm $title', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
        content: Text('Are you sure you want to $title on your Remote PC?', style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF94A3B8))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            onPressed: () {
              Navigator.pop(ctx);
              _sendKey(keyCmd);
              _showToast('Sent $title signal to PC');
            },
            child: Text('Yes, $title'),
          ),
        ],
      ),
    );
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

  /// TAB 1: Live Screen Mirroring View with "Why Can't I See The Screen?" Root-Cause Diagnosis
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
                              errorBuilder: (context, error, stackTrace) => _buildFrameErrorBox(error),
                            ),
                          )
                        : SizedBox.expand(
                            child: Image.memory(
                              _latestFrameBytes!,
                              fit: BoxFit.fill,
                              gaplessPlayback: true,
                              filterQuality: FilterQuality.low,
                              errorBuilder: (context, error, stackTrace) => _buildFrameErrorBox(error),
                            ),
                          ),
                  ),
                )
              : _buildRootCauseDiagnosticCenter(),

          // Floating Warning Banner if Screen Content is Pitch Black
          if (_latestFrameBytes != null && _isScreenBlackDetected)
            Positioned(
              left: 16,
              bottom: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B).withOpacity(0.95),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFF59E0B)),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 10),
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: Color(0xFFF59E0B), size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Text('Desktop screen appears pitch black', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                          Text('PC monitor may be asleep, locked, or on secondary display.', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 10)),
                        ],
                      ),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0284C7),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      ),
                      onPressed: () {
                        _wakeDisplay();
                        _cycleDisplay();
                      },
                      child: const Text('Wake / Fix', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
            ),

          // Floating Controls Bar (Top Right)
          Positioned(
            top: 10,
            right: 10,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // "Why Can't I See The Screen?" Root-Cause Diagnosis Toggle
                InkWell(
                  onTap: () => setState(() => _showDebugHud = !_showDebugHud),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: _showDebugHud
                          ? const Color(0xFF0284C7)
                          : const Color(0xFF1E293B).withOpacity(0.85),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _showDebugHud ? const Color(0xFF38BDF8) : const Color(0xFF334155),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.troubleshoot, size: 14, color: Color(0xFF38BDF8)),
                        const SizedBox(width: 4),
                        Text(
                          _showDebugHud ? 'Hide Diagnosis' : 'Screen Diagnostics',
                          style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                if (_latestFrameBytes != null)
                  FloatingActionButton.small(
                    heroTag: 'fit_btn',
                    backgroundColor: const Color(0xFF1E293B).withOpacity(0.85),
                    foregroundColor: const Color(0xFF38BDF8),
                    onPressed: () => setState(() => _isFitScreen = !_isFitScreen),
                    tooltip: _isFitScreen ? 'Switch to Stretch Fill' : 'Switch to Aspect Ratio Fit',
                    child: Icon(_isFitScreen ? Icons.aspect_ratio : Icons.fullscreen),
                  ),
              ],
            ),
          ),

          // Floating Real-Time Diagnostics HUD Overlay
          if (_showDebugHud)
            Positioned(
              left: 10,
              top: 50,
              right: 10,
              child: _buildFloatingDebugHud(),
            ),
        ],
      ),
    );
  }

  Widget _buildFrameErrorBox(Object error) {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(20),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFEF4444)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image, color: Color(0xFFEF4444), size: 36),
            const SizedBox(height: 8),
            Text('Image Decode Error: $error', style: const TextStyle(color: Colors.white, fontSize: 12)),
            const SizedBox(height: 12),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0284C7)),
              onPressed: _requestImmediateFrame,
              child: const Text('Request Fresh Frame'),
            ),
          ],
        ),
      ),
    );
  }

  /// DIRECT ROOT-CAUSE DIAGNOSIS: Explains WHY the user cannot see the screen and offers 1-tap auto repairs
  Widget _buildRootCauseDiagnosticCenter() {
    final bool networkOk = _isConnected;
    final bool framesArriving = _totalBinaryFramesReceived > 0;
    final bool pcCapturing = _hostFrameCount > 0;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 540),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF38BDF8).withOpacity(0.4)),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.6), blurRadius: 20, offset: const Offset(0, 6)),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0284C7).withOpacity(0.2),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.troubleshoot, color: Color(0xFF38BDF8), size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text(
                          "WHY CAN'T I SEE THE SCREEN?",
                          style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold, letterSpacing: 1),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Live Pipeline Diagnostic & 1-Tap Auto-Repair Center',
                          style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),
              const Divider(color: Color(0xFF334155)),
              const SizedBox(height: 8),

              // Checklist Item 1: Network Connection
              _buildDiagnosticCheckItem(
                title: '1. Phone-to-PC Network Connection',
                statusOk: networkOk,
                statusText: networkOk
                    ? 'Connected to ${_isOutsideWifiMode ? "Outside Wi-Fi (WAN)" : "Home Wi-Fi"} (${_ipController.text}) • Latency: ${_latencyMs}ms'
                    : 'Not connected to PC server. Connect via Home Wi-Fi or Outside Wi-Fi first.',
                explanation: !networkOk
                    ? 'Ensure PC host server is running and port 8765 is accessible.'
                    : null,
              ),

              const SizedBox(height: 8),

              // Checklist Item 2: PC Desktop Capture Engine
              _buildDiagnosticCheckItem(
                title: '2. PC Desktop Capture Engine',
                statusOk: pcCapturing,
                statusText: pcCapturing
                    ? 'Host produced $_hostFrameCount frames via $_hostCaptureEngine (${_remoteWidth.toInt()}x${_remoteHeight.toInt()})'
                    : 'PC capture engine has not produced desktop buffer yet (0 frames)',
                explanation: !pcCapturing
                    ? 'Windows GDI BitBlt or DirectX duplication is initializing. Tap "Force GDI Desktop Capture" below.'
                    : null,
              ),

              const SizedBox(height: 8),

              // Checklist Item 3: Video Frame Delivery
              _buildDiagnosticCheckItem(
                title: '3. Video Packet Delivery to Phone',
                statusOk: framesArriving,
                statusText: framesArriving
                    ? '$_totalBinaryFramesReceived video frames received (${(_totalBytesReceived / 1024).toStringAsFixed(1)} KB)'
                    : (networkOk ? 'Connected, but waiting for video stream packets from PC' : 'Awaiting network connection'),
                explanation: (networkOk && !framesArriving)
                    ? 'The PC is capturing, but binary image frames have not arrived. Tap "Request Frame Now" or "Show Test Color Pattern" below.'
                    : null,
              ),

              const SizedBox(height: 8),

              // Checklist Item 4: Exact Host Windows Error / Status
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: (_hostLastError != null && _hostLastError!.isNotEmpty)
                        ? const Color(0xFFEF4444).withOpacity(0.6)
                        : const Color(0xFF334155),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          (_hostLastError != null && _hostLastError!.isNotEmpty)
                              ? Icons.error_outline
                              : Icons.info_outline,
                          size: 16,
                          color: (_hostLastError != null && _hostLastError!.isNotEmpty)
                              ? const Color(0xFFEF4444)
                              : const Color(0xFF38BDF8),
                        ),
                        const SizedBox(width: 6),
                        const Text(
                          'Windows Host Status & Error Detail:',
                          style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      (_hostLastError != null && _hostLastError!.isNotEmpty)
                          ? _hostLastError!
                          : (_hostFrameCount > 0
                              ? 'Active Engine: $_hostCaptureEngine ($_hostStatus)'
                              : 'Initializing Windows GDI Direct DIBSection with CAPTUREBLT...'),
                      style: TextStyle(
                        color: (_hostLastError != null && _hostLastError!.isNotEmpty)
                            ? const Color(0xFFFCA5A5)
                            : const Color(0xFF94A3B8),
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // 1-Tap Action Repairs
              const Text(
                '1-TAP AUTO-REPAIR ACTIONS:',
                style: TextStyle(color: Color(0xFF94A3B8), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1),
              ),
              const SizedBox(height: 8),

              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    ),
                    onPressed: _isConnected ? _forceGdiCapture : null,
                    icon: const Icon(Icons.build_circle, size: 18),
                    label: const Text('AUTO-FIX: Force GDI Desktop Capture', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1E293B),
                      foregroundColor: const Color(0xFF38BDF8),
                      side: const BorderSide(color: Color(0xFF38BDF8)),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    ),
                    onPressed: _isConnected ? _wakeDisplay : null,
                    icon: const Icon(Icons.wb_sunny, size: 18),
                    label: const Text('Wake PC Sleeping Screen', style: TextStyle(fontSize: 12)),
                  ),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1E293B),
                      foregroundColor: const Color(0xFFA855F7),
                      side: const BorderSide(color: Color(0xFFA855F7)),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    ),
                    onPressed: _isConnected ? _cycleDisplay : null,
                    icon: const Icon(Icons.connected_tv, size: 18),
                    label: const Text('Switch Primary / Virtual Display', style: TextStyle(fontSize: 12)),
                  ),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1E293B),
                      foregroundColor: const Color(0xFF22C55E),
                      side: const BorderSide(color: Color(0xFF22C55E)),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    ),
                    onPressed: _isConnected ? _requestTestPattern : null,
                    icon: const Icon(Icons.palette, size: 18),
                    label: const Text('Test Video Link: Show Color Pattern', style: TextStyle(fontSize: 12)),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF94A3B8),
                      side: const BorderSide(color: Color(0xFF475569)),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                    onPressed: _showDiagnosticsLogSheet,
                    icon: const Icon(Icons.terminal, size: 16),
                    label: const Text('View Raw Event Logs', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDiagnosticCheckItem({
    required String title,
    required bool statusOk,
    required String statusText,
    String? explanation,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: statusOk ? const Color(0xFF22C55E).withOpacity(0.5) : const Color(0xFFF59E0B).withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                statusOk ? Icons.check_circle : Icons.warning_amber_rounded,
                size: 16,
                color: statusOk ? const Color(0xFF22C55E) : const Color(0xFFF59E0B),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 24.0),
            child: Text(
              statusText,
              style: TextStyle(
                color: statusOk ? const Color(0xFF22C55E) : const Color(0xFFF59E0B),
                fontSize: 11,
              ),
            ),
          ),
          if (explanation != null) ...[
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.only(left: 24.0),
              child: Text(
                explanation,
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFloatingDebugHud() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withOpacity(0.95),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF38BDF8).withOpacity(0.6)),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.6), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: const [
                  Icon(Icons.troubleshoot, color: Color(0xFF38BDF8), size: 16),
                  SizedBox(width: 6),
                  Text(
                    'SCREEN PIPELINE DIAGNOSTICS',
                    style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1),
                  ),
                ],
              ),
              InkWell(
                onTap: () => setState(() => _showDebugHud = false),
                child: const Icon(Icons.close, size: 16, color: Color(0xFF94A3B8)),
              ),
            ],
          ),
          const Divider(color: Color(0xFF334155), height: 16),

          Text(
            '• Engine: $_hostCaptureEngine (${_hostCaptureMode.toUpperCase()} mode)',
            style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 11),
          ),
          Text(
            '• Frame Metrics: ${_renderedFps} Rendered FPS | ${_latencyMs}ms Latency | ${(_lastFrameSizeBytes / 1024).toStringAsFixed(1)} KB/frame',
            style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 11),
          ),
          Text(
            '• Host Captured: $_hostFrameCount | Host Sent: $_hostFramesSent | Phone Recv: $_totalBinaryFramesReceived',
            style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 11),
          ),
          if (_savedPublicIp.isNotEmpty)
            Text(
              '• Public Internet WAN: $_savedPublicIp (${_isOutsideWifiMode ? "Active" : "Ready"})',
              style: const TextStyle(color: Color(0xFFA855F7), fontSize: 11),
            ),
          if (_hostLastError != null && _hostLastError!.isNotEmpty)
            Text(
              '• Host Notice: $_hostLastError',
              style: const TextStyle(color: Color(0xFFF87171), fontSize: 11),
            ),

          const SizedBox(height: 10),
          Row(
            children: [
              const Text('Engine: ', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11)),
              _buildHudModeBtn('GDI BitBlt', 'gdi'),
              const SizedBox(width: 4),
              _buildHudModeBtn('DXGI HW', 'xcap'),
              const SizedBox(width: 4),
              _buildHudModeBtn('Test Pattern', 'test_pattern'),
              const Spacer(),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0284C7),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
                onPressed: _requestImmediateFrame,
                child: const Text('Refresh Frame', style: TextStyle(fontSize: 10)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHudModeBtn(String label, String modeVal) {
    final isSel = _hostCaptureMode == modeVal;
    return InkWell(
      onTap: () {
        _sendJson({'type': 'set_capture_mode', 'mode': modeVal});
        _sendJson({'type': 'request_frame'});
        setState(() => _hostCaptureMode = modeVal);
        _showToast('Switched engine to $label');
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: isSel ? const Color(0xFF0284C7) : const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: isSel ? const Color(0xFF38BDF8) : const Color(0xFF334155)),
        ),
        child: Text(label, style: TextStyle(fontSize: 10, color: isSel ? Colors.white : const Color(0xFF94A3B8))),
      ),
    );
  }

  /// TAB 2: Apps & Web Shortcuts
  Widget _buildShortcutsAndAppsTab() {
    return Container(
      color: const Color(0xFF0F172A),
      padding: const EdgeInsets.all(12),
      child: ListView(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'QUICK WEBSITES',
                style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1),
              ),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 16, color: Color(0xFF38BDF8)),
                label: const Text('Add Shortcut', style: TextStyle(color: Color(0xFF38BDF8), fontSize: 12)),
                onPressed: _showAddShortcutDialog,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _webShortcuts.map((item) {
              final isCustom = !_defaultWebShortcuts.any((d) => d.name == item.name && d.url == item.url);
              return InputChip(
                backgroundColor: const Color(0xFF1E293B),
                side: const BorderSide(color: Color(0xFF334155)),
                avatar: Icon(item.icon, size: 18, color: const Color(0xFF38BDF8)),
                label: Text(item.name, style: const TextStyle(color: Colors.white, fontSize: 12)),
                onPressed: _isConnected ? () => _openUrl(item.url) : null,
                onDeleted: isCustom
                    ? () {
                        setState(() {
                          _webShortcuts.removeWhere((s) => s.name == item.name && s.url == item.url);
                        });
                        _saveWebShortcuts();
                        _showToast('Removed shortcut: ${item.name}');
                      }
                    : null,
                deleteIconColor: const Color(0xFF94A3B8),
              );
            }).toList(),
          ),

          const SizedBox(height: 20),
          const Text(
            'LAUNCH PC APPS',
            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1),
          ),
          const SizedBox(height: 8),

          GridView.count(
            crossAxisCount: 3,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 2.2,
            children: [
              _buildAppTile('Chrome', 'chrome', Icons.travel_explore),
              _buildAppTile('Edge', 'edge', Icons.language),
              _buildAppTile('Explorer', 'explorer', Icons.folder_open),
              _buildAppTile('Task Manager', 'taskmgr', Icons.analytics),
              _buildAppTile('Notepad', 'notepad', Icons.edit_note),
              _buildAppTile('Calculator', 'calculator', Icons.calculate),
              _buildAppTile('Terminal (CMD)', 'cmd', Icons.terminal),
            ],
          ),

          const SizedBox(height: 20),
          const Text(
            'KEYBOARD INPUT TO PC',
            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1),
          ),
          const SizedBox(height: 8),

          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _textController,
                  focusNode: _textFocusNode,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: const InputDecoration(
                    hintText: 'Type text here to send to PC...',
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  onSubmitted: _sendText,
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0284C7),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
                onPressed: _isConnected ? () => _sendText(_textController.text) : null,
                icon: const Icon(Icons.send, size: 16),
                label: const Text('Send'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAppTile(String label, String appCmd, IconData icon) {
    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF1E293B),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: _isConnected ? () => _launchApp(appCmd) : null,
      icon: Icon(icon, size: 18, color: const Color(0xFF38BDF8)),
      label: Text(label, style: const TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis),
    );
  }

  /// TAB 3: Administrator Security Portal (Password: Sagiv_2311)
  Widget _buildAdminTab() {
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
              border: Border.all(color: const Color(0xFF38BDF8).withOpacity(0.4)),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 15, offset: const Offset(0, 4)),
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
                  child: const Icon(Icons.admin_panel_settings, color: Color(0xFF38BDF8), size: 48),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Administrator Portal',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Enter password to view all connected devices, disconnect users, and lock phone apps.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _adminPasswordController,
                  obscureText: _obscureAdminPassword,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Admin Password',
                    prefixIcon: const Icon(Icons.key, color: Color(0xFF38BDF8), size: 20),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureAdminPassword ? Icons.visibility_off : Icons.visibility,
                        color: const Color(0xFF94A3B8),
                      ),
                      onPressed: () => setState(() => _obscureAdminPassword = !_obscureAdminPassword),
                    ),
                  ),
                  onSubmitted: (_) => _submitAdminAuth(),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0284C7)),
                    onPressed: _isConnected && !_isAdminAuthenticating ? _submitAdminAuth : null,
                    child: _isAdminAuthenticating
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                          )
                        : const Text('Unlock Admin Access', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      color: const Color(0xFF0F172A),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: const [
                  Icon(Icons.security, color: Color(0xFF22C55E), size: 18),
                  SizedBox(width: 8),
                  Text(
                    'CONNECTED PHONES & PERMISSIONS',
                    style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1),
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.refresh, color: Color(0xFF38BDF8), size: 20),
                tooltip: 'Refresh list',
                onPressed: () => _sendJson({'type': 'admin_get_clients'}),
              ),
            ],
          ),
          const SizedBox(height: 8),

          Expanded(
            child: _connectedPhones.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(Icons.phone_android, size: 40, color: Color(0xFF475569)),
                        SizedBox(height: 8),
                        Text('No other phones connected to PC', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13)),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _connectedPhones.length,
                    itemBuilder: (ctx, idx) {
                      final phone = _connectedPhones[idx];
                      final isMe = phone.id == _myClientId;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: phone.isLocked
                                ? const Color(0xFFEF4444)
                                : (isMe ? const Color(0xFF38BDF8) : const Color(0xFF334155)),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: phone.isLocked
                                    ? const Color(0xFFEF4444).withOpacity(0.2)
                                    : const Color(0xFF0284C7).withOpacity(0.2),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                phone.isLocked ? Icons.lock : Icons.phone_android,
                                color: phone.isLocked ? const Color(0xFFEF4444) : const Color(0xFF38BDF8),
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        phone.deviceName,
                                        style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 13),
                                      ),
                                      if (isMe) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF0284C7),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: const Text('THIS PHONE', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold)),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'IP: ${phone.ip} • Device ID: ${phone.deviceId.length > 18 ? phone.deviceId.substring(0, 18) : phone.deviceId}',
                                    style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                                  ),
                                  if (phone.isLocked) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      phone.lockedUntil == 0
                                          ? 'Status: Locked indefinitely until unlocked'
                                          : 'Status: Locked until ${DateTime.fromMillisecondsSinceEpoch(phone.lockedUntil * 1000).toLocal().toString().substring(11, 16)}',
                                      style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 10, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (phone.isLocked)
                                  IconButton(
                                    icon: const Icon(Icons.lock_open, color: Color(0xFF22C55E), size: 20),
                                    tooltip: 'Unlock Phone',
                                    onPressed: () {
                                      _sendJson({'type': 'admin_unlock_client', 'target_id': phone.id});
                                      _showToast('Unlocked ${phone.deviceName}');
                                    },
                                  )
                                else
                                  IconButton(
                                    icon: const Icon(Icons.lock_outline, color: Color(0xFFF59E0B), size: 20),
                                    tooltip: 'Lock Phone',
                                    onPressed: () => _showLockDurationDialog(phone.id, phone.deviceName),
                                  ),
                                IconButton(
                                  icon: const Icon(Icons.link_off, color: Color(0xFFEF4444), size: 20),
                                  tooltip: 'Disconnect Phone',
                                  onPressed: () {
                                    _sendJson({'type': 'admin_disconnect_client', 'target_id': phone.id});
                                    _showToast('Disconnected ${phone.deviceName}');
                                  },
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

  /// Full-Screen Lock Overlay shown when device is locked by administrator
  Widget _buildLockedScreen() {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: Center(
        child: Container(
          margin: const EdgeInsets.all(24),
          padding: const EdgeInsets.all(24),
          constraints: const BoxConstraints(maxWidth: 440),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFEF4444), width: 2),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.6), blurRadius: 20),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_person, size: 64, color: Color(0xFFEF4444)),
              const SizedBox(height: 16),
              const Text(
                'APP ACCESS LOCKED',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 1.2),
              ),
              const SizedBox(height: 8),
              const Text(
                'This device has been temporarily locked by the PC administrator.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
              ),
              const SizedBox(height: 16),

              if (_remainingLockSeconds > 0) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.timer, color: Color(0xFFF59E0B), size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'Unlocks in: ${_remainingLockSeconds ~/ 60}m ${_remainingLockSeconds % 60}s',
                        style: const TextStyle(color: Color(0xFFF59E0B), fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    'Locked until unlocked by Administrator',
                    style: TextStyle(color: Color(0xFFEF4444), fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                ),
              ],

              const SizedBox(height: 20),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF334155),
                  foregroundColor: Colors.white,
                ),
                onPressed: _showAdminLoginDialog,
                icon: const Icon(Icons.admin_panel_settings, size: 16),
                label: const Text('Admin Unlock'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
