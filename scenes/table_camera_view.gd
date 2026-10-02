# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 只改变观察镜头。牌位、碰撞、牌桌边界和规则状态均保持原值。
const Fit = preload("res://scenes/drawer_camera_fit.gd")
const MIN_ZOOM := 1.0
const MAX_ZOOM := 2.5
var camera: Camera3D
var overview: Dictionary = {}
var content := Rect2()
var world := Rect2()
var zoom := MIN_ZOOM
var offset := Vector3.ZERO

func configure(target: Camera3D, fitted: Dictionary, area: Rect2, world_rect: Rect2) -> void:
	camera = target
	overview = fitted
	content = area
	world = world_rect
	_apply()
	_limit()

func _point(pixel: Vector2) -> Vector3:
	var ray := camera.project_ray_normal(pixel)
	var origin := camera.project_ray_origin(pixel)
	return origin - ray * origin.y / ray.y if absf(ray.y) > 0.0001 else Vector3.INF

func change(value: float, previous: Vector2, current: Vector2) -> void:
	if camera == null or overview.is_empty():
		return
	var before := _point(previous)
	zoom = clampf(value, MIN_ZOOM, MAX_ZOOM)
	_apply()
	var after := _point(current)
	if before != Vector3.INF and after != Vector3.INF:
		offset += before - after
	_apply()
	_limit()

func reset() -> void:
	zoom = MIN_ZOOM
	offset = Vector3.ZERO
	_apply()

func _apply() -> void:
	if camera == null or overview.is_empty():
		return
	Fit.apply(camera, overview)
	camera.fov = rad_to_deg(2.0 * atan(tan(deg_to_rad(float(overview["fov"])) * 0.5) / zoom))
	camera.position += offset

func _limit() -> void:
	if is_equal_approx(zoom, MIN_ZOOM):
		offset = Vector3.ZERO
	else:
		var half := world.size * (0.5 * (1.0 - 1.0 / zoom))
		offset.x = clampf(offset.x, -half.x, half.x)
		offset.z = clampf(offset.z, -half.y, half.y)
	_apply()
