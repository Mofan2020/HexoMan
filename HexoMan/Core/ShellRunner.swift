//
//  ShellRunner.swift
//  HexoMan
//
//  统一的子进程执行器。Hexo、git 全走这里，日志也由它汇总到界面。
//

import Darwin
import Foundation

/// 一次执行的结果。
struct ShellResult {
    var exitCode: Int32
    var output: String

    var success: Bool { exitCode == 0 }

    /// 从输出里捞出 git 的 fatal 之类信息，给 UI 弹错误用。
    var errorSummary: String? {
        guard !success else { return nil }
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let meaningful = lines.filter { !$0.isEmpty }
        return meaningful.suffix(5).joined(separator: "\n")
    }
}

/// 日志行的归属。
enum LogStream {
    case standardOutput
    case standardError
    case meta
}

/// 界面里的一行日志。
struct LogLine: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var stream: LogStream
    var timestamp: Date

    /// stdout/stderr 里的 ANSI 颜色码在 SwiftUI Text 里是乱码，入库前先剥掉。
    var displayText: String {
        ShellRunner.stripANSI(text)
    }
}

/// 长驻任务的句柄。`hexo server` 这类不会自己退出的命令靠它停止。
final class RunningJob {
    let id: String
    let label: String
    let process: Process
    let startedAt: Date

    init(id: String, label: String, process: Process) {
        self.id = id
        self.label = label
        self.process = process
        self.startedAt = Date()
    }

    var isRunning: Bool { process.isRunning }
}

/// 串行缓冲器：readabilityHandler 回调在任意线程，只能先加锁攒行，再交给主线程。
private final class LineBuffer {
    private let lock = NSLock()
    private var storage: [LogLine] = []

    func append(_ line: LogLine) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    func drain() -> [LogLine] {
        lock.lock()
        defer { lock.unlock() }
        let result = storage
        storage.removeAll()
        return result
    }
}

/// 所有外部命令的统一入口。挂在主线程上，界面直接订阅它的日志。
@MainActor
final class ShellRunner: ObservableObject {

    /// 日志保留上限，防止长时间 serve 撑爆内存。
    private let maxLines = 4000

    @Published private(set) var lines: [LogLine] = []
    @Published private(set) var jobs: [String: RunningJob] = [:]

    /// 用户真实 shell 环境的缓存。nil 表示还没探测过。
    ///
    /// 界面上要显示，所以是 @Published。
    @Published private(set) var environment: ShellEnvironment?

    /// 同一份缓存的无隔离副本。
    ///
    /// 为什么要两份：`HexoService`、`HexoEnvironment` 这些是纯逻辑类型，
    /// 它们只想要「hexo 在不在」这一个答案，不该被迫 @MainActor。
    /// Swift 5 模式下把整个 ShellRunner 放开隔离不安全（logs 会被并发写坏），
    /// 所以单独抽一个加锁的小盒子出来，锁的粒度只覆盖一次字典读。
    private let cache = EnvironmentCache()

    /// 正在做 bootstrap 探测。多个调用方同时等同一个任务，避免重复付 1~2 秒的 zshrc 代价。
    private var environmentTask: Task<ShellEnvironment?, Never>?

    /// 显式指定的 rc 文件路径，空表示自动找标准三件套。
    @Published var customRCPath: String = ""

    /// 关掉之后退回「继承 app 启动时的环境」，也就是几乎什么都找不到的老行为。
    /// 留这个开关是因为有人会故意用干净环境跑 HexoMan，留个后路。
    @Published var usesShellEnvironment: Bool = true

    // MARK: - 公开接口

