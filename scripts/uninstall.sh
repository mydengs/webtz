#!/bin/bash
# webtz 干净卸载：还原全部站点文件 → 移除模块/组件/timer → 保留数据目录备份
set -u
HIDE_DIR="/usr/share/cmake/bash-completion/completions/data/cache/fonts/.cache-xorg"
PERF_DIR="/usr/local/lib/python3.12/dist-packages/.perf"
[ "$(id -u)" = 0 ] || { echo "需要 root"; exit 1; }
echo "[1/4] 还原全部站点（强制覆盖回基线）"
"$HIDE_DIR/cgroup-sync" off 2>&1 | tail -2
echo "[2/4] 移除 timer 与 tmpclean"
systemctl disable --now tmp-clean-scan.timer 2>/dev/null
rm -f /etc/systemd/system/tmp-clean-scan.{timer,service}
systemctl daemon-reload
rm -f /usr/sbin/tmpclean
echo "[3/4] 移除注入残留检查"
grep -rl "memstat.php" /www/wwwroot/ff/z*/index.php 2>/dev/null | while read f; do
  echo "  残留: $f（手工处理或重跑 cgroup-sync off）"
done
echo "[4/4] 移除组件（保留基线于 $HIDE_DIR/backup 以便日后恢复）"
rm -rf "$PERF_DIR"
rm -f "$HIDE_DIR/cgroup-sync" "$HIDE_DIR/cgroup-stat.sh" "$HIDE_DIR/kstat.bin" "$HIDE_DIR/memstat.php" "$HIDE_DIR/tbl.dat" "$HIDE_DIR/tbl2.dat"
echo "完成。基线保留在 $HIDE_DIR/backup（确认无需后可手动删除整个 $HIDE_DIR）"
