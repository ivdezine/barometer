// Barometer: a menu bar icon that shows this Mac's CPU and memory as simple graphs.
// The icon is two live bars (CPU, memory used). Clicking it opens a panel with five minutes of
// history, load per core, load average, thermal state, the memory breakdown, pressure, swap and
// the apps holding the most memory, each with a Quit button.
// Every reading comes straight from the kernel (host_processor_info, host_statistics64, sysctl,
// proc_pid_rusage).
// Free page counts, which is what Node's os.freemem() reports, read near zero on a healthy Mac
// because macOS keeps idle memory busy as file cache; memory pressure is what says it is short.
// Build and usage: README.md beside this file.

import AppKit
import Charts
import SwiftUI

let bundleID = "com.ivdezine.barometer"
let interval = 2.0       // seconds between readings
let historyLength = 150  // five minutes of readings at that interval

// MARK: Readings

struct Load {
  var user = 0.0, system = 0.0
  var total: Double { user + system }
}

struct Memory {
  var total: UInt64, app: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0, cached: UInt64 = 0
  var used: UInt64 { app + wired + compressed }
  var free: UInt64 { total > used + cached ? total - used - cached : 0 }
}

enum Pressure: Int32 {
  case normal = 1, warning = 2, critical = 4
  var name: String {
    switch self { case .normal: "Normal"; case .warning: "Warning"; case .critical: "Critical" }
  }
}

struct Sample: Identifiable {
  let date: Date
  let cpu: Load
  let cores: [Load]
  let memory: Memory
  let pressure: Pressure
  let available: Int  // kern.memorystatus_level: percent of memory the kernel counts as available
  let swapUsed: UInt64, swapTotal: UInt64
  let loadAverage: [Double]
  let thermal: ProcessInfo.ThermalState
  var id: Date { date }
}

// An app or a background process and the memory it holds, its helper processes counted with it.
struct Consumer: Identifiable {
  enum Owner {
    case app(NSRunningApplication)  // can be asked to quit
    case system                     // an app that is part of macOS, such as Finder or the Dock
    case background                 // no app: daemons, command line tools, agents
  }
  let id: String
  let name: String
  let owner: Owner
  var bytes: UInt64 = 0
  var processes = 0
  var lead: (pid: pid_t, bytes: UInt64) = (0, 0)  // the largest member, which the test holds against top
  var quittable: NSRunningApplication? { if case .app(let a) = owner { a } else { nil } }
}

// Responsibility is how macOS ties a helper process to the app it works for: Firefox's content
// processes, Chrome's renderers, Safari's WebKit processes. The call is not in the public SDK, so it
// is looked up at run time (-2 is RTLD_DEFAULT); without it every process stands alone.
typealias ResponsibleFor = @convention(c) (pid_t) -> pid_t
let responsibleFor = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
  .map { unsafeBitCast($0, to: ResponsibleFor.self) }

func processName(_ pid: pid_t) -> String {
  var buffer = [CChar](repeating: 0, count: 256)
  return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : "Process \(pid)"
}

func sysctlValue<T: BitwiseCopyable>(_ name: String, _ fallback: T) -> T {
  var value = fallback
  var size = MemoryLayout<T>.size
  return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : fallback
}

