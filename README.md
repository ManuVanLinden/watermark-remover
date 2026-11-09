# Watermark Remover for Mac

<img src="AppIcon.png" width="96" alt="Watermark Remover app icon">

Remove fixed visible watermarks from batches of videos on your Mac. Select the
area once and use FFmpeg to retouch or crop it across the batch. Videos are
processed locally and exports are saved as separate MP4 files.

## Install

1. Install Python 3 and FFmpeg with `brew install python ffmpeg`.
2. Download the Apple Silicon ZIP from the [latest release](https://github.com/ManuVanLinden/watermark-remover/releases/latest).
3. Unzip it and move **Watermark Remover.app** to Applications. If you already
   have the app, replace your existing copy.

The download targets macOS 13 or later and is ad hoc signed. macOS may ask for
approval at first launch. See [Apple’s guide to opening downloaded apps](https://support.apple.com/en-us/102445).

## Use the Mac app

1. Open **Watermark Remover.app**.
2. Click **Add videos…**, select one or several videos, or drop videos onto the
   app's icon in Finder. The popup switches which queued video is previewed.
3. Check the orange selection. Drag a new rectangle around the entire visible
   logo with a small margin, keeping a few pixels away from the frame edges.
   **Reset sparkle preset** restores the default rectangle near the lower right.
4. Choose a method and click **Export videos**:
   - **Retouch:** preserves the full frame and fills the area using nearby pixels.
     A soft patch can be visible, especially on moving subjects and fine detail.
   - **Crop:** finds the largest crop on one side of the selection, maintaining
     the original aspect ratio, then scales it back to the source resolution.
     This zooms in and removes part of the picture around the edges.
5. Click **Show exports** to find the new MP4s.

The selected area uses percentages, so it scales with the resolution. All queued
videos share that selection and method. Review each preview before processing;
use separate batches when watermarks occupy different positions. The preview
shows the source's first frame with the selection overlay, not the retouched result.

Exports appear beside each source in **Watermark Remover Exports**, named
`name-retouch.mp4` or `name-crop.mp4`. Existing files receive a numeric suffix.
Originals are never overwritten. Cancelling removes the current partial file
and keeps completed exports. Batch errors do not prevent remaining files from
being processed.

H.264 MP4 output uses the source frame rate, original display resolution (rounded
down to even pixels when required), and AAC audio. Audio is re-encoded for MP4
compatibility. Rotation metadata is respected. The tool targets standard SDR,
square-pixel videos such as the supplied clip; HDR color mastering, unusual pixel
aspect ratios, subtitles, and extra video tracks are not preserved.

The rectangle stays fixed throughout each video. Use this tool for visible
overlays that stay in one place.

## Build from source

Install Xcode Command Line Tools, Python 3, and FFmpeg, then run:

```sh
python3 build.py
```

The build targets the current Mac’s architecture and writes the app to
`~/Applications/Watermark Remover/` by default. Use `--destination` to choose a
different build folder. Run the export checks with `python3 -m unittest -v`.

## Command line and automation

```sh
python3 remove_watermark.py "/path/to/video.mp4"
python3 remove_watermark.py "/path/to/video-folder" --mode crop
python3 remove_watermark.py "one.mp4" "two.mov" --output-dir "/path/to/exports"
python3 remove_watermark.py "video.mp4" --region 0.785,0.89,0.093,0.056
```

`--region` is `left,top,width,height`, with each value expressed as a fraction of
the displayed frame. Folder scans include MP4, MOV, M4V, MKV, and WebM files
directly inside that folder. Subfolders are not scanned. `--json` emits progress
events for integration with other tools. No network services are used.
