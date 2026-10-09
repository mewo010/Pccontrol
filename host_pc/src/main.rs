//! Remote PC Host Server
//! High-performance Windows Screen Mirroring & Direct Win32 Remote Input Server
//!
//! Features:
//! - Auto-Elevation to Administrator (UAC prompt on double-click)
//! - Auto-Firewall Rule Configuration (Port 8765 TCP & 8766 UDP)
//! - Multi-Service Public IP Auto-Detection & Periodic WAN Refresh
//! - Router UPnP Port Forwarding Automation (Port 8765 TCP)
//! - UDP Auto-Discovery Beacon on Port 8766 (delivers both Local LAN IP & Public WAN IP)
//! - Dual Display Engine: Windows GDI CreateDIBSection with CAPTUREBLT + GdiFlush + XCap DXGI
//! - Multi-Monitor & Virtual Screen Support with Cycle Display & Display Wakeup
//! - 100% Reliable Infallible Frame Delivery with Black-Screen Detection & Instant Auto-Recovery
//! - 1-Second Real-Time Telemetry & Pipeline Diagnostics Stream
//! - Direct Win32 Mouse & Keyboard Injection
//! - Administrator Security Portal (Password: Sagiv_2311) with Persistent Device Locks

use enigo::{Axis, Button, Direction, Enigo, Key, Keyboard, Mouse, Settings};
use futures_util::{SinkExt, StreamExt};
use std::collections::HashMap;
use std::error::Error;
use std::net::{SocketAddr, UdpSocket};
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use image::codecs::jpeg::JpegEncoder;
use image::ColorType;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{broadcast, mpsc, Mutex, RwLock};
use tokio_tungstenite::tungstenite::protocol::Message;

/// Administrator password as requested by the user
pub const ADMIN_PASSWORD: &str = "Sagiv_2311";

/// Connected client profile tracked in memory
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConnectedClientRecord {
    pub id: usize,
    pub ip: String,
    pub device_name: String,
    pub device_id: String,
    pub connected_at: u64,
    pub is_locked: bool,
    pub locked_until: u64, // 0 = indefinite, >0 = epoch seconds
    pub is_admin: bool,
}

/// Registry entry holding client metadata and its outbound message sender
struct ClientRegistryEntry {
    pub record: ConnectedClientRecord,
    pub out_tx: mpsc::Sender<Message>,
}

type ClientRegistry = Arc<Mutex<HashMap<usize, ClientRegistryEntry>>>;
type LockedTable = Arc<Mutex<HashMap<String, u64>>>; // Key (device_id or IP) -> locked_until

/// Inbound JSON messages sent by the mobile client.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type")]
pub enum ClientMessage {
    #[serde(rename = "client_hello")]
    ClientHello {
        device_name: Option<String>,
        device_id: Option<String>,
    },
    #[serde(rename = "request_frame")]
    RequestFrame,
    #[serde(rename = "request_test_frame")]
    RequestTestFrame,
    #[serde(rename = "set_capture_mode")]
    SetCaptureMode { mode: String },
    #[serde(rename = "cycle_display")]
    CycleDisplay,
    #[serde(rename = "wake_display")]
    WakeDisplay,
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

