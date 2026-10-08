import React, { useState } from 'react';
import {
  Smartphone,
  Monitor,
  Wifi,
  ShieldCheck,
  CheckCircle2,
  AlertTriangle,
  ArrowRight,
  Terminal,
  Copy,
  Check,
  Radio,
  Share2,
  HelpCircle,
  QrCode
} from 'lucide-react';

export const ConnectionGuide: React.FC = () => {
  const [userIp, setUserIp] = useState('192.168.1.45');
  const [copiedCmd, setCopiedCmd] = useState<string | null>(null);

  const copyToClipboard = (text: string, id: string) => {
    navigator.clipboard.writeText(text);
    setCopiedCmd(id);
    setTimeout(() => setCopiedCmd(null), 2000);
  };

  return (
    <div className="space-y-8">
      {/* Hero Header */}
      <div className="bg-slate-900 border border-slate-800 rounded-2xl p-6 shadow-xl">
        <div className="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4">
          <div className="flex items-center gap-3">
            <div className="p-3 bg-sky-500/10 border border-sky-500/20 rounded-xl text-sky-400">
              <Wifi className="w-6 h-6" />
            </div>
            <div>
              <h2 className="text-lg font-bold text-white">Zero-Setup Connection (No Commands Needed)</h2>
              <p className="text-xs text-slate-400 mt-0.5">
                The Windows .exe automatically requests Administrator rights, configures your firewall, and broadcasts to your mobile app
              </p>
            </div>
          </div>

          <div className="flex items-center gap-2">
            <div className="px-3 py-1.5 bg-emerald-500/10 border border-emerald-500/20 rounded-xl flex items-center gap-2 text-xs font-mono text-emerald-400">
              <ShieldCheck className="w-4 h-4 text-emerald-400" />
              <span>Auto-Admin UAC + Auto-Firewall</span>
            </div>
            <div className="px-3 py-1.5 bg-sky-500/10 border border-sky-500/20 rounded-xl flex items-center gap-2 text-xs font-mono text-sky-400">
              <Radio className="w-4 h-4 text-sky-400 animate-pulse" />
              <span>UDP 1-Click Discovery</span>
            </div>
          </div>
        </div>
      </div>

      {/* 4 Step Process Cards */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
        {/* Step 1 */}
        <div className="bg-slate-900 border border-slate-800 rounded-2xl p-5 shadow-xl flex flex-col justify-between space-y-4">
          <div className="space-y-3">
            <div className="flex items-center justify-between">
              <span className="w-7 h-7 rounded-lg bg-sky-500/20 border border-sky-500/30 text-sky-400 font-bold text-xs flex items-center justify-center">
                1
              </span>
              <Monitor className="w-4 h-4 text-slate-500" />
            </div>
            <h3 className="text-sm font-semibold text-white">Run .exe on Windows</h3>
            <p className="text-xs text-slate-300 leading-relaxed">
              Double-click <code className="text-sky-300 font-mono text-[11px]">remote_pc_host.exe</code>. A command window opens, starts the DXGI capture loop, and prints your local IP address.
            </p>
          </div>
          <div className="bg-slate-950 p-2.5 rounded-lg border border-slate-800 font-mono text-[11px] text-slate-400">
            [+] YOUR PC IP: <span className="text-emerald-400 font-bold">192.168.1.45</span>
          </div>
        </div>

        {/* Step 2 */}
        <div className="bg-slate-900 border border-slate-800 rounded-2xl p-5 shadow-xl flex flex-col justify-between space-y-4">
          <div className="space-y-3">
            <div className="flex items-center justify-between">
              <span className="w-7 h-7 rounded-lg bg-sky-500/20 border border-sky-500/30 text-sky-400 font-bold text-xs flex items-center justify-center">
                2
              </span>
              <ShieldCheck className="w-4 h-4 text-slate-500" />
            </div>
            <h3 className="text-sm font-semibold text-white">Allow Firewall Access</h3>
            <p className="text-xs text-slate-300 leading-relaxed">
              Windows will display a security prompt: <em>&quot;Windows Defender Firewall has blocked some features&quot;</em>.
            </p>
          </div>
          <div className="bg-slate-950 p-2.5 rounded-lg border border-slate-800 text-[11px] text-emerald-300 flex items-center gap-1.5">
            <CheckCircle2 className="w-3.5 h-3.5 text-emerald-400 shrink-0" />
            <span>Check <strong>&quot;Private networks&quot;</strong> &amp; click Allow</span>
          </div>
        </div>

        {/* Step 3 */}
        <div className="bg-slate-900 border border-slate-800 rounded-2xl p-5 shadow-xl flex flex-col justify-between space-y-4">
          <div className="space-y-3">
            <div className="flex items-center justify-between">
              <span className="w-7 h-7 rounded-lg bg-sky-500/20 border border-sky-500/30 text-sky-400 font-bold text-xs flex items-center justify-center">
                3
              </span>
              <Wifi className="w-4 h-4 text-slate-500" />
            </div>
            <h3 className="text-sm font-semibold text-white">Connect to Same Wi-Fi</h3>
            <p className="text-xs text-slate-300 leading-relaxed">
              Verify your Android phone is connected to the same home/office Wi-Fi router (or mobile personal hotspot) as your PC.
            </p>
          </div>
          <div className="bg-slate-950 p-2.5 rounded-lg border border-slate-800 text-[11px] text-slate-400">
            Both devices on same subnet (e.g. 192.168.1.x)
          </div>
        </div>

        {/* Step 4 */}
        <div className="bg-slate-900 border border-slate-800 rounded-2xl p-5 shadow-xl flex flex-col justify-between space-y-4">
          <div className="space-y-3">
            <div className="flex items-center justify-between">
              <span className="w-7 h-7 rounded-lg bg-sky-500/20 border border-sky-500/30 text-sky-400 font-bold text-xs flex items-center justify-center">
                4
              </span>
              <Smartphone className="w-4 h-4 text-slate-500" />
            </div>
            <h3 className="text-sm font-semibold text-white">Open App &amp; Tap Connect</h3>
            <p className="text-xs text-slate-300 leading-relaxed">
              In the Android app top bar, enter your PC&apos;s IP address plus port <strong>8765</strong>, then tap <strong>&quot;Connect&quot;</strong>.
            </p>
          </div>
          <div className="bg-sky-500/10 border border-sky-500/20 p-2.5 rounded-lg font-mono text-[11px] text-sky-300 text-center font-bold">
            192.168.1.45:8765
          </div>
        </div>
      </div>

      {/* Interactive Terminal Helper & IP Finder */}
      <div className="grid grid-cols-1 lg:grid-cols-12 gap-6">
        {/* Left Column: Windows Console Output Preview */}
        <div className="lg:col-span-6 bg-slate-900 border border-slate-800 rounded-2xl p-5 shadow-xl space-y-4">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-2">
              <Terminal className="w-4 h-4 text-sky-400" />
              <h3 className="text-sm font-semibold text-white">What You See in the PC Console</h3>
            </div>
            <span className="text-[11px] font-mono text-emerald-400">cmd.exe / PowerShell</span>
          </div>

          <div className="bg-slate-950 border border-slate-800 rounded-xl p-4 font-mono text-xs leading-relaxed text-slate-300 space-y-1 overflow-x-auto shadow-inner">
            <div className="text-slate-500">C:\Users\User\Downloads&gt; remote_pc_host.exe</div>
            <div className="text-slate-400">============================================================</div>
            <div className="text-sky-300 font-bold">  REMOTE PC HOST SERVER - WINDOWS DXGI + TOKIO WEBSOCKET   </div>
            <div className="text-slate-400">============================================================</div>
            <div className="text-slate-300">[DXGI] Initializing Windows DXGI Desktop Duplication API...</div>
            <div className="text-emerald-400">[DXGI] Successfully attached to primary GPU output adapter.</div>
            <div className="text-slate-500">------------------------------------------------------------</div>
            <div className="text-amber-300 font-bold">[+] YOUR PC&apos;S LOCAL IP ADDRESS: 192.168.1.45</div>
            <div className="text-sky-300">[+] ON YOUR MOBILE PHONE, ENTER:</div>
            <div className="text-emerald-400 font-bold pl-4">192.168.1.45:8765</div>
            <div className="text-sky-300">    THEN TAP &apos;CONNECT&apos;!</div>
            <div className="text-slate-500">------------------------------------------------------------</div>
            <div className="text-slate-400">[NETWORK] WebSocket Server listening on ws://0.0.0.0:8765</div>
            <div className="text-slate-400">[NETWORK] Waiting for Android Flutter Client connections...</div>
            <div className="text-emerald-400">[+] Client #1 connected from 192.168.1.88:51240</div>
          </div>

          <p className="text-xs text-slate-400 leading-normal">
            The server auto-detects your primary LAN network card and prints the exact IP and port to enter into your phone.
          </p>
        </div>

        {/* Right Column: Interactive IP Calculator & Troubleshooting */}
        <div className="lg:col-span-6 space-y-4">
          {/* Quick IP config tester */}
          <div className="bg-slate-900 border border-slate-800 rounded-2xl p-5 shadow-xl space-y-3">
            <h3 className="text-sm font-semibold text-white flex items-center gap-2">
              <Smartphone className="w-4 h-4 text-emerald-400" />
              Custom IP Address Helper
            </h3>
            <p className="text-xs text-slate-300">
              If your PC is on a different IP (e.g. 192.168.0.x or 10.0.0.x), enter it here to preview what to type on your phone:
            </p>

            <div className="flex gap-2">
              <input
                type="text"
                value={userIp}
                onChange={(e) => setUserIp(e.target.value)}
                placeholder="192.168.1.45"
                className="flex-1 bg-slate-950 border border-slate-800 rounded-lg px-3 py-2 text-xs font-mono text-white placeholder-slate-500 focus:outline-none focus:border-sky-400"
              />
              <button
                onClick={() => copyToClipboard(`${userIp.trim()}:8765`, 'ip')}
                className="px-3.5 py-2 bg-sky-600 hover:bg-sky-500 text-white text-xs font-medium rounded-lg flex items-center gap-1.5 transition-colors"
              >
                {copiedCmd === 'ip' ? <Check className="w-3.5 h-3.5 text-emerald-400" /> : <Copy className="w-3.5 h-3.5" />}
                <span>{copiedCmd === 'ip' ? 'Copied!' : 'Copy String'}</span>
              </button>
            </div>

            <div className="p-3 bg-slate-950 border border-slate-800 rounded-xl flex items-center justify-between text-xs">
              <span className="text-slate-400">Target to enter in Android app:</span>
              <span className="font-mono font-bold text-sky-400 text-sm">{userIp.trim()}:8765</span>
            </div>
          </div>

          {/* Quick Firewall Fix */}
          <div className="bg-slate-900 border border-slate-800 rounded-2xl p-5 shadow-xl space-y-3">
            <div className="flex items-center justify-between">
              <h3 className="text-sm font-semibold text-white flex items-center gap-2">
                <ShieldCheck className="w-4 h-4 text-amber-400" />
                Firewall 1-Click PowerShell Command
              </h3>
              <button
                onClick={() =>
                  copyToClipboard(
                    'netsh advfirewall firewall add rule name="RemotePC_Host" dir=in action=allow protocol=TCP localport=8765',
                    'firewall'
                  )
                }
                className="text-xs text-sky-400 hover:text-sky-300 flex items-center gap-1"
              >
                {copiedCmd === 'firewall' ? <Check className="w-3 h-3 text-emerald-400" /> : <Copy className="w-3 h-3" />}
                <span>{copiedCmd === 'firewall' ? 'Copied Command!' : 'Copy'}</span>
              </button>
            </div>
            <p className="text-xs text-slate-300">
              If your phone shows &quot;Connection error&quot; or hangs, run this once in <strong>PowerShell as Administrator</strong>:
            </p>
            <div className="bg-slate-950 p-2.5 rounded-lg border border-slate-800 font-mono text-[11px] text-amber-300 overflow-x-auto select-all">
              netsh advfirewall firewall add rule name=&quot;RemotePC_Host&quot; dir=in action=allow protocol=TCP localport=8765
            </div>
          </div>
        </div>
      </div>

      {/* Troubleshooting Matrix */}
      <div className="bg-slate-900 border border-slate-800 rounded-2xl p-6 shadow-xl space-y-4">
        <h3 className="text-sm font-semibold text-white flex items-center gap-2">
          <HelpCircle className="w-4 h-4 text-sky-400" />
          Troubleshooting Checklist
        </h3>

        <div className="grid grid-cols-1 md:grid-cols-3 gap-4 text-xs">
          <div className="p-4 bg-slate-950 border border-slate-800 rounded-xl space-y-2">
            <div className="flex items-center gap-2 font-semibold text-white">
              <AlertTriangle className="w-4 h-4 text-amber-400" />
              <span>&quot;Failed to Connect&quot;</span>
            </div>
            <p className="text-slate-400 leading-relaxed text-[11px]">
              Usually caused by Windows Firewall blocking inbound port 8765. Make sure your network in Windows Settings is set to <strong>&quot;Private Network&quot;</strong> rather than &quot;Public&quot;, or run the firewall rule above.
            </p>
          </div>

          <div className="p-4 bg-slate-950 border border-slate-800 rounded-xl space-y-2">
            <div className="flex items-center gap-2 font-semibold text-white">
              <Wifi className="w-4 h-4 text-sky-400" />
              <span>Router AP / Client Isolation</span>
            </div>
            <p className="text-slate-400 leading-relaxed text-[11px]">
              Some public or university Wi-Fi networks enable &quot;AP Isolation&quot;, which blocks wireless devices from talking to each other. <strong>Solution:</strong> Turn on your mobile phone&apos;s Mobile Hotspot, connect your PC to it, and connect instantly!
            </p>
          </div>

          <div className="p-4 bg-slate-950 border border-slate-800 rounded-xl space-y-2">
            <div className="flex items-center gap-2 font-semibold text-white">
              <CheckCircle2 className="w-4 h-4 text-emerald-400" />
              <span>Verifying Connection</span>
            </div>
            <p className="text-slate-400 leading-relaxed text-[11px]">
              Once connected, the phone header displays a green dot, live latency in milliseconds (e.g. <strong>12ms</strong>), and live FPS. You can immediately drag to move the mouse or tap to click!
            </p>
          </div>
        </div>
      </div>
    </div>
  );
};
