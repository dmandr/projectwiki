#!/usr/bin/env python3
"""Push committed book changes only. No checkout, pull, merge or force push."""
import json, os, subprocess, sys, time
from pathlib import Path
book=Path(sys.argv[1]).resolve()
state=Path(sys.argv[2]).resolve()
state.parent.mkdir(parents=True,exist_ok=True)
env=dict(os.environ,GIT_TERMINAL_PROMPT='0',GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=10')
def git(*args):
 return subprocess.run(['git','-C',str(book),*args],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=60)
last=None
while True:
 try:
  head=git('rev-parse','HEAD').stdout.strip()
  branch=git('symbolic-ref','--short','HEAD').stdout.strip()
  if not branch: raise RuntimeError('Detached HEAD: auto-push paused')
  if head!=last or time.time()-checked>60:
   result=git('push','--porcelain','origin','HEAD:refs/heads/'+branch)
   payload={'checked_at':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'head':head,'branch':branch,'ok':result.returncode==0,'message':result.stderr.strip()[-1500:]}
   state.write_text(json.dumps(payload,indent=2)+'\n')
   if result.returncode==0:last=head
   else: print('Book push failed: '+payload['message'],flush=True);time.sleep(28)
   checked=time.time()
 except Exception as error:
  state.write_text(json.dumps({'ok':False,'message':str(error)})+'\n');print(type(error).__name__,flush=True);time.sleep(28)
 time.sleep(2)
