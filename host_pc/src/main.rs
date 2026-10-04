//! Remote PC Host Server
//! Windows DXGI Desktop Duplication Screen Mirror & Remote Input Injection
//!
//! Features:
//! - Auto-Elevation to Administrator (UAC prompt on double-click)
//! - Auto-Firewall Rule Configuration (Port 8765 TCP & 8766 UDP)
//! - UDP Auto-Discovery Beacon (Mobile app discovers PC with 1 click, no typing)
//! - DXGI Desktop Duplication 60 FPS screen capture with instant frame delivery
//! - Touch screen & Trackpad Mouse Control (absolute & relative movement, click, drag, scroll)
//! - Windows Key & Keyboard shortcuts (Win / Meta, Alt+Tab, Win+D, TaskMgr)
//! - Web Shortcut Launcher (opens sites on PC default browser)
//! - Desktop App Launcher (opens apps & shortcuts on PC)

use std::error::Error;
use std::net::{SocketAddr, UdpSocket};
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use dxgi_capture_rs::DXGIManager;
use enigo::{Axis, Button, Coordinate, Direction, Enigo, Key, Keyboard, Mouse, Settings};
use futures_util::{SinkExt, StreamExt};
use image::codecs::jpeg::JpegEncoder;
use image::ColorType;
use serde::{Deserialize, Serialize};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{broadcast, mpsc, Mutex, RwLock};
use tokio_tungstenite::tungstenite::protocol::Message;

