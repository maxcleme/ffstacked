#!/bin/bash
set -euo pipefail

VERBOSE="${VERBOSE:-0}"
DEBUG="${DEBUG:-0}"

# GIF Optimization settings (user-configurable via environment variables)
GIF_COLORS="${GIF_COLORS:-128}"          # Color palette size: 32, 64, 128, 256 (default: 128)
GIF_FPS="${GIF_FPS:-10}"                  # Output frame rate (default: 10)
GIF_DITHER="${GIF_DITHER:-sierra2_4a}"   # Dithering: none, bayer, floyd_steinberg, sierra2_4a (default: sierra2_4a)
GIF_LOSSY="${GIF_LOSSY:-80}"             # Lossy compression 0-200 (0=off, 80=good balance, 200=max) requires gifsicle
GIF_QUALITY="${GIF_QUALITY:-medium}"     # Presets: low, medium, high, max (overrides other settings)

log() { echo "[$(date '+%H:%M:%S')] $*"; }
log_verbose() { [[ "$VERBOSE" == "1" ]] && log "$*" || true; }
log_debug() { [[ "$DEBUG" == "1" ]] && log "[DEBUG] $*" || true; }
die() { log "ERROR: $*" >&2; exit 1; }

TEMP_DIR=""
PROGRESS_FILE=""
PROGRESS_PID=""

cleanup() {
    local exit_code=$?
    if [[ -n "${PROGRESS_PID:-}" ]] && kill -0 "$PROGRESS_PID" 2>/dev/null; then
        kill "$PROGRESS_PID" 2>/dev/null || true
    fi
    [[ -f "${PROGRESS_FILE:-}" ]] && rm -f "$PROGRESS_FILE"
    if [[ -n "${TEMP_DIR:-}" ]] && [[ -d "$TEMP_DIR" ]]; then
        log_debug "Cleaning up temp directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
    [[ $exit_code -ne 0 ]] && log "Script failed with exit code $exit_code"
    exit $exit_code
}
trap cleanup EXIT INT TERM

apply_quality_preset() {
    case "$GIF_QUALITY" in
        low)
            GIF_COLORS=64
            GIF_FPS=8
            GIF_DITHER="none"
            GIF_LOSSY=120
            ;;
        medium)
            GIF_COLORS=128
            GIF_FPS=10
            GIF_DITHER="sierra2_4a"
            GIF_LOSSY=80
            ;;
        high)
            GIF_COLORS=192
            GIF_FPS=12
            GIF_DITHER="floyd_steinberg"
            GIF_LOSSY=40
            ;;
        max)
            GIF_COLORS=256
            GIF_FPS=15
            GIF_DITHER="floyd_steinberg"
            GIF_LOSSY=0
            ;;
        custom)
            ;;
        *)
            log "Unknown quality preset '$GIF_QUALITY', using medium"
            GIF_QUALITY="medium"
            apply_quality_preset
            ;;
    esac
}
if [[ "$GIF_QUALITY" != "custom" ]]; then
    apply_quality_preset
fi

validate_gif_settings() {
    [[ $GIF_COLORS -lt 2 || $GIF_COLORS -gt 256 ]] && die "GIF_COLORS must be between 2 and 256"
    [[ $GIF_FPS -lt 1 || $GIF_FPS -gt 30 ]] && die "GIF_FPS must be between 1 and 30"
    [[ $GIF_LOSSY -lt 0 || $GIF_LOSSY -gt 200 ]] && die "GIF_LOSSY must be between 0 and 200"
    case "$GIF_DITHER" in
        none|bayer|floyd_steinberg|sierra2_4a) ;;
        *) die "GIF_DITHER must be one of: none, bayer, floyd_steinberg, sierra2_4a" ;;
    esac
}

get_dither_filter() {
    case "$GIF_DITHER" in
        none) echo "dither=none" ;;
        bayer) echo "dither=bayer:bayer_scale=3" ;;
        floyd_steinberg) echo "dither=floyd_steinberg" ;;
        sierra2_4a) echo "dither=sierra2_4a" ;;
    esac
}

