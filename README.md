# luci-app-homeproxy (patched)

基于 [immortalwrt/homeproxy](https://github.com/immortalwrt/homeproxy)（branch `master`）的**修正版**，
新增功能：**导入订阅链接时自动提取链接内嵌的自签 TLS 证书并绑定到节点**，
从而在 **不开启 `insecure`** 的前提下通过证书钉扎（certificate pinning）通过 TLS 校验。

服务端示例：[fscarmen/sing-box](https://github.com/fscarmen/sing-box) 生成的订阅链接，
其内嵌证书形如：

```
hysteria2://...?tls_certificate=-----BEGIN%20CERTIFICATE-----%0A...%0A-----END%20CERTIFICATE-----
trojan://...?cert=...
anytls://...?tls_certificate=-----BEGIN%20CERTIFICATE-----%2C...%2C-----END%20CERTIFICATE-----   # throne 订阅：逗号连接
```

原版 HomeProxy 的 `parseShareLink` / `parse_uri` **不读取** `tls_certificate=` / `cert=`，
导入时证书被静默丢弃，于是客户端只能靠 `insecure=1` 跳过校验。本仓库的修正补齐了这一点。

## 修正内容

改动 3 个文件（+175 / −8）：

| 文件 | 作用 |
| --- | --- |
| `root/etc/homeproxy/scripts/update_subscriptions.uc` | 订阅同步（后端）：新增 `extract_certificate()`；命中后把证书**直接写入** `/etc/homeproxy/certs/<节点名>-<哈希8>.pem` 并设 `tls_cert_path` |
| `root/etc/homeproxy/scripts/generate_client.uc` | ① `write_node_certificate()`：供"前端导入"路径把节点选项 `tls_cert_pem` 还原成 PEM 文件；② `remove_orphan_certificates()`：清理已无节点引用的证书文件 |
| `htdocs/luci-static/resources/view/homeproxy/node.js` | 手动 "Import share links"（前端）：新增 `extractCertificate()`，把证书编码为单行 `tls_cert_pem` 存入节点选项 |

另修正上游一处逻辑：订阅同步时对**已存在**的节点，原逻辑只遍历 UCI 里"已有的键"
（`map(keys(cfg), ...)`），导致已存在的节点**永远得不到新增选项**（如 `tls_cert_path` / `tls_self_sign`）——
必须删除节点重新导入才会生效。现已改为写入新解析结果的全部键，再清理上游已移除的键。

设计要点：

- **后端路径（订阅同步）写入持久目录**：证书落在 `/etc/homeproxy/certs/`，于是 LuCI 里
  "追加自签名证书 → 证书路径" **能直接看到**该文件路径，重启/升级不丢，且是真正用于校验的证书。
- **每次同步都会刷新证书**：证书写入在解析循环内，对每个带证书的节点每次同步都覆盖写，
  服务端换证书后重新同步即自动更新。
- **证书生命周期闭环**：`generate_client.uc` 每次生成 sing-box 配置后，会清理
  `/etc/homeproxy/certs/` 下**已无任何节点引用**的证书文件，覆盖三种路径——订阅同步删除节点、
  GUI 手动删除节点、订阅里节点被移除（含节点改名导致的旧文件残留）。
  清理**只针对本补丁生成的 `<节点名>-<哈希8>.pem` 命名**（以结尾的 `-<8位十六进制>.pem` 作签名；
  节点名可能含空格/中文，故前缀不做字符白名单），用户自己上传的证书（如 `client_ca.pem`）绝不动。
  **已知取舍**：用户自传的证书若文件名恰好也以 `-<8位十六进制>.pem` 结尾、且未被任何节点引用，会被一并清理。
- **前端路径（手动 Import share links）**：浏览器没有文件系统，只把证书编码成单行 `tls_cert_pem`
  （PEM 换行 → `|`，PEM 内不含 `|`），由 `generate_client.uc` 在生成配置时还原为 `RUN_DIR/certs/<节点>.pem`。
- 两条路径互不干扰：`write_node_certificate()` 仅在 `tls_cert_pem` 非空时才落盘，否则原样返回 `tls_cert_path`。
- 命中后强制 `tls_insecure=0`、`tls_self_sign=1`，即**钉扎**而非跳过校验。
- **不触碰** `insecure` 的默认行为：用户无需打开不安全选项。

## 编译（GitHub Actions）

Workflow：`.github/workflows/build.yml`：

- **同时产出两种固件格式**：25.12 出 `.apk`、24.10 出 `.ipk`——由 `prepare` job 解析成 matrix，
  每个目标使用各自的 SDK 与 feeds 分支；`workflow_dispatch` 可选 `both` / `25.12` / `24.10`
- 包架构为 `noarch`（来自 Makefile 的 `LUCI_PKGARCH:=all`，可用 `apk adbdump <pkg>` 核对 `arch:` 字段），
  **一个包通吃 x86_64 / aarch64 / 其它架构**，无需按架构分别编译
- 源码：**本仓库自身**（检出后复制进 SDK 的 `package/custom/homeproxy`，不再拉取上游）
- 产物：`luci-app-homeproxy` + `luci-i18n-homeproxy-zh-cn`，发布到**版本化 Release**（只保留最新 2 个）
- **两道 ucode 闸门**：`luci.mk` 只把 `root/` 下的 `.uc` 原样拷进包、不做语法编译，
  语法或 API 错误会静默出厂、到路由器上才炸（订阅更新失败甚至代理起不来）。因此构建前：
  1. `ucode -c` 校验全部脚本语法（`.github/scripts/ucode-strip-imports.py` 先剥离 import/export）
  2. 在真 ucode 上跑 `.github/scripts/check-orphan-cleanup.uc`，用与补丁**完全相同的 API 与正则**
     实跑一遍证书清理算法，确认 `lsdir` / `unlink` / `basename` 存在且行为正确

  ucode 语法检查器首次编译约 2 分钟，之后由 `actions/cache` 复用（约 10 秒）
- `Ensure disk space` 仅在可用空间 < 20 GiB 时清理 runner 预装 SDK；空间充足时自动跳过（约省 1.5 分钟）

触发方式：push 到 `main`（限 `Makefile` / `root/**` / `htdocs/**` / `po/**` / `.github/**` 变更），或在 Actions 页手动 `Run workflow`。

## 安装

```bash
# 路由器上
apk add --allow-untrusted /tmp/luci-app-homeproxy-<version>.apk
apk add --allow-untrusted /tmp/luci-i18n-homeproxy-zh-cn-<version>.apk
rm -f /tmp/luci-indexcache.*
/etc/init.d/rpcd reload
```

安装后：**重新更新一次订阅**即可（已无需删除节点——同步逻辑修正已覆盖该场景）。

## 验证

```bash
# 1. ucode 语法
ucode -c /etc/homeproxy/scripts/update_subscriptions.uc && echo OK
ucode -c /etc/homeproxy/scripts/generate_client.uc && echo OK

# 2. 证书已写入持久目录
ls -l /etc/homeproxy/certs/
head -1 /etc/homeproxy/certs/<节点名>-<哈希8>.pem    # 应输出 -----BEGIN CERTIFICATE-----

# 3. 节点选项（GUI 里"证书路径"应显示该路径）
uci show homeproxy | grep -E 'tls_cert_path|tls_self_sign'

# 4. sing-box 配置里引用了证书
grep -o '"certificate_path":"[^"]*"' /var/run/homeproxy/sing-box-c.json | sort -u

# 5. 证书生命周期：删掉一个节点并重启服务，其证书文件应消失
/etc/init.d/homeproxy restart && ls -l /etc/homeproxy/certs/
```

## 已知边界

- 仅对链接**确实内嵌证书 PEM** 的节点生效（`tls_certificate=` / `cert=`）。
- `pinSHA256=` / `hpkp=` 是**公钥/证书指纹**而非 PEM，且与 sing-box 需要的
  `certificate_public_key_sha256`（SPKI 哈希）算法不同，**无法由指纹反推证书**，故不处理。
  fscarmen 的 `shadowrocket` 订阅即用 `hpkp=`，若需钉扎请改用其 `throne` 订阅。
- fscarmen 的 `v2rayn://<base64-json>` 格式，原版与修正版**均不解析**。
- 服务端容器重建会重新生成自签证书 → 重新同步一次订阅即可自动刷新（建议在 compose 中持久化 `/sing-box/cert`）。
- 前端"手动 Import share links"路径的证书仍存放在运行时目录 `RUN_DIR/certs/`，不在 GUI 中显示证书路径。
- 升级 HomeProxy 官方包会覆盖安装文件；本仓库编译的包不受影响。
- 前端改动需清浏览器缓存（Ctrl+Shift+R）。
