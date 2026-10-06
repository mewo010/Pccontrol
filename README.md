# Remote PC Controller Suite 🚀

High-performance, ultra-low-latency Windows Remote Desktop Mirroring, Touchpad Control, and Device Management Suite.

Built with **Rust (Windows Host)** and **Flutter (Android Mobile Client)**.

---

## 🌟 Key Features

### 🖥️ Windows Host Server (`RemotePC-Host-Windows.exe`)
* **Reliable Screen Capture (`CAPTUREBLT` + `GdiFlush`)**: Captures modern Windows 10/11 desktops, Desktop Window Manager (DWM) compositing, hardware-accelerated browsers (Chrome, Edge), Discord, and games without blank or black screens.
* **Multi-Engine Desktop Fallback**:
  1. `Windows GDI DIBSection` (with `SRCCOPY | CAPTUREBLT` and `GdiFlush`)
  2. `Windows GDI Compatible Bitmap`
  3. `XCap DirectX / DXGI Desktop Duplication`
  4. `Animated Diagnostic Test Pattern`
* **Multi-Monitor & Virtual Screen Support**: Cycle between Primary Monitor and Virtual All-Displays.
* **Sleeping Screen Wakeup**: Detects sleeping PC monitors or locked displays and wakes them up automatically on request.
* **Outside Wi-Fi WAN Access & UPnP**: Automatically discovers public WAN IP and configures router port `8765 TCP` via UPnP.
* **Zero Setup Needed**: Prompts for UAC Administrator privileges on launch, opens inbound firewall rules for port `8765 TCP` and `8766 UDP`, and displays a native GUI with both Local and Public IP addresses.
* **Administrator Security Portal**: Password-protected (`Sagiv_2311`) client management with persistent device locking.

---

### 📱 Android Mobile Client (`RemotePC-Client-Android.apk`)
* **Dedicated Laptop Touchpad**:
  * Glide smoothly with adjustable cursor sensitivity.
  * Left Click, Right Click, Double Click, Drag Lock (Mouse Down).
  * Smooth vertical scroll strip and quick Windows shortcuts (`Win`, `Alt+Tab`, `Show Desktop`, `Task Manager`, `Esc`).
* **Live Screen Mirroring**:
  * Stream desktop screen with aspect ratio fit or stretch fill options.
  * Touch-to-click directly on the remote desktop, pan to drag, and long-press to right click.
  * **"Why Can't I See The Screen?" Live Diagnostics**: Step-by-step checklist inspecting network latency, capture engine, packet delivery, and Windows host errors with 1-tap repair buttons.
* **Seamless Outside-of-WiFi Auto-Failover**:
  * Connect on Home Wi-Fi once: the phone automatically memorizes your PC's Public WAN IP.
  * If you walk outside or turn off Wi-Fi, the app automatically switches to Mobile Data (4G/5G) and reconnects without manual setup.
* **Apps & Website Launcher**:
  * Launch PC applications (`Chrome`, `Edge`, `Explorer`, `Task Manager`, `Notepad`, `Calculator`, `CMD`) with 1 tap.
  * Open web shortcuts (`YouTube`, `Google`, `ChatGPT`, `Netflix`, `Twitch`, `Reddit`, `GitHub`) or add custom links.
  * Type text on phone keyboard and stream directly to active PC window.
* **Admin Security Portal**:
  * Enter password `Sagiv_2311` to inspect all connected phones.
  * Disconnect phones or apply timed/indefinite locks that persist even if the app is restarted.

---

## 🚀 Quickstart Guide

### Step 1: Run the Windows Host Server
1. Go to the [Releases](https://github.com/mewo010/Pccontrol/releases) section.
2. Download **`RemotePC-Host-Windows.exe`**.
3. Double-click to run. Click **Yes** when Windows prompts for Administrator privileges (this configures firewall rules).
4. A window will appear showing:
   * **1. Local Wi-Fi Address**: (e.g. `192.168.1.15:8765`)
   * **2. Outside Wi-Fi Address**: (e.g. `84.110.45.120:8765`)

### Step 2: Install the Android Mobile App
1. Download **`RemotePC-Client-Android.apk`** from [Releases](https://github.com/mewo010/Pccontrol/releases).
2. Install the APK on your Android smartphone or tablet.
3. Open the app.

### Step 3: Connect
* **On Home Wi-Fi**: Tap **Auto-Detect PC** in the top bar. The app will discover the PC within 1 second and connect automatically.
* **Outside Wi-Fi (4G/5G Mobile Data)**: Switch to the **Outside Wi-Fi** tab. Your saved PC public IP will be ready—tap **Connect**.

---

## 🔍 "Why Can't I See The Screen?" Troubleshooting

If your PC desktop screen does not appear or appears black in the **See Screen** tab:

1. **Tap "Screen Diagnostics"** at the top right of the See Screen tab.
2. The diagnosis panel will inspect all 4 parts of the pipeline:
   * **Network Link**: Checks if WebSocket packets are flowing.
   * **PC Capture Engine**: Verifies if Windows is capturing desktop frames.
   * **Packet Delivery**: Verifies if video bytes reach the phone.
   * **Windows Host Status**: Displays exact Win32 system errors.
3. **Use the 1-Tap Auto-Repair Buttons**:
   * 🟢 **AUTO-FIX: Force GDI Desktop Capture**: Forces Windows GDI BitBlt mode.
   * 💡 **Wake PC Sleeping Screen**: Sends a wake-up signal if Windows put monitors to sleep.
   * 🖥️ **Switch Primary / Virtual Display**: Toggles monitor capture if running dual displays.
   * 🌈 **Test Video Link (Color Pattern)**: Tests if the phone can render video frames.
   * 🔄 **Request Frame**: Pulls an immediate fresh frame from the PC.

---

## 🔒 Administrator Access & Device Locking

1. Navigate to the **Admin** tab on the phone.
2. Enter the administrator password:
   ```
   Sagiv_2311
   ```
3. Once unlocked, you can:
   * View all active phone connections, their IP addresses, and device IDs.
   * Disconnect any phone.
   * Lock a phone's app for **1 Minute**, **5 Minutes**, **15 Minutes**, **30 Minutes**, **1 Hour**, or **Indefinitely**.
   * Locks are persistent: even if the phone user closes and re-opens the app, the device remains locked until the timer expires or the administrator unlocks it.

---

## 🛠️ Building from Source

### Prerequisites
* **Rust**: `dtolnay/rust-toolchain@stable` or `cargo 1.75+`
* **Flutter SDK**: `3.24.x` with Android SDK 34+

### Build Windows Host (.exe)
```bash
cd host_pc
cargo build --release
# Binary generated at: target/release/remote_pc_host.exe
```

### Build Android Client (.apk)
```bash
cd client_mobile
flutter pub get
flutter build apk --release
# APK generated at: build/app/outputs/flutter-apk/app-release.apk
```

---

## 📦 Automated GitHub Releases

Every push to `main` automatically runs `.github/workflows/build-release.yml` on GitHub Actions:
* Compiles `remote_pc_host.exe` on `windows-latest`.
* Builds `RemotePC-Client-Android.apk` on `ubuntu-latest`.
* Publishes a GitHub Release with version title and release notes.
