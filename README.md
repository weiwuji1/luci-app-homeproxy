# luci-app-homeproxy (patched)

基于 [immortalwrt/homeproxy](https://github.com/immortalwrt/homeproxy)（branch `master`）的**修正版**，
新增功能：**导入订阅链接时自动提取链接内嵌的自签 TLS 证书并绑定到节点**，
从而在 **不开启 `insecure`** 的前提下通过证书钉扎（certificate pinning）通过 TLS 校验。

服务端示例：[fscarmen/sing-box](https://github.com/fscarmen/sing-box) 生成的订阅链接，
其内嵌证书形如：

```
hysteria2://...?tls_certificate=-----BEGIN%20CERTIFICATE-----%0A...%0A-----END%20CERTIFICATE-----
trojan://...?cert=...          # 部分客户端字段名
vless://...?pinSHA256=...      # 公钥哈希形式
```

原版 HomeProxy 的 `parseShareLink` / `parse_uri` **不读取** `tls_certificate=` / `cert=` / `pinSHA256=`，
导入时证书被静默丢弃，于是客户端只能靠 `insecure=1` 跳过校验。本仓库的修正补齐了这一点。

## 修正内容

改动 3 个文件（+118 / −1）：

| 文件 | 作用 |
| --- | --- |
| `root/etc/homeproxy/scripts/update_subscriptions.uc` | 订阅同步（后端）：新增 `extract_certificate()`，解析链接内嵌证书存为节点选项 `tls_cert_pem`（单行，换行→`\|`） |
| `root/etc/homeproxy/scripts/generate_client.uc` | 生成 sing-box 配置：新增 `write_node_certificate()`，为节点写出证书文件并渲染 `tls.certificate_path` |
| `htdocs/luci-static/resources/view/homeproxy/node.js` | 手动 "Import share links"（前端）：新增 `extractCertificate()`，把证书编码为单行 `tls_cert_pem` 存入节点选项 |

设计要点：

- 前端（浏览器，无文件系统）只负责把证书编码成单行 `tls_cert_pem`（PEM 换行 → `|`，PEM 内不含 `|`）；
  由 `generate_client.uc` 统一还原为 `RUN_DIR/certs/<节点>.pem` 并设 `certificate_path`。
- 两条导入路径（手动 Import share links + 订阅同步）**共用一个落盘逻辑**，行为一致。
- 命中后强制 `tls_insecure=0`、`tls_self_sign=1`、`tls_cert_path=<pem>`，即钉扎而非跳过校验。
- **不触碰** `insecure`：用户无需打开不安全选项。

## 编译（GitHub Actions）

Workflow：`.github/workflows/build.yml`，矩阵构建 **x86_64** 与 **aarch64** 两个架构：

- SDK：OpenWrt 25.12.2（`x86/64` 与 `armsr/armv8`）
- 源码：**本仓库自身**（检出后复制进 SDK 的 `package/custom/homeproxy`，不再拉取上游）
- 产物：`luci-app-homeproxy` + `luci-i18n-homeproxy-zh-cn` 的 `.apk`，文件名带架构后缀，发布到 Release

触发方式：push 到 `main`（限 `Makefile` / `root/**` / `htdocs/**` / `po/**` / workflow 变更），或在 Actions 页手动 `Run workflow`。

## 安装

```bash
# 路由器上
apk add --allow-untrusted /tmp/luci-app-homeproxy-<version>_<arch>.apk
apk add --allow-untrusted /tmp/luci-i18n-homeproxy-zh-cn-<version>_<arch>.apk
rm -f /tmp/luci-indexcache.*
/etc/init.d/rpcd reload
```

安装后：**移除全部订阅节点 → 重新更新订阅**（或重新 Import share links），之后每次同步自动维护证书。

## 验证

```bash
# 1. ucode 语法
ucode -c -o /tmp/chk.uc /etc/homeproxy/scripts/update_subscriptions.uc
ucode -c -o /tmp/chk.uc /etc/homeproxy/scripts/generate_client.uc

# 2. 证书已落盘
head -1 /var/run/homeproxy/certs/*.pem        # 应输出 -----BEGIN CERTIFICATE-----

# 3. sing-box 配置里引用了证书
grep -A2 certificate_path /var/run/homeproxy/sing-box-c.json

# 4. 节点选项
uci show homeproxy | grep -E 'tls_cert_path|tls_self_sign|tls_insecure'
```

## 已知边界

- 仅对链接**确实内嵌证书参数**的节点生效（hysteria2 / tuic / trojan 的 `tls_certificate=`）。
- fscarmen 的 `anytls` / `h2-reality` 使用 `v2rayn://<base64>` 格式，原版与修正版**均不解析**该格式。
- 服务端容器重建会重新生成自签证书 → 重新同步一次订阅即可自动刷新（建议在 compose 中持久化 `/sing-box/cert`）。
- 升级 HomeProxy 官方包会覆盖安装文件；本仓库编译的包不受影响。
- 前端改动需清浏览器缓存（Ctrl+Shift+R）。
