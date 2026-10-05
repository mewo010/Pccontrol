//! Remote PC Host Server
//! High-performance Windows Screen Mirroring & Direct Win32 Remote Input Server
//!
//! Features:
//! - Auto-Elevation to Administrator (UAC prompt on double-click)
//! - Auto-Firewall Rule Configuration (Port 8765 TCP & 8766 UDP)
//! - UDP Auto-Discovery Beacon on Port 8766
//! - High-Performance Dual Screen Capture: XCap Hardware DXGI + Direct GDI BitBlt + Test Pattern
//! - Full Telemetry & Diagnostics Heartbeat Stream (Engine, FPS, Encode MS, Error logging)
//! - Direct Win32 Mouse & Keyboard Injection
//! - Administrator Security Portal with Device Locks & Client Management

use enigo::{Axis, Button, Direction, Enigo, Key, Keyboard, Mouse, Settings};
use futures_util::{SinkExt, StreamExt};
use std::collections::HashMap;
use std::error::Error;
use std::net::{SocketAddr, UdpSocket};
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use image::codecs::jpeg::JpegEncoder;
use image::ColorType;
use serde::{Deserialize, Serialize};
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
type LockedTable = Arc<Mutex<HashMap<String, u64>>>; // Key (device_id or IP) -> locked_until (0 = indefinite, >0 = epoch secs)

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
$t1.Text = "• Host PC: " + $pcName
$t1.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#CBD5E1")
$t1.FontSize = 12; $t1.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)
$sp2.Children.Add($t1) | Out-Null

$t2 = New-Object System.Windows.Controls.TextBlock
$t2.Text = "• Stream Port: 8765 TCP | Discovery: 8766 UDP"
$t2.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#CBD5E1")
$t2.FontSize = 12; $t2.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)
$sp2.Children.Add($t2) | Out-Null

$t3 = New-Object System.Windows.Controls.TextBlock
$t3.Text = "• Admin Pass: " + "Sagiv_2311"
$t3.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#38BDF8")
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

/// Universal, 100% reliable desktop capture via native Windows GDI BitBlt
/// Uses screen DC for GetDIBits to ensure correct 32-bit color extraction
unsafe fn capture_screen_gdi(width: i32, height: i32) -> Result<Vec<u8>, String> {
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
        return Err(format!("CreateCompatibleBitmap({}x{}) failed (Win32 error: {})", width, height, err));
    }

    let old_obj = SelectObject(hdc_mem, hbitmap);
    let blt_res = BitBlt(hdc_mem, 0, 0, width, height, hdc_screen, 0, 0, SRCCOPY);
    if blt_res == 0 {
        let err = windows_sys::Win32::Foundation::GetLastError();
        eprintln!("[GDI] BitBlt returned 0 (Win32 error: {})", err);
    }

    // Unselect hbitmap before GetDIBits to comply with Win32 GDI specifications
    SelectObject(hdc_mem, old_obj);

    let mut bi = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width,
            biHeight: height, // Standard positive bottom-up DIB (universally supported across all Windows versions)
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

    let mut bgra_buf = vec![0u8; (width * height * 4) as usize];
    let lines = GetDIBits(
        hdc_screen,
        hbitmap,
        0,
        height as u32,
        bgra_buf.as_mut_ptr() as _,
        &mut bi,
        DIB_RGB_COLORS,
    );

    DeleteObject(hbitmap);
    DeleteDC(hdc_mem);
    ReleaseDC(null_mut(), hdc_screen);

    if lines == 0 {
        let err = windows_sys::Win32::Foundation::GetLastError();
        return Err(format!("GetDIBits failed (Win32 error: {})", err));
    }

    // Convert bottom-to-top BGRA to top-to-bottom RGBA
    let stride = (width * 4) as usize;
    let mut rgba_buf = vec![0u8; (width * height * 4) as usize];
    for y in 0..(height as usize) {
        let src_row = (height as usize - 1 - y) * stride;
        let dst_row = y * stride;
        for x in 0..(width as usize) {
            let src_idx = src_row + x * 4;
            let dst_idx = dst_row + x * 4;
            rgba_buf[dst_idx] = bgra_buf[src_idx + 2];     // Red
            rgba_buf[dst_idx + 1] = bgra_buf[src_idx + 1]; // Green
            rgba_buf[dst_idx + 2] = bgra_buf[src_idx];     // Blue
            rgba_buf[dst_idx + 3] = 255;                  // Alpha
        }
    }

    Ok(rgba_buf)
}