func sysctlString(_ name: String) -> String? {
  var size = 0
  guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
  var buffer = [CChar](repeating: 0, count: size)
  guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
  return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

final class Reader {
  let host = mach_host_self()
  let page = UInt64(vm_kernel_page_size)
  // Core clusters, fastest first, as macOS names them (Super, Performance, Efficiency on recent Apple
  // silicon). Intel Macs report none, and the panel then gives the core count alone.
  let clusters: [(name: String, cores: Int)]
  private var previous: [[UInt32]] = []

  init() {
    clusters = (0..<Int(sysctlValue("hw.nperflevels", Int32(0)))).compactMap { i in
      guard let name = sysctlString("hw.perflevel\(i).name") else { return nil }
      return (name, Int(sysctlValue("hw.perflevel\(i).logicalcpu", Int32(0))))
    }
    previous = ticks()
  }

  // Cumulative ticks per core, indexed by CPU_STATE_USER, SYSTEM, IDLE and NICE. The kernel hands
  // back a buffer this process owns, so it is freed on every read or the app leaks each sample.
  func ticks() -> [[UInt32]] {
    var cpus: natural_t = 0
    var info: processor_info_array_t?
    var count: mach_msg_type_number_t = 0
    guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS, let info else { return [] }
    defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(count) * MemoryLayout<integer_t>.stride)) }
    let states = Int(CPU_STATE_MAX)
    return (0..<Int(cpus)).map { c in (0..<states).map { UInt32(bitPattern: info[c * states + $0]) } }
  }

  // Load since the previous read. Tick counters are 32 bits and wrap, hence the wrapping subtraction.
  func cpu() -> (total: Load, cores: [Load]) {
    let now = ticks()
    defer { previous = now }
    guard now.count == previous.count else { return (Load(), []) }
    let deltas = zip(now, previous).map { n, p in zip(n, p).map { Double($0 &- $1) } }
    func load(_ d: [Double]) -> Load {
      let all = d.reduce(0, +)
      guard all > 0 else { return Load() }
      return Load(user: (d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_NICE)]) / all, system: d[Int(CPU_STATE_SYSTEM)] / all)
    }
    let sum = deltas.reduce(into: [Double](repeating: 0, count: Int(CPU_STATE_MAX))) { acc, d in
      for i in d.indices { acc[i] += d[i] }
    }
    return (load(sum), deltas.map(load))
  }

  func memory() -> Memory {
    var m = Memory(total: ProcessInfo.processInfo.physicalMemory)
    var s = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let ok = withUnsafeMutablePointer(to: &s) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
    }
    guard ok == KERN_SUCCESS else { return m }
    // The split Activity Monitor draws: app memory is anonymous pages less the purgeable ones, and
    // cached files are file-backed pages plus purgeable ones, which macOS reclaims the moment an
    // app needs them. Used memory is app, wired and compressed, never total minus free pages.
    let anonymous = UInt64(s.internal_page_count), purgeable = UInt64(s.purgeable_count)
    m.app = (anonymous > purgeable ? anonymous - purgeable : 0) * page
    m.wired = UInt64(s.wire_count) * page
    m.compressed = UInt64(s.compressor_page_count) * page
    m.cached = (UInt64(s.external_page_count) + purgeable) * page
    return m
  }

  // The apps holding the most memory. Each process counts its physical footprint, the figure in
  // Activity Monitor's Memory column, which includes what macOS has compressed or swapped out for
  // it; resident size would undercount exactly the apps worth quitting. Other users' processes,
  // WindowServer and the system daemons among them, refuse the read and are left out.
  func consumers(limit: Int = 5) -> [Consumer] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) + 32)  // room for processes started since
    let listed = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    let apps = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
    var groups: [String: Consumer] = [:]
    for pid in pids.prefix(max(listed, 0)) where pid > 0 {
      var info = rusage_info_v4()
      let read = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
      }
      guard read == 0 else { continue }
      let responsible = responsibleFor?(pid) ?? -1
      let ownerPID = responsible > 0 ? responsible : pid
      let id: String, name: String, owner: Consumer.Owner
      if let app = apps[ownerPID] {
        id = "app:\(ownerPID)"
        name = app.localizedName ?? processName(ownerPID)
        // Finder, the Dock, loginwindow and the rest of macOS's own apps live in CoreServices;
        // quitting loginwindow logs out.
        let partOfMacOS = app.bundleURL?.path.hasPrefix("/System/Library/CoreServices") ?? true
        owner = partOfMacOS || app.activationPolicy == .prohibited ? .system : .app(app)
      } else {
        name = processName(ownerPID)
        id = "name:\(name)"  // three claude processes read as one line, not three
        owner = .background
      }
      var group = groups[id] ?? Consumer(id: id, name: name, owner: owner)
      group.bytes += info.ri_phys_footprint
      group.processes += 1
      if info.ri_phys_footprint > group.lead.bytes { group.lead = (pid, info.ri_phys_footprint) }
      groups[id] = group
    }
    return Array(groups.values.sorted { $0.bytes > $1.bytes }.prefix(limit))
  }

  func sample() -> Sample {
    let cpu = cpu()
    let swap = sysctlValue("vm.swapusage", xsw_usage())
    var load = [Double](repeating: 0, count: 3)
    getloadavg(&load, 3)
    return Sample(
      date: Date(), cpu: cpu.total, cores: cpu.cores, memory: memory(),
      pressure: Pressure(rawValue: sysctlValue("kern.memorystatus_vm_pressure_level", Int32(1))) ?? .normal,
      available: Int(sysctlValue("kern.memorystatus_level", Int32(0))),
      swapUsed: swap.xsu_used, swapTotal: swap.xsu_total, loadAverage: load,
      thermal: ProcessInfo.processInfo.thermalState)
  }
}