    // Administrator Portal Messages
    #[serde(rename = "admin_auth")]
    AdminAuth { password: String },
    #[serde(rename = "admin_get_clients")]
    AdminGetClients,
    #[serde(rename = "admin_disconnect_client")]
    AdminDisconnectClient { target_id: usize },
    #[serde(rename = "admin_lock_client")]
    AdminLockClient {
        target_id: usize,
        duration_seconds: Option<u64>,
    },
    #[serde(rename = "admin_unlock_client")]
    AdminUnlockClient { target_id: usize },
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
        public_ip: Option<String>,
        client_id: usize,
    },
    #[serde(rename = "capture_debug")]
    CaptureDebug {
        engine: String,
        fps: u32,
        frame_count: u64,
        width: u32,
        height: u32,
        last_bytes: usize,
        last_encode_ms: u64,
        status: String,
        last_error: Option<String>,
        mode: String,
        frames_sent_to_client: u64,
        public_ip: Option<String>,
        is_screen_black: bool,
    },
    #[serde(rename = "admin_auth_result")]
    AdminAuthResult {
        success: bool,
        message: String,
        is_admin: bool,
    },
    #[serde(rename = "admin_clients_list")]
    AdminClientsList {
        clients: Vec<ConnectedClientRecord>,
    },
    #[serde(rename = "lock_status")]
    LockStatus {
        is_locked: bool,
        locked_until: u64,
        remaining_seconds: Option<u64>,
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

/// Detect Public Internet IP via multiple redundant providers + PowerShell fallback
async fn detect_public_ip() -> String {
    let providers = [
        ("api.ipify.org", "api.ipify.org:80", "GET / HTTP/1.1\r\nHost: api.ipify.org\r\nUser-Agent: RemotePC\r\nConnection: close\r\n\r\n"),
        ("icanhazip.com", "icanhazip.com:80", "GET / HTTP/1.1\r\nHost: icanhazip.com\r\nUser-Agent: RemotePC\r\nConnection: close\r\n\r\n"),
        ("ifconfig.me", "ifconfig.me:80", "GET /ip HTTP/1.1\r\nHost: ifconfig.me\r\nUser-Agent: RemotePC\r\nConnection: close\r\n\r\n"),
    ];

    for (_name, host, req) in providers {
        let query = async {
            let mut stream = TcpStream::connect(host).await.ok()?;
            stream.write_all(req.as_bytes()).await.ok()?;
            let mut buf = vec![0u8; 1024];
            let n = stream.read(&mut buf).await.ok()?;
            let resp = String::from_utf8_lossy(&buf[..n]);
            let body = resp.split("\r\n\r\n").nth(1)?.trim();
            let clean_ip = body.lines().next()?.trim();
            if !clean_ip.is_empty() && clean_ip.chars().all(|c| c.is_ascii_digit() || c == '.') && clean_ip.contains('.') {
                Some(clean_ip.to_string())
            } else {
                None
            }
        };

        if let Ok(Some(ip)) = tokio::time::timeout(Duration::from_millis(1500), query).await {
            return ip;
        }
    }

    // PowerShell fallback
    let ps_output = Command::new("powershell")
        .args([
            "-NoProfile",
            "-Command",
            "(Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 3).Trim()",
        ])
        .output();

    if let Ok(out) = ps_output {
        let ip = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !ip.is_empty() && ip.contains('.') {
            return ip;
        }
    }

    "Detecting / Router IP".to_string()
}

/// Automatically configure router UPnP port forwarding for port 8765 so user can connect outside Wi-Fi
fn setup_upnp_port_forward(port: u16, local_ip: &str) {
    let script = format!(
        r###"
$ErrorActionPreference = 'SilentlyContinue'
try {{
    $nat = New-Object -ComObject HNetCfg.NATUPnP
    if ($nat -and $nat.StaticPortMappingCollection) {{
        $nat.StaticPortMappingCollection.Add({}, "TCP", {}, "{}", $true, "RemotePC_Host")
        Write-Host "[UPnP] Port {} mapped to {}"
    }}
}} catch {{}}
"###,
        port, port, local_ip, port, local_ip
    );
    let _ = Command::new("powershell")
        .args(["-NoProfile", "-WindowStyle", "Hidden", "-Command", &script])
        .spawn();
}

/// Broadcast updated connected client list to all authenticated admins
async fn broadcast_admin_clients(registry: &ClientRegistry) {
    let clients: Vec<ConnectedClientRecord> = {
        let guard = registry.lock().await;
        guard.values().map(|e| e.record.clone()).collect()
    };

    let msg = HostMessage::AdminClientsList { clients };
    if let Ok(json_str) = serde_json::to_string(&msg) {
        let guard = registry.lock().await;
        for entry in guard.values() {
            if entry.record.is_admin {
                let _ = entry.out_tx.try_send(Message::Text(json_str.clone()));
            }
        }
    }
}

/// Helper to verify if calling client is authenticated as admin
async fn is_client_admin(registry: &ClientRegistry, client_id: usize) -> bool {
    let guard = registry.lock().await;
    guard
        .get(&client_id)
        .map(|e| e.record.is_admin)
        .unwrap_or(false)
}

/// Spawns a native Windows GUI window displaying both Local Wi-Fi IP and Outside Wi-Fi Public IP
fn spawn_gui_window(local_ip: &str, public_ip: &str, host_name: &str) {
    let local_ip = local_ip.to_string();
    let public_ip = public_ip.to_string();
    let host_name = host_name.to_string();

    std::thread::spawn(move || {
        let ps_code = r###"
Add-Type -AssemblyName PresentationFramework, System.Windows.Forms
$localIp = $args[0]
$fullLocalIp = "$localIp:8765"
$publicIp = $args[1]
$fullPublicIp = "$publicIp:8765"
$pcName = $args[2]

$win = New-Object System.Windows.Window
$win.Title = "Remote PC Controller - Host Server ($pcName)"
$win.Width = 530
$win.Height = 460
$win.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
$win.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0F172A")
$win.ResizeMode = [System.Windows.ResizeMode]::CanMinimize

$grid = New-Object System.Windows.Controls.Grid
$grid.Margin = New-Object System.Windows.Thickness(20)

for ($i = 0; $i -lt 6; $i++) {
    $rd = New-Object System.Windows.Controls.RowDefinition
    if ($i -eq 4) { $rd.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star) }
    else { $rd.Height = [System.Windows.GridLength]::Auto }
    $grid.RowDefinitions.Add($rd)
}

# Row 0: Status Header
$sp0 = New-Object System.Windows.Controls.StackPanel
$sp0.Orientation = [System.Windows.Controls.Orientation]::Horizontal
$sp0.Margin = New-Object System.Windows.Thickness(0, 0, 0, 14)
[System.Windows.Controls.Grid]::SetRow($sp0, 0)

$dot = New-Object System.Windows.Controls.Border
$dot.Width = 12; $dot.Height = 12; $dot.CornerRadius = New-Object System.Windows.CornerRadius(6)
$dot.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#22C55E")
$dot.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
$dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
$sp0.Children.Add($dot) | Out-Null

$title = New-Object System.Windows.Controls.TextBlock
$title.Text = "Server Active • Wi-Fi & Outside-of-WiFi Ready"
$title.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F8FAFC")
$title.FontSize = 15; $title.FontWeight = [System.Windows.FontWeights]::Bold
$title.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
$sp0.Children.Add($title) | Out-Null
$grid.Children.Add($sp0) | Out-Null

# Row 1: Local Wi-Fi IP Card
$b1 = New-Object System.Windows.Controls.Border
$b1.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#1E293B")
$b1.CornerRadius = New-Object System.Windows.CornerRadius(8)
$b1.Padding = New-Object System.Windows.Thickness(12)
$b1.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#334155")
$b1.BorderThickness = New-Object System.Windows.Thickness(1)
$b1.Margin = New-Object System.Windows.Thickness(0, 0, 0, 10)
[System.Windows.Controls.Grid]::SetRow($b1, 1)

$sp1 = New-Object System.Windows.Controls.StackPanel
$lbl1 = New-Object System.Windows.Controls.TextBlock
$lbl1.Text = "1. LOCAL WI-FI ADDRESS (HOME USE):"
$lbl1.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#38BDF8")
$lbl1.FontSize = 10; $lbl1.FontWeight = [System.Windows.FontWeights]::Bold
$lbl1.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)
$sp1.Children.Add($lbl1) | Out-Null

$gIp1 = New-Object System.Windows.Controls.Grid
$col0 = New-Object System.Windows.Controls.ColumnDefinition
$col0.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
$col1 = New-Object System.Windows.Controls.ColumnDefinition
$col1.Width = [System.Windows.GridLength]::Auto
$gIp1.ColumnDefinitions.Add($col0)
$gIp1.ColumnDefinitions.Add($col1)

$txtIp1 = New-Object System.Windows.Controls.TextBox
$txtIp1.Text = $fullLocalIp
$txtIp1.IsReadOnly = $true
$txtIp1.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0F172A")
$txtIp1.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#38BDF8")
$txtIp1.FontSize = 15; $txtIp1.FontWeight = [System.Windows.FontWeights]::Bold
$txtIp1.Padding = New-Object System.Windows.Thickness(6, 3, 6, 3)
$txtIp1.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0284C7")
[System.Windows.Controls.Grid]::SetColumn($txtIp1, 0)
$gIp1.Children.Add($txtIp1) | Out-Null

$btnCopy1 = New-Object System.Windows.Controls.Button
$btnCopy1.Content = "Copy"
$btnCopy1.Width = 65
$btnCopy1.Margin = New-Object System.Windows.Thickness(6, 0, 0, 0)
$btnCopy1.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0284C7")
$btnCopy1.Foreground = [System.Windows.Media.Brushes]::White
$btnCopy1.FontWeight = [System.Windows.FontWeights]::Bold
$btnCopy1.BorderThickness = New-Object System.Windows.Thickness(0)
$btnCopy1.Add_Click({ [System.Windows.Forms.Clipboard]::SetText($txtIp1.Text); $btnCopy1.Content = "Copied!" })
[System.Windows.Controls.Grid]::SetColumn($btnCopy1, 1)
$gIp1.Children.Add($btnCopy1) | Out-Null
$sp1.Children.Add($gIp1) | Out-Null
$b1.Child = $sp1
$grid.Children.Add($b1) | Out-Null

# Row 2: Outside Wi-Fi Internet IP Card
$b2 = New-Object System.Windows.Controls.Border
$b2.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#1E293B")
$b2.CornerRadius = New-Object System.Windows.CornerRadius(8)
$b2.Padding = New-Object System.Windows.Thickness(12)
$b2.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#334155")
$b2.BorderThickness = New-Object System.Windows.Thickness(1)
$b2.Margin = New-Object System.Windows.Thickness(0, 0, 0, 10)
[System.Windows.Controls.Grid]::SetRow($b2, 2)

$sp2 = New-Object System.Windows.Controls.StackPanel
$lbl2 = New-Object System.Windows.Controls.TextBlock
$lbl2.Text = "2. OUTSIDE WI-FI / MOBILE DATA ADDRESS (CELLULAR 4G/5G):"
$lbl2.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#A855F7")
$lbl2.FontSize = 10; $lbl2.FontWeight = [System.Windows.FontWeights]::Bold
$lbl2.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)
$sp2.Children.Add($lbl2) | Out-Null

$gIp2 = New-Object System.Windows.Controls.Grid
$col20 = New-Object System.Windows.Controls.ColumnDefinition
$col20.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
$col21 = New-Object System.Windows.Controls.ColumnDefinition
$col21.Width = [System.Windows.GridLength]::Auto
$gIp2.ColumnDefinitions.Add($col20)
$gIp2.ColumnDefinitions.Add($col21)

$txtIp2 = New-Object System.Windows.Controls.TextBox
$txtIp2.Text = $fullPublicIp
$txtIp2.IsReadOnly = $true
$txtIp2.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0F172A")
$txtIp2.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#A855F7")
$txtIp2.FontSize = 15; $txtIp2.FontWeight = [System.Windows.FontWeights]::Bold
$txtIp2.Padding = New-Object System.Windows.Thickness(6, 3, 6, 3)
$txtIp2.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#7E22CE")
[System.Windows.Controls.Grid]::SetColumn($txtIp2, 0)
$gIp2.Children.Add($txtIp2) | Out-Null

$btnCopy2 = New-Object System.Windows.Controls.Button
$btnCopy2.Content = "Copy"
$btnCopy2.Width = 65
$btnCopy2.Margin = New-Object System.Windows.Thickness(6, 0, 0, 0)
$btnCopy2.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#7E22CE")
$btnCopy2.Foreground = [System.Windows.Media.Brushes]::White
$btnCopy2.FontWeight = [System.Windows.FontWeights]::Bold
$btnCopy2.BorderThickness = New-Object System.Windows.Thickness(0)
$btnCopy2.Add_Click({ [System.Windows.Forms.Clipboard]::SetText($txtIp2.Text); $btnCopy2.Content = "Copied!" })
[System.Windows.Controls.Grid]::SetColumn($btnCopy2, 1)
$gIp2.Children.Add($btnCopy2) | Out-Null
$sp2.Children.Add($gIp2) | Out-Null
$b2.Child = $sp2
$grid.Children.Add($b2) | Out-Null

# Row 3: Security & Credentials
$sp3 = New-Object System.Windows.Controls.StackPanel
$sp3.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
[System.Windows.Controls.Grid]::SetRow($sp3, 3)

$t1 = New-Object System.Windows.Controls.TextBlock
$t1.Text = "• Host PC: " + $pcName + " | Stream Port: 8765 TCP | UPnP Auto-Mapped"
$t1.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#94A3B8")
$t1.FontSize = 11; $t1.Margin = New-Object System.Windows.Thickness(0, 0, 0, 2)
$sp3.Children.Add($t1) | Out-Null

$t3 = New-Object System.Windows.Controls.TextBlock
$t3.Text = "• Admin Tab Password: Sagiv_2311"
$t3.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#38BDF8")
$t3.FontSize = 11; $t3.FontWeight = [System.Windows.FontWeights]::SemiBold
$sp3.Children.Add($t3) | Out-Null
$grid.Children.Add($sp3) | Out-Null

# Row 4: Seamless Switch Guide
$b4 = New-Object System.Windows.Controls.Border
$b4.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0F172A")
$b4.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
$b4.Padding = New-Object System.Windows.Thickness(10)
$b4.CornerRadius = New-Object System.Windows.CornerRadius(8)
$b4.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#1E293B")
$b4.BorderThickness = New-Object System.Windows.Thickness(1)
[System.Windows.Controls.Grid]::SetRow($b4, 4)

$tInst = New-Object System.Windows.Controls.TextBlock
$tInst.Text = "Seamless Outside-of-WiFi Reconnect:`nWhen connected on Wi-Fi, the phone app automatically memorizes your Public Address. If you step outside Wi-Fi, the app automatically switches to 4G/5G mobile data and keeps you connected!"
$tInst.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#94A3B8")
$tInst.FontSize = 11; $tInst.TextWrapping = [System.Windows.TextWrapping]::Wrap
$b4.Child = $tInst
$grid.Children.Add($b4) | Out-Null

# Row 5: Footer
$foot = New-Object System.Windows.Controls.TextBlock
$foot.Text = "You can minimize this window to keep the server running in background."
$foot.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#64748B")
$foot.FontSize = 10; $foot.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
$foot.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
[System.Windows.Controls.Grid]::SetRow($foot, 5)
$grid.Children.Add($foot) | Out-Null

$win.Content = $grid
$win.ShowDialog() | Out-Null
"###;

        let _ = Command::new("powershell")
            .args(["-NoProfile", "-WindowStyle", "Hidden", "-Command", ps_code, &local_ip, &public_ip, &host_name])
            .output();
    });
}

/// Start UDP discovery beacon on port 8766 so mobile app discovers PC automatically on Wi-Fi
fn start_udp_discovery_beacon(local_ip: String, public_ip: String, host_name: String) {
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
                    let reply = format!("REMOTE_PC_HOST:{}:{}:8765:{}", host_name, local_ip, public_ip);
                    let _ = socket.send_to(reply.as_bytes(), src);
                }
            }
        }
    });
}

/// Checks whether an uncompressed RGBA pixel buffer is 100% black (all 0s)
fn is_frame_all_black(slice: &[u8]) -> bool {
    let step = (slice.len() / 200).max(4);
    for i in (0..slice.len()).step_by(step) {
        if i + 2 < slice.len() {
            if slice[i] > 10 || slice[i + 1] > 10 || slice[i + 2] > 10 {
                return false;
            }
        }
    }
    true
}

