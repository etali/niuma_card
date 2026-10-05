#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""单机手动调参工作台。只监听127.0.0.1；不改默认卡表或历史实验。"""
from __future__ import annotations
import argparse
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit
sys.path.insert(0, str(Path(__file__).resolve().parent))
from legacy_names import normalize_legacy
from project_paths import relative_path, display_path, redact_paths, sanitize_file

ROOT = Path(__file__).resolve().parent.parent
WEB = ROOT / 'tools/balance'
DEFAULT_STORE = ROOT / 'reports/manual_balance'
LABELS = {'price':'购买价格','pawn':'出售价格','weight':'市场权重','recipe_n':'配方数量','output_n':'产出数量',
          'attack_n':'攻击点数','start_cash':'初始现金','start_user':'初始用户'}
DEFINITIONS = [
    ['Q1','先手胜率','开局先手获胜局数 ÷ 已结束局数。接近50%表示本批次较对称；不是越高越好。','%'],
    ['Q2','平均结束回合','已结束对局的结束回合总和 ÷ 已结束局数。未结束局不混算；与Q3一起看。','回合'],
    ['Q3','未结束比例','达到回合上限仍未结束局数 ÷ 已模拟局数。0%表示本批次全部结束，是正常值。','%'],
    ['Q4','有效反馈比例','有正产出、成功升级、成功攻击或典当直接获胜的座位回合 ÷ 实际发生的座位行动回合数。同人同回合只计一次；不是玩家爽感评分。','%'],
    ['Q5','双方攻击比例','双方都曾成功攻击的对局数 ÷ 已模拟局数。仅单方攻击不算双方互动。','%'],
    ['Q6','卡牌使用覆盖','买入、有效编组使用或升级产物中出现的不同非资源卡种数 ÷ 全部非资源卡种数。买入即计覆盖，不代表有用或平衡；局数越多通常越高。可展开获得卡牌的张数与占比，包含购买和升级产物，排除现金牌和用户牌。','%'],
    ['Q7','升级后成功生产','至少一方用本局升级生成的卡牌成功生产过正产出的对局数 ÷ 已模拟局数。同局只计一次；仅合成、出售升级产物或生产被打断不计。旧口径记录须重新评估。','%'],
    ['Q8','局均最大现金数','每局任意一方曾持有的最高现金数之和 ÷ 有峰值记录的局数。包含开局及未结束局已观测到的峰值，不把双方现金相加。','现金'],
    ['Q9','局均最大用户数','每局任意一方曾持有的最高用户数之和 ÷ 有峰值记录的局数。包含开局及未结束局已观测到的峰值，不把双方用户相加。','用户'],
    ['Q10','获胜方式多样性','按已归类胜局的获胜方式分布计算有效方式数：1表示只有一种，上限为配置支持的分类数；它衡量终局机制分布，不等于打法或乐趣多样性，也不是越高越好。','种'],
    ['Q11','典当后获胜比例','最终获胜方曾成功典当过的对局数 ÷ 已模拟局数。普通卡、用户及传说的典当均计，不要求典当直接致胜；双方都典当且有胜者也只计一局。未结束局计入分母，不计入分子。','%'],
]
MAX_SAFE_INTEGER = 9007199254740991  # 与浏览器 Number / JSON 的精确整数范围一致。
DEFAULT_OPTIONS = {'pairs':5,'max_rounds':40,'seed_start':1001,'model':'bot','strength':0.5,'bot_parameters':{}}
PLAY_START_TIMEOUT = 20.0


def source_version():
    files = [Path(__file__).resolve(), WEB/'report.html', WEB/'report.js', WEB/'report.css',
             ROOT/'data/card_config_schema.json', Path(__file__).with_name('project_paths.py'),
             Path(__file__).with_name('legacy_names.py')]
    return hashlib.sha256(b''.join(p.read_bytes() for p in files)).hexdigest()[:16]


def project_id():
    """Identify this checkout without publishing its local directory."""
    return 'sha256:' + hashlib.sha256(os.fsencode(ROOT.resolve())).hexdigest()


def same_project(value):
    # 旧服务返回绝对目录；只用于识别并提示重启，不能继续复用旧接口。
    return value in (project_id(), str(ROOT))


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def atomic_json(path, obj):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(obj, ensure_ascii=False, indent=2, allow_nan=False) + '\n'
    fd, name = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(payload)
            f.flush()
            os.fsync(f.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name): os.unlink(name)


def digest(obj):
    return hashlib.sha256(json.dumps(obj, sort_keys=True, ensure_ascii=False, allow_nan=False).encode()).hexdigest()


def numeric(v):
    try:
        return type(v) in (int,float) and math.isfinite(v)
    except OverflowError:
        return False