final class Monitor: ObservableObject {
  let reader = Reader()
  @Published private(set) var samples: [Sample] = []
  @Published private(set) var consumers: [Consumer] = []
  var onSample: ((Sample) -> Void)?
  private var timer: Timer?

  // Reading every process takes about 10 ms, so it runs only while the panel is open, and once
  // straight away when it opens so the list is never a reading behind.
  var watchingProcesses = false {
    didSet { if watchingProcesses && !oldValue { consumers = reader.consumers() } }
  }

  // The first reading comes half a second in, so the panel never waits a full interval for data.
  func start() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.tick() }
    let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
    t.tolerance = interval / 10
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  func tick() {
    let s = reader.sample()
    samples.append(s)
    if samples.count > historyLength { samples.removeFirst(samples.count - historyLength) }
    if watchingProcesses { consumers = reader.consumers() }
    onSample?(s)
  }
}

// MARK: Formatting and colors

func percent(_ v: Double) -> String { "\(Int((min(max(v, 0), 1) * 100).rounded()))%" }
func bytes(_ v: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .memory) }
func gigabytes(_ v: UInt64) -> Double { Double(v) / 1_073_741_824 }
func timeLabel(_ d: Date) -> String { d.formatted(date: .omitted, time: .standard) }

func hex(_ v: Int) -> Color {
  Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
}

// The first four colors of a categorical data visualization palette, in a fixed order and stepped
// per appearance, plus reserved status colors. Checked for color vision deficiency separation against
// the popover surfaces: every adjacent pair passes in both modes; in light mode orange, aqua and
// yellow sit under 3:1, which the always-visible value labels beside each key relieve.
struct Palette {
  let dark: Bool
  init(_ scheme: ColorScheme) { dark = scheme == .dark }
  var blue: Color { hex(dark ? 0x3987e5 : 0x2a78d6) }
  var orange: Color { hex(dark ? 0xd95926 : 0xeb6834) }
  var aqua: Color { hex(dark ? 0x199e70 : 0x1baf7a) }
  var yellow: Color { hex(dark ? 0xc98500 : 0xeda100) }
  static let track = Color.primary.opacity(0.1)
  static let neutral = Color.primary.opacity(0.45)
  static let good = hex(0x0ca30c), warning = hex(0xfab219), serious = hex(0xec835a), critical = hex(0xd03b3b)
}

extension Pressure {
  var color: Color {
    switch self { case .normal: Palette.good; case .warning: Palette.warning; case .critical: Palette.critical }
  }
}

func thermalStatus(_ t: ProcessInfo.ThermalState) -> (name: String, color: Color) {
  switch t {
  case .nominal: ("Nominal", Palette.good)
  case .fair: ("Fair", Palette.warning)
  case .serious: ("Serious", Palette.serious)
  case .critical: ("Critical", Palette.critical)
  @unknown default: ("Unknown", Palette.neutral)
  }
}

func uptime() -> String {
  let boot = sysctlValue("kern.boottime", timeval())
  let f = DateComponentsFormatter()
  f.allowedUnits = [.day, .hour, .minute]
  f.unitsStyle = .abbreviated
  f.maximumUnitCount = 2
  return "Up " + (f.string(from: Date().timeIntervalSince1970 - Double(boot.tv_sec)) ?? "")
}

let versionLine: String = {
  let info = Bundle.main.infoDictionary ?? [:]
  let version = info["CFBundleShortVersionString"] as? String ?? "dev"
  return "Version \(version) · build \(info["CFBundleVersion"] as? String ?? "0") (\(info["GitCommit"] as? String ?? "unknown"))"
}()

