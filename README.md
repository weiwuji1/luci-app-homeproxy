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

改动 3 个文件（+141 / −7）：

| 文件 | 作用 |
| --- | --- |
| `root/etc/homeproxy/scripts/update_subscriptions.uc` | 订阅同步（后端）：新增 `extract_certificate()`；命中后把证书**直接写入** `/etc/homeproxy/certs/<节点名>-<哈希8>.pem` 并设 `tls_cert_path` |
| `root/etc/homeproxy/scripts/generate_client.uc` | 生成 sing-box 配置：新增 `write_node_certificate()`，供"前端导入"路径把节点选项 `tls_cert_pem` 还原成 PEM 文件并渲染 `tls.certificate_path` |
| `htdocs/luci-static/resources/view/homeproxy/node.js` | 手动 "Import share links"（前端）：新增 `extractCertificate()`，把证书编码为单行 `tls_cert_pem` 存入节点选项 |

另修正上游一处逻辑：订阅同步时对**已存在**的节点，原逻辑只遍历 UCI 里"已有的键"
（`map(keys(cfg), ...)`），导致已存在的节点**永远得不到新增选项**（如 `tls_cert_path` / `tls_self_sign`）——
必须删除节点重新导入才会生效。现已改为写入新解析结果的全部键，再清理上游已移除的键。

设计要点：

- **后端路径（订阅同步）写入持久目录**：证书落在 `/etc/homeproxy/certs/`，于是 LuCI 里
  "追加自签名证书 → 证书路径" **能直接看到**该文件路径，重启/升级不丢，且是真正用于校验的证书。
- **前端路径（手动 Import share links）**：浏览器没有文件系统，只把证书编码成单行 `tls_cert_pem`
  （PEM 换行 → `|`，PEM 内不含 `|`），由 `generate_client.uc` 在生成配置时还原为 `RUN_DIR/certs/<节点>.pem`。
- 两条路径互不干扰：`write_node_certificate()` 仅在 `tls_cert_pem` 非空时才落盘，否则原样返回 `tls_cert_path`。
- 命中后强制 `tls_insecure=0`、`tls_self_sign=1`，即**钉扎**而非跳过校验。
- **不触碰** `insecure` 的默认行为：用户无需打开不安全选项。

## 编译（GitHub Actions）

Workflow：`.github/workflows/build.yml`，**单次编译产出一个 noarch 包**：

- 包架构为 `noarch`（来自 Makefile 的 `LUCI_PKGARCH:=all`，可用 `apk adbdump <pkg>` 核对 `arch:` 字段），
  **一个包通吃 x86_64 / aarch64 / 其它架构**，因此无需按架构分别编译
- SDK：OpenWrt 25.12.2（`x86/64`，仅作为编译宿主，不影响产物架构）
- 源码：**本仓库自身**（检出后复制进 SDK 的 `package/custom/homeproxy`，不再拉取上游）
- 产物：`luci-app-homeproxy` + `luci-i18n-homeproxy-zh-cn` 的 `.apk`，发布到 Release
- **ucode 语法闸门**：`luci.mk` 只把 `root/` 下的 `.uc` 原样拷进包、不做语法编译，
  语法错误会静默出厂并让路由器上的订阅更新直接失败；因此构建前会用源码编译出的 `ucode -c`
  校验全部脚本（首次约 2 分钟，之后由 `actions/cache` 复用，约 10 秒）
- `Ensure disk space` 仅在可用空间 < 20 GiB 时清理 runner 预装 SDK；空间充足时自动跳过（约省 1.5 分钟）

触发方式：push 到 `main`（限 `Makefile` / `root/**` / `htdocs/**` / `po/**` / workflow 变更），或在 Actions 页手动 `Run workflow`。

## 安装

```bash
# 路由器上
apk add --allow-untrusted /tmp/luci-app-homeproxy-<version>.apk
apk add --allow-untrusted /tmp/luci-i18n-homeproxy-zh-cn-<version>.apk
rm -f /tmp/luci-indexcache.*
/etc/init.d/rpcd reload
```

安装后：**重新更新一次订阅**即可（已无需删除节点——上面的同步逻辑修正已覆盖该场景）。

## 验证

```bash
# 1. ucode 语法
ucode -c /etc/homeproxy/scripts/update_subscriptions.uc && echo OK
ucode -c /etc/homeproxy/scripts/generate_client.uc && echo OK

# 2. 证书已写入持久目录
grep -c 'tls_cert_path=' /etc/config/homeproxy
ls -l /etc/homeproxy/certs/
head -1 /etc/homeproxy/certs/<节点名>-<哈希8>.pem    # 应输出 -----BEGIN CERTIFICATE-----

# 3. 节点选项（GUI 里"证书路径"应显示该路径）
uci show homeproxy | grep -E 'tls_cert_path|tls_self_sign|tls_insecure'

# 4. sing-box 配置里引用了证书
grep -o '"certificate_path":"[^"]*"' /var/run/homeproxy/sing-box-c.json | sort -u
```

## 已知边界

- 仅对链接**确实内嵌证书 PEM** 的节点生效（`tls_certificate=` / `cert=`）。
- `pinSHA256=` / `hpkp=` 是**公钥/证书指纹**而非 PEM，且与 sing-box 需要的
  `certificate_public_key_sha256`（SPKI 哈希）算法不同，**无法由指纹反推证书**，故不处理。
  fscarmen 的 `shadowrocket` 订阅即用 `hpkp=`，若需钉扎请改用其 `throne` 订阅。
- fscarmen 的 `v2rayn://<base64-json>` 格式，原版与修正版**均不解析**。
- 服务端容器重建会重新生成自签证书 → 重新同步一次订阅即可自动刷新（建议在 compose 中持久化 `/sing-box/cert`）。
- 升级 HomeProxy 官方包会覆盖安装文件；本仓库编译的包不受影响。
- 前端改动需清浏览器缓存（Ctrl+Shift+R）。
