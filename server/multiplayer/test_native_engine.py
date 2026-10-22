import json
from pathlib import Path
import secrets
import shutil
import unittest

from native_engine import NativeEngine,atomic_private,canonical


class NativeProtocolTests(unittest.TestCase):
    def setUp(self):
        self.base = Path(__file__).parent/'data/tests'
        self.root = self.base/('native_protocol_'+secrets.token_hex(8))
        runtime = self.root/'runtime'
        (runtime/'Data/Scripts').mkdir(parents=True)
        (runtime/'server/multiplayer').mkdir(parents=True)
        for name in ('Game.exe','Game.ini','Data/multiplayer-build.json'):
            (runtime/name).write_bytes(b'protocol fixture; never executed')
        self.engine = NativeEngine(runtime,self.root/'private')
        self.job_id = 'job_'+secrets.token_hex(16)
        self.directory = self.engine.directory(self.job_id)
        self.directory.mkdir()

    def tearDown(self):
        self.engine.close()
        assert self.root.resolve().parent==self.base.resolve() and not self.root.is_symlink()
        shutil.rmtree(self.root)

    def test_signed_unicode_and_uint32_roundtrip(self):
        payload = {'job_id':self.job_id,'nonce':'n'*32,'owner':'服务器角色','value':4294967295}
        path = self.directory/'result.json'
        atomic_private(path,canonical(self.engine.signed(payload)))
        self.assertEqual(self.engine.poll(self.job_id,'n'*32),('result',payload))

    def test_tampered_result_cannot_authorize_a_mutation(self):
        envelope = self.engine.signed({'job_id':self.job_id,'nonce':'n'*32,'level':5})
        envelope['payload']['level'] = 100
        path = self.directory/'result.json'
        atomic_private(path,canonical(envelope))
        with self.assertRaisesRegex(ValueError,'signature'):
            self.engine.poll(self.job_id,'n'*32)

    def test_wrong_job_nonce_rejects_a_valid_signature(self):
        atomic_private(self.directory/'result.json',canonical(self.engine.signed({'job_id':self.job_id,'nonce':'old'})))
        with self.assertRaisesRegex(ValueError,'different job'):
            self.engine.poll(self.job_id,'new')

    def test_job_ids_cannot_select_arbitrary_paths(self):
        for value in ('../owner','job_../owner','CON','job_'+'a'*31,'job_'+'g'*32):
            with self.assertRaises(ValueError):
                self.engine.directory(value)

    def test_command_retry_is_identical_or_rejected(self):
        action = {'action':'move','move_index':0}
        self.engine.command(self.job_id,'n'*32,0,action)
        self.engine.command(self.job_id,'n'*32,0,action)
        with self.assertRaisesRegex(ValueError,'reused'):
            self.engine.command(self.job_id,'n'*32,0,{'action':'move','move_index':1})

    def test_another_service_key_cannot_sign_current_results(self):
        other = NativeEngine(self.engine.game_root,self.root/'other-private')
        try:
            atomic_private(self.directory/'result.json',canonical(other.signed({'job_id':self.job_id,'nonce':'n'*32})))
            with self.assertRaisesRegex(ValueError,'signature'):
                self.engine.poll(self.job_id,'n'*32)
        finally:
            other.close()


if __name__=='__main__':
    unittest.main()