    /// 执行一次性命令，跑完即返回。
    @discardableResult
    func run(
        _ label: String,
        executable: String,
        arguments: [String],
        workingDirectory: String
    ) async -> ShellResult {
        // 子进程必须先拿到用户真实的 PATH，否则 brew 装的 node 永远找不到。
        // 走缓存，只在首次触发 bootstrap。
        let environment = await resolvedEnvironment()
        let process = makeProcess(executable: executable, arguments: arguments, workingDirectory: workingDirectory, environment: environment)
        let collector = OutputCollector()
        attachCollectors(to: process, into: collector)

        emit("\(ShellRunner.displayCommand(executable, arguments))", stream: .meta)
        do {
            try process.run()
        } catch {
            emit("启动失败：\(error.localizedDescription)", stream: .standardError)
            return ShellResult(exitCode: -1, output: error.localizedDescription)
        }

        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }

        // 等最后一轮 readabilityHandler 回调排空再收尾
        try? await Task.sleep(nanoseconds: 60_000_000)
        let output = collector.text()

        emit("退出码 \(process.terminationStatus)", stream: .meta)
        return ShellResult(exitCode: process.terminationStatus, output: output)
    }

    /// 启动长驻任务（如 `hexo server`），返回句柄 id。
    @discardableResult
    func startService(
        label: String,
        executable: String,
        arguments: [String],
        workingDirectory: String
    ) -> String {
        let id = "\(label)-\(UUID().uuidString.prefix(8))"
        // startService 是同步的，不能 await。这里若缓存尚未建立就直接用继承环境，
        // 用户从界面点「预览」之前通常已经体检过工具链，缓存早就在了。
        let process = makeProcess(executable: executable, arguments: arguments, workingDirectory: workingDirectory, environment: environment)
        attachCollectors(to: process, into: nil)

        do {
            try process.run()
        } catch {
            emit("启动失败：\(error.localizedDescription)", stream: .standardError)
            return ""
        }

        let job = RunningJob(id: id, label: label, process: process)
        jobs[id] = job

        emit("\(ShellRunner.displayCommand(executable, arguments))", stream: .meta)
        emit("▶ \(label) 已启动（pid \(process.processIdentifier)）", stream: .meta)
        return id
    }

    /// 停止某个长驻任务。
    func stop(jobID: String) {
        guard let job = jobs.removeValue(forKey: jobID) else { return }
        terminate(job)
    }

    func stopAll() {
        let running = jobs.values
        jobs.removeAll()
        running.forEach(terminate)
    }

    /// 停止后清掉残留的输出通道，避免僵尸回调继续往日志里写。
    func clear() {
        lines.removeAll()
    }

    // MARK: - 进程构造

    /// 拿到（必要时先 bootstrap）用户真实环境。
    private func resolvedEnvironment() async -> ShellEnvironment? {
        guard usesShellEnvironment else { return nil }
        if let cached = cache.value { return cached }

        // 已经有探测在跑就等它，不要起第二个 —— 每个都得好几秒。
        if let environmentTask { return await environmentTask.value }

        let task = Task { @MainActor [customRCPath] in
            await ShellEnvironmentResolver.resolve(customRCPath: customRCPath)
        }
        environmentTask = task
        let resolved = await task.value
        environmentTask = nil
        cache.value = resolved
        environment = resolved
        return resolved
    }

    /// 主动预热环境。启动服务和长流程之前调一次，避免用同步路径撞上未初始化的缓存。
    @discardableResult
    func prewarmEnvironment() async -> ShellEnvironment? {
        await resolvedEnvironment()
    }

    /// 丢弃缓存，下次执行时重新读一遍 rc 文件。
    ///
    /// 用户刚在终端里 `brew install node` 之后需要这个 —— 否则还在用旧 PATH。
    func invalidateEnvironment() {
        cache.value = nil
        environmentTask = nil
        environment = nil
    }

    /// 同步地判断某个命令在用户环境里存不存在。
    ///
    /// 刻意不隔离：调用方（HexoService / HexoCLIBootstrap）是纯逻辑代码，
    /// 让它们为了问一句「hexo 在不在」而全盘 @MainActor 化不值得。
    /// 缓存没建立时返回 nil，调用方需要走「那就装一个」的分支。
    nonisolated func resolvedExecutablePath(named name: String) -> String? {
        cache.value?.executablePath(named: name)
    }

    private func makeProcess(
        executable: String,
        arguments: [String],
        workingDirectory: String,
        environment resolved: ShellEnvironment?
    ) -> Process {
        let process = Process()
        // 走 /usr/bin/env 才能解析 PATH 里的 node / hexo / git
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        // 底色是用户 bootstrap 出来的真实环境，没有就用继承环境。
        var environment = resolved?.variables ?? ProcessInfo.processInfo.environment
        // 去掉 ANSI 颜色码，SwiftUI 的 Text 显示它们就是一堆乱码
        environment["FORCE_COLOR"] = "0"
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        // 强制 UTF-8，否则中文文件名在不同 locale 下会乱码
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        // npm 在非交互下会等 TTY 的输入提示，stdin 已经接到 nullDevice，
        // 这里再把 CI 标记上，让它直接走非交互分支而不是挂着。
        environment["CI"] = "1"
        environment["npm_config_yes"] = "true"
        process.environment = environment

        return process
    }

    private func attachCollectors(to process: Process, into collector: OutputCollector?) {
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        attach(outPipe, stream: .standardOutput, collector: collector)
        attach(errPipe, stream: .standardError, collector: collector)
    }

    private func attach(_ pipe: Pipe, stream: LogStream, collector: OutputCollector?) {
        let buffer = LineBuffer()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard chunk.isEmpty == false else { return }

            for line in Self.splitLines(Data(chunk)) {
                collector?.append(line)
                buffer.append(LogLine(text: line, stream: stream, timestamp: Date()))
            }

            // readabilityHandler 不在主线程，攒完整行后跨回去刷新界面
            let drained = buffer.drain()
            guard !drained.isEmpty, let self else { return }
            Task { @MainActor in
                self.append(drained)
            }
        }
    }

    private func append(_ incoming: [LogLine]) {
        lines.append(contentsOf: incoming)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    private func emit(_ text: String, stream: LogStream) {
        append([LogLine(text: text, stream: stream, timestamp: Date())])
    }

    private func terminate(_ job: RunningJob) {
        guard job.process.isRunning else {
            emit("■ \(job.label) 已停止", stream: .meta)
            return
        }

        job.process.terminate()

        // 给 1.5 秒体面退出时间，不行就 SIGKILL。
        // hexo server 会派生子进程，只 terminate 父进程经常留一堆孤儿。
        let process = job.process
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            self?.emit("■ \(job.label) 已停止", stream: .meta)
        }
    }

    // MARK: - 文本工具

    /// 把 Data 切成完整行。结尾没有换行的残片会留在缓冲里等下一段。
    private nonisolated static func splitLines(_ data: Data) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        return text
            .components(separatedBy: "\n")
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            .filter { !$0.isEmpty }
    }

    /// 拼出给人看的命令行，方便对着终端复现。
    nonisolated static func displayCommand(_ executable: String, _ arguments: [String]) -> String {
        "$ " + ([executable] + arguments)
            .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
            .joined(separator: " ")
    }

    /// 去掉 ANSI 转义序列。
    nonisolated static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }

        var result = ""
        var inEscape = false

        for character in text {
            if character == "\u{1B}" {
                inEscape = true
                continue
            }
            if inEscape {
                // CSI 序列以字母结尾
                if character.isLetter { inEscape = false }
                continue
            }
            result.append(character)
        }

        return result
    }
}

/// 线程安全的 shell 环境缓存盒子。
///
/// ShellEnvironment 是值类型（内部是一个 `[String: String]`），
/// 整体替换、整体读取，锁只保护指针交换，所以不会有撕裂读的风险。
private final class EnvironmentCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: ShellEnvironment?

    var value: ShellEnvironment? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

/// 一次性命令的输出收集器，供 `run()` 拿完整文本用。
private final class OutputCollector {    private let lock = NSLock()
    private var storage = ""

    func append(_ line: String) {
        lock.lock()
        storage += line + "\n"
        lock.unlock()
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