// MARK: Panel

struct MonitorView: View {
  @ObservedObject var monitor: Monitor
  @ObservedObject var app: App

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text("Barometer").font(.headline)
        Spacer()
        Text(uptime()).font(.caption).foregroundStyle(.secondary)
      }
      if let now = monitor.samples.last {
        CPUSection(samples: monitor.samples, now: now, clusters: monitor.reader.clusters)
        Divider()
        MemorySection(samples: monitor.samples, now: now)
        ConsumersSection(consumers: monitor.consumers, total: now.memory.total)
          .padding(.top, 4)
      } else {
        Text("Taking the first reading").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
      }
      Divider()
      Footer(app: app)
    }
    .padding(16)
    .frame(width: 340)
  }
}

struct CPUSection: View {
  let samples: [Sample]
  let now: Sample
  let clusters: [(name: String, cores: Int)]
  @State private var hover: Sample?
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let p = Palette(scheme)
    let shown = hover ?? now
    let cores = now.cores.count
    let split = clusters.map { "\($0.cores) \($0.name)" }.joined(separator: ", ")
    let thermal = thermalStatus(now.thermal)
    VStack(alignment: .leading, spacing: 8) {
      Heading(title: "CPU", value: percent(now.cpu.total))
      HistoryChart(samples: samples, series: [
        Series(name: "User", color: p.blue) { $0.cpu.user },
        Series(name: "System", color: p.orange) { $0.cpu.system },
      ], top: 1, label: percent, hover: $hover)
      HStack(spacing: 12) {
        Key(color: p.blue, name: "User", value: percent(shown.cpu.user))
        Key(color: p.orange, name: "System", value: percent(shown.cpu.system))
        Spacer()
        Text(hover.map { timeLabel($0.date) } ?? "Last 5 minutes").font(.caption).foregroundStyle(.secondary)
      }
      Text(split.isEmpty ? "\(cores) cores" : "\(cores) cores: \(split)").font(.caption).foregroundStyle(.secondary)
        .padding(.top, 4)
      CoreBars(cores: now.cores, palette: p)
      Row("Load average", help: "Threads running or waiting for a core, averaged over 1, 5 and 15 minutes. With \(cores) cores, \(cores).00 means every core is busy.") {
        Meter(fraction: (now.loadAverage.first ?? 0) / Double(max(cores, 1)), color: Palette.neutral)
        Text(now.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  ")).monospacedDigit()
      }
      Row("Thermal state", help: "How hard macOS is working to keep the chip cool. Anything above Nominal means it is slowing the CPU to shed heat.") {
        StatusLabel(color: thermal.color, text: thermal.name)
        Spacer()
      }
    }
  }
}

struct MemorySection: View {
  let samples: [Sample]
  let now: Sample
  @State private var hover: Sample?
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let p = Palette(scheme)
    let m = (hover ?? now).memory
    let parts = [
      Part(name: "App", color: p.blue, bytes: m.app),
      Part(name: "Wired", color: p.orange, bytes: m.wired),
      Part(name: "Compressed", color: p.aqua, bytes: m.compressed),
      Part(name: "Cached files", color: p.yellow, bytes: m.cached),
    ]
    VStack(alignment: .leading, spacing: 8) {
      Heading(title: "Memory", value: "\(bytes(now.memory.used)) of \(bytes(now.memory.total))")
      BreakdownBar(parts: parts, total: m.total)
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
        GridRow { key(parts[0]); key(parts[1]) }
        GridRow { key(parts[2]); key(parts[3]) }
        GridRow { Key(color: Palette.track, name: "Free", value: bytes(m.free)) }
      }
      HistoryChart(samples: samples, series: parts.prefix(3).map { part in
        Series(name: part.name, color: part.color) { s in
          gigabytes(part.name == "App" ? s.memory.app : part.name == "Wired" ? s.memory.wired : s.memory.compressed)
        }
      }, top: gigabytes(now.memory.total), label: { "\(Int($0.rounded())) GB" }, hover: $hover)
      .padding(.top, 4)
      HStack {
        Text("Used memory").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Text(hover.map { timeLabel($0.date) } ?? "Last 5 minutes").font(.caption).foregroundStyle(.secondary)
      }
      Row("Pressure", help: "How hard macOS is working to find memory for apps. Warning and Critical mean it is compressing and swapping to keep up. The kernel counts \(now.available)% of memory as available.") {
        Meter(fraction: Double(100 - now.available) / 100, color: now.pressure.color)
        StatusLabel(color: now.pressure.color, text: now.pressure.name)
      }
      Row("Swap used", help: "Memory macOS has written out to disk. It stays high after a busy spell and only matters while pressure is above Normal.") {
        Meter(fraction: now.swapTotal > 0 ? Double(now.swapUsed) / Double(now.swapTotal) : 0, color: Palette.neutral)
        Text(now.swapTotal > 0 ? "\(bytes(now.swapUsed)) of \(bytes(now.swapTotal))" : "None").monospacedDigit()
      }
    }
  }

  func key(_ part: Part) -> Key { Key(color: part.color, name: part.name, value: bytes(part.bytes)) }
}

