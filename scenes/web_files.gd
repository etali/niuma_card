# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends Node

## 浏览器文件边界：设备文件通过 FileReader 导入私有存储，导出走真实下载。
## 回调保留到浏览器完成；切场景时取消输入和读取，避免回调访问已释放场景。
const Store = preload("res://engine/json_store.gd")
const MAX_IMPORT_BYTES := 64 * 1024 * 1024
const BRIDGE_SOURCE := """
window.niumaFiles = {
  cancel() {
    if (this.input) { this.input.remove(); this.input = null; }
    if (this.reader) {
      this.reader.onload = this.reader.onerror = null;
      if (this.reader.readyState === 1) this.reader.abort();
      this.reader = null;
    }
  },
  pick(callback, limit) {
    this.cancel();
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = '.json,application/json';
    input.style.display = 'none';
    document.body.appendChild(input);
    this.input = input;
    const finish = (name, text, error) => {
      if (this.input !== input) return;
      this.cancel();
      callback(name, text, error);
    };
    input.addEventListener('cancel', () => finish('', '', 'cancelled'), {once: true});
    input.addEventListener('change', () => {
      if (this.input !== input) return;
      const file = input.files[0];
      if (!file) { finish('', '', 'cancelled'); return; }
      if (file.size > limit) { finish(file.name, '', '文件超过 64 MB，无法导入。'); return; }
      const reader = new FileReader();
      this.reader = reader;
      reader.onload = () => finish(file.name, String(reader.result), '');
      reader.onerror = () => finish(file.name, '', '浏览器无法读取此文件，请重新选择。');
      reader.readAsText(file);
    }, {once: true});
    input.click();
  }
};
"""

## 可替换浏览器边界供无头回归；业务读写仍走同一条导入/导出实现。
var request_backend := Callable()
var download_backend := Callable()
var _receiver := Callable()
var _js: Object
var _browser: Object
var _callback: Object

func _ready() -> void:
	if not OS.has_feature("web") or not Engine.has_singleton("JavaScriptBridge"):
		return
	_js = Engine.get_singleton("JavaScriptBridge")
	_js.eval(BRIDGE_SOURCE, true)
	_browser = _js.get_interface("niumaFiles")
	_callback = _js.create_callback(_on_browser_file)

func request_json(receiver: Callable) -> void:
	if _receiver.is_valid():
		receiver.call({"ok": false, "reason": "请先完成或取消当前文件选择。"})
		return
	_receiver = receiver
	if request_backend.is_valid():
		request_backend.call(_on_browser_file)
	elif _browser != null:
		_browser.pick(_callback, MAX_IMPORT_BYTES)
	else:
		_deliver({"ok": false, "reason": "浏览器文件选择不可用。"})

func _on_browser_file(args: Array) -> void:
	if not _receiver.is_valid():
		return
	if args.size() != 3 or not args[0] is String or not args[1] is String or not args[2] is String:
		_deliver({"ok": false, "reason": "浏览器返回的文件信息无效。"})
		return
	if args[2] != "":
		_deliver({"ok": false, "cancelled": args[2] == "cancelled", "reason": args[2]})
		return
	_deliver(import_json(args[0], args[1]))

static func import_json(filename: String, text: String) -> Dictionary:
	if text.to_utf8_buffer().size() > MAX_IMPORT_BYTES:
		return {"ok": false, "reason": "文件超过 64 MB，无法导入。"}
	var name := filename.get_file().validate_filename()
	if name.get_extension().to_lower() != "json":
		return {"ok": false, "reason": "请选择 JSON 文件。"}
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		return {"ok": false, "reason": "文件不是有效的 JSON 对象。"}
	# 同名的不同配置互不覆盖，当前对局下一次加载仍读原来选择的内容。
	var path := "user://imports/".path_join(text.sha256_text()).path_join(name)
	if not Store.save(path, json.data):
		return {"ok": false, "reason": "浏览器存储不可写，未导入文件。"}
	return {"ok": true, "path": ProjectSettings.globalize_path(path), "name": name}

func _deliver(result: Dictionary) -> void:
	var receiver := _receiver
	_receiver = Callable()
	if receiver.is_valid():
		receiver.call(result)

func download_json(value: Dictionary, filename: String) -> bool:
	var bytes := JSON.stringify(value, "  ", false).to_utf8_buffer()
	if download_backend.is_valid():
		return bool(download_backend.call(bytes, filename, "application/json"))
	if _js == null:
		return false
	_js.download_buffer(bytes, filename, "application/json")
	return true

func _exit_tree() -> void:
	_receiver = Callable()
	if _browser != null:
		_browser.cancel()
	_callback = null
	_browser = null
