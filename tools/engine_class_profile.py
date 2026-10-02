# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""保守类级裁剪：只裁已核对用途的节点族，保留项目用到的类及其整个父类链。"""
# 不裁Control、窗口、文本、物理服务器、材质、导入纹理或引擎内部资源基类。
CANDIDATE_ROOTS = (
    'AnimationMixer', 'AnimationNode', 'Animation', 'AnimationLibrary',
    'Skeleton3D', 'SkeletonModifier3D', 'BoneAttachment3D', 'BoneMap', 'SkeletonProfile',
    'Skeleton2D', 'SkeletonModification2D', 'SkeletonModificationStack2D', 'Bone2D',
    'Sprite2D', 'AnimatedSprite2D', 'AnimatedSprite3D', 'SpriteFrames',
    'TileMap', 'TileMapLayer', 'TileSet', 'TileMapPattern', 'TileData', 'TileSetSource',
    'Polygon2D', 'Line2D', 'Path2D', 'PathFollow2D', 'Path3D', 'PathFollow3D',
    'GPUParticles2D', 'GPUParticles3D', 'GPUParticlesAttractor3D', 'GPUParticlesCollision3D',
    'CPUParticles2D', 'GPUParticlesCollisionSDF3D',
    'VehicleBody3D', 'VehicleWheel3D', 'Joint3D', 'SpringArm3D', 'PhysicalBone3D',
    'AudioStreamPlayer2D', 'AudioStreamPlayer3D', 'VideoStreamPlayer',
    'GraphElement', 'GraphEdit',
)


def disabled_classes(capabilities, used_classes, keep_classes=()):
    parents = capabilities['classes']
    protected = set(used_classes) | set(keep_classes)
    for name in list(protected):
        while (parent := parents.get(name)):
            protected.add(parent)
            name = parent
    roots = {name for name in CANDIDATE_ROOTS if name in parents and name not in protected}
    disabled = set()
    for name in parents:
        current = name
        while current:
            if current in roots:
                disabled.add(name)
                break
            current = parents.get(current)
    return sorted(disabled - protected)
