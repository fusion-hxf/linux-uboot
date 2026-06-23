故障排查总结:getaddrinfo 解析慢
现象
走 getaddrinfo() 的程序(curl、npm、git)访问域名必现卡顿:curl 总耗时约 4.27s,其中 DNS 解析独占约 4.25s,而 TCP/TLS/服务器响应全部正常(几十到两百毫秒)。问题稳定复现、时长固定。
排查路径与几次反转
这次排查最有价值的地方是不同工具测出来的结果互相矛盾,逐步逼出真相:
工具走的路径结果说明dig / nslookup自己发包,不走 NSS快(0.26~0.56s)误导:看着上游没问题resolvectl querysystemd-resolved快(167ms)误导:看着 resolved 没问题改 resolved 配置 / 删 1.1.1.1—curl 纹丝不动关键:证明 curl 根本不走 resolvedcurl -4(只 A)getaddrinfo2.17s砍掉 AAAA 省了一次超时getent ahostsv4(只 A)getaddrinfo2.16s关键:只查 A 也慢,推翻"A/AAAA 竞态"猜想
前几轮的猜测(某个上游持续坏、A/AAAA 并发竞态)都被数据逐一否决。决定性的一步是:只查 A 仍然卡 2 秒 → 慢点不在并发、不在上游、不在 resolved,而在 getaddrinfo 必经的 nsswitch 这一层。
根因
/etc/nsswitch.conf 的 hosts 行:
hosts: files mdns4_minimal [NOTFOUND=return] tls dns
                                             ^^^
那个 tls 是 nss-tlsd / libnss-tls 这个独立 DoH 解析守护进程注入的 NSS 模块,排在 dns 前面。它配置的三个 resolver——9.9.9.9(Quad9)、dns.google、1.1.1.1——在国内全部被干扰、连不上。于是每次解析都先把这几个 DoH 服务器试到超时,才 fallthrough 到能用的 dns(glibc → 223.5.5.5)。A 和 AAAA 各吃一次约 2s 超时,合计约 4s。
这就解释了全部矛盾:dig/nslookup/resolvectl 都不经过 nsswitch,所以碰不到 tls;只有走 getaddrinfo 的程序才会踩坑,且每次吃固定超时常量,因此"必现、时长稳定"。
修复
从 nsswitch 移除 tls 模块,getent ahosts 立刻从 2.13s 降到 0.099s:
bashsudo cp /etc/nsswitch.conf /etc/nsswitch.conf.bak
sudo sed -i 's/\[NOTFOUND=return\] tls dns/[NOTFOUND=return] dns/' /etc/nsswitch.conf
最终 hosts 行:files mdns4_minimal [NOTFOUND=return] dns,配合 223.5.5.5,干净秒回。这个文件不受 resolv.conf 的 foreign 重写影响,改完即持久。
待收尾事项
这几项在上一条里给过命令,尚未执行/确认:

彻底清掉 nss-tlsd —— 守护进程仍在后台 active (running),且其 resolver 国内全不可用,建议 systemctl disable --now nss-tlsd 后 apt purge nss-tlsd libnss-tls,purge 后再确认 hosts 行没被卸载脚本改回去。
恢复 IPv6 —— 需先诊断是哪一层关的(内核 cmdline ipv6.disable / sysctl disable_ipv6 / 网络管理器),再对症恢复;尤其内核 cmdline 那种要重启,在 mainline 手机上需谨慎。
网络栈"完全重置" —— 不建议一键 nuke;根因已定位修复,剩下的是配置层叠不一致。更稳的是有界的解析层重置(可选把 nsswitch 的 dns 换成 resolve 收口到 resolved)。重启网络前,SSH 用户务必确认有 usb0 USB 退路,别把自己踢下线。

一句话教训
排查 DNS 慢时,dig/nslookup 和应用程序走的不是同一条路:前者直接发包,后者走 getaddrinfo → nsswitch → 各 NSS 模块。当"命令行测着快、程序却慢"时,第一个该看的就是 /etc/nsswitch.conf 的 hosts 行,而不是上游 DNS 服务器。

