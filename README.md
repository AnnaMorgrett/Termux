# Termux & PC Media Processing Pipeline

A modular, automated media ingest and audio normalization pipeline built for **Android (Termux)**, **Windows (PowerShell / CMD / Git Bash)**, and **Linux / macOS**.

It moves non-video assets safely to an asset library, updates dependencies silently, and performs two-pass linear audio loudness normalization to **-12 LUFS** (strictly zero dynamic range compression), followed by automated media indexing.

---

## ⚡ Quick Start & Installation

### Option A: On Mobile (Android Termux)
Paste this single command into a fresh Termux terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/AnnaMorgrett/Termux/main/install.sh | bash
```

### Option B: On Windows (PowerShell)
Open PowerShell in the cloned repository folder and run:

```powershell
.\install.ps1
```

### Option C: On Linux / macOS / Git Bash
Clone the repository and run the installer:

```bash
git clone https://github.com/AnnaMorgrett/Termux.git
cd Termux
bash install.sh
```

---

## 🚀 Unified Commands (Same on Windows, Linux, and Android)

All platforms use the exact same command names directly in your terminal:

### 1. Download & Normalize (`dl`)
Downloads media via `yt-dlp` into the download queue and immediately triggers loudness normalization:

```bash
dl "https://www.tiktok.com/@username/video/1234567890"
```
*(Any additional flags are passed directly to `yt-dlp`, e.g. `dl "https://..." -f bestvideo+bestaudio`)*

### 2. Batch Process Media (`tiktok`)
Scans the input folders, relocates image/gif assets, and normalizes all pending videos:

```bash
tiktok
```

---

## 📁 Storage & Folder Architecture

The scripts auto-detect whether they are running on Android or a PC:

| Location | Mobile (Termux) | PC (Windows / Linux / macOS) |
| :--- | :--- | :--- |
| **Scripts Root** | `/storage/emulated/0/Termux/` | Your cloned `Termux/` repository directory |
| **Global Shortcuts** | `$PREFIX/bin/` (`dl`, `tiktok`) | `WindowsApps/` (`dl.cmd`, `tiktok.cmd`) or `~/.local/bin/` |
| **TikTok Input** | `/storage/emulated/0/DCIM/TikTok/` | `~/TermuxMedia/DCIM/TikTok/` |
| **yt-dlp Input** | `/storage/emulated/0/Download/yt-dlp/` | `~/TermuxMedia/Download/yt-dlp/` |
| **Assets Output** | `/storage/emulated/0/Pictures/TikTok_Assets/` | `~/TermuxMedia/Pictures/TikTok_Assets/` |
| **Normalized Output** | `/storage/emulated/0/Movies/NormalizedVideo/` | `~/TermuxMedia/Movies/NormalizedVideo/` |
| **Debug Log** | `/storage/emulated/0/Documents/.media_processor.log` | `~/TermuxMedia/Documents/.media_processor.log` |

> *Tip for PC testing:* You can override the root media storage folder anytime by setting `export MEDIA_DIR="/path/to/custom/folder"` (or in PowerShell: `$env:MEDIA_DIR="C:\custom\folder"`).

---

## ⚙️ Modular Architecture

- **[`download.sh`](download.sh)**: Dedicated `yt-dlp` download logic with sane output naming and timestamp flags.
- **[`move_assets.sh`](move_assets.sh)**: Scans for non-video assets (`.jpg`, `.png`, `.gif`, `.webp`, `.heic`, `.svg`), relocates them safely without overwriting, and triggers Android's `MediaScanner` (or skips gracefully on PC).
- **[`normalize.sh`](normalize.sh)**:
  - Sanitizes output filenames strictly to `[A-Za-z0-9_-]`.
  - Stream-copies compatible video codecs (`h264`, `hevc`, `mpeg4`) or encodes with `libx264`.
  - **Pass 1**: Accurately measures integrated loudness (LUFS) with FFmpeg `loudnorm`.
  - **Pass 2**: Applies pure linear gain (`volume=${gain}dB`) to reach **-12 LUFS** without dynamic compression.
  - Generates web-optimized MP4s with `+faststart`.
  - Verifies container duration and file size before safely deleting source files.
- **[`master_run.sh`](master_run.sh)**: Orchestration controller managing single-instance lockfiles (`flock`), rotating debug logs (2MB cap), silent `yt-dlp` updates, and sequential execution.
- **[`install.sh`](install.sh)**: Cross-platform setup script for Android Termux and Linux/macOS environments.
- **[`install.ps1`](install.ps1)**: Windows PowerShell native installer providing Windows CLI wrappers (`dl.cmd` and `tiktok.cmd`).
