import React, { useState, useEffect, useRef, useCallback } from 'react';
import {
  Monitor,
  Smartphone,
  Play,
  Square,
  Send,
  CornerDownLeft,
  Delete,
  XCircle,
  Activity,
  Layers,
  Sparkles,
  RefreshCw,
  Terminal,
  MousePointer,
  Cpu,
  Wifi,
  Radio,
  Sliders,
  CheckCircle2,
  Minimize2,
  Maximize2
} from 'lucide-react';

interface PacketLog {
  id: string;
  timestamp: string;
  direction: 'tx' | 'rx';
  type: string;
  payload: string;
  size?: string;
}

export const InteractiveSimulator: React.FC = () => {
  // Connection states
  const [isConnected, setIsConnected] = useState(true);
  const [isConnecting, setIsConnecting] = useState(false);
  const [ipAddress, setIpAddress] = useState('192.168.1.100:8765');
  const [fps, setFps] = useState(60);
  const [latency, setLatency] = useState(14);
  const [bandwidth, setBandwidth] = useState(1.4); // MB/s

  // Remote desktop virtual state
  const [cursorPos, setCursorPos] = useState({ x: 0.5, y: 0.5 }); // normalized 0..1
  const [clickRipples, setClickRipples] = useState<Array<{ id: number; x: number; y: number; button: string }>>([]);
  const [typedBuffer, setTypedBuffer] = useState<string>('cargo run --release\n[+] Server listening on 0.0.0.0:8765\n[+] Client attached via DXGI Desktop Duplication stream\n> ');
  const [typingInput, setTypingInput] = useState('');
  const [activeWindow, setActiveWindow] = useState<'terminal' | 'notepad'>('terminal');
  const [viewMode, setViewMode] = useState<'split' | 'mobile_only' | 'host_only'>('split');
  const [touchMode, setTouchMode] = useState<'direct' | 'trackpad'>('direct');

  // Logs
  const [logs, setLogs] = useState<PacketLog[]>([]);
  const [logFilter, setLogFilter] = useState<'all' | 'input' | 'frames'>('all');

  const mobileViewportRef = useRef<HTMLDivElement>(null);
  const desktopCanvasRef = useRef<HTMLCanvasElement>(null);
  const animFrameRef = useRef<number | null>(null);

  // Push log entry
  const addLog = useCallback((direction: 'tx' | 'rx', type: string, payload: object | string, size?: string) => {
    const now = new Date();
    const ts = `${now.toTimeString().split(' ')[0]}.${String(now.getMilliseconds()).padStart(3, '0')}`;
    const payloadStr = typeof payload === 'string' ? payload : JSON.stringify(payload);
    
    setLogs((prev) => [
      {
        id: Math.random().toString(36).substring(2, 9),
        timestamp: ts,
        direction,
        type,
        payload: payloadStr,
        size
      },
      ...prev.slice(0, 49) // Keep last 50 logs
    ]);
  }, []);

  // Connect / Disconnect toggle
  const handleToggleConnect = () => {
    if (isConnected) {
      setIsConnected(false);
      addLog('tx', 'close', 'Client initiated WebSocket disconnect');
    } else {
      setIsConnecting(true);
      setTimeout(() => {
        setIsConnecting(false);
        setIsConnected(true);
        addLog('tx', 'connect', `Connecting to ws://${ipAddress}`);
        addLog('rx', 'info', { width: 1920, height: 1080, fps_target: 60, host_name: 'Windows-Gaming-PC', ip_address: ipAddress });
      }, 400);
    }
  };

  // 1-Click Auto-Detect PC simulation
  const [isScanning, setIsScanning] = useState(false);
  const handleAutoDetect = () => {
    if (isScanning || isConnected) return;
    setIsScanning(true);
    addLog('tx', 'udp_discover', 'Broadcasting UDP ping to 255.255.255.255:8766');
    setTimeout(() => {
      addLog('rx', 'udp_beacon', 'Received REMOTE_PC_HOST:Windows-Gaming-PC:192.168.1.100:8765');
      setIpAddress('192.168.1.100:8765');
      setIsScanning(false);
      setIsConnecting(true);
      setTimeout(() => {
        setIsConnecting(false);
        setIsConnected(true);
        addLog('tx', 'connect', 'Auto-connecting to ws://192.168.1.100:8765');
        addLog('rx', 'info', { width: 1920, height: 1080, fps_target: 60, host_name: 'Windows-Gaming-PC', ip_address: '192.168.1.100' });
      }, 300);
    }, 600);
  };

  // Ping interval simulation
  useEffect(() => {
    if (!isConnected) return;
    const interval = setInterval(() => {
      const pingTs = Date.now();
      addLog('tx', 'ping', { type: 'ping', timestamp: pingTs });
      // Simulate real-world 10-25ms jitter
      const simulatedLatency = Math.floor(10 + Math.random() * 12);
      setTimeout(() => {
        setLatency(simulatedLatency);
        addLog('rx', 'pong', { type: 'pong', timestamp: pingTs });
      }, simulatedLatency);
    }, 3000);
    return () => clearInterval(interval);
  }, [isConnected, addLog]);

  // Screen mirroring simulated 60 FPS renderer
  useEffect(() => {
    let frameCount = 0;
    let lastTime = performance.now();

    const render = (time: number) => {
      if (desktopCanvasRef.current) {
        const canvas = desktopCanvasRef.current;
        const ctx = canvas.getContext('2d');
        if (ctx) {
          const w = canvas.width;
          const h = canvas.height;

          // Background wallpaper: Dark tech gradient
          const grad = ctx.createLinearGradient(0, 0, w, h);
          grad.addColorStop(0, '#0a0f1d');
          grad.addColorStop(0.5, '#0f172a');
          grad.addColorStop(1, '#1e1b4b');
          ctx.fillStyle = grad;
          ctx.fillRect(0, 0, w, h);

          // Subtle grid pattern
          ctx.strokeStyle = 'rgba(56, 189, 248, 0.05)';
          ctx.lineWidth = 1;
          for (let x = 0; x < w; x += 40) {
            ctx.beginPath();
            ctx.moveTo(x, 0);
            ctx.lineTo(x, h);
            ctx.stroke();
          }
          for (let y = 0; y < h; y += 40) {
            ctx.beginPath();
            ctx.moveTo(0, y);
            ctx.lineTo(w, y);
            ctx.stroke();
          }

          // Desktop Window: Terminal Console
          const termX = 40;
          const termY = 30;
          const termW = w - 80;
          const termH = h - 90;

          // Window shadow & body
          ctx.fillStyle = 'rgba(15, 23, 42, 0.92)';
          ctx.strokeStyle = activeWindow === 'terminal' ? 'rgba(56, 189, 248, 0.4)' : 'rgba(51, 65, 85, 0.6)';
          ctx.lineWidth = 1.5;
          ctx.beginPath();
          ctx.roundRect(termX, termY, termW, termH, 8);
          ctx.fill();
          ctx.stroke();

          // Title bar
          ctx.fillStyle = '#1e293b';
          ctx.beginPath();
          ctx.roundRect(termX, termY, termW, 32, [8, 8, 0, 0]);
          ctx.fill();

          // Window buttons
          ctx.fillStyle = '#ef4444';
          ctx.beginPath();
          ctx.arc(termX + 16, termY + 16, 5, 0, Math.PI * 2);
          ctx.fill();
          ctx.fillStyle = '#f59e0b';
          ctx.beginPath();
          ctx.arc(termX + 32, termY + 16, 5, 0, Math.PI * 2);
          ctx.fill();
          ctx.fillStyle = '#10b981';
          ctx.beginPath();
          ctx.arc(termX + 48, termY + 16, 5, 0, Math.PI * 2);
          ctx.fill();

          // Title text
          ctx.fillStyle = '#94a3b8';
          ctx.font = '12px ui-monospace, monospace';
          ctx.fillText('PowerShell (Administrator) - DXGI GPU Desktop Duplication Stream [1920x1080 @ 60 FPS]', termX + 66, termY + 20);

          // Terminal content lines
          ctx.fillStyle = '#38bdf8';
          ctx.font = '11px ui-monospace, monospace';
          const lines = typedBuffer.split('\n');
          const maxVisibleLines = 16;
          const visibleLines = lines.slice(-maxVisibleLines);
          visibleLines.forEach((line, idx) => {
            if (idx === visibleLines.length - 1) {
              ctx.fillStyle = '#4ade80';
              ctx.fillText(line, termX + 16, termY + 54 + idx * 18);
              // Blinking prompt cursor
              if (Math.floor(time / 500) % 2 === 0) {
                const textWidth = ctx.measureText(line).width;
                ctx.fillStyle = '#38bdf8';
                ctx.fillRect(termX + 16 + textWidth + 2, termY + 43 + idx * 18, 7, 13);
              }
            } else {
              ctx.fillStyle = line.startsWith('[+]') ? '#38bdf8' : (line.startsWith('>') ? '#e2e8f0' : '#94a3b8');
              ctx.fillText(line, termX + 16, termY + 54 + idx * 18);
            }
          });

          // Taskbar at bottom
          ctx.fillStyle = 'rgba(15, 23, 42, 0.95)';
          ctx.fillRect(0, h - 36, w, 36);
          ctx.strokeStyle = '#334155';
          ctx.beginPath();
          ctx.moveTo(0, h - 36);
          ctx.lineTo(w, h - 36);
          ctx.stroke();

          // Windows Start icon & pinned icons
          ctx.fillStyle = '#38bdf8';
          ctx.fillRect(16, h - 26, 16, 16);
          ctx.fillStyle = '#64748b';
          ctx.fillRect(40, h - 26, 16, 16);
          ctx.fillRect(64, h - 26, 16, 16);

          // System tray time
          const nowStr = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
          ctx.fillStyle = '#94a3b8';
          ctx.font = '11px sans-serif';
          ctx.fillText(nowStr, w - 65, h - 14);
          ctx.fillText('ENG', w - 100, h - 14);

          // Simulated remote mouse cursor
          const physX = cursorPos.x * w;
          const physY = cursorPos.y * h;

          ctx.save();
          ctx.shadowColor = 'rgba(0, 0, 0, 0.6)';
          ctx.shadowBlur = 6;
          ctx.fillStyle = '#ffffff';
          ctx.strokeStyle = '#000000';
          ctx.lineWidth = 1.5;
          ctx.beginPath();
          ctx.moveTo(physX, physY);
          ctx.lineTo(physX, physY + 16);
          ctx.lineTo(physX + 4.5, physY + 12.5);
          ctx.lineTo(physX + 9, physY + 20);
          ctx.lineTo(physX + 12, physY + 18.5);
          ctx.lineTo(physX + 7.5, physY + 11);
          ctx.lineTo(physX + 14, physY + 11);
          ctx.closePath();
          ctx.fill();
          ctx.stroke();
          ctx.restore();

          // Click ripple animation
          clickRipples.forEach((ripple) => {
            const rx = ripple.x * w;
            const ry = ripple.y * h;
            ctx.strokeStyle = ripple.button === 'right' ? '#f59e0b' : '#38bdf8';
            ctx.lineWidth = 2;
            ctx.beginPath();
            ctx.arc(rx, ry, (Date.now() - ripple.id) * 0.05, 0, Math.PI * 2);
            ctx.stroke();
          });
        }
      }

      frameCount++;
      if (time - lastTime >= 1000) {
        setFps(frameCount);
        frameCount = 0;
        lastTime = time;
      }

      animFrameRef.current = requestAnimationFrame(render);
    };

    animFrameRef.current = requestAnimationFrame(render);
    return () => {
      if (animFrameRef.current) cancelAnimationFrame(animFrameRef.current);
    };
  }, [cursorPos, typedBuffer, activeWindow, clickRipples]);

  // Clean old ripples
  useEffect(() => {
    const timer = setInterval(() => {
      const now = Date.now();
      setClickRipples((prev) => prev.filter((r) => now - r.id < 400));
    }, 100);
    return () => clearInterval(timer);
  }, []);

  // Handle touch or drag in mobile client viewport
  const handleTouch = (e: React.MouseEvent<HTMLDivElement> | React.TouchEvent<HTMLDivElement>, isClick = false, button = 'left') => {
    if (!isConnected || !mobileViewportRef.current) return;
    const rect = mobileViewportRef.current.getBoundingClientRect();

    let clientX = 0;
    let clientY = 0;

    if ('touches' in e && e.touches.length > 0) {
      clientX = e.touches[0].clientX;
      clientY = e.touches[0].clientY;
    } else if ('clientX' in e) {
      clientX = e.clientX;
      clientY = e.clientY;
    }

    const rawX = clientX - rect.left;
    const rawY = clientY - rect.top;

    // Viewport containment math (aspect ratio 16:9)
    const hostAspect = 16 / 9;
    const viewAspect = rect.width / rect.height;

    let renderedWidth = rect.width;
    let renderedHeight = rect.height;
    let offsetX = 0;
    let offsetY = 0;

    if (viewAspect > hostAspect) {
      renderedHeight = rect.height;
      renderedWidth = rect.height * hostAspect;
      offsetX = (rect.width - renderedWidth) / 2;
    } else {
      renderedWidth = rect.width;
      renderedHeight = rect.width / hostAspect;
      offsetY = (rect.height - renderedHeight) / 2;
    }

    const insideX = rawX - offsetX;
    const insideY = rawY - offsetY;

    if (insideX < 0 || insideX > renderedWidth || insideY < 0 || insideY > renderedHeight) {
      return;
    }

    const normX = Math.min(Math.max(insideX / renderedWidth, 0), 1);
    const normY = Math.min(Math.max(insideY / renderedHeight, 0), 1);

    setCursorPos({ x: normX, y: normY });
    addLog('tx', 'move', { type: 'move', x: Number(normX.toFixed(4)), y: Number(normY.toFixed(4)) });

    if (isClick) {
      setClickRipples((prev) => [...prev, { id: Date.now(), x: normX, y: normY, button }]);
      addLog('tx', 'click', { type: 'click', button });
    }
  };

  // Remote text injection
  const handleSendText = () => {
    if (!typingInput || !isConnected) return;
    const textToSend = typingInput;
    addLog('tx', 'type', { type: 'type', text: textToSend });
    setTypedBuffer((prev) => prev + textToSend);
    setTypingInput('');
  };

  // Remote system key injection
  const handleSendKey = (key: string) => {
    if (!isConnected) return;
    addLog('tx', 'key', { type: 'key', key });
    if (key === 'enter') {
      setTypedBuffer((prev) => prev + '\n> ');
    } else if (key === 'backspace') {
      setTypedBuffer((prev) => (prev.length > 2 ? prev.slice(0, -1) : prev));
    } else if (key === 'space') {
      setTypedBuffer((prev) => prev + ' ');
    } else if (key === 'tab') {
      setTypedBuffer((prev) => prev + '  ');
    } else if (key === 'escape') {
      setTypedBuffer((prev) => prev + '^C\n> ');
    }
  };

  const filteredLogs = logs.filter((l) => {
    if (logFilter === 'input') return ['move', 'click', 'type', 'key'].includes(l.type);
    if (logFilter === 'frames') return ['ping', 'pong', 'info', 'connect', 'close'].includes(l.type);
    return true;
  });

  return (
    <div className="space-y-6">
      {/* Top Controller Bar */}
      <div className="bg-slate-900 border border-slate-800 rounded-xl p-4 shadow-xl">
        <div className="flex flex-wrap items-center justify-between gap-4">
          <div className="flex items-center gap-3">
            <div className="p-2.5 bg-sky-500/10 border border-sky-500/20 rounded-lg text-sky-400">
              <Radio className="w-5 h-5 animate-pulse" />
            </div>
            <div>
              <div className="flex items-center gap-2">
                <h2 className="text-base font-semibold text-white">Live Simulator &amp; Protocol Inspector</h2>
                <span className={`w-2 h-2 rounded-full ${isConnected ? 'bg-emerald-400 animate-ping' : 'bg-rose-500'}`} />
              </div>
              <p className="text-xs text-slate-400">
                Interactive real-time testbed simulating Windows DXGI host and Android Flutter client over WebSocket
              </p>
            </div>
          </div>

          {/* Quick telemetry metrics */}
          <div className="flex items-center gap-3">
            <div className="flex items-center gap-1.5 px-3 py-1.5 bg-slate-950 border border-slate-800 rounded-lg">
              <Activity className="w-3.5 h-3.5 text-emerald-400" />
              <span className="text-xs text-slate-400">Latency:</span>
              <span className="text-xs font-mono font-semibold text-emerald-400">{latency}ms</span>
            </div>
            <div className="flex items-center gap-1.5 px-3 py-1.5 bg-slate-950 border border-slate-800 rounded-lg">
              <Cpu className="w-3.5 h-3.5 text-sky-400" />
              <span className="text-xs text-slate-400">Stream:</span>
              <span className="text-xs font-mono font-semibold text-sky-400">{fps} FPS</span>
            </div>
            <div className="flex items-center gap-1.5 px-3 py-1.5 bg-slate-950 border border-slate-800 rounded-lg">
              <Wifi className="w-3.5 h-3.5 text-amber-400" />
              <span className="text-xs text-slate-400">Throughput:</span>
              <span className="text-xs font-mono font-semibold text-amber-400">{bandwidth} MB/s</span>
            </div>

            {/* View Mode Switcher */}
            <div className="flex items-center p-1 bg-slate-950 border border-slate-800 rounded-lg">
              <button
                onClick={() => setViewMode('split')}
                className={`px-2.5 py-1 text-xs font-medium rounded transition-colors ${
                  viewMode === 'split' ? 'bg-slate-800 text-white shadow-sm' : 'text-slate-400 hover:text-white'
                }`}
                title="Side by Side Split View"
              >
                Split View
              </button>
              <button
                onClick={() => setViewMode('mobile_only')}
                className={`px-2.5 py-1 text-xs font-medium rounded transition-colors ${
                  viewMode === 'mobile_only' ? 'bg-slate-800 text-white shadow-sm' : 'text-slate-400 hover:text-white'
                }`}
                title="Android Client View"
              >
                Mobile
              </button>
              <button
                onClick={() => setViewMode('host_only')}
                className={`px-2.5 py-1 text-xs font-medium rounded transition-colors ${
                  viewMode === 'host_only' ? 'bg-slate-800 text-white shadow-sm' : 'text-slate-400 hover:text-white'
                }`}
                title="Windows PC Host Screen"
              >
                Host PC
              </button>
            </div>
          </div>
        </div>
      </div>

      {/* Main Interactive Stage */}
      <div className="grid grid-cols-1 lg:grid-cols-12 gap-6">
        {/* Left / Top: Mobile Android Client View */}
        {(viewMode === 'split' || viewMode === 'mobile_only') && (
          <div className={`${viewMode === 'split' ? 'lg:col-span-6' : 'lg:col-span-12'} flex flex-col`}>
            <div className="bg-slate-900 border border-slate-800 rounded-2xl overflow-hidden shadow-2xl flex flex-col h-full">
              {/* Flutter App Header Bar (Exact match to lib/main.dart) */}
              <div className="bg-slate-800/90 border-b border-slate-700/80 px-3.5 py-2 flex items-center justify-between gap-3">
                <div className="flex items-center gap-2.5 flex-1">
                  <div
                    className={`w-2.5 h-2.5 rounded-full ${
                      isConnected ? 'bg-emerald-400' : isConnecting || isScanning ? 'bg-amber-400' : 'bg-rose-500'
                    }`}
                  />
                  {!isConnected && (
                    <button
                      onClick={handleAutoDetect}
                      disabled={isScanning || isConnecting}
                      className="px-2.5 py-1 text-xs font-medium rounded-lg border border-sky-500/40 text-sky-400 hover:bg-sky-500/10 transition-colors flex items-center gap-1"
                      title="Simulate 1-Click UDP Auto-Discovery"
                    >
                      {isScanning ? (
                        <>
                          <RefreshCw className="w-3 h-3 animate-spin" />
                          <span>Scanning...</span>
                        </>
                      ) : (
                        <>
                          <Radio className="w-3 h-3" />
                          <span>Auto-Detect PC</span>
                        </>
                      )}
                    </button>
                  )}
                  <div className="relative flex-1 max-w-xs">
                    <input
                      type="text"
                      value={ipAddress}
                      onChange={(e) => setIpAddress(e.target.value)}
                      disabled={isConnected || isConnecting}
                      placeholder="192.168.1.100:8765"
                      className="w-full bg-slate-950/80 border border-slate-700/80 rounded-lg px-2.5 py-1 text-xs text-white placeholder-slate-500 focus:outline-none focus:border-sky-400"
                    />
                  </div>
                  <button
                    onClick={handleToggleConnect}
                    disabled={isConnecting}
                    className={`px-3 py-1 text-xs font-medium rounded-lg transition-colors flex items-center gap-1.5 ${
                      isConnected
                        ? 'bg-rose-600 hover:bg-rose-500 text-white'
                        : 'bg-sky-600 hover:bg-sky-500 text-white'
                    }`}
                  >
                    {isConnected ? (
                      <>
                        <Square className="w-3 h-3 fill-current" />
                        Disconnect
                      </>
                    ) : (
                      <>
                        <Play className="w-3 h-3 fill-current" />
                        Connect
                      </>
                    )}
                  </button>
                </div>

                <div className="flex items-center gap-2 text-[11px] font-mono">
                  <span className={latency < 50 ? 'text-emerald-400' : 'text-amber-400'}>{latency}ms</span>
                  <span className="text-slate-500">·</span>
                  <span className="text-sky-400">{fps}fps</span>
                </div>
              </div>

              {/* Mobile Viewport Screen Mirroring Frame */}
              <div className="relative flex-1 bg-black min-h-[340px] flex items-center justify-center p-2 select-none">
                <div
                  ref={mobileViewportRef}
                  onMouseMove={(e) => {
                    if (e.buttons === 1) handleTouch(e, false);
                  }}
                  onMouseDown={(e) => {
                    e.preventDefault();
                    handleTouch(e, true, e.button === 2 ? 'right' : 'left');
                  }}
                  onContextMenu={(e) => {
                    e.preventDefault();
                    handleTouch(e, true, 'right');
                  }}
                  onTouchMove={(e) => handleTouch(e, false)}
                  onTouchStart={(e) => handleTouch(e, true, 'left')}
                  className="relative w-full aspect-video max-w-full bg-slate-950 rounded-lg overflow-hidden cursor-crosshair border border-slate-800 shadow-inner group"
                >
                  {isConnected ? (
                    <>
                      {/* Mirrored Canvas Screen */}
                      <canvas
                        ref={desktopCanvasRef}
                        width={960}
                        height={540}
                        className="w-full h-full object-contain pointer-events-none"
                      />

                      {/* Touch Coordinate HUD Overlay */}
                      <div className="absolute top-2 left-2 pointer-events-none bg-slate-950/80 backdrop-blur border border-slate-800/80 px-2 py-1 rounded text-[10px] font-mono text-slate-300 flex items-center gap-2">
                        <MousePointer className="w-3 h-3 text-sky-400" />
                        <span>
                          Norm: ({cursorPos.x.toFixed(3)}, {cursorPos.y.toFixed(3)})
                        </span>
                        <span className="text-slate-500">|</span>
                        <span>
                          DXGI: ({(cursorPos.x * 1920).toFixed(0)}, {(cursorPos.y * 1080).toFixed(0)}) px
                        </span>
                      </div>

                      {/* Interactive Touch Hint */}
                      <div className="absolute bottom-2 right-2 pointer-events-none opacity-0 group-hover:opacity-100 transition-opacity bg-slate-950/80 backdrop-blur border border-slate-800/80 px-2 py-1 rounded text-[10px] text-slate-300">
                        Drag to move · Left/Right click to trigger
                      </div>
                    </>
                  ) : (
                    <div className="h-full flex flex-col items-center justify-center text-center p-6 text-slate-500">
                      <Monitor className="w-12 h-12 mb-3 text-slate-600 stroke-1" />
                      <p className="text-sm font-medium text-slate-300">Mobile Stream Disconnected</p>
                      <p className="text-xs text-slate-500 mt-1 max-w-xs">
                        Click &apos;Connect&apos; in the header above to establish WebSocket link to ws://{ipAddress}
                      </p>
                    </div>
                  )}
                </div>
              </div>

              {/* Mobile Action Bar (Typing bar + quick action chips) */}
              <div className="bg-slate-850 bg-slate-900 border-t border-slate-800 p-3 space-y-2.5">
                {/* Typing input */}
                <div className="flex gap-2">
                  <input
                    type="text"
                    value={typingInput}
                    onChange={(e) => setTypingInput(e.target.value)}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter') handleSendText();
                    }}
                    disabled={!isConnected}
                    placeholder="Type text to send to host PC..."
                    className="flex-1 bg-slate-950 border border-slate-800 rounded-lg px-3 py-1.5 text-xs text-white placeholder-slate-500 focus:outline-none focus:border-sky-400"
                  />
                  <button
                    onClick={handleSendText}
                    disabled={!isConnected || !typingInput}
                    className="px-3.5 py-1.5 bg-sky-500 hover:bg-sky-400 disabled:opacity-50 text-slate-950 text-xs font-semibold rounded-lg flex items-center gap-1.5 transition-colors"
                  >
                    <Send className="w-3.5 h-3.5" />
                    Send
                  </button>
                </div>

                {/* Quick Action Chips */}
                <div className="flex items-center gap-1.5 overflow-x-auto pb-1 text-xs">
                  <button
                    onClick={() => handleSendKey('enter')}
                    disabled={!isConnected}
                    className="px-2.5 py-1 bg-slate-950 border border-slate-800 hover:border-slate-700 text-slate-300 rounded-md flex items-center gap-1 transition-colors"
                  >
                    <CornerDownLeft className="w-3 h-3 text-sky-400" />
                    Enter
                  </button>
                  <button
                    onClick={() => handleSendKey('backspace')}
                    disabled={!isConnected}
                    className="px-2.5 py-1 bg-slate-950 border border-slate-800 hover:border-slate-700 text-slate-300 rounded-md flex items-center gap-1 transition-colors"
                  >
                    <Delete className="w-3 h-3 text-rose-400" />
                    Backspace
                  </button>
                  <button
                    onClick={() => handleSendKey('escape')}
                    disabled={!isConnected}
                    className="px-2.5 py-1 bg-slate-950 border border-slate-800 hover:border-slate-700 text-slate-300 rounded-md flex items-center gap-1 transition-colors"
                  >
                    <XCircle className="w-3 h-3 text-amber-400" />
                    Escape
                  </button>
                  <button
                    onClick={() => handleSendKey('space')}
                    disabled={!isConnected}
                    className="px-2.5 py-1 bg-slate-950 border border-slate-800 hover:border-slate-700 text-slate-300 rounded-md transition-colors"
                  >
                    Space
                  </button>
                  <button
                    onClick={() => handleSendKey('tab')}
                    disabled={!isConnected}
                    className="px-2.5 py-1 bg-slate-950 border border-slate-800 hover:border-slate-700 text-slate-300 rounded-md transition-colors"
                  >
                    Tab
                  </button>
                  <button
                    onClick={() => {
                      if (!isConnected) return;
                      addLog('tx', 'click', { type: 'click', button: 'right' });
                      setClickRipples((prev) => [...prev, { id: Date.now(), x: cursorPos.x, y: cursorPos.y, button: 'right' }]);
                    }}
                    disabled={!isConnected}
                    className="px-2.5 py-1 bg-sky-500/10 border border-sky-500/30 hover:border-sky-500/50 text-sky-300 rounded-md flex items-center gap-1 transition-colors"
                  >
                    <MousePointer className="w-3 h-3" />
                    Right Click
                  </button>
                </div>
              </div>
            </div>
          </div>
        )}

        {/* Right / Host View: Virtual Windows 11 Desktop Screen & Protocol Logs */}
        {(viewMode === 'split' || viewMode === 'host_only') && (
          <div className={`${viewMode === 'split' ? 'lg:col-span-6' : 'lg:col-span-12'} flex flex-col gap-6`}>
            {/* Host PC Status Card */}
            <div className="bg-slate-900 border border-slate-800 rounded-2xl p-4 shadow-xl">
              <div className="flex items-center justify-between mb-3 pb-3 border-b border-slate-800">
                <div className="flex items-center gap-2">
                  <Monitor className="w-4 h-4 text-sky-400" />
                  <span className="text-sm font-semibold text-white">Windows DXGI Host Engine</span>
                  <span className="text-xs text-slate-500">·</span>
                  <span className="text-xs font-mono text-emerald-400">0.0.0.0:8765</span>
                </div>
                <div className="flex items-center gap-2 text-xs text-slate-400">
                  <span>Enigo v0.2 Input Injected</span>
                  <span className="w-1.5 h-1.5 rounded-full bg-emerald-400" />
                </div>
              </div>

              {/* Host state indicators */}
              <div className="grid grid-cols-3 gap-2.5">
                <div className="p-2.5 bg-slate-950 border border-slate-800/80 rounded-lg">
                  <div className="text-[11px] text-slate-400">Capture Device</div>
                  <div className="text-xs font-mono text-slate-200 mt-0.5 truncate">DirectX 11 DXGI Adapter</div>
                </div>
                <div className="p-2.5 bg-slate-950 border border-slate-800/80 rounded-lg">
                  <div className="text-[11px] text-slate-400">Frame Encoder</div>
                  <div className="text-xs font-mono text-slate-200 mt-0.5">JPEG (Quality 70)</div>
                </div>
                <div className="p-2.5 bg-slate-950 border border-slate-800/80 rounded-lg">
                  <div className="text-[11px] text-slate-400">Active Clients</div>
                  <div className="text-xs font-mono text-emerald-400 mt-0.5">{isConnected ? '1 Connected' : '0 (Listening)'}</div>
                </div>
              </div>
            </div>

            {/* Protocol WebSocket Logs Card */}
            <div className="bg-slate-900 border border-slate-800 rounded-2xl p-4 shadow-xl flex-1 flex flex-col">
              <div className="flex items-center justify-between mb-3 pb-2 border-b border-slate-800">
                <div className="flex items-center gap-2">
                  <Terminal className="w-4 h-4 text-emerald-400" />
                  <span className="text-sm font-semibold text-white">Live WebSocket Protocol Inspector</span>
                </div>

                <div className="flex items-center gap-2">
                  <div className="flex items-center p-0.5 bg-slate-950 border border-slate-800 rounded-md text-[11px]">
                    <button
                      onClick={() => setLogFilter('all')}
                      className={`px-2 py-0.5 rounded transition-colors ${
                        logFilter === 'all' ? 'bg-slate-800 text-white' : 'text-slate-400 hover:text-white'
                      }`}
                    >
                      All
                    </button>
                    <button
                      onClick={() => setLogFilter('input')}
                      className={`px-2 py-0.5 rounded transition-colors ${
                        logFilter === 'input' ? 'bg-slate-800 text-white' : 'text-slate-400 hover:text-white'
                      }`}
                    >
                      Inputs
                    </button>
                    <button
                      onClick={() => setLogFilter('frames')}
                      className={`px-2 py-0.5 rounded transition-colors ${
                        logFilter === 'frames' ? 'bg-slate-800 text-white' : 'text-slate-400 hover:text-white'
                      }`}
                    >
                      Network
                    </button>
                  </div>

                  <button
                    onClick={() => setLogs([])}
                    className="p-1 hover:bg-slate-800 rounded text-slate-400 hover:text-white transition-colors"
                    title="Clear Logs"
                  >
                    <RefreshCw className="w-3.5 h-3.5" />
                  </button>
                </div>
              </div>

              {/* Log Stream */}
              <div className="flex-1 bg-slate-950 border border-slate-800/80 rounded-xl p-3 font-mono text-[11px] overflow-y-auto max-h-[360px] space-y-1.5 shadow-inner">
                {filteredLogs.length === 0 ? (
                  <div className="text-center py-10 text-slate-600">
                    No WebSocket events captured yet. Tap or drag on the mobile viewport to emit control packets.
                  </div>
                ) : (
                  filteredLogs.map((log) => (
                    <div key={log.id} className="flex items-start gap-2 hover:bg-slate-900/60 p-1 rounded transition-colors">
                      <span className="text-slate-600 select-none">{log.timestamp}</span>
                      <span
                        className={`px-1.5 py-0.2 rounded text-[10px] font-bold uppercase select-none ${
                          log.direction === 'tx'
                            ? 'bg-sky-500/10 text-sky-400 border border-sky-500/20'
                            : 'bg-emerald-500/10 text-emerald-400 border border-emerald-500/20'
                        }`}
                      >
                        {log.direction === 'tx' ? 'TX ➔ Host' : 'RX ⬅ Client'}
                      </span>
                      <span className="text-slate-400 font-semibold">{log.type}</span>
                      <span className="text-slate-300 truncate flex-1">{log.payload}</span>
                    </div>
                  ))
                )}
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
};
