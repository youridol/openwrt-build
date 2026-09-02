# patches/luci-app-dnsproxy — 本地 Patch 维护说明

## 原则

- **禁止**直接修改上游仓库 `adm1n5ky/luci-app-dnsproxy`（不改分支、不 fork、不把修改后源码拷进仓库覆盖上游）。
- 所有 LuCI 改动以 patch 形式保存在本目录，由 CI（`.github/workflows/build-openwrt.yml`）在编译阶段自动应用：

```
adm1n5ky/luci-app-dnsproxy
        │  CI 拉取克隆
        ▼
   git apply patches/luci-app-dnsproxy/*.patch
        │
        ▼
   OpenWrt 编译
```

## 文件清单

| Patch | 职责 |
|---|---|
| `0001-add-lan-dns-intercept.patch` | 新增 LuCI「拦截所有客户端 DNS」ON/OFF 开关（UCI: `dnsproxy.global.lan_dns_intercept`），保存后触发 `dnsproxy` reload 以同步拦截规则 |
| `0002-fix-version-detect-for-opkg.patch` | 修复 Service Control 按钮在 opkg 固件（lede/24.10）全部禁用：`parseVersion` 兼容读取 `/usr/lib/opkg/status`（apk 库缺失时回退），并给 ACL 增加该文件只读权限 |
| `0003-add-zh-cn-localization.patch` | 完整简体中文汉化：6 个 JS 页面 210 处 `_()` 字符串直接替换为中文（不引入 luci.mk/po2lmo，零构建链依赖，CI 自动应用即生效） |

## 维护规范

1. **单一职责**：每个 patch 只做一件事；多个独立修改按 `0001-`、`0002-` 递增编号。
2. **最小修改**：不重写页面、不复制整个上游 package、不引入 TODO/临时文件。
3. **新增文件**（如翻译 po）通过 `git diff --no-index` 或直接在干净克隆应用后 `git diff` 生成，
   确保 patch 是相对上游仓库根目录的 `a/... b/...` 格式。
4. **上游更新后**：
   - CI 每次全新克隆上游再应用 patch，天然幂等、可重复执行；
   - 若上游代码变更导致 patch 无法应用，`git apply --check` 会失败 → CI 明确失败（**禁止** `|| true` 静默忽略）；
   - 此时在本目录更新对应 patch 即可。

## 更新 patch 的标准流程

```sh
# 1) 全新克隆上游
git clone https://github.com/adm1n5ky/luci-app-dnsproxy.git /tmp/upstream
cd /tmp/upstream
# 2) 【只在本地工作副本】做必要修改（禁止推送到上游）
# 3) 重新生成 patch
git diff > /path/to/openwrt-build/patches/luci-app-dnsproxy/000N-xxx.patch
# 4) 在干净克隆上验证可应用
git -C /tmp/verify apply --check /path/to/openwrt-build/patches/luci-app-dnsproxy/000N-xxx.patch
```

## 配套（非 patch，见仓库根）

- `files/etc/init.d/dnsproxy`：dnsproxy procd 服务 + LAN DNS 拦截规则管理（生成/删除 `/etc/nftables.d/10-dnsproxy-lan-intercept.nft` 并触发 `fw4 reload`）。
- `files/etc/config/dnsproxy`：ALL_DOH 默认 UCI 配置。
- 拦截实现完全基于 firewall4/nftables（`/etc/nftables.d/*.nft` 自动加载），不修改 firewall4 源码、不使用轮询脚本。

## 验证清单（对应任务验收）

1. 上游 `luci-app-dnsproxy` 正常获取（CI 日志可见 clone 输出）
2. 本地 patch 成功应用（CI 日志 `>>> patch 应用成功`）
3. patch 不修改上游仓库（只在本仓库维护）
4. `dnsproxy` 编译成功
5. `luci-app-dnsproxy` 编译成功
6. `https-dns-proxy` 完全移除（CONFIG 已删，固件无该包）
7. LuCI 出现「拦截所有客户端 DNS」（General 选项卡）
8. 默认状态 ON（`dnsproxy.global.lan_dns_intercept=1`）
9. ON 创建 LAN UDP/53 与 TCP/53 redirect（`nft list tables` / `fw4 print` 可见 `dns_intercept_lan` 链）
10. IPv6 启用时同步拦截（nft inet family 一条规则同时覆盖 v4/v6）
11. OFF 删除 redirect（文件删除 + fw4 reload）
12. OFF 不影响 dnsproxy 服务
13. ON/OFF 重启后状态保持（UCI 持久 + init 启动时同步）
14. ALL_DOH 正常（dnsmasq → 127.0.0.1#5353 → DoH）
15. 无明文 DNS fallback（bootstrap 仅解析加密上游主机名）
16. 客户端改 DNS 无法绕过拦截
17. 关闭拦截后客户端 DNS 恢复正常
18. CI 完整编译成功、固件生成