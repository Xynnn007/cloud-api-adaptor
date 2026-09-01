# cloud-api-adaptor（专有云适配版）

本仓库基于 [Confidential Containers cloud-api-adaptor](https://github.com/confidential-containers/cloud-api-adaptor) v0.22.0，针对 **专有云** 做了以下适配：

- **Pod VM 镜像**：基于 Alibaba Cloud Linux 3（alinux3）构建，而非上游 Ubuntu/mkosi 路径
- **user-data 格式**：支持 script 脚本下发（专有云 环境不使用 cloud-init `write_files`）
- **二进制来源**：kata-agent 从源码编译；AA / CDH / ASR 从 alinux3 yum 安装

架构说明见上游 [architecture documentation](./docs/architecture.md)。

---

## 目录结构

| 路径 | 说明 |
|------|------|
| `src/cloud-api-adaptor/` | Cloud API Adaptor（CAA）主程序及 Helm Chart |
| `src/cloud-providers/` | 云 Provider 实现（含 alibabacloud） |
| `src/cloud-api-adaptor/podvm/` | Pod VM 镜像构建（含 alinux3 路径） |
| `src/peerpod-ctrl/` | PeerPod 资源清理控制器 |
| `src/webhook/` | Peer Pod 调度 Mutating Webhook |

---

## 构建全流程

整体顺序：**准备构建机 → 构建 Pod VM 镜像 → 构建 CAA 镜像 → 部署到集群**。

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────┐     ┌──────────────┐
│  构建机准备  │ ──▶ │  make image-alinux3 │ ──▶ │  make image  │ ──▶ │ Helm 部署 CAA │
│ Docker/代理  │     │  Pod VM qcow2     │     │  CAA 容器镜像 │     │ + 上传 Pod VM │
└─────────────┘     └──────────────────┘     └─────────────┘     └──────────────┘
```

### 1. 构建机环境准备

**必需依赖：**

| 工具 | 用途 |
|------|------|
| Docker（含 buildx） | 构建 Pod VM overlay 与 customizer 容器 |
| `make` | 驱动 Makefile |
| `yq` v4 | 解析 `versions.yaml` |
| `curl` | 下载 base qcow2 |
| `git` | kata-agent 源码克隆 |

安装 yq 并加入 docker 组（需 sudo）：

```bash
sudo yum install -y docker
sudo systemctl enable --now docker
sudo curl -fsSL -o /usr/local/bin/yq \
  https://github.com/mikefarah/yq/releases/download/v4.35.1/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq
sudo usermod -aG docker "$USER"
newgrp docker   # 或重新登录
```

验证：

```bash
docker info
yq --version
```

### 2. 配置网络代理（构建机需翻墙时）

Docker 不能直接使用 SOCKS5，需先转为本地 HTTP 代理（privoxy）：

```bash
# 1) 启动 SOCKS5 隧道（示例：SSH 动态转发）
ssh -qTfnNg -D localhost:5432 user@jump-host

# 2) 安装 privoxy，将 SOCKS5 转为 HTTP（需 sudo）
sudo yum install -y privoxy
sudo tee /etc/privoxy/config <<'EOF'
listen-address 127.0.0.1:8118
listen-address 172.17.0.1:8118
forward-socks5 / 127.0.0.1:5432 .
EOF
sudo systemctl enable --now privoxy

# 3) 配置 Docker daemon 代理（需 sudo）
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf <<'EOF'
[Service]
Environment="HTTP_PROXY=http://172.17.0.1:8118"
Environment="HTTPS_PROXY=http://172.17.0.1:8118"
Environment="NO_PROXY=localhost,127.0.0.1,.aliyun.com,.alibaba-inc.com,alibaba-cloud-linux-3-registry.cn-hangzhou.cr.aliyuncs.com,koji.alibaba-inc.com,mirrors.aliyun.com"
EOF
sudo systemctl daemon-reload && sudo systemctl restart docker
```

构建前导出代理环境变量：

```bash
export HTTP_PROXY=http://127.0.0.1:8118
export HTTPS_PROXY=http://127.0.0.1:8118
export http_proxy="$HTTP_PROXY" https_proxy="$HTTPS_PROXY"
export NO_PROXY=localhost,127.0.0.1,.aliyun.com,.alibaba-inc.com,alibaba-cloud-linux-3-registry.cn-hangzhou.cr.aliyuncs.com,koji.alibaba-inc.com,mirrors.aliyun.com
export no_proxy="$NO_PROXY"
export GOPROXY=https://goproxy.cn,direct
```

### 3. 构建 Pod VM 镜像（alinux3）

Base 镜像来自 Koji（已在 `versions.yaml` 中配置）：

```text
https://koji.alibaba-inc.com/kojifiles/product/alinux-3.2104-U12P-GA/x86_64/aliyun_3_x64_20G_pro_alibase_20250425.qcow2
```

**一条命令完成**（下载 base qcow2 → 构建二进制 overlay → virt-customize 注入 → 输出 qcow2）：

```bash
cd src/cloud-api-adaptor/podvm
make image-alinux3
```

构建分两个阶段（`make image-alinux3` 自动串联）：

| 阶段 | Make 目标 | 说明 |
|------|-----------|------|
| 1 | `podvm-binaries-alinux3` | 在 alinux3 容器内编译 CAA 二进制、kata-agent（源码）、yum 安装 AA/CDH/ASR，拉取 pause bundle |
| 2 | `image-alinux3` | 下载 Koji base qcow2，用 libguestfs 注入 overlay，更新 GRUB/SELinux，压缩输出 |

**产物路径：**

```text
src/cloud-api-adaptor/podvm/build-alinux3/output/podvm-alinux3-amd64.qcow2
```

仅重做 qcow2 定制（overlay 和 base 已存在时）：

```bash
make image-alinux3-customize
```

清理：

```bash
make clean   # 删除 build/、build-alinux3/、resources/binaries-tree/
```

**可选 Make 变量：**

```bash
make image-alinux3 \
  ALINUX3_BUILDER_IMAGE=alibaba-cloud-linux-3-registry.cn-hangzhou.cr.aliyuncs.com/alinux3/alinux3:latest
```

### 4. 构建 CAA 容器镜像

```bash
cd src/cloud-api-adaptor
make image
```

默认构建 dev 版（含 libvirt provider）。发布版：

```bash
make image RELEASE_BUILD=true
```

产物为本地 Docker 镜像，tag 由 Makefile 决定。也可只编译二进制：

```bash
make build   # 生成 cloud-api-adaptor、agent-protocol-forwarder、process-user-data
```

### 5. 上传 Pod VM 镜像并部署 CAA

1. 将 `podvm-alinux3-amd64.qcow2` 上传至专有云，获取 **IMAGEID**（VHD/qcow2 镜像 ID）
2. 编辑 `src/cloud-api-adaptor/install/charts/peerpods/providers/alibabacloud.yaml`，填入 region、vswitch、security group、IMAGEID 等
3. 使用 Helm 部署（参见 `src/cloud-api-adaptor/install/` 目录）

**专有云 关键配置项**（已在 `alibabacloud.yaml` 中预置，部署前核对）：

```yaml
USER_DATA_FORMAT: "script"          # user-data 以 bash 脚本下发
CONFIDENTIAL_COMPUTING_MODE: "CSV" # Hygon CSV 机密 VM
DISABLECVM: "true"
REGION: "cn-wulan-env213-d01"
ECS_ENDPOINT: "ecs-internal.inter.env213.shuguang.com"
VPC_ENDPOINT: "vpc-internal.inter.env213.shuguang.com"
IMAGEID: "<上传后的 Pod VM 镜像 ID>"
```

`USER_DATA_FORMAT=script` 通过 `peer-pods-cm` ConfigMap 注入 CAA，**无需修改 DaemonSet 模板**。

---

## 专有云 适配要点

| 模块 | 上游行为 | 专有云 适配 |
|------|----------|-----------|
| Pod VM 基础 OS | Ubuntu + mkosi | alinux3 Koji base qcow2 + virt-customize |
| kata-agent | oras 拉 OCI 预编译包 | 从 kata-containers 源码编译 |
| guest-components | oras 拉 OCI 预编译包 | yum 安装 attestation-agent / confidential-data-hub / trustiflux-api-server |
| user-data | `#cloud-config` write_files | bash 脚本（`USER_DATA_FORMAT=script`） |
| initdata 解压 | process-user-data | 不变，脚本写入 `/run/peerpod/initdata` 后照常解压 |

---

## 常见问题

**`permission denied` 访问 Docker**

```bash
sudo usermod -aG docker "$USER" && newgrp docker
# 或临时：sudo chmod 666 /var/run/docker.sock
```

**`newgrp docker` 报 `__vsc_prompt_cmd_original: command not found`**

Cursor 终端集成问题，可忽略；或在 `~/.bashrc` 开头清除残留的 `PROMPT_COMMAND=__vsc_*`。

**`virt-customize` / supermin 失败**

customizer 镜像已包含 `linux-image-virtual` 并挂载 `/dev`、`/boot`、`/lib/modules`。确认 Docker 以 `--privileged` 运行（Makefile 已配置）。

**构建目录权限问题**

若 `build-alinux3/` 属主为 root，删除或移走后再构建：

```bash
mv build-alinux3 build-alinux3.stale && mkdir build-alinux3
```

---

## 许可证

本项目使用 [Apache 2.0](./LICENSE) 许可证。贡献需遵循 [DCO 1.1](./DCO1.1.txt) 流程。
