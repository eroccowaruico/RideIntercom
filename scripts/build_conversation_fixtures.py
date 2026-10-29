#!/usr/bin/env python3
"""Generate deterministic-layout conversation fixtures with installed macOS voices.

Generation is optional: automated tests use the checked-in WAVs and manifest.
Speech synthesis can vary with OS/voice versions; review new output before replacing fixtures.
"""
import argparse
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import wave


def generate(destination):
    destination.mkdir(parents=True, exist_ok=True)
    pairs = [
        ('conversation-ja', 'Kyoko', [
            '次の分岐で右に曲がります。速度を落として、間隔を保ってください。', 'うん', 'ふん',
            '了解。前の人が止まったら、こちらも止まります。']),
        ('conversation-reply-ja', 'Reed (日本語（日本）)', [
            'こちらは聞こえています。後ろからも合図を送ります。', 'うん', 'ふん',
            '大丈夫です。このままゆっくり進みましょう。']),
    ]
    manifest = dict(sampleRate=48000, channels=1, pausesSeconds=[1, 2, 3], fixtures=[])
    with tempfile.TemporaryDirectory(prefix='ride-conversation-') as folder:
        temporary = Path(folder)
        for name, voice, phrases in pairs:
            audio = [0] * 24000
            utterances = []
            for index, phrase in enumerate(phrases):
                aiff, wav = temporary / 'speech.aiff', temporary / 'speech.wav'
                subprocess.run(['/usr/bin/say', '-v', voice, '-r', '190', '-o', str(aiff), phrase], check=True)
                subprocess.run(['/usr/bin/afconvert', '-f', 'WAVE', '-d', 'LEI16@48000', '-c', '1', str(aiff), str(wav)], check=True)
                with wave.open(str(wav), 'rb') as source:
                    assert (source.getnchannels(), source.getframerate(), source.getsampwidth()) == (1, 48000, 2)
                    pcm = list(struct.unpack('<' + 'h' * source.getnframes(), source.readframes(source.getnframes())))
                audible = [i for i, value in enumerate(pcm) if abs(value) > 32]
                assert audible, 'Synthesized phrase must be audible'
                pcm = pcm[max(0, audible[0] - 240):min(len(pcm), audible[-1] + 241)]
                start = len(audio) / 48000
                audio.extend(pcm)
                utterances.append(dict(text=phrase, startSeconds=start, endSeconds=len(audio) / 48000))
                if index < 3:
                    audio.extend([0] * (48000 * (index + 1)))
            audio.extend([0] * 24000)
            with wave.open(str(destination / (name + '.wav')), 'wb') as target:
                target.setparams((1, 2, 48000, len(audio), 'NONE', 'not compressed'))
                target.writeframes(struct.pack('<' + 'h' * len(audio), *audio))
            manifest['fixtures'].append(dict(name=name, voice=voice, rate=190, durationSeconds=len(audio)/48000, utterances=utterances))
    (destination / 'conversation-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    generate(parser.parse_args().output)