estimate_gif_size() {
    local width=$1 height=$2 frames=$3 colors=$4
    local pixels=$((width * height))
    local bits_per_pixel
    if [[ $colors -le 4 ]]; then bits_per_pixel=2
    elif [[ $colors -le 16 ]]; then bits_per_pixel=4
    elif [[ $colors -le 64 ]]; then bits_per_pixel=6
    elif [[ $colors -le 128 ]]; then bits_per_pixel=7
    else bits_per_pixel=8
    fi
    local raw_size=$((pixels * bits_per_pixel * frames / 8))
    local compression_ratio=3
    local estimated=$((raw_size / compression_ratio / 1024 / 1024))
    [[ $estimated -lt 1 ]] && estimated=1
    echo $estimated
}

HAS_GIFSICLE=0
if command -v gifsicle &>/dev/null; then
    HAS_GIFSICLE=1
fi

show_progress() {
    local progress_file="$1" start_time="$2" total_frames="$3"
    while [[ -f "$progress_file" ]]; do
        if [[ -s "$progress_file" ]]; then
            local frame=$(grep -a '^frame=' "$progress_file" 2>/dev/null | tail -1 | cut -d'=' -f2 || echo "0")
            local speed=$(grep -a '^speed=' "$progress_file" 2>/dev/null | tail -1 | cut -d'=' -f2 || echo "N/A")
            local fps=$(grep -a '^fps=' "$progress_file" 2>/dev/null | tail -1 | cut -d'=' -f2 || echo "0")
            frame=${frame:-0}
            if [[ "$frame" =~ ^[0-9]+$ ]] && [[ $frame -gt 0 ]]; then
                local now=$(date +%s)
                local elapsed=$((now - start_time))
                local percent=0
                [[ $total_frames -gt 0 ]] && percent=$((frame * 100 / total_frames))
                [[ $percent -gt 100 ]] && percent=100
                local eta="calculating..."
                if [[ $frame -gt 0 ]] && [[ $elapsed -gt 5 ]]; then
                    local remaining_frames=$((total_frames - frame))
                    local frames_per_sec=$(echo "scale=2; $frame / $elapsed" | bc 2>/dev/null || echo "0")
                    if [[ $(echo "$frames_per_sec > 0" | bc 2>/dev/null || echo "0") == "1" ]]; then
                        local eta_secs=$(printf "%.0f" "$(echo "scale=2; $remaining_frames / $frames_per_sec" | bc 2>/dev/null || echo "0")")
                        if [[ $eta_secs -gt 0 ]]; then
                            local eta_min=$((eta_secs / 60))
                            local eta_sec=$((eta_secs % 60))
                            eta="${eta_min}m ${eta_sec}s"
                        fi
                    fi
                fi
                local bar_width=30
                local filled=$((percent * bar_width / 100))
                local empty=$((bar_width - filled))
                local bar=$(printf '%*s' "$filled" '' | tr ' ' '█')$(printf '%*s' "$empty" '' | tr ' ' '░')
                printf "\r[%s] %3d%% | Frame: %d/%d | Speed: %s | FPS: %s | ETA: %s     " \
                    "$bar" "$percent" "$frame" "$total_frames" "$speed" "$fps" "$eta"
            fi
        fi
        sleep 1
    done
    echo ""
}

