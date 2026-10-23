"""Owned-AVD adapter for the same production managed-role restore scenario."""
import json,re,subprocess,time

def restore_android(root,adb_path,serial,port,username,evidence):
    app='org.kuray.kif';adb=[str(adb_path),'-s',serial]
    def command(*args,check=True,timeout=35):
        result=subprocess.run(adb+list(args),capture_output=True,timeout=timeout)
        if check and result.returncode:raise RuntimeError((result.stdout+result.stderr).decode(errors='replace')[-1500:])
        return result.stdout.decode('utf-8',errors='replace').strip()
    assert serial!='emulator-5554' and command('emu','avd','name').startswith('kif_mixed_'),'Owned AVD required'
    record=json.loads((root/'temp/artifacts/KIF-0.20.7-android.9-arm64-emulator-network-test-build-record.json').read_text(encoding='utf-8'))
    content=command('shell','run-as',app,'cat','files/active-content');assert re.fullmatch('[0-9a-f]{24}',content)
    command('shell','am','force-stop',app)
    apk=command('shell','pm','path',app).removeprefix('package:')
    assert re.fullmatch(r'/data/app/[A-Za-z0-9_./~+=-]+/base\.apk',apk)
    sha=command('shell','sha256sum',apk,timeout=90).split()[0]
    assert sha==record['sha256'] and content==record['payload'],'Installed APK mismatch'
    private='/data/user/0/'+app+'/files/diagnostics/mainline-'+evidence.name
    game='/data/user/0/'+app+'/files/content/'+content;backups=[]
    command('shell','am','force-stop',app)
    command('shell','run-as',app,'mkdir','-p',private,game+'/scripts/multiplayer')
    def push(source,target):
        transfer='/data/local/tmp/kif-mainline-restore';command('push',str(source),transfer)
        command('shell','run-as',app,'cp',transfer,target)
    for name in ('android-game-smoke.rb','mkxp.json'):
        if subprocess.run(adb+['shell','run-as',app,'test','-f',game+'/'+name],capture_output=True).returncode==0:
            command('shell','run-as',app,'cp',game+'/'+name,private+'/original-'+name);backups.append(name)
    try:
        for name,path in {'test-bootstrap.rb':root/'scripts/multiplayer/test-bootstrap.rb','runtime-preload.rb':root/'scripts/multiplayer/runtime-preload.rb','mainline_restore_game.rb':root/'tests/multiplayer/mainline_restore_game.rb'}.items():push(path,game+'/scripts/multiplayer/'+name)
        scenario=evidence/'android-scenario.json';scenario.write_text(json.dumps(dict(directory=private,username=username,cross_device=True)),encoding='utf-8');push(scenario,private+'/scenario.json')
        env=dict(KIF_MULTIPLAYER_PROFILE='mainline-android-restore',KIF_MULTIPLAYER_SAVE_DIR=private,KIF_MULTIPLAYER_SERVER='http://10.0.2.2:'+str(port),KIF_MULTIPLAYER_SCENARIO=private+'/scenario.json')
        wrapper=evidence/'android-restore-entry.rb';wrapper.write_text('\n'.join('ENV['+json.dumps(key)+']='+json.dumps(value) for key,value in env.items())+'\nload "kif_android_preload.rb"\nload "scripts/multiplayer/mainline_restore_game.rb"\n',encoding='utf-8');push(wrapper,game+'/android-game-smoke.rb')
        command('shell','am','start','-W','-n',app+'/.LauncherActivity','--ez','gameSmoke','true')
        deadline=time.monotonic()+300
        while time.monotonic()<deadline:
            passed=command('exec-out','run-as',app,'cat',private+'/mainline-restore-pass.json',check=False)
            if passed.startswith('{'):
                result=json.loads(passed);result.update(apk_sha256=sha,content=content,platform='Android11 x86_64 AVD with ARM64 translation')
                return result
            error=command('exec-out','run-as',app,'cat',private+'/mainline-error.log',check=False)
            if error and not error.startswith('cat:'):raise RuntimeError(error[-2400:])
            time.sleep(1)
        raise TimeoutError('Android managed-role restore')
    finally:
        for name in ('feature-smoke.log','runtime.log','mainline-error.log','managed-restore.png'):
            raw=subprocess.run(adb+['exec-out','run-as',app,'cat',private+'/'+name],capture_output=True,timeout=20)
            valid=raw.stdout.startswith(b'\x89PNG') if name.endswith('.png') else bool(raw.stdout) and not raw.stdout.startswith(b'cat:')
            if raw.returncode==0 and valid:(evidence/('android-'+name)).write_bytes(raw.stdout)
        command('shell','am','force-stop',app,check=False)
        for name in ('android-game-smoke.rb','mkxp.json'):
            if name in backups:command('shell','run-as',app,'cp',private+'/original-'+name,game+'/'+name,check=False)
            else:command('shell','run-as',app,'rm','-f',game+'/'+name,check=False)