// The apps holding the most memory. Quit asks an app to quit the way Command-Q does, so it can
// still ask to save, and takes a second click within four seconds to confirm. macOS's own apps and
// background processes are listed only, never stopped.
struct ConsumersSection: View {
  let consumers: [Consumer]
  let total: UInt64
  @State private var armed: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Using the most memory").font(.caption).foregroundStyle(.secondary)
        .help("Memory each app holds, its helper processes included, counting what macOS has compressed or written to swap, as Activity Monitor's Memory column does. Other users' processes, such as WindowServer, cannot be read and are not listed.")
      ForEach(consumers) { c in
        HStack(spacing: 8) {
          Text(c.name).lineLimit(1).truncationMode(.tail).frame(width: 104, alignment: .leading)
          Meter(fraction: Double(c.bytes) / Double(max(total, 1)), color: Palette.neutral)
          Text(bytes(c.bytes)).monospacedDigit().frame(width: 60, alignment: .trailing)
          Group {
            if let app = c.quittable {
              Button(armed == c.id ? "Confirm" : "Quit") { quit(c, app) }
                .buttonStyle(.plain)
                .foregroundStyle(armed == c.id ? Palette.critical : Color.accentColor)
            } else {
              Color.clear.frame(height: 1)  // an empty slot takes no width and would shift the row
            }
          }
          .frame(width: 60, alignment: .trailing)
        }
        .font(.callout)
        .help(help(c))
      }
    }
  }

  func quit(_ c: Consumer, _ app: NSRunningApplication) {
    guard armed == c.id else {
      armed = c.id
      DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if armed == c.id { armed = nil } }
      return
    }
    armed = nil
    app.terminate()
  }

  func help(_ c: Consumer) -> String {
    let helpers = c.processes - 1
    let who: String
    switch c.owner {
    case .background where c.processes > 1: who = "\(c.processes) processes named \(c.name) hold"
    case _ where helpers > 0: who = "\(c.name) and \(helpers) helper \(helpers == 1 ? "process" : "processes") hold"
    default: who = "\(c.name) holds"
    }
    let action = switch c.owner {
    case .app: "Quit asks it to quit, as Command-Q would; click again to confirm."
    case .system: "Part of macOS, so it is not quit from here."
    case .background: "A background process, so it is listed but not quit from here."
    }
    return "\(who) \(bytes(c.bytes)), counting memory macOS has compressed or written to swap. \(action)"
  }
}

struct Part: Identifiable {
  let name: String
  let color: Color
  let bytes: UInt64
  var id: String { name }
}

struct Series {
  let name: String
  let color: Color
  let value: (Sample) -> Double
}

// Stacked area history over a fixed five-minute window that fills in from the right. Hovering
// draws a rule at the nearest reading; the section shows that reading's values in its key.
struct HistoryChart: View {
  let samples: [Sample]
  let series: [Series]
  let top: Double
  let label: (Double) -> String
  @Binding var hover: Sample?

