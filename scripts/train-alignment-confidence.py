#!/usr/bin/env python3
"""Deterministic L2 multinomial logistic regression, standard library only.
Train weights on train speakers; select a confidence threshold on validation.
Report held-out results once. Input rows are transcript-derived simulations.
"""
import argparse, json, math, pathlib
p=argparse.ArgumentParser(); p.add_argument('rows'); p.add_argument('--output',required=True); a=p.parse_args()
all_rows=json.loads(pathlib.Path(a.rows).read_text())
rows=[r for r in all_rows if r.get("features") is not None and r.get("label") is not None]
parts={split:[r for r in rows if r['split']==split] for split in ('train','validation','held-out')}
speakers={s:sorted(set(r['speakerID'] for r in rs)) for s,rs in parts.items()}
assert all(parts.values()) and len(parts['train'])>=50
assert not(set(speakers['train']) & set(speakers['validation']+speakers['held-out']))
assert not(set(speakers['validation']) & set(speakers['held-out']))
size=10
constant=[False]+[max(r["features"][j] for r in parts["train"])-min(r["features"][j] for r in parts["train"])<1e-9 for j in range(9)]
weights=[[0.0]*size for _ in range(3)]
def predict(r):
    x=[1.0]+r['features']; logits=[sum(w*v for w,v in zip(ws,x)) for ws in weights]
    ex=[math.exp(v-max(logits)) for v in logits]; return [v/sum(ex) for v in ex]
for epoch in range(400):
    gradient=[[0.0]*size for _ in range(3)]
    for r in parts['train']:
        probs=predict(r); x=[1.0]+r['features']
        for k in range(3):
            delta=probs[k]-(r['label']==k)
            for j in range(size): gradient[k][j]+=delta*x[j]
    for k in range(3):
        for j in range(size):
            if constant[j]: continue
            weights[k][j]-=0.3*(gradient[k][j]/len(parts['train'])+(.01*weights[k][j] if j else 0))
def score(rs,threshold):
    ps=[(r,predict(r)) for r in rs]
    wrong_accept=sum(r['label']==1 and prob[0]+prob[2]>=threshold for r,prob in ps)
    good_hold=sum(r['label']!=1 and prob[0]+prob[2]<threshold for r,prob in ps)
    brier=sum(((prob[0]+prob[2])-(r['label']!=1))**2 for r,prob in ps)/len(ps)
    return {'rows':len(rs),'wrongCandidateAccepted':wrong_accept,'correctCandidateHeld':good_hold,'brierCorrectness':brier,
            'incorrectCandidates':sum(r['label']==1 for r in rs)}
threshold=min([i/100 for i in range(20,96,5)], key=lambda t: score(parts['validation'],t)['wrongCandidateAccepted']*4+score(parts['validation'],t)['correctCandidateHeld'])
model={'version':'ami-pilot-simulation-v1','featureNames':['quality','margin','coverage','context','distance','backward','misses','asrConfidence','asrConfidenceKnown'],
       'coefficients':weights,'trainingSpeakers':speakers['train'],'validationSpeakers':speakers['validation'],'heldOutSpeakers':speakers['held-out'],
       'trainingRows':len(parts['train']),'sourceCorpus':'AMI ES2002b CC BY 4.0; transcript-derived error simulations, no audio training','holdThreshold':threshold,'maximumScriptTokens':max(r['scriptTokenCount'] for r in parts['train'])}
out=pathlib.Path(a.output); out.parent.mkdir(parents=True,exist_ok=True); out.write_text(json.dumps(model,indent=2)+'\n')
report={'method':'transcript-derived recognition-error simulation; independent of ASR and live latency','epochs':400,'learningRate':.3,'L2':.01,'thresholdSelectedOn':'validation',
        'splits':{s:score(rs,threshold) for s,rs in parts.items()},'baseline':'Current rule tracker; these candidate statistics do not measure resulting tracking/recovery. Production promotion requires end-to-end replay.'}
out.with_suffix('.evaluation.json').write_text(json.dumps(report,indent=2)+'\n'); print(json.dumps(report,indent=2))