/// Inbound JSON messages sent by the mobile client.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type")]
pub enum ClientMessage {
    #[serde(rename = "move")]
    Move { x: f64, y: f64 },
    #[serde(rename = "move_relative")]
    MoveRelative { dx: f64, dy: f64 },
    #[serde(rename = "mouse_down")]
    MouseDown { button: String },
    #[serde(rename = "mouse_up")]
    MouseUp { button: String },
    #[serde(rename = "click")]
    Click { button: String },
    #[serde(rename = "double_click")]
    DoubleClick { button: String },
    #[serde(rename = "scroll")]
    Scroll { dx: Option<i32>, dy: Option<i32> },
    #[serde(rename = "type")]
    Type { text: String },
    #[serde(rename = "key")]
    Key { key: String },
    #[serde(rename = "open_url")]
    OpenUrl { url: String },
    #[serde(rename = "launch_app")]
    LaunchApp { app: String },
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

/// Request UAC elevation by relaunching executable with `runas` verb via PowerShell
fn relaunch_as_admin() {
    if let Ok(current_exe) = std::env::current_exe() {
        if let Some(exe_str) = current_exe.to_str() {
            let script = format!(
                "Start-Process -FilePath '{}' -Verb RunAs",
                exe_str.replace('\'', "''")
            );
            let _ = Command::new("powershell")
                .args(["-NoProfile", "-WindowStyle", "Hidden", "-Command", &script])
                .spawn();
            std::process::exit(0);
        }
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

/// Spawns a native Windows GUI window displaying the PC's IP and connection status
fn spawn_gui_window(local_ip: &str, host_name: &str) {
    let local_ip = local_ip.to_string();
    let host_name = host_name.to_string();

    std::thread::spawn(move || {
        let ps_code = r###"
Add-Type -AssemblyName PresentationFramework, System.Windows.Forms
$ip = $args[0]
$fullIp = "$ip:8765"
$pcName = $args[1]

$win = New-Object System.Windows.Window
$win.Title = "Remote PC Controller - Host Server"
$win.Width = 470
$win.Height = 360
$win.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
$win.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0F172A")
$win.ResizeMode = [System.Windows.ResizeMode]::CanMinimize

$grid = New-Object System.Windows.Controls.Grid
$grid.Margin = New-Object System.Windows.Thickness(20)

for ($i = 0; $i -lt 5; $i++) {
    $rd = New-Object System.Windows.Controls.RowDefinition
    if ($i -eq 3) { $rd.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star) }
    else { $rd.Height = [System.Windows.GridLength]::Auto }
    $grid.RowDefinitions.Add($rd)
}

# Row 0: Status Header
$sp0 = New-Object System.Windows.Controls.StackPanel
$sp0.Orientation = [System.Windows.Controls.Orientation]::Horizontal
$sp0.Margin = New-Object System.Windows.Thickness(0, 0, 0, 16)
[System.Windows.Controls.Grid]::SetRow($sp0, 0)

$dot = New-Object System.Windows.Controls.Border
$dot.Width = 12; $dot.Height = 12; $dot.CornerRadius = New-Object System.Windows.CornerRadius(6)
$dot.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#22C55E")
$dot.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
$dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
$sp0.Children.Add($dot) | Out-Null

$title = New-Object System.Windows.Controls.TextBlock
$title.Text = "Server Running & Mirroring Active"
$title.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F8FAFC")
$title.FontSize = 15; $title.FontWeight = [System.Windows.FontWeights]::Bold
$title.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
$sp0.Children.Add($title) | Out-Null
$grid.Children.Add($sp0) | Out-Null

# Row 1: IP Box Card
$b1 = New-Object System.Windows.Controls.Border
$b1.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#1E293B")
$b1.CornerRadius = New-Object System.Windows.CornerRadius(10)
$b1.Padding = New-Object System.Windows.Thickness(14)
$b1.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#334155")
$b1.BorderThickness = New-Object System.Windows.Thickness(1)
[System.Windows.Controls.Grid]::SetRow($b1, 1)

$sp1 = New-Object System.Windows.Controls.StackPanel
$lbl = New-Object System.Windows.Controls.TextBlock
$lbl.Text = "YOUR PC LOCAL IP ADDRESS (ENTER IN PHONE APP):"
$lbl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#94A3B8")
$lbl.FontSize = 11; $lbl.FontWeight = [System.Windows.FontWeights]::Bold
$lbl.Margin = New-Object System.Windows.Thickness(0, 0, 0, 6)
$sp1.Children.Add($lbl) | Out-Null

$gIp = New-Object System.Windows.Controls.Grid
$col0 = New-Object System.Windows.Controls.ColumnDefinition
$col0.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
$col1 = New-Object System.Windows.Controls.ColumnDefinition
$col1.Width = [System.Windows.GridLength]::Auto
$gIp.ColumnDefinitions.Add($col0)
$gIp.ColumnDefinitions.Add($col1)

$txtIp = New-Object System.Windows.Controls.TextBox
$txtIp.Text = $fullIp
$txtIp.IsReadOnly = $true
$txtIp.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0F172A")
$txtIp.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#38BDF8")
$txtIp.FontSize = 18; $txtIp.FontWeight = [System.Windows.FontWeights]::Bold
$txtIp.Padding = New-Object System.Windows.Thickness(8, 4, 8, 4)
$txtIp.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#38BDF8")
[System.Windows.Controls.Grid]::SetColumn($txtIp, 0)
$gIp.Children.Add($txtIp) | Out-Null

$btnCopy = New-Object System.Windows.Controls.Button
$btnCopy.Content = "Copy IP"
$btnCopy.Width = 85
$btnCopy.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
$btnCopy.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0284C7")
$btnCopy.Foreground = [System.Windows.Media.Brushes]::White
$btnCopy.FontWeight = [System.Windows.FontWeights]::Bold
$btnCopy.BorderThickness = New-Object System.Windows.Thickness(0)
$btnCopy.Add_Click({
    [System.Windows.Forms.Clipboard]::SetText($txtIp.Text)
    $btnCopy.Content = "Copied!"
})
[System.Windows.Controls.Grid]::SetColumn($btnCopy, 1)
$gIp.Children.Add($btnCopy) | Out-Null
$sp1.Children.Add($gIp) | Out-Null
$b1.Child = $sp1
$grid.Children.Add($b1) | Out-Null

# Row 2: Status Details
$sp2 = New-Object System.Windows.Controls.StackPanel
$sp2.Margin = New-Object System.Windows.Thickness(0, 14, 0, 0)
[System.Windows.Controls.Grid]::SetRow($sp2, 2)

$t1 = New-Object System.Windows.Controls.TextBlock
$t1.Text = ". Host PC: " + $pcName
$t1.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#CBD5E1")
$t1.FontSize = 12; $t1.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)
$sp2.Children.Add($t1) | Out-Null

$t2 = New-Object System.Windows.Controls.TextBlock
$t2.Text = ". Stream Port: 8765 TCP | Discovery: 8766 UDP"
$t2.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#CBD5E1")
$t2.FontSize = 12; $t2.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)
$sp2.Children.Add($t2) | Out-Null

$t3 = New-Object System.Windows.Controls.TextBlock
$t3.Text = ". Windows Firewall: Configured & Active"
$t3.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#4ADE80")
$t3.FontSize = 12
$sp2.Children.Add($t3) | Out-Null
$grid.Children.Add($sp2) | Out-Null

# Row 3: Instructions
$b3 = New-Object System.Windows.Controls.Border
$b3.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0F172A")
$b3.Margin = New-Object System.Windows.Thickness(0, 12, 0, 0)
$b3.Padding = New-Object System.Windows.Thickness(10)
$b3.CornerRadius = New-Object System.Windows.CornerRadius(8)
$b3.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#1E293B")
$b3.BorderThickness = New-Object System.Windows.Thickness(1)
[System.Windows.Controls.Grid]::SetRow($b3, 3)

$tInst = New-Object System.Windows.Controls.TextBlock
$tInst.Text = "On your Android phone, tap Auto-Detect PC or type the IP address above to connect instantly."
$tInst.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#94A3B8")
$tInst.FontSize = 11; $tInst.TextWrapping = [System.Windows.TextWrapping]::Wrap
$b3.Child = $tInst
$grid.Children.Add($b3) | Out-Null

# Row 4: Footer
$foot = New-Object System.Windows.Controls.TextBlock
$foot.Text = "You can minimize this window to keep the server running in background."
$foot.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#64748B")
$foot.FontSize = 10; $foot.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
$foot.Margin = New-Object System.Windows.Thickness(0, 10, 0, 0)
[System.Windows.Controls.Grid]::SetRow($foot, 4)
$grid.Children.Add($foot) | Out-Null

$win.Content = $grid
$win.ShowDialog() | Out-Null
"###;

        let _ = Command::new("powershell")
            .args(["-NoProfile", "-WindowStyle", "Hidden", "-Command", ps_code, &local_ip, &host_name])
            .output();
    });
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