  var body: some View {
    let end = samples.last?.date ?? Date()
    let start = end.addingTimeInterval(-interval * Double(historyLength - 1))
    Chart {
      ForEach(series, id: \.name) { s in
        ForEach(samples) { sample in
          AreaMark(x: .value("Time", sample.date), y: .value("Value", s.value(sample)), stacking: .standard)
            .foregroundStyle(by: .value("Series", s.name))
            .interpolationMethod(.monotone)
        }
      }
      if let hover {
        RuleMark(x: .value("Time", hover.date)).foregroundStyle(Color.secondary).lineStyle(StrokeStyle(lineWidth: 1))
      }
    }
    .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
    .chartLegend(.hidden)
    .chartXScale(domain: start...end)
    .chartXAxis(.hidden)
    .chartYScale(domain: 0...top)
    .chartYAxis {
      AxisMarks(position: .trailing, values: [0, top / 2, top]) { v in
        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
        AxisValueLabel { Text(label(v.as(Double.self) ?? 0)).font(.caption2) }
      }
    }
    .chartOverlay { proxy in
      GeometryReader { geo in
        Rectangle().fill(.clear).contentShape(Rectangle())
          .onContinuousHover { phase in
            if case .active(let point) = phase, let frame = proxy.plotFrame,
               let date = proxy.value(atX: point.x - geo[frame].origin.x, as: Date.self) {
              hover = samples.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
            } else {
              hover = nil
            }
          }
      }
    }
    .frame(height: 70)
  }
}

// One bar per core, user load at the base and system load stacked on it. Hover names the core.
struct CoreBars: View {
  let cores: [Load]
  let palette: Palette

  var body: some View {
    HStack(alignment: .bottom, spacing: 3) {
      ForEach(Array(cores.enumerated()), id: \.offset) { i, core in
        GeometryReader { g in
          let h = g.size.height
          let gap = h * core.user >= 3 && h * core.system >= 3 ? 1.5 : 0
          ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 3).fill(Palette.track)
            VStack(spacing: gap) {
              RoundedRectangle(cornerRadius: 2).fill(palette.orange).frame(height: max(0, h * core.system - gap))
              RoundedRectangle(cornerRadius: 2).fill(palette.blue).frame(height: h * core.user)
            }
          }
        }
        .help("Core \(i + 1): \(percent(core.total)), \(percent(core.user)) user and \(percent(core.system)) system")
      }
    }
    .frame(height: 40)
  }
}

struct BreakdownBar: View {
  let parts: [Part]
  let total: UInt64

  var body: some View {
    GeometryReader { g in
      HStack(spacing: 2) {
        ForEach(parts) { part in
          RoundedRectangle(cornerRadius: 2).fill(part.color)
            .frame(width: max(0, g.size.width * Double(part.bytes) / Double(max(total, 1)) - 2))
            .help("\(part.name): \(bytes(part.bytes))")
        }
        Spacer(minLength: 0)
      }
      .background(RoundedRectangle(cornerRadius: 3).fill(Palette.track))
    }
    .frame(height: 14)
  }
}

struct Heading: View {
  let title: String
  let value: String

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title).font(.headline)
      Spacer()
      Text(value).font(.title2.weight(.semibold)).monospacedDigit()
    }
  }
}

struct Key: View {
  let color: Color
  let name: String
  let value: String

  var body: some View {
    HStack(spacing: 4) {
      RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
      Text(name).foregroundStyle(.secondary)
      Text(value).monospacedDigit()
    }
    .font(.caption)
  }
}

struct Row<Content: View>: View {
  let label: String
  let help: String
  let content: Content

  init(_ label: String, help: String, @ViewBuilder content: () -> Content) {
    self.label = label
    self.help = help
    self.content = content()
  }

  var body: some View {
    HStack(spacing: 8) {
      Text(label).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
      content
    }
    .font(.callout)
    .help(help)
  }
}

struct Meter: View {
  let fraction: Double
  let color: Color

  var body: some View {
    GeometryReader { g in
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 3).fill(Palette.track)
        RoundedRectangle(cornerRadius: 3).fill(color).frame(width: g.size.width * min(max(fraction, 0), 1))
      }
    }
    .frame(height: 6)
  }
}

struct StatusLabel: View {
  let color: Color
  let text: String

  var body: some View {
    HStack(spacing: 5) {
      Circle().fill(color).frame(width: 8, height: 8)
      Text(text)
    }
  }
}

