# 专有云部署指南

本文说明在 ACK 集群中部署 **CAA DaemonSet**，以及如何创建带远程证明 initdata 的 Peer Pod。  
镜像构建、IMAGEID / Helm provider 配置等开发侧步骤见 [development.md](./development.md)。

---

## 1. 在集群中部署 CAA DaemonSet

CAA 部署分三步：**配置 RRSA**（授予 CAA 调用 ECS / VPC API 的权限）→ **部署 cert-manager**（CAA Webhook 证书的前置依赖）→ **Helm Chart 安装 peerpods**（含 CAA DaemonSet、kata-deploy、peerpod-ctrl、webhook）。

前置条件（开发侧完成后）：

- Pod VM 镜像已上传，`IMAGEID` 已写入 `alibabacloud.yaml`（见 [development.md](./development.md) §6）
- CAA 及依赖镜像（cert-manager 三件套、cloud-api-adaptor、peerpod-ctrl、webhook、kata-deploy、kube-rbac-proxy 等）**均已构建/备份在专有云内网 registry** `registry.acs.intra.env213.shuguang.com/acs`（构建见 [development.md](./development.md) §5）。部署到其他专有云环境时，请先将这些镜像 mirror 到目标 registry，完整清单与同步方法见 §1.5
- `kata-remote` RuntimeClass 无需单独安装：与公有云一致，随 Helm Chart（kata-deploy 子 chart）一并安装，验证与排查见 §1.4

以下命令除特别说明外，均在本仓库 `src/cloud-api-adaptor/install/charts/peerpods/` 目录下执行。

### 1.1 配置 RRSA 与 RAM 角色

1. 在专有云控制台的集群基本信息页点击 **启用 RRSA**，记录页面上显示的 **提供商 ARN**（后续写入 Secret）。

2. 在 **企业 → 权限管理 → 权限策略** 中创建名为 `ack-caa-policy` 的 RAM 权限策略，授予 ECS 和 VPC 的操作权限：

```json
{
  "Version": "1",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecs:RunInstances",
        "ecs:DeleteInstance",
        "ecs:DescribeInstanceAttribute",
        "ecs:CreateNetworkInterface",
        "ecs:DeleteNetworkInterface",
        "ecs:AttachNetworkInterface",
        "ecs:ModifyNetworkInterfaceAttribute",
        "ecs:DescribeNetworkInterfaceAttribute"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "vpc:DescribeVSwitchAttributes",
        "vpc:AllocateEipAddress",
        "vpc:ReleaseEipAddress",
        "vpc:AssociateEipAddress",
        "vpc:UnassociateEipAddress",
        "vpc:DescribeEipAddresses"
      ],
      "Resource": "*"
    }
  ]
}
```

3. 在 **企业 → 权限管理 → 角色授权 → 创建角色** 的高级创建里，创建 RAM 角色（示例名 `ack-caa-demo`）并绑定上述策略，信任策略按下表配置：

| 配置项 | 描述 |
|--------|------|
| 身份提供者类型 | OIDC |
| 身份提供者 | 选择 `ack-rrsa-<CLUSTER_ID>`（`<CLUSTER_ID>` 为集群 ID） |
| 条件 | `oidc:iss`、`oidc:aud` 保持默认；手动添加 `oidc:sub`（StringEquals），限定可扮演该角色的 ServiceAccount：<br>• `system:serviceaccount:confidential-containers-system:cloud-api-adaptor`<br>• `system:serviceaccount:confidential-containers-system:peerpod-ctrl-controller-manager` |
| 角色名称 | `ack-caa-demo` |

> 注意：授信组织要选自己集群所在的组织，OIDC provider 选自己集群下启用的 RRSA。

4. 创建完成后，在角色详情页记录 **角色 ARN**（后续写入 Secret）。

### 1.2 部署 cert-manager

CAA Webhook 等组件依赖 cert-manager 做证书校验，需先部署。专有云内无法拉取 quay.io 镜像，使用 kustomize 将镜像替换为内网 registry 地址：

