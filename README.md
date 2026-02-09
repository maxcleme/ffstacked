# ffstacked

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Bash-4.0%2B-green.svg)](https://www.gnu.org/software/bash/)
[![FFmpeg](https://img.shields.io/badge/FFmpeg-required-orange.svg)](https://ffmpeg.org/)

A command-line tool that generates animated GIF mosaics from video files. ffstacked extracts clips from throughout a video and arranges them in a randomized grid, creating an eye-catching visual summary that plays all clips simultaneously.

<p align="center">
  <img src="assets/output.gif" alt="Aegis" width="100%">
</p>

## Features

- **Mosaic Generation** — Creates a customizable grid from a single video file with aspect-preserving tiles and automatic square grid dimensions
- **Smart Sampling** — Extracts 30-second clips distributed throughout the video with randomized intervals
- **Quality Presets** — Choose from `low`, `medium`, `high`, or `max` quality presets
- **Fine-Grained Control** — Customize colors, FPS, dithering, and lossy compression
- **Progress Tracking** — Real-time progress bars with ETA for both extraction and encoding phases
- **Optimized Performance** — Multi-threaded processing with automatic CPU core detection
- **Optional Compression** — Supports gifsicle for additional lossy compression to reduce file size

## Installation

### Prerequisites

Ensure the following tools are installed on your system:

| Tool                                       | Required    | Purpose                                          |
| ------------------------------------------ | ----------- | ------------------------------------------------ |
| [FFmpeg](https://ffmpeg.org/)              | ✅ Yes      | Video processing and GIF encoding                |
| [ffprobe](https://ffmpeg.org/)             | ✅ Yes      | Video metadata extraction (included with FFmpeg) |
| [bc](https://www.gnu.org/software/bc/)     | ✅ Yes      | Mathematical calculations                        |
| [gifsicle](https://www.lcdf.org/gifsicle/) | ❌ Optional | Lossy GIF compression                            |

#### macOS (Homebrew)

```bash
brew install ffmpeg bc gifsicle
```

#### Ubuntu/Debian

```bash
sudo apt update
sudo apt install ffmpeg bc gifsicle
```

#### Arch Linux

```bash
sudo pacman -S ffmpeg bc gifsicle
```

### Installing ffstacked

```bash
# Clone the repository
git clone https://github.com/maxcleme/ffstacked.git
cd ffstacked

# Make the script executable
chmod +x ffstacked.sh

# Optional: Add to PATH
sudo ln -s "$(pwd)/ffstacked.sh" /usr/local/bin/ffstacked
```

## Usage

### Basic Usage

```bash
./ffstacked.sh video.mp4
```

This creates `stacked-video.gif` in the same directory as the input file.

### Quality Presets

```bash
# Smallest file size, lower quality (~15MB)
GIF_QUALITY=low ./ffstacked.sh video.mp4

# Balanced quality and size (~25MB) [default]
GIF_QUALITY=medium ./ffstacked.sh video.mp4

# Higher quality, larger file (~40MB)
GIF_QUALITY=high ./ffstacked.sh video.mp4

# Maximum quality, largest file (~80MB+)
GIF_QUALITY=max ./ffstacked.sh video.mp4
```

### Custom Settings

```bash
# Fine-tune individual parameters
GIF_COLORS=64 GIF_FPS=8 GIF_DITHER=bayer ./ffstacked.sh video.mp4

# Combine with lossy compression
GIF_COLORS=128 GIF_LOSSY=100 ./ffstacked.sh video.mp4
```

### Grid Dimensions

By default, ffstacked uses a roughly square grid (≈11×11) targeting approximately 120 tiles. Each tile preserves the input video's aspect ratio, ensuring the final GIF maintains the same aspect ratio as the source video.

**How automatic grid calculation works:**
- Calculates a square grid where cols ≈ rows ≈ √120 ≈ 11
- Targets ~120 total tiles (enforced range: 100-150)
- Ensures grid dimensions stay between 4 and 20
- Tiles preserve the input video's aspect ratio (width=80px, height=80/AR)

**Why square grids?**

The key insight is: **output AR = grid AR × tile AR**. By using a square grid (1:1) with aspect-preserving tiles (input AR), the output maintains the original video's aspect ratio:

- Square grid (11×11 = 1:1) × 16:9 tiles = 16:9 output ✓
- Square grid (11×11 = 1:1) × 9:16 tiles = 9:16 output ✓

If the grid matched the video's aspect ratio instead, you'd get the "aspect ratio squared" effect: a 15×8 grid (≈16:9) with 16:9 tiles would produce (16×15):(9×8) = 240:72 ≈ 3.3:1 output — much wider than intended.

**Examples by aspect ratio:**

| Input Aspect Ratio | Video Type | Grid | Tile Size | Total Tiles | Output Size |
| ------------------ | ---------- | ---- | --------- | ----------- | ----------- |
| 16:9 (1.78)        | Widescreen | 11×11 | 80×46    | 121         | 880×506     |
| 4:3 (1.33)         | Standard   | 11×11 | 80×60    | 121         | 880×660     |
| 1:1 (1.00)         | Square     | 11×11 | 80×80    | 121         | 880×880     |
| 9:16 (0.56)        | Vertical   | 11×11 | 80×142   | 121         | 880×1562    |
| 21:9 (2.37)        | Ultrawide  | 11×11 | 80×34    | 121         | 880×374     |

```bash
# Auto-calculated grid (default behavior)
./ffstacked.sh video.mp4

# Override with custom dimensions
GRID_COLS=8 GRID_ROWS=6 ./ffstacked.sh video.mp4    # 48 tiles
GRID_COLS=20 GRID_ROWS=5 ./ffstacked.sh video.mp4   # 100 tiles
GRID_COLS=16 GRID_ROWS=9 ./ffstacked.sh video.mp4   # Classic 144 tiles

# Override only one dimension (the other auto-calculates to default)
GRID_COLS=20 ./ffstacked.sh video.mp4               # 20×9 = 180 tiles
```

### Verbose Output

```bash
# Enable verbose logging
VERBOSE=1 ./ffstacked.sh video.mp4

# Enable debug logging (very detailed)
DEBUG=1 ./ffstacked.sh video.mp4
```

## Configuration

### Environment Variables

| Variable      | Default      | Description                                                 |
| ------------- | ------------ | ----------------------------------------------------------- |
| `GRID_COLS`   | auto         | Number of columns in the grid (auto-calculated as ~11 for square grid) |
| `GRID_ROWS`   | auto         | Number of rows in the grid (auto-calculated as ~11 for square grid)    |
| `GIF_QUALITY` | `medium`     | Quality preset: `low`, `medium`, `high`, `max`, or `custom` |
| `GIF_COLORS`  | `128`        | Color palette size: 2–256                                   |
| `GIF_FPS`     | `10`         | Output frame rate: 1–30                                     |
| `GIF_DITHER`  | `sierra2_4a` | Dithering algorithm                                         |
| `GIF_LOSSY`   | `80`         | Lossy compression level: 0–200 (requires gifsicle)          |
| `VERBOSE`     | `0`          | Enable verbose output: `0` or `1`                           |
| `DEBUG`       | `0`          | Enable debug output: `0` or `1`                             |

### Quality Preset Details

| Preset   | Colors | FPS | Dithering       | Lossy | Typical Size |
| -------- | ------ | --- | --------------- | ----- | ------------ |
| `low`    | 64     | 8   | none            | 120   | ~15MB        |
| `medium` | 128    | 10  | sierra2_4a      | 80    | ~25MB        |
| `high`   | 192    | 12  | floyd_steinberg | 40    | ~40MB        |
| `max`    | 256    | 15  | floyd_steinberg | 0     | ~80MB+       |

### Dithering Algorithms

| Algorithm         | Description                                     |
| ----------------- | ----------------------------------------------- |
| `none`            | No dithering; sharp edges, potential banding    |
| `bayer`           | Ordered dithering; retro/pixelated look         |
| `floyd_steinberg` | Error diffusion; smooth gradients               |
| `sierra2_4a`      | Error diffusion variant; good balance (default) |

## Examples

### Creating a Low-Size Preview

```bash
GIF_QUALITY=low ./ffstacked.sh movie.mp4
# Output: stacked-movie.gif (~15MB)
```

### Maximum Quality for Presentation

```bash
GIF_QUALITY=max ./ffstacked.sh presentation.mp4
# Output: stacked-presentation.gif (~80MB+)
```

### Custom Configuration for Social Media

```bash
GIF_COLORS=96 GIF_FPS=12 GIF_LOSSY=60 ./ffstacked.sh clip.mp4
# Optimized for sharing with good quality-to-size ratio
```

### Processing Multiple Videos

```bash
for video in *.mp4; do
    GIF_QUALITY=medium ./ffstacked.sh "$video"
done
```

## Output

The tool generates a GIF file with the following characteristics:

- **Grid Layout**: Roughly square grid (~11×11) targeting ~120 tiles, customizable via `GRID_COLS` and `GRID_ROWS`
- **Tile Size**: 80×(80/AR) pixels — tiles preserve the input video's aspect ratio
- **Clip Duration**: 30 seconds per tile (all playing simultaneously)
- **Output Location**: Same directory as input file
- **Output Naming**: `stacked-{input_filename}.gif`

### Sample Output Structure

```
Input:  /path/to/video.mp4
Output: /path/to/stacked-video.gif
```

## Troubleshooting

### Common Issues

#### "Video must be at least 30 seconds long"

The input video must be at least 30 seconds to generate clips. Use a longer video or modify the `CLIP_DURATION` variable in the script.

#### "ffmpeg is required"

Install FFmpeg:

```bash
# macOS
brew install ffmpeg

# Ubuntu/Debian
sudo apt install ffmpeg
```

#### "bc is required for calculations"

Install bc:

```bash
# macOS (usually pre-installed)
brew install bc

# Ubuntu/Debian
sudo apt install bc
```

#### Lossy compression not working

The lossy compression feature requires gifsicle to be installed:

```bash
# macOS
brew install gifsicle

# Ubuntu/Debian
sudo apt install gifsicle
```

If gifsicle is not found, the script will skip lossy compression and output a warning.

#### Output file is too large

Try using a lower quality preset or adjusting individual settings:

```bash
GIF_QUALITY=low ./ffstacked.sh video.mp4
# or
GIF_COLORS=64 GIF_FPS=8 GIF_LOSSY=120 ./ffstacked.sh video.mp4
```

#### Script is slow

The encoding process is CPU-intensive. The script automatically detects and uses all available CPU cores. You can monitor progress through the built-in progress bars.

#### Permission denied

Make the script executable:

```bash
chmod +x ffstacked.sh
```

## Performance Tips

- **SSD Storage**: Use an SSD for the temp directory to speed up clip extraction
- **Sufficient RAM**: Ensure adequate RAM for processing large videos
- **Lower Quality for Drafts**: Use `GIF_QUALITY=low` for quick previews
- **Parallel Processing**: The script automatically utilizes all CPU cores

## Dependencies

| Dependency | Version         | License  |
| ---------- | --------------- | -------- |
| Bash       | 4.0+            | GPL      |
| FFmpeg     | 4.0+            | LGPL/GPL |
| bc         | Any             | GPL      |
| gifsicle   | 1.9+ (optional) | GPL      |

## Acknowledgments

- [FFmpeg](https://ffmpeg.org/) — The backbone of video processing
- [gifsicle](https://www.lcdf.org/gifsicle/) — GIF optimization tool