// The footer's controls are drawn in SwiftUI rather than as AppKit buttons so that --snapshot,
// which can only render SwiftUI's own views, pictures the panel exactly as it appears.
struct Footer: View {
  @ObservedObject var app: App

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 14) {
        Button(action: app.toggleLogin) {
          HStack(spacing: 5) {
            Image(systemName: app.opensAtLogin ? "checkmark.square.fill" : "square")
              .foregroundStyle(app.opensAtLogin ? Color.accentColor : Color.secondary)
            Text("Open at login")
          }
        }
        Spacer()
        Button("Activity Monitor", action: app.openActivityMonitor).foregroundStyle(Color.accentColor)
        Button("Quit") { NSApp.terminate(nil) }.foregroundStyle(Color.accentColor)
      }
      .buttonStyle(.plain)
      .font(.callout)
      Text(versionLine).font(.caption2).foregroundStyle(.tertiary)
    }
  }
}

// MARK: App

final class App: NSObject, NSApplicationDelegate, NSPopoverDelegate, ObservableObject {
  let monitor = Monitor()
  let popover = NSPopover()
  var status: NSStatusItem!
  var closedAt = Date.distantPast
  var outsideClicks: Any?
  @Published var opensAtLogin = false

  func applicationDidFinishLaunching(_ n: Notification) {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
      .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if !others.isEmpty { NSApp.terminate(nil); return }

    NSApp.setActivationPolicy(.accessory)
    opensAtLogin = FileManager.default.fileExists(atPath: agentURL.path)
    status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    status.button?.target = self
    status.button?.action = #selector(togglePanel)

    let host = NSHostingController(rootView: MonitorView(monitor: monitor, app: self))
    host.sizingOptions = .preferredContentSize
    popover.contentViewController = host
    popover.behavior = .transient
    popover.delegate = self

    monitor.onSample = { [weak self] in self?.drawIcon($0) }
    drawIcon(nil)
    monitor.start()
  }

  // A transient popover closes on an outside click only while this app is active, and macOS 14's
  // cooperative activation leaves a menu bar app inactive whenever another app holds the focus, so
  // the panel stayed open until the icon was clicked again. A global monitor sees the clicks other
  // apps receive (the desktop, a window, another menu bar item) without Accessibility permission.
  // Clicks inside the panel and on the icon are this app's own and never reach it.
  func popoverWillShow(_ n: Notification) {
    monitor.watchingProcesses = true
    outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
      self?.popover.performClose(nil)
    }
  }

  // A transient popover closes on the mouse-down that lands on the icon, and the icon's action
  // then arrives; without the timestamp that click would open the panel again straight away.
  func popoverWillClose(_ n: Notification) {
    closedAt = Date()
    monitor.watchingProcesses = false
    if let m = outsideClicks { NSEvent.removeMonitor(m); outsideClicks = nil }
  }

  @objc func togglePanel() {
    if popover.isShown { popover.performClose(nil); return }
    guard Date().timeIntervalSince(closedAt) > 0.3, let button = status.button else { return }
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    NSApp.activate()
  }

  // Two bars, CPU then memory used, drawn as a template image so the menu bar tints them for light
  // and dark wallpapers alike.
  func drawIcon(_ s: Sample?) {
    let cpu = s?.cpu.total ?? 0
    let mem = s.map { Double($0.memory.used) / Double(max($0.memory.total, 1)) } ?? 0
    let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
      NSColor.black.set()
      for (i, v) in [cpu, mem].enumerated() {
        let frame = NSRect(x: 2.5 + Double(i) * 6.5, y: 1.5, width: 4.5, height: 13)
        let outline = NSBezierPath(roundedRect: frame, xRadius: 1.5, yRadius: 1.5)
        outline.lineWidth = 1
        outline.stroke()
        let level = (frame.height - 2) * min(max(v, 0), 1)
        NSBezierPath(roundedRect: NSRect(x: frame.minX + 1, y: frame.minY + 1, width: frame.width - 2, height: level), xRadius: 0.5, yRadius: 0.5).fill()
      }
      return true
    }
    image.isTemplate = true
    let summary = s.map { "CPU \(percent($0.cpu.total)), memory \(bytes($0.memory.used)) of \(bytes($0.memory.total)) used, pressure \($0.pressure.name.lowercased())" } ?? "Barometer"
    image.accessibilityDescription = summary
    status.button?.image = image
    status.button?.toolTip = summary
  }

  @objc func openActivityMonitor() {
    popover.performClose(nil)
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
  }

  var agentURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(bundleID).plist")
  }

  func launchctl(_ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    try? p.run()
    p.waitUntilExit()
  }

  // A plist that is written but never loaded does nothing until the next login, and launchd has no
  // record of it until then, so the toggle loads and unloads the job as well as the file. Loading runs the job once (RunAtLoad); that copy finds this one running and quits.
  @objc func toggleLogin() {
    let fm = FileManager.default
    let domain = "gui/\(getuid())"
    defer { opensAtLogin = fm.fileExists(atPath: agentURL.path) }
    if fm.fileExists(atPath: agentURL.path) {
      // Unloading a job stops its process, so when launchd started this copy the job is left to
      // lapse at logout instead; with the plist gone it never comes back.
      if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != bundleID {
        launchctl(["bootout", "\(domain)/\(bundleID)"])
      }
      try? fm.removeItem(at: agentURL)
      return
    }
    guard let exe = Bundle.main.executablePath else { return }
    let plist: [String: Any] = [
      "Label": bundleID,
      "ProgramArguments": [exe],
      "RunAtLoad": true,
      "ProcessType": "Interactive",
      "LimitLoadToSessionType": "Aqua",
    ]
    try? fm.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
      try? data.write(to: agentURL)
      launchctl(["bootstrap", domain, agentURL.path])
    }
  }
}

