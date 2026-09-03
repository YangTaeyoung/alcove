// alcovectl: a small command-line front end to AlcoveEngine, used by the test
// harness and for scripting. Commands:
//   alcovectl create --name NAME --os windows|linux|other [--iso PATH] [--disk-gib N] [--cpus N] [--memory-mib N] [--adopt-disk PATH] [--adopt-vars PATH] [--forward HOST:GUEST]... [--dir DIR]
//   alcovectl list [--dir DIR]
//   alcovectl args NAME [--dir DIR]          print the QEMU command line
//   alcovectl run NAME [--dir DIR] [--seconds N]   start headless, keep running N seconds (default 30), then power down
import Foundation
import AlcoveEngine

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

let args = Args(Array(CommandLine.arguments.dropFirst()))
let vmDir = URL(fileURLWithPath: args.value("dir") ?? ProcessInfo.processInfo.environment["ALCOVE_VM_DIR"]
    ?? (NSHomeDirectory() + "/Library/Application Support/Alcove/VMs"))
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
    // top-level code is main-actor isolated; run the VM work detached and park the main thread
    Task.detached {
        do {
            try await vm.start()
            print("running (state \(await vm.state)); qmp \(b.qmpSocketPath)")
            try await Task.sleep(for: .seconds(seconds))
            try await vm.shutdown(force: false, gracePeriod: .seconds(60))
            print("stopped (state \(await vm.state))")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("run failed: \(error)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
default:
    fail("usage: alcovectl create|list|args|run ...")
}