show_extraction_progress() {
    local current="$1" total="$2" start_time="$3"
    local percent=$((current * 100 / total))
    local now=$(date +%s)
    local elapsed=$((now - start_time))
    local eta="calculating..."
    if [[ $current -gt 0 ]] && [[ $elapsed -gt 2 ]]; then
        local remaining=$((total - current))
        local secs_per_clip=$(echo "scale=2; $elapsed / $current" | bc 2>/dev/null || echo "0")
        if [[ $(echo "$secs_per_clip > 0" | bc 2>/dev/null || echo "0") == "1" ]]; then
            local eta_secs=$(printf "%.0f" "$(echo "scale=2; $remaining * $secs_per_clip" | bc 2>/dev/null || echo "0")")
            if [[ $eta_secs -ge 0 ]]; then
                local eta_min=$((eta_secs / 60))
                local eta_sec=$((eta_secs % 60))
                eta="${eta_min}m ${eta_sec}s"
            fi
        fi
    fi
    local bar_width=30
    local filled=$((percent * bar_width / 100))
    local empty=$((bar_width - filled))
    local bar=$(printf '%*s' "$filled" '' | tr ' ' '█')$(printf '%*s' "$empty" '' | tr ' ' '░')
    printf "\r[%s] %3d%% | Clip: %d/%d | ETA: %s     " "$bar" "$percent" "$current" "$total" "$eta"
}

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <video_file>"
    echo ""
    echo "Environment variables:"
    echo "  VERBOSE=1       Enable verbose output"
    echo "  DEBUG=1         Enable debug output"
    echo "  GRID_COLS=<n>   Number of columns in grid (auto-calculated if not set)"
    echo "  GRID_ROWS=<n>   Number of rows in grid (auto-calculated if not set)"
    echo ""
    echo "Grid Dimensions:"
    echo "  By default, grid dimensions are auto-calculated based on the input video's"
    echo "  aspect ratio to maintain proportional output (targeting ~120 tiles)."
    echo "  Set GRID_COLS and/or GRID_ROWS to override with manual values."
    echo ""
    echo "GIF Optimization (file size vs quality trade-offs):"
    echo "  GIF_QUALITY=<preset>  Quality preset: low (~15MB), medium (~25MB), high (~40MB), max (~80MB+)"
    echo "                        Presets override individual settings below"
    echo ""
    echo "  Or fine-tune individually:"
    echo "  GIF_COLORS=<n>        Color palette: 32, 64, 128, 256 (default: 128)"
    echo "  GIF_FPS=<n>           Frame rate: 5-15 recommended (default: 10)"
    echo "  GIF_DITHER=<mode>     Dithering: none, bayer, floyd_steinberg, sierra2_4a (default: sierra2_4a)"
    echo "  GIF_LOSSY=<n>         Lossy compression: 0=off, 30-80=balanced, 100+=aggressive (default: 80)"
    echo "                        Requires 'gifsicle' to be installed"
    echo ""
    echo "Examples:"
    echo "  GIF_QUALITY=low $0 video.mp4       # Smallest file, lower quality"
    echo "  GIF_QUALITY=high $0 video.mp4      # Larger file, better quality"
    echo "  GIF_COLORS=64 GIF_FPS=8 $0 video.mp4  # Custom settings"
    exit 1
fi

INPUT_FILE="$1"
[[ -f "$INPUT_FILE" ]] || die "File '$INPUT_FILE' not found"
command -v ffmpeg &>/dev/null || die "ffmpeg is required"
command -v ffprobe &>/dev/null || die "ffprobe is required"
command -v bc &>/dev/null || die "bc is required for calculations"

log "Starting ffstacked (optimized clip extraction)..."
log_debug "Input file: $INPUT_FILE"

if [[ "$(uname)" == "Darwin" ]]; then
    CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
else
    CPU_CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 4)
fi
[[ $CPU_CORES -lt 1 ]] && CPU_CORES=4
FFMPEG_THREADS=$CPU_CORES
FILTER_THREADS=$((CPU_CORES > 16 ? 16 : CPU_CORES))
log_debug "Detected $CPU_CORES CPU cores, using $FFMPEG_THREADS threads"

CLIP_DURATION=30
TILE_WIDTH=80
FPS=$GIF_FPS

validate_gif_settings

INPUT_DIR=$(dirname "$INPUT_FILE")
INPUT_BASENAME=$(basename "$INPUT_FILE")
INPUT_NAME="${INPUT_BASENAME%.*}"
OUTPUT_FILE="${INPUT_DIR}/stacked-${INPUT_NAME}.gif"

log "Probing video file..."
VIDEO_INFO=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,duration -of csv=p=0 "$INPUT_FILE" 2>&1) || die "Failed to probe video: $VIDEO_INFO"
log_debug "Video info: $VIDEO_INFO"
INPUT_WIDTH=$(echo "$VIDEO_INFO" | cut -d',' -f1)
INPUT_HEIGHT=$(echo "$VIDEO_INFO" | cut -d',' -f2)
DURATION=$(echo "$VIDEO_INFO" | cut -d',' -f3)
if [[ -z "$DURATION" || "$DURATION" == "N/A" ]]; then
    log_verbose "Duration not in stream, checking container..."
    DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT_FILE" 2>/dev/null)
fi
[[ -z "$INPUT_WIDTH" || ! "$INPUT_WIDTH" =~ ^[0-9]+$ ]] && die "Could not read video width"
[[ -z "$INPUT_HEIGHT" || ! "$INPUT_HEIGHT" =~ ^[0-9]+$ ]] && die "Could not read video height"
[[ -z "$DURATION" ]] && die "Could not read video duration"
DURATION_INT=${DURATION%.*}
[[ -z "$DURATION_INT" || ! "$DURATION_INT" =~ ^[0-9]+$ ]] && die "Invalid duration: $DURATION"
[[ $DURATION_INT -lt $CLIP_DURATION ]] && die "Video must be at least ${CLIP_DURATION} seconds long (got ${DURATION_INT}s)"

