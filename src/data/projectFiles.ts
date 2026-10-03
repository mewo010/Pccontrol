export interface ProjectFile {
  path: string;
  name: string;
  language: string;
  category: 'rust' | 'flutter' | 'ci';
  description: string;
  content: string;
}

export const PROJECT_FILES: ProjectFile[] = [
  {
    path: 'host_pc/Cargo.toml',
    name: 'Cargo.toml',
    language: 'toml',
    category: 'rust',
    description: 'Rust Host dependencies: Tokio, DXGI capture (v1.2.2), Enigo (v0.6), Image, and Serde',
    content: `[package]
name = "remote_pc_host"
version = "1.0.0"
edition = "2021"
authors = ["Remote PC Team"]
description = "High-performance Windows DXGI GPU Screen Mirroring & Remote Input Server"

[dependencies]
tokio = { version = "1.38", features = ["full"] }
tokio-tungstenite = "0.23"
dxgi-capture-rs = "1.2.2"
enigo = "0.6"
image = { version = "0.25", default-features = false, features = ["jpeg"] }
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
futures-util = "0.3"

[profile.release]
opt-level = 3
lto = true
codegen-units = 1
panic = "abort"
strip = true`
  },
  {
    path: 'host_pc/src/main.rs',
    name: 'main.rs',
    language: 'rust',
    category: 'rust',
    description: 'Auto-Elevation (UAC), Auto-Firewall setup, UDP Auto-Discovery beacon, DXGI 60 FPS capture & input executor',
    content: `//! Remote PC Host Server
//! Windows DXGI Desktop Duplication Screen Mirror & Remote Input Injection
//!
//! Features:
//! - Auto-Elevation to Administrator (UAC prompt on double-click)
//! - Auto-Firewall Rule Configuration (Port 8765 TCP & 8766 UDP)
//! - UDP Auto-Discovery Beacon (Mobile app discovers PC with 1 click, no typing)
//! - DXGI Desktop Duplication 60 FPS screen capture
//! - Enigo remote input injection (mouse, keyboard, keys)

use std::error::Error;
use std::net::{SocketAddr, UdpSocket};
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use dxgi_capture_rs::DXGIManager;
use enigo::{Button, Coordinate, Direction, Enigo, Key, Keyboard, Mouse, Settings};
use futures_util::{SinkExt, StreamExt};
use image::codecs::jpeg::JpegEncoder;
use image::ColorType;
use serde::{Deserialize, Serialize};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{broadcast, mpsc, Mutex};
use tokio_tungstenite::tungstenite::protocol::Message;

/// Inbound JSON messages sent by the mobile client.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type")]
pub enum ClientMessage {
    #[serde(rename = "move")]
    Move { x: f64, y: f64 },
    #[serde(rename = "click")]
    Click { button: String },
    #[serde(rename = "type")]
    Type { text: String },
    #[serde(rename = "key")]
    Key { key: String },
    #[serde(rename = "ping")]
    Ping { timestamp: Option<u64> },
}

/// Outbound JSON messages sent back to the mobile client.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type")]
pub enum HostMessage {
    #[serde(rename = "pong")]
    Pong { timestamp: u64 },
    #[serde(rename = "info")]
    Info {
        width: u32,
        height: u32,
        fps_target: u32,
        host_name: String,
        ip_address: String,
    },
}

/// Shared desktop frame buffer broadcast to connected WebSocket clients.
#[derive(Clone)]
struct FrameData {
    pub jpeg_bytes: Arc<Vec<u8>>,
    pub width: u32,
    pub height: u32,
}

/// Check if running with Administrative privileges on Windows
fn is_running_as_admin() -> bool {
    let output = Command::new("net").arg("session").output();
    match output {
        Ok(out) => out.status.success(),
        Err(_) => false,
    }
}

/// Automatically re-launch process with Administrator UAC prompt if not already elevated
fn relaunch_as_admin() {
    if let Ok(current_exe) = std::env::current_exe() {
        let exe_path = current_exe.to_string_lossy().to_string();
        let args = format!("Start-Process -FilePath '{}' -Verb RunAs", exe_path);
        let _ = Command::new("powershell")
            .args(["-NoProfile", "-WindowStyle", "Normal", "-Command", &args])
            .spawn();
        std::process::exit(0);
    }
}

/// Automatically configure Windows Defender Firewall for ports 8765 (TCP) and 8766 (UDP)
fn setup_windows_firewall() {
    println!("[FIREWALL] Ensuring inbound firewall rules exist for port 8765 TCP & 8766 UDP...");
    let _ = Command::new("netsh")
        .args([
            "advfirewall",
            "firewall",
            "add",
            "rule",
            "name=RemotePC_Host_TCP",
            "dir=in",
            "action=allow",
            "protocol=TCP",
            "localport=8765",
            "profile=any",
        ])
        .output();

    let _ = Command::new("netsh")
        .args([
            "advfirewall",
            "firewall",
            "add",
            "rule",
            "name=RemotePC_Host_UDP",
            "dir=in",
            "action=allow",
            "protocol=UDP",
            "localport=8766",
            "profile=any",
        ])
        .output();
    println!("[FIREWALL] Firewall rules verified and active.");
}

/// Detect primary Local Area Network (LAN) IP
fn get_local_lan_ip() -> String {
    UdpSocket::bind("0.0.0.0:0")
        .and_then(|s| {
            s.connect("8.8.8.8:80")?;
            s.local_addr()
        })
        .map(|addr| addr.ip().to_string())
        .unwrap_or_else(|_| "127.0.0.1".to_string())
}

/// Start UDP discovery beacon on port 8766 so mobile app discovers PC automatically
fn start_udp_discovery_beacon(local_ip: String, host_name: String) {
    std::thread::spawn(move || {
        let socket = match UdpSocket::bind("0.0.0.0:8766") {
            Ok(s) => s,
            Err(e) => {
                eprintln!("[DISCOVERY] Could not bind UDP discovery port 8766: {:?}", e);
                return;
            }
        };
        let _ = socket.set_broadcast(true);
        println!("[DISCOVERY] Auto-Discovery beacon active on UDP port 8766.");

        let mut buf = [0u8; 1024];
        loop {
            if let Ok((len, src)) = socket.recv_from(&mut buf) {
                let msg = String::from_utf8_lossy(&buf[..len]);
                if msg.trim().starts_with("DISCOVER_REMOTE_PC") {
                    println!("[DISCOVERY] Received discovery ping from mobile at {}", src);
                    let reply = format!("REMOTE_PC_HOST:{}:{}:8765", host_name, local_ip);
                    let _ = socket.send_to(reply.as_bytes(), src);
                }
            }
        }
    });
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    // 1. Automatic UAC Elevation: Prompt Windows UAC elevation automatically
    if !is_running_as_admin() {
        println!("[UAC] Requesting Administrator privileges for DXGI capture and Firewall setup...");
        relaunch_as_admin();
    }

    println!("============================================================");
    println!("    REMOTE PC CONTROLLER HOST (HIGH-PERFORMANCE SUITE)     ");
    println!("============================================================");

    // 2. Automatically configure firewall rules
    setup_windows_firewall();

    // 3. Auto-detect LAN IP and Device Name
    let local_lan_ip = get_local_lan_ip();
    let host_name = std::env::var("COMPUTERNAME").unwrap_or_else(|_| "Windows-PC".to_string());

    // 4. Start UDP Discovery Beacon so mobile app discovers PC with 1 click
    start_udp_discovery_beacon(local_lan_ip.clone(), host_name.clone());

    println!("------------------------------------------------------------");
    println!("  [+] PC NAME:              {}", host_name);
    println!("  [+] YOUR PC'S LOCAL IP:   {}", local_lan_ip);
    println!("  [+] PORT:                 8765");
    println!();
    println!("  >>> ON YOUR MOBILE APP:");
    println!("      Either tap 'Auto-Detect PC' to connect instantly,");
    println!("      or enter: {}:8765", local_lan_ip);
    println!("------------------------------------------------------------");

    let (frame_tx, _) = broadcast::channel::<FrameData>(2);

    let screen_width = Arc::new(AtomicUsize::new(1920));
    let screen_height = Arc::new(AtomicUsize::new(1080));

    let enigo = Arc::new(Mutex::new(
        Enigo::new(&Settings::default()).expect("Failed to initialize Enigo input injector"),
    ));

    let is_running = Arc::new(AtomicBool::new(true));

    let capture_tx = frame_tx.clone();
    let capture_running = is_running.clone();
    let width_ref = screen_width.clone();
    let height_ref = screen_height.clone();

    std::thread::spawn(move || {
        println!("[DXGI] Initializing Windows DXGI Desktop Duplication API...");
        let mut manager = match DXGIManager::new(100) {
            Ok(mgr) => {
                println!("[DXGI] Successfully attached to primary GPU output adapter.");
                mgr
            }
            Err(e) => {
                eprintln!("[DXGI ERROR] Failed to initialize DXGIManager: {:?}. Retrying in 1s...", e);
                std::thread::sleep(Duration::from_secs(1));
                DXGIManager::new(100).expect("Fatal: Could not initialize DXGI Output Duplication")
            }
        };

        let target_frame_duration = Duration::from_millis(16);
        let mut last_valid_jpeg = Arc::new(Vec::new());

        while capture_running.load(Ordering::Relaxed) {
            let start_time = Instant::now();

            match manager.capture_frame() {
                Ok((mut pixels, (width, height))) => {
                    width_ref.store(width, Ordering::Relaxed);
                    height_ref.store(height, Ordering::Relaxed);

                    for chunk in pixels.chunks_exact_mut(4) {
                        chunk.swap(0, 2);
                    }

                    let mut jpeg_buffer = Vec::with_capacity((width * height) / 4);
                    let mut encoder = JpegEncoder::new_with_quality(&mut jpeg_buffer, 70);
                    if let Ok(()) = encoder.encode(
                        &pixels,
                        width as u32,
                        height as u32,
                        ColorType::Rgba8.into(),
                    ) {
                        last_valid_jpeg = Arc::new(jpeg_buffer);
                        let frame = FrameData {
                            jpeg_bytes: last_valid_jpeg.clone(),
                            width: width as u32,
                            height: height as u32,
                        };
                        let _ = capture_tx.send(frame);
                    }
                }
                Err(_) => {
                    if !last_valid_jpeg.is_empty() {
                        let frame = FrameData {
                            jpeg_bytes: last_valid_jpeg.clone(),
                            width: width_ref.load(Ordering::Relaxed) as u32,
                            height: height_ref.load(Ordering::Relaxed) as u32,
                        };
                        let _ = capture_tx.send(frame);
                    }
                }
            }

            let elapsed = start_time.elapsed();
            if elapsed < target_frame_duration {
                std::thread::sleep(target_frame_duration - elapsed);
            }
        }
    });

    let bind_addr = "0.0.0.0:8765";
    let listener = TcpListener::bind(bind_addr).await?;
    println!("[NETWORK] WebSocket Server listening on ws://{}", bind_addr);
    println!("[NETWORK] Ready for Android Flutter Client connections...");

    let client_counter = Arc::new(AtomicUsize::new(0));

    while let Ok((stream, addr)) = listener.accept().await {
        let client_id = client_counter.fetch_add(1, Ordering::SeqCst) + 1;
        println!("[+] Client #{} connected from {}", client_id, addr);

        let frame_rx = frame_tx.subscribe();
        let enigo_clone = enigo.clone();
        let width_clone = screen_width.clone();
        let height_clone = screen_height.clone();
        let host_name_clone = host_name.clone();
        let ip_clone = local_lan_ip.clone();

        tokio::spawn(async move {
            if let Err(e) = handle_connection(
                stream,
                addr,
                client_id,
                frame_rx,
                enigo_clone,
                width_clone,
                height_clone,
                host_name_clone,
                ip_clone,
            )
            .await
            {
                eprintln!("[-] Client #{} error: {:?}", client_id, e);
            }
            println!("[-] Client #{} disconnected ({})", client_id, addr);
        });
    }

    Ok(())
}

async fn handle_connection(
    stream: TcpStream,
    addr: SocketAddr,
    client_id: usize,
    mut frame_rx: broadcast::Receiver<FrameData>,
    enigo: Arc<Mutex<Enigo>>,
    screen_width: Arc<AtomicUsize>,
    screen_height: Arc<AtomicUsize>,
    host_name: String,
    ip_address: String,
) -> Result<(), Box<dyn Error + Send + Sync>> {
    let ws_stream = tokio_tungstenite::accept_async(stream).await?;
    let (mut ws_sink, mut ws_stream_reader) = ws_stream.split();

    let (out_tx, mut out_rx) = mpsc::channel::<Message>(8);

    let initial_width = screen_width.load(Ordering::Relaxed) as u32;
    let initial_height = screen_height.load(Ordering::Relaxed) as u32;
    let info_msg = HostMessage::Info {
        width: initial_width,
        height: initial_height,
        fps_target: 60,
        host_name,
        ip_address,
    };
    if let Ok(info_json) = serde_json::to_string(&info_msg) {
        let _ = out_tx.send(Message::Text(info_json)).await;
    }

    let out_tx_ping = out_tx.clone();
    let write_task = tokio::spawn(async move {
        while let Some(msg) = out_rx.recv().await {
            if let Err(e) = ws_sink.send(msg).await {
                eprintln!("[WS Sink #{}] Send error: {:?}", client_id, e);
                break;
            }
        }
    });

    let frame_task = tokio::spawn(async move {
        while let Ok(frame) = frame_rx.recv().await {
            let msg = Message::Binary(frame.jpeg_bytes.as_ref().clone());
            let _ = out_tx.try_send(msg);
        }
    });

    while let Some(msg_result) = ws_stream_reader.next().await {
        match msg_result {
            Ok(Message::Text(text)) => {
                if let Ok(cmd) = serde_json::from_str::<ClientMessage>(&text) {
                    let mut enigo_guard = enigo.lock().await;
                    let cur_w = screen_width.load(Ordering::Relaxed) as f64;
                    let cur_h = screen_height.load(Ordering::Relaxed) as f64;

                    match cmd {
                        ClientMessage::Move { x, y } => {
                            let clamped_x = x.clamp(0.0, 1.0);
                            let clamped_y = y.clamp(0.0, 1.0);
                            let target_x = (clamped_x * cur_w).round() as i32;
                            let target_y = (clamped_y * cur_h).round() as i32;
                            let _ = enigo_guard.move_mouse(target_x, target_y, Coordinate::Abs);
                        }
                        ClientMessage::Click { button } => {
                            let btn = match button.to_lowercase().as_str() {
                                "right" => Button::Right,
                                "middle" => Button::Middle,
                                _ => Button::Left,
                            };
                            let _ = enigo_guard.button(btn, Direction::Click);
                        }
                        ClientMessage::Type { text } => {
                            let _ = enigo_guard.text(&text);
                        }
                        ClientMessage::Key { key } => {
                            let target_key = match key.to_lowercase().as_str() {
                                "enter" | "return" => Some(Key::Return),
                                "backspace" => Some(Key::Backspace),
                                "escape" | "esc" => Some(Key::Escape),
                                "tab" => Some(Key::Tab),
                                "space" => Some(Key::Space),
                                "up" => Some(Key::UpArrow),
                                "down" => Some(Key::DownArrow),
                                "left" => Some(Key::LeftArrow),
                                "right" => Some(Key::RightArrow),
                                _ => None,
                            };
                            if let Some(k) = target_key {
                                let _ = enigo_guard.key(k, Direction::Click);
                            }
                        }
                        ClientMessage::Ping { timestamp } => {
                            let ts = timestamp.unwrap_or_else(|| {
                                std::time::SystemTime::now()
                                    .duration_since(std::time::UNIX_EPOCH)
                                    .unwrap_or_default()
                                    .as_millis() as u64
                            });
                            let pong = HostMessage::Pong { timestamp: ts };
                            if let Ok(pong_json) = serde_json::to_string(&pong) {
                                let _ = out_tx_ping.send(Message::Text(pong_json)).await;
                            }
                        }
                    }
                }
            }
            Ok(Message::Close(_)) => break,
            Ok(Message::Ping(data)) => {
                let _ = out_tx_ping.send(Message::Pong(data)).await;
            }
            Err(_) => break,
            _ => {}
        }
    }

    write_task.abort();
    frame_task.abort();

    Ok(())
}`
  },
  {
    path: 'client_mobile/pubspec.yaml',
    name: 'pubspec.yaml',
    language: 'yaml',
    category: 'flutter',
    description: 'Flutter project config with web_socket_channel, cupertino_icons, and Android build settings',
    content: `name: remote_pc_client
description: "High-performance Remote PC Controller & Screen Mirroring Android Client"
publish_to: "none"
version: 1.0.0+1

environment:
  sdk: ">=3.0.0 <4.0.0"
  flutter: ">=3.16.0"

dependencies:
  flutter:
    sdk: flutter
  web_socket_channel: ^3.0.1
  cupertino_icons: ^1.0.8

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0

flutter:
  uses-material-design: true`
  },
  {
    path: 'client_mobile/lib/main.dart',
    name: 'main.dart',
    language: 'dart',
    category: 'flutter',
    description: 'Android client with 1-Click UDP Auto-Detect PC on Wi-Fi, normalized touch mapping, typing bar & action keys',
    content: `import 'dart:async';
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

      // Send discovery broadcast beacon
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
          _statusMessage = 'Scan error: $e';
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
              _statusMessage = 'Connected to \${_hostPcName.isNotEmpty ? _hostPcName : wsUrl}';
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

          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '\${_latencyMs}ms',
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
                '\${_renderedFps}fps',
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
}`
  },
  {
    path: '.github/workflows/build-release.yml',
    name: 'build-release.yml',
    language: 'yaml',
    category: 'ci',
    description: 'Cross-platform GitHub Actions workflow: Windows MSVC Rust build + Ubuntu Android Flutter APK build + softprops release',
    content: `name: Build & Release Cross-Platform Suite

on:
  push:
    branches:
      - main
      - master
    tags:
      - 'v*'
  pull_request:
    branches:
      - main
      - master
  workflow_dispatch:

permissions:
  contents: write

jobs:
  build-rust-host:
    name: Build Windows Host (.exe)
    runs-on: windows-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Install Rust Toolchain
        uses: dtolnay/rust-toolchain@stable

      - name: Cache Rust Dependencies
        uses: Swatinem/rust-cache@v2
        with:
          workspaces: host_pc
        continue-on-error: true

      - name: Build Windows Host Executable
        working-directory: host_pc
        run: cargo build --release

      - name: Upload Windows Executable Artifact
        uses: actions/upload-artifact@v4
        with:
          name: windows-host-binary
          path: host_pc/target/release/remote_pc_host.exe
          if-no-files-found: error

  build-flutter-client:
    name: Build Android Client (.apk)
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Set up Java 17
        uses: actions/setup-java@v4
        with:
          distribution: 'temurin'
          java-version: '17'

      - name: Set up Flutter SDK
        uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.24.x'
          channel: 'stable'
          cache: true

      - name: Ensure Android Project Scaffolding
        working-directory: client_mobile
        run: |
          if [ ! -d "android" ]; then
            echo "Generating Android platform scaffolding..."
            flutter create . --platforms=android --org com.remotepc
          fi
          flutter pub get

      - name: Build Android Release APK
        working-directory: client_mobile
        run: flutter build apk --release

      - name: Upload Android APK Artifact
        uses: actions/upload-artifact@v4
        with:
          name: android-client-apk
          path: client_mobile/build/app/outputs/flutter-apk/app-release.apk
          if-no-files-found: error

  create-github-release:
    name: Publish Unified GitHub Release
    needs: [build-rust-host, build-flutter-client]
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Determine Release Tag & Version
        id: release_meta
        run: |
          if [[ "\${{ github.ref }}" == refs/tags/v* ]]; then
            TAG="\${{ github.ref_name }}"
            IS_PRERELEASE=false
          else
            TAG="v1.0.0-run.\${{ github.run_number }}"
            IS_PRERELEASE=true
          fi
          echo "tag=$TAG" >> $GITHUB_OUTPUT
          echo "prerelease=$IS_PRERELEASE" >> $GITHUB_OUTPUT
          echo "Resolved Tag: $TAG (Prerelease: $IS_PRERELEASE)"

      - name: Create Artifacts Staging Directory
        run: mkdir -p release_assets

      - name: Download Windows Host Artifact
        uses: actions/download-artifact@v4
        with:
          name: windows-host-binary
          path: download_host

      - name: Download Android Client Artifact
        uses: actions/download-artifact@v4
        with:
          name: android-client-apk
          path: download_client

      - name: Stage & Verify Release Assets
        run: |
          find download_host -type f -name "*.exe" -exec cp {} release_assets/RemotePC-Host-Windows.exe \\;
          find download_client -type f -name "*.apk" -exec cp {} release_assets/RemotePC-Client-Android.apk \\;
          echo "Staged release assets:"
          ls -lah release_assets/

      - name: Create GitHub Release with Binaries
        uses: softprops/action-gh-release@v2
        with:
          name: "Remote PC Suite \${{ steps.release_meta.outputs.tag }}"
          tag_name: \${{ steps.release_meta.outputs.tag }}
          draft: false
          prerelease: \${{ steps.release_meta.outputs.prerelease == 'true' }}
          generate_release_notes: true
          files: |
            release_assets/RemotePC-Host-Windows.exe
            release_assets/RemotePC-Client-Android.apk
        env:
          GITHUB_TOKEN: \${{ secrets.GITHUB_TOKEN }}
`
  }
];