# 字段白名单、数值边界和跨字段约束与游戏/无头评估共用同一份规格。
CARD_SCHEMA = read_json(ROOT / 'data/card_config_schema.json')


def editable_specs(key, card):
    section = '_game' if key == '_game' else 'cards'
    if key != '_game' and (key.startswith('_') or card.get('kind') == 'unit'):
        return {}
    return {field:spec for field,spec in CARD_SCHEMA['editable'][section].items()
            if (field in card or spec.get('optional'))
            and (not spec.get('positive_default') or card.get(field,0) > 0)}


def mutable_fields(base):
    fields = []
    for key, card in base.items():
        if not isinstance(card,dict): continue
        for field,spec in editable_specs(key,card).items():
            item = {'card':key,'field':field,'label':LABELS[field],
                    'name':'开局资源' if key == '_game' else card['name'],
                    'min':spec['min'],'max':spec.get('max', CARD_SCHEMA['max_integer'])}
            if spec.get('optional'): item['optional'] = field not in card
            fields.append(item)
    return fields


def fixed_rule_equal(path, value, baseline):
    if path in CARD_SCHEMA['fixed_text_paths']:
        return isinstance(value,str) and isinstance(baseline,str)
    if isinstance(baseline,dict):
        return (isinstance(value,dict) and set(value) == set(baseline)
                and all(fixed_rule_equal(path+'.'+key,value[key],v) for key,v in baseline.items()))
    if isinstance(baseline,list):
        return (isinstance(value,list) and len(value) == len(baseline)
                and all(fixed_rule_equal(path+'.'+str(i),v,b) for i,(v,b) in enumerate(zip(value,baseline))))
    if numeric(baseline): return numeric(value) and value == baseline
    return type(value) is type(baseline) and value == baseline


def validate_cards(cards, base):
    if not isinstance(cards,dict):
        raise ValueError('卡表必须是完整 JSON 对象')
    candidate = cards.copy()
    for key in CARD_SCHEMA['ignored_metadata']:
        if key in candidate and not isinstance(candidate[key],str):
            raise ValueError('配置名称必须是文本')
        candidate.pop(key,None)
    if set(candidate) != set(base):
        raise ValueError('卡表必须包含与默认配置相同的卡牌和规则段，请导入完整 cards.json')
    for key, original in base.items():
        value = candidate[key]
        if not isinstance(original,dict):
            if not fixed_rule_equal(key,value,original): raise ValueError('不能修改固定配置说明')
            continue
        editable = editable_specs(key,original)
        extra = {field for field,spec in editable.items() if spec.get('optional')}
        if not isinstance(value,dict) or not set(original) <= set(value) <= set(original) | extra:
            raise ValueError('字段集合改变：' + original.get('name',key))
        for field, v in value.items():
            label = original.get('name','全局规则') + ' · ' + LABELS.get(field,field)
            if field in editable:
                minimum = editable[field]['min']
                maximum = editable[field].get('max', CARD_SCHEMA['max_integer'])
                if not numeric(v) or v < minimum or v != int(v) or v > maximum:
                    constraint = '非负整数' if minimum == 0 else '正整数'
                    raise ValueError(label+' 必须是'+constraint+'（不超过%d）' % maximum)
            elif not fixed_rule_equal(key+'.'+field,v,original[field]):
                raise ValueError('不能修改固定字段：'+label)
    for rule in CARD_SCHEMA['less_than']:
        left, right = candidate, candidate
        for key in rule['left']: left = left[key]
        for key in rule['right']: right = right[key]
        if left >= right: raise ValueError(rule['message'])
    return candidate


def validate_options(o, schema):
    if not isinstance(o,dict) or set(o) != set(DEFAULT_OPTIONS):
        raise ValueError('模拟参数字段不完整或含不支持字段')
    for key in ('pairs','max_rounds','seed_start'):
        if not numeric(o[key]) or o[key] != int(o[key]) or not 1 <= o[key] <= MAX_SAFE_INTEGER:
            raise ValueError({'pairs':'种子对数','max_rounds':'回合上限','seed_start':'起始种子'}[key]+'必须为可精确表示的正整数')
    if o['pairs'] > MAX_SAFE_INTEGER // 2:
        raise ValueError('总局数超过精确整数范围')
    if o['pairs'] - 1 > MAX_SAFE_INTEGER - o['seed_start']:
        raise ValueError('最后一个种子超过精确整数范围')
    if o['model'] != 'bot' or not numeric(o['strength']) or not 0 <= o['strength'] <= 1:
        raise ValueError('BOT实现或强度无效')
    if not isinstance(o['bot_parameters'],dict): raise ValueError('BOT参数必须为对象')
    if set(o['bot_parameters']) != {s['key'] for s in schema}: raise ValueError('BOT参数必须包含全部可编辑项')
    specs = {s['key']:s for s in schema}
    for key,v in o['bot_parameters'].items():
        s = specs.get(key)
        if not s or not numeric(v) or not s['min'] <= v <= s['max']:
            raise ValueError('BOT参数无效：'+key)
        if s.get('read_only'):
            points = s['strength_points']
            expected = points[-1][1]
            for left, right in zip(points, points[1:]):
                if o['strength'] < right[0]:
                    fraction = (o['strength'] - left[0]) / (right[0] - left[0])
                    expected = left[1] + (right[1] - left[1]) * fraction
                    break
            expected = s['min'] + math.floor((expected - s['min']) / s['step'] + 0.5) * s['step']
            if not math.isclose(v, expected, rel_tol=0, abs_tol=1e-10):
                raise ValueError(s['label']+'由强度自动推导，不能单独修改')
        if s['kind']=='int' and v != int(v): raise ValueError('BOT参数要求整数：'+s['label'])
        step = (v-s['min'])/s['step']
        if abs(step-round(step)) > 1e-6: raise ValueError('BOT参数步长不正确：'+s['label'])
    return copy.deepcopy(o)


