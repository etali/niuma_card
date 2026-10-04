#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

import copy
import importlib.util
import io
import json
import pathlib
import os
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from unittest import mock

ROOT=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
spec=importlib.util.spec_from_file_location('manual_balance',ROOT/'tools/manual_balance.py')
mb=importlib.util.module_from_spec(spec);spec.loader.exec_module(mb)

class ManualBalanceTest(unittest.TestCase):
    def setUp(self): self.base=json.loads((ROOT/'data/cards.json').read_text())

    def test_project_identity_is_private_stable_and_checkout_specific(self):
        identity=mb.project_id()
        self.assertEqual(identity,mb.project_id())
        self.assertNotIn(str(ROOT),identity)
        self.assertNotIn(str(pathlib.Path.home()),identity)
        self.assertTrue(mb.same_project(str(ROOT))) # 旧服务仍提示退出重启。
        self.assertTrue(mb.same_project(identity))
        with mock.patch.object(mb,'ROOT',ROOT/'another-checkout'):
            self.assertNotEqual(identity,mb.project_id())
            self.assertFalse(mb.same_project(identity))

    def test_profile_request_uses_readable_relative_paths(self):
        app=mb.Workbench.__new__(mb.Workbench);app.godot='godot-fixture'
        def evaluate(command,**kwargs):
            self.assertEqual(kwargs['cwd'],str(ROOT))
            self.assertEqual(command[command.index('--path')+1],'.')
            request_path=pathlib.Path(command[-1])
            self.assertFalse(request_path.is_absolute())
            request=mb.read_json(ROOT/request_path)
            self.assertFalse(pathlib.Path(request['output_path']).is_absolute())
            mb.atomic_json(ROOT/request['output_path'],{'schema':[],'parameters':{}})
            return subprocess.CompletedProcess(command,0,'','')
        with mock.patch.object(mb.subprocess,'run',side_effect=evaluate):
            self.assertEqual(app.profile(1.0),{'schema':[],'parameters':{}})
    def test_old_annotations_do_not_invalidate_saved_configs(self):
        legacy=copy.deepcopy(self.base)
        legacy['_comment']='旧卡表说明：同名传说材料'
        legacy['_upgrade']['_note']='旧升级路线说明'
        legacy['_game']['_note']='旧全局规则说明'
        legacy['yunketang']['output_n']+=1
        before=copy.deepcopy(legacy)
        self.assertEqual(mb.validate_cards(legacy,self.base),before)
        self.assertEqual(legacy,before)
        for key in ['_comment','_upgrade','_game']:
            bad=copy.deepcopy(legacy)
            if key=='_comment': bad[key]=7
            else: bad[key]['_note']={'not':'text'}
            with self.subTest(key=key),self.assertRaises(ValueError):mb.validate_cards(bad,self.base)
        for field in ['_note','dup_key','routes']:
            bad=copy.deepcopy(legacy);del bad['_upgrade'][field]
            with self.subTest(field=field),self.assertRaises(ValueError):mb.validate_cards(bad,self.base)
        for section,field,value in [('_upgrade','dup_key','different'),('_upgrade','extra_rule',True),
                                    ('dujiaoshou','upgrade_dup_n',99),('_game','win_cash',999)]:
            bad=copy.deepcopy(legacy);bad[section][field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):mb.validate_cards(bad,self.base)
        bad=copy.deepcopy(legacy);bad['_upgrade']['routes'][0]['per']=99
        with self.assertRaises(ValueError):mb.validate_cards(bad,self.base)

    def test_whitelist_and_fields(self):
        self.assertEqual(mb.validate_cards(self.base,self.base),self.base)
        named=copy.deepcopy(self.base);named['_name']='内部平衡版'
        self.assertEqual(mb.validate_cards(named,self.base),self.base)
        self.assertGreater(len(mb.mutable_fields(self.base)),20)
        bad=copy.deepcopy(self.base);bad['yunketang']['name']='英文名'
        with self.assertRaises(ValueError):mb.validate_cards(bad,self.base)
        bad=copy.deepcopy(self.base);bad['yunketang']['price']=1.5
        with self.assertRaises(ValueError):mb.validate_cards(bad,self.base)
    def test_options_and_deterministic_fingerprint(self):
        schema=[{'key':'x','kind':'int','min':1,'max':4,'step':1,'label':'测试'}]
        o=copy.deepcopy(mb.DEFAULT_OPTIONS);o['ai_parameters']={'x':2}
        self.assertEqual(mb.validate_options(o,schema)['pairs'],5)
        o['ai_parameters']['x']=2.5
        with self.assertRaises(ValueError):mb.validate_options(o,schema)
        self.assertEqual(mb.digest(self.base),mb.digest(copy.deepcopy(self.base)))

    def test_simulation_budget_has_only_numeric_safety_limits(self):
        options=copy.deepcopy(mb.DEFAULT_OPTIONS)
        options.update(pairs=5001,max_rounds=10000,seed_start=2147483648)
        self.assertEqual(mb.validate_options(options,[]),options)
        for key in ('pairs','max_rounds','seed_start'):
            for value in (0,-1,1.5,float('inf'),float('nan'),True,'1000',mb.MAX_SAFE_INTEGER+1):
                changed={**options,key:value}
                with self.subTest(key=key,value=value),self.assertRaises(ValueError):
                    mb.validate_options(changed,[])
        options.update(pairs=1,seed_start=mb.MAX_SAFE_INTEGER)
        self.assertEqual(mb.validate_options(options,[]),options)
        with self.assertRaisesRegex(ValueError,'最后一个种子'):
            mb.validate_options({**options,'pairs':2},[])
        options.update(pairs=mb.MAX_SAFE_INTEGER//2,seed_start=1)
        self.assertEqual(mb.validate_options(options,[]),options)
        with self.assertRaisesRegex(ValueError,'总局数'):
            mb.validate_options({**options,'pairs':options['pairs']+1},[])

    def test_new_requests_use_ai_and_reject_legacy_model_names(self):
        self.assertEqual(mb.DEFAULT_OPTIONS['model'],'ai')
        self.assertEqual(mb.validate_options(copy.deepcopy(mb.DEFAULT_OPTIONS),[])['model'],'ai')
        for model in ['v1','v2','unknown']:
            options=copy.deepcopy(mb.DEFAULT_OPTIONS);options['model']=model
            with self.subTest(model=model),self.assertRaisesRegex(ValueError,'AI实现或强度无效'):
                mb.validate_options(options,[])

    def test_engine_fingerprint_tracks_victory_classification(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=pathlib.Path(tmp)
            for relative in ['engine/state.gd','tools/ai_duel.gd','tools/ai_duel_report.gd','tools/ai_decision_stats.gd','tools/eval_report.gd','tools/balance/scoring.gd',
                             'tools/balance/logic.gd','tools/balance/victory.gd','data/ai.json',
                             'data/card_config_schema.json']:
                path=root/relative
                path.parent.mkdir(parents=True,exist_ok=True)
                path.write_text('fixture')
            with mock.patch.object(mb,'ROOT',root),mock.patch.object(mb,'WEB',root/'tools/balance'):
                before=mb.engine_fingerprint()
                self.assertEqual(before,mb.engine_fingerprint())
                (root/'tools/balance/victory.gd').write_text('changed terminal-event classification')
                self.assertNotEqual(before,mb.engine_fingerprint())

    def test_schema_change_invalidates_workbench_and_simulation_versions(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=pathlib.Path(tmp)
            for relative in ['tools/ai_duel.gd','tools/ai_duel_report.gd','tools/ai_decision_stats.gd','tools/eval_report.gd','data/ai.json','data/card_config_schema.json',
                             'tools/balance/report.html','tools/balance/report.js','tools/balance/report.css']:
                path=root/relative
                path.parent.mkdir(parents=True,exist_ok=True)
                path.write_text('fixture')
            with mock.patch.object(mb,'ROOT',root),mock.patch.object(mb,'WEB',root/'tools/balance'):
                source,engine=mb.source_version(),mb.engine_fingerprint()
                (root/'data/card_config_schema.json').write_text('changed validation contract')
                self.assertNotEqual(source,mb.source_version())
                self.assertNotEqual(engine,mb.engine_fingerprint())

    def test_pawn_overrides_and_editable_metadata(self):
        pawn_fields={f['card']:f for f in mb.mutable_fields(self.base) if f['field']=='pawn'}
        non_resources={key for key,card in self.base.items()
                       if not key.startswith('_') and card.get('kind')!='unit'}
        self.assertEqual(set(pawn_fields),non_resources)
        for key,field in pawn_fields.items():
            self.assertEqual(field['min'],0)
            self.assertEqual(field['label'],'出售价格')
            self.assertEqual(field['optional'],'pawn' not in self.base[key])
        for value in [0,17,1000]:
            cards=copy.deepcopy(self.base)
            cards['yunketang']['pawn']=value
            cards['dujiaoshou']['pawn']=value
            self.assertEqual(mb.validate_cards(cards,self.base),cards)
        cards=copy.deepcopy(self.base);cards['yunketang']['pawn']=10
        del cards['yunketang']['pawn']
        self.assertEqual(mb.validate_cards(cards,self.base),self.base)
        for value in [-1,0.5,1001,2147483647,2147483648,True,None,'2']:
            cards=copy.deepcopy(self.base);cards['yunketang']['pawn']=value
            with self.subTest(value=value),self.assertRaisesRegex(ValueError,'出售价格.*非负整数'):
                mb.validate_cards(cards,self.base)
        cards=copy.deepcopy(self.base);del cards['dujiaoshou']['pawn']
        with self.assertRaisesRegex(ValueError,'字段集合改变'): mb.validate_cards(cards,self.base)
        resource=next(key for key,card in self.base.items() if isinstance(card,dict) and card.get('kind')=='unit')
        cards=copy.deepcopy(self.base);cards[resource]['pawn']=3
        with self.assertRaisesRegex(ValueError,'字段集合改变'): mb.validate_cards(cards,self.base)
        cards=copy.deepcopy(self.base);cards['yunketang']['price']=0
        with self.assertRaisesRegex(ValueError,'购买价格.*正整数'): mb.validate_cards(cards,self.base)


class WorkbenchStorageTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='配置格式迁移 ')
        self.store=pathlib.Path(self.tmp.name)
        self.base=json.loads((ROOT/'data/cards.json').read_text())
        self.apps=[]

    def tearDown(self):
        for app in self.apps: app._file_lock.close()
        self.tmp.cleanup()

    def open_app(self):
        with mock.patch.object(mb.Workbench,'profile',return_value={'schema':[],'parameters':{}}):
            app=mb.Workbench(self.store,'unused-godot')
        self.apps.append(app)
        return app

    def legacy(self):
        cards=copy.deepcopy(self.base)
        cards['yunketang']['output_n']+=1
        cards['_comment']='历史说明必须原样保留'
        cards['_game']['win_cash']+=1 # 历史固定规则可以不同，迁移/展示不按当前版本强制校验。
        return {'id':'20261001-123456-abcdef12','name':'历史配置 中文','created':1720000000.25,
                'hash':mb.digest(cards),'cards':cards,'imported_name':'原始导入名称',
                'source_file':'带 空格/card.json','custom_metadata':{'nested':['preserved',3]}}

    def test_save_is_directly_usable_card_table_and_restart_reassembles_record(self):
        app=self.open_app()
        cards=copy.deepcopy(self.base);cards['yunketang']['pawn']=0
        saved=app.save({'source_id':'default','name':'新纯卡表','cards':cards,
                        'imported_name':'导入名称','source_file':'原始 cards.json'})
        cid=saved['id']
        path=self.store/'configs'/(cid+'.json')
        self.assertEqual(mb.read_json(path),cards)
        self.assertEqual(mb.validate_cards(mb.read_json(path),self.base),cards)
        self.assertNotIn('cards',mb.read_json(path))
        self.assertEqual(mb.read_json(self.store/'config_meta'/(cid+'.json')),
                         {k:v for k,v in saved.items() if k!='cards'})
        app.notes({'id':cid,'text':'与配置关联的备注'})
        app._file_lock.close()
        restarted=self.open_app()
        loaded=restarted.config(cid)
        self.assertEqual({k:v for k,v in loaded.items() if k!='notes'},saved)
        self.assertEqual(loaded['notes']['text'],'与配置关联的备注')
        self.assertTrue(restarted.save({'source_id':cid,'name':saved['name'],'cards':cards})['reused'])
        self.assertEqual(len(list((self.store/'configs').glob('*.json'))),1)

    def test_legacy_migration_preserves_all_metadata_cards_notes_and_runs(self):
        legacy=self.legacy();cid=legacy['id']
        path=self.store/'configs'/(cid+'.json')
        mb.atomic_json(path,legacy)
        note_path=self.store/'notes'/(cid+'.json')
        mb.atomic_json(note_path,{'text':'旧配置备注','updated':123.5})
        rid='20261001-223456-abcdef12'
        run_path=self.store/'runs'/rid/'run.json'
        run={'id':rid,'config_id':cid,'name':legacy['name'],'status':'complete','cards':legacy['cards']}
        mb.atomic_json(run_path,run)
        result_path=run_path.with_name('result.json')
        mb.atomic_json(result_path,{'status':'complete','games':[{'seed':1001}],'metrics':{'Q1':{'value':50}}})
        preserved={p:p.read_bytes() for p in [note_path,run_path,result_path]}
        app=self.open_app()
        self.assertEqual(mb.read_json(path),legacy['cards'])
        self.assertEqual(mb.read_json(self.store/'config_meta'/path.name),
                         {k:v for k,v in legacy.items() if k!='cards'})
        loaded=app.config(cid)
        self.assertEqual({k:v for k,v in loaded.items() if k!='notes'},legacy)
        self.assertEqual(loaded['notes']['text'],'旧配置备注')
        self.assertEqual(app.runs()[0]['config_id'],cid)
        for p,content in preserved.items(): self.assertEqual(p.read_bytes(),content)
        migrated={p:p.read_bytes() for p in [path,self.store/'config_meta'/path.name]}
        app._file_lock.close()
        reopened=self.open_app()
        self.assertEqual(reopened.config(cid),loaded)
        for p,content in migrated.items(): self.assertEqual(p.read_bytes(),content)

    def test_migration_interruption_can_retry_at_both_atomic_write_boundaries(self):
        legacy=self.legacy();path=self.store/'configs'/(legacy['id']+'.json')
        meta_path=self.store/'config_meta'/path.name
        real_atomic=mb.atomic_json
        for stage in ['metadata','cards','cards-published']:
            with self.subTest(stage=stage):
                mb.atomic_json(path,legacy)
                if meta_path.exists(): meta_path.unlink()
                def interrupt(target,value):
                    if stage=='metadata' and pathlib.Path(target)==meta_path: raise OSError('模拟元信息写入失败')
                    if pathlib.Path(target)==path:
                        if stage=='cards': raise OSError('模拟元信息完成后的中断')
                        if stage=='cards-published':
                            real_atomic(target,value)
                            raise OSError('模拟纯卡表发布后的中断')
                    real_atomic(target,value)
                with mock.patch.object(mb,'atomic_json',side_effect=interrupt):
                    with self.assertRaisesRegex(ValueError,'读取或迁移配置失败：.*'+path.name):
                        self.open_app()
                self.assertEqual(mb.read_json(path),legacy['cards'] if stage=='cards-published' else legacy)
                if stage!='metadata':
                    self.assertEqual(mb.read_json(meta_path),{k:v for k,v in legacy.items() if k!='cards'})
                # 同一个目录马上重启也能成功，证明失败路径释放了 flock。
                app=self.open_app()
                self.assertEqual(mb.read_json(path),legacy['cards'])
                self.assertEqual({k:v for k,v in app.config(legacy['id']).items() if k!='notes'},legacy)
                app._file_lock.close()

    def test_bad_or_missing_metadata_reports_file_and_does_not_silently_drop_config(self):
        path=self.store/'configs'/'20261001-123456-abcdef12.json'
        meta_path=self.store/'config_meta'/path.name
        for content,metadata in [('{broken',None),(json.dumps(self.base),None),
                                 ('{}',{'id':path.stem,'name':'损坏的卡表'}),
                                 (json.dumps(self.base),{'id':'wrong','name':'wrong'}),
                                 (json.dumps(self.base),{'id':path.stem})]:
            with self.subTest(metadata=metadata):
                path.parent.mkdir(exist_ok=True)
                path.write_text(content)
                if meta_path.exists():meta_path.unlink()
                if metadata is not None:mb.atomic_json(meta_path,metadata)
                with self.assertRaisesRegex(ValueError,'读取或迁移配置失败：.*'+path.name):self.open_app()
                self.assertEqual(path.read_text(),content)
        mb.atomic_json(meta_path,{'id':path.stem,'name':'修复后的元信息'})
        self.assertEqual(self.open_app().config(path.stem)['cards'],self.base)

    def test_migration_requires_store_lock(self):
        self.open_app()
        legacy=self.legacy()
        path=self.store/'configs'/(legacy['id']+'.json')
        mb.atomic_json(path,legacy)
        with self.assertRaisesRegex(ValueError,'已有工作台运行'):self.open_app()
        self.assertEqual(mb.read_json(path),legacy)
        self.assertFalse((self.store/'config_meta'/path.name).exists())

    def test_new_save_failure_does_not_publish_partial_config(self):
        app=self.open_app()
        cards=copy.deepcopy(self.base);cards['yunketang']['price']+=1
        real_atomic=mb.atomic_json
        def interrupt(path,value):
            if pathlib.Path(path).parent.name=='configs':raise OSError('模拟卡表保存失败')
            real_atomic(path,value)
        with mock.patch.object(mb,'atomic_json',side_effect=interrupt),self.assertRaises(OSError):
            app.save({'source_id':'default','name':'未发布配置','cards':cards})
        self.assertEqual([c['id'] for c in app.configs()],['default'])
        app._file_lock.close()
        app=self.open_app()
        self.assertEqual([c['id'] for c in app.configs()],['default'])
        saved=app.save({'source_id':'default','name':'未发布配置','cards':cards})
        self.assertEqual(app.config(saved['id'])['cards'],cards)


class WorkbenchPlayTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='试玩 空格 ')
        self.base=json.loads((ROOT/'data/cards.json').read_text())
        with mock.patch.object(mb.Workbench,'profile',return_value={'schema':[],'parameters':{}}):
            self.app=mb.Workbench(pathlib.Path(self.tmp.name)/'配置 存档','/应用 程序/Godot')
        cards=copy.deepcopy(self.base);cards['yunketang']['pawn']=0
        self.config=self.app.save({'source_id':'default','name':'出售为零 测试','cards':cards})
    def tearDown(self):
        self.app._file_lock.close()
        self.tmp.cleanup()

    def filtered_launcher(self, launch_game):
        """模拟两进程管道；真实跨服务退出的管道由独立行为用例覆盖。"""
        pending={}
        def launch(command,**kwargs):
            if command[0]==self.app.godot:
                self.assertEqual(kwargs['stdout'],subprocess.PIPE)
                stream=io.StringIO()
                proc=launch_game(command,**{**kwargs,'stdout':stream})
                proc.stdout=mock.Mock()
                pending.update(stream=stream,proc=proc)
                return proc
            self.assertEqual(command[:2],[sys.executable,'-u'])
            self.assertEqual(pathlib.Path(command[2]).name,'project_paths.py')
            self.assertIs(kwargs['stdin'],pending['proc'].stdout)
            self.assertTrue(kwargs['start_new_session'])
            kwargs['stdout'].write(mb.redact_paths(pending['stream'].getvalue(),ROOT))
            kwargs['stdout'].flush()
            return mock.Mock(poll=mock.Mock(return_value=None),wait=mock.Mock(return_value=0))
        return launch

    def test_play_uses_independent_snapshot_and_waits_for_readiness(self):
        before=self.app.configs()
        commands=[]
        def launch(command,**kwargs):
            commands.append(command)
            self.assertIs(kwargs['shell'],False)
            self.assertTrue(kwargs['start_new_session'])
            self.assertEqual(kwargs['cwd'],str(ROOT))
            self.assertEqual(command[:4],[self.app.godot,'--path','.','--'])
            self.assertEqual(len(command),5)
            snapshot=pathlib.Path(command[-1].removeprefix('--cards-config='))
            self.assertFalse(snapshot.is_absolute())
            snapshot=(ROOT/snapshot).resolve()
            self.assertIn('试玩 空格 ',str(snapshot))
            self.assertEqual(json.loads(snapshot.read_text()),self.config['cards'])
            kwargs['stdout'].write('CARDS_CONFIG_READY: '+str(snapshot)+'\n')
            kwargs['stdout'].flush()
            return mock.Mock(pid=1234,poll=mock.Mock(return_value=None),wait=mock.Mock(return_value=0))
        with mock.patch.object(mb.subprocess,'Popen',side_effect=self.filtered_launcher(launch)):
            first=self.app.play({'config_id':self.config['id']})
            second=self.app.play({'config_id':self.config['id']})
        self.assertTrue(first['started'])
        self.assertEqual(first['config_id'],self.config['id'])
        self.assertEqual(first['name'],'出售为零 测试')
        self.assertEqual(first['pid'],1234)
        self.assertNotEqual(first['cards_path'],second['cards_path'])
        self.assertEqual(self.app.configs(),before)
        self.assertEqual(self.app.runs(),[])
        self.assertEqual(self.app.run_overview()['active_run_ids'],[])
        self.assertEqual(json.loads((ROOT/'data/cards.json').read_text()),self.base)
        self.assertEqual(len(commands),2)
        for key in ('cards_path','log_path'):
            self.assertFalse(pathlib.Path(first[key]).is_absolute())

    def test_play_filters_ready_marker_without_breaking_handshake(self):
        class ImmediateThread:
            def __init__(self,target,**_): self.target=target
            def start(self): self.target()
        def launch(command,**kwargs):
            snapshot=(ROOT/command[-1].removeprefix('--cards-config=')).resolve()
            # 引擎可输出绝对路径；过滤后的标记仍能完成同一配置的握手。
            kwargs['stdout'].write('CARDS_CONFIG_READY: '+str(snapshot)+'\n'+str(ROOT/'scenes/main.gd')+'\n')
            kwargs['stdout'].flush()
            return mock.Mock(pid=1234,poll=mock.Mock(return_value=None),wait=mock.Mock(return_value=0))
        with mock.patch.object(mb.subprocess,'Popen',side_effect=self.filtered_launcher(launch)),mock.patch.object(mb.threading,'Thread',ImmediateThread):
            result=self.app.play({'config_id':self.config['id']})
        self.assertTrue(result['started'])
        log=next((self.app.store/'playtests').glob('*/godot.log')).read_text()
        self.assertNotIn(str(ROOT),log)
        self.assertIn('./scenes/main.gd',log)

    def test_play_spawn_failure_reports_log_and_does_not_create_run(self):
        with mock.patch.object(mb.subprocess,'Popen',side_effect=FileNotFoundError('测试执行文件不存在：'+str(ROOT/'missing-godot'))):
            with self.assertRaisesRegex(ValueError,'无法启动试玩游戏.*日志：.*godot.log') as error:
                self.app.play({'config_id':self.config['id']})
        self.assertNotIn(str(ROOT),str(error.exception))
        self.assertEqual(self.app.runs(),[])
        logs=list((self.app.store/'playtests').glob('*/godot.log'))
        self.assertEqual(len(logs),1)
        self.assertIn('测试执行文件不存在',logs[0].read_text())
        self.assertNotIn(str(ROOT),logs[0].read_text())

    def test_play_filter_spawn_failure_reaps_game_and_closes_pipe(self):
        proc=mock.Mock(poll=mock.Mock(return_value=None),wait=mock.Mock(return_value=0))
        with mock.patch.object(mb.subprocess,'Popen',side_effect=[proc,FileNotFoundError(str(ROOT/'missing-filter'))]):
            with self.assertRaisesRegex(ValueError,'无法启动试玩游戏') as error:
                self.app.play({'config_id':self.config['id']})
        proc.terminate.assert_called_once()
        proc.wait.assert_called_once()
        proc.stdout.close.assert_called_once()
        self.assertNotIn(str(ROOT),str(error.exception))

    def test_play_log_stays_private_after_workbench_exits(self):
        folder=pathlib.Path(self.tmp.name)
        game=folder/'independent-game'
        release=folder/'continue'
        result_path=folder/'started.json'
        game.write_text('#!/usr/bin/env python3\n'+"""
import pathlib,sys,time
cards=pathlib.Path(sys.argv[-1].removeprefix('--cards-config='))
assert cards.is_file()
print('CARDS_CONFIG_READY: '+str(cards.resolve()),flush=True)
while not pathlib.Path(__file__).with_name('continue').exists(): time.sleep(.02)
print('LATE_PROJECT: '+str(pathlib.Path.cwd()/'late-event.gd'),flush=True)
print('LATE_HOME: '+str(pathlib.Path.home()/'late-event.txt'),flush=True)
""")
        game.chmod(0o755)
        service_code="""
import json,pathlib,sys
sys.path.insert(0,str(pathlib.Path(sys.argv[1])/'tools'))
import manual_balance as mb
mb.Workbench.profile=lambda self,strength: {'schema':[],'parameters':{}}
spawn=mb.subprocess.Popen
filters=[]
def observe(command,**kwargs):
    child=spawn(command,**kwargs)
    if command[0]==sys.executable: filters.append(child.pid)
    return child
mb.subprocess.Popen=observe
app=mb.Workbench(pathlib.Path(sys.argv[2]),sys.argv[3])
result=app.play({'config_id':'default'})
result['filter_pid']=filters[0]
app.close()
pathlib.Path(sys.argv[4]).write_text(json.dumps(result))
"""
        service=subprocess.Popen([sys.executable,'-c',service_code,str(ROOT),str(folder/'independent-store'),
                                  str(game),str(result_path)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        result=None
        try:
            output,_=service.communicate(timeout=10)
            self.assertEqual(service.returncode,0,output)
            result=mb.read_json(result_path)
            os.kill(result['pid'],0) # 工作台已退出，试玩仍然存活。
            release.touch()
            log=next((folder/'independent-store/playtests').glob('*/godot.log'))
            deadline=time.monotonic()+5
            while time.monotonic()<deadline and 'LATE_HOME:' not in log.read_text(): time.sleep(.02)
            text=log.read_text()
            self.assertIn('LATE_PROJECT: ./late-event.gd',text)
            self.assertIn('LATE_HOME: ~/late-event.txt',text)
            self.assertNotIn(str(ROOT),text)
            self.assertNotIn(str(pathlib.Path.home()),text)
        finally:
            release.touch()
            if service.poll() is None: service.terminate();service.wait(timeout=3)
            if service.stdout: service.stdout.close()
            if result:
                for key in ('pid','filter_pid'):
                    deadline=time.monotonic()+5
                    while time.monotonic()<deadline:
                        try: os.kill(result[key],0)
                        except ProcessLookupError: break
                        time.sleep(.02)
                    else:
                        os.kill(result[key],signal.SIGTERM)
                        self.fail('试玩或过滤器未随输出结束自动退出：'+key)

    def test_play_requires_ready_marker_and_running_process(self):
        for mode in ['exited','no-marker','wrong-marker','ready-then-exit']:
            with self.subTest(mode=mode):
                proc=mock.Mock(pid=1234,poll=mock.Mock(return_value=1 if mode=='exited' else None))
                if mode=='ready-then-exit': proc.poll.side_effect=[None,1,1]
                def launch(command,**kwargs):
                    if mode=='wrong-marker':
                        kwargs['stdout'].write('CARDS_CONFIG_READY: /不是此次配置/cards.json\n')
                        kwargs['stdout'].flush()
                    elif mode=='ready-then-exit':
                        kwargs['stdout'].write('CARDS_CONFIG_READY: '+command[-1].removeprefix('--cards-config=')+'\n')
                        kwargs['stdout'].flush()
                    return proc
                with mock.patch.object(mb.subprocess,'Popen',side_effect=self.filtered_launcher(launch)),mock.patch.object(mb,'PLAY_START_TIMEOUT',0):
                    with self.assertRaisesRegex(ValueError,'日志：.*godot.log'):
                        self.app.play({'config_id':self.config['id']})
                if mode in ('no-marker','wrong-marker'): proc.terminate.assert_called_once()
        self.assertEqual(self.app.runs(),[])

    def test_play_rejects_missing_or_invalid_saved_config_before_spawn(self):
        with mock.patch.object(mb.subprocess,'Popen') as spawn:
            with self.assertRaisesRegex(ValueError,'配置不存在'):
                self.app.play({'config_id':'missing'})
            path=self.app.store/'configs'/(self.config['id']+'.json')
            invalid=json.loads(path.read_text());invalid['yunketang']['pawn']=-1
            mb.atomic_json(path,invalid)
            with self.assertRaisesRegex(ValueError,'出售价格'):
                self.app.play({'config_id':self.config['id']})
            spawn.assert_not_called()
        self.assertFalse((self.app.store/'playtests').exists())

class WorkbenchParallelTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='parallel-workbench-')
        self.store=pathlib.Path(self.tmp.name)/'store'
        self.fake=pathlib.Path(self.tmp.name)/'godot-fixture'
        self.fake.write_text('#!/usr/bin/env python3\n'+"""
import json,os,pathlib,sys,time
request=json.loads(pathlib.Path(sys.argv[-1]).read_text())
output=pathlib.Path(request['output_path']);folder=output.parent
def write(path,value):
    tmp=path.with_suffix('.tmp')
    tmp.write_text(json.dumps(value));tmp.replace(path)
if request.get('action')=='metadata':
    write(output,{'schema':[],'parameters':{}});sys.exit(0)
progress=pathlib.Path(request['progress_path'])
if request['options']['seed_start']==2002:
    detail='fixture process failed: '+str(pathlib.Path.cwd()/'scenes/main.gd')
    pathlib.Path(sys.argv[sys.argv.index('--log-file')+1]).write_text(detail)
    print(detail,flush=True);sys.exit(7)
count=0
while not (folder/'release').exists():
    count+=1;write(progress,{'completed':count,'pid':os.getpid()})
    time.sleep(.03)
write(output,{'status':'complete','games':[]})
""")
        self.fake.chmod(0o755)
        with mock.patch.object(mb.Workbench,'profile',return_value={'schema':[],'parameters':{}}):
            self.app=mb.Workbench(self.store,self.fake)

    def tearDown(self):
        self.app.close()
        self.tmp.cleanup()

    def start(self,seed=1001):
        options=copy.deepcopy(mb.DEFAULT_OPTIONS);options['seed_start']=seed
        return self.app.start({'config_id':'default','options':options})

    def until(self,predicate,timeout=5):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            value=predicate()
            if value:return value
            time.sleep(.02)
        self.fail('condition timed out: '+str(self.app.run_overview()))

    def running(self,rid):
        return self.until(lambda:self.app.run(rid) if self.app.run(rid).get('progress',{}).get('completed',0)>0 else None)

    def finished(self,rid):
        return self.until(lambda:self.app.run(rid) if self.app.run(rid)['status'] not in ('queued','running','stopping') else None)

    def release(self,rid):
        (self.store/'runs'/rid/'release').touch()

    def test_duel_and_evaluation_stop_independently_and_capture_manual_parameters(self):
        spec={'key':'budget','label':'预算','min':1,'max':100,'step':1,'kind':'int'}
        self.app.schema=[spec]
        raw={'pairs':5001,'max_rounds':1,'seed_start':1,
             'a':{'strength':1,'ai_parameters':{'budget':50}},'b':{'strength':0,'ai_parameters':{'budget':1}}}
        with mock.patch.object(self.app,'profile',side_effect=AssertionError('提交时不重新映射手动参数')):
            duel=self.app.start_duel({'config_id':'default','options':raw})
        raw['a']['ai_parameters']['budget']=90
        self.assertEqual(duel['options']['a']['ai_parameters']['budget'],50)
        self.assertEqual(duel['options']['b']['ai_parameters']['budget'],1)
        self.app.schema=[]
        evaluation=self.start()
        self.running(duel['id']);self.running(evaluation['id'])
        self.app.stop({'run_id':duel['id']})
        self.assertEqual(self.finished(duel['id'])['status'],'cancelled')
        self.assertEqual(self.app.run(evaluation['id'])['status'],'running')
        self.release(evaluation['id'])
        self.assertEqual(self.finished(evaluation['id'])['status'],'complete')

    def test_real_processes_overlap_and_stop_is_scoped_to_run(self):
        a,b=self.start(),self.start(1002)
        ar,br=self.running(a['id']),self.running(b['id'])
        for key in ('cards_path','output_path','progress_path'):
            path=mb.read_json(self.store/'runs'/a['id']/'request.json')[key]
            self.assertFalse(pathlib.Path(path).is_absolute())
            self.assertEqual((ROOT/path).resolve().parent,(self.store/'runs'/a['id']).resolve())
        self.assertNotEqual(ar['pid'],br['pid'])
        os.kill(ar['pid'],0);os.kill(br['pid'],0) # 两个真实子进程此刻同时存活。
        self.assertEqual(set(self.app.run_overview()['active_run_ids']),{a['id'],b['id']})
        for body in [{},{'run_id':None},{'run_id':'../../x'},{'run_id':'ffffffff'}]:
            with self.assertRaises(ValueError):self.app.stop(body)
        self.assertEqual(set(self.app.jobs),{a['id'],b['id']})
        before=br['progress']['completed']
        first=self.app.stop({'run_id':a['id']})
        self.assertTrue(first['stopping'])
        self.assertEqual(first['run_id'],a['id'])
        self.app.stop({'run_id':a['id']}) # 取消重复到达也不能影响 B。
        ended=self.finished(a['id'])
        self.assertEqual(ended['status'],'cancelled')
        self.assertGreater(ended['progress']['completed'],0)
        self.assertEqual(self.app.run_overview()['active_run_ids'],[b['id']])
        self.until(lambda:self.app.run(b['id'])['progress']['completed']>before)
        os.kill(br['pid'],0)
        self.assertEqual(self.app.stop({'run_id':a['id']})['status'],'cancelled')
        self.assertFalse(self.app.stop({'run_id':a['id']})['stopping'])
        self.release(b['id'])
        self.assertEqual(self.finished(b['id'])['status'],'complete')
        self.assertEqual(self.app.run_overview()['active_run_ids'],[])

    def test_cancel_before_spawn_never_starts_a_process(self):
        with mock.patch.object(mb.subprocess,'Popen') as spawn:
            with self.app.lock:
                run=self.start()
                self.assertEqual(self.app.stop({'run_id':run['id']})['status'],'stopping')
                self.app.stop({'run_id':run['id']})
            self.assertEqual(self.finished(run['id'])['status'],'cancelled')
            spawn.assert_not_called()
        self.assertEqual(self.app.jobs,{})

    def test_process_and_thread_failures_do_not_cancel_another_job(self):
        good=self.start();self.running(good['id'])
        with mock.patch.object(mb.subprocess,'Popen',side_effect=FileNotFoundError('spawn fixture failure')):
            bad=self.start()
            self.assertIn('spawn fixture failure',self.finished(bad['id'])['error'])
        exited=self.start(2002)
        failure=self.finished(exited['id'])
        self.assertEqual(failure['status'],'error')
        self.assertIn('fixture process failed',failure['error'])
        self.assertNotIn(str(ROOT),failure['error'])
        for name in ('godot.log','engine.log','run.json'):
            self.assertNotIn(str(ROOT),(self.store/'runs'/exited['id']/name).read_text())
        with mock.patch.object(mb.threading.Thread,'start',side_effect=RuntimeError('thread quota')):
            with self.assertRaisesRegex(ValueError,'无法启动模拟：thread quota'):self.start()
        self.assertEqual(self.app.run_overview()['active_run_ids'],[good['id']])
        errors=[r for r in self.app.runs() if r['status']=='error']
        self.assertEqual(len(errors),3)
        self.release(good['id'])
        self.assertEqual(self.finished(good['id'])['status'],'complete')

    def test_stop_after_process_exit_preserves_success_before_worker_cleanup(self):
        run=self.start();self.running(run['id'])
        with self.app.lock:
            proc=self.app.jobs[run['id']]['proc']
            self.release(run['id'])
            self.until(lambda:proc.poll() is not None)
            stopped=self.app.stop({'run_id':run['id']})
            self.assertEqual(stopped,{'stopping':False,'run_id':run['id'],'status':'complete'})
            path=self.store/'runs'/run['id']/'run.json'
            before=path.read_bytes()
        self.app.stop({'run_id':run['id']})
        self.assertEqual(path.read_bytes(),before)
        self.assertEqual(self.app.jobs,{})

    def test_service_signals_cancel_and_reap_all_jobs(self):
        import socket
        for signum in [signal.SIGINT,signal.SIGTERM,signal.SIGHUP]:
            with self.subTest(signum=signum):
                store=pathlib.Path(self.tmp.name)/('service-'+str(signum))
                with socket.socket() as sock:
                    sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
                server=subprocess.Popen(['/usr/bin/python3',str(ROOT/'tools/manual_balance.py'),
                                         '--port',str(port),'--store',str(store),'--godot',str(self.fake)],
                                        stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
                url=f'http://127.0.0.1:{port}/'
                pids=[]
                try:
                    deadline=time.monotonic()+5
                    while True:
                        try:
                            with urllib.request.urlopen(url+'api/bootstrap',timeout=.2) as response:
                                bootstrap=json.load(response)
                            break
                        except OSError:
                            if server.poll() is not None or time.monotonic()>deadline:
                                self.fail('fixture server failed to start')
                            time.sleep(.03)
                    headers={'Content-Type':'application/json','X-Balance-Token':bootstrap['token']}
                    runs=[]
                    for _ in range(2):
                        body={'config_id':'default','options':copy.deepcopy(mb.DEFAULT_OPTIONS)}
                        request=urllib.request.Request(url+'api/run',data=json.dumps(body).encode(),headers=headers)
                        with urllib.request.urlopen(request,timeout=2) as response:runs.append(json.load(response))
                    for run in runs:
                        path=store/'runs'/run['id']/'run.json'
                        deadline=time.monotonic()+5
                        while not (path.parent/'progress.json').exists():
                            if time.monotonic()>deadline:self.fail('fixture child did not start')
                            time.sleep(.02)
                        pids.append(mb.read_json(path)['pid'])
                    server.send_signal(signum)
                    self.assertEqual(server.wait(timeout=8),0)
                    for run,pid in zip(runs,pids):
                        with self.assertRaises(ProcessLookupError):os.kill(pid,0)
                        path=store/'runs'/run['id']/'run.json'
                        self.assertEqual(mb.read_json(path)['status'],'cancelled')
                        self.assertGreater(mb.read_json(path.parent/'progress.json')['completed'],0)
                finally:
                    if server.poll() is None:server.kill();server.wait(timeout=3)
                    for pid in pids:
                        try:os.kill(pid,signal.SIGKILL)
                        except ProcessLookupError:pass
                    if server.stdout:server.stdout.close()

    def test_close_reaps_all_simulations_but_not_independent_play_process(self):
        a,b=self.start(),self.start(1002)
        ar,br=self.running(a['id']),self.running(b['id'])
        jobs=list(self.app.jobs.values())
        play=subprocess.Popen(['/usr/bin/python3','-c','import time;time.sleep(15)'],start_new_session=True)
        try:
            self.app.close()
            self.assertEqual(self.app.jobs,{})
            for job in jobs:
                self.assertIsNotNone(job['proc'].poll())
                self.assertFalse(job['thread'].is_alive())
                self.assertEqual(self.app.run(job['run']['id'])['status'],'cancelled')
            self.assertIsNone(play.poll())
            with self.assertRaisesRegex(ValueError,'工作台正在关闭'):self.start()
        finally:
            play.terminate();play.wait(timeout=3)


class ManualBalanceUiTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which('node'), '网页行为测试需要 Node.js')
    def test_editor_save_and_run(self):
        result=subprocess.run([shutil.which('node'),'--test',str(ROOT/'tests/test_manual_balance_ui.cjs')],
                              cwd=ROOT,capture_output=True,text=True,timeout=30)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)

class ApiIntegrationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import subprocess,socket
        cls.tmp=tempfile.TemporaryDirectory()
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0));cls.port=sock.getsockname()[1]
        cls.proc=subprocess.Popen(['/usr/bin/python3',str(ROOT/'tools/manual_balance.py'),'--port',str(cls.port),'--store',cls.tmp.name],cwd=cls.tmp.name,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        cls.url=f'http://127.0.0.1:{cls.port}/'
        for _ in range(100):
            try:
                cls.data=json.loads(urllib.request.urlopen(cls.url+'api/bootstrap',timeout=.3).read());break
            except OSError: time.sleep(.1)
        else: raise RuntimeError(cls.proc.stdout.read())
    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        try: cls.proc.wait(timeout=10)
        except __import__('subprocess').TimeoutExpired:
            cls.proc.kill();cls.proc.wait(timeout=10)
        if cls.proc.stdout: cls.proc.stdout.close()
        cls.tmp.cleanup()
    def post(self,path,body,token=True):
        headers={'Content-Type':'application/json'}
        if token:headers['X-Balance-Token']=type(self).data['token']
        return urllib.request.urlopen(urllib.request.Request(self.url+path,data=json.dumps(body).encode(),headers=headers),timeout=10)
    def ai_side(self,strength):
        metadata=json.load(self.post('api/profile',{'strength':strength}))
        return {'strength':strength,'ai_parameters':metadata['parameters']}

    def test_live_slider_table_contains_exact_engine_profiles(self):
        metadata=self.data['ai']
        profiles=metadata['strength_profiles']
        self.assertEqual(set(profiles),{f'{index/100:.2f}' for index in range(101)})
        keys={spec['key'] for spec in metadata['schema']}
        for values in profiles.values():
            self.assertEqual(set(values),keys)
            mb.validate_options({**mb.DEFAULT_OPTIONS,'ai_parameters':values},metadata['schema'])
        self.assertEqual(profiles['0.50'],metadata['parameters'])
        for strength in (0,.37,.51,.75,1):
            actual=self.ai_side(strength)['ai_parameters']
            self.assertEqual(profiles[f'{strength:.2f}'],actual)
        self.assertEqual(profiles['0.50']['generation_budget'],0)
        self.assertEqual(profiles['0.51']['generation_budget'],30000)

    def test_duel_validates_and_preserves_all_manual_parameters(self):
        side=self.ai_side(.5)
        side['ai_parameters']['engine_horizon']=2.31
        side['ai_parameters']['financing_mode']=1
        options={'pairs':1,'max_rounds':1,'seed_start':207,'a':side,'b':self.ai_side(0)}
        for change in ({'missing':'value'},{'engine_horizon':10.1},{'financing_mode':1.5},
                       {'node_budget':True},{'unknown_parameter':1}):
            invalid=copy.deepcopy(options)
            if 'missing' in change:invalid['a']['ai_parameters'].pop('samples')
            else:invalid['a']['ai_parameters'].update(change)
            with self.assertRaises(urllib.error.HTTPError) as error:
                self.post('api/duel',{'config_id':'default','options':invalid})
            self.assertEqual(error.exception.code,400);error.exception.close()
        run=json.load(self.post('api/duel',{'config_id':'default','options':options}))
        for _ in range(150):
            result=json.load(urllib.request.urlopen(self.url+'api/run/'+run['id']))
            if result['status'] not in ('queued','running'):break
            time.sleep(.1)
        self.assertEqual(result['status'],'complete',result.get('error'))
        self.assertEqual(result['options']['a']['ai_parameters'],side['ai_parameters'])
        actual=result['result']['a']['parameters']
        self.assertEqual(actual['engine_horizon'],2.31)
        self.assertEqual(actual['financing_mode'],1)
        self.assertEqual(set(side['ai_parameters']),{s['key'] for s in self.data['ai']['schema']})

    def test_version_requires_name_and_parameters_to_change_together(self):
        cards=self.data['configs'][0]['cards']
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.post('api/config',{'source_id':'default','name':'只改名称','cards':cards})
        self.assertIn('只修改了版本名称',error.exception.read().decode());error.exception.close()
        changed=copy.deepcopy(cards);changed['yunketang']['price']+=1
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.post('api/config',{'source_id':'default','name':'默认卡表','cards':changed})
        self.assertIn('版本名称没有变化',error.exception.read().decode());error.exception.close()
        first=json.loads(self.post('api/config',{'source_id':'default','name':'唯一名称','cards':changed}).read())
        reused=json.loads(self.post('api/config',{'source_id':first['id'],'name':'唯一名称','cards':changed}).read())
        self.assertEqual(first['id'],reused['id'])
        self.assertTrue(reused['reused'])
        changed_again=copy.deepcopy(changed);changed_again['yunketang']['price']+=1
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.post('api/config',{'source_id':first['id'],'name':'唯一名称','cards':changed_again})
        self.assertIn('版本名称没有变化',error.exception.read().decode());error.exception.close()

    def test_ai_duel_resolves_two_profiles_and_records_swapped_results(self):
        options={'pairs':2,'max_rounds':1,'seed_start':113,
                 'a':self.ai_side(0.1),'b':self.ai_side(0)}
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.post('api/duel',{'config_id':'default','options':options},token=False)
        self.assertEqual(error.exception.code,403);error.exception.close()
        for bad in [dict(options,pairs=0),dict(options,a={**options['a'],'strength':2}),
                    dict(options,b={'strength':0,'ai_parameters':{}}),
                    dict(options,seed_start=mb.MAX_SAFE_INTEGER)]:
            with self.assertRaises(urllib.error.HTTPError) as error:
                self.post('api/duel',{'config_id':'default','options':bad})
            self.assertEqual(error.exception.code,400);error.exception.close()
        run=json.load(self.post('api/duel',{'config_id':'default','options':options}))
        for _ in range(150):
            result=json.load(urllib.request.urlopen(self.url+'api/run/'+run['id']))
            if result['status'] not in ('queued','running'):break
            time.sleep(.1)
        self.assertEqual(result['status'],'complete',result.get('error'))
        self.assertEqual(result['kind'],'ai-duel')
        report=result['result'];summary=report['summary']
        self.assertNotEqual(report['a']['parameters'],report['b']['parameters'])
        self.assertEqual(summary['completed_games'],4)
        self.assertEqual(summary['completed_seed_pairs'],2)
        self.assertEqual(summary['a_wins']+summary['b_wins']+summary['draws'],4)
        self.assertEqual(summary['mean_rounds'],1)
        self.assertEqual(result['progress']['summary']['a_wins'],summary['a_wins'])
        for seed in (113,114):
            games=[g for g in report['games'] if g['seed']==seed]
            self.assertEqual([g['a_seat'] for g in games],['player','ai'])
        self.assertEqual(report['cards_sha256'],__import__('hashlib').sha256(
            (pathlib.Path(self.tmp.name)/'runs'/run['id']/'cards.json').read_bytes()).hexdigest())
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.post('api/duel',{'config_id':'default','options':dict(options,pairs=5001,seed_start=mb.MAX_SAFE_INTEGER)})
        error.exception.close()

    def test_ai_duel_wins_follow_ai_identity_when_swapping_seats(self):
        cards=copy.deepcopy(self.data['configs'][0]['cards']);cards['_game']['start_cash']=99
        config=json.load(self.post('api/config',{'source_id':'default','name':'AI对战冲线验证','cards':cards}))
        options={'pairs':1,'max_rounds':1,'seed_start':115,
                 'a':self.ai_side(1),'b':self.ai_side(0)}
        run=json.load(self.post('api/duel',{'config_id':config['id'],'options':options}))
        for _ in range(150):
            result=json.load(urllib.request.urlopen(self.url+'api/run/'+run['id']))
            if result['status'] not in ('queued','running'):break
            time.sleep(.1)
        self.assertEqual(result['status'],'complete',result.get('error'))
        report=result['result'];summary=report['summary']
        self.assertEqual((summary['a_wins'],summary['b_wins'],summary['draws']),(1,1,0))
        self.assertEqual([g['winner'] for g in report['games']],['A','B'])
        self.assertEqual(summary['a_decisive_win_rate'],.5)
        self.assertEqual(summary['a_score_pair_bootstrap_95'],[])
        self.assertEqual(report['a']['parameters']['financing_mode'],2)
        self.assertEqual(report['b']['parameters']['financing_mode'],0)

    def test_export_to_selected_path(self):
        target=pathlib.Path(self.tmp.name)/'chosen-name.json'
        result=json.loads(self.post('api/export',{'path':str(target),'obj':self.data['configs'][0]['cards']}).read())
        self.assertEqual(result['path'],mb.display_path(target.resolve(),ROOT))
        self.assertEqual(json.loads(target.read_text()),self.data['configs'][0]['cards'])
        icon=urllib.request.urlopen(self.url+'assets/art/icon/icon_yunketang.png').read()
        self.assertGreater(len(icon),100)

    def test_health_and_http_errors_do_not_expose_local_project_path(self):
        health=json.loads(urllib.request.urlopen(self.url+'api/health').read())
        self.assertEqual(health['project'],mb.project_id())
        self.assertNotIn(str(pathlib.Path.home()),json.dumps(health))
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.post('api/export',{'path':str(ROOT/'missing-private-directory'/'cards.json'),
                                    'obj':self.data['configs'][0]['cards']})
        detail=error.exception.read().decode();error.exception.close()
        self.assertNotIn(str(ROOT),detail)
        self.assertIn('missing-private-directory',detail)

    def test_pawn_override_can_be_saved_and_removed(self):
        cards=copy.deepcopy(self.data['configs'][0]['cards']);cards['yunketang']['pawn']=0
        first=json.loads(self.post('api/config',{'source_id':'default','name':'自定义出售价格','cards':cards}).read())
        self.assertEqual(first['cards']['yunketang']['pawn'],0)
        del cards['yunketang']['pawn']
        restored=json.loads(self.post('api/config',{'source_id':first['id'],'name':'恢复自动出售价格','cards':cards}).read())
        self.assertNotIn('pawn',restored['cards']['yunketang'])
        before=json.loads(urllib.request.urlopen(self.url+'api/bootstrap').read())
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.post('api/play',{'config_id':'missing-config'})
        self.assertIn('配置不存在',error.exception.read().decode());error.exception.close()
        after=json.loads(urllib.request.urlopen(self.url+'api/bootstrap').read())
        self.assertEqual(after['runs'],before['runs'])

    def test_notes_belong_to_each_config_without_running(self):
        before=json.loads(urllib.request.urlopen(self.url+'api/bootstrap').read())
        base=before['configs'][0]['cards']
        configs=[]
        for index in range(2):
            changed=copy.deepcopy(base);changed['yunketang']['price']+=index+3
            configs.append(json.loads(self.post('api/config',{
                'source_id':'default','name':'备注测试'+str(index),'cards':changed}).read()))
        expected={'default':'默认卡表试玩感受',configs[0]['id']:'节奏偏快',configs[1]['id']:'资源不足'}
        for cid,text in expected.items():
            notes=json.loads(self.post('api/notes',{'id':cid,'text':text}).read())
            self.assertEqual(notes['text'],text)
            self.assertNotIn('rating',notes)
            self.assertEqual(json.loads((pathlib.Path(self.tmp.name)/'notes'/(cid+'.json')).read_text()),notes)
        expected[configs[0]['id']]='只更新第一份配置的备注'
        self.post('api/notes',{'id':configs[0]['id'],'text':expected[configs[0]['id']]}).close()
        note_files=set((pathlib.Path(self.tmp.name)/'notes').glob('*.json'))
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.post('api/notes',{'id':'missing-config','text':'不能保存到不存在的配置'})
        self.assertIn('配置不存在',error.exception.read().decode());error.exception.close()
        self.assertEqual(set((pathlib.Path(self.tmp.name)/'notes').glob('*.json')),note_files)
        after=json.loads(urllib.request.urlopen(self.url+'api/bootstrap').read())
        stored={config['id']:config for config in after['configs']}
        for cid,text in expected.items(): self.assertEqual(stored[cid]['notes']['text'],text)
        self.assertEqual(set(stored),{c['id'] for c in before['configs']}|{c['id'] for c in configs})
        self.assertEqual([r['id'] for r in after['runs']],[r['id'] for r in before['runs']])

    def test_write_requires_token_and_run_completes(self):
        with self.assertRaises(urllib.error.HTTPError) as e:
            self.post('api/config',{'source_id':'default','name':'默认卡表','cards':self.data['configs'][0]['cards']},False)
        self.assertEqual(e.exception.code,403)
        e.exception.close()
        changed=copy.deepcopy(self.data['configs'][0]['cards']);changed['yunketang']['price']+=1
        config=json.loads(self.post('api/config',{'source_id':'default','name':'集成测试','imported_name':'卡表内名称','source_file':'cards.json','cards':changed}).read())
        self.assertEqual(config['imported_name'],'卡表内名称')
        self.assertEqual(config['source_file'],'cards.json')
        stored=pathlib.Path(self.tmp.name)/'configs'/(config['id']+'.json')
        self.assertEqual(mb.read_json(stored),changed)
        self.assertEqual(mb.read_json(pathlib.Path(self.tmp.name)/'config_meta'/stored.name),
                         {k:v for k,v in config.items() if k!='cards'})
        self.post('api/notes',{'id':config['id'],'text':'多次模拟共用这份配置的试玩备注'}).close()
        options=copy.deepcopy(mb.DEFAULT_OPTIONS)
        profile=json.loads(self.post('api/profile',{'strength':0.0}).read())
        type(self).data=json.loads(urllib.request.urlopen(self.url+'api/bootstrap').read())
        before=type(self).data
        options.update(pairs=1,max_rounds=2,strength=0.0,ai_parameters=profile['parameters'])
        new_runs=[]
        for _ in range(2):
            result=json.loads(self.post('api/run',{'config_id':config['id'],'options':options}).read())
            self.assertEqual(result['status'],'queued')
            self.assertIsInstance(result['created'],float)
            run=result;new_runs.append(run['id'])
            self.assertEqual(mb.read_json(pathlib.Path(self.tmp.name)/'runs'/run['id']/'cards.json'),changed)
            for _ in range(120):
                result=json.loads(urllib.request.urlopen(self.url+'api/run/'+run['id']).read())
                if result['status'] not in ('queued','running'):break
                time.sleep(.25)
            self.assertEqual(result['status'],'complete',result.get('error'))
            metrics=result['result']['metrics']
            self.assertEqual(set(metrics),{definition[0] for definition in before['definitions']})
            self.assertEqual(before['definitions'][6][:2],['Q7','升级后成功生产'])
            self.assertEqual(before['definitions'][-2][:2],['Q10','获胜方式多样性'])
            self.assertEqual(before['definitions'][-2][3],'种')
            self.assertEqual(before['definitions'][-1][:2],['Q11','典当后获胜比例'])
            self.assertEqual(before['definitions'][-1][3],'%')
            games=result['result']['games']
            self.assertTrue(all(type(game['upgrade_produced']) is bool for game in games))
            self.assertTrue(all(isinstance(game['pawned_seats'],list) and
                                set(game['pawned_seats']) <= {'player','ai'} for game in games))
            self.assertEqual(metrics['Q7']['definition'],'upgrade-production-v1')
            for q,hits in [('Q7',sum(game['upgrade_produced'] for game in games)),
                           ('Q11',sum(bool(game['winner']) and game['winner'] in game['pawned_seats'] for game in games))]:
                self.assertEqual(metrics[q]['numerator'],hits)
                self.assertEqual(metrics[q]['denominator'],len(games))
                self.assertEqual(metrics[q]['value'],100*hits/len(games))
                self.assertEqual(result['progress']['metrics'][q],metrics[q])
            for q,field,start,unit in [('Q8','max_cash','start_cash','现金'),('Q9','max_users','start_user','用户')]:
                self.assertTrue(all(game[field]>=changed['_game'][start] for game in games))
                self.assertEqual(metrics[q]['numerator'],sum(game[field] for game in games))
                self.assertEqual(metrics[q]['denominator'],len(games))
                self.assertEqual(metrics[q]['value'],sum(game[field] for game in games)/len(games))
                self.assertEqual(metrics[q]['unit'],unit)
                self.assertEqual(result['progress']['metrics'][q],metrics[q])
            diversity=metrics['Q10']
            self.assertEqual(diversity['unit'],'种')
            self.assertIsNone(diversity['numerator'])
            self.assertEqual(diversity['denominator'],diversity['classified_games'])
            self.assertEqual(sum(item['count'] for item in diversity['distribution']),diversity['classified_games'])
            self.assertEqual(len(diversity['distribution']),diversity['category_count'])
            self.assertEqual(sum(item['count']>0 for item in diversity['distribution']),diversity['observed_categories'])
            self.assertEqual(diversity['classified_games']+diversity['unclassified_wins'],sum(bool(game['winner']) for game in games))
            if diversity['classified_games']:
                self.assertGreaterEqual(diversity['value'],1)
                self.assertLessEqual(diversity['value'],diversity['category_count']+1e-9)
                self.assertAlmostEqual(sum(item['percentage'] for item in diversity['distribution']),100)
            else:
                self.assertIsNone(diversity['value'])
            self.assertEqual(result['progress']['metrics']['Q10'],diversity)
            self.assertEqual(result['progress']['completed'],2)
            self.assertEqual(result['result']['meta']['metric_version'],'manual-eleven-v4')
            self.assertNotIn('notes',result)
            latest=json.loads(urllib.request.urlopen(self.url+'api/bootstrap').read())
            self.assertEqual({c['id']:c['notes'] for c in latest['configs']},
                             {c['id']:c['notes'] for c in before['configs']})
        cls = type(self)
        cls.data=json.loads(urllib.request.urlopen(self.url+'api/bootstrap').read())
        self.assertEqual(len(set(new_runs)),2)
        self.assertEqual({r['id'] for r in cls.data['runs']},{r['id'] for r in before['runs']}|set(new_runs))

    def test_saved_card_file_is_accepted_directly_by_real_game(self):
        cards=copy.deepcopy(self.data['configs'][0]['cards']);cards['yunketang']['pawn']=17
        config=json.loads(self.post('api/config',{'source_id':'default','name':'直接加载纯文件','cards':cards}).read())
        path=pathlib.Path(self.tmp.name)/'configs'/(config['id']+'.json')
        profile=json.loads(self.post('api/profile',{'strength':0.0}).read())
        options=copy.deepcopy(mb.DEFAULT_OPTIONS)
        options.update(pairs=1,max_rounds=1,strength=0.0,ai_parameters=profile['parameters'])
        output=pathlib.Path(self.tmp.name)/'direct-game-result.json'
        request=pathlib.Path(self.tmp.name)/'direct-game-request.json'
        progress=pathlib.Path(self.tmp.name)/'direct-game-progress.json'
        mb.atomic_json(request,{'schema':'manual-balance-request-v1','cards_path':mb.relative_path(path,ROOT),
                               'output_path':mb.relative_path(output,ROOT),
                               'progress_path':mb.relative_path(progress,ROOT),'options':options})
        godot=__import__('os').environ.get('GODOT','/Applications/Godot.app/Contents/MacOS/Godot')
        result=subprocess.run([godot,'--headless','--path','.','-s','tools/eval_report.gd','--',mb.relative_path(request,ROOT)],
                              cwd=ROOT,capture_output=True,text=True,timeout=30)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertNotIn('SCRIPT ERROR:',result.stdout+result.stderr)
        self.assertTrue(output.is_file(),result.stdout+result.stderr)
        report=mb.read_json(output)
        self.assertEqual(report['status'],'complete',report)
        self.assertEqual(len(report['games']),2)
        self.assertEqual(mb.read_json(progress)['completed'],2)
        self.assertEqual(mb.read_json(path),cards)

    def test_stop_keeps_server_alive(self):
        base=type(self).data['configs'][0]['cards'];changed=copy.deepcopy(base);changed['yunketang']['price']+=2
        config=json.loads(self.post('api/config',{'source_id':'default','name':'停止测试','cards':changed}).read())
        latest=json.loads(urllib.request.urlopen(self.url+'api/bootstrap').read())
        type(self).data=latest
        options=copy.deepcopy(mb.DEFAULT_OPTIONS)
        editable={s['key'] for s in latest['ai']['schema']}
        options.update(pairs=5001,max_rounds=1000,seed_start=5001,strength=1.0,
                       ai_parameters={k:v for k,v in latest['ai']['parameters'].items() if k in editable})
        try:
            response=self.post('api/run',{'config_id':config['id'],'options':options})
        except urllib.error.HTTPError as error:
            detail=error.read().decode();error.close()
            self.fail('长任务启动失败：'+detail)
        run=json.loads(response.read())
        self.assertTrue(json.loads(self.post('api/stop',{'run_id':run['id']}).read())['stopping'])
        for _ in range(120):
            result=json.loads(urllib.request.urlopen(self.url+'api/run/'+run['id']).read())
            if result['status'] not in ('queued','running','stopping'):break
            time.sleep(.1)
        self.assertEqual(result['status'],'cancelled',result.get('error'))
        health=json.loads(urllib.request.urlopen(self.url+'api/health').read())
        self.assertEqual(health['app'],'manual-balance-v1')

    def test_two_real_godot_runs_overlap_and_stop_independently(self):
        profile=json.loads(self.post('api/profile',{'strength':0.0}).read())
        options=copy.deepcopy(mb.DEFAULT_OPTIONS)
        options.update(pairs=50,max_rounds=40,strength=0.0,ai_parameters=profile['parameters'])
        launched=[]
        def get_run(rid):
            with urllib.request.urlopen(self.url+'api/run/'+rid,timeout=2) as response:return json.load(response)
        def wait_for(predicate,timeout=20):
            deadline=time.monotonic()+timeout
            while time.monotonic()<deadline:
                value=predicate()
                if value:return value
                time.sleep(.03)
            self.fail('真实并行模拟超时：'+str([get_run(r['id'])['status'] for r in launched]))
        def terminal(rid):
            result=get_run(rid)
            return result if result['status'] not in ('queued','running','stopping') else None
        try:
            a=json.loads(self.post('api/run',{'config_id':'default','options':options}).read());launched.append(a)
            options.update(pairs=10,max_rounds=2,seed_start=2001)
            b=json.loads(self.post('api/run',{'config_id':'default','options':options}).read());launched.append(b)
            wait_for(lambda:all(get_run(r['id'])['status']=='running' for r in launched))
            ar,br=get_run(a['id']),get_run(b['id'])
            self.assertNotEqual(ar['pid'],br['pid'])
            os.kill(ar['pid'],0);os.kill(br['pid'],0)
            overview=json.loads(urllib.request.urlopen(self.url+'api/runs').read())
            self.assertTrue({a['id'],b['id']} <= set(overview['active_run_ids']))
            self.assertNotIn('active',overview)
            for body in [{},{'run_id':'ffffffff'},{'run_id':'../bad'}]:
                with self.assertRaises(urllib.error.HTTPError) as error:self.post('api/stop',body)
                self.assertEqual(error.exception.code,400);error.exception.close()
            before=get_run(b['id']).get('progress',{}).get('completed',0)
            stopped=json.loads(self.post('api/stop',{'run_id':a['id']}).read())
            self.assertEqual(stopped['run_id'],a['id'])
            self.assertTrue(stopped['stopping'])
            self.assertEqual(wait_for(lambda:terminal(a['id']))['status'],'cancelled')
            self.assertFalse(json.loads(self.post('api/stop',{'run_id':a['id']}).read())['stopping'])
            wait_for(lambda:get_run(b['id']).get('progress',{}).get('completed',0)>before)
            result=wait_for(lambda:terminal(b['id']))
            self.assertEqual(result['status'],'complete',result.get('error'))
            self.assertEqual(result['progress']['completed'],20)
            complete_stop=json.loads(self.post('api/stop',{'run_id':b['id']}).read())
            self.assertEqual(complete_stop,{'stopping':False,'run_id':b['id'],'status':'complete'})
            # A 可能在 Godot 初始化日志前就被取消，完成的 B 必须使用自己的日志文件。
            self.assertTrue((pathlib.Path(self.tmp.name)/'runs'/b['id']/'engine.log').is_file())
        finally:
            for run in launched:
                self.post('api/stop',{'run_id':run['id']}).close()
            for run in launched:wait_for(lambda rid=run['id']:terminal(rid))

if __name__=='__main__':unittest.main()
