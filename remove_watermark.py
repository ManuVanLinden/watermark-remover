#!/usr/bin/env python3
"""Local, non-destructive batch removal of a fixed visible video watermark."""
import argparse
import json
import math
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import uuid

DEFAULT_REGION = (0.785, 0.89, 0.093, 0.056)
EXTENSIONS = {'.mp4', '.mov', '.m4v', '.mkv', '.webm'}
ACTIVE = None


def tool(name):
    found = shutil.which(name)
    if found:
        return found
    for base in ('/opt/homebrew/bin', '/usr/local/bin'):
        candidate = Path(base) / name
        if candidate.is_file():
            return str(candidate)
    raise ValueError(f'{name} is required. Install FFmpeg with: brew install ffmpeg')


def region_arg(value):
    try:
        result = tuple(float(n.strip()) for n in value.split(','))
        if len(result) != 4 or not all(math.isfinite(n) for n in result):
            raise ValueError()
        x, y, w, h = result
        if min(x, y) < 0 or min(w, h) <= 0 or x + w >= 1 or y + h >= 1:
            raise ValueError()
        return result
    except ValueError:
        raise argparse.ArgumentTypeError('Use x,y,width,height fractions, wholly inside the frame (e.g. 0.785,0.89,0.093,0.056).')


def probe(path):
    result = subprocess.run([tool('ffprobe'), '-v', 'error', '-show_streams',
                             '-show_format', '-of', 'json', str(path)],
                            capture_output=True, text=True)
    if result.returncode:
        raise ValueError(f'Cannot read {path.name}: {result.stderr.strip()}')
    data = json.loads(result.stdout)
    stream = next((s for s in data['streams'] if s['codec_type'] == 'video'
                   and not s.get('disposition', {}).get('attached_pic')), None)
    if not stream:
        raise ValueError(f'No video stream in {path.name}')
    width, height = stream['width'], stream['height']
    rotation = float(stream.get('tags', {}).get('rotate', 0))
    for side in stream.get('side_data_list', []):
        rotation = float(side.get('rotation', rotation))
    if round(rotation / 90) % 2:
        width, height = height, width
    return width, height, float(data.get('format', {}).get('duration', 0) or 0), stream['index']


def make_filter(width, height, region, mode):
    x, y, w, h = region
    left, top = math.floor(x * width), math.floor(y * height)
    right, bottom = math.ceil((x + w) * width), math.ceil((y + h) * height)
    if left < 1 or top < 1 or right > width - 2 or bottom > height - 2:
        raise ValueError('The selection needs a few pixels of surrounding picture on all sides.')
    if right - left < 4 or bottom - top < 4:
        raise ValueError('The selection is too small. Draw a larger rectangle.')
    even = 'scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1'
    if mode == 'retouch':
        return f'delogo=x={left}:y={top}:w={right-left}:h={bottom-top},{even}'
    # Largest original-aspect crop wholly on one side of the selection.
    ratio = width / height
    candidates = []
    for area_x, area_y, area_w, area_h in ((0, 0, width, top - 2),
            (0, bottom + 2, width, height - bottom - 2),
            (0, 0, left - 2, height), (right + 2, 0, width - right - 2, height)):
        crop_w = int(min(area_w, area_h * ratio)) // 2 * 2
        crop_h = int(crop_w / ratio) // 2 * 2
        if min(crop_w, crop_h) < 16:
            continue
        cx = int(area_x + (area_w - crop_w) / 2) // 2 * 2
        cy = int(area_y + (area_h - crop_h) / 2) // 2 * 2
        candidates.append((crop_w * crop_h, crop_w, crop_h, cx, cy))
    if not candidates:
        raise ValueError('Selection leaves no usable crop.')
    _, cw, ch, cx, cy = max(candidates)
    return f'crop={cw}:{ch}:{cx}:{cy},scale={width//2*2}:{height//2*2}:flags=lanczos,setsar=1'


def free_name(directory, stem, mode):
    candidate = directory / f'{stem}-{mode}.mp4'
    i = 2
    while candidate.exists():
        candidate = directory / f'{stem}-{mode}-{i}.mp4'
        i += 1
    return candidate


