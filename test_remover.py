"""Integration checks for output safety, batch failures, rotation and audio."""
import hashlib
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest

import remove_watermark as remover


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / "clip ' $().mp4"
        subprocess.run([remover.tool('ffmpeg'), '-v', 'error', '-f', 'lavfi',
            '-i', 'testsrc2=size=320x180:rate=12:duration=1', '-f', 'lavfi',
            '-i', 'sine=frequency=440:duration=1', '-c:v', 'libx264',
            '-c:a', 'aac', '-shortest', str(self.source)], check=True)
        self.original_hash = hashlib.sha256(self.source.read_bytes()).hexdigest()

    def tearDown(self):
        self.assertEqual(hashlib.sha256(self.source.read_bytes()).hexdigest(), self.original_hash)
        self.temp.cleanup()

    def run_cli(self, *arguments):
        result = subprocess.run([sys.executable, str(Path(remover.__file__)), '--json',
            *map(str, arguments)], text=True, capture_output=True)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        return result, events

    def test_batch_failure_continues_and_existing_export_is_preserved(self):
        output = self.root / 'exports'
        output.mkdir()
        existing = output / f'{self.source.stem}-retouch.mp4'
        existing.write_bytes(b'keep existing export')
        bad = self.root / 'broken.mp4'
        bad.write_bytes(b'not a video')
        result, events = self.run_cli(bad, self.source, '--output-dir', output)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(events[-1]['failures'], 1)
        self.assertEqual(len(events[-1]['outputs']), 1)
        destination = Path(events[-1]['outputs'][0])
        self.assertTrue(destination.name.endswith('-retouch-2.mp4'))
        self.assertEqual(existing.read_bytes(), b'keep existing export')
        self.assertEqual(remover.probe(destination)[:2], (320,180))
        audio = subprocess.run([remover.tool('ffprobe'), '-v', 'error', '-select_streams',
            'a', '-show_entries', 'stream=codec_name', '-of', 'csv=p=0', str(destination)],
            capture_output=True, text=True, check=True)
        self.assertEqual(audio.stdout.strip(), 'aac')
        fractions = [e['fraction'] for e in events if e['event'] == 'progress']
        self.assertEqual(fractions, sorted(fractions))
        self.assertFalse(list(output.glob('.watermark-*')))

    def test_rotated_silent_input_with_both_modes(self):
        rotated = self.root / 'rotated.mp4'
        subprocess.run([remover.tool('ffmpeg'), '-v', 'error', '-display_rotation', '90',
            '-i', str(self.source), '-an', '-c:v', 'copy', str(rotated)], check=True)
        self.assertEqual(remover.probe(rotated)[:2], (180,320))
        for mode in ('retouch', 'crop'):
            with self.subTest(mode=mode):
                result, events = self.run_cli(rotated, '--mode', mode)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                destination = Path(events[-1]['outputs'][0])
                self.assertEqual(remover.probe(destination)[:2], (180,320))
                subprocess.run([remover.tool('ffmpeg'), '-v', 'error', '-i', str(destination),
                    '-f', 'null', '-'], check=True, capture_output=True)

    def test_cancellation_cleans_partial_export(self):
        output = self.root / 'cancelled'
        process = subprocess.Popen([sys.executable, str(Path(remover.__file__)), '--json',
            str(self.source), '--output-dir', str(output)], stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True)
        event = json.loads(process.stdout.readline())
        self.assertEqual(event['event'], 'start')
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=15)
        self.assertEqual(process.returncode, 130, stdout + stderr)
        self.assertEqual(list(output.iterdir()), [])

    def test_invalid_regions_are_rejected(self):
        for region in ('nan,0,.1,.1', '0,0,1,1', '.8,.9,.3,.2', '0,0,-.1,.1'):
            result, _ = self.run_cli(self.source, '--region', region)
            self.assertEqual(result.returncode, 2)


if __name__ == '__main__':
    unittest.main()
