#!/usr/bin/env python3
"""Create a local word-boundary review page, or apply its reviewed JSON export.
Raw speech remains local. Automated AMI boundaries are never silently relabeled.
"""
import argparse, json, pathlib, html
p=argparse.ArgumentParser(); p.add_argument('manifest'); p.add_argument('--clip'); p.add_argument('--output'); p.add_argument('--apply'); a=p.parse_args()
path=pathlib.Path(a.manifest).resolve(); manifest=json.loads(path.read_text())
if a.apply:
    review=json.loads(pathlib.Path(a.apply).read_text()); clip=next(c for c in manifest['clips'] if c['id']==review['clipID'])
    assert review['reviewer'].strip() and review['reviewedAt']
    words=review['words']; assert len(words)==len(clip['referenceWords'])
    previous=0
    for word,original in zip(words,clip['referenceWords']):
        assert word['text']==original['text'] and word['checked'] is True
        assert 0<=word['start']<=word['end']<=clip['duration'] and word['start']>=previous
        previous=word['start']; word.pop('checked'); word['timingSource']='manualReviewed'
    clip['referenceWords']=words; clip['timingReviewer']=review['reviewer']; clip['timingReviewedAt']=review['reviewedAt']
    manifest['version']+='-reviewed'; destination=pathlib.Path(a.output or str(path.with_name('corpus-reviewed.json')))
    destination.write_text(json.dumps(manifest,indent=2)+'\n'); print(destination); raise SystemExit
assert a.clip and a.output
clip=next(c for c in manifest['clips'] if c['id']==a.clip)
audio=(path.parent/clip['audioPath']).as_uri()
data=json.dumps(clip).replace('<','\\u003c')
page='''<!doctype html><meta charset="utf-8"><title>CameraCue timing review</title>
<style>body{font:16px system-ui;max-width:850px;margin:40px auto;color:#332941;background:#fbfaf7}button,input{font:inherit;padding:10px;margin:4px;border:1px solid #ddd4e9;border-radius:8px}button{background:#eee5ff}li{padding:8px}li.active{background:#eee5ff}#words{max-height:350px;overflow:auto}label{display:block}audio{width:100%}</style>
<h1>Review word boundaries</h1><p>Listen to every word and check its start/end. Original timing is forced alignment, not a human review. Export is enabled only when every word is checked.</p>
<audio id="audio" controls src="AUDIO"></audio><p id="status"></p><div><button id="play">Play word</button><button id="start">Set start at playhead</button><button id="end">Set end at playhead</button><button id="checked">Checked; next word</button></div>
<label>Start <input id="s" type="number" min="0" step=".01"></label><label>End <input id="e" type="number" min="0" step=".01"></label><ol id="words"></ol>
<label>Reviewer <input id="reviewer" placeholder="Name or reviewer ID"></label><button id="export">Export reviewed boundaries</button>
<script>const clip=DATA, words=clip.referenceWords.map(w=>({...w,checked:false}));let i=0, stop=null;const audio=document.querySelector('audio'),s=document.querySelector('#s'),e=document.querySelector('#e'),list=document.querySelector('#words');
function render(){list.replaceChildren();words.forEach((w,n)=>{const li=document.createElement('li');li.textContent=(w.checked?'✓ ':'')+w.text+' '+w.start.toFixed(2)+'–'+w.end.toFixed(2);li.className=n===i?'active':'';li.onclick=()=>{i=n;render()};list.append(li)});s.value=words[i].start;e.value=words[i].end;document.querySelector('#status').textContent=`Word ${i+1}/${words.length} · ${words.filter(w=>w.checked).length} checked`;document.querySelector('#export').disabled=words.some(w=>!w.checked)||!document.querySelector('#reviewer').value.trim()}
function update(){words[i].start=+s.value;words[i].end=+e.value;words[i].checked=false;render()}
s.onchange=e.onchange=update;document.querySelector('#reviewer').oninput=render;
document.querySelector('#start').onclick=()=>{s.value=audio.currentTime;update()};document.querySelector('#end').onclick=()=>{e.value=audio.currentTime;update()};
document.querySelector('#play').onclick=()=>{audio.currentTime=Math.max(0,words[i].start-.1);stop=words[i].end+.1;audio.play()};audio.ontimeupdate=()=>{if(stop!==null&&audio.currentTime>=stop){audio.pause();stop=null}};
document.querySelector('#checked').onclick=()=>{const w=words[i];if(!(w.start>=0&&w.end>=w.start&&w.end<=clip.duration)){alert('Invalid boundaries');return}w.checked=true;i=Math.min(i+1,words.length-1);render()};
document.querySelector('#export').onclick=()=>{const result={clipID:clip.id,reviewer:document.querySelector('#reviewer').value.trim(),reviewedAt:new Date().toISOString(),words};const link=document.createElement('a');link.href=URL.createObjectURL(new Blob([JSON.stringify(result,null,2)],{type:'application/json'}));link.download=clip.id+'-reviewed.json';link.click();URL.revokeObjectURL(link.href)};render();</script>'''
page=page.replace('AUDIO',html.escape(audio,quote=True)).replace('DATA',data)
pathlib.Path(a.output).write_text(page); print(a.output)