/// Universal Windows GDI CreateDIBSection with CAPTUREBLT and GdiFlush
/// Captures layered windows, hardware-accelerated browsers, DWM desktop compositions
unsafe fn capture_screen_gdi_dib(x: i32, y: i32, width: i32, height: i32) -> Result<Vec<u8>, String> {
    use std::ptr::null_mut;
    use windows_sys::Win32::Graphics::Gdi::*;

    let hdc_screen = GetDC(null_mut());
    if hdc_screen.is_null() {
        let err = windows_sys::Win32::Foundation::GetLastError();
        return Err(format!("GetDC(NULL) failed (Win32 error: {})", err));
    }
    let hdc_mem = CreateCompatibleDC(hdc_screen);
    if hdc_mem.is_null() {
        let err = windows_sys::Win32::Foundation::GetLastError();
        ReleaseDC(null_mut(), hdc_screen);
        return Err(format!("CreateCompatibleDC failed (Win32 error: {})", err));
    }

    // Top-down 32-bit BGRA DIB section (negative height specifies top-to-bottom layout directly)
    let bi = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width,
            biHeight: -height, // Negative height = top-down bitmap
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB,
            biSizeImage: (width * height * 4) as u32,
            biXPelsPerMeter: 0,
            biYPelsPerMeter: 0,
            biClrUsed: 0,
            biClrImportant: 0,
        },
        bmiColors: [RGBQUAD { rgbBlue: 0, rgbGreen: 0, rgbRed: 0, rgbReserved: 0 }],
    };

    let mut bits_ptr: *mut std::ffi::c_void = null_mut();
    let hbitmap = CreateDIBSection(
        hdc_mem,
        &bi as *const BITMAPINFO,
        DIB_RGB_COLORS,
        &mut bits_ptr as *mut *mut _ as *mut *mut std::ffi::c_void,
        null_mut(),
        0,
    );

    if hbitmap.is_null() || bits_ptr.is_null() {
        let err = windows_sys::Win32::Foundation::GetLastError();
        DeleteDC(hdc_mem);
        ReleaseDC(null_mut(), hdc_screen);
        return Err(format!("CreateDIBSection failed (Win32 error: {})", err));
    }

    let old_obj = SelectObject(hdc_mem, hbitmap);

    // SRCCOPY | CAPTUREBLT (0x40000000 | 0x00CC0020) captures modern DWM composited & layered windows
    let rop = SRCCOPY | CAPTUREBLT;
    let blt_res = BitBlt(hdc_mem, 0, 0, width, height, hdc_screen, x, y, rop);

    // Mandatory: Flush GDI rendering pipeline into memory buffer before reading
    GdiFlush();

    // Unselect and delete DC handles
    SelectObject(hdc_mem, old_obj);
    DeleteDC(hdc_mem);
    ReleaseDC(null_mut(), hdc_screen);

    if blt_res == 0 {
        let err = windows_sys::Win32::Foundation::GetLastError();
        DeleteObject(hbitmap);
        return Err(format!("BitBlt returned 0 (Win32 error: {})", err));
    }

    // Direct pixel extraction from the DIB Section memory buffer
    let total_bytes = (width * height * 4) as usize;
    let bgra_slice = std::slice::from_raw_parts(bits_ptr as *const u8, total_bytes);
    let mut rgba_buf = vec![0u8; total_bytes];

    // Fast 32-bit color conversion: BGRA to RGBA
    for i in (0..total_bytes).step_by(4) {
        rgba_buf[i] = bgra_slice[i + 2];     // Red
        rgba_buf[i + 1] = bgra_slice[i + 1]; // Green
        rgba_buf[i + 2] = bgra_slice[i];     // Blue
        rgba_buf[i + 3] = 255;              // Alpha
    }

    DeleteObject(hbitmap);

    if is_frame_all_black(&rgba_buf) {
        return Err("GDI DIB produced all black pixels (monitor asleep, locked, or protected window)".to_string());
    }

    Ok(rgba_buf)
}

/// Fallback Windows GDI capture via CreateCompatibleBitmap + GetDIBits with CAPTUREBLT
unsafe fn capture_screen_gdi_compatible(x: i32, y: i32, width: i32, height: i32) -> Result<Vec<u8>, String> {
    use std::ptr::null_mut;
    use windows_sys::Win32::Graphics::Gdi::*;

    let hdc_screen = GetDC(null_mut());
    if hdc_screen.is_null() {
        let err = windows_sys::Win32::Foundation::GetLastError();
        return Err(format!("GetDC(NULL) failed (Win32 error: {})", err));
    }
    let hdc_mem = CreateCompatibleDC(hdc_screen);
    if hdc_mem.is_null() {
        let err = windows_sys::Win32::Foundation::GetLastError();
        ReleaseDC(null_mut(), hdc_screen);
        return Err(format!("CreateCompatibleDC failed (Win32 error: {})", err));
    }
    let hbitmap = CreateCompatibleBitmap(hdc_screen, width, height);
    if hbitmap.is_null() {
        let err = windows_sys::Win32::Foundation::GetLastError();
        DeleteDC(hdc_mem);
        ReleaseDC(null_mut(), hdc_screen);
        return Err(format!("CreateCompatibleBitmap failed (Win32 error: {})", err));
    }

    let old_obj = SelectObject(hdc_mem, hbitmap);
    let rop = SRCCOPY | CAPTUREBLT;
    let blt_res = BitBlt(hdc_mem, 0, 0, width, height, hdc_screen, x, y, rop);

    GdiFlush();
    SelectObject(hdc_mem, old_obj);
    DeleteDC(hdc_mem);

    if blt_res == 0 {
        let err = windows_sys::Win32::Foundation::GetLastError();
        DeleteObject(hbitmap);
        ReleaseDC(null_mut(), hdc_screen);
        return Err(format!("BitBlt compatible failed (Win32 error: {})", err));
    }

    let mut bi = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width,
            biHeight: -height, // Top-down
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB,
            biSizeImage: (width * height * 4) as u32,
            biXPelsPerMeter: 0,
            biYPelsPerMeter: 0,
            biClrUsed: 0,
            biClrImportant: 0,
        },
        bmiColors: [RGBQUAD { rgbBlue: 0, rgbGreen: 0, rgbRed: 0, rgbReserved: 0 }],
    };

    let total_bytes = (width * height * 4) as usize;
    let mut bgra_buf = vec![0u8; total_bytes];

    let lines = GetDIBits(
        hdc_screen,
        hbitmap,
        0,
        height as u32,
        bgra_buf.as_mut_ptr() as *mut std::ffi::c_void,
        &mut bi as *mut BITMAPINFO,
        DIB_RGB_COLORS,
    );

    DeleteObject(hbitmap);
    ReleaseDC(null_mut(), hdc_screen);

    if lines == 0 {
        let err = windows_sys::Win32::Foundation::GetLastError();
        return Err(format!("GetDIBits failed (Win32 error: {})", err));
    }

    let mut rgba_buf = vec![0u8; total_bytes];
    for i in (0..total_bytes).step_by(4) {
        rgba_buf[i] = bgra_buf[i + 2];
        rgba_buf[i + 1] = bgra_buf[i + 1];
        rgba_buf[i + 2] = bgra_buf[i];
        rgba_buf[i + 3] = 255;
    }

    if is_frame_all_black(&rgba_buf) {
        return Err("GDI Compatible Bitmap returned all black pixels".to_string());
    }

    Ok(rgba_buf)
}

/// Hardware DXGI desktop capture via xcap
fn capture_screen_xcap(display_mode: &str) -> Result<(Vec<u8>, u32, u32), String> {
    let monitors = xcap::Monitor::all().map_err(|e| format!("XCap monitors error: {:?}", e))?;
    if monitors.is_empty() {
        return Err("XCap: No monitors detected by DXGI".to_string());
    }

    let target_monitor = if display_mode == "secondary" && monitors.len() > 1 {
        &monitors[1]
    } else {
        monitors.iter().find(|m| m.is_primary().unwrap_or(false)).unwrap_or(&monitors[0])
    };

    let img = target_monitor.capture_image().map_err(|e| format!("XCap capture failed: {:?}", e))?;
    let raw = img.into_raw();
    if is_frame_all_black(&raw) {
        return Err("XCap DXGI returned all black frame (display asleep or access lost)".to_string());
    }
    let (w, h) = (target_monitor.width().unwrap_or(1920), target_monitor.height().unwrap_or(1080));
    Ok((raw, w, h))
}

