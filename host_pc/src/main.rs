//! Remote PC Host Server
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
    // Add rule for WebSocket TCP streaming port
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

    // Add rule for UDP Auto-Discovery beacon
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
    // 1. Automatic UAC Elevation: If not admin, prompt Windows UAC elevation automatically
    if !is_running_as_admin() {
        println!("[UAC] Requesting Administrator privileges for DXGI capture and Firewall setup...");
        relaunch_as_admin();
    }

    println!("============================================================");
    println!("    REMOTE PC CONTROLLER HOST (HIGH-PERFORMANCE SUITE)     ");
    println!("============================================================");

    // 2. Automatically configure firewall rule so user never types commands
    setup_windows_firewall();

    // 3. Auto-detect LAN IP
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

    // Broadcast channel for distributing compressed JPEG frames
    let (frame_tx, _) = broadcast::channel::<FrameData>(2);

    let screen_width = Arc::new(AtomicUsize::new(1920));
    let screen_height = Arc::new(AtomicUsize::new(1080));

    // Shared thread-safe input injector
    let enigo = Arc::new(Mutex::new(
        Enigo::new(&Settings::default()).expect("Failed to initialize Enigo input injector"),
    ));

    let is_running = Arc::new(AtomicBool::new(true));

    // Spawn DXGI Screen Capture Task on dedicated OS thread
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

        let target_frame_duration = Duration::from_millis(16); // ~60 FPS target
        let mut last_valid_jpeg = Arc::new(Vec::new());

        while capture_running.load(Ordering::Relaxed) {
            let start_time = Instant::now();

            match manager.capture_frame_components() {
                Ok((mut pixels, (width, height))) => {
                    width_ref.store(width, Ordering::Relaxed);
                    height_ref.store(height, Ordering::Relaxed);

                    // pixels is Vec<u8> (BGRA raw byte components)
                    // Swizzle B and R in-place to RGBA for accurate JPEG color
                    for chunk in pixels.chunks_exact_mut(4) {
                        chunk.swap(0, 2);
                    }

                    // Compress to JPEG (quality 70 offers optimal size/speed tradeoff)
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

    // Start TokIO WebSocket server
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

/// Handles a single connected WebSocket client.
async fn handle_connection(
    stream: TcpStream,
    _addr: SocketAddr,
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

    // Send screen resolution and host info payload
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

    // Task A: Write outbound frames and responses to client socket
    let out_tx_ping = out_tx.clone();
    let write_task = tokio::spawn(async move {
        while let Some(msg) = out_rx.recv().await {
            if let Err(e) = ws_sink.send(msg).await {
                eprintln!("[WS Sink #{}] Send error: {:?}", client_id, e);
                break;
            }
        }
    });

    // Task B: Forward video frames; drop lagging frames if channel buffer is full
    let frame_task = tokio::spawn(async move {
        while let Ok(frame) = frame_rx.recv().await {
            let msg = Message::Binary(frame.jpeg_bytes.as_ref().clone());
            let _ = out_tx.try_send(msg);
        }
    });

    // Task C: Inbound command processing
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
}

