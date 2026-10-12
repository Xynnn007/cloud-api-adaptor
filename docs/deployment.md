# 专有云部署指南

本文说明在 ACK 集群中部署 **CAA DaemonSet**，以及如何创建带远程证明 initdata 的 Peer Pod。  
镜像构建、IMAGEID / Helm provider 配置等开发侧步骤见 [development.md](./development.md)。

---

## 1. 在集群中部署 CAA DaemonSet

> **待补充**：完整 Helm / DaemonSet 安装步骤。

前置条件（开发侧完成后）：

- Pod VM 镜像已上传，`IMAGEID` 已写入 `alibabacloud.yaml`（见 [development.md](./development.md) §6）
- CAA 容器镜像已构建或推送到集群可拉取的仓库
- 集群已安装 `kata-remote` RuntimeClass（随 peer-pods 安装一并提供）

可先参考仓库安装入口：

- `src/cloud-api-adaptor/install/README.md`
- Helm Chart：`src/cloud-api-adaptor/install/charts/peerpods/`

部署完成后，确认各 Worker 上 CAA DaemonSet Pod 为 Running。

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
    io.katacontainers.config.hypervisor.cc_init_data: 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
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
kubectl exec -it pod-caa-demo -- bash
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
