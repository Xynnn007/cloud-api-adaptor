# cloud-api-adaptor（专有云适配版）

本仓库基于 [Confidential Containers cloud-api-adaptor](https://github.com/confidential-containers/cloud-api-adaptor) v0.22.0，针对 **专有云** 做了以下适配：

- **Pod VM 镜像**：基于 Alibaba Cloud Linux 3（alinux3）构建，而非上游 Ubuntu/mkosi 路径
- **user-data 格式**：支持 script 脚本下发（专有云 环境不使用 cloud-init `write_files`）
- **二进制来源**：kata-agent / peerpods 组件源码编译；AA / CDH / ASR 使用 [inclavare-containers/guest-components](https://github.com/inclavare-containers/guest-components) **musl 静态**编译（AA 仅开启 `csv-attester` + `hygon-dcu-attester`）

## 文档

| 文档 | 说明 |
|------|------|
| [docs/architecture.md](./docs/architecture.md) | 专有云 架构、组件清单、适配要点；含 [架构图 SVG](./docs/architecture-private-cloud-podvm.svg) |
| [docs/deployment.md](./docs/deployment.md) | 集群部署 CAA、Trustee、Peer Pod 与远程证明 |
| [docs/development.md](./docs/development.md) | 构建机、Pod VM / CAA 镜像构建、IMAGEID、FAQ |
| [docs/architecture-upstream.md](./docs/architecture-upstream.md) | 上游 Peer Pods 通用架构说明 |

## 目录结构

| 路径 | 说明 |
|------|------|
| `src/cloud-api-adaptor/` | Cloud API Adaptor（CAA）主程序及 Helm Chart |
| `src/cloud-providers/` | 云 Provider 实现（含 alibabacloud） |
| `src/cloud-api-adaptor/podvm/` | Pod VM 镜像构建（含 alinux3 路径） |
| `src/peerpod-ctrl/` | PeerPod 资源清理控制器 |
| `src/webhook/` | Peer Pod 调度 Mutating Webhook |
| `work/podvm-alinux3-tree/` | 手工叠加到 alinux3 的 Pod VM 目录树（含已构建二进制，通常不入库） |
| `work/build-artifacts/` | AA/CDH/ASR 等构建产物与脚本 |

## 快速开始

```bash
# 构建（开发侧）
cd src/cloud-api-adaptor/podvm && make image-alinux3
cd src/cloud-api-adaptor && make image
```

- 构建 / IMAGEID：见 [docs/development.md](./docs/development.md)  
- 集群部署与跑 Pod：见 [docs/deployment.md](./docs/deployment.md)

## 许可证

本项目使用 [Apache 2.0](./LICENSE) 许可证。贡献需遵循 [DCO 1.1](./DCO1.1.txt) 流程。
