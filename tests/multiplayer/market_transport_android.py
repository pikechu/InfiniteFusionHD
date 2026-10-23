"""Small actual-APK repro for repeated fragmented local HTTP responses."""
from pathlib import Path
import argparse,json,secrets,threading,time
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
root=Path(__file__).resolve().parents[2]
from market_expansion_android import AndroidGuest
parser=argparse.ArgumentParser();parser.add_argument('--adb',type=Path,required=True);parser.add_argument('--serial',default='emulator-5558');args=parser.parse_args()
run=root/'temp/multiplayer'/('market-transport-'+secrets.token_hex(5));run.mkdir(parents=True);done=False
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        count=[0,1,20,80][int(self.path.rsplit('/',1)[1])]
        raw=json.dumps({'ok':True,'value':['汉字测试'*128 for _ in range(count)]},ensure_ascii=False).encode()
        self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)));self.end_headers();written=self.wfile.write(raw)
        assert written==len(raw)
    def do_POST(self):
        global done
        self.rfile.read(int(self.headers.get('Content-Length',0)));done=True
        raw=b'{"ok":true}';self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
    def log_message(self,*args):pass
server=ThreadingHTTPServer(('127.0.0.1',0),Handler);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start();android=None
try:
    android=AndroidGuest(root,args.adb,args.serial,server.server_port,run)
    android.push(root/'tests/multiplayer/market_transport_game.rb',android.game+'/scripts/multiplayer/market_expansion_game.rb')
    android.start();deadline=time.monotonic()+240
    while not done and time.monotonic()<deadline:
        error=android.error()
        if error:raise RuntimeError(error)
        time.sleep(1)
    assert done,'HTTP framing probe timed out'
    record=dict(passed=True,requests=80,payloads='Empty, 1, 20 and 80 strings containing exactly 512 Chinese characters each; exact response values and HTTP framing retained',android=android.metadata,directory=run.relative_to(root).as_posix(),scope='Actual APK over ADB reverse; emulator NAT comparison failed strict framing, no product validation bypass or deadline extension')
    (root/'docs/multiplayer-trading-evidence/market-expansion-transport.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('ANDROID_HTTP_STRESS_PASS',run)
finally:
    if android:android.close()
    server.shutdown();server.server_close();thread.join(5)
