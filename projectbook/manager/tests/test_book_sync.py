import sys, tempfile, subprocess, unittest, fcntl, threading, time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from book_sync import sync_book

class SyncTest(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
  self.remote=self.root/'remote';self.a=self.root/'a';self.b=self.root/'b'
  self.run_git(self.root,'init','--bare',str(self.remote))
  self.run_git(self.root,'clone',str(self.remote),str(self.a))
  self.run_git(self.a,'checkout','-b','main');self.commit(self.a,'Home.md','Home')
  self.run_git(self.a,'push','origin','main');self.run_git(self.remote,'symbolic-ref','HEAD','refs/heads/main')
  self.run_git(self.root,'clone',str(self.remote),str(self.b))
 def tearDown(self):self.tmp.cleanup()
 def run_git(self,path,*args,check=True):
  p=subprocess.run(['git','-c','user.name=Test','-c','user.email=test@example.invalid',*args],cwd=path,capture_output=True,text=True)
  if check and p.returncode:raise RuntimeError(p.stderr)
  return p.stdout.strip() if check else p
 def commit(self,path,name,text):
  (path/name).write_text(text);self.run_git(path,'add',name);self.run_git(path,'commit','-m','Test')
 def sync(self,path):return sync_book(lambda *a,**kw:self.run_git(path,*a,**kw),path)
 def test_pull_push_and_repeat(self):
  self.commit(self.a,'one.md','one');self.sync(self.a);result=self.sync(self.b)
  self.assertEqual(result['pulled_commits'],1);self.assertEqual((self.b/'one.md').read_text(),'one')
  self.commit(self.b,'two.md','two');self.sync(self.b);self.sync(self.a)
  self.assertTrue((self.a/'two.md').exists());self.assertEqual(self.sync(self.a)['pulled_commits'],0)
 def test_diverged_history_is_untouched(self):
  self.commit(self.a,'a.md','a');self.commit(self.b,'b.md','b');self.sync(self.a)
  before=self.run_git(self.b,'rev-parse','HEAD')
  with self.assertRaisesRegex(RuntimeError,'diverged'):self.sync(self.b)
  self.assertEqual(before,self.run_git(self.b,'rev-parse','HEAD'));self.assertFalse((self.b/'a.md').exists())
 def test_uncommitted_changes_preserved(self):
  (self.b/'Home.md').write_text('unsaved')
  with self.assertRaisesRegex(RuntimeError,'Uncommitted'):self.sync(self.b)
  self.assertEqual((self.b/'Home.md').read_text(),'unsaved')
 def test_ignored_notes_preserved(self):
  self.commit(self.a,'.gitignore','raw-notes/\n');self.sync(self.a);self.sync(self.b)
  (self.b/'raw-notes').mkdir();(self.b/'raw-notes/note.md').write_text('local')
  self.sync(self.b);self.assertEqual((self.b/'raw-notes/note.md').read_text(),'local')
  self.assertNotIn('raw-notes',self.run_git(self.b,'ls-files'))
 def test_remote_cannot_overwrite_ignored_note(self):
  self.commit(self.a,'.gitignore','raw-notes/\n');self.sync(self.a);self.sync(self.b)
  for p in [self.a,self.b]:(p/'raw-notes').mkdir()
  (self.b/'raw-notes/note.md').write_text('local')
  (self.a/'raw-notes/note.md').write_text('remote');self.run_git(self.a,'add','-f','raw-notes/note.md');self.run_git(self.a,'commit','-m','remote note');self.sync(self.a)
  with self.assertRaises(RuntimeError):self.sync(self.b)
  self.assertEqual((self.b/'raw-notes/note.md').read_text(),'local')
 def test_sync_waits_for_application_lock(self):
  self.commit(self.a,'new.md','new');self.sync(self.a)
  errors=[]
  def work():
   try:self.sync(self.b)
   except Exception as e:errors.append(e)
  with (self.b/'.git/projectbook-sync.lock').open('a+') as lock:
   fcntl.flock(lock,fcntl.LOCK_EX)
   thread=threading.Thread(target=work);thread.start();time.sleep(.3)
   self.assertFalse((self.b/'new.md').exists())
   fcntl.flock(lock,fcntl.LOCK_UN)
  thread.join(10);self.assertFalse(thread.is_alive());self.assertEqual(errors,[])
  self.assertTrue((self.b/'new.md').exists())
if __name__=='__main__':unittest.main()