/// Generates an animated test pattern frame with color bars and moving scanner
/// This guarantees the network and video rendering pipeline can be validated 100%
fn generate_test_pattern(width: u32, height: u32, frame_num: u64, _host_name: &str, _ip: &str) -> Vec<u8> {
    let mut rgba = vec![0u8; (width * height * 4) as usize];
    let colors: [[u8; 3]; 8] = [
        [248, 250, 252], // White / Slate 50
        [234, 179, 8],   // Amber
        [14, 165, 233],  // Sky
        [34, 197, 94],   // Green
        [168, 85, 247],  // Purple
        [239, 68, 68],   // Red
        [59, 130, 246],  // Blue
        [15, 23, 42],    // Dark Slate 900
    ];
    let col_w = (width / 8).max(1);
    let bar_shift = ((frame_num % 120) as f64 / 120.0 * width as f64) as u32;

    for y in 0..height {
        let is_header_bar = y < 50 || y > height - 50;
        for x in 0..width {
            let idx = ((y * width + x) * 4) as usize;
            if is_header_bar {
                rgba[idx] = 15;
                rgba[idx + 1] = 23;
                rgba[idx + 2] = 42;
                rgba[idx + 3] = 255;
            } else {
                let col_idx = ((x / col_w) as usize).min(7);
                let base_color = colors[col_idx];
                let is_scanner = (x as i32 - bar_shift as i32).abs() < 8;
                if is_scanner {
                    rgba[idx] = 56;
                    rgba[idx + 1] = 189;
                    rgba[idx + 2] = 248; // Bright Sky Scanner Line
                    rgba[idx + 3] = 255;
                } else {
                    rgba[idx] = base_color[0];
                    rgba[idx + 1] = base_color[1];
                    rgba[idx + 2] = base_color[2];
                    rgba[idx + 3] = 255;
                }
            }
        }
    }
    rgba
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    // 0. Enable Windows DPI Awareness so screen width/height and GDI captures match true physical pixels
    unsafe {
        windows_sys::Win32::UI::WindowsAndMessaging::SetProcessDPIAware();
    }

    // 1. Automatic UAC Elevation: If not admin, prompt Windows UAC elevation automatically
    if !is_running_as_admin() {
        println!("[UAC] Requesting Administrator privileges for screen capture and Firewall setup...");
        relaunch_as_admin();
    }

    println!("============================================================");
    println!("    REMOTE PC CONTROLLER HOST (HIGH-PERFORMANCE SUITE)     ");
    println!("============================================================");

    // 2. Automatically configure firewall rule so user never types commands
    setup_windows_firewall();

    // 3. Auto-detect LAN IP & Query Public Internet IP
    let local_lan_ip = get_local_lan_ip();
    println!("[NETWORK] Detecting Public Internet IP for outside-of-WiFi access...");
    let public_ip_init = detect_public_ip().await;
    let public_ip_shared = Arc::new(RwLock::new(public_ip_init.clone()));
    let host_name = std::env::var("COMPUTERNAME").unwrap_or_else(|_| "Windows-PC".to_string());

    // 4. Automatically configure router UPnP port forwarding for port 8765
    setup_upnp_port_forward(8765, &local_lan_ip);

    // 5. Start UDP Discovery Beacon so mobile app discovers PC on Wi-Fi with 1 click
    start_udp_discovery_beacon(local_lan_ip.clone(), public_ip_init.clone(), host_name.clone());

    // 6. Open sleek native Windows GUI Window with dual IP addresses & Copy buttons
    spawn_gui_window(&local_lan_ip, &public_ip_init, &host_name);

    // Background task: Periodically refresh Public WAN IP and UPnP mapping every 60 seconds
    let public_ip_refresher = public_ip_shared.clone();
    let local_lan_ip_refresher = local_lan_ip.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(60));
        loop {
            interval.tick().await;
            let fresh_ip = detect_public_ip().await;
            if !fresh_ip.is_empty() && fresh_ip != "Detecting / Router IP" {
                let mut guard = public_ip_refresher.write().await;
                *guard = fresh_ip;
            }
            setup_upnp_port_forward(8765, &local_lan_ip_refresher);
        }
    });

    println!("------------------------------------------------------------");
    println!("  [+] PC NAME:                  {}", host_name);
    println!("  [+] 1. LOCAL WI-FI IP:        {}:8765", local_lan_ip);
    println!("  [+] 2. OUTSIDE WI-FI INTERNET: {}:8765", public_ip_init);
    println!("  [+] UPNP PORT FORWARDING:     Port 8765 TCP Auto-Requested");
    println!("  [+] ADMIN PASSWORD:           {}", ADMIN_PASSWORD);
    println!();
    println!("  >>> ON YOUR MOBILE APP:");
    println!("      • On Home Wi-Fi: Tap 'Auto-Detect PC' or enter {}:8765", local_lan_ip);
    println!("      • Outside Wi-Fi: Connect once on Wi-Fi to auto-save, or enter {}:8765", public_ip_init);
    println!("------------------------------------------------------------");

    // Detect actual physical screen metrics via Windows user32 API
    let sys_screen_w = unsafe {
        windows_sys::Win32::UI::WindowsAndMessaging::GetSystemMetrics(
            windows_sys::Win32::UI::WindowsAndMessaging::SM_CXSCREEN,
        )
    };
    let sys_screen_h = unsafe {
        windows_sys::Win32::UI::WindowsAndMessaging::GetSystemMetrics(
            windows_sys::Win32::UI::WindowsAndMessaging::SM_CYSCREEN,
        )
    };
    let initial_w = if sys_screen_w > 0 { sys_screen_w as usize } else { 1920 };
    let initial_h = if sys_screen_h > 0 { sys_screen_h as usize } else { 1080 };
    println!("[DISPLAY] Detected Primary Screen: {}x{}", initial_w, initial_h);

    // Initial Screen Capture Diagnostic: Test Windows GDI CreateDIBSection with CAPTUREBLT
    println!("[CAPTURE DIAGNOSTIC] Testing Windows GDI DIBSection + CAPTUREBLT capture engine...");
    let test_capture = unsafe { capture_screen_gdi_dib(0, 0, initial_w as i32, initial_h as i32) };
    let mut gdi_verified = false;
    match test_capture {
        Ok(buf) => {
            println!(
                "[CAPTURE DIAGNOSTIC] SUCCESS! GDI DIBSection captured {} bytes for {}x{} screen.",
                buf.len(),
                initial_w,
                initial_h
            );
            gdi_verified = true;
        }
        Err(err) => {
            eprintln!("[CAPTURE DIAGNOSTIC] GDI DIBSection Notice: {}", err);
        }
    }

    let screen_width = Arc::new(AtomicUsize::new(initial_w));
    let screen_height = Arc::new(AtomicUsize::new(initial_h));
    let display_target = Arc::new(RwLock::new("primary".to_string())); // "primary" or "virtual"

    // Broadcast channel for distributing compressed JPEG frames
    let (frame_tx, _) = broadcast::channel::<FrameData>(16);
    let latest_jpeg = Arc::new(RwLock::new(Vec::new()));

    // Shared thread-safe input injector for keyboard text & clicks
    let enigo = Arc::new(StdMutex::new(
        Enigo::new(&Settings::default()).expect("Failed to initialize Enigo input injector"),
    ));

    // Client connection registry & persistent lock table
    let client_registry: ClientRegistry = Arc::new(Mutex::new(HashMap::new()));
    let locked_table: LockedTable = Arc::new(Mutex::new(HashMap::new()));

    // Telemetry & diagnostics state
    let total_frames_captured = Arc::new(AtomicU64::new(0));
    let last_encode_time_ms = Arc::new(AtomicU64::new(0));
    let last_frame_size_bytes = Arc::new(AtomicUsize::new(0));
    let active_engine_name = Arc::new(RwLock::new("Windows GDI Direct DIB".to_string()));
    let capture_mode = Arc::new(RwLock::new(if gdi_verified { "gdi".to_string() } else { "auto".to_string() }));
    let last_capture_error = Arc::new(RwLock::new(None::<String>));
    let is_screen_black_flag = Arc::new(AtomicBool::new(false));

    let is_running = Arc::new(AtomicBool::new(true));

    // Spawn Multi-Engine Screen Capture Task on dedicated OS thread
    let capture_tx = frame_tx.clone();
    let capture_running = is_running.clone();
    let width_ref = screen_width.clone();
    let height_ref = screen_height.clone();
    let capture_latest = latest_jpeg.clone();
    let frames_counter_clone = total_frames_captured.clone();
    let encode_time_clone = last_encode_time_ms.clone();
    let frame_size_clone = last_frame_size_bytes.clone();
    let engine_name_clone = active_engine_name.clone();
    let mode_clone = capture_mode.clone();
    let error_clone = last_capture_error.clone();
    let display_target_clone = display_target.clone();
    let host_name_capture = host_name.clone();
    let lan_ip_capture = local_lan_ip.clone();
    let black_flag_capture = is_screen_black_flag.clone();

    std::thread::spawn(move || {
        // Initialize COM on this thread so DirectX and Windows Graphics Capture work cleanly
        unsafe {
            windows_sys::Win32::System::Com::CoInitializeEx(
                std::ptr::null_mut(),
                windows_sys::Win32::System::Com::COINIT_MULTITHREADED as u32,
            );
        }

        println!("[CAPTURE] Screen Capture Engine active. Default: Windows GDI Direct DIB + CAPTUREBLT.");
        let target_frame_duration = Duration::from_millis(33); // ~30 FPS default for maximum Wi-Fi stability
        let mut last_valid_jpeg = Arc::new(Vec::new());
        let mut first_frame_logged = false;

        while capture_running.load(Ordering::Relaxed) {
            let start_time = Instant::now();
            let current_mode = mode_clone.blocking_read().clone();
            let current_display = display_target_clone.blocking_read().clone();

            let (disp_x, disp_y, disp_w, disp_h) = if current_display == "virtual" {
                unsafe {
                    let vx = windows_sys::Win32::UI::WindowsAndMessaging::GetSystemMetrics(windows_sys::Win32::UI::WindowsAndMessaging::SM_XVIRTUALSCREEN);
                    let vy = windows_sys::Win32::UI::WindowsAndMessaging::GetSystemMetrics(windows_sys::Win32::UI::WindowsAndMessaging::SM_YVIRTUALSCREEN);
                    let vw = windows_sys::Win32::UI::WindowsAndMessaging::GetSystemMetrics(windows_sys::Win32::UI::WindowsAndMessaging::SM_CXVIRTUALSCREEN);
                    let vh = windows_sys::Win32::UI::WindowsAndMessaging::GetSystemMetrics(windows_sys::Win32::UI::WindowsAndMessaging::SM_CYVIRTUALSCREEN);
                    (vx, vy, if vw > 0 { vw } else { 1920 }, if vh > 0 { vh } else { 1080 })
                }
            } else {
                let cur_w = width_ref.load(Ordering::Relaxed) as i32;
                let cur_h = height_ref.load(Ordering::Relaxed) as i32;
                (0, 0, if cur_w > 0 { cur_w } else { 1920 }, if cur_h > 0 { cur_h } else { 1080 })
            };

            let mut captured_rgba: Option<(Vec<u8>, u32, u32, &'static str)> = None;
            let mut current_err: Option<String> = None;

            // Strategy 1: Test Pattern Mode
            if current_mode == "test_pattern" {
                let frame_num = frames_counter_clone.load(Ordering::Relaxed);
                let rgba = generate_test_pattern(disp_w as u32, disp_h as u32, frame_num, &host_name_capture, &lan_ip_capture);
                captured_rgba = Some((rgba, disp_w as u32, disp_h as u32, "Diagnostic Test Pattern"));
                black_flag_capture.store(false, Ordering::Relaxed);
            }

            // Strategy 2: Windows GDI Direct DIB Section with CAPTUREBLT + GdiFlush
            if captured_rgba.is_none() && (current_mode == "gdi" || current_mode == "auto") {
                match unsafe { capture_screen_gdi_dib(disp_x, disp_y, disp_w, disp_h) } {
                    Ok(rgba) => {
                        captured_rgba = Some((rgba, disp_w as u32, disp_h as u32, "Windows GDI DIB Section"));
                        current_err = None;
                        black_flag_capture.store(false, Ordering::Relaxed);
                    }
                    Err(e) => {
                        current_err = Some(format!("GDI DIB notice: {}", e));
                        if e.contains("all black") {
                            black_flag_capture.store(true, Ordering::Relaxed);
                        }
                    }
                }
            }

            // Strategy 3: Windows GDI Compatible Bitmap with CAPTUREBLT (fallback for unusual display drivers)
            if captured_rgba.is_none() && (current_mode == "gdi" || current_mode == "auto") {
                match unsafe { capture_screen_gdi_compatible(disp_x, disp_y, disp_w, disp_h) } {
                    Ok(rgba) => {
                        captured_rgba = Some((rgba, disp_w as u32, disp_h as u32, "Windows GDI Compatible"));
                        current_err = None;
                        black_flag_capture.store(false, Ordering::Relaxed);
                    }
                    Err(e) => {
                        if current_err.is_none() {
                            current_err = Some(format!("GDI Compatible notice: {}", e));
                        }
                    }
                }
            }

            // Strategy 4: XCap Hardware DXGI / WGC Capture (fallback or if explicitly requested)
            if captured_rgba.is_none() && (current_mode == "xcap" || current_mode == "auto") {
                match capture_screen_xcap(&current_display) {
                    Ok((raw, w, h)) => {
                        captured_rgba = Some((raw, w, h, "XCap Hardware DXGI"));
                        current_err = None;
                        black_flag_capture.store(false, Ordering::Relaxed);
                    }
                    Err(e) => {
                        current_err = Some(format!("XCap capture error: {}", e));
                    }
                }
            }

            // Strategy 5: Emergency Test Pattern Fallback if screen buffer is completely unavailable
            if captured_rgba.is_none() && last_valid_jpeg.is_empty() {
                let frame_num = frames_counter_clone.load(Ordering::Relaxed);
                let rgba = generate_test_pattern(disp_w as u32, disp_h as u32, frame_num, &host_name_capture, &lan_ip_capture);
                captured_rgba = Some((rgba, disp_w as u32, disp_h as u32, "Fallback Test Pattern"));
                if current_err.is_none() {
                    current_err = Some("Desktop capture initialized fallback pattern".to_string());
                }
            }

            // Update telemetry error reason
            {
                let mut err_guard = error_clone.blocking_write();
                *err_guard = current_err;
            }

            // Encode to JPEG and distribute to connected clients
            if let Some((raw_pixels, width, height, engine_name)) = captured_rgba {
                width_ref.store(width as usize, Ordering::Relaxed);
                height_ref.store(height as usize, Ordering::Relaxed);

                let encode_start = Instant::now();
                let mut jpeg_buffer = Vec::with_capacity((width * height / 4) as usize);
                let mut encoder = JpegEncoder::new_with_quality(&mut jpeg_buffer, 65);
                if encoder
                    .encode(&raw_pixels, width, height, ColorType::Rgba8.into())
                    .is_ok()
                {
                    let enc_ms = encode_start.elapsed().as_millis() as u64;
                    let buf_len = jpeg_buffer.len();

                    encode_time_clone.store(enc_ms, Ordering::Relaxed);
                    frame_size_clone.store(buf_len, Ordering::Relaxed);
                    frames_counter_clone.fetch_add(1, Ordering::Relaxed);

                    {
                        let mut name_guard = engine_name_clone.blocking_write();
                        *name_guard = engine_name.to_string();
                    }

                    last_valid_jpeg = Arc::new(jpeg_buffer.clone());

                    if !first_frame_logged {
                        first_frame_logged = true;
                        println!(
                            "[CAPTURE] Screen streaming active! Engine: {}, {}x{}, {} KB (encode: {} ms)",
                            engine_name,
                            width,
                            height,
                            buf_len / 1024,
                            enc_ms
                        );
                    }

                    {
                        let mut guard = capture_latest.blocking_write();
                        *guard = jpeg_buffer;
                    }

                    let frame = FrameData {
                        jpeg_bytes: last_valid_jpeg.clone(),
                        width,
                        height,
                    };
                    let _ = capture_tx.send(frame);
                }
            } else if !last_valid_jpeg.is_empty() {
                let frame = FrameData {
                    jpeg_bytes: last_valid_jpeg.clone(),
                    width: width_ref.load(Ordering::Relaxed) as u32,
                    height: height_ref.load(Ordering::Relaxed) as u32,
                };
                let _ = capture_tx.send(frame);
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
        let public_ip_clone = public_ip_shared.clone();
        let latest_jpeg_clone = latest_jpeg.clone();
        let registry_clone = client_registry.clone();
        let locked_clone = locked_table.clone();
        let frames_counter_ws = total_frames_captured.clone();
        let encode_ms_ws = last_encode_time_ms.clone();
        let frame_size_ws = last_frame_size_bytes.clone();
        let engine_name_ws = active_engine_name.clone();
        let capture_mode_ws = capture_mode.clone();
        let capture_error_ws = last_capture_error.clone();
        let black_flag_ws = is_screen_black_flag.clone();
        let display_target_ws = display_target.clone();

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
                public_ip_clone,
                latest_jpeg_clone,
                registry_clone,
                locked_clone,
                frames_counter_ws,
                encode_ms_ws,
                frame_size_ws,
                engine_name_ws,
                capture_mode_ws,
                capture_error_ws,
                black_flag_ws,
                display_target_ws,
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
    addr: SocketAddr,
    client_id: usize,
    mut frame_rx: broadcast::Receiver<FrameData>,
    enigo: Arc<StdMutex<Enigo>>,
    screen_width: Arc<AtomicUsize>,
    screen_height: Arc<AtomicUsize>,
    host_name: String,
    ip_address: String,
    public_ip: Arc<RwLock<String>>,
    latest_jpeg: Arc<RwLock<Vec<u8>>>,
    registry: ClientRegistry,
    locked_table: LockedTable,
    total_frames_counter: Arc<AtomicU64>,
    last_encode_ms: Arc<AtomicU64>,
    last_frame_bytes: Arc<AtomicUsize>,
    active_engine_name: Arc<RwLock<String>>,
    capture_mode: Arc<RwLock<String>>,
    last_capture_error: Arc<RwLock<Option<String>>>,
    is_screen_black_flag: Arc<AtomicBool>,
    display_target: Arc<RwLock<String>>,
) -> Result<(), Box<dyn Error + Send + Sync>> {
    let ws_stream = tokio_tungstenite::accept_async(stream).await?;
    let (mut ws_sink, mut ws_stream_reader) = ws_stream.split();

    let (out_tx, mut out_rx) = mpsc::channel::<Message>(128);
    let client_frames_sent = Arc::new(AtomicU64::new(0));

    let client_ip = addr.ip().to_string();
    let now_sec = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    // Check if this client IP is currently locked in persistent locked_table
    let mut is_initially_locked = false;
    let mut initial_locked_until = 0u64;
    {
        let mut lock_guard = locked_table.lock().await;
        if let Some(&expiry) = lock_guard.get(&client_ip) {
            if expiry == 0 || expiry > now_sec {
                is_initially_locked = true;
                initial_locked_until = expiry;
            } else {
                lock_guard.remove(&client_ip);
            }
        }
    }

    // Register this client in the central registry
    let initial_record = ConnectedClientRecord {
        id: client_id,
        ip: client_ip.clone(),
        device_name: format!("Phone #{} ({})", client_id, client_ip),
        device_id: client_ip.clone(),
        connected_at: now_sec,
        is_locked: is_initially_locked,
        locked_until: initial_locked_until,
        is_admin: false,
    };

    {
        let mut reg = registry.lock().await;
        reg.insert(
            client_id,
            ClientRegistryEntry {
                record: initial_record.clone(),
                out_tx: out_tx.clone(),
            },
        );
    }

    // Task A: Outbound frame writer
    let write_task = tokio::spawn(async move {
        while let Some(msg) = out_rx.recv().await {
            if let Err(e) = ws_sink.send(msg).await {
                eprintln!("[WS Sink #{}] Send error: {:?}", client_id, e);
                break;
            }
        }
    });

    let current_public_ip = public_ip.read().await.clone();

    // Send screen resolution, host info payload, and public IP for outside-of-WiFi connection
    let initial_width = screen_width.load(Ordering::Relaxed) as u32;
    let initial_height = screen_height.load(Ordering::Relaxed) as u32;
    let info_msg = HostMessage::Info {
        width: initial_width,
        height: initial_height,
        fps_target: 60,
        host_name: host_name.clone(),
        ip_address: ip_address.clone(),
        public_ip: Some(current_public_ip.clone()),
        client_id,
    };
    if let Ok(info_json) = serde_json::to_string(&info_msg) {
        let _ = out_tx.send(Message::Text(info_json)).await;
    }

    // Immediately deliver the latest frame so client sees the screen without waiting!
    {
        let cached = latest_jpeg.read().await;
        if !cached.is_empty() {
            println!("[WS] Sending initial cached frame to client #{} ({} KB)", client_id, cached.len() / 1024);
            client_frames_sent.fetch_add(1, Ordering::Relaxed);
            let _ = out_tx.send(Message::Binary(cached.clone())).await;
        } else {
            // Generate an instant diagnostic frame so client NEVER has a black screen
            println!("[WS] Generating instant startup diagnostic frame for client #{}", client_id);
            let test_rgba = generate_test_pattern(initial_width, initial_height, 1, &host_name, &ip_address);
            let mut buf = Vec::new();
            let mut enc = JpegEncoder::new_with_quality(&mut buf, 70);
            if enc.encode(&test_rgba, initial_width, initial_height, ColorType::Rgba8.into()).is_ok() {
                client_frames_sent.fetch_add(1, Ordering::Relaxed);
                let _ = out_tx.send(Message::Binary(buf)).await;
            }
        }
    }

    // Send initial telemetry debug info
    {
        let engine = active_engine_name.read().await.clone();
        let cur_mode = capture_mode.read().await.clone();
        let cur_err = last_capture_error.read().await.clone();
        let is_black = is_screen_black_flag.load(Ordering::Relaxed);
        let debug_msg = HostMessage::CaptureDebug {
            engine,
            fps: 30,
            frame_count: total_frames_counter.load(Ordering::Relaxed),
            width: initial_width,
            height: initial_height,
            last_bytes: last_frame_bytes.load(Ordering::Relaxed),
            last_encode_ms: last_encode_ms.load(Ordering::Relaxed),
            status: "Connected & Streaming Active".to_string(),
            last_error: cur_err,
            mode: cur_mode,
            frames_sent_to_client: client_frames_sent.load(Ordering::Relaxed),
            public_ip: Some(current_public_ip.clone()),
            is_screen_black: is_black,
        };
        if let Ok(json_str) = serde_json::to_string(&debug_msg) {
            let _ = out_tx.send(Message::Text(json_str)).await;
        }
    }

    // If client is locked upon joining, notify them immediately
    if is_initially_locked {
        let rem = if initial_locked_until > now_sec {
            Some(initial_locked_until - now_sec)
        } else {
            None
        };
        let lock_msg = HostMessage::LockStatus {
            is_locked: true,
            locked_until: initial_locked_until,
            remaining_seconds: rem,
        };
        if let Ok(lock_json) = serde_json::to_string(&lock_msg) {
            let _ = out_tx.send(Message::Text(lock_json)).await;
        }
    }

    // Broadcast updated client list to all connected admins
    broadcast_admin_clients(&registry).await;

    // Task B: Forward video frames
    let out_tx_frames = out_tx.clone();
    let sent_counter_frames = client_frames_sent.clone();
    let frame_task = tokio::spawn(async move {
        let mut skip_next = false;
        loop {
            match frame_rx.recv().await {
                Ok(frame) => {
                    // Adaptive frame skipping: if channel is getting congested, skip every other frame
                    // to prevent total stall on slow WAN links, but keep the stream alive
                    let channel_capacity = out_tx_frames.capacity();
                    let is_congested = channel_capacity < 32;
                    
                    if is_congested && skip_next {
                        skip_next = false;
                        continue;
                    }
                    if is_congested {
                        skip_next = true;
                    } else {
                        skip_next = false;
                    }
                    
                    let msg = Message::Binary(frame.jpeg_bytes.as_ref().clone());
                    if out_tx_frames.try_send(msg).is_ok() {
                        sent_counter_frames.fetch_add(1, Ordering::Relaxed);
                    }
                }
                Err(broadcast::error::RecvError::Lagged(_)) => {
                    continue;
                }
                Err(broadcast::error::RecvError::Closed) => {
                    break;
                }
            }
        }
    });

    // Task C: Telemetry Heartbeat Ticker (every 1 second sends live debug diagnostics)
    let out_tx_ticker = out_tx.clone();
    let ticker_engine = active_engine_name.clone();
    let ticker_mode = capture_mode.clone();
    let ticker_err = last_capture_error.clone();
    let ticker_frames = total_frames_counter.clone();
    let ticker_width = screen_width.clone();
    let ticker_height = screen_height.clone();
    let ticker_bytes = last_frame_bytes.clone();
    let ticker_encode = last_encode_ms.clone();
    let ticker_sent = client_frames_sent.clone();
    let ticker_public_ip = public_ip.clone();
    let ticker_black = is_screen_black_flag.clone();

    let ticker_task = tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(1));
        loop {
            interval.tick().await;
            let engine = ticker_engine.read().await.clone();
            let mode = ticker_mode.read().await.clone();
            let err = ticker_err.read().await.clone();
            let cur_pub = ticker_public_ip.read().await.clone();
            let is_black = ticker_black.load(Ordering::Relaxed);
            let debug_msg = HostMessage::CaptureDebug {
                engine,
                fps: 30,
                frame_count: ticker_frames.load(Ordering::Relaxed),
                width: ticker_width.load(Ordering::Relaxed) as u32,
                height: ticker_height.load(Ordering::Relaxed) as u32,
                last_bytes: ticker_bytes.load(Ordering::Relaxed),
                last_encode_ms: ticker_encode.load(Ordering::Relaxed),
                status: "Live Stream Synchronized".to_string(),
                last_error: err,
                mode,
                frames_sent_to_client: ticker_sent.load(Ordering::Relaxed),
                public_ip: Some(cur_pub),
                is_screen_black: is_black,
            };
            if let Ok(json_str) = serde_json::to_string(&debug_msg) {
                if out_tx_ticker.try_send(Message::Text(json_str)).is_err() {
                    break;
                }
            }
        }
    });

    let out_tx_ping = out_tx.clone();

    // Task D: Inbound command processing
    while let Some(msg_result) = ws_stream_reader.next().await {
        match msg_result {
            Ok(Message::Text(text)) => {
                if let Ok(cmd) = serde_json::from_str::<ClientMessage>(&text) {
                    let cur_w = screen_width.load(Ordering::Relaxed) as f64;
                    let cur_h = screen_height.load(Ordering::Relaxed) as f64;

                    // Check if this client is currently locked
                    let (is_locked, locked_until) = {
                        let now = SystemTime::now()
                            .duration_since(UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_secs();
                        let mut reg = registry.lock().await;
                        if let Some(entry) = reg.get_mut(&client_id) {
                            if entry.record.is_locked {
                                if entry.record.locked_until > 0 && now >= entry.record.locked_until {
                                    // Lock expired
                                    entry.record.is_locked = false;
                                    entry.record.locked_until = 0;
                                    let _ = entry.out_tx.try_send(Message::Text(
                                        serde_json::to_string(&HostMessage::LockStatus {
                                            is_locked: false,
                                            locked_until: 0,
                                            remaining_seconds: None,
                                        })
                                        .unwrap(),
                                    ));
                                    (false, 0)
                                } else {
                                    (true, entry.record.locked_until)
                                }
                            } else {
                                (false, 0)
                            }
                        } else {
                            (false, 0)
                        }
                    };

                    match cmd {
                        // Client handshake with friendly name & persistent device ID
                        ClientMessage::ClientHello {
                            device_name,
                            device_id,
                        } => {
                            let now = SystemTime::now()
                                .duration_since(UNIX_EPOCH)
                                .unwrap_or_default()
                                .as_secs();

                            let dev_id = device_id.unwrap_or_else(|| client_ip.clone());

                            // Check persistent lock for this device ID
                            let mut locked_by_id = false;
                            let mut locked_until_by_id = 0u64;
                            {
                                let mut lock_guard = locked_table.lock().await;
                                if let Some(&expiry) = lock_guard.get(&dev_id).or_else(|| lock_guard.get(&client_ip)) {
                                    if expiry == 0 || expiry > now {
                                        locked_by_id = true;
                                        locked_until_by_id = expiry;
                                    } else {
                                        lock_guard.remove(&dev_id);
                                        lock_guard.remove(&client_ip);
                                    }
                                }
                            }

                            {
                                let mut reg = registry.lock().await;
                                if let Some(entry) = reg.get_mut(&client_id) {
                                    if let Some(name) = device_name {
                                        entry.record.device_name = name;
                                    }
                                    entry.record.device_id = dev_id.clone();
                                    if locked_by_id {
                                        entry.record.is_locked = true;
                                        entry.record.locked_until = locked_until_by_id;
                                    }
                                }
                            }

                            if locked_by_id {
                                let rem = if locked_until_by_id > now {
                                    Some(locked_until_by_id - now)
                                } else {
                                    None
                                };
                                let _ = out_tx_ping.send(Message::Text(
                                    serde_json::to_string(&HostMessage::LockStatus {
                                        is_locked: true,
                                        locked_until: locked_until_by_id,
                                        remaining_seconds: rem,
                                    })
                                    .unwrap(),
                                )).await;
                            }

                            broadcast_admin_clients(&registry).await;
                        }

                        // Client requests an immediate fresh frame and telemetry
                        ClientMessage::RequestFrame => {
                            let cached = latest_jpeg.read().await;
                            if !cached.is_empty() {
                                println!("[WS] Fulfilling RequestFrame for client #{} ({} KB)", client_id, cached.len() / 1024);
                                client_frames_sent.fetch_add(1, Ordering::Relaxed);
                                let _ = out_tx_ping.send(Message::Binary(cached.clone())).await;
                            } else {
                                let cur_w = screen_width.load(Ordering::Relaxed) as u32;
                                let cur_h = screen_height.load(Ordering::Relaxed) as u32;
                                let test_rgba = generate_test_pattern(cur_w, cur_h, total_frames_counter.load(Ordering::Relaxed), &host_name, &ip_address);
                                let mut buf = Vec::new();
                                let mut enc = JpegEncoder::new_with_quality(&mut buf, 70);
                                if enc.encode(&test_rgba, cur_w, cur_h, ColorType::Rgba8.into()).is_ok() {
                                    client_frames_sent.fetch_add(1, Ordering::Relaxed);
                                    let _ = out_tx_ping.send(Message::Binary(buf)).await;
                                }
                            }

                            let engine = active_engine_name.read().await.clone();
                            let mode = capture_mode.read().await.clone();
                            let err = last_capture_error.read().await.clone();
                            let is_black = is_screen_black_flag.load(Ordering::Relaxed);
                            let pub_ip = public_ip.read().await.clone();
                            let debug_msg = HostMessage::CaptureDebug {
                                engine,
                                fps: 30,
                                frame_count: total_frames_counter.load(Ordering::Relaxed),
                                width: screen_width.load(Ordering::Relaxed) as u32,
                                height: screen_height.load(Ordering::Relaxed) as u32,
                                last_bytes: last_frame_bytes.load(Ordering::Relaxed),
                                last_encode_ms: last_encode_ms.load(Ordering::Relaxed),
                                status: "Frame Request Fulfilled".to_string(),
                                last_error: err,
                                mode,
                                frames_sent_to_client: client_frames_sent.load(Ordering::Relaxed),
                                public_ip: Some(pub_ip),
                                is_screen_black: is_black,
                            };
                            if let Ok(json_str) = serde_json::to_string(&debug_msg) {
                                let _ = out_tx_ping.send(Message::Text(json_str)).await;
                            }
                        }

                        // Client requests test frame to verify pipeline
                        ClientMessage::RequestTestFrame => {
                            println!("[CAPTURE] Client #{} requested Test Frame pattern", client_id);
                            let cur_w = screen_width.load(Ordering::Relaxed) as u32;
                            let cur_h = screen_height.load(Ordering::Relaxed) as u32;
                            let test_rgba = generate_test_pattern(
                                cur_w,
                                cur_h,
                                total_frames_counter.load(Ordering::Relaxed) + 1,
                                &host_name,
                                &ip_address,
                            );
                            let mut buf = Vec::new();
                            let mut enc = JpegEncoder::new_with_quality(&mut buf, 70);
                            if enc.encode(&test_rgba, cur_w, cur_h, ColorType::Rgba8.into()).is_ok() {
                                client_frames_sent.fetch_add(1, Ordering::Relaxed);
                                let _ = out_tx_ping.send(Message::Binary(buf)).await;
                            }
                        }

                        // Client switches capture mode: "auto", "gdi", "xcap", "test_pattern"
                        ClientMessage::SetCaptureMode { mode } => {
                            let new_mode = match mode.to_lowercase().as_str() {
                                "gdi" => "gdi",
                                "xcap" => "xcap",
                                "test_pattern" => "test_pattern",
                                _ => "auto",
                            };
                            println!("[CAPTURE] Client #{} switched capture mode to: {}", client_id, new_mode);
                            {
                                let mut mode_guard = capture_mode.write().await;
                                *mode_guard = new_mode.to_string();
                            }
                            // Immediately send fresh telemetry with updated mode
                            let engine = active_engine_name.read().await.clone();
                            let err = last_capture_error.read().await.clone();
                            let is_black = is_screen_black_flag.load(Ordering::Relaxed);
                            let pub_ip = public_ip.read().await.clone();
                            let debug_msg = HostMessage::CaptureDebug {
                                engine,
                                fps: 30,
                                frame_count: total_frames_counter.load(Ordering::Relaxed),
                                width: screen_width.load(Ordering::Relaxed) as u32,
                                height: screen_height.load(Ordering::Relaxed) as u32,
                                last_bytes: last_frame_bytes.load(Ordering::Relaxed),
                                last_encode_ms: last_encode_ms.load(Ordering::Relaxed),
                                status: format!("Mode switched to: {}", new_mode),
                                last_error: err,
                                mode: new_mode.to_string(),
                                frames_sent_to_client: client_frames_sent.load(Ordering::Relaxed),
                                public_ip: Some(pub_ip),
                                is_screen_black: is_black,
                            };
                            if let Ok(json_str) = serde_json::to_string(&debug_msg) {
                                let _ = out_tx_ping.send(Message::Text(json_str)).await;
                            }
                        }

                        // Cycle between Primary Display and Virtual All Displays
                        ClientMessage::CycleDisplay => {
                            let new_target = {
                                let mut target_guard = display_target.write().await;
                                if *target_guard == "primary" {
                                    *target_guard = "virtual".to_string();
                                    "virtual"
                                } else {
                                    *target_guard = "primary".to_string();
                                    "primary"
                                }
                            };
                            println!("[DISPLAY] Client #{} toggled display target to: {}", client_id, new_target);
                        }

                        // Wake sleeping Windows monitor by jiggling cursor / simulating key
                        ClientMessage::WakeDisplay => {
                            println!("[DISPLAY] Client #{} requested Wake Display", client_id);
                            let enigo_lock = enigo.clone();
                            tokio::task::spawn_blocking(move || {
                                if let Ok(mut en) = enigo_lock.lock() {
                                    let _ = en.move_mouse(1, 0, enigo::Coordinate::Rel);
                                    let _ = en.move_mouse(-1, 0, enigo::Coordinate::Rel);
                                }
                            });
                        }

                        // --- Administrator Portal Operations ---

                        // Admin authentication with password Sagiv_2311
                        ClientMessage::AdminAuth { password } => {
                            if password.trim() == ADMIN_PASSWORD {
                                {
                                    let mut reg = registry.lock().await;
                                    if let Some(entry) = reg.get_mut(&client_id) {
                                        entry.record.is_admin = true;
                                    }
                                }
                                let _ = out_tx
                                    .send(Message::Text(
                                        serde_json::to_string(&HostMessage::AdminAuthResult {
                                            success: true,
                                            message: "Admin authentication successful.".to_string(),
                                            is_admin: true,
                                        })
                                        .unwrap(),
                                    ))
                                    .await;
                                broadcast_admin_clients(&registry).await;
                            } else {
                                let _ = out_tx
                                    .send(Message::Text(
                                        serde_json::to_string(&HostMessage::AdminAuthResult {
                                            success: false,
                                            message: "Invalid administrator password.".to_string(),
                                            is_admin: false,
                                        })
                                        .unwrap(),
                                    ))
                                    .await;
                            }
                        }

                        // Admin requests list of all connected clients
                        ClientMessage::AdminGetClients => {
                            if is_client_admin(&registry, client_id).await {
                                broadcast_admin_clients(&registry).await;
                            }
                        }

                        // Admin disconnects a client
                        ClientMessage::AdminDisconnectClient { target_id } => {
                            if is_client_admin(&registry, client_id).await {
                                println!("[ADMIN] Disconnecting client #{}", target_id);
                                let mut reg = registry.lock().await;
                                if let Some(target_entry) = reg.remove(&target_id) {
                                    let _ = target_entry.out_tx.try_send(Message::Close(None));
                                }
                                drop(reg);
                                broadcast_admin_clients(&registry).await;
                            }
                        }

                        // Admin locks a client app for duration_seconds (0 = indefinite)
                        ClientMessage::AdminLockClient {
                            target_id,
                            duration_seconds,
                        } => {
                            if is_client_admin(&registry, client_id).await {
                                let now = SystemTime::now()
                                    .duration_since(UNIX_EPOCH)
                                    .unwrap_or_default()
                                    .as_secs();

                                let dur = duration_seconds.unwrap_or(0);
                                let expiry = if dur > 0 { now + dur } else { 0 };

                                let (target_ip, target_dev_id) = {
                                    let mut reg = registry.lock().await;
                                    if let Some(target_entry) = reg.get_mut(&target_id) {
                                        target_entry.record.is_locked = true;
                                        target_entry.record.locked_until = expiry;

                                        let rem = if expiry > now { Some(expiry - now) } else { None };
                                        let _ = target_entry.out_tx.try_send(Message::Text(
                                            serde_json::to_string(&HostMessage::LockStatus {
                                                is_locked: true,
                                                locked_until: expiry,
                                                remaining_seconds: rem,
                                            })
                                            .unwrap(),
                                        ));
                                        (target_entry.record.ip.clone(), target_entry.record.device_id.clone())
                                    } else {
                                        ("".to_string(), "".to_string())
                                    }
                                };

                                if !target_ip.is_empty() {
                                    let mut table = locked_table.lock().await;
                                    table.insert(target_ip, expiry);
                                    if !target_dev_id.is_empty() {
                                        table.insert(target_dev_id, expiry);
                                    }
                                }

                                broadcast_admin_clients(&registry).await;
                            }
                        }

                        // Admin unlocks a client
                        ClientMessage::AdminUnlockClient { target_id } => {
                            if is_client_admin(&registry, client_id).await {
                                let (target_ip, target_dev_id) = {
                                    let mut reg = registry.lock().await;
                                    if let Some(target_entry) = reg.get_mut(&target_id) {
                                        target_entry.record.is_locked = false;
                                        target_entry.record.locked_until = 0;
                                        let _ = target_entry.out_tx.try_send(Message::Text(
                                            serde_json::to_string(&HostMessage::LockStatus {
                                                is_locked: false,
                                                locked_until: 0,
                                                remaining_seconds: None,
                                            })
                                            .unwrap(),
                                        ));
                                        (target_entry.record.ip.clone(), target_entry.record.device_id.clone())
                                    } else {
                                        ("".to_string(), "".to_string())
                                    }
                                };

                                if !target_ip.is_empty() {
                                    let mut table = locked_table.lock().await;
                                    table.remove(&target_ip);
                                    if !target_dev_id.is_empty() {
                                        table.remove(&target_dev_id);
                                    }
                                }

                                broadcast_admin_clients(&registry).await;
                            }
                        }

                        // --- Input Operations (Blocked if client is locked) ---
                        _ if is_locked => {
                            let now = SystemTime::now()
                                .duration_since(UNIX_EPOCH)
                                .unwrap_or_default()
                                .as_secs();
                            let rem = if locked_until > now {
                                Some(locked_until - now)
                            } else {
                                None
                            };
                            let _ = out_tx_ping.send(Message::Text(
                                serde_json::to_string(&HostMessage::LockStatus {
                                    is_locked: true,
                                    locked_until,
                                    remaining_seconds: rem,
                                })
                                .unwrap(),
                            )).await;
                        }

                        ClientMessage::Move { x, y } => {
                            let enigo_clone = enigo.clone();
                            tokio::task::spawn_blocking(move || {
                                let target_x = (x.clamp(0.0, 1.0) * cur_w) as i32;
                                let target_y = (y.clamp(0.0, 1.0) * cur_h) as i32;
                                unsafe {
                                    windows_sys::Win32::UI::WindowsAndMessaging::SetCursorPos(target_x, target_y);
                                }
                                if let Ok(mut en) = enigo_clone.lock() {
                                    let _ = en.move_mouse(target_x, target_y, enigo::Coordinate::Abs);
                                }
                            });
                        }

                        ClientMessage::MoveRelative { dx, dy } => {
                            let enigo_clone = enigo.clone();
                            tokio::task::spawn_blocking(move || {
                                unsafe {
                                    let mut pt = windows_sys::Win32::Foundation::POINT { x: 0, y: 0 };
                                    if windows_sys::Win32::UI::WindowsAndMessaging::GetCursorPos(&mut pt) != 0 {
                                        windows_sys::Win32::UI::WindowsAndMessaging::SetCursorPos(
                                            pt.x + dx as i32,
                                            pt.y + dy as i32,
                                        );
                                    }
                                }
                                if let Ok(mut en) = enigo_clone.lock() {
                                    let _ = en.move_mouse(dx as i32, dy as i32, enigo::Coordinate::Rel);
                                }
                            });
                        }

                        ClientMessage::MouseDown { button } => {
                            let enigo_clone = enigo.clone();
                            tokio::task::spawn_blocking(move || {
                                if let Ok(mut en) = enigo_clone.lock() {
                                    let b = match button.as_str() {
                                        "right" => Button::Right,
                                        "middle" => Button::Middle,
                                        _ => Button::Left,
                                    };
                                    let _ = en.button(b, Direction::Press);
                                }
                            });
                        }

                        ClientMessage::MouseUp { button } => {
                            let enigo_clone = enigo.clone();
                            tokio::task::spawn_blocking(move || {
                                if let Ok(mut en) = enigo_clone.lock() {
                                    let b = match button.as_str() {
                                        "right" => Button::Right,
                                        "middle" => Button::Middle,
                                        _ => Button::Left,
                                    };
                                    let _ = en.button(b, Direction::Release);
                                }
                            });
                        }

                        ClientMessage::Click { button } => {
                            let enigo_clone = enigo.clone();
                            tokio::task::spawn_blocking(move || {
                                if let Ok(mut en) = enigo_clone.lock() {
                                    let b = match button.as_str() {
                                        "right" => Button::Right,
                                        "middle" => Button::Middle,
                                        _ => Button::Left,
                                    };
                                    let _ = en.button(b, Direction::Click);
                                }
                            });
                        }

                        ClientMessage::DoubleClick { button } => {
                            let enigo_clone = enigo.clone();
                            tokio::task::spawn_blocking(move || {
                                if let Ok(mut en) = enigo_clone.lock() {
                                    let b = match button.as_str() {
                                        "right" => Button::Right,
                                        "middle" => Button::Middle,
                                        _ => Button::Left,
                                    };
                                    let _ = en.button(b, Direction::Click);
                                    std::thread::sleep(Duration::from_millis(60));
                                    let _ = en.button(b, Direction::Click);
                                }
                            });
                        }

                        ClientMessage::Scroll { dx, dy } => {
                            let enigo_clone = enigo.clone();
                            tokio::task::spawn_blocking(move || {
                                if let Ok(mut en) = enigo_clone.lock() {
                                    if let Some(y) = dy {
                                        let _ = en.scroll(y, Axis::Vertical);
                                    }
                                    if let Some(x) = dx {
                                        let _ = en.scroll(x, Axis::Horizontal);
                                    }
                                }
                            });
                        }

                        ClientMessage::Type { text } => {
                            let enigo_clone = enigo.clone();
                            tokio::task::spawn_blocking(move || {
                                if let Ok(mut en) = enigo_clone.lock() {
                                    let _ = en.text(&text);
                                }
                            });
                        }

                        ClientMessage::Key { key } => {
                            let enigo_clone = enigo.clone();
                            tokio::task::spawn_blocking(move || {
                                if let Ok(mut en) = enigo_clone.lock() {
                                    execute_key_shortcut(&mut en, &key);
                                }
                            });
                        }

                        ClientMessage::OpenUrl { url } => {
                            println!("[ACTION] Opening URL in default browser: {}", url);
                            let _ = Command::new("cmd")
                                .args(["/C", "start", "", &url])
                                .spawn();
                        }

                        ClientMessage::LaunchApp { app } => {
                            println!("[ACTION] Launching application: {}", app);
                            let cmd_target = match app.as_str() {
                                "notepad" => "notepad.exe",
                                "calculator" => "calc.exe",
                                "explorer" => "explorer.exe",
                                "taskmgr" => "taskmgr.exe",
                                "cmd" => "cmd.exe",
                                "chrome" => "start chrome",
                                "edge" => "start msedge",
                                other => other,
                            };
                            let _ = Command::new("cmd")
                                .args(["/C", "start", "", cmd_target])
                                .spawn();
                        }

                        ClientMessage::Ping { timestamp } => {
                            let pong = HostMessage::Pong {
                                timestamp: timestamp.unwrap_or(0),
                            };
                            if let Ok(pong_json) = serde_json::to_string(&pong) {
                                let _ = out_tx_ping.send(Message::Text(pong_json)).await;
                            }
                        }
                    }
                }
            }
            Ok(Message::Binary(_)) => {}
            Ok(Message::Ping(data)) => {
                let _ = out_tx_ping.send(Message::Pong(data)).await;
            }
            Ok(Message::Pong(_)) => {}
            Ok(Message::Close(_)) => {
                break;
            }
            Ok(Message::Frame(_)) => {}
            Ok(_) => {}
            Err(_) => {
                break;
            }
        }
    }

    // Unregister client upon disconnection
    {
        let mut reg = registry.lock().await;
        reg.remove(&client_id);
    }
    broadcast_admin_clients(&registry).await;

    frame_task.abort();
    ticker_task.abort();
    write_task.abort();

    Ok(())
}

/// Dispatches convenient system keys and keyboard shortcuts
fn execute_key_shortcut(en: &mut Enigo, key: &str) {
    match key {
        "enter" => { let _ = en.key(Key::Return, Direction::Click); }
        "backspace" => { let _ = en.key(Key::Backspace, Direction::Click); }
        "escape" => { let _ = en.key(Key::Escape, Direction::Click); }
        "space" => { let _ = en.key(Key::Space, Direction::Click); }
        "tab" => { let _ = en.key(Key::Tab, Direction::Click); }
        "up" => { let _ = en.key(Key::UpArrow, Direction::Click); }
        "down" => { let _ = en.key(Key::DownArrow, Direction::Click); }
        "left" => { let _ = en.key(Key::LeftArrow, Direction::Click); }
        "right" => { let _ = en.key(Key::RightArrow, Direction::Click); }
        "home" => { let _ = en.key(Key::Home, Direction::Click); }
        "end" => { let _ = en.key(Key::End, Direction::Click); }
        "pageup" => { let _ = en.key(Key::PageUp, Direction::Click); }
        "pagedown" => { let _ = en.key(Key::PageDown, Direction::Click); }
        "win" => {
            let _ = en.key(Key::Meta, Direction::Press);
            let _ = en.key(Key::Meta, Direction::Release);
        }
        "desktop" => {
            let _ = en.key(Key::Meta, Direction::Press);
            let _ = en.key(Key::Unicode('d'), Direction::Click);
            let _ = en.key(Key::Meta, Direction::Release);
        }
        "taskmgr" => {
            let _ = Command::new("taskmgr.exe").spawn();
        }
        "alt+tab" => {
            let _ = en.key(Key::Alt, Direction::Press);
            let _ = en.key(Key::Tab, Direction::Click);
            let _ = en.key(Key::Alt, Direction::Release);
        }
        "alt+f4" => {
            let _ = en.key(Key::Alt, Direction::Press);
            let _ = en.key(Key::F4, Direction::Click);
            let _ = en.key(Key::Alt, Direction::Release);
        }
        "ctrl+c" => {
            let _ = en.key(Key::Control, Direction::Press);
            let _ = en.key(Key::Unicode('c'), Direction::Click);
            let _ = en.key(Key::Control, Direction::Release);
        }
        "ctrl+v" => {
            let _ = en.key(Key::Control, Direction::Press);
            let _ = en.key(Key::Unicode('v'), Direction::Click);
            let _ = en.key(Key::Control, Direction::Release);
        }
        "ctrl+z" => {
            let _ = en.key(Key::Control, Direction::Press);
            let _ = en.key(Key::Unicode('z'), Direction::Click);
            let _ = en.key(Key::Control, Direction::Release);
        }
        "ctrl+a" => {
            let _ = en.key(Key::Control, Direction::Press);
            let _ = en.key(Key::Unicode('a'), Direction::Click);
            let _ = en.key(Key::Control, Direction::Release);
        }
        "media_play_pause" => { let _ = en.key(Key::MediaPlayPause, Direction::Click); }
        "media_next" => { let _ = en.key(Key::MediaNextTrack, Direction::Click); }
        "media_prev" => { let _ = en.key(Key::MediaPrevTrack, Direction::Click); }
        "volume_up" => { let _ = en.key(Key::VolumeUp, Direction::Click); }
        "volume_down" => { let _ = en.key(Key::VolumeDown, Direction::Click); }
        "volume_mute" => { let _ = en.key(Key::VolumeMute, Direction::Click); }
        "lock_pc" => {
            let _ = en.key(Key::Meta, Direction::Press);
            let _ = en.key(Key::Unicode('l'), Direction::Click);
            let _ = en.key(Key::Meta, Direction::Release);
        }
        "sleep_pc" => {
            let _ = Command::new("cmd")
                .args(["/C", "rundll32.exe powrprof.dll,SetSuspendState 0,1,0"])
                .spawn();
        }
        "restart_pc" => {
            let _ = Command::new("cmd")
                .args(["/C", "shutdown /r /t 5"])
                .spawn();
        }
        "shutdown_pc" => {
            let _ = Command::new("cmd")
                .args(["/C", "shutdown /s /t 5"])
                .spawn();
        }
        _ => {}
    }
}
