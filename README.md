# Termux Media Processing Pipeline

A modular, automated media ingest and audio normalization pipeline for Android devices running Termux. It handles silent dependency updates, moves and catalogs non-video assets, and performs two-pass linear audio loudness normalization to **-12 LUFS** (strictly zero dynamic range compression) before cataloging finalized media directly into Android's native MediaStore (Gallery / WhatsApp picker).

---

## ⚡ 1-Click Automated Installation

Paste this single command into a fresh Termux terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/AnnaMorgrett/Termux/main/install.sh | bash
```

### What the installer does:
1. Requests Android storage permissions (`termux-setup-storage`) and waits until access is granted.
2. Updates package repositories and installs required tools: `git`, `ffmpeg`, `python`, `python-pip`, and `yt-dlp`.
3. Clones this repository into `/storage/emulated/0/Termux/` (or pulls the latest changes if already present).
4. Registers global shortcuts in `$PREFIX/bin/`:
   - `dl`: Downloads any video/audio stream and triggers the normalization pipeline.
   - `tiktok`: Directly triggers the normalization pipeline over existing media.
5. Applies executable permissions (`chmod +x`) to all scripts and commands.

---

## 🚀 Usage

### 1. Download & Process (`dl`)
Download media from any site supported by `yt-dlp` directly into the ingestion folder and immediately process it:

```bash
dl "https://www.tiktok.com/@username/video/1234567890"
```
*Extra `yt-dlp` arguments can be passed through directly (e.g. `dl "https://..." -f bestvideo+bestaudio`).*

### 2. Batch Process Existing Media (`tiktok`)
Scan input directories, relocate non-video assets, and normalize all pending videos:

```bash
tiktok
```

---

## 📁 Storage & Folder Architecture

| Path | Purpose |
| :--- | :--- |
| `/storage/emulated/0/DCIM/TikTok` | Primary video/asset input directory |
| `/storage/emulated/0/Download/yt-dlp` | Ingestion folder for `dl` command downloads |
| `/storage/emulated/0/Pictures/TikTok_Assets` | Relocation folder for non-video assets (`.jpg`, `.png`, `.gif`, `.webp`, `.heic`, etc.) |
| `/storage/emulated/0/Movies/NormalizedVideo` | Output destination for verified, loudness-normalized videos |
| `/storage/emulated/0/Documents/.media_processor.log` | Central debug log with automated size trimming (2MB max) |

---

## ⚙️ Modular Pipeline Components

All components reside in `/storage/emulated/0/Termux/`:

- **[`download.sh`](download.sh)**: Dedicated `yt-dlp` execution wrapper targeting `/storage/emulated/0/Download/yt-dlp`.
- **[`move_assets.sh`](move_assets.sh)**: Scans input folders for image and sticker assets, safely relocates them with collision resolution, and triggers Android's `MediaScanner`.
- **[`normalize.sh`](normalize.sh)**:
  - Sanitizes filenames strictly to `[A-Za-z0-9_-]`.
  - Probes video codec: preserves bitstream (`-c:v copy`) for H.264/HEVC/MPEG-4; re-encodes incompatible formats to high-quality H.264.
  - **Two-Pass Audio Normalization**:
    - **Pass 1**: Analyzes integrated loudness via FFmpeg `loudnorm` filter output.
    - **Pass 2**: Applies exact constant linear volume gain (`volume=${gain}dB`) to target **-12 LUFS**. Eliminates pumping and dynamic compression artifacts.
  - Generates web-optimized MP4s (`+faststart`).
  - Verifies container duration and file integrity with `ffprobe` prior to deleting the source file.
  - Broadcasts media updates immediately so videos appear instantly in Android Gallery and social app pickers.
- **[`master_run.sh`](master_run.sh)**: Orchestration controller that handles concurrency locks (`flock`), debug log rotation, silent `yt-dlp` dependency updates, and sequential execution of asset relocation and video normalization.
