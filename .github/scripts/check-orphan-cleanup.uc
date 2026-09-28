#!/usr/bin/ucode
/*
 * 校验补丁依赖的 fs API，以及"孤儿证书清理"算法在真实 ucode 上确实可运行。
 *
 * 这里刻意使用与 root/etc/homeproxy/scripts/generate_client.uc 中
 * remove_orphan_certificates() 完全相同的 API 与正则 —— 任何 API 缺失
 * 或算法偏差都会让本脚本非零退出，从而在 CI 阶段拦住问题，
 * 避免把"会让路由器上配置生成失败"的代码发出去。
 */
import { lsdir, unlink, writefile, basename } from 'fs';

const dir = '/tmp/ucode-orphan-check';

system('rm -rf ' + dir);
system('mkdir -p ' + dir);

/* 四种文件：
   1) 仍被节点引用的证书（保留）—— 刻意用真实节点名，含空格
   2) 节点已被删除、遗留的证书（必须清理）—— 同样含空格，
      专门回归"前缀不能做字符白名单"这个坑（真实节点名就叫 "sing-box anytls"）
   3) 用户自己上传的证书（必须保留）—— 名字不含 -<8位十六进制> 签名
   4) 用户自传但名字恰好带 -<8位十六进制> 的（会被清理）—— 已知取舍，README 有说明 */
writefile(dir + '/sing-box anytls-12ab34cd.pem', 'x');
writefile(dir + '/sing-box hysteria2-5678ef90.pem', 'x');
writefile(dir + '/client_ca.pem', 'x');
writefile(dir + '/my-own-cert-deadbeef.pem', 'x');

const keep = { 'sing-box anytls-12ab34cd.pem': true };
const entries = lsdir(dir);

if (type(entries) !== 'array') {
	print('FAIL: lsdir 未返回数组\n');
	exit(1);
}

for (let name in entries) {
	if (!match(name, /^.+-[0-9a-f]{8}\.pem$/))
		continue;

	if (name in keep)
		continue;

	unlink(dir + '/' + name);
}

const left = lsdir(dir);
let count = 0, sawKept = false, sawUser = false, sawTradeOff = false;

for (let name in left) {
	if (name === 'sing-box anytls-12ab34cd.pem')
		sawKept = true;
	else if (name === 'client_ca.pem')
		sawUser = true;
	else if (name === 'my-own-cert-deadbeef.pem')
		sawTradeOff = true;

	count++;
}

print('剩余文件: ' + sprintf('%J', left) + '\n');
print('basename(): ' + (basename('/etc/homeproxy/certs/a.pem') === 'a.pem' ? 'OK' : 'FAIL') + '\n');

const ok = (count === 2) && sawKept && sawUser && !sawTradeOff;

print(ok ? '孤儿证书清理算法 OK\n' : 'FAIL: 清理结果不符合预期\n');

exit(ok ? 0 : 1);