```bash
mkdir -p cert-manager && cd cert-manager

# 下载官方 v1.9.1 清单（构建机可访问外网时下载后传入）
curl -LO https://github.com/jetstack/cert-manager/releases/download/v1.9.1/cert-manager.yaml

cat << EOF > kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cert-manager.yaml

images:
  # 源镜像：quay.io/jetstack/cert-manager-controller:v1.9.1（专有云 已缓存）
  - name: quay.io/jetstack/cert-manager-controller
    newName: registry.acs.intra.env213.shuguang.com/acs/cert-manager-controller
  # 源镜像：quay.io/jetstack/cert-manager-webhook:v1.9.1（专有云 已缓存）
  - name: quay.io/jetstack/cert-manager-webhook
    newName: registry.acs.intra.env213.shuguang.com/acs/cert-manager-webhook
  # 源镜像：quay.io/jetstack/cert-manager-cainjector:v1.9.1（专有云 已缓存）
  - name: quay.io/jetstack/cert-manager-cainjector
    newName: registry.acs.intra.env213.shuguang.com/acs/cert-manager-cainjector
EOF

kubectl apply -k .
kubectl -n cert-manager get pod
```

三个 Pod 均 Running 后继续。

> **镜像来源说明**：上述三个 cert-manager 镜像已缓存在专有云内网 registry（`registry.acs.intra.env213.shuguang.com/acs/cert-manager-*`，源 ref `quay.io/jetstack/cert-manager-{controller,webhook,cainjector}:v1.9.1`）。其他环境部署时需先将源镜像同步到自己的 registry，再把 `newName` 改为对应地址（同步方法见 §1.5）。

### 1.3 Helm 部署 CAA

1. 创建 Helm 管理的 namespace：

```bash
kubectl apply -f - << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: confidential-containers-system
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: peerpods
    meta.helm.sh/release-namespace: confidential-containers-system
EOF
```

2. 修改 `providers/alibabacloud.yaml` 中的关键配置（完整说明见 [development.md](./development.md) §6）：

| 参数 | 说明 |
|------|------|
| `REGION` | 集群所在区域（专有云示例：`cn-wulan-env213-d01`） |
| `VSWITCH_ID` | Pod VM 使用的交换机 ID |
| `SECURITY_GROUP_IDS` | Pod VM 安全组 ID |
| `IMAGEID` | Pod VM 启动镜像 ID（专有云定制 CSV 镜像，当前样例：`m-7ng00w62s46354u8s5eq`） |
| `PODVM_INSTANCE_TYPE` | CSV 机密实例规格（专有云示例：`ecs.g8h-csv-2numa-hg-k10-c1m1.large`） |
| `CONFIDENTIAL_COMPUTING_MODE` | 机密计算模式，专有云海光平台填 `CSV` |

3. 确认 `mirror-values.yaml` 中各组件镜像均指向内网 registry（仓库已附带 专有云 配置）。

4. 创建云 API 凭据 Secret，供 CAA DaemonSet 以 RRSA 方式调用 ECS API。将 `${ALIBABA_CLOUD_ROLE_ARN}` 替换为 §1.1 记录的 **角色 ARN**、`${ALIBABA_CLOUD_OIDC_PROVIDER_ARN}` 替换为 **提供商 ARN**：

```bash
kubectl create secret generic my-provider-creds \
    -n confidential-containers-system \
    --from-literal=ALIBABA_CLOUD_ROLE_ARN=${ALIBABA_CLOUD_ROLE_ARN} \
    --from-literal=ALIBABA_CLOUD_OIDC_PROVIDER_ARN=${ALIBABA_CLOUD_OIDC_PROVIDER_ARN} \
    --from-literal=ALIBABA_CLOUD_OIDC_TOKEN_FILE=/var/run/secrets/ack.alibabacloud.com/rrsa-tokens/token
```

5. 安装：

```bash
helm dependency update
helm install peerpods . \
    -f providers/alibabacloud.yaml \
    -f ./mirror-values.yaml \
    --set secrets.mode=reference \
    --set secrets.existingSecretName=my-provider-creds \
    --set alibabacloud.rrsa.enable=true \
    -n confidential-containers-system
```

后续修改 `providers/alibabacloud.yaml`（如更换 `IMAGEID`）后，用相同参数执行 `helm upgrade peerpods .`，再重启 DaemonSet 使 ConfigMap 生效：

```bash
kubectl -n confidential-containers-system rollout restart ds/cloud-api-adaptor-daemonset
```

### 1.4 验证部署

等待约 3 分钟后检查部署状态：

```bash
kubectl -n confidential-containers-system get pod
```

