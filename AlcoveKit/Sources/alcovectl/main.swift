// alcovectl: a small command-line front end to AlcoveEngine, used by the test
// harness and for scripting. Commands:
//   alcovectl create --name NAME --os windows|linux|other [--iso PATH] [--disk-gib N] [--cpus N] [--memory-mib N] [--adopt-disk PATH] [--adopt-vars PATH] [--forward HOST:GUEST]... [--dir DIR]
//   alcovectl list [--dir DIR]
//   alcovectl args NAME [--dir DIR]          print the QEMU command line
//   alcovectl agent NAME [--dir DIR] [--command CMD]   probe the guest agent of a running VM
//   alcovectl serve [--dir DIR] [--socket PATH]   headless control server (docs/control-protocol.md) until SIGTERM
//   alcovectl run-script [--vm NAME] [--var KEY[=VALUE]]... [--snapshot NAME] [--socket PATH] [--in-process] [--] FILE   replay a script (--help lists the exit statuses)
//   alcovectl run NAME [--dir DIR] [--seconds N] [--screenshot PATH --after N] [--resize WxH --resize-after N]
//                 start headless, keep running N seconds (default 30), then power down;
//                 optionally take a QMP screenshot and/or ask the guest to change resolution
import Foundation
import AlcoveEngine
import AlcoveDisplayProtocol
import AlcoveControl
import AlcoveAgent

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

struct Args {
    var positional: [String] = []
    var options: [String: [String]] = [:]
    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                let value = (i + 1 < argv.count && !argv[i + 1].hasPrefix("--")) ? argv[i + 1] : ""
                if !value.isEmpty { i += 1 }
                options[key, default: []].append(value)
            } else {
                positional.append(a)
            }
            i += 1
        }
    }
    func value(_ k: String) -> String? { options[k]?.last }
    func int(_ k: String) -> Int? { value(k).flatMap(Int.init) }
}

if CommandLine.arguments.dropFirst().first == "run-script" { runScriptCommand(Array(CommandLine.arguments.dropFirst(2))) }
let args = Args(Array(CommandLine.arguments.dropFirst()))
let vmDir = resolvedVMDirectory(args.value("dir"))
try? FileManager.default.createDirectory(at: vmDir, withIntermediateDirectories: true)
let engine: EngineLocator.Engine
do { engine = try EngineLocator.standard().locate() } catch { fail("engine not found: \(error)") }

func bundle(named name: String) -> VMBundle {
    let b = VMBundle(url: vmDir.appendingPathComponent(name).appendingPathExtension(VMBundle.pathExtension))
    guard FileManager.default.fileExists(atPath: b.configURL.path) else { fail("no such VM: \(b.url.path)") }
    return b
}