# Calculate square grid dimensions (cols ≈ rows)
# Using a square grid with aspect-preserving tiles gives output AR ≈ input AR
# Formula: Square_Grid_AR (≈1:1) × Tile_AR (=Input_AR) = Output_AR (≈Input_AR)
calculate_grid_dimensions() {
    local target_tiles=120
    local min_tiles=100
    local max_tiles=150
    local min_dim=4
    local max_dim=20
    # For a square grid, cols ≈ rows ≈ sqrt(target_tiles)
    local side=$(printf "%.0f" "$(echo "scale=6; sqrt($target_tiles)" | bc)")
    local cols=$side
    local rows=$side
    # Enforce dimension bounds
    [[ $cols -lt $min_dim ]] && cols=$min_dim
    [[ $rows -lt $min_dim ]] && rows=$min_dim
    [[ $cols -gt $max_dim ]] && cols=$max_dim
    [[ $rows -gt $max_dim ]] && rows=$max_dim
    # Adjust to reach target tile range while keeping grid roughly square
    local total=$((cols * rows))
    while [[ $total -lt $min_tiles ]] && [[ $cols -lt $max_dim || $rows -lt $max_dim ]]; do
        if [[ $cols -le $rows ]] && [[ $cols -lt $max_dim ]]; then
            cols=$((cols + 1))
        elif [[ $rows -lt $max_dim ]]; then
            rows=$((rows + 1))
        else
            cols=$((cols + 1))
        fi
        total=$((cols * rows))
    done
    while [[ $total -gt $max_tiles ]] && [[ $cols -gt $min_dim || $rows -gt $min_dim ]]; do
        if [[ $cols -ge $rows ]] && [[ $cols -gt $min_dim ]]; then
            cols=$((cols - 1))
        elif [[ $rows -gt $min_dim ]]; then
            rows=$((rows - 1))
        else
            cols=$((cols - 1))
        fi
        total=$((cols * rows))
    done
    echo "$cols $rows"
}

# Determine grid dimensions (auto-calculate or use environment overrides)
GRID_MODE="auto"
if [[ -n "${GRID_COLS:-}" ]] || [[ -n "${GRID_ROWS:-}" ]]; then
    GRID_MODE="manual"
    GRID_COLS="${GRID_COLS:-16}"
    GRID_ROWS="${GRID_ROWS:-9}"
    log_verbose "Using manual grid dimensions from environment: ${GRID_COLS}x${GRID_ROWS}"
else
    CALC_RESULT=$(calculate_grid_dimensions 2>/dev/null) || CALC_RESULT=""
    if [[ -n "$CALC_RESULT" ]]; then
        GRID_COLS=$(echo "$CALC_RESULT" | cut -d' ' -f1)
        GRID_ROWS=$(echo "$CALC_RESULT" | cut -d' ' -f2)
        log_verbose "Auto-calculated grid dimensions: ${GRID_COLS}x${GRID_ROWS} (square grid for ~120 tiles)"
    else
        GRID_COLS=16
        GRID_ROWS=9
        GRID_MODE="fallback"
        log_verbose "Grid calculation failed, using fallback: ${GRID_COLS}x${GRID_ROWS}"
    fi
fi
TOTAL_TILES=$((GRID_COLS * GRID_ROWS))

log "Input: $INPUT_FILE"
log "  Resolution: ${INPUT_WIDTH}x${INPUT_HEIGHT}"
log "  Duration: ${DURATION_INT}s"
log "Grid: ${GRID_COLS}x${GRID_ROWS} (${TOTAL_TILES} tiles) [${GRID_MODE}]"
log "Using $CPU_CORES CPU cores"