预期输出包含 `kata-deploy-*`、`cloud-api-adaptor-daemonset-*`、`peerpodctrl-controller-manager-*` 三类组件，状态均为 Running：

```
NAME                                             READY   STATUS    RESTARTS   AGE
cloud-api-adaptor-daemonset-pnmpz                1/1     Running   0          20m
kata-deploy-89x8h                                1/1     Running   0          20m
peerpodctrl-controller-manager-bfdb466fb-xl8xc   2/2     Running   0          20m
```

其中 `cloud-api-adaptor-daemonset-*` 在每个 Worker 节点各一个。

**kata-remote RuntimeClass**（与公有云一致，由 Helm 一并安装，无需手工创建）：peerpods chart 的 kata-deploy 子 chart 通过其 `runtimeclasses.yaml` 模板渲染创建 `RuntimeClass/kata-remote`（handler 为 `kata-remote`）；kata-deploy DaemonSet 同时在每个节点安装 kata-remote shim 二进制并写入 containerd 配置。验证：

```bash
kubectl get runtimeclass kata-remote
```

若缺失：先确认 kata-deploy Pod 是否 Running 并查看日志（`kubectl -n confidential-containers-system logs <kata-deploy-pod>`）；恢复后重新执行 `helm upgrade` 即可重建。

> **重要**：后续如需删除集群，请先删除所有使用 `runtimeClassName: kata-remote` 的工作负载，再删集群，避免 CAA 创建的机密虚拟机资源残留。

### 1.5 镜像清单与跨环境迁移

上表所有容器镜像均已构建/备份在 **专有云内网 registry**（`registry.acs.intra.env213.shuguang.com/acs`，下表简写 `.../acs`），可供专有云整体 mirror 使用。部署到其他环境时，先按下表把镜像同步到目标 registry，再修改对应配置位置：

| 组件 | 上游源 ref | 专有云内网地址 | 配置位置 |
|------|-----------|--------------|----------|
| cert-manager 三件套 | `quay.io/jetstack/cert-manager-{controller,webhook,cainjector}:v1.9.1` | `.../acs/cert-manager-{controller,webhook,cainjector}` | §1.2 kustomization `newName` |
| cloud-api-adaptor | 本仓库自建，含 专有云定制（构建见 [development.md](./development.md) §5；上游 `quay.io/confidential-containers/cloud-api-adaptor`） | `.../acs/coco-cloud-api-adaptor:2274f17ad298088eeefa20fe4b3a58a350ceab4e` | `mirror-values.yaml` → `image` |
| peerpod-ctrl | `quay.io/confidential-containers/peerpod-ctrl:v0.22.0` | `.../acs/peerpod-ctrl:v0.22.0` | `mirror-values.yaml` → `resourceCtrl`；单独部署时为 `src/peerpod-ctrl/chart/values.yaml` |
| peer-pods-webhook | `quay.io/confidential-containers/peer-pods-webhook:v0.22.0` | `.../acs/peer-pods-webhook:v0.22.0` | `mirror-values.yaml` → `webhook` |
| kube-rbac-proxy | `registry.k8s.io/kubebuilder/kube-rbac-proxy:v0.14.0` | `.../acs/kube-rbac-proxy:v0.14.0` | `mirror-values.yaml` → `authProxy` |
| kata-deploy | `quay.io/kata-containers/kata-deploy:4.0.0`（chart 默认；专有云 备份为 CoCo 变体，转自 confidential-ai-registry） | `.../acs/coco-kata-deploy:4.0.0` | `mirror-values.yaml` → `kata-deploy.image` |
| kata-containers-kubectl | `registry-cn-hangzhou.ack.aliyuncs.com/dev/kata-containers-kubectl:latest` | `.../acs/kata-containers-kubectl:latest` | `mirror-values.yaml` → `kata-deploy.kubectlImage` |

> Pod VM 镜像是 ECS 系统盘镜像（非容器镜像），每个环境需单独烘焙上传，构建与 `IMAGEID` 获取见 [development.md](./development.md) §4/§6。

镜像同步示例（在能同时访问源与目标 registry 的机器上执行，推送需携带凭据）：

```bash
skopeo copy --all --dest-tls-verify=false \
  --dest-creds '<user>:<password>' \
  docker://quay.io/confidential-containers/peerpod-ctrl:v0.22.0 \
  docker://<目标registry>/<命名空间>/peerpod-ctrl:v0.22.0
```