def engine_fingerprint():
    files = sorted((ROOT/'engine').glob('*.gd')) + sorted(WEB.glob('*.gd')) + [
        ROOT/'tools/eval_report.gd', ROOT/'tools/bot_duel_report.gd', ROOT/'tools/bot_duel.gd', ROOT/'tools/bot_decision_stats.gd', ROOT/'data/bot.json', ROOT/'data/card_config_schema.json']
    return digest({str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files})


class Workbench:
    def __init__(self, store, godot):
        self.store = Path(store)
        self.godot = str(godot)
        self.base = read_json(ROOT/'data/cards.json')
        self.lock = threading.RLock()
        self.jobs = {}
        self.closing = False
        self.store.mkdir(parents=True,exist_ok=True)
        self._file_lock = (self.store/'server.lock').open('a+')
        import fcntl
        try: fcntl.flock(self._file_lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:
            self._file_lock.close()
            raise ValueError('此数据目录已有工作台运行，请使用已打开的页面')
        try:
            # 先持有目录排他锁再迁移；启动失败不能留下半个可用服务或占用锁。
            with self.lock:
                for path in sorted((self.store/'configs').glob('*.json')):
                    self._read_saved_config(path)
            self.metadata = self.profile(DEFAULT_OPTIONS['strength'])
            self.schema = self.metadata['schema']
            for path in (self.store/'runs').glob('*/run.json'):
                run = read_json(path)
                if run['status'] in ('running','queued','stopping'):
                    run['status'] = 'interrupted'
                    run['error'] = '上次服务已退出；结果未完成，请重新运行。已完成局进度保留。'
                    atomic_json(path,run)
        except Exception:
            self._file_lock.close()
            raise

    def profile(self,strength):
        if not numeric(strength) or not 0<=strength<=1: raise ValueError('强度无效')
        with tempfile.TemporaryDirectory(prefix='balance-profile-') as tmp:
            request,output = Path(tmp)/'request.json',Path(tmp)/'result.json'
            atomic_json(request,{'action':'metadata','strength':strength,'output_path':relative_path(output,ROOT)})
            try:
                r = subprocess.run([self.godot,'--headless','--path','.','--log-file',relative_path(Path(tmp)/'engine.log',ROOT),'-s','tools/eval_report.gd','--',relative_path(request,ROOT)],
                                   cwd=str(ROOT),capture_output=True,text=True,timeout=45)
            except (OSError,subprocess.TimeoutExpired) as error:
                raise ValueError('无法读取真实BOT参数：'+redact_paths(str(error),ROOT)) from error
            if r.returncode or 'SCRIPT ERROR:' in r.stderr or not output.exists():
                raise ValueError('无法读取真实BOT参数：'+redact_paths((r.stderr+r.stdout)[-3000:],ROOT))
            result = read_json(output)
            keys = {item['key'] for item in result['schema']}
            result['parameters'] = {key:value for key,value in result['parameters'].items() if key in keys}
            return result

    def _read_saved_config(self, path):
        """Read the API record; upgrade old wrappers while the caller holds self.lock."""
        meta_path = self.store/'config_meta'/path.name
        try:
            stored = read_json(path)
            if not isinstance(stored,dict): raise ValueError('配置文件必须是完整卡表对象')
            legacy = 'cards' in stored and 'id' in stored
            if legacy:
                cards = stored['cards']
                metadata = {key:value for key,value in stored.items() if key != 'cards'}
            else:
                cards = stored
                if not meta_path.exists(): raise ValueError('缺少配置元信息：'+str(meta_path))
                metadata = read_json(meta_path)
            if not isinstance(cards,dict): raise ValueError('配置中的卡表必须是对象')
            if not isinstance(cards.get('_game'),dict) or not any(
                    not key.startswith('_') and isinstance(value,dict) and 'kind' in value
                    for key,value in cards.items()):
                raise ValueError('不是完整卡表：需要 _game 规则段和卡牌定义')
            if not isinstance(metadata,dict) or metadata.get('id') != path.stem:
                raise ValueError('配置元信息 ID 与文件名不一致')
            if not isinstance(metadata.get('name'),str) or not metadata['name'].strip():
                raise ValueError('配置元信息缺少名称')
            if legacy:
                # 元信息先写全，卡表后替换。中断时封装仍是恢复依据；再次启动可重试。
                atomic_json(meta_path,metadata)
                atomic_json(path,cards)
            return {**metadata,'cards':cards}
        except (OSError,ValueError,TypeError) as error:
            raise ValueError('读取或迁移配置失败：'+display_path(path,ROOT)+'；'+redact_paths(str(error),ROOT)) from error

    def configs(self):
        with self.lock:
            default_notes = self.store/'notes'/'default.json'
            result = [{'id':'default','name':'默认卡表','cards':self.base,'created':0,
                       'notes':read_json(default_notes) if default_notes.exists() else {'text':''}}]
            for p in sorted((self.store/'configs').glob('*.json')):
                c = self._read_saved_config(p)
                notes = self.store/'notes'/p.name
                c['notes'] = read_json(notes) if notes.exists() else {'text':''}
                result.append(c)
            return result

    def config(self,cid):
        return next((c for c in self.configs() if c['id']==cid),None)

    def save(self,body):
        with self.lock:
            return self._save(body)

    def _save(self,body):
        cards = validate_cards(body.get('cards'),self.base)
        name = body.get('name','')
        source_id = body.get('source_id')
        if not isinstance(name,str) or not name.strip() or len(name)>100: raise ValueError('配置名称须为1–100字')
        name = name.strip()
        source = self.config(source_id)
        if not source: raise ValueError('起点配置不存在，请刷新页面后重试')
        cards_changed = source['cards'] != cards
        name_changed = source['name'] != name
        if cards_changed != name_changed:
            if name_changed:
                raise ValueError('只修改了版本名称，卡牌参数没有变化；不能创建内容相同的新版本')
            raise ValueError('卡牌参数已修改，但版本名称没有变化；请填写新名称后再运行')
        if not cards_changed:
            reused = copy.deepcopy(source)
            reused['reused'] = True
            return reused
        same_name = [existing for existing in self.configs() if existing['name'] == name]
        if same_name:
            raise ValueError('配置名称“%s”已存在；新版本必须使用未占用的新名称' % name)
        imported_name = body.get('imported_name')
        source_file = body.get('source_file')
        if imported_name is not None and (not isinstance(imported_name,str) or not imported_name.strip()):
            raise ValueError('导入名称无效')
        if source_file is not None and (not isinstance(source_file,str) or not source_file.strip()):
            raise ValueError('导入文件名无效')
        obj = {'id':time.strftime('%Y%m%d-%H%M%S')+'-'+secrets.token_hex(4),'name':name,
               'cards':cards,'created':time.time(),'hash':digest(cards)}
        if imported_name is not None: obj['imported_name'] = imported_name.strip()
        if source_file is not None: obj['source_file'] = source_file.strip()
        atomic_json(self.store/'config_meta'/(obj['id']+'.json'),
                    {key:value for key,value in obj.items() if key != 'cards'})
        atomic_json(self.store/'configs'/(obj['id']+'.json'),cards)
        return obj

    def export(self,body):
        path = body.get('path')
        obj = body.get('obj')
        if not isinstance(path,str) or not path.strip(): raise ValueError('保存路径不能为空')
        target = Path(os.path.expanduser(path.strip())).resolve()
        if target.suffix.lower() != '.json': target = target.with_suffix('.json')
        if not target.parent.is_dir(): raise ValueError('保存目录不存在：'+display_path(target.parent,ROOT))
        # 仅接受合法完整卡表，避免此本地写入口被页面以外的内容滥用。
        clean = validate_cards(obj,self.base)
        atomic_json(target,clean)
        return {'path':display_path(target,ROOT)}

    def notes(self,body):
        cid = body.get('id')
        if not self.config(cid): raise ValueError('配置不存在，请先保存配置再记录试玩备注')
        text = body.get('text','')
        if not isinstance(text,str) or len(text)>10000: raise ValueError('备注最多10000字')
        obj = {'text':text,'updated':time.time()}
        with self.lock: atomic_json(self.store/'notes'/(cid+'.json'),obj)
        return obj

    def play(self,body):
        config = self.config(body.get('config_id'))
        if not config: raise ValueError('配置不存在，请先保存配置再试玩')
        cards = validate_cards(config['cards'],self.base)
        play_id = time.strftime('%Y%m%d-%H%M%S')+'-'+secrets.token_hex(4)
        folder = (self.store/'playtests'/play_id).resolve()
        folder.mkdir(parents=True)
        cards_path,log_path = folder/'cards.json',folder/'godot.log'
        atomic_json(cards_path,cards)
        # 直接运行当前项目源码；导出的 App 可能仍含旧卡牌加载逻辑。
        command = [self.godot,'--path','.','--','--cards-config='+relative_path(cards_path,ROOT)]
        proc,log_filter = None,None
        with log_path.open('w',encoding='utf-8') as log:
            try:
                proc = subprocess.Popen(command,cwd=str(ROOT),stdin=subprocess.DEVNULL,
                                        stdout=subprocess.PIPE,stderr=subprocess.STDOUT,shell=False,start_new_session=True)
                # 过滤器独立于工作台存活；先关工作台也不会留下继续写原始路径的试玩。
                log_filter = subprocess.Popen([sys.executable,'-u',str(Path(__file__).with_name('project_paths.py'))],
                                               cwd=str(ROOT),stdin=proc.stdout,stdout=log,stderr=subprocess.STDOUT,
                                               shell=False,start_new_session=True)
            except OSError as error:
                if proc is not None:
                    self._terminate(proc)
                    try: proc.wait(timeout=2)
                    except subprocess.TimeoutExpired: proc.kill();proc.wait()
                log.write(redact_paths(str(error),ROOT)+'\n')
                raise ValueError('无法启动试玩游戏：'+redact_paths(str(error),ROOT)+'；日志：'+display_path(log_path,ROOT)) from error
            finally:
                if proc is not None and proc.stdout is not None: proc.stdout.close()
        def ready():
            for line in log_path.read_text(encoding='utf-8',errors='replace').splitlines():
                if line.startswith('CARDS_CONFIG_READY: '):
                    loaded = Path(line.removeprefix('CARDS_CONFIG_READY: ')).expanduser()
                    if (ROOT/loaded).resolve() == cards_path: return True
            return False
        def reap_play():
            try: proc.wait()
            finally: log_filter.wait()
        deadline = time.monotonic()+PLAY_START_TIMEOUT
        try:
            while True:
                code = proc.poll()
                if code is not None:
                    raise ValueError('试玩游戏启动失败，进程已退出（状态码 %s）；日志：%s' % (code,display_path(log_path,ROOT)))
                if log_filter.poll() is not None:
                    raise ValueError('试玩日志过滤器已退出；日志：'+display_path(log_path,ROOT))
                if ready():
                    if proc.poll() is not None:
                        raise ValueError('试玩游戏加载卡表后退出；日志：'+display_path(log_path,ROOT))
                    # 试玩窗口独立存活；退出后回收进程，不混入模拟状态与停止按钮。
                    threading.Thread(target=reap_play,daemon=True).start()
                    return {'started':True,'config_id':config['id'],'name':config['name'],
                            'pid':proc.pid,'cards_path':display_path(cards_path,ROOT),'log_path':display_path(log_path,ROOT)}
                if time.monotonic() >= deadline:
                    raise ValueError('试玩游戏未能在20秒内完成卡表加载和开局；日志：'+display_path(log_path,ROOT))
                time.sleep(.1)
        except (OSError,ValueError) as error:
            if proc.poll() is None:
                proc.terminate()
                try: proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    proc.kill();proc.wait()
            try: log_filter.wait(timeout=2)
            except subprocess.TimeoutExpired:
                log_filter.terminate();log_filter.wait()
            raise ValueError(redact_paths(str(error),ROOT)) from error

    def runs(self):
        with self.lock:
            return [self.run(p.parent.name) for p in sorted((self.store/'runs').glob('*/run.json'),reverse=True)]

    def run_overview(self):
        with self.lock:
            return {'runs':self.runs(),'active_run_ids':list(self.jobs)}

    def run(self,rid):
        if not isinstance(rid,str) or not rid or any(c not in '0123456789abcdef-' for c in rid):
            raise ValueError('运行标识无效')
        folder = self.store/'runs'/rid
        obj = read_json(folder/'run.json')
        if isinstance(obj.get('error'),str): obj['error'] = redact_paths(obj['error'],ROOT)
        for key,file in [('result','result.json'),('progress','progress.json'),('recordings','recordings.json')]:
            if (folder/file).exists(): obj[key] = read_json(folder/file)
        return normalize_legacy(obj)

    def recording(self,rid,filename):
        run = self.run(rid)
        if run.get('kind') != 'bot-duel' or not any(item.get('file') == filename for item in run.get('recordings',[])):
            raise ValueError('录像不存在')
        folder = (self.store/'runs'/rid/'recordings').resolve()
        target = (folder/filename).resolve()
        if target.parent != folder or target.suffix != '.json' or not target.is_file():
            raise ValueError('录像路径无效')
        return target.read_bytes()

    def start_duel(self,body):
        raw = body.get('options')
        if not isinstance(raw,dict) or set(raw) != {'pairs','max_rounds','seed_start','a','b'}:
            raise ValueError('BOT对比参数字段不完整或含不支持字段')
        options = {key:raw[key] for key in ('pairs','max_rounds','seed_start')}
        for side in ('a','b'):
            profile = raw[side]
            if not isinstance(profile,dict) or set(profile) != {'strength','bot_parameters'}:
                raise ValueError('BOT对比配置须包含强度与全部可调参数：'+side)
            checked = validate_options({**{key:options[key] for key in ('pairs','max_rounds','seed_start')},
                'model':'bot','strength':profile['strength'],'bot_parameters':profile['bot_parameters']},self.schema)
            # Freeze the submitted values, including manual edits. Never reapply a preset here.
            options[side] = {'strength':checked['strength'],'model':'bot','bot_parameters':checked['bot_parameters']}
        return self.start(body,duel_options=options)

    def start(self,body,duel_options=None):
        config = self.config(body.get('config_id'))
        if not config: raise ValueError('配置不存在，请先保存')
        validate_cards(config['cards'],self.base)
        options = duel_options if duel_options is not None else validate_options(body.get('options'),self.schema)
        with self.lock:
            if self.closing: raise ValueError('工作台正在关闭，不能启动新模拟')
            rid = time.strftime('%Y%m%d-%H%M%S')+'-'+secrets.token_hex(4)
            folder = self.store/'runs'/rid
            folder.mkdir(parents=True)
            run = {'id':rid,'config_id':config['id'],'name':config['name'],'status':'queued','created':time.time(),
                   'cards':config['cards'],'options':options,'strength_scale':'overall-v1','engine_fingerprint':engine_fingerprint()}
            if duel_options is not None: run['kind'] = 'bot-duel'
            atomic_json(folder/'cards.json',config['cards'])
            atomic_json(folder/'request.json',{'schema':'manual-balance-request-v1','cards_path':relative_path(folder/'cards.json',ROOT),
                        'output_path':relative_path(folder/'result.json',ROOT),'progress_path':relative_path(folder/'progress.json',ROOT),'options':options})
            atomic_json(folder/'run.json',run)
            job = {'run':run,'folder':folder,'proc':None,'cancel':threading.Event()}
            job['thread'] = threading.Thread(target=self._worker,args=(job,),daemon=True)
            self.jobs[rid] = job
            try: job['thread'].start()
            except Exception as error:
                self._finish_job(job,error=str(error))
                raise ValueError('无法启动模拟：'+redact_paths(str(error),ROOT)) from error
            # 后台线程会更新自己的 run；响应不引用那个仍在变化的字典。
            return copy.deepcopy(run)

    @staticmethod
    def _terminate(proc):
        if proc is not None and proc.poll() is None:
            try: proc.terminate()
            except ProcessLookupError: pass

    def _worker(self,job):
        run,folder = job['run'],job['folder']
        proc,code,error = None,None,None
        try:
            with (folder/'godot.log').open('w',encoding='utf-8') as log:
                with self.lock:
                    if job['cancel'].is_set(): return
                    proc = subprocess.Popen([self.godot,'--headless','--path','.','--log-file',relative_path(folder/'engine.log',ROOT),'-s',('tools/bot_duel_report.gd' if run.get('kind') == 'bot-duel' else 'tools/eval_report.gd'),'--',relative_path(folder/'request.json',ROOT)],
                                            cwd=str(ROOT),stdout=log,stderr=subprocess.STDOUT)
                    job['proc'] = proc
                    run['status']='running'
                    run['pid']=proc.pid
                    atomic_json(folder/'run.json',run)
                while proc.poll() is None:
                    if job['cancel'].wait(.1):
                        self._terminate(proc)
                        try: proc.wait(timeout=4)
                        except subprocess.TimeoutExpired: proc.kill(); proc.wait()
                        break
                code = proc.wait()
        except Exception as failure:
            error = str(failure)
        finally:
            if proc is not None and proc.poll() is None:
                self._terminate(proc)
                try: proc.wait(timeout=4)
                except subprocess.TimeoutExpired: proc.kill(); proc.wait()
            with self.lock:
                self._finish_job(job,code,error)

    def _finish_job(self,job,code=None,error=None):
        """Finalize only this job under the lock; stop may already have finalized it."""
        run,folder = job['run'],job['folder']
        if self.jobs.get(run['id']) is not job: return
        try:
            for name in ('godot.log','engine.log'): sanitize_file(folder/name,ROOT)
            text = (folder/'godot.log').read_text(encoding='utf-8') if (folder/'godot.log').exists() else ''
            result = read_json(folder/'result.json') if (folder/'result.json').exists() else {}
            # 完整结果已成功落盘并正常退出时，稍晚到达的停止不能把成功改成取消。
            completed = error is None and code == 0 and result.get('status') == 'complete' \
                        and 'SCRIPT ERROR:' not in text and '\nERROR:' not in text
            if completed:
                if engine_fingerprint() != run['engine_fingerprint']:
                    run.update(status='error',error='模拟期间引擎或BOT配置改变，请重新运行，勿混用结果')
                else: run['status']='complete'
            elif job['cancel'].is_set(): run['status']='cancelled'
            else: run.update(status='error',error=error or text[-4000:] or json.dumps(result,ensure_ascii=False))
        except Exception as failure:
            run.update(status='cancelled' if job['cancel'].is_set() else 'error',error=str(failure))
        if isinstance(run.get('error'),str): run['error'] = redact_paths(run['error'],ROOT)
        run['finished']=time.time()
        try: atomic_json(folder/'run.json',run)
        finally: self.jobs.pop(run['id'],None)

    def stop(self,body):
        rid = body.get('run_id')
        if not isinstance(rid,str) or not rid or any(c not in '0123456789abcdef-' for c in rid):
            raise ValueError('必须提供有效的 run_id，停止只针对指定评估记录')
        with self.lock:
            path = self.store/'runs'/rid/'run.json'
            if not path.is_file(): raise ValueError('评估记录不存在：'+rid)
            job = self.jobs.get(rid)
            if job is None:
                return {'stopping':False,'run_id':rid,'status':read_json(path)['status']}
            proc = job['proc']
            if proc is not None and proc.poll() is not None:
                self._finish_job(job,proc.returncode)
                return {'stopping':False,'run_id':rid,'status':job['run']['status']}
            job['cancel'].set()
            run = job['run']
            run['status']='stopping'
            run.setdefault('stop_requested',time.time())
            atomic_json(path,run)
            self._terminate(proc)
            return {'stopping':True,'run_id':rid,'status':'stopping','pid':proc.pid if proc else None}

    def close(self):
        """Cancel and reap every simulation; independent play windows are not jobs."""
        with self.lock:
            self.closing = True
            jobs = list(self.jobs.values())
            for job in jobs:
                job['cancel'].set()
                self._terminate(job['proc'])
        for job in jobs:
            if job['thread'].ident is not None: job['thread'].join()
        self._file_lock.close()


class Handler(BaseHTTPRequestHandler):
    server_version = 'LocalBalance/1'
    def log_message(self,*args): pass

    def guard(self,write=False):
        expected = '127.0.0.1:'+str(self.server.server_port)
        if self.headers.get('Host') != expected: raise PermissionError('仅允许本机地址')
        origin = self.headers.get('Origin')
        if origin and origin != 'http://'+expected: raise PermissionError('拒绝跨站请求')
        if self.headers.get('Sec-Fetch-Site') == 'cross-site': raise PermissionError('拒绝跨站请求')
        if write and self.headers.get('X-Balance-Token') != self.server.token: raise PermissionError('请刷新页面后重试')

    def reply(self,obj,status=200,mime='application/json; charset=utf-8'):
        content = json.dumps(obj,ensure_ascii=False,allow_nan=False).encode() if not isinstance(obj,bytes) else obj
        self.send_response(status)
        self.send_header('Content-Type',mime)
        self.send_header('Content-Length',str(len(content)))
        self.send_header('Cache-Control','no-store')
        self.send_header('X-Content-Type-Options','nosniff')
        self.send_header('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")
        self.end_headers()
        try: self.wfile.write(content)
        except (BrokenPipeError,ConnectionResetError): pass

    def do_GET(self):
        try:
            self.guard()
            path = urlsplit(self.path).path
            app = self.server.app
            if path=='/api/bootstrap':
                self.reply({'token':self.server.token,'default_options':DEFAULT_OPTIONS,'definitions':DEFINITIONS,
                            'fields':mutable_fields(app.base),'labels':LABELS,'bot':app.metadata,
                            'configs':app.configs(),**app.run_overview()})
            elif path=='/api/runs': self.reply(app.run_overview())
            elif path=='/api/health': self.reply({'app':'manual-balance-v1','project':project_id(),'source_version':self.server.source_version,'pid':os.getpid()})
            elif path.startswith('/api/recording/'):
                parts = path.removeprefix('/api/recording/').split('/')
                if len(parts) != 2: raise ValueError('录像路径无效')
                self.reply(app.recording(parts[0],unquote(parts[1])))
            elif path.startswith('/api/run/'): self.reply(app.run(path.removeprefix('/api/run/')))
            elif path.startswith('/assets/art/icon/'):
                name = Path(path).name
                target = (ROOT/'assets/art/icon'/name).resolve()
                icon_dir = (ROOT/'assets/art/icon').resolve()
                if target.parent != icon_dir or not target.is_file():
                    self.reply({'error':'找不到卡牌图标'},404)
                else:
                    self.reply(target.read_bytes(),mime='image/png')
            elif path in ('/','/report.js','/report.css'):
                file = 'report.html' if path=='/' else path[1:]
                mime = {'report.html':'text/html; charset=utf-8','report.js':'text/javascript; charset=utf-8','report.css':'text/css; charset=utf-8'}[file]
                self.reply((WEB/file).read_bytes(),mime=mime)
            else: self.reply({'error':'找不到页面'},404)
        except PermissionError as e: self.reply({'error':redact_paths(str(e),ROOT)},403)
        except (ValueError,OSError,KeyError) as e: self.reply({'error':redact_paths(str(e),ROOT)},400)

    def do_POST(self):
        try:
            self.guard(True)
            size = int(self.headers.get('Content-Length','0'))
            if not 0 < size <= 2_000_000: raise ValueError('请求大小无效（上限2MB）')
            if self.headers.get_content_type()!='application/json': raise ValueError('仅接受JSON请求')
            body = json.loads(self.rfile.read(size),parse_constant=lambda s: (_ for _ in ()).throw(ValueError('不接受非有限数值')))
            if not isinstance(body,dict): raise ValueError('请求必须是对象')
            app = self.server.app
            path = urlsplit(self.path).path
            if path=='/api/profile':
                result=app.profile(body.get('strength'))
                result['token']=self.server.token
                self.reply(result)
                return
            else:
                routes = {'/api/config':app.save,'/api/notes':app.notes,'/api/run':app.start,'/api/play':app.play,
                          '/api/stop':app.stop,'/api/export':app.export,'/api/duel':app.start_duel}
                action = routes.get(path)
                if not action: self.reply({'error':'接口不存在'},404); return
                self.reply(action(body))
        except PermissionError as e: self.reply({'error':redact_paths(str(e),ROOT)},403)
        except (ValueError,OSError,KeyError,TypeError) as e: self.reply({'error':redact_paths(str(e),ROOT)},400)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--port',type=int,default=29861)
    p.add_argument('--store',type=Path,default=DEFAULT_STORE)
    p.add_argument('--godot',default=os.environ.get('GODOT','/Applications/Godot.app/Contents/MacOS/Godot'))
    p.add_argument('--open',action='store_true',help='启动后打开默认浏览器')
    args = p.parse_args()
    if not Path(args.godot).is_file(): p.error('找不到Godot，请设置GODOT为可执行文件路径')
    url = 'http://127.0.0.1:'+str(args.port)+'/'
    current_version = source_version()
    # 重复双击只复用完全相同源码版本；旧版本服务必须显式退出后再启动。
    if args.open:
        import urllib.request
        try:
            existing=json.loads(urllib.request.urlopen(url+'api/health',timeout=1).read())
            if (existing.get('app')=='manual-balance-v1' and existing.get('project')==project_id()
                    and existing.get('source_version')==current_version):
                import webbrowser
                webbrowser.open(url)
                print('已打开现有工作台：'+url,flush=True)
                return
            if existing.get('app')=='manual-balance-v1' and same_project(existing.get('project')):
                p.error('检测到旧版本工作台仍占用端口。请关闭旧工作台终端后重新双击启动；不能继续复用旧代码。')
        except (OSError,ValueError): pass
    try:
        app = Workbench(args.store.resolve(),args.godot)
        server = ThreadingHTTPServer(('127.0.0.1',args.port),Handler)
    except (ValueError,OSError) as e: p.error(redact_paths(str(e),ROOT))
    server.app,server.token,server.source_version = app,secrets.token_urlsafe(32),current_version
    print('手动调参工作台 '+url,flush=True)
    print('数据目录：'+display_path(app.store,ROOT)+'；关闭此终端将停止服务。',flush=True)
    if args.open:
        import webbrowser
        webbrowser.open(url)
    def interrupted(_signum,_frame): raise KeyboardInterrupt
    exit_signals = [signal.SIGINT,signal.SIGTERM,signal.SIGHUP]
    for signum in exit_signals: signal.signal(signum,interrupted)
    try: server.serve_forever()
    except KeyboardInterrupt: pass
    finally:
        # 清理期间重复退出信号不能打断子进程回收和结果落盘。
        for signum in exit_signals: signal.signal(signum,signal.SIG_IGN)
        app.close()
        server.server_close()

if __name__=='__main__': main()
