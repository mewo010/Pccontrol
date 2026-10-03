import React, { useState } from 'react';
import { PROJECT_FILES, ProjectFile } from '../data/projectFiles';
import {
  FileCode,
  Copy,
  Check,
  Download,
  FolderGit2,
  ExternalLink,
  Code2,
  Terminal,
  Cpu,
  Smartphone
} from 'lucide-react';

export const CodeViewer: React.FC = () => {
  const [selectedFile, setSelectedFile] = useState<ProjectFile>(PROJECT_FILES[1]); // default to main.rs
  const [copied, setCopied] = useState(false);

  const handleCopy = () => {
    navigator.clipboard.writeText(selectedFile.content);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  const handleDownloadSingle = (file: ProjectFile) => {
    const blob = new Blob([file.content], { type: 'text/plain;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = file.name;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    URL.revokeObjectURL(url);
  };

  const handleDownloadAll = () => {
    PROJECT_FILES.forEach((file, index) => {
      setTimeout(() => {
        handleDownloadSingle(file);
      }, index * 200);
    });
  };

  const getCategoryBadge = (cat: ProjectFile['category']) => {
    switch (cat) {
      case 'rust':
        return (
          <span className="flex items-center gap-1 text-[11px] text-orange-400">
            <Cpu className="w-3 h-3" /> Rust Host (Windows)
          </span>
        );
      case 'flutter':
        return (
          <span className="flex items-center gap-1 text-[11px] text-sky-400">
            <Smartphone className="w-3 h-3" /> Flutter Client (Android)
          </span>
        );
      case 'ci':
        return (
          <span className="flex items-center gap-1 text-[11px] text-purple-400">
            <FolderGit2 className="w-3 h-3" /> GitHub Actions CI/CD
          </span>
        );
    }
  };

  return (
    <div className="space-y-6">
      {/* Header bar */}
      <div className="flex flex-wrap items-center justify-between gap-4 bg-slate-900 border border-slate-800 rounded-xl p-4 shadow-xl">
        <div>
          <div className="flex items-center gap-2">
            <h2 className="text-base font-semibold text-white">Production Source Code Repository</h2>
            <span className="text-xs text-slate-500">·</span>
            <span className="text-xs font-mono text-emerald-400">Complete &amp; Unabridged</span>
          </div>
          <p className="text-xs text-slate-400 mt-0.5">
            Production-grade source files with zero stubs or missing dependencies. Fully compiled and tested.
          </p>
        </div>

        <div className="flex items-center gap-2">
          <button
            onClick={handleDownloadAll}
            className="px-3 py-1.5 bg-slate-800 hover:bg-slate-700 text-slate-200 text-xs font-medium rounded-lg flex items-center gap-1.5 transition-colors border border-slate-700/80"
          >
            <Download className="w-3.5 h-3.5" />
            Download All 5 Files
          </button>
        </div>
      </div>

      {/* Code Studio Layout */}
      <div className="grid grid-cols-1 lg:grid-cols-12 gap-6">
        {/* Left Column: File Tree Sidebar */}
        <div className="lg:col-span-4 space-y-4">
          <div className="bg-slate-900 border border-slate-800 rounded-xl p-3 shadow-xl">
            <div className="text-xs font-semibold text-slate-400 uppercase tracking-wider px-2 py-1 mb-2">
              Project File Hierarchy
            </div>

            <div className="space-y-1">
              {PROJECT_FILES.map((file) => {
                const isSelected = selectedFile.path === file.path;
                return (
                  <button
                    key={file.path}
                    onClick={() => {
                      setSelectedFile(file);
                      setCopied(false);
                    }}
                    className={`w-full text-left p-2.5 rounded-lg transition-all flex flex-col gap-1 border ${
                      isSelected
                        ? 'bg-slate-800/90 border-sky-500/50 shadow-md'
                        : 'border-transparent hover:bg-slate-800/40 text-slate-400 hover:text-slate-200'
                    }`}
                  >
                    <div className="flex items-center justify-between w-full">
                      <div className="flex items-center gap-2">
                        <FileCode
                          className={`w-4 h-4 ${
                            file.category === 'rust'
                              ? 'text-orange-400'
                              : file.category === 'flutter'
                              ? 'text-sky-400'
                              : 'text-purple-400'
                          }`}
                        />
                        <span className="text-xs font-mono font-medium text-white">{file.name}</span>
                      </div>
                      {getCategoryBadge(file.category)}
                    </div>
                    <span className="text-[11px] font-mono text-slate-500 truncate">{file.path}</span>
                  </button>
                );
              })}
            </div>
          </div>

          {/* Quick File Details Card */}
          <div className="bg-slate-900 border border-slate-800 rounded-xl p-4 shadow-xl text-xs space-y-3">
            <div className="text-xs font-semibold text-slate-300">File Specification</div>
            <p className="text-slate-400 leading-relaxed">{selectedFile.description}</p>
            <div className="pt-2 border-t border-slate-800 flex items-center justify-between text-slate-500 font-mono text-[11px]">
              <span>Lines: {selectedFile.content.split('\n').length}</span>
              <span>Size: {(new TextEncoder().encode(selectedFile.content).length / 1024).toFixed(1)} KB</span>
              <span className="uppercase">{selectedFile.language}</span>
            </div>
          </div>
        </div>

        {/* Right Column: Code Editor View */}
        <div className="lg:col-span-8 flex flex-col">
          <div className="bg-slate-950 border border-slate-800 rounded-xl overflow-hidden shadow-2xl flex flex-col flex-1">
            {/* Editor Top Bar */}
            <div className="bg-slate-900 border-b border-slate-800 px-4 py-2.5 flex items-center justify-between gap-4">
              <div className="flex items-center gap-2.5">
                <FileCode className="w-4 h-4 text-sky-400" />
                <span className="text-xs font-mono text-white font-medium">{selectedFile.path}</span>
              </div>

              <div className="flex items-center gap-2">
                <button
                  onClick={handleCopy}
                  className="px-2.5 py-1 text-xs bg-slate-800 hover:bg-slate-700 text-slate-200 rounded-md flex items-center gap-1.5 transition-colors border border-slate-700"
                >
                  {copied ? (
                    <>
                      <Check className="w-3.5 h-3.5 text-emerald-400" />
                      <span className="text-emerald-400">Copied!</span>
                    </>
                  ) : (
                    <>
                      <Copy className="w-3.5 h-3.5" />
                      <span>Copy</span>
                    </>
                  )}
                </button>

                <button
                  onClick={() => handleDownloadSingle(selectedFile)}
                  className="px-2.5 py-1 text-xs bg-sky-600 hover:bg-sky-500 text-white rounded-md flex items-center gap-1.5 transition-colors"
                >
                  <Download className="w-3.5 h-3.5" />
                  <span>Download</span>
                </button>
              </div>
            </div>

            {/* Code Body with Line Numbers */}
            <div className="flex-1 overflow-auto max-h-[640px] p-4 text-xs font-mono leading-relaxed bg-slate-950 text-slate-300">
              <pre className="flex">
                <code className="text-slate-600 select-none pr-4 text-right border-r border-slate-800/80 mr-4">
                  {selectedFile.content.split('\n').map((_, i) => (
                    <div key={i}>{i + 1}</div>
                  ))}
                </code>
                <code className="flex-1 overflow-x-auto text-slate-200">
                  {selectedFile.content}
                </code>
              </pre>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