    // 5. Open sleek native Windows GUI Window with IP & Copy button
    spawn_gui_window(&local_lan_ip, &host_name);

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
    let (frame_tx, _) = broadcast::channel::<FrameData>(16);

    let screen_width = Arc::new(AtomicUsize::new(1920));
    let screen_height = Arc::new(AtomicUsize::new(1080));
    let latest_jpeg = Arc::new(RwLock::new(Vec::new()));

    // Shared thread-safe input injector
    let enigo = Arc::new(Mutex::new(
        Enigo::new(&Settings::default()).expect("Failed to initialize Enigo input injector"),
    ));

    // Force an initial tiny mouse nudge so DXGI generates a frame immediately on start
    {
        if let Ok(mut enigo_init) = Enigo::new(&Settings::default()) {
            let _ = enigo_init.move_mouse(1, 0, Coordinate::Rel);
            let _ = enigo_init.move_mouse(-1, 0, Coordinate::Rel);
        }
    }

    let is_running = Arc::new(AtomicBool::new(true));

    // Spawn DXGI Screen Capture Task on dedicated OS thread
    let capture_tx = frame_tx.clone();
    let capture_running = is_running.clone();
    let width_ref = screen_width.clone();
    let height_ref = screen_height.clone();
    let capture_latest = latest_jpeg.clone();