# Calculate tile height to preserve input video aspect ratio
# Combined with square grid, this gives output AR ≈ input AR
INPUT_AR=$(echo "scale=6; $INPUT_WIDTH / $INPUT_HEIGHT" | bc)
TILE_HEIGHT=$(printf "%.0f" "$(echo "scale=2; $TILE_WIDTH / $INPUT_AR" | bc)")
# Ensure even dimensions for video encoding compatibility
TILE_WIDTH=$((TILE_WIDTH + TILE_WIDTH % 2))
TILE_HEIGHT=$((TILE_HEIGHT + TILE_HEIGHT % 2))
MOSAIC_WIDTH=$((TILE_WIDTH * GRID_COLS))
MOSAIC_HEIGHT=$((TILE_HEIGHT * GRID_ROWS))
log "Tile size: ${TILE_WIDTH}x${TILE_HEIGHT}"
log "Output size: ${MOSAIC_WIDTH}x${MOSAIC_HEIGHT}"
log "Output file: $OUTPUT_FILE"

TOTAL_FRAMES=$((CLIP_DURATION * GIF_FPS))
ESTIMATED_SIZE=$(estimate_gif_size "$MOSAIC_WIDTH" "$MOSAIC_HEIGHT" "$TOTAL_FRAMES" "$GIF_COLORS")
log ""
log "GIF Settings (quality preset: $GIF_QUALITY):"
log "  Colors: $GIF_COLORS | FPS: $GIF_FPS | Dithering: $GIF_DITHER"
if [[ $GIF_LOSSY -gt 0 ]]; then
    if [[ $HAS_GIFSICLE -eq 1 ]]; then
        log "  Lossy compression: $GIF_LOSSY (gifsicle)"
    else
        log "  Lossy compression: $GIF_LOSSY (gifsicle not found - will be skipped)"
    fi
fi
log "  Estimated size: ~${ESTIMATED_SIZE}MB (before lossy compression)"

declare -a START_TIMES
USABLE_END=$((DURATION_INT - CLIP_DURATION))
[[ $USABLE_END -lt 0 ]] && USABLE_END=0
MIDDLE_TILES=$((TOTAL_TILES - 2))
MIDDLE_START=$CLIP_DURATION
MIDDLE_END=$((DURATION_INT - 2 * CLIP_DURATION))
[[ $MIDDLE_END -lt $MIDDLE_START ]] && MIDDLE_END=$MIDDLE_START
MIDDLE_RANGE=$((MIDDLE_END - MIDDLE_START))
log_verbose "Calculating start times for $TOTAL_TILES tiles..."
for ((i=0; i<TOTAL_TILES; i++)); do
    if [[ $i -eq 0 ]]; then
        START_TIMES[$i]=0
    elif [[ $i -eq $((TOTAL_TILES - 1)) ]]; then
        START_TIMES[$i]=$USABLE_END
    else
        INTERVAL_START=$(( MIDDLE_START + (i - 1) * MIDDLE_RANGE / MIDDLE_TILES ))
        INTERVAL_END=$(( MIDDLE_START + i * MIDDLE_RANGE / MIDDLE_TILES ))
        INTERVAL_SIZE=$((INTERVAL_END - INTERVAL_START))
        if [[ $INTERVAL_SIZE -gt 0 ]]; then
            RANDOM_OFFSET=$((RANDOM % INTERVAL_SIZE))
        else
            RANDOM_OFFSET=0
        fi
        START_TIMES[$i]=$((INTERVAL_START + RANDOM_OFFSET))
    fi
    log_debug "Tile $i: start=${START_TIMES[$i]}s"
done
log_verbose "Start times calculated"

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ffstacked.XXXXXX")
log_debug "Temp directory: $TEMP_DIR"

log ""
log "═══════════════════════════════════════════════════════════════"
log "  Phase 1: Extracting ${TOTAL_TILES} clips (30s each)..."
log "  Using fast input seeking for efficient extraction"
log "═══════════════════════════════════════════════════════════════"
log ""

EXTRACT_START=$(date +%s)
declare -a CLIP_FILES
for ((i=0; i<TOTAL_TILES; i++)); do
    CLIP_FILE="${TEMP_DIR}/clip_$(printf '%03d' $i).mp4"
    CLIP_FILES[$i]="$CLIP_FILE"
    START_TIME=${START_TIMES[$i]}
    log_debug "Extracting clip $i: start=${START_TIME}s -> $CLIP_FILE"
    ffmpeg -y -hide_banner -loglevel error \
        -ss "$START_TIME" \
        -i "$INPUT_FILE" \
        -t "$CLIP_DURATION" \
        -c:v libx264 -preset ultrafast -crf 18 \
        -an \
        -threads "$FFMPEG_THREADS" \
        "$CLIP_FILE" || die "Failed to extract clip $i"
    show_extraction_progress $((i + 1)) "$TOTAL_TILES" "$EXTRACT_START"
