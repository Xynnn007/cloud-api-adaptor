#!/bin/bash

# ================= 配置区 =================
# 源镜像仓库地址前缀 (例如: docker.io/library 或 registry.cn-hangzhou.aliyuncs.com/zhengqing)
# 如果源镜像是官方镜像且不带前缀，请留空 ""
SOURCE_REGISTRY_PREFIX="registry-cn-hangzhou.ack.aliyuncs.com/dev"

# 目标私有仓库地址前缀 (例如: registry.acs.intra.env213.shuguang.com/acs)
TARGET_REGISTRY_PREFIX="registry.acs.intra.env213.shuguang.com/acs"

# 镜像清单文件路径
IMAGE_LIST="images.txt"
# =========================================

# 检查清单文件是否存在
if [ ! -f "$IMAGE_LIST" ]; then
    echo "❌ 错误: 找不到镜像清单文件 $IMAGE_LIST，请先创建。"
    exit 1
fi

# 循环读取镜像列表并处理
while IFS= read -r IMAGE; do
    # 跳过空行和注释行
    if [[ -z "$IMAGE" || "$IMAGE" =~ ^# ]]; then
        continue
    fi

    # 提取镜像名和标签
    IMAGE_NAME=$(echo "$IMAGE" | cut -d':' -f1)
    TAG=$(echo "$IMAGE" | cut -d':' -f2)
    
    # 拼接源镜像完整地址
    if [ -n "$SOURCE_REGISTRY_PREFIX" ]; then
        SOURCE_IMAGE="${SOURCE_REGISTRY_PREFIX}/${IMAGE_NAME}:${TAG}"
    else
        SOURCE_IMAGE="${IMAGE_NAME}:${TAG}"
    fi

    # 拼接目标镜像完整地址
    TARGET_IMAGE="${TARGET_REGISTRY_PREFIX}/${IMAGE_NAME}:${TAG}"

    echo "-----------------------------------"
    echo "[1/4] 正在拉取镜像: $SOURCE_IMAGE"
    if ! docker pull --platform linux/amd64 "$SOURCE_IMAGE"; then
        echo "❌ 错误: 拉取镜像 $SOURCE_IMAGE 失败，跳过该镜像。"
        continue
    fi

    echo "[2/4] 正在打标签: $TARGET_IMAGE"
    docker tag "$SOURCE_IMAGE" "$TARGET_IMAGE"

    echo "[3/4] 正在推送镜像: $TARGET_IMAGE"
    if ! docker push "$TARGET_IMAGE"; then
        echo "❌ 错误: 推送镜像 $TARGET_IMAGE 失败，跳过清理步骤。"
        continue
    fi

    echo "[4/4] 正在清理本地临时标签..."
    docker rmi "$TARGET_IMAGE"
    
    echo "✅ 镜像 $IMAGE 迁移完成！"

done < "$IMAGE_LIST"

echo "==================================="
echo "🎉 所有镜像处理完毕！"