换环境时需要修改的内容汇总：

- `mirror-values.yaml`：全部组件镜像地址与 tag
- `providers/alibabacloud.yaml`：`REGION` / `VSWITCH_ID` / `SECURITY_GROUP_IDS` / `IMAGEID`
- §1.2 cert-manager kustomization 的 `newName`
- `src/peerpod-ctrl/chart/values.yaml`：仅单独部署 peerpod-ctrl 时

---

## 2. 创建 Trustee 实例

在专有云控制台创建 **Trustee（远程证明服务）** 实例，并记录其访问地址（后续写入 `initdata.toml` 中的 KBS / AS URL）。

Trustee 内通常包含 **KBS / AS / RVPS** 等组件（见 [architecture.md](./architecture.md)）。

---

## 3. 编写 Pod YAML

创建 `pod.yaml`，例如：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-caa-demo
  annotations:
    io.katacontainers.config.hypervisor.cc_init_data: H4sIAAAAAAAAA5VVTZOqyBLd8ysIZ3EXTitqa+tEzKL4UNEGRVHEjg67gBJKgUIoKfHXT6Fz4/XceZvRIIzKPHky82RSwjgkOaZRIv4pNooI9oavDaFEeYFJWpukVqclNYSPAFL4KTQgbFGSxA3u+vHjh/BByRmlB5+kRxwWn8IvhpZPfHKA3HHN45otojT7o93udN9aEv92/hhKEmf/Nezs/TOk+CVmyGMoQoczqg7wewOaok5ftHUTdPuDufOy5D8N4TfRjpAY4ZSKNIJUnMtrMUcFiUtUiJRwIxIhpaigkNZdZyTGPq59NRqVML5CivgJF2J45bAfBedEJQ5Q6qOWqCUZrUSvEgN0hNeY/i6yCPuRGCP4yMDpCxQj/0HO8/H8rUdJ0PdRRlHA2eokHAtzjs2Qj4/Yr6HwUWyAsphUCeINwDTgj3hNzylhqYgDkReVoxNnR0GLE31r5PBopDo8k5O8FghyC6oFRyWni0n4t+Z8dDjF9JD5NazzJqAUejE6/IRxI82viAfyw6cQc/tjOjg9Ek5X70LDD6J/LMdTd0rzzBcL4p9FchT5fJ6y8rKvBQrqJmNcUJT+nESOLrXGhVCHIFonuab4xjegnV/T9qNcLjzFMH7hBwpxyre1XSevI+reIN9UCA//jeCbcC8w5P5/W34m+I1PReGFxnwtAvHn0gofZ8//5M4V7wDnfByP/mtoChO+Jzrl2GsciB4Sv3z/wOFfIsl5xBc5HmNexuFYPKwtEcTxQw1MUcKVSgOUi18fPmd9Vl58fokMc5CHeHyOaI75SAKuKU7DRyTnaQl14lqAZ7ZaG5zwVvi00Y3m8JATQg8+ymm9cLybgoM/Go2G8FJ/ZG2im6KirWx9rCvA1h5WwdB11b8rCqBVCJgug1CXlTsw5fB8ic54MmKSDKxiDFT5YlgFUyxX3VrWRGMz1T5pK8EAwwnobDSFRztJFK+TOPIS/6bZYCmH5lYGvqFoEbcFEE5GHWMFmBo+SOYqCGTBm8TYdWaRYTGmPB3vKi/A6hi3sQ3sJ4lhqBOz9NJV5XUZ9ZNRGagAjZlUCaatVYYaMuPEQ1QZcqP0tBnctuFPBA1Nv43vYPskI7aamn2/t4o9O6OCuzOl/W52/16Bxp4VTGyw+7sCW5vQjptsKy/ZcrxBXWdFofPKhDDUsAGkibK+TNa611MtjYu2AeBVl1UGGPfPAeHiWmoJQqtP8enaUcMQwUumSTNTWPb6wfhyWmplets1fbXbs9RblTpa5hT45vYcdPHeVHnfXJNipLB1EvSsStcWzC4dx+yEwnCkvkLFCktyzPwpuBzDbBuYu9ng1sRtc2SQS1YEWI/u/ZPTu2zIYD864r3D7G3gtrMREaoF3SRzrV++ruDuPl29DUJfz9MrZOmEtSNX04D5inXrnpiR11nMV6pFZqt91/Cczfy6oEJmbI5He9eN+37hjE9Jprxv8s4yH26PzM/oq9R/M3qbO3Kp4RWK5qG2tEx67ps0czTH1bfCmoS9EspTpWmqg6O0bO4uqbzfV/mVyXoybc67K/vUdu3kfVHOsoXiFBO4B832ndn7XifzBBAaMgCTU+gzFvrn55atpCWwpu1aehAiYMhGva3BzLIMA5CJohQTPqmxzAyFrzJ7ODWmyW1mKQYAbMoeJCdZDtmYgE3eG2377GzLZIt2uFm658stUk5giQkTlsDV58yVZWszBZamGSq4Ggr7X5Y7kCMsk2C6Ygs8LN3utgqmxtV1zPt7Mi4EuAs7Hu6fvK5Uel3z7qugU2/fdDXU3k+gMJRLOJ+DJMKr/0si1CzfSR4vitI/+QljquXO5mSvR6Vv8ureZQtwiTSgp5mkL0dy0e4RYVldoF0Fw8EYJc6s2gwWQcfrgCwPpWNgjuSw1wzm4NJ19CTQ99I4eb9Jd3+4WRNGNOk8F/rNa+QsMiVmiiNXAzY9vSb5nsxzb92+jbo4SXarwcmeQ93vLVzLs/FVvaBNtbjE9VsMheMYdrNmp+9sT2UyXHX1brxXcJhu26D3umN/Pq8zzVT/fZnxy+7z+f/1F2HM8gwKCQAA