def run_one(source, out_dir, mode, region, emit, index, total):
    global ACTIVE
    width, height, duration, stream_index = probe(source)
    vf = make_filter(width, height, region, mode)
    directory = out_dir or source.parent / 'Watermark Remover Exports'
    directory.mkdir(parents=True, exist_ok=True)
    destination = free_name(directory, source.stem, mode)
    temporary = directory / f'.watermark-{uuid.uuid4().hex}.mp4'
    error_log = directory / f'.watermark-{uuid.uuid4().hex}.log'
    emit('start', input=str(source), output=str(destination), index=index, total=total)
    try:
        command = [tool('ffmpeg'), '-hide_banner', '-loglevel', 'error', '-nostdin', '-n',
            '-i', str(source), '-map', f'0:{stream_index}', '-map', '0:a?', '-vf', vf,
            '-c:v', 'libx264', '-preset', 'medium', '-crf', '18', '-pix_fmt', 'yuv420p',
            '-c:a', 'aac', '-b:a', '192k', '-map_metadata', '0', '-metadata:s:v:0', 'rotate=0',
            '-movflags', '+faststart', '-progress', 'pipe:1', '-nostats', str(temporary)]
        with error_log.open('w+') as errors:
            ACTIVE = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=errors, text=True)
            last_progress = 0
            for line in ACTIVE.stdout:
                if line.startswith('out_time_us='):
                    try:
                        elapsed = float(line.split('=', 1)[1]) / 1_000_000
                        progress = max(last_progress, min(1, elapsed / duration)) if duration else 0
                        last_progress = progress
                        emit('progress', fraction=((index - 1) + progress) / total)
                    except ValueError:
                        pass
            code = ACTIVE.wait()
            ACTIVE = None
            if code:
                errors.seek(0)
                raise ValueError(errors.read().strip()[-3000:] or 'FFmpeg could not process this video.')
        out_width, out_height, out_duration, _ = probe(temporary)
        if (out_width, out_height) != (width//2*2, height//2*2):
            raise ValueError('Output resolution validation failed.')
        if duration and abs(out_duration - duration) > max(0.3, duration * 0.01):
            raise ValueError('Output duration validation failed.')
        # Atomic no-overwrite publication, including competing runs.
        while True:
            try:
                os.link(temporary, destination)
                break
            except FileExistsError:
                destination = free_name(directory, source.stem, mode)
        emit('done', input=str(source), output=str(destination), index=index, total=total)
        return destination
    finally:
        if ACTIVE is not None:
            ACTIVE.terminate()
            try:
                ACTIVE.wait(timeout=5)
            except subprocess.TimeoutExpired:
                ACTIVE.kill()
                ACTIVE.wait()
            ACTIVE = None
        temporary.unlink(missing_ok=True)
        error_log.unlink(missing_ok=True)


def cancel(_signum, _frame):
    raise KeyboardInterrupt()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('inputs', nargs='+', type=Path, help='Videos or folders (non-recursive).')
    parser.add_argument('--mode', choices=('retouch', 'crop'), default='retouch')
    parser.add_argument('--region', type=region_arg, default=DEFAULT_REGION)
    parser.add_argument('--output-dir', type=Path)
    parser.add_argument('--json', action='store_true', help='Machine-readable progress events.')
    args = parser.parse_args()

    def emit(event, **details):
        if args.json:
            print(json.dumps(dict(event=event, **details)), flush=True)
        elif event == 'start':
            print(f"[{details['index']}/{details['total']}] {details['input']}", flush=True)
        elif event == 'done':
            print(f"Saved: {details['output']}", flush=True)
        elif event == 'error':
            print(f"Error: {details['message']}", file=sys.stderr, flush=True)

    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)
    sources = []
    for path in args.inputs:
        paths = sorted(p for p in path.iterdir() if p.is_file() and p.suffix.lower() in EXTENSIONS) if path.is_dir() else [path]
        for source in paths:
            source = source.expanduser().resolve()
            if source not in sources:
                sources.append(source)
    if not sources:
        emit('error', message='No videos found.')
        return 1
    failures, outputs = 0, []
    try:
        for index, source in enumerate(sources, 1):
            try:
                outputs.append(str(run_one(source, args.output_dir, args.mode, args.region, emit, index, len(sources))))
            except (ValueError, OSError, json.JSONDecodeError) as error:
                failures += 1
                emit('error', input=str(source), message=str(error))
        emit('complete', outputs=outputs, failures=failures)
        return 1 if failures else 0
    except KeyboardInterrupt:
        emit('cancelled', outputs=outputs)
        return 130


if __name__ == '__main__':
    sys.exit(main())
