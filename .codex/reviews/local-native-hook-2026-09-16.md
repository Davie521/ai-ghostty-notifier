# Native hook migration — local code review

日期：2026-09-16。工作树：`claude-ghostty-notify_hook-migration`，分支：
`refactor-hook-agent`。基线：`9a3440b9237eba0b460f80939059e27cdf7d343d`。

审查初始快照涵盖相对 HEAD 的已跟踪改动及新增文件，共 85 个文件。
按 Swift、Python、General 分配功能审查，另做独立 Security 全量审查。
只有协调者应用修复；三个独立审查者随后复核修复。

## Findings

以下原始定位对应修复前快照；每项均经 patch 范围分类，属于本次改动范围。

### HIGH / in-scope — 停机后仍可创建未取消的任务

- 原始定位：`agent/Sources/NotifyCore/HookProcessor.swift:115`，introduced。
- 证据：接收任务可以在 `journal.prepare` 挂起期间被 shutdown 取消。恢复后
  仍创建新的非结构化 Task，不在 shutdown 已捕获的取消集合中。确定性复现中，
  prompt 回调或 Stop 的 binding/content/notification 仍执行；新增回归在修复前失败。
- 修复：每次相关 actor await 后重检取消与 `closing`，且在 `valid` 返回前
  再次重检。当前定位：`HookProcessor.swift:94`。
- 验证：`shutdownDuringIntakeCannotCreateUncancelledWork` 分别覆盖 prompt、Stop；
  Swift 独立复核确认创建 pending 前不再有未防护的挂起点。fixed。

### MEDIUM / in-scope — 停止消费后仍对外宣称就绪

- 原始定位：`agent/Sources/ghostty-notify-agent/Agent.swift:161`，introduced。
- 证据：停止 spool 后等待异步终端清理，但 ready/capabilities 直到最终退出才
  删除；期间到来的 hook 仍可能选择已经停止消费的 resident。
- 修复：新增 `ResidentReadiness`，在 `spool.stop()` 前撤销 admission，保留
  singleton PID 直到退出；拒绝迟到的授权回调重新发布就绪标记。
  当前定位：`Agent.swift:162`。
- 验证：`shutdownRevokesAdmissionAndIgnoresLateAuthorization` 验证拒绝新事件、
  保留 PID、迟到发布无效；真实常驻进程退出和重启检查通过。fixed。

### MEDIUM / in-scope — spool 内容写完后才收紧权限

- 原始定位：`agent/Sources/NotifyCore/HookTransport.swift:16`，enlarged。
- 证据：旧 spool 目录可能为 0755，临时文件写入时为 0644，之后才 chmod。
  迁移后的 payload 含 prompt/settings，扩大了泄露影响。在可遍历目录中存在
  本地其他用户读取窗口；隔离诊断观察到修改前的可读临时文件和假 payload。
- 修复：创建前收紧目录为 0700，以 `open(O_CREAT|O_EXCL, 0600)` 创建临时
  文件，再通过文件描述符写入并 rename。当前定位：`HookTransport.swift:25`。
- 验证：旧目录权限升级回归通过；安全审查者对最终构建运行 20 次隔离诊断，
  只观察到 0600 临时/最终文件和 0700 spool，未再观察到可读窗口。fixed。

### MEDIUM / in-scope — runtime-only 升级遗漏手动启动的 resident

- 原始定位：`scripts/install-agent.sh:101`，introduced。
- 证据：`--no-start` 原本只拒绝已有 LaunchAgent plist；没有 plist 的活跃
  resident 不受影响。隔离原生进程复现中安装成功、App 被替换，但旧进程继续运行。
- 修复：在安装写入前调用新只读模式 `--resident-pid`，复用原生进程身份检查；
  有活跃 resident 则拒绝升级，不发送信号。当前定位：`install-agent.sh:108`。
- 验证：真实 C fixture 验证旧进程和 App 字节不变；无关 PID 不被误拦；
  查询模式在空私有 HOME 不创建状态。fixed。

### MEDIUM / in-scope — bootstrap 复制失败会破坏旧 hook

- 原始定位：`install.sh:41`；相关 `scripts/install-codex.py:27`，introduced。
- 证据：原本先覆盖依赖新 bootstrap 的 launcher，随后才复制 `native-hook.sh`。
  注入 bootstrap 复制失败后，Claude 和 Codex 的已注册入口都因缺文件退出 1。
- 修复：先暂存并语法校验整个脚本集合，全部成功后优先发布 bootstrap，再逐文件
  原子替换 launcher。当前定位：`install.sh:38`、`install-codex.py:359`。
- 验证：复制、下载、语法失败均保留旧 hook；Codex 的配置和备份也保持不变。
  General 独立复核及 7 项相关隔离回归通过。fixed。

## Verdict

修复前：**WARNING**。

| Severity | In-scope | Out-of-scope |
| --- | ---: | ---: |
| CRITICAL | 0 | 0 |
| HIGH | 1 | 0 |
| MEDIUM | 4 | 0 |
| LOW | 0 | 0 |

修复后：**APPROVE**。以上 5 项全部关闭，独立复核未发现新的高置信度问题。
此结论是本地代码审查结论，不表示真实 UI 验收或远程 CI 已完成。

## Verification

- `swift test --package-path agent --quiet`：144 tests / 20 suites 通过。
- `bash scripts/build-agent.sh --build-only`：release 构建及 ad-hoc 签名通过。
- `codesign --verify --deep --strict build/ClaudeGhosttyNotify.app`：通过。
- `NATIVE_TEST_BINARY="$PWD/build/ClaudeGhosttyNotify.app/Contents/MacOS/ghostty-notify-agent" PYTHONPATH=tests python3 -m unittest test_native_hooks test_native_install -q`：32 通过（17 native entry + 15 isolated install）。
- `bash tests/test-agent.sh`：47 检查通过，使用真实构建和私有测试状态。
- `python3 -m unittest discover -s tests -p 'test_codex_hooks.py' -q`：50 通过
  （36 冻结历史 shell 行为测试 + 14 当前安装器测试，不是 50 个原生 runtime 测试）。
- 改动/新增 Swift 的 `swift-format lint --strict`、ShellCheck、安装脚本 Bash
  语法检查及 `git diff --check`：通过。

## Boundaries and remaining acceptance

- 未安装、替换或重启用户已安装的 App，未修改 main，未提交、推送或操作 PR。
  仅停止自己创建的测试进程，常驻集成测试清理了自己的合成通知。
- 真实 Ghostty 标签恢复、可见横幅、声音和通知点击仍需人工验收。
- GitHub CI 尚未运行；完整 Swift 格式检查中原有的未改文件问题没有顺手修改。
- 安装说明已同步。迁移文档的旧 benchmark 明确标为修复前历史快照，未当作
  本轮修复后的性能结果。