spec:
  runtimeClassName: kata-remote
  containers:
    - image: registry.acs.intra.env213.shuguang.com/acs/nginx:stable-alpine
      name: hello
      command:
        - sleep
        - "10000"
```

注解 `io.katacontainers.config.hypervisor.cc_init_data` 用于下发：

- Trustee（KBS / AS）地址
- 镜像仓库 TLS 证书（专有云多为自签名，需通过 `extra_root_certificates` 注入）

上面示例中的长字符串可由下方 `initdata.toml` 按 §3.2 生成；部署前请按自己的 Trustee 地址重新生成。

### 3.1 编写 `initdata.toml`

```toml
algorithm = "sha384"
version = "0.1.0"

[data]

"aa.toml" = '''
[token_configs]

[token_configs.coco_as]
url = "http://127.0.0.1:8000"

[token_configs.kbs]
url = "https://127.0.0.1:8080"
tee_key_algorithm = "ECDH-ES+A256KW-P256"
# attestation_policy_selector = "alice"

[eventlog_config]
init_pcr = 17
enable_eventlog = true

[log]
level = "info"
'''

"cdh.toml" = '''
socket = "unix:///run/confidential-containers/cdh.sock"

[aa]
aa_socket = "unix:///run/confidential-containers/attestation-agent/attestation-agent.sock"

[kbc]
name = "cc_kbc"

[image]

extra_root_certificates = ["""
-----BEGIN CERTIFICATE-----
MIIFEzCCAvugAwIBAgISb1OPTg1WBiJnvJZAFBT0554eMA0GCSqGSIb3DQEBCwUA
MBExDzANBgNVBAMMBmVudjIxMzAgFw0yNTEyMDYxNjAwMDBaGA8yMDY1MTIwNjE2
MDAwMFowETEPMA0GA1UEAwwGZW52MjEzMIICIjANBgkqhkiG9w0BAQEFAAOCAg8A
MIICCgKCAgEAgB/3GQedwy5M8QHvtJdiTlUx3uXrfCfjfk7OUORWKaTdmmUN3BjD
niZt+a17ivOjhMv91ZVh87zlj2Wh0vwUA/Q0AEDoURUYvOsbDMgvthz8FhtMYZId
mdXo8FOcYG5R1y7qmBcsfreZcGz0XPJ55DA7oSsM72KLKQz0mds+rskimtaDv40T
ZW4YELGqMNwfbqZwF+YHS7IIVxeMLONsg06TUkH2l6vrYuIQd3qaWZ3FfN9oSs8v
iAhT7ycXTuMxxQ26fZenIB4g+nFp16OOF5tGtLbIpGTfV/8Va92yKa3Kvm+TVcdM
O5rKvn8Rg4z4F/m/YA1yqJ713AQYkByU/SMtFWKIIVip8rM6pxijd0vwEMT7ym/+
+ZZ5vCDd+GbOf9Ed7pCAASJo7p1Ve5Ff4Aef4eL7iA5VwKUbNNWmcF6Z3myIcDa1
HZr7yF5TK2VmIuqtzw7LBW+GxtaFyfTX8QTEa0Fdy6ooRe42oJp0FGQH8+vkZ0UB
BM/5SxC+33tz3w5NgHLQLKCKgsxPp8Hwyee8Jeb2eWVwkh1E/eclvqGeNZYaRaaV
t17iQWcF1iCU9SJfRAkHhfFyagStxxW74imuXlvuFpC6Zuh91WK22bQbhYdm2qu5
ejb6VRN48qpoaOF9Bv5TFFGHFgmiTTtdRN0KMqe45fcagApF0QGrqZ0CAwEAAaNj
MGEwDgYDVR0PAQH/BAQDAgEGMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFIu/
3gzMUskoN4NRPH4A1GjNvAa1MB8GA1UdIwQYMBaAFIu/3gzMUskoN4NRPH4A1GjN
vAa1MA0GCSqGSIb3DQEBCwUAA4ICAQABtNEGqocYgNDP2yUAWUWeg1lwWkxLFW0M
zKewyL+t/mR5Xt+nC1NsY2uthOT2FbnRg05vye+oap/Bycf/2HKerrqTV0g16Bxi
A8k1UVs9kaAL7jvhZETfP6Nso6F2XGPdGQnR5BGuKmE0249T+VEl/XWbPuvJR8aF
6hQ4P+Sub75t7uY/B0vPgRaKU6DRqBWm89i0UJo6MLyBRPSZDjOB3wtEAFx6RJ90
5e4sLS3FZ64wgh/gploU4EYLQI1cY073BJNYWpLQzVFloSTWsVYmQkJJA1hL0d2x
7CMu6F2Ud2RDq2wozAnL+VZZtbUciH91/bCLy2VimS1t8G1C2fUQNB9nSqbzCjcf
0L43uSpGJuXd8WgPYWnxn2ke5EVNPApZsKcUl6xG8aKK6JxdUBZzHzZSc9oarn0s
y35ju4vsFg721W9wCZfv2jRFPtdOZ66jZc7QV9Pkb9PMump4kgBC0XyUryP+ReTM
pWq2ejYyNOOTHEWj0vv7/bayKxs//Qme5oucO0cZS2tJxIX/Cq5+v5nQaFyFirZH
dK0TXvjr7HOPkJmYZIW7dUhYY18Na5xuClKSVqpCn33zqLja4ToaMUR0jEu5HsTK
h+mEtiawPqcJFagJw9YVuGPNnQZuQknbqazMg7kbbjCkqoSpCqhOyb82jKVcgSgG
tebBYyAuwQ==
-----END CERTIFICATE-----
""",
"""
-----BEGIN CERTIFICATE-----
MIIElzCCAn+gAwIBAgITAIAZ9uELCEP7Oc4J/VcdtO2DoTANBgkqhkiG9w0BAQsF
ADARMQ8wDQYDVQQDDAZlbnYyMTMwIBcNMjUxMjA2MTYwMDAwWhgPMjA2NTEyMDYx
NjAwMDBaMBExDzANBgNVBAMMBmVudjIxMzCCAaIwDQYJKoZIhvcNAQEBBQADggGP
ADCCAYoCggGBALqWlhDOI5jxZDuMNMx6B2TTIaDI5OI5XQ/LqH2hMA6ZWJTcmtH/
XwxnTHS4O3vRZGPjWdvqACzGMI/2JsRvlUm8Upp+eUmMskCD05YzKfarrojHB9Es
lKRmo1yHQsPA1D/sVaOh1Bopk+PAWXNRYN2/IrIMnetjxQQcfR3rdUw2pvErlpKg
BbcbyjsLSAecQT2dUL2IGZPYyFlpgn2ctpEEaVeqnfyJeasoe3SaH/afBcPGs6Tw
BDhydpdSzBzrsxVZR743sXnHEBGg+qtCjkt8LRXZzuX5SHzpo4pnEVcJm+H6yxqK
q/cent2tsCKx5vGqZpgvrxJE+BOUPpta1j2KlIT9dfHB397F/9e6UZHAzs593kmM
PZR4RCwWz8cGrE+RVyM2OWqcVJ5OF0w8tgiG/6ZhTB+GvBWRAzPr2dzRTSs8BJJj
lhE5gkkNRVQSaNi3SSYSUToRVKNpvKyoUMZ6wljS3zyHeI17c0u5qzXw8UQAWSu1
k6oQYWvngeRN2wIDAQABo2YwZDAOBgNVHQ8BAf8EBAMCAQYwEgYDVR0TAQH/BAgw
BgEB/wIBADAdBgNVHQ4EFgQUDQnBDH2y2W0Smph1dPJFrBBcKPIwHwYDVR0jBBgw
FoAUi7/eDMxSySg3g1E8fgDUaM28BrUwDQYJKoZIhvcNAQELBQADggIBAFZ6ua6/
T5W0VuyZFqWI4B1tnExW54eBEpNmG7U/zaaAikfuMXnw1sPVlS6TEJGJfH61eSmb
V3aJVNr1CTWkBLntNs5i0dzxlVa3zrvgxDdM+QMsWKCnjzJe7L6ls1ZfKX5Z4xcl
l9i+vFunHev67miRO1gqi6HvIH8LzIsbc3gJ0kGhKTxtR5ffJCMO8LOrE09MOf6y
33n/GZhEcHgIi7NVZE4dtsGSYktEvmBDYj81euYh1aFoiQB7S4IgC8eDFlgO/yWS
+0x3nUW07l6h6aQT6suq4X10WlqmZSw2eP0IOjyJNVWH/g056JX3icsYkA6Iij87
wMSCsVfKv+T3ueXy9q3iiEvTSCd81WiHZYbfUUEwRfeXLVMoMsx7cqzpXKYbA4RU
Yc/UpVdcCf/CDa8MlGpHfFmlSa61hE8qIRfEuAXpJv3YF8yJ8idkDkBSFxR4MZ9X
ToNxHYcu31WqUvSsdKbOc6SJyzfUGD98GD0GRcaNQHLxwZ3s/TRlCWATYs0Lj/e4
j+zrHFBzDbnJhapIuyL2PeIB8eaEESLWUYwI2xvS3lBvwa99jHumZqesd1RjDGqT
Fa8fdJCIpRrYmiveJsKPyobBwZ+wgPG0YtXkoUb/kjPctGArBlwESu9K2nBtpxkT
7V9eKY+yAZB7DWT2f8vySVJVhaAlye6ZIdwb
-----END CERTIFICATE-----
"""
]
'''
```

配置要点：

1. **Trustee 地址**  
   将 `[token_configs.coco_as].url` 与 `[token_configs.kbs].url` 替换为第 2 步记录的 Trustee（AS / KBS）地址。示例中的 `127.0.0.1` 仅为占位。

2. **镜像仓库证书链**  
   配置 `[image].extra_root_certificates`。上方示例为 专有云 环境的自签名根证书与 Registry TLS Server 证书；换环境时请替换为对应证书 PEM。

### 3.2 转为 Pod annotation

```bash
cat initdata.toml | gzip | base64 -w0
```

将输出的长字符串填入 `pod.yaml` 的  
`metadata.annotations["io.katacontainers.config.hypervisor.cc_init_data"]`。

---

## 4. 创建 Pod

```bash
kubectl apply -f pod.yaml
```

确认 Pod 使用 `runtimeClassName: kata-remote`，并由 CAA 拉起对应 Pod VM。

```bash
kubectl get pod pod-caa-demo -o wide
kubectl describe pod pod-caa-demo
```

---

## 5. 在容器内做远程证明

进入容器：

```bash
kubectl exec -it pod-caa-demo -- sh
```

ASR（api-server-rest）在 pod netns 内默认提供 REST（示例端口 `8006`）：

**a. 获取证据（evidence）**

```bash
curl "127.0.0.1:8006/aa/evidence?runtime_data=AAAA"
```

**b. 获取远程证明 Token**

```bash
curl "127.0.0.1:8006/aa/token?token_type=kbs"
```

**c. 获取当前远程证明 / 基础设施信息**

```bash
curl "127.0.0.1:8006/info"
```

---

## 相关文档

| 文档 | 说明 |
|------|------|
| [development.md](./development.md) | 构建机、Pod VM / CAA 镜像构建、IMAGEID |
| [architecture.md](./architecture.md) | 架构图与组件清单 |
