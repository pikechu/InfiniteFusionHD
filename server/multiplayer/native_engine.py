"""Private, signed IPC to the installed native game runtime.

The public client never receives the signing key or submits engine results.
Workers use isolated data directories and only fixed, installed Ruby code.
"""
from pathlib import Path
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import subprocess
import time


def canonical(value):
    return json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(',',':'),allow_nan=False).encode('utf-8')


def atomic_private(path,data):
    path = Path(path)
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    temporary = path.with_name('.'+path.name+'-'+secrets.token_hex(8))
    descriptor = os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    try:
        with os.fdopen(descriptor,'wb') as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary,path)
    finally:
        temporary.unlink(missing_ok=True)


class NativeEngine:
    def __init__(self,game_root,engine_root):
        self.game_root,self.root = Path(game_root).resolve(),Path(engine_root).resolve()
        self.worker=Path(__file__).resolve().with_name('native_worker.rb')
        required = ('Game.exe','Game.ini','Data/Scripts','Data/multiplayer-build.json')
        if not self.worker.is_file() or not all((self.game_root/name).exists() for name in required):
            raise ValueError('Native mainline runtime is incomplete')
        if self.root == self.root.parent or self.root == self.game_root:
            raise ValueError('Use a dedicated engine work directory')
        self.root.mkdir(parents=True,exist_ok=True,mode=0o700)
        self.secret = secrets.token_bytes(32)
        self.key_path = self.root/'worker.key'
        atomic_private(self.key_path,self.secret)
        self.processes = {}

    def directory(self,job_id):
        if not re.fullmatch(r'job_[a-f0-9]{32}',job_id):
            raise ValueError('Invalid native job ID')
        result = (self.root/job_id).resolve()
        if result.parent != self.root:
            raise ValueError('Native job escaped its work directory')
        return result

    def signed(self,payload):
        return {'payload':payload,'signature':hmac.new(self.secret,canonical(payload),hashlib.sha256).hexdigest()}

    def read_signed(self,path):
        path = Path(path)
        if not path.is_file():
            return None
        if path.stat().st_size>2*1024*1024:
            raise ValueError('Native response exceeds its limit')
        document = json.loads(path.read_text(encoding='utf-8'))
        if type(document) is not dict or set(document)!={'payload','signature'} or type(document['signature']) is not str:
            raise ValueError('Invalid native response envelope')
        expected = hmac.new(self.secret,canonical(document['payload']),hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected,document['signature']):
            raise ValueError('Native response signature does not match this service')
        return document['payload']

    def start(self,job_id,payload):
        directory = self.directory(job_id)
        if job_id in self.processes:
            return
        # Reap only owned process objects; completed jobs never launch twice
        # merely because a DB status update was retried after worker completion.
        for old_id,process in list(self.processes.items()):
            if process.poll() is not None:
                process.wait()
                del self.processes[old_id]
        existing = self.read_signed(directory/'result.json')
        if existing is not None:
            if existing.get('job_id')!=job_id or existing.get('nonce')!=payload.get('nonce'):
                raise ValueError('Completed native job has a different input nonce')
            return
        directory.mkdir(exist_ok=True,mode=0o700)
        (directory/'cache').mkdir(exist_ok=True,mode=0o700)
        for source in [self.game_root/'Game.exe',self.game_root/'Game.ini',*self.game_root.glob('*.dll')]:
            target = directory/source.name
            if not target.exists():
                try:
                    os.link(source,target)
                except OSError:
                    shutil.copyfile(source,target)
        config = {'gameFolder':self.game_root.as_posix(),'rgssVersion':1,'windowTitle':'KIF Server Engine','defScreenW':512,'defScreenH':384,'pathCache':False,'customScript':self.worker.as_posix()}
        atomic_private(directory/'mkxp.json',canonical(config))
        request = dict(payload,job_id=job_id)
        atomic_private(directory/'request.json',canonical(self.signed(request)))
        environment = dict(os.environ)
        environment.update(KIF_SERVER_ENGINE='1',KIF_ENGINE_JOB_DIR=str(directory),KIF_ENGINE_SECRET_FILE=str(self.key_path),KIF_MULTIPLAYER_SAVE_DIR=str(directory/'cache'),KIF_MULTIPLAYER_PROFILE='engine-'+job_id)
        options = {}
        if os.name=='nt':
            startup = subprocess.STARTUPINFO()
            startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startup.wShowWindow = 0
            options.update(startupinfo=startup,creationflags=subprocess.CREATE_NO_WINDOW)
        stdout,stderr = open(directory/'stdout.log','wb'),open(directory/'stderr.log','wb')
        try:
            process = subprocess.Popen([str(directory/'Game.exe')],cwd=directory,env=environment,stdin=subprocess.DEVNULL,stdout=stdout,stderr=stderr,**options)
            self.processes[job_id] = process
        finally:
            stdout.close()
            stderr.close()

    def poll(self,job_id,nonce):
        directory = self.directory(job_id)
        for name in ('result.json','prompt.json'):
            value = self.read_signed(directory/name)
            if value is not None:
                if type(value) is not dict or value.get('job_id')!=job_id or value.get('nonce')!=nonce:
                    raise ValueError('Native response is for a different job')
                return name.split('.')[0],value
        process = self.processes.get(job_id)
        if process and process.poll() is not None:
            raise RuntimeError('Native engine exited without a verified result')
        return 'running',None

    def command(self,job_id,nonce,sequence,command):
        if type(sequence) is not int or not 0<=sequence<1000:
            raise ValueError('Invalid native command sequence')
        payload = {'job_id':job_id,'nonce':nonce,'sequence':sequence,'command':command}
        target = self.directory(job_id)/('command-%04d.json'%sequence)
        if target.exists():
            existing = self.read_signed(target)
            if existing != payload:
                raise ValueError('Native command sequence was reused')
            return
        atomic_private(target,canonical(self.signed(payload)))

    def close(self):
        # Only processes launched and retained by this exact instance are owned.
        # Never kill a PID recovered from disk after a restart.
        for job_id in list(self.processes):
            self.cancel(job_id)

    def cancel(self,job_id):
        process=self.processes.pop(job_id,None)
        if process and process.poll() is None:
            process.terminate()
            try:process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill();process.wait(timeout=2)