done
echo ""

EXTRACT_END=$(date +%s)
EXTRACT_ELAPSED=$((EXTRACT_END - EXTRACT_START))
log "Clip extraction completed in ${EXTRACT_ELAPSED}s"

TOTAL_CLIP_SIZE=$(du -sh "$TEMP_DIR" 2>/dev/null | cut -f1)
log_verbose "Total clip size: $TOTAL_CLIP_SIZE"

build_mosaic_filter() {
    local inputs="" xstack_inputs="" layout=""
    local -a grid_order
    local i j temp n
    for ((i=0; i<TOTAL_TILES; i++)); do
        grid_order[$i]=$i
    done
    # Fisher-Yates shuffle (bash 3.2+ compatible)
    n=${#grid_order[@]}
    for ((i = n - 1; i > 0; i--)); do
        j=$((RANDOM % (i + 1)))
        temp=${grid_order[$i]}
        grid_order[$i]=${grid_order[$j]}
        grid_order[$j]=$temp
    done
    log_verbose "Randomized grid placement order"
    for ((i=0; i<TOTAL_TILES; i++)); do
        inputs+="[${i}:v]scale=${TILE_WIDTH}:${TILE_HEIGHT}:flags=lanczos,fps=${FPS},setpts=PTS-STARTPTS[v${i}];"
    done
    for ((row=0; row<GRID_ROWS; row++)); do
        for ((col=0; col<GRID_COLS; col++)); do
            local grid_pos=$((row * GRID_COLS + col))
            local clip_idx=${grid_order[$grid_pos]}
            [[ -n "$layout" ]] && layout+="|"
            layout+="$((col * TILE_WIDTH))_$((row * TILE_HEIGHT))"
            xstack_inputs+="[v${clip_idx}]"
        done
    done
    echo "${inputs}${xstack_inputs}xstack=inputs=${TOTAL_TILES}:layout=${layout}:fill=black[mosaic]"
}

log ""
log "═══════════════════════════════════════════════════════════════"
log "  Phase 2: Building mosaic from extracted clips..."
log "═══════════════════════════════════════════════════════════════"
log ""

FILTER=$(build_mosaic_filter)
log_debug "Filter length: ${#FILTER} characters"
[[ -z "$FILTER" ]] && die "Failed to build filter graph"

TOTAL_OUTPUT_FRAMES=$((CLIP_DURATION * FPS))
log_verbose "Expected output frames: $TOTAL_OUTPUT_FRAMES"

PROGRESS_FILE=$(mktemp "${TMPDIR:-/tmp}/ffstacked_progress.XXXXXX")
log_debug "Progress file: $PROGRESS_FILE"

MOSAIC_START=$(date +%s)
show_progress "$PROGRESS_FILE" "$MOSAIC_START" "$TOTAL_OUTPUT_FRAMES" &
PROGRESS_PID=$!
log_debug "Progress monitor PID: $PROGRESS_PID"

FFMPEG_INPUTS=()
for ((i=0; i<TOTAL_TILES; i++)); do
    FFMPEG_INPUTS+=(-i "${CLIP_FILES[$i]}")
done

DITHER_SETTING=$(get_dither_filter)
FFMPEG_CMD=(
    ffmpeg -y -hide_banner
    -threads "$FFMPEG_THREADS"
    "${FFMPEG_INPUTS[@]}"
    -filter_complex_threads "$FILTER_THREADS"
    -filter_complex "${FILTER};[mosaic]split[s0][s1];[s0]palettegen=max_colors=${GIF_COLORS}:stats_mode=diff[p];[s1][p]paletteuse=${DITHER_SETTING}"
    -progress "$PROGRESS_FILE"
    -loop 0
    "$OUTPUT_FILE"
)
log_debug "FFmpeg command has ${#FFMPEG_CMD[@]} arguments"

FFMPEG_LOG=$(mktemp "${TMPDIR:-/tmp}/ffstacked_ffmpeg.XXXXXX")
if [[ "$DEBUG" == "1" ]]; then
    "${FFMPEG_CMD[@]}" 2>&1 | tee "$FFMPEG_LOG"
    FFMPEG_EXIT=${PIPESTATUS[0]}
else
    "${FFMPEG_CMD[@]}" >"$FFMPEG_LOG" 2>&1
    FFMPEG_EXIT=$?
fi

kill "$PROGRESS_PID" 2>/dev/null || true
wait "$PROGRESS_PID" 2>/dev/null || true
unset PROGRESS_PID
rm -f "$PROGRESS_FILE"
unset PROGRESS_FILE

MOSAIC_END=$(date +%s)
MOSAIC_ELAPSED=$((MOSAIC_END - MOSAIC_START))

echo ""
if [[ $FFMPEG_EXIT -ne 0 ]]; then
    log "═══════════════════════════════════════════════════════════════"
    log "  ENCODING FAILED (exit code: $FFMPEG_EXIT)"
    log "═══════════════════════════════════════════════════════════════"
    log ""
    log "FFmpeg output (last 50 lines):"
    tail -50 "$FFMPEG_LOG"
    rm -f "$FFMPEG_LOG"
    die "FFmpeg encoding failed"
fi
rm -f "$FFMPEG_LOG"

if [[ ! -f "$OUTPUT_FILE" ]]; then
    die "Output file was not created"
fi

PRE_OPTIMIZE_SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
PRE_OPTIMIZE_BYTES=$(stat -f%z "$OUTPUT_FILE" 2>/dev/null || stat -c%s "$OUTPUT_FILE" 2>/dev/null)
OPTIMIZE_ELAPSED=0

if [[ $GIF_LOSSY -gt 0 ]] && [[ $HAS_GIFSICLE -eq 1 ]]; then
    log ""
    log "═══════════════════════════════════════════════════════════════"
    log "  Phase 3: Applying lossy compression with gifsicle..."
    log "═══════════════════════════════════════════════════════════════"
    log ""
    OPTIMIZE_START=$(date +%s)
    TEMP_GIF="${TEMP_DIR}/optimized.gif"
    if gifsicle --lossy="$GIF_LOSSY" -O3 "$OUTPUT_FILE" -o "$TEMP_GIF" 2>/dev/null; then
        mv "$TEMP_GIF" "$OUTPUT_FILE"
        OPTIMIZE_END=$(date +%s)
        OPTIMIZE_ELAPSED=$((OPTIMIZE_END - OPTIMIZE_START))
        log "Lossy compression completed in ${OPTIMIZE_ELAPSED}s"
    else
        log "Warning: gifsicle optimization failed, keeping original GIF"
    fi
fi

TOTAL_END=$(date +%s)
TOTAL_ELAPSED=$((TOTAL_END - EXTRACT_START))
TOTAL_MIN=$((TOTAL_ELAPSED / 60))
TOTAL_SEC=$((TOTAL_ELAPSED % 60))

OUTPUT_SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
OUTPUT_BYTES=$(stat -f%z "$OUTPUT_FILE" 2>/dev/null || stat -c%s "$OUTPUT_FILE" 2>/dev/null)

log "═══════════════════════════════════════════════════════════════"
log "  ENCODING COMPLETE!"
log "═══════════════════════════════════════════════════════════════"
log ""
log "  Output: $OUTPUT_FILE"
log "  Size: $OUTPUT_SIZE"
if [[ $GIF_LOSSY -gt 0 ]] && [[ $HAS_GIFSICLE -eq 1 ]] && [[ $PRE_OPTIMIZE_BYTES -gt 0 ]]; then
    SAVINGS=$((100 - OUTPUT_BYTES * 100 / PRE_OPTIMIZE_BYTES))
    log "  (before gifsicle: $PRE_OPTIMIZE_SIZE, saved ${SAVINGS}%)"
fi
log ""
log "  GIF settings used:"
log "    Preset: $GIF_QUALITY | Colors: $GIF_COLORS | FPS: $GIF_FPS"
log "    Dither: $GIF_DITHER | Lossy: $GIF_LOSSY"
log ""
log "  Timing breakdown:"
log "    Clip extraction: ${EXTRACT_ELAPSED}s"
log "    Mosaic assembly: ${MOSAIC_ELAPSED}s"
if [[ $OPTIMIZE_ELAPSED -gt 0 ]]; then
    log "    GIF optimization: ${OPTIMIZE_ELAPSED}s"
fi
log "    Total time: ${TOTAL_MIN}m ${TOTAL_SEC}s"
log ""
