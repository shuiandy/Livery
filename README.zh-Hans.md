# Livery

<p align="center">
  <img src="Design/AppIcon-256.png" width="128" alt="Livery">
</p>

<p align="center">给 Mac 上的 App 换图标。</p>

<p align="center"><a href="README.md">English</a> · 简体中文</p>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Design/window-dark.png">
  <img src="Design/window-light.png" alt="Livery 主窗口：app 网格、检查器，以及一条关于图标被更新抹掉的 app 的横幅">
</picture>

Livery 给应用程序文件夹里的任何 app 换一张图标。可以从约 30,000 张社区图标的目录里直接在检查器中挑，也可以用自己的 `.icns` 或 `.png`，
点一下就写进去。Livery 会给每张用过的图标留一份副本，app 更新把图标抹掉时自动补回去，选好的图标就一直是选好的样子。
界面有英文和简体中文，跟随系统语言。

## 它能做什么

- **挑图标。** 选中一个 app，检查器按下载量列出图标目录里为它准备的图标，点一张就下载并写入 bundle。
  *Search more…* 打开完整搜索，*Choose file…* 用本地的 `.icns` 或 `.png`。
- **把每张图标放到 macOS 的网格上。** 社区作品常常不守苹果图标共有的尺寸和圆角。Livery 会测量每张图标，缩放或裁切，让它在程序坞里和邻居齐平。见[图标网格](#图标网格)。
- **换上了就不会丢。** app 更新经常把自定义图标抹掉。launch agent 盯着两个 Applications 目录，把保存的图标写回去；
  app 里能看到坏了什么、为什么坏，一键修复。见[图标为什么会在更新后消失](#图标为什么会在更新后消失)。
- **root 所有的 app 也能换。** App Store 和 pkg 安装的 app 以你的身份写不进去。app 内的一个小特权 helper 在两次一次性授权后代为写入。见[权限](#权限)。
- **终端里也能用。** `livery` 能做 app 能做的一切，还能导入 Replacicon 管理的图标。

Livery 列出 `/Applications` 和 `~/Applications` 下的全部 app，含一层厂商目录，所以 Setapp 和 Utilities 也在内。
它由一个 SwiftUI app、一个命令行工具和一个 launch agent 组成，共用同一个核心，除 macOS SDK 外没有任何依赖。

## 环境要求

- macOS 15 或更高。
- Xcode 16 或更高，需要 Swift 6 工具链。
- 登录钥匙串里有一张 Apple Development 证书。在 Xcode 的 Settings > Accounts 里用任意 Apple ID 登录后 Xcode 会自动生成，免费账号就够。
  安装脚本用它签名，下面提到的权限授权才能在重新编译后继续有效。

## 编译与安装

```bash
git clone https://github.com/shuiandy/Livery.git
cd Livery
./install-app.sh
```

`install-app.sh` 以 release 模式编译，把 helper 打进 `Livery.app`，用你的证书签名，把命令行工具装到 `~/.local/bin/livery`，
然后通过一个新目录替换 `~/Applications/Livery.app` 并重新启动。验证不通过或启动失败的构建不会动已安装的版本。
单独运行 `./install.sh` 只安装命令行工具，agent 已安装的话会一并重载。

没有证书时两个脚本都会停下。`LIVERY_ALLOW_ADHOC=1` 可以改用 ad-hoc 签名，代价是每次重新编译在 macOS 眼里都是一个新身份，
所有授权都要重新给，而且特权 helper 因为没有可信任的 team 而完全不工作。

没有可下载的构建。把 bundle 交给另一台 Mac 需要 Developer ID 证书和公证，二者都要付费的 Apple Developer Program，
否则 Gatekeeper 会拒绝下载来的副本。从源码编译只要一分钟。

绝对不要用 `cp` 原地覆盖正在运行的 Mach-O：内核在 vnode 上缓存着旧的代码签名哈希，之后每次执行都会被 `OS_REASON_CODESIGNING` 杀掉。
两个脚本都是通过新 inode 替换二进制，原因就在这里。

## 使用 app

- **选图标。** 选中一个 app，检查器按下载量列出目录里的候选，点一张就写入。*Search more…* 打开搜索面板，*Choose file…* 用本地的 `.icns` 或 `.png`。
- **修复。** 需要处理的 app 会在侧栏计数，网格上方也有横幅。*Fix all* 一次全修，检查器里的 *Repair icon* 只修一个。
- **后台监视。** Settings > Background agent 安装 launch agent。侧栏底部的卡片显示它在盯哪些目录，以及 macOS 是否允许它写入。
- **root 所有的 app。** Settings > Privileged helper > Set up 引导完成 macOS 需要的两次授权，每一步都有一盏反映系统真实状态的状态灯。
- **撤销。** 检查器里的 *Reset to stock icon* 恢复一个 app；菜单 Icons > Restore All Stock Icons 恢复全部并清空库，图标文件仍保留。

界面语言跟随系统。想单独给 Livery 切换，去系统设置 > 通用 > 语言与地区 > 应用程序，把 Livery 加进去。

窗口在激活时、每 30 秒、以及库发生变化时都会重新读取所有 app，所以 agent 或命令行做的修复会自己出现。

## 命令行

```bash
livery search chrome                     # 编号的候选拼图在预览中打开（Iconic 目录，不需要 key）
livery set "Google Chrome" --pick 3      # 应用第三个结果并开始追踪
livery set Wren --file ~/Downloads/wren.icns
livery list                              # 已追踪的 app 及当前健康状态
livery check --fix                       # 检查每个追踪的 app，重写坏掉的
livery reset Wren                        # 恢复 app 自己的图标，停止追踪
livery reset --all                       # 全部撤销
livery import-replacicon --apply         # 迁移 Replacicon 当前管理的图标
livery agent install                     # launch agent，KeepAlive，日志在 ~/Library/Logs/livery.log
livery refit --apply                     # 把不守 macOS 图标网格的图标重新缩放
livery key <KEY>                         # 可选：macosicons.com 的 key，供 --source macosicons 使用
```

`<app>` 可以是显示名、bundle identifier，或 `.app` 的路径。`livery --help` 列出全部命令和选项。命令行工具只有英文。

## 权限

往别的 app 的 bundle 里写 `Icon\r` 受 TCC 的 App Management（`kTCCServiceSystemPolicyAppBundles`）管制。
交互式 shell 从终端 app 继承授权；launch agent 和 app 各自需要一份。app 第一次修复图标时会自己弹出请求。
agent 要在系统设置 > 隐私与安全性 > App 管理里加一次 `~/.local/bin/livery`，否则每次修复都会在日志里留下 "NSWorkspace refused"。

App Store 和 pkg 安装的 app 属主是 `root:wheel`，以你的身份运行的任何进程都写不进去。Livery 通过 `LiveryHelper` 写这些 bundle，
它是 app bundle 内用 `SMAppService` 注册的 LaunchDaemon。它只暴露两个操作：往 bundle 写一个图标，或删掉一个；
每个 XPC 连接都必须满足一条代码签名要求，指向构建它的 team 和 Livery 的 identifier，别的进程驱动不了它。
team 在运行时从 helper 自己的签名里读出，`com.apple.application-identifier` 授权在编译时由签名证书生成，
所以用别的证书签名的 fork 会信任自己那份 app，不用改任何源码。

helper 需要两次一次性授权，都在图形界面里完成，不用终端，不用密码：

1. **登录项与扩展 > 允许在后台运行**：打开 Livery。这让守护进程可以运行。
2. **隐私与安全性 > App 管理**：打开 Livery。不用手动添加：helper 的第一次请求会让 macOS 自己建行并弹出标准对话框
   （设置面板里的 *Ask macOS* 按钮就是恰好一次请求）。tccd 把 bundle 内的守护进程归到 bundle 上，所以这一行同时覆盖 app 和 helper。

之后所有写入都静默完成，包括 app 更新后 bundle 重新变成 root 所有时的自动修复。授权绑定的是 helper 的代码签名身份，
不是任何 app 的属主，所以 Livery 和它管理的 app 更新后都不受影响。

需要第二步是因为 LaunchDaemon 以 audit user 0 运行，TCC 会拿系统库来判 App Management，而系统设置把授权写进的是用户库。
helper 调用 `audit_session_port` 和 `audit_session_join` 加入调用方用户的 audit session，查询就落到那个用户的库里，授权正好在那。
不加入的话，无论用户批准什么，tccd 一律回 `auth_value absent`。

## 隐私

Livery 只为两件事联网：按 app 名字查图标，以及下载你选中的图标。没有统计、没有崩溃上报、没有更新检查。

选中一个 app 会把它的名字发给图标目录，除此之外什么都不发，这样检查器才能显示候选。Settings > Icon catalog 可以关掉；
关掉后只有点 *Look up icons* 或 *Search more…* 才会查询。

## 图标为什么会在更新后消失

`.app` 上的自定义图标其实是两样东西：bundle 的 `com.apple.FinderInfo` 扩展属性里的 `kHasCustomIcon` 标志位，
以及 bundle 内一个叫 `Icon\r` 的文件，图标数据存在它的资源分支里。原地重写 bundle 的更新器（Setapp、Keystone、pkg 安装器）
会保留目录和扩展属性，但把 `Icon\r` 删掉。访达于是相信标志位、找不到数据，画出一个普通文件夹。只检查标志位的工具会认为这些 app 一切正常，永远不去修。

Livery 两半都检查，任何一半缺失就重写图标。另一种失败它也能处理：bundle 被整个替换，标志位被清掉，原厂图标回来了。
launch agent 用 FSEvents 盯着两个 Applications 目录，每十分钟再扫一遍，通常你还没看见文件夹它就修好了。

## 状态与安全

状态存在 `~/Library/Application Support/Livery/`：保存的图标和 `manifest.json`。

manifest 由三个进程写入：app、命令行工具和 watcher。每次读改写都在一把独占 `flock` 下完成整个周期，谁也不会丢掉别人的条目。
解析不了的 manifest 会被挪到一边并从 `manifest.backup.json` 恢复，而不是当成空库；更新格式写出的 manifest 会被拒绝而不是覆盖。

换图标是这把锁下的一个事务：新图标先以独立文件名暂存，旧图标放到一旁，写入 manifest 条目，最后才写 bundle。
bundle 写入失败会把旧图标和条目放回去；进程在中途死掉会留下一个条目，由 `check --fix` 补完。库里从不会记录一个访达没有显示的图标。
中断写入留下的残余会在启动时清扫。

追踪的 app 以其 `Info.plist` 里的 bundle identifier 识别，不是路径，所以同名位置装了别的 app 也不会被写入。
这个 identifier 来自别人的 bundle，又被用作文件名，所以先经过消毒：`[A-Za-z0-9._-]` 之外的字符被折叠，并追加摘要以保持不同 identifier 各不相同。

helper 在判断路径前解析所有链接，只接受 `/Applications` 或调用方自己的 `~/Applications` 下至多一层厂商目录内的真实 bundle，
只读取带 icns 或 PNG 文件头的普通文件作为图标，加入不了调用方的 audit session 就拒绝写入，且一次只做一个写入。

下载固定走 HTTPS，重定向会重新检查而不是盲目跟随，名字或解析地址指向本机或私有网络的主机被拒绝，响应一超过体积上限立即截断，图像画布也有上限。

`swift test` 覆盖并发写入、损坏和事务中途失败下的 manifest、全部恢复、路径消毒、bundle 身份、图标网格规则、helper 的输入校验（含链接和管道）以及网络守卫。

## 图标网格

macOS 的图标坐落在一张网格上：1024 pt 画布上一块 824 pt 的圆角贴片，圆角半径 185 pt，留白是 Dock 用来均匀排布的。
社区目录里到处是无视这张网格的作品：涂满四角的方形贴纸，或者铺满整张画布的贴片。原样写进去会比周围所有图标都更大更方。

Livery 会测量每个入库图标的不透明包围盒。覆盖画布超过 90% 的作品缩放到贴片上，四角被涂满的作品裁成圆角。
已经守网格的图标逐字节原样保存。app 里的缩略图走同一套代码，所以预览即所得。
`livery refit` 报告库里不守网格的图标，`livery refit --apply` 把它们修正。

## 卸载

1. Settings > Background agent 关掉，或运行 `livery agent uninstall`。
2. Settings > Privileged helper > Remove，或 `open ~/Applications/Livery.app --args --remove-helper`。
3. 想让所有 app 回到自己的图标，运行 `livery reset --all`。
4. 删除 `~/Applications/Livery.app`、`~/.local/bin/livery`、`~/Library/Application Support/Livery`、
   `~/Library/Caches/Livery`、`~/Library/Logs/livery.log` 和 `~/.config/livery`。

Livery 在登录项和 App 管理里留下的行可以在系统设置里手动删掉。

## 做一个 fork

identifier 分别是 `com.shuiandy.Livery`（app）、`com.shuiandy.Livery.helper`（helper 及其 mach service）和
`com.shuiandy.livery`（命令行工具和 launch agent）。每个都只定义在一处，helper 信任的 identifier 从它自己的推导，
所以改名就是一次查找替换。可信的 team 从不写在源码里，它来自给构建签名的那张证书。

## 致谢

图标来自两个共用同一个社区图库的目录，约 30,000 张：[Iconic](https://icons.ahmetdedeler.com)，作者 Ahmet Dedeler，
不需要 key，是默认来源；[macosicons.com](https://macosicons.com)，需要一个免费 key，免费计划每月 50 次调用。
那里的每一张图标都属于画它的人。Livery 只替你下载你选中的那一张，不再分发任何一张。

## 已知限制

- 没有可下载的构建，因为没有 Developer ID 证书。请从源码编译。
- 重置只能回到原厂图标，无法撤销到它之前用过的那张自定义图标。
- 下载的私有网络检查发生在查询时。查询与连接之间记录发生变化是客户端看不到的；目录主机是固定的。

## 许可证

MIT，见 [LICENSE](LICENSE)。
