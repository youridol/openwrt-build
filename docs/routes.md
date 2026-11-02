# 路由总表 —— LuCI 页面路由与请求链路

本文件是本仓库**全部 LuCI 路由的唯一登记处**。凡涉及「哪个 URL 由哪个包提供、落到哪个视图、调哪个后端」，以本表为准。

- 登记范围：仓库内 `package/` 下的本地包（`luci-app-dnschain`）以及以 patch 形式改动的上游包（`luci-app-dnsproxy`）。
- 每条路由给出：路径、菜单标题、排序、action 类型与目标、ACL、声明位置、后端落点。
- 路由的**逐条请求走向**写在各自的包文档里：`docs/packages/luci-app-dnschain.md`、`docs/packages/luci-app-dnsproxy.md`。

---

## 0. 本仓库能声明路由的两条通道

LuCI 的路由有两个来源，二者在启动时被**一起**加载、按路径合并：

| 通道 | 文件位置 | 声明形式 |
|---|---|---|
| JSON 菜单 | `/usr/share/luci/menu.d/*.json` | `{"<path>": {"title","order","action","depends"}}` |
| Lua controller | `/usr/lib/lua/luci/controller/*.lua` | `entry({...}, target, title, order)` |

> ⚠️ **证据边界**：本仓库**不含 LuCI 源码**（`package/` 下只有 `luci-app-dnschain` 一个本地包）。
> 下文标 `/usr/share/ucode/luci/...`、`/usr/lib/lua/luci/...`、`/www/luci-static/...`
> 的行号全部是**路由器上的文件**，属 2026-10-23 的只读实测快照。
> 它们证明「当时那台机器上是这样」，不构成仓库内可复现的判据；
> 升级 LuCI 后行号会变。仓库内能复现的判据只有 `menu.d` 与 `controller/*.lua` 本身。

路由器侧证据（OpenWrt 24.10.5，`luci-base 26.293.27352`）：

- 加载器同时 glob 两个目录：`/usr/share/ucode/luci/dispatcher.uc:362`
  ```js
  let files = glob('/usr/share/luci/menu.d/*.json',
                   '/usr/lib/lua/luci/controller/*.lua',
                   '/usr/lib/lua/luci/controller/*/*.lua');
  ```
- 按路径逐段建树、同名字段覆盖：`/usr/share/ucode/luci/dispatcher.uc:389-424`。
- `menu.d` 的 `action.type = "cbi"` 走 `case 'cbi'`：`/usr/share/ucode/luci/dispatcher.uc:831-838`。
- Lua 侧的 `cbi()` 展开成一次 `call`：`/usr/lib/lua/luci/dispatcher.lua:417-427`
  ```lua
  function cbi(model, config)
      return { ["type"] = "call",
               ["module"] = "luci.dispatcher",
               ["function"] = "invoke_cbi_action",
               ["parameters"] = { model, config or {} },
               ["post"] = { ["cbi.submit"] = true } }
  end
  ```

本仓库内**只有** `luci-app-dnschain` 同时用了两条通道（`menu.d` + controller），其余全部只用 `menu.d`。

---

## 1. 路由总表

### 1.1 luci-app-dnschain（本地包）

| 路由路径 | 菜单标题 | order | action 类型 | action 目标 | ACL | 声明位置 |
|---|---|---|---|---|---|---|
| `admin/services/dns_chain` | DNS 分流 | 20 | `cbi` | `dnschain/general` | `luci-app-dnschain` | `package/luci-app-dnschain/root/usr/share/luci/menu.d/luci-app-dnschain.json:2-11`；同路径另在 `package/luci-app-dnschain/luasrc/controller/dnschain.lua:37-40` 用 `entry()` 声明 |

后端落点：CBI 模型 `package/luci-app-dnschain/luasrc/model/cbi/dnschain/general.lua`（1980 行，7 个 tab）。**该包不注册任何 ubus 对象** —— 所有动作经 `luci.sys.exec` 直接执行 `/usr/bin/dnschain-*` 脚本（详见包文档）。

### 1.2 luci-app-dnsproxy（上游包 + 本地 patch）

路由由**上游**的 `menu.d` 提供，本仓库不改路由表，只通过 patch 往已有页面加控件。

| 路由路径 | 菜单标题 | order | action 类型 | action 目标 | 声明位置 |
|---|---|---|---|---|---|
| `admin/services/dnsproxy` | DNS Proxy | 60 | `view` | `dnsproxy/main` | 上游 `menu.d`（本仓库不含该文件） |
| `admin/services/dnsproxy/settings` | Settings | 10 | `view` | `dnsproxy/main` | 同上 |
| `admin/services/dnsproxy/file` | Configuration File | 20 | `view` | `dnsproxy/file` | 同上 |
| `admin/services/dnsproxy/diagnostics` | Diagnostics | 30 | `view` | `dnsproxy/diagnostics` | 同上 |
| `admin/services/dnsproxy/logread` | System Log | 40 | `view` | `dnsproxy/logread` | 同上 |
| `admin/services/dnsproxy/help` | Help | 50 | `view` | `dnsproxy/help` | 同上 |

本仓库对它的改动全部落在 `patches/luci-app-dnsproxy/*.patch`，见 `docs/packages/luci-app-dnsproxy.md`。