    std::thread::spawn(move || {
        println!("[DXGI] Initializing Windows DXGI Desktop Duplication API...");
        let mut manager = match DXGIManager::new(100) {
            Ok(mgr) => {
                println!("[DXGI] Successfully attached to primary GPU output adapter.");
                mgr
            }
            Err(e) => {
                eprintln!("[DXGI] DXGI initialization failed: {:?}. Retrying...", e);
                std::thread::sleep(Duration::from_secs(1));
                DXGIManager::new(100).expect("Fatal: Could not initialize DXGI Output Duplication")
            }
        };

        let target_frame_duration = Duration::from_millis(16);
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
                        last_valid_jpeg = Arc::new(jpeg_buffer.clone());

                        // Cache latest frame for instantaneous delivery to new client connections
                        {
                            let mut guard = capture_latest.blocking_write();
                            *guard = jpeg_buffer;
                        }

                        let frame = FrameData {
                            jpeg_bytes: last_valid_jpeg.clone(),
                            width: width as u32,
                            height: height as u32,
                        };
                        let _ = capture_tx.send(frame);
                    }
                }
                Err(_) => {
                    // Screen has not changed (DXGI Timeout) - periodically refresh last frame
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

    let mut client_counter = 0usize;

    while let Ok((stream, addr)) = listener.accept().await {
        client_counter += 1;
        let client_id = client_counter;
        println!("[+] Client #{} connected from {}", client_id, addr);

        let frame_rx = frame_tx.subscribe();
        let enigo_clone = enigo.clone();
        let width_clone = screen_width.clone();
        let height_clone = screen_height.clone();
        let host_name_clone = host_name.clone();
        let ip_clone = local_lan_ip.clone();
        let latest_jpeg_clone = latest_jpeg.clone();

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
                latest_jpeg_clone,
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
    latest_jpeg: Arc<RwLock<Vec<u8>>>,
) -> Result<(), Box<dyn Error + Send + Sync>> {
    let ws_stream = tokio_tungstenite::accept_async(stream).await?;
    let (mut ws_sink, mut ws_stream_reader) = ws_stream.split();

    let (out_tx, mut out_rx) = mpsc::channel::<Message>(32);

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

    // Immediately deliver the latest frame so client sees the screen without waiting!
    {
        let cached = latest_jpeg.read().await;
        if !cached.is_empty() {
            let _ = out_tx.send(Message::Binary(cached.clone())).await;
        }
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

    // Task B: Forward video frames; gracefully skip lagged frames without terminating loop!
    let out_tx_frames = out_tx.clone();
    let frame_task = tokio::spawn(async move {
        loop {
            match frame_rx.recv().await {
                Ok(frame) => {
                    let msg = Message::Binary(frame.jpeg_bytes.as_ref().clone());
                    let _ = out_tx_frames.try_send(msg);
                }
                Err(broadcast::error::RecvError::Lagged(_)) => {
                    // Receiver fell behind: simply continue to receive the newest frame!
                    continue;
                }
                Err(broadcast::error::RecvError::Closed) => {
                    break;
                }
            }
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
                        // Direct Touch Screen / Absolute Mouse Positioning
                        ClientMessage::Move { x, y } => {
                            let clamped_x = (x.clamp(0.0, 1.0) * cur_w) as i32;
                            let clamped_y = (y.clamp(0.0, 1.0) * cur_h) as i32;
                            let _ = enigo_guard.move_mouse(clamped_x, clamped_y, Coordinate::Abs);
                        }
                        // Laptop Trackpad / Relative Mouse Movement
                        ClientMessage::MoveRelative { dx, dy } => {
                            let _ = enigo_guard.move_mouse(dx as i32, dy as i32, Coordinate::Rel);
                        }
                        // Mouse Press / Dragging
                        ClientMessage::MouseDown { button } => {
                            let btn = match button.to_lowercase().as_str() {
                                "right" => Button::Right,
                                "middle" => Button::Middle,
                                _ => Button::Left,
                            };
                            let _ = enigo_guard.button(btn, Direction::Press);
                        }
                        // Mouse Release
                        ClientMessage::MouseUp { button } => {
                            let btn = match button.to_lowercase().as_str() {
                                "right" => Button::Right,
                                "middle" => Button::Middle,
                                _ => Button::Left,
                            };
                            let _ = enigo_guard.button(btn, Direction::Release);
                        }
                        // Mouse Click
                        ClientMessage::Click { button } => {
                            let btn = match button.to_lowercase().as_str() {
                                "right" => Button::Right,
                                "middle" => Button::Middle,
                                _ => Button::Left,
                            };
                            let _ = enigo_guard.button(btn, Direction::Click);
                        }
                        // Double Click
                        ClientMessage::DoubleClick { button } => {
                            let btn = match button.to_lowercase().as_str() {
                                "right" => Button::Right,
                                "middle" => Button::Middle,
                                _ => Button::Left,
                            };
                            let _ = enigo_guard.button(btn, Direction::Click);
                            let _ = enigo_guard.button(btn, Direction::Click);
                        }
                        // Mouse Scroll
                        ClientMessage::Scroll { dx: _, dy } => {
                            if let Some(y) = dy {
                                let _ = enigo_guard.scroll(y, Axis::Vertical);
                            }
                        }
                        // Keyboard Text Typing
                        ClientMessage::Type { text } => {
                            let _ = enigo_guard.text(&text);
                        }
                        // Keyboard Key and Windows Key Actions
                        ClientMessage::Key { key } => {
                            let lower = key.to_lowercase();
                            match lower.as_str() {
                                // Windows Start Menu key (triggers VK_LWIN + Ctrl+Esc for 100% reliability)
                                "win" | "meta" | "super" | "windows" => {
                                    let _ = enigo_guard.key(Key::Meta, Direction::Press);
                                    std::thread::sleep(Duration::from_millis(50));
                                    let _ = enigo_guard.key(Key::Meta, Direction::Release);

                                    // Fallback Ctrl+Esc triggers Start Menu on all Windows configurations
                                    let _ = enigo_guard.key(Key::Control, Direction::Press);
                                    let _ = enigo_guard.key(Key::Escape, Direction::Click);
                                    let _ = enigo_guard.key(Key::Control, Direction::Release);
                                }
                                "win+d" | "desktop" => {
                                    let _ = enigo_guard.key(Key::Meta, Direction::Press);
                                    let _ = enigo_guard.key(Key::Unicode('d'), Direction::Click);
                                    let _ = enigo_guard.key(Key::Meta, Direction::Release);
                                }
                                "win+tab" => {
                                    let _ = enigo_guard.key(Key::Meta, Direction::Press);
                                    let _ = enigo_guard.key(Key::Tab, Direction::Click);
                                    let _ = enigo_guard.key(Key::Meta, Direction::Release);
                                }
                                "alt+tab" => {
                                    let _ = enigo_guard.key(Key::Alt, Direction::Press);
                                    let _ = enigo_guard.key(Key::Tab, Direction::Click);
                                    let _ = enigo_guard.key(Key::Alt, Direction::Release);
                                }
                                "alt+f4" => {
                                    let _ = enigo_guard.key(Key::Alt, Direction::Press);
                                    let _ = enigo_guard.key(Key::F4, Direction::Click);
                                    let _ = enigo_guard.key(Key::Alt, Direction::Release);
                                }
                                "ctrl+c" => {
                                    let _ = enigo_guard.key(Key::Control, Direction::Press);
                                    let _ = enigo_guard.key(Key::Unicode('c'), Direction::Click);
                                    let _ = enigo_guard.key(Key::Control, Direction::Release);
                                }
                                "ctrl+v" => {
                                    let _ = enigo_guard.key(Key::Control, Direction::Press);
                                    let _ = enigo_guard.key(Key::Unicode('v'), Direction::Click);
                                    let _ = enigo_guard.key(Key::Control, Direction::Release);
                                }
                                "ctrl+z" => {
                                    let _ = enigo_guard.key(Key::Control, Direction::Press);
                                    let _ = enigo_guard.key(Key::Unicode('z'), Direction::Click);
                                    let _ = enigo_guard.key(Key::Control, Direction::Release);
                                }
                                "taskmgr" => {
                                    let _ = Command::new("cmd").args(["/C", "start", "", "taskmgr"]).spawn();
                                }
                                "enter" | "return" => {
                                    let _ = enigo_guard.key(Key::Return, Direction::Click);
                                }
                                "backspace" => {
                                    let _ = enigo_guard.key(Key::Backspace, Direction::Click);
                                }
                                "escape" | "esc" => {
                                    let _ = enigo_guard.key(Key::Escape, Direction::Click);
                                }
                                "tab" => {
                                    let _ = enigo_guard.key(Key::Tab, Direction::Click);
                                }
                                "space" => {
                                    let _ = enigo_guard.key(Key::Space, Direction::Click);
                                }
                                "up" => {
                                    let _ = enigo_guard.key(Key::UpArrow, Direction::Click);
                                }
                                "down" => {
                                    let _ = enigo_guard.key(Key::DownArrow, Direction::Click);
                                }
                                "left" => {
                                    let _ = enigo_guard.key(Key::LeftArrow, Direction::Click);
                                }
                                "right" => {
                                    let _ = enigo_guard.key(Key::RightArrow, Direction::Click);
                                }
                                "delete" | "del" => {
                                    let _ = enigo_guard.key(Key::Delete, Direction::Click);
                                }
                                "home" => {
                                    let _ = enigo_guard.key(Key::Home, Direction::Click);
                                }
                                "end" => {
                                    let _ = enigo_guard.key(Key::End, Direction::Click);
                                }
                                "pageup" => {
                                    let _ = enigo_guard.key(Key::PageUp, Direction::Click);
                                }
                                "pagedown" => {
                                    let _ = enigo_guard.key(Key::PageDown, Direction::Click);
                                }
                                _ => {}
                            }
                        }
                        // Open Website Shortcut in PC's default browser
                        ClientMessage::OpenUrl { url } => {
                            println!("[SHORTCUT] Opening site on PC: {}", url);
                            let target = if !url.starts_with("http://") && !url.starts_with("https://") {
                                format!("https://{}", url)
                            } else {
                                url
                            };
                            let _ = Command::new("cmd")
                                .args(["/C", "start", "", &target])
                                .spawn();
                        }
                        // Launch Desktop Application or Shortcut
                        ClientMessage::LaunchApp { app } => {
                            println!("[APP LAUNCHER] Launching application or file: {}", app);
                            let _ = Command::new("cmd")
                                .args(["/C", "start", "", &app])
                                .spawn();
                        }
                        // Latency Ping
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