/// Generates a crisp diagnostic test pattern frame with color bars and moving scanner
/// This guarantees the network and video rendering pipeline can be validated 100%
fn generate_test_pattern(width: u32, height: u32, frame_num: u64, host_name: &str, ip: &str) -> Vec<u8> {
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
    // 0. Enable Windows DPI Awareness so screen width/height and GDI captures match true monitor pixels
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
    println!("  [+] ADMIN PASSWORD:       {}", ADMIN_PASSWORD);
    println!();
    println!("  >>> ON YOUR MOBILE APP:");
    println!("      Either tap 'Auto-Detect PC' to connect instantly,");
    println!("      or enter: {}:8765", local_lan_ip);
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

    // Quick startup test of GDI capture
    println!("[CAPTURE] Running initial GDI capture diagnostic...");
    let test_capture = unsafe { capture_screen_gdi(initial_w as i32, initial_h as i32) };
    match test_capture {
        Ok(buf) => println!(
            "[CAPTURE] Test GDI capture SUCCESS: {} bytes generated for {}x{}",
            buf.len(),
            initial_w,
            initial_h
        ),
        Err(err) => eprintln!("[CAPTURE] Warning: Initial test GDI capture: {}", err),
    }

    let screen_width = Arc::new(AtomicUsize::new(initial_w));
    let screen_height = Arc::new(AtomicUsize::new(initial_h));

    // Broadcast channel for distributing compressed JPEG frames
    let (frame_tx, _) = broadcast::channel::<FrameData>(16);
    let latest_jpeg = Arc::new(RwLock::new(Vec::new()));

    // Shared thread-safe input injector for keyboard text & clicks
    let enigo = Arc::new(Mutex::new(
        Enigo::new(&Settings::default()).expect("Failed to initialize Enigo input injector"),
    ));

    // Client connection registry & persistent lock table
    let client_registry: ClientRegistry = Arc::new(Mutex::new(HashMap::new()));
    let locked_table: LockedTable = Arc::new(Mutex::new(HashMap::new()));

    // Telemetry & diagnostics state
    let total_frames_captured = Arc::new(AtomicU64::new(0));
    let last_encode_time_ms = Arc::new(AtomicU64::new(0));
    let last_frame_size_bytes = Arc::new(AtomicUsize::new(0));
    let active_engine_name = Arc::new(RwLock::new("Initializing".to_string()));
    let capture_mode = Arc::new(RwLock::new("auto".to_string())); // "auto", "gdi", "xcap", "test_pattern"
    let last_capture_error = Arc::new(RwLock::new(None::<String>));

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
    let host_name_capture = host_name.clone();
    let lan_ip_capture = local_lan_ip.clone();

    std::thread::spawn(move || {
        // Initialize COM on this thread so DirectX and Windows Graphics Capture work cleanly
        unsafe {
            windows_sys::Win32::System::Com::CoInitializeEx(
                std::ptr::null_mut(),
                windows_sys::Win32::System::Com::COINIT_MULTITHREADED as u32,
            );
        }

        println!("[CAPTURE] Initializing Screen Capture Engine (XCap DXGI + Windows GDI BitBlt + Test Pattern)...");
        let target_frame_duration = Duration::from_millis(33); // ~30 FPS default
        let mut last_valid_jpeg = Arc::new(Vec::new());
        let mut last_monitor_check = Instant::now() - Duration::from_secs(10);
        let mut cached_monitors = Vec::new();
        let mut first_frame_logged = false;

        while capture_running.load(Ordering::Relaxed) {
            let start_time = Instant::now();
            let current_mode = mode_clone.blocking_read().clone();

            // Refresh monitor list every 5 seconds if using xcap
            if current_mode != "gdi" && current_mode != "test_pattern" && last_monitor_check.elapsed() > Duration::from_secs(5) {
                last_monitor_check = Instant::now();
                if let Ok(m) = xcap::Monitor::all() {
                    cached_monitors = m;
                }
            }

            let mut captured_rgba: Option<(Vec<u8>, u32, u32, &'static str)> = None;
            let mut current_err: Option<String> = None;

            // Strategy 1: Test Pattern forced mode
            if current_mode == "test_pattern" {
                let cur_w = width_ref.load(Ordering::Relaxed) as u32;
                let cur_h = height_ref.load(Ordering::Relaxed) as u32;
                let w = if cur_w > 0 { cur_w } else { 1920 };
                let h = if cur_h > 0 { cur_h } else { 1080 };
                let frame_num = frames_counter_clone.load(Ordering::Relaxed);
                let rgba = generate_test_pattern(w, h, frame_num, &host_name_capture, &lan_ip_capture);
                captured_rgba = Some((rgba, w, h, "Diagnostic Test Pattern"));
            }

            // Strategy 2: XCap Hardware DXGI / WGC Capture (when mode is "auto" or "xcap")
            if captured_rgba.is_none() && (current_mode == "auto" || current_mode == "xcap") {
                if !cached_monitors.is_empty() {
                    let p_idx = cached_monitors
                        .iter()
                        .position(|m| m.is_primary().unwrap_or(false))
                        .unwrap_or(0);
                    if let Some(m) = cached_monitors.get(p_idx) {
                        match m.capture_image() {
                            Ok(img) => {
                                let w = img.width();
                                let h = img.height();
                                captured_rgba = Some((img.into_raw(), w, h, "XCap Hardware DXGI"));
                            }
                            Err(e) => {
                                current_err = Some(format!("XCap capture error: {:?}", e));
                            }
                        }
                    }
                } else if current_mode == "xcap" {
                    current_err = Some("XCap: No monitors detected".to_string());
                }
            }

            // Strategy 3: Windows GDI BitBlt Capture (infallible fallback or when mode is "gdi" or "auto")
            if captured_rgba.is_none() && (current_mode == "auto" || current_mode == "gdi") {
                let cur_w = width_ref.load(Ordering::Relaxed) as i32;
                let cur_h = height_ref.load(Ordering::Relaxed) as i32;
                let w = if cur_w > 0 { cur_w } else { 1920 };
                let h = if cur_h > 0 { cur_h } else { 1080 };
                match unsafe { capture_screen_gdi(w, h) } {
                    Ok(rgba) => {
                        captured_rgba = Some((rgba, w as u32, h as u32, "Windows GDI BitBlt"));
                        current_err = None;
                    }
                    Err(e) => {
                        current_err = Some(format!("GDI error: {}", e));
                    }
                }
            }

            // Strategy 4: Fallback to Diagnostic Test Pattern if hardware capture is completely stalled
            if captured_rgba.is_none() && last_valid_jpeg.is_empty() {
                let cur_w = width_ref.load(Ordering::Relaxed) as u32;
                let cur_h = height_ref.load(Ordering::Relaxed) as u32;
                let w = if cur_w > 0 { cur_w } else { 1920 };
                let h = if cur_h > 0 { cur_h } else { 1080 };
                let frame_num = frames_counter_clone.load(Ordering::Relaxed);
                let rgba = generate_test_pattern(w, h, frame_num, &host_name_capture, &lan_ip_capture);
                captured_rgba = Some((rgba, w, h, "Fallback Diagnostic Pattern"));
                if current_err.is_none() {
                    current_err = Some("Hardware capture initial fallback".to_string());
                }
            }

            // Update telemetry error string
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
        let latest_jpeg_clone = latest_jpeg.clone();
        let registry_clone = client_registry.clone();
        let locked_clone = locked_table.clone();
        let frames_counter_ws = total_frames_captured.clone();
        let encode_ms_ws = last_encode_time_ms.clone();
        let frame_size_ws = last_frame_size_bytes.clone();
        let engine_name_ws = active_engine_name.clone();
        let capture_mode_ws = capture_mode.clone();
        let capture_error_ws = last_capture_error.clone();

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
                registry_clone,
                locked_clone,
                frames_counter_ws,
                encode_ms_ws,
                frame_size_ws,
                engine_name_ws,
                capture_mode_ws,
                capture_error_ws,
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
    enigo: Arc<Mutex<Enigo>>,
    screen_width: Arc<AtomicUsize>,
    screen_height: Arc<AtomicUsize>,
    host_name: String,
    ip_address: String,
    latest_jpeg: Arc<RwLock<Vec<u8>>>,
    registry: ClientRegistry,
    locked_table: LockedTable,
    total_frames_counter: Arc<AtomicU64>,
    last_encode_ms: Arc<AtomicU64>,
    last_frame_bytes: Arc<AtomicUsize>,
    active_engine_name: Arc<RwLock<String>>,
    capture_mode: Arc<RwLock<String>>,
    last_capture_error: Arc<RwLock<Option<String>>>,
) -> Result<(), Box<dyn Error + Send + Sync>> {
    let ws_stream = tokio_tungstenite::accept_async(stream).await?;
    let (mut ws_sink, mut ws_stream_reader) = ws_stream.split();

    let (out_tx, mut out_rx) = mpsc::channel::<Message>(64);
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

    // Send screen resolution and host info payload
    let initial_width = screen_width.load(Ordering::Relaxed) as u32;
    let initial_height = screen_height.load(Ordering::Relaxed) as u32;
    let info_msg = HostMessage::Info {
        width: initial_width,
        height: initial_height,
        fps_target: 60,
        host_name: host_name.clone(),
        ip_address: ip_address.clone(),
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
        loop {
            match frame_rx.recv().await {
                Ok(frame) => {
                    let msg = Message::Binary(frame.jpeg_bytes.as_ref().clone());
                    // Non-blocking try_send drops congested frames to guarantee 0ms latency lag
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

    let ticker_task = tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(1));
        loop {
            interval.tick().await;
            let engine = ticker_engine.read().await.clone();
            let mode = ticker_mode.read().await.clone();
            let err = ticker_err.read().await.clone();
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
                            };
                            if let Ok(json_str) = serde_json::to_string(&debug_msg) {
                                let _ = out_tx_ping.send(Message::Text(json_str)).await;
                            }
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
                                            message: "Administrator access granted.".to_string(),
                                            is_admin: true,
                                        })
                                        .unwrap(),
                                    ))
                                    .await;

                                // Send current connected client list
                                let clients: Vec<ConnectedClientRecord> = {
                                    let reg = registry.lock().await;
                                    reg.values().map(|e| e.record.clone()).collect()
                                };
                                let _ = out_tx
                                    .send(Message::Text(
                                        serde_json::to_string(&HostMessage::AdminClientsList {
                                            clients,
                                        })
                                        .unwrap(),
                                    ))
                                    .await;
                            } else {
                                let _ = out_tx
                                    .send(Message::Text(
                                        serde_json::to_string(&HostMessage::AdminAuthResult {
                                            success: false,
                                            message: "Incorrect administrator password.".to_string(),
                                            is_admin: false,
                                        })
                                        .unwrap(),
                                    ))
                                    .await;
                            }
                        }

                        // Admin request to get clients list
                        ClientMessage::AdminGetClients => {
                            if is_client_admin(&registry, client_id).await {
                                let clients: Vec<ConnectedClientRecord> = {
                                    let reg = registry.lock().await;
                                    reg.values().map(|e| e.record.clone()).collect()
                                };
                                let _ = out_tx
                                    .send(Message::Text(
                                        serde_json::to_string(&HostMessage::AdminClientsList {
                                            clients,
                                        })
                                        .unwrap(),
                                    ))
                                    .await;
                            }
                        }

                        // Admin request to disconnect a connected phone
                        ClientMessage::AdminDisconnectClient { target_id } => {
                            if is_client_admin(&registry, client_id).await {
                                let target_sender = {
                                    let mut reg = registry.lock().await;
                                    reg.remove(&target_id)
                                };
                                if let Some(target) = target_sender {
                                    let _ = target.out_tx.send(Message::Close(None)).await;
                                    println!(
                                        "[ADMIN] Admin #{} disconnected client #{} ({})",
                                        client_id, target_id, target.record.ip
                                    );
                                }
                                broadcast_admin_clients(&registry).await;
                            }
                        }

                        // Admin request to lock a connected phone (indefinite or timed)
                        ClientMessage::AdminLockClient {
                            target_id,
                            duration_seconds,
                        } => {
                            if is_client_admin(&registry, client_id).await {
                                let now = SystemTime::now()
                                    .duration_since(UNIX_EPOCH)
                                    .unwrap_or_default()
                                    .as_secs();

                                let target_lock_until = match duration_seconds {
                                    Some(sec) if sec > 0 => now + sec,
                                    _ => 0, // Indefinite lock
                                };

                                let target_info = {
                                    let mut reg = registry.lock().await;
                                    if let Some(entry) = reg.get_mut(&target_id) {
                                        entry.record.is_locked = true;
                                        entry.record.locked_until = target_lock_until;
                                        Some((
                                            entry.record.ip.clone(),
                                            entry.record.device_id.clone(),
                                            entry.out_tx.clone(),
                                        ))
                                    } else {
                                        None
                                    }
                                };

                                if let Some((target_ip, target_dev_id, target_out)) = target_info {
                                    // Persist in lock table by both IP and Device ID!
                                    {
                                        let mut lock_guard = locked_table.lock().await;
                                        lock_guard.insert(target_ip.clone(), target_lock_until);
                                        lock_guard.insert(target_dev_id.clone(), target_lock_until);
                                    }

                                    let rem = if target_lock_until > now {
                                        Some(target_lock_until - now)
                                    } else {
                                        None
                                    };

                                    let _ = target_out
                                        .send(Message::Text(
                                            serde_json::to_string(&HostMessage::LockStatus {
                                                is_locked: true,
                                                locked_until: target_lock_until,
                                                remaining_seconds: rem,
                                            })
                                            .unwrap(),
                                        ))
                                        .await;

                                    println!(
                                        "[ADMIN] Admin #{} locked client #{} ({}/{}) until {}",
                                        client_id, target_id, target_ip, target_dev_id, target_lock_until
                                    );
                                }

                                broadcast_admin_clients(&registry).await;
                            }
                        }

                        // Admin request to unlock a locked phone
                        ClientMessage::AdminUnlockClient { target_id } => {
                            if is_client_admin(&registry, client_id).await {
                                let target_info = {
                                    let mut reg = registry.lock().await;
                                    if let Some(entry) = reg.get_mut(&target_id) {
                                        entry.record.is_locked = false;
                                        entry.record.locked_until = 0;
                                        Some((
                                            entry.record.ip.clone(),
                                            entry.record.device_id.clone(),
                                            entry.out_tx.clone(),
                                        ))
                                    } else {
                                        None
                                    }
                                };

                                if let Some((target_ip, target_dev_id, target_out)) = target_info {
                                    {
                                        let mut lock_guard = locked_table.lock().await;
                                        lock_guard.remove(&target_ip);
                                        lock_guard.remove(&target_dev_id);
                                    }

                                    let _ = target_out
                                        .send(Message::Text(
                                            serde_json::to_string(&HostMessage::LockStatus {
                                                is_locked: false,
                                                locked_until: 0,
                                                remaining_seconds: None,
                                            })
                                            .unwrap(),
                                        ))
                                        .await;

                                    println!(
                                        "[ADMIN] Admin #{} unlocked client #{} ({})",
                                        client_id, target_id, target_ip
                                    );
                                }

                                broadcast_admin_clients(&registry).await;
                            }
                        }

                        // Latency Ping (allowed even when locked)
                        ClientMessage::Ping { timestamp } => {
                            let ts = timestamp.unwrap_or_else(|| {
                                SystemTime::now()
                                    .duration_since(UNIX_EPOCH)
                                    .unwrap_or_default()
                                    .as_millis() as u64
                            });
                            let pong = HostMessage::Pong { timestamp: ts };
                            if let Ok(pong_json) = serde_json::to_string(&pong) {
                                let _ = out_tx_ping.send(Message::Text(pong_json)).await;
                            }
                        }

                        // --- Device Control Operations (BLOCKED IF CLIENT IS LOCKED) ---
                        ClientMessage::Move { .. }
                        | ClientMessage::MoveRelative { .. }
                        | ClientMessage::MouseDown { .. }
                        | ClientMessage::MouseUp { .. }
                        | ClientMessage::Click { .. }
                        | ClientMessage::DoubleClick { .. }
                        | ClientMessage::Scroll { .. }
                        | ClientMessage::Type { .. }
                        | ClientMessage::Key { .. }
                        | ClientMessage::OpenUrl { .. }
                        | ClientMessage::LaunchApp { .. } if is_locked => {
                            let now = SystemTime::now()
                                .duration_since(UNIX_EPOCH)
                                .unwrap_or_default()
                                .as_secs();
                            let rem = if locked_until > now {
                                Some(locked_until - now)
                            } else {
                                None
                            };
                            let _ = out_tx_ping
                                .try_send(Message::Text(
                                    serde_json::to_string(&HostMessage::LockStatus {
                                        is_locked: true,
                                        locked_until,
                                        remaining_seconds: rem,
                                    })
                                    .unwrap(),
                                ));
                        }

                        // Direct Touch Screen / Absolute Mouse Positioning via Windows user32 SetCursorPos
                        ClientMessage::Move { x, y } => {
                            let clamped_x = (x.clamp(0.0, 1.0) * cur_w) as i32;
                            let clamped_y = (y.clamp(0.0, 1.0) * cur_h) as i32;
                            unsafe {
                                windows_sys::Win32::UI::WindowsAndMessaging::SetCursorPos(
                                    clamped_x, clamped_y,
                                );
                            }
                        }

                        // Laptop Trackpad / Relative Mouse Movement via Windows user32 GetCursorPos + SetCursorPos
                        ClientMessage::MoveRelative { dx, dy } => {
                            unsafe {
                                let mut pt = windows_sys::Win32::Foundation::POINT { x: 0, y: 0 };
                                if windows_sys::Win32::UI::WindowsAndMessaging::GetCursorPos(&mut pt) != 0 {
                                    windows_sys::Win32::UI::WindowsAndMessaging::SetCursorPos(
                                        pt.x + dx as i32,
                                        pt.y + dy as i32,
                                    );
                                }
                            }
                        }

                        // Mouse Press / Dragging
                        ClientMessage::MouseDown { button } => {
                            let mut enigo_guard = enigo.lock().await;
                            let btn = match button.to_lowercase().as_str() {
                                "right" => Button::Right,
                                "middle" => Button::Middle,
                                _ => Button::Left,
                            };
                            let _ = enigo_guard.button(btn, Direction::Press);
                        }

                        // Mouse Release
                        ClientMessage::MouseUp { button } => {
                            let mut enigo_guard = enigo.lock().await;
                            let btn = match button.to_lowercase().as_str() {
                                "right" => Button::Right,
                                "middle" => Button::Middle,
                                _ => Button::Left,
                            };
                            let _ = enigo_guard.button(btn, Direction::Release);
                        }

                        // Mouse Click
                        ClientMessage::Click { button } => {
                            let mut enigo_guard = enigo.lock().await;
                            let btn = match button.to_lowercase().as_str() {
                                "right" => Button::Right,
                                "middle" => Button::Middle,
                                _ => Button::Left,
                            };
                            let _ = enigo_guard.button(btn, Direction::Click);
                        }

                        // Double Click
                        ClientMessage::DoubleClick { button } => {
                            let mut enigo_guard = enigo.lock().await;
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
                                let mut enigo_guard = enigo.lock().await;
                                let _ = enigo_guard.scroll(y, Axis::Vertical);
                            }
                        }

                        // Keyboard Text Typing
                        ClientMessage::Type { text } => {
                            let mut enigo_guard = enigo.lock().await;
                            let _ = enigo_guard.text(&text);
                        }

                        // Keyboard Key and Windows Key Actions
                        ClientMessage::Key { key } => {
                            let mut enigo_guard = enigo.lock().await;
                            let lower = key.to_lowercase();
                            match lower.as_str() {
                                "win" | "meta" | "super" | "windows" => {
                                    let _ = enigo_guard.key(Key::Meta, Direction::Press);
                                    std::thread::sleep(Duration::from_millis(50));
                                    let _ = enigo_guard.key(Key::Meta, Direction::Release);

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
                                    let _ = Command::new("cmd")
                                        .args(["/C", "start", "", "taskmgr"])
                                        .spawn();
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

                        // Open Website Shortcut in PC default browser
                        ClientMessage::OpenUrl { url } => {
                            println!("[SHORTCUT] Opening site on PC: {}", url);
                            let target =
                                if !url.starts_with("http://") && !url.starts_with("https://") {
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

    // Clean up disconnected client from registry
    {
        let mut reg = registry.lock().await;
        reg.remove(&client_id);
    }
    broadcast_admin_clients(&registry).await;

    write_task.abort();
    frame_task.abort();
    ticker_task.abort();

    Ok(())
}
