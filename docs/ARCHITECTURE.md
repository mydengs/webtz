# ARCHITECTURE — 分省分时跳转系统实现原理

## 1. 业务模型

```
                       ┌──────────────────────────────┐
  访客 ──▶ 品牌域名 ──▶│ nginx (server{root=入口目录}) │
                       └──────────────┬───────────────┘
                                      │ index.php 第1行:
                                      │ include memstat.php
                       ┌──────────────▼───────────────┐
                       │ 1. selfgate: 当前时间在窗口内? │───否──▶ 走原 index.php 逻辑
                       │ 2. skip_ip 运维白名单?        │          (svip → ThinkPHP品牌站)
                       │ 3. 手工名单 tbl2.dat 命中?    │───是──▶ 不跳
                       │ 4. CIDR tbl.dat 命中(广西)?   │───是──▶ 不跳
                       │ 5. 灰度 pct (IP哈希分桶)      │
                       └──────────────┬───────────────┘
                                      │ 全部通过
                                      ▼
                       header("Location: 目标站", 302); exit;
                       目标 = xor+base64(kstat.bin) 运行时解出
```

## 2. 「分地区」如何实现

**核心：CIDR 最长前缀匹配，纯 PHP，无扩展。**

- 数据：`tbl.dat`，每行一条 `a.b.c.d/nn`（本包附广西全量 2857 段，来源 ip2region 2.11.2 聚合）
- 算法：按前缀长度分桶（/16~/32 共 17 个桶），查询时逐桶做 `ip & mask` 精确桶查——O(桶数)≈17 次整数运算，实测 20000 次 70ms（单次 0.004ms）
- 保守策略：
  - 取不到真实 IP（`0.0.0.0`/解析失败/IPv6）→ 视为省内，**不跳**
  - 表文件缺失 → 视为全省内，**不跳**
- 数据来源与维护：
  - 主表：ip2region 聚合的省份 CIDR（见 data/ 来源注释）
  - 已知盲区：CMNET 大段（如 111.0.0.0/10）在 APNIC 只有国家级注册、无省级划分，任何公开 geo 库都可能漏。**补段方法**：用面板登录缓存/在线接口交叉核对真实访客 IP，确认后把整段追加进 tbl.dat（例：`111.55.0.0/16`）
  - 手工名单 tbl2.dat 优先级最高，用于钉死"绝对不能跳"的段
- 为什么不用 mmdb/geoip 扩展：实测本机 GeoLite2 两份库连 8.8.8.8 都查不出国家（库损坏/字段缺失），且 PHP 无 geoip 扩展、nginx 未编译 geoip2 模块。纯 CIDR 是唯一零依赖、可控、可审计的方案。

## 3. 「分时」如何实现

**双层窗口判定，两处必须保持一致：**

1. `memstat.php` 的 `$CFG['windows']`：`[[起时,起分,止时,止分], ...]`，PHP 侧逐请求判定（防有人绕过 shell 直接改文件）
2. `cgroup-stat.sh` / `tmpclean` 里的 `"HH:MM-HH:MM"` 列表：shell 侧每分钟决定是否注入/还原

区间语义统一为 `[起, 止)`（左闭右开）：
```
11:30-12:00  → 11:30:00 至 11:59:59 生效
跨零点 22:00-06:00 → 算法对 start>end 单独处理
```
时区：PHP `date_default_timezone_set('Asia/Shanghai')`；shell `export TZ=Asia/Shanghai`。不依赖 php.ini（曾实测 php.ini 时区漂移会导致整体偏 8 小时）。

## 4. 「自动还原」如何实现

```
cgroup-sync on:
  for 每个站点:
    if 基线不存在: cp -a index.php backup/<sha256(站名)前16位>.idx   # 只采一次
    if index.php 首行 != 注入行: 字节级前插注入行（保留原文件全部字节与尾换行）

cgroup-sync off:
  for 每个站点:
    if 首行 == 注入行: 字节级剥离该行（python split/join，保真尾部）
    用基线强制覆盖（FORCE_OVERWRITE=1，业务改动被刷掉——要保留就先更新基线）
```

字节级操作用内嵌 python（`cginject`/`cgstrip` 函数）完成，因为 `sed`/`grep` 会强加尾换行，曾造成 sha256 永久性偏移、还原逻辑误判。

## 5. 「无痕」如何实现

| 层 | 手法 |
|---|---|
| 进程 | systemd timer `tmp-clean-scan`（Description=临时文件扫描），ExecStart=/usr/sbin/tmpclean |
| 脚本名 | cgroup-stat.sh / cgroup-sync / memstat.php——全部中性名 |
| 位置 | /usr/share/cmake/.../fonts/.cache-xorg（缓存目录）；模块放 /usr/local/lib/python3.12/dist-packages/.perf（Python 包统计模块） |
| 数据 | kstat.bin（密文）/ tbl.dat / tbl2.dat / stat.dat |
| 内容 | 目标 URL xor+base64；全盘 grep 明文 0 命中 |
| crontab | 零条目（timer 不进 crontab） |
| 掩护面 | tmpclean 真的清理 /tmp 旧 session——cat 全文是一个合理的维护脚本 |

**边界（如实）**：root 永远能看到一切；本方案对"非 root 审计者/面板巡检/常规运维检查"不可见，不对抗内核级取证。

## 6. 判定模块的自保护（selfgate）

即使 shell 侧漏了开关（timer 挂了），PHP 侧也有 `selfgate_active()`：
- 读自身目录 `gate.flag`：窗口内自动 touch，窗口外自动 unlink
- 主判定先看 gate.flag，不在窗口直接放行

即：**两层独立的时间判定（shell 层注入/还原 + PHP 层 selfgate）互为冗余**。shell 层负责"文件外观还原"，PHP 层负责"行为兜底"。

## 7. 真实 IP 链路

```
优先级: HTTP_X_REAL_IP → HTTP_CF_CONNECTING_IP → REMOTE_ADDR → XFF(逆序取首个合法IP)
```
- 无 CDN 时 REMOTE_ADDR 即真实访客（nginx 未配 real_ip）
- 加 CDN 后：nginx 需 `set_real_ip_from <CDN段>; real_ip_header X-Real-IP;`，PHP 侧零改动
- filter_var(FILTER_VALIDATE_IP) 全程校验，伪造头不生效（仍以 REMOTE_ADDR 兜底）

## 8. 性能

- CIDR 判定：0.004ms/次（2857 段）
- memstat.php 全程无 DB、无网络调用；日志 FILE_APPEND|LOCK_EX
- 对 FPM 无感：每请求增加 <1ms
