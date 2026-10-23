"""Owned-AVD guest adapter; normal APK source and production clients are used."""
import json,re,subprocess

class AndroidGuest:
    def __init__(self,root,adb,serial,port,run):
        self.adb=[str(adb),'-s',serial];self.app='org.kuray.kif';self.run=run;self.backups=[];self.reverse_port=None
        assert serial!='emulator-5554' and self.command('emu','avd','name').startswith('kif_mixed_'),'Owned AVD required'
        self.command('shell','am','force-stop',self.app)
        record=json.loads((root/'temp/artifacts/KIF-0.20.7-android.9-arm64-emulator-network-test-build-record.json').read_text(encoding='utf-8'))
        content=self.command('shell','run-as',self.app,'cat','files/active-content');assert re.fullmatch('[0-9a-f]{24}',content)
        apk=self.command('shell','pm','path',self.app).removeprefix('package:');assert re.fullmatch(r'/data/app/[A-Za-z0-9_./~+=-]+/base\.apk',apk)
        sha=self.command('shell','sha256sum',apk,timeout=90).split()[0]
        assert sha==record['sha256'] and content==record['payload'],'Installed final APK mismatch'
        self.metadata=dict(apk_sha256=sha,content=content,platform='Android11/API30 x86_64 owned AVD with ARM64 translation')
        self.private='/data/user/0/'+self.app+'/files/diagnostics/expansion-'+run.name
        self.game='/data/user/0/'+self.app+'/files/content/'+content
        self.command('shell','run-as',self.app,'mkdir','-p',self.private,self.game+'/scripts/multiplayer')
        for name in ('android-game-smoke.rb','mkxp.json'):
            if subprocess.run(self.adb+['shell','run-as',self.app,'test','-f',self.game+'/'+name],capture_output=True).returncode==0:
                self.command('shell','run-as',self.app,'cp',self.game+'/'+name,self.private+'/original-'+name);self.backups.append(name)
        try:
            # shortcut: this AVD's NAT truncates UTF-8 responses; use ADB's local tunnel until the emulator route is reliable.
            self.command('reverse','--no-rebind','tcp:'+str(port),'tcp:'+str(port));self.reverse_port=port
            self.metadata['transport']='ADB reverse to the isolated loopback server'
            for name,path in {'test-bootstrap.rb':root/'scripts/multiplayer/test-bootstrap.rb','runtime-preload.rb':root/'scripts/multiplayer/runtime-preload.rb','market_expansion_game.rb':root/'tests/multiplayer/market_expansion_game.rb'}.items():self.push(path,self.game+'/scripts/multiplayer/'+name)
            scenario=run/'android-scenario.json';scenario.write_text(json.dumps(dict(role='guest',cross_device=True,directory='http-fixture')),encoding='utf-8');self.push(scenario,self.private+'/scenario.json')
            env=dict(KIF_MULTIPLAYER_PROFILE='market-expansion-guest',KIF_MULTIPLAYER_SAVE_DIR=self.private,KIF_MULTIPLAYER_SERVER='http://127.0.0.1:'+str(port),KIF_MULTIPLAYER_SCENARIO=self.private+'/scenario.json')
            wrapper=run/'android-entry.rb';wrapper.write_text('\n'.join('ENV['+json.dumps(key)+']='+json.dumps(value) for key,value in env.items())+'\nload "kif_android_preload.rb"\nload "scripts/multiplayer/market_expansion_game.rb"\n',encoding='utf-8');self.push(wrapper,self.game+'/android-game-smoke.rb')
        except Exception:
            self.close();raise
    def command(self,*args,check=True,timeout=35):
        value=subprocess.run(self.adb+list(args),capture_output=True,timeout=timeout)
        if check and value.returncode:raise RuntimeError((value.stdout+value.stderr).decode(errors='replace')[-1500:])
        return value.stdout.decode('utf-8',errors='replace').strip()
    def push(self,source,target):
        transfer='/data/local/tmp/kif-market-expansion'
        self.command('push',str(source),transfer);self.command('shell','run-as',self.app,'cp',transfer,target)
    def start(self):
        self.command('shell','am','force-stop',self.app)
        self.command('shell','am','start','-W','-n',self.app+'/.LauncherActivity','--ez','gameSmoke','true')
    def error(self):
        value=self.command('exec-out','run-as',self.app,'cat',self.private+'/market-extension-error.log',check=False)
        return value if value and not value.startswith('cat:') else None
    def close(self):
        for name in ('feature-smoke.log','runtime.log','market-extension-error.log','market-rental-map.png'):
            value=subprocess.run(self.adb+['exec-out','run-as',self.app,'cat',self.private+'/'+name],capture_output=True,timeout=20)
            valid=value.stdout.startswith(b'\x89PNG') if name.endswith('.png') else bool(value.stdout) and not value.stdout.startswith(b'cat:')
            if value.returncode==0 and valid:(self.run/('android-'+name)).write_bytes(value.stdout)
        self.command('shell','am','force-stop',self.app,check=False)
        for name in ('android-game-smoke.rb','mkxp.json'):
            if name in self.backups:self.command('shell','run-as',self.app,'cp',self.private+'/original-'+name,self.game+'/'+name,check=False)
            else:self.command('shell','run-as',self.app,'rm','-f',self.game+'/'+name,check=False)
        if self.reverse_port is not None:self.command('reverse','--remove','tcp:'+str(self.reverse_port),check=False)
