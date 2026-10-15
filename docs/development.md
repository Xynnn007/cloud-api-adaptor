# 专有云开发与构建

本文覆盖构建机准备、Pod VM / CAA 镜像构建、本机组件编译等**开发侧**步骤。集群侧部署与跑 Pod 见 [deployment.md](./deployment.md)；架构见 [architecture.md](./architecture.md)。

整体顺序：**准备构建机 → 构建 Pod VM 镜像 → 构建 CAA 镜像 →（上传 IMAGEID 后）按 deployment 部署**。

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────┐     ┌──────────────┐
│  构建机准备  │ ──▶ │  make image-alinux3 │ ──▶ │  make image  │ ──▶ │ 见 deployment │
│ Docker/代理  │     │  Pod VM qcow2     │     │  CAA 容器镜像 │     │ 部署 CAA/Pod  │
└─────────────┘     └──────────────────┘     └─────────────┘     └──────────────┘
```

---

## 1. 构建机环境准备

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

---

## 2. 配置网络代理（构建机需翻墙时）

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

---

## 3. 本机构建 Pod VM 组件（可选）

一条命令可生成与 Pod VM 根目录相同布局的叠加层，并打包为
`_output/podvm-alinux3-tree.tar.gz`：

```bash
cd src/cloud-api-adaptor/podvm
make podvm-alinux3-tree
```

kata-agent、guest-components、alinux3 构建镜像及运行时 RPM 的版本统一定义在
`src/cloud-api-adaptor/versions.yaml`。

也可以分步构建：

```bash
# 1) peerpods Go 组件
cd src/cloud-api-adaptor && CGO_ENABLED=0 make agent-protocol-forwarder process-user-data

# 2) kata-agent（本地 kata-containers 仓库）
./podvm/hack/build-kata-agent-musl.sh /path/to/kata-containers ./files/usr/local/bin/kata-agent

# 3) AA / CDH / ASR（inclavare musl 静态）
#    推荐：Ubuntu + musl-tools
#    产物示例：work/build-artifacts/{attestation-agent,confidential-data-hub,api-server-rest}
./podvm/hack/build-aa-cdh-asr-musl.sh

# 4) 汇总到可拷贝目录树
./podvm/hack/assemble-podvm-alinux3-tree.sh
# 产物：work/podvm-alinux3-tree/
```

### GitHub Actions 产物

`.github/workflows/podvm_alinux3_tree.yaml` 支持两种触发方式：

- 推送 tag：构建 tar 包，并创建或复用同名 GitHub Release 上传产物。
- 手动运行：不创建 Release，只保存 14 天的 Actions artifact，供测试下载。

### 拷贝到运行中的 alinux3 实例后 enable

将 `work/podvm-alinux3-tree/` 中的 `etc/`、`usr/`、`pause_bundle/` 拷到 guest 根文件系统后执行：

```bash
systemctl daemon-reload

systemctl enable process-user-data.service
systemctl enable setup-nat-for-imds.service
systemctl enable scratch-storage.service
systemctl enable 'run-kata\x2dcontainers.mount'
systemctl enable agent-protocol-forwarder.service
systemctl enable attestation-agent.path
systemctl enable confidential-data-hub.path
systemctl enable kata-agent.path
systemctl enable api-server-rest.path

# pause image 权限
chmod -R 0777 /pause_bundle

# guest 收尾（SELinux/GRUB/peerpod 等）；--skip-yum 跳过装包
# 源文件：src/cloud-api-adaptor/podvm/hack/guest-setup.sh
# 注意：sudo 会清掉环境变量，请用 --skip-yum 而不是 GUEST_PKGS=
./guest-setup.sh --skip-yum
```

也可一条命令 enable：

```bash
systemctl daemon-reload
systemctl enable \
  process-user-data.service \
  setup-nat-for-imds.service \
  scratch-storage.service \
  'run-kata\x2dcontainers.mount' \
  agent-protocol-forwarder.service \
  attestation-agent.path \
  confidential-data-hub.path \
  kata-agent.path \
  api-server-rest.path
```

enable 完成后打快照即可作为 Pod VM 镜像。

---

## 4. 构建 Pod VM 镜像（alinux3）

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
| 1 | `podvm-binaries-alinux3` | 在容器内编译 CAA 二进制、kata-agent（**musl 静态**）；AA/CDH/ASR 建议改用 inclavare musl 静态产物（见 [architecture.md](./architecture.md)），拉取 pause bundle |
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

上传 qcow2 到专有云并取得 **IMAGEID** 后，在 Helm provider 配置中填写（见下文「上传镜像与 provider 配置」及 [deployment.md](./deployment.md)）。

---

## 5. 构建 CAA 容器镜像

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

---

## 6. 上传 Pod VM 镜像与 provider 配置

1. 将 `podvm-alinux3-amd64.qcow2` 上传至专有云，获取 **IMAGEID**
2. 编辑 `src/cloud-api-adaptor/install/charts/peerpods/providers/alibabacloud.yaml`，填入 region、vswitch、security group、IMAGEID 等

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

`USER_DATA_FORMAT=script` 通过 `peer-pods-cm` ConfigMap 注入 CAA，**无需修改 DaemonSet 模板**。集群侧安装步骤见 [deployment.md](./deployment.md)。

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