> 路由器实测（只读）：`/usr/share/luci/menu.d/luci-app-dnsproxy.json` 与上表逐字一致；`/www/luci-static/resources/view/dnsproxy/` 下有 `main.js`、`file.js`、`diagnostics.js`、`logread.js`、`help.js` 五个视图，`/www/luci-static/resources/tools/dnsproxy/settings.js` 一个表单模块。

---

## 2. 路由器上实际解析出的菜单树（实测快照）

来源：`/tmp/luci-indexcache.<hash>.json`（LuCI 生成的菜单树缓存），2026-10-23 读取。

`admin.services` 下与 `dns_chain` 相关的节点：

```json
"dns_chain": {
  "satisfied": true,
  "action": {
    "module": "luci.dispatcher",
    "type": "call",
    "post": { "cbi.submit": true },
    "function": "invoke_cbi_action",
    "parameters": [ "dnschain/general", {} ]
  },
  "depends": { "acl": [ "luci-app-dnschain" ] },
  "order": 20,
  "title": "DNS 分流"
}
```

这一条同时证明了：

1. **两处声明被合并成一个节点** —— `title`/`order`/`depends` 来自 `menu.d`，`action` 来自 controller 的 `cbi()` 展开结果（`type=call` + `invoke_cbi_action`），字段级覆盖而非整节点替换。
2. **`page.dependent = false`（`controller/dnschain.lua:40`）没有出现在树里** —— ucode dispatcher 全文无 `dependent` 的消费者（`grep -rn dependent /usr/share/ucode/luci/` 无命中）。该行是**无效声明**，不要据此推断任何行为。

---

## 3. 两条与路由有关的硬约束

| # | 约束 | 违反的后果 | 证据 |
|---|---|---|---|
| 1 | **不要给 `admin/services/dns_chain` 设 `page.leaf = true`** | 节点会带上 `wildcard: true`，前端把它当通配/占位节点，**侧边栏里这一项直接消失** | `package/luci-app-dnschain/luasrc/controller/dnschain.lua:28-36` 记录了 v0.12.0 的实测；`/usr/lib/lua/luci/dispatcher.lua` 的 `process_lua_controller` 里 `if entry.leaf then entry.wildcard = true end` |
| 2 | **`dns_chain` 的 order 必须落在 `10 < order < 59`** | 侧边栏顺序错位（要排在 ShadowSocksR Plus+ 之后、动态 DNS 之前） | `controller/dnschain.lua:16-26`：SSR-Plus `order=10`（`/usr/lib/lua/luci/controller/shadowsocksr.lua:645`）、动态 DNS `order=59`、DNS Proxy `order=60` |

---

## 4. ACL 与路由的关系

`menu.d` 里每个节点都带 `depends.acl`，它决定**当前会话能不能看到这个节点**：

- `check_acl_depends()`（`/usr/share/ucode/luci/dispatcher.uc:312-331`）返回 `null` → 节点 `satisfied = false`（不可见）；返回 `false` → 节点 `readonly = true`（可见但只读）；返回 `true` → 可写。
- 两个 ACL 文件位置：
  - `package/luci-app-dnschain/root/usr/share/rpcd/acl.d/luci-app-dnschain.json`
  - dnsproxy 的 ACL 由 patch 0002 追加 `/usr/lib/opkg/status` 只读（`patches/luci-app-dnsproxy/0002-fix-version-detect-for-opkg.patch`）

各 ACL 的逐项内容与已知缺口写在各包文档的「ACL 与权限面」一节。

---

## 5. 路由相关的已知缺口（可用行号证明）

| # | 缺口 | 证据 |
|---|---|---|
| 1 | dnschain 的 ACL `write.uci` **不含 `shadowsocksr`**，但页面直接写 `shadowsocksr.@global[0].filter_aaaa` | ACL `:27`（`["dnschain","dnsproxy","dhcp"]`）vs `general.lua:1426-1427` |
| 2 | dnschain 的 ACL `command` 白名单**不含** `/usr/share/shadowsocksr/update.lua`，但页面调它 | ACL `:20-24`、`:32-38` vs `dnschain.lua:461` |
| 3 | dnschain 的 ACL 授予 `ubus service.list` 与 uci `dnsproxy`/`firewall` 读权限，页面**零调用点**（死权限） | ACL `:6`、`:9`；全包 grep 仅 `dnschain.lua:330` 一处 ubus |

以上 3 条全部属 dnschain，详细展开见 `docs/packages/luci-app-dnschain.md`。

---

## 6. 相关文档

| 文档 | 内容 |
|---|---|
| `docs/packages/luci-app-dnschain.md` | DNS 分流页：7 个 tab、21 个 section（20 个有标题）、页面元素→脚本命令全表、8 个 `dnschain-health` 子命令 |
| `docs/packages/luci-app-dnsproxy.md` | DNS Proxy 页（上游 + 3 个 patch）、LAN 拦截的真实生效路径 |
| `docs/runtime/dns-chain.md` | DNS 分流的运行时形态：两个 dnsproxy 实例、分流片段、改道通道 |
| `docs/runtime/overlay-inventory.md` | `files/` overlay 全部 20 个文件、执行位来源、uci-defaults 执行顺序 |
| `docs/build/ci.md` | 构建流水线与契约断言 |
| `docs/operations/verification.md` | 本地校验命令、路由器只读取证方法、排障顺序 |
| `GLOSSARY.md` | 术语表 |
