#!/usr/bin/env python3
"""Prepare a small speaker-disjoint AMI evaluation set from official downloads.
Audio remains in the supplied local directory; never download personal media.
AMI word times are forced alignment, not manually checked boundaries.
"""
import argparse, array, hashlib, json, math, random, re, sys, wave, zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

parser = argparse.ArgumentParser()
parser.add_argument('--meeting', default='ES2002b')
parser.add_argument('--source', type=Path, default=Path('ReviewArtifacts/MLCorpus'))
parser.add_argument('--output', type=Path, default=Path('ReviewArtifacts/MLCorpus/ami-mini'))
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
archive = zipfile.ZipFile(args.source / 'ami-public-manual.zip')
meeting = next(x for x in ET.fromstring(archive.read('corpusResources/meetings.xml')) if x.attrib.get('observation') == args.meeting)
speakers = {x.attrib['nxt_agent']: x.attrib for x in meeting}
clips = []
for channel, agent in enumerate('ABCD'):
    source = args.source / f'{args.meeting}.Headset-{channel}.wav'
    words = []
    for node in ET.fromstring(archive.read(f'words/{args.meeting}.{agent}.words.xml')):
        text = (node.text or '').strip().replace('*', '')
        if node.tag != 'w' or node.attrib.get('punc') == 'true' or not re.search(r'[A-Za-z]', text): continue
        if any(symbol in text for symbol in '@#$%[]'): continue
        words.append({'text': text, 'start': float(node.attrib['starttime']), 'end': float(node.attrib['endtime']), 'timingSource': 'forcedAlignment'})
    candidates = []
    for index, word in enumerate(words):
        following = [w for w in words[index:] if w['end'] <= word['start'] + 20]
        if len(following) >= 10: candidates.append((len(following), word['start'], following))
    candidates.sort(key=lambda x: (-x[0], x[1]))
    chosen = []
    for _, start, group in candidates:
        if any(abs(start - existing[0]) < 25 for existing in chosen): continue
        chosen.append((start, group))
        if len(chosen) == 3: break
    if len(chosen) != 3: raise SystemExit(f'Insufficient usable speech for {agent}')
    source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
    with wave.open(str(source), 'rb') as audio:
        if audio.getsampwidth() != 2 or audio.getnchannels() != 1: raise SystemExit('Expected official 16-bit mono headset audio')
        rate = audio.getframerate()
        for number, (start, group) in enumerate(sorted(chosen)):
            cut = max(0, start - .15); duration = group[-1]['end'] + .35 - cut
            audio.setpos(round(cut * rate)); raw = audio.readframes(round(duration * rate))
            reference = [{**w, 'start': round(w['start'] - cut, 6), 'end': round(w['end'] - cut, 6)} for w in group]
            split = 'train' if agent in 'AB' else 'validation' if agent == 'C' else 'held-out'
            for noise in ([False, True] if number == 0 else [False]):
                identifier = f'ami-{args.meeting}-{agent}-{number}' + ('-noise15db' if noise else '')
                data = raw
                if noise:
                    samples = array.array('h'); samples.frombytes(raw)
                    if sys.byteorder != 'little': samples.byteswap()
                    rms = math.sqrt(sum(x*x for x in samples) / len(samples))
                    rng = random.Random(20261005 + channel)
                    sd = rms / (10 ** (15 / 20))
                    samples = array.array('h', (max(-32768, min(32767, round(x + rng.gauss(0, sd)))) for x in samples))
                    if sys.byteorder != 'little': samples.byteswap()
                    data = samples.tobytes()
                destination = args.output / (identifier + '.wav')
                with wave.open(str(destination), 'wb') as out:
                    out.setnchannels(1); out.setsampwidth(2); out.setframerate(rate); out.writeframes(data)
                clips.append({'id': identifier, 'speakerID': speakers[agent]['global_name'], 'split': split, 'audioPath': destination.name,
                              'sourceOffsetSeconds': round(cut, 6), 'sourceSHA256': source_hash, 'audioSHA256': hashlib.sha256(destination.read_bytes()).hexdigest(),
                              'script': ' '.join(w['text'] for w in reference), 'referenceWords': reference, 'duration': len(raw) / (2 * rate),
                              'license': 'CC BY 4.0 — AMI Meeting Corpus', 'sourceURL': f'https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/{args.meeting}/audio/{args.meeting}.Headset-{channel}.wav', 'isPublic': True})
manifest = {'version': 'ami-mini-v1', 'annotationsSHA256': hashlib.sha256((args.source / 'ami-public-manual.zip').read_bytes()).hexdigest(), 'clips': clips}
(args.output / 'corpus.json').write_text(json.dumps(manifest, indent=2))
(args.output / 'SHA256.json').write_text(json.dumps({p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(args.output.glob('*.wav'))}, indent=2))
print(f'Prepared {len(clips)} clips from four disjoint speakers; timings are forced alignment.')
