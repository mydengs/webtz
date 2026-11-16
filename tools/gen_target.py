#!/usr/bin/env python3
"""生成跳转目标密文 kstat.bin（xor+base64，与 memstat.php 的 KEY 一致）
用法: python3 gen_target.py 'https://4568866.com/' /path/to/kstat.bin
"""
import base64, sys

KEY = b'Kx9fQm2v'

def encode(url: str) -> bytes:
    x = url.encode()
    return base64.b64encode(bytes(b ^ KEY[i % len(KEY)] for i, b in enumerate(x)))

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(__doc__); sys.exit(2)
    url, out = sys.argv[1], sys.argv[2]
    assert url.startswith('http'), '目标必须以 http(s):// 开头'
    data = encode(url)
    open(out, 'wb').write(data)
    # 自验
    d = base64.b64decode(open(out,'rb').read())
    d = bytes(b ^ KEY[i % len(KEY)] for i, b in enumerate(d)).decode()
    assert d == url, '自验失败'
    print(f'OK 密文写入 {out}（{len(data)}B），回解验证: {d}')