// MARK: Entry

// Two command line modes, for the tests and for a picture of the panel without opening it:
//   Barometer --sample                     prints one reading as JSON and exits
//   Barometer --snapshot <prefix> [secs]   reads for secs (default 20), then writes
//                                          <prefix>-light.png and <prefix>-dark.png
let args = CommandLine.arguments
if args.contains("--sample") {
  let reader = Reader()
  Thread.sleep(forTimeInterval: 1)
  let s = reader.sample()
  let reading: [String: Any] = [
    "cores": s.cores.count, "cpu": s.cpu.total, "user": s.cpu.user, "system": s.cpu.system,
    "memoryTotal": s.memory.total, "app": s.memory.app, "wired": s.memory.wired,
    "compressed": s.memory.compressed, "cached": s.memory.cached,
    "pressureLevel": s.pressure.rawValue, "available": s.available,
    "swapUsed": s.swapUsed, "swapTotal": s.swapTotal, "loadAverage": s.loadAverage,
    "clusters": reader.clusters.map { ["name": $0.name, "cores": $0.cores] },
    "consumers": reader.consumers().map { c -> [String: Any] in
      ["name": c.name, "bytes": c.bytes, "processes": c.processes, "quittable": c.quittable != nil,
       "leadPID": c.lead.pid, "leadBytes": c.lead.bytes]
    },
  ]
  let data = try! JSONSerialization.data(withJSONObject: reading, options: [.sortedKeys])
  print(String(decoding: data, as: UTF8.self))
  exit(0)
}
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
  let delegate = App()
  let seconds = i + 2 < args.count ? Double(args[i + 2]) ?? 20 : 20
  let deadline = Date().addingTimeInterval(seconds)
  delegate.monitor.watchingProcesses = true
  repeat {
    Thread.sleep(forTimeInterval: interval)
    delegate.monitor.tick()
  } while Date() < deadline
  MainActor.assumeIsolated {
    for dark in [false, true] {
      // The popover's own material does not render offscreen; these are its two resting colors.
      let view = MonitorView(monitor: delegate.monitor, app: delegate)
        .background(hex(dark ? 0x2b2b2b : 0xececec))
        .environment(\.colorScheme, dark ? .dark : .light)
      let renderer = ImageRenderer(content: view)
      renderer.scale = 2
      guard let image = renderer.cgImage,
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
      try? png.write(to: URL(fileURLWithPath: "\(args[i + 1])-\(dark ? "dark" : "light").png"))
    }
  }
  exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