switch args.positional.first {
case "create":
    guard let name = args.value("name"), let osName = args.value("os"), let os = VMConfig.GuestOS(rawValue: osName) else {
        fail("usage: alcovectl create --name NAME --os windows|linux|other [--iso PATH] ...")
    }
    var config = VMConfig.defaults(name: name, guestOS: os, installISO: args.value("iso"))
    if let n = args.int("cpus") { config.cpuCount = n }
    if let n = args.int("memory-mib") { config.memoryMiB = n }
    if let n = args.int("disk-gib") { config.disks[0].sizeGiB = n }
    if let bus = args.value("disk-bus").flatMap(VMConfig.DiskBus.init(rawValue:)) { config.disks[0].bus = bus }
    if let d = args.value("display").flatMap(VMConfig.DisplayDevice.init(rawValue:)) { config.display = d }
    var forwards: [VMConfig.PortForward] = []
    for f in args.options["forward"] ?? [] {
        let parts = f.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { fail("bad --forward \(f); expected HOST:GUEST") }
        forwards.append(.init(hostPort: parts[0], guestPort: parts[1]))
    }
    config.network = args.value("network") == "none" ? .none : .user(portForwards: forwards)
    let adoptDisk = args.value("adopt-disk")
    if adoptDisk != nil {
        // create the bundle without touching the disk, then move the existing image in
        var stub = config
        stub.disks = []
        let url = vmDir.appendingPathComponent(name).appendingPathExtension(VMBundle.pathExtension)
        guard !FileManager.default.fileExists(atPath: url.path) else { fail("exists: \(url.path)") }
        try! FileManager.default.createDirectory(at: url.appendingPathComponent("run"), withIntermediateDirectories: true)
        let b = VMBundle(url: url)
        try! FileManager.default.moveItem(atPath: adoptDisk!, toPath: b.diskURL(config.disks[0]).path)
        if let vars = args.value("adopt-vars") {
            try! FileManager.default.copyItem(atPath: vars, toPath: b.efiVarsURL.path)
        } else {
            try! b.resetFirmwareVars(engine: engine)
        }
        try! b.save(config)
        print(b.url.path)
    } else {
        do {
            let b = try VMBundle.create(config, in: vmDir, engine: engine)
            print(b.url.path)
        } catch { fail("create failed: \(error)") }
    }
case "list":
    for b in VMBundle.list(in: vmDir) {
        let c = try? b.loadConfig()
        print("\(c?.name ?? "?")\t\(c?.guestOS.rawValue ?? "?")\t\(c?.cpuCount ?? 0) cpu\t\(c?.memoryMiB ?? 0) MiB\t\(b.isSuspended ? "suspended" : "")\t\(b.url.path)")
    }
case "args":
    guard args.positional.count > 1 else { fail("usage: alcovectl args NAME") }
    let b = bundle(named: args.positional[1])
    let c = try! b.loadConfig()
    print(([engine.qemuSystem] + QEMUCommandBuilder(engine: engine).arguments(for: c, bundle: b)).joined(separator: " \\\n  "))
case "run":
    guard args.positional.count > 1 else { fail("usage: alcovectl run NAME [--seconds N]") }
    let b = bundle(named: args.positional[1])
    let c = try! b.loadConfig()
    let seconds = args.int("seconds") ?? 30
    let vm = VMController(bundle: b, config: c, engine: engine)
    let screenshotPath = args.value("screenshot")
    let screenshotAfter = args.int("after") ?? 60
    let resize = args.value("resize")?.split(separator: "x").compactMap { Int($0) }
    let resizeAfter = args.int("resize-after") ?? 45
    // top-level code is main-actor isolated; run the VM work detached and park the main thread
    Task.detached {
        do {
            try await vm.start()
            print("running (state \(await vm.state)); qmp \(b.qmpSocketPath)")
            // watch the display stream so resolution changes are visible in the log
            if let display = await vm.display {
                Task.detached {
                    for await m in display.messages {
                        if case .switchSurface(let sw) = m { print("display: \(sw.w)x\(sw.h)") }
                    }
                }
            }
            var elapsed = 0
            while elapsed < seconds {
                try await Task.sleep(for: .seconds(1))
                elapsed += 1
                if let resize, resize.count == 2, elapsed == resizeAfter, let display = await vm.display {
                    display.send(.ui(con: 0, w: resize[0], h: resize[1]))
                    print("sent ui \(resize[0])x\(resize[1])")
                }
                if let screenshotPath, elapsed == screenshotAfter {
                    try await vm.screenshot(to: URL(fileURLWithPath: screenshotPath))
                    print("screenshot \(screenshotPath)")
                }
            }
            try await vm.shutdown(force: false, gracePeriod: .seconds(60))
            print("stopped (state \(await vm.state))")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("run failed: \(error)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
case "agent":
    guard args.positional.count > 1 else { fail("usage: alcovectl agent NAME [--command CMD]") }
    let b = bundle(named: args.positional[1])
    let c = try! b.loadConfig()
    let command = args.value("command")
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        let client = AgentClient()
        do {
            try await client.connect(port: c.agentHostPort, expectedToken: c.agentToken, timeout: .seconds(8))
            let hello = await client.hello
            print("connected on port \(c.agentHostPort): os=\(hello?.os ?? "?") agent=\(hello?.agentVersion ?? "?") caps=\(hello?.capabilities ?? [])")
            if let command {
                let r = try await client.exec(command)
                print("exit \(r.code)\n\(r.output)")
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("agent probe failed (port \(c.agentHostPort), token \(c.agentToken)): \(error)\n".utf8))
            exit(1)
        }
        sem.signal()
    }
    dispatchMain()
case "serve":
    let socketPath = args.value("socket") ?? ControlServer.defaultSocketPath
    if ControlServer.isAlive(at: socketPath) {
        fail("a control server is already running at \(socketPath) (the Alcove app, or another alcovectl serve)")
    }
    let registry = HeadlessRegistry(directory: vmDir, engine: engine)
    let handler = ControlHandler(registry: registry, hostKind: "headless", engineDescription: engine.qemuSystem)
    let server = ControlServer(handler: handler, socketPath: socketPath)
    do { try server.start(loadingRecognizers: true) } catch { fail("cannot start control server: \(error)") }
    print("alcove control server (headless) listening at \(socketPath); VMs in \(vmDir.path)")
    let stop = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let shutdown: @Sendable () -> Void = {
        Task.detached {
            await handler.shutdown()
            await registry.stopAll()
            server.stop()
            exit(0)
        }
    }
    stop.setEventHandler(handler: shutdown); sigint.setEventHandler(handler: shutdown)
    stop.resume(); sigint.resume()
    dispatchMain()
default:
    fail("usage: alcovectl create|list|args|run|run-script|serve ...")
}
