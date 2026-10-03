import React, { useState } from 'react';
import { InteractiveSimulator } from './components/InteractiveSimulator';
import { CodeViewer } from './components/CodeViewer';
import { ArchitectureDocs } from './components/ArchitectureDocs';
import { ConnectionGuide } from './components/ConnectionGuide';
import {
  Monitor,
  Smartphone,
  GitBranch,
  Terminal,
  Layers,
  Code2,
  Workflow,
  Sparkles,
  Download,
  Github,
  PlayCircle,
  Wifi
} from 'lucide-react';
import { PROJECT_FILES } from './data/projectFiles';

export default function App() {
  const [activeTab, setActiveTab] = useState<'simulator' | 'connect' | 'code' | 'docs'>('connect');

  const handleDownloadAll = () => {
    PROJECT_FILES.forEach((file, index) => {
      setTimeout(() => {
        const blob = new Blob([file.content], { type: 'text/plain;charset=utf-8' });
        const url = URL.createObjectURL(blob);
        const link = document.createElement('a');
        link.href = url;
        link.download = file.name;
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
        URL.revokeObjectURL(url);
      }, index * 200);
    });
  };

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 flex flex-col font-sans selection:bg-sky-500 selection:text-slate-950">
      {/* Top Navigation Bar */}
      <header className="sticky top-0 z-50 bg-slate-950/90 backdrop-blur border-b border-slate-800">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 h-16 flex items-center justify-between gap-4">
          {/* Brand Logo & Title */}
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-xl bg-gradient-to-br from-sky-400 to-indigo-600 flex items-center justify-center text-slate-950 shadow-lg shadow-sky-500/20 font-black text-lg">
              <Monitor className="w-5 h-5 text-white" />
            </div>
            <div>
              <div className="flex items-center gap-2">
                <span className="font-bold text-sm sm:text-base text-white tracking-tight">
                  Remote PC Controller &amp; Mirroring Suite
                </span>
                <span className="text-[10px] font-mono px-1.5 py-0.5 rounded bg-sky-500/10 text-sky-400 border border-sky-500/20">
                  v1.0.0
                </span>
              </div>
              <div className="flex items-center gap-2 text-[11px] text-slate-400">
                <span>Windows DXGI GPU Server</span>
                <span aria-hidden="true">·</span>
                <span>Flutter Android Client</span>
                <span aria-hidden="true">·</span>
                <span>GitHub Actions CI/CD</span>
              </div>
            </div>
          </div>

          {/* Navigation Tabs (Functional interactive buttons) */}
          <div className="flex items-center gap-1 p-1 bg-slate-900 border border-slate-800 rounded-xl">
            <button
              onClick={() => setActiveTab('connect')}
              className={`flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium rounded-lg transition-all ${
                activeTab === 'connect'
                  ? 'bg-sky-500 text-slate-950 font-semibold shadow-sm'
                  : 'text-slate-400 hover:text-white'
              }`}
            >
              <Wifi className="w-3.5 h-3.5" />
              <span>How to Connect</span>
            </button>
            <button
              onClick={() => setActiveTab('simulator')}
              className={`flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium rounded-lg transition-all ${
                activeTab === 'simulator'
                  ? 'bg-sky-500 text-slate-950 font-semibold shadow-sm'
                  : 'text-slate-400 hover:text-white'
              }`}
            >
              <PlayCircle className="w-3.5 h-3.5" />
              <span>Live Simulator</span>
            </button>
            <button
              onClick={() => setActiveTab('code')}
              className={`flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium rounded-lg transition-all ${
                activeTab === 'code'
                  ? 'bg-sky-500 text-slate-950 font-semibold shadow-sm'
                  : 'text-slate-400 hover:text-white'
              }`}
            >
              <Code2 className="w-3.5 h-3.5" />
              <span>Source Files (5)</span>
            </button>
            <button
              onClick={() => setActiveTab('docs')}
              className={`flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium rounded-lg transition-all ${
                activeTab === 'docs'
                  ? 'bg-sky-500 text-slate-950 font-semibold shadow-sm'
                  : 'text-slate-400 hover:text-white'
              }`}
            >
              <Workflow className="w-3.5 h-3.5" />
              <span>Architecture &amp; CI/CD</span>
            </button>
          </div>

          {/* Export / Download Action */}
          <div className="hidden sm:flex items-center gap-2">
            <button
              onClick={handleDownloadAll}
              className="px-3 py-1.5 bg-slate-900 hover:bg-slate-800 border border-slate-800 hover:border-slate-700 text-slate-200 text-xs font-medium rounded-lg flex items-center gap-1.5 transition-colors shadow-sm"
              title="Download all 5 project files"
            >
              <Download className="w-3.5 h-3.5 text-sky-400" />
              <span>Export Suite</span>
            </button>
          </div>
        </div>
      </header>

      {/* Main Container */}
      <main className="flex-1 max-w-7xl w-full mx-auto px-4 sm:px-6 lg:px-8 py-6">
        {activeTab === 'connect' && <ConnectionGuide />}
        {activeTab === 'simulator' && <InteractiveSimulator />}
        {activeTab === 'code' && <CodeViewer />}
        {activeTab === 'docs' && <ArchitectureDocs />}
      </main>

      {/* Footer */}
      <footer className="bg-slate-950 border-t border-slate-800/80 py-6 text-xs text-slate-500">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 flex flex-col sm:flex-row items-center justify-between gap-4">
          <div className="flex items-center gap-2">
            <span>Remote PC Controller &amp; Screen Mirroring Suite</span>
            <span aria-hidden="true">·</span>
            <span>Rust (DXGI) + Flutter + GitHub Actions</span>
          </div>

          <div className="flex items-center gap-4 text-slate-400 font-mono text-[11px]">
            <span>Port: 8765 TCP</span>
            <span aria-hidden="true">·</span>
            <span>Target: 60-120 FPS</span>
            <span aria-hidden="true">·</span>
            <span>Sub-30ms Latency</span>
          </div>
        </div>
      </footer>
    </div>
  );
}
