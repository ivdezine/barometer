// Guards for Barometer. The build test compiles the real app with swiftc into a temp folder, checks
// the release identity it stamps, then takes one reading with --sample and holds it against what
// sysctl, vm_stat and top report; it skips on a machine without swiftc.
// Run from the repo root: node --test barometer.test.mjs

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync, existsSync, mkdtempSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const source = readFileSync(path.join(here, 'Barometer.swift'), 'utf8');
const git = (...a) => spawnSync('git', a, { cwd: here, encoding: 'utf8' }).stdout.trim();
const sysctl = (name) => spawnSync('sysctl', ['-n', name], { encoding: 'utf8' }).stdout.trim();
const swapTotal = () => Math.round(Number(sysctl('vm.swapusage').match(/total = ([\d.]+)M/)[1]) * 1048576);

// Free pages read near zero on a healthy Mac because idle memory is kept as file cache, which is
// what made os.freemem() report 1.7% free while the kernel counted 66% available.
test('memory comes from the kernel counters, with pressure from memorystatus, never free pages', () => {
  assert.match(source, /host_statistics64\(host, HOST_VM_INFO64/);
  assert.match(source, /"kern\.memorystatus_vm_pressure_level"/);
  assert.match(source, /"kern\.memorystatus_level"/);
  assert.doesNotMatch(source, /free_count/, 'free pages are not a measure of available memory');
});

test('CPU ticks wrap safely and the kernel buffer is freed on every read', () => {
  const ticks = source.slice(source.indexOf('func ticks()'), source.indexOf('func cpu()'));
  assert.match(ticks, /defer \{ vm_deallocate\(mach_task_self_/, 'host_processor_info hands back memory this process owns');
  assert.match(source, /\$0 &- \$1/, 'tick counters are 32 bits and wrap');
});

test('the history window matches the five minutes the panel says it shows', () => {
  const interval = Number(source.match(/^let interval = ([\d.]+)/m)[1]);
  const length = Number(source.match(/^let historyLength = (\d+)/m)[1]);
  assert.equal(interval * length, 300);
  assert.match(source, /"Last 5 minutes"/);
});

test('the menu bar icon is a template image, so it follows the menu bar in light and dark', () => {
  assert.match(source, /image\.isTemplate = true/);
  assert.match(source, /accessibilityDescription = summary/);
});

// Ticking the box has to take effect now: a plist that is written but never loaded does nothing
// until the next login.
test('Open at login loads the agent it writes, and unloads it unless launchd owns this copy', () => {
  const toggle = source.slice(source.indexOf('func toggleLogin()'));
  const body = toggle.slice(0, toggle.indexOf('\n  }\n'));
  assert.ok(body.indexOf('launchctl(["bootstrap"') > body.indexOf('data.write(to: agentURL)'), 'bootstrap must follow the plist write');
  assert.match(body, /launchctl\(\["bootout"/);
  assert.match(body, /XPC_SERVICE_NAME"\] != bundleID/, 'booting out the job launchd started would quit the app');
});

// Resident size leaves out what macOS has compressed or swapped out, which on a Mac deep in swap is
// most of what a browser holds, so the list would undercount exactly the apps worth quitting.
test('the top memory list counts physical footprint and folds helper processes into their app', () => {
  const read = source.slice(source.indexOf('func consumers('), source.indexOf('func sample()'));
  assert.match(read, /proc_pid_rusage\(pid, RUSAGE_INFO_V4/);
  assert.match(read, /group\.bytes \+= info\.ri_phys_footprint/);
  assert.doesNotMatch(source, /ri_resident_size|pti_resident_size/, 'resident size is not the Memory column');
  assert.match(source, /"responsibility_get_pid_responsible_for_pid"/, 'Firefox content processes count toward Firefox');
  assert.match(read, /responsibleFor\?\(pid\) \?\? -1/, 'without the lookup each process stands alone rather than failing');
});

test('Quit asks an app to quit after a second click, and never stops macOS or a background process', () => {
  assert.doesNotMatch(source, /forceTerminate|\bkill\(|SIGKILL|SIGTERM/, 'nothing is ever killed');
  const quit = source.slice(source.indexOf('func quit(_ c: Consumer'), source.indexOf('func help(_ c: Consumer'));
  assert.ok(quit.indexOf('guard armed == c.id else') < quit.indexOf('app.terminate()'), 'the first click only arms the button');
  assert.match(source, /var quittable: NSRunningApplication\? \{ if case \.app\(let a\) = owner \{ a \} else \{ nil \} \}/);
  const read = source.slice(source.indexOf('func consumers('), source.indexOf('func sample()'));
  assert.match(read, /hasPrefix\("\/System\/Library\/CoreServices"\) \?\? true/, 'Finder, the Dock and loginwindow, whose quit logs out');
  assert.match(read, /owner = partOfMacOS \|\| app\.activationPolicy == \.prohibited \? \.system : \.app\(app\)/);
  assert.match(read, /owner = \.background/);
});

const method = (name) => {
  const from = source.slice(source.indexOf(`func ${name}(`));
  return from.slice(0, from.indexOf('\n  }\n'));
};

test('processes are read only while the panel is open, and straight away when it opens', () => {
  assert.match(method('popoverWillShow'), /monitor\.watchingProcesses = true/);
  assert.match(method('popoverWillClose'), /monitor\.watchingProcesses = false/);
  assert.match(source, /if watchingProcesses \{ consumers = reader\.consumers\(\) \}/);
  assert.match(source, /didSet \{ if watchingProcesses && !oldValue \{ consumers = reader\.consumers\(\) \} \}/);
});

// The transient popover alone never closes while another app holds the focus, so the panel would
// stay open until the icon was clicked again.
test('a click outside the panel closes it, and the watch on outside clicks ends with the panel', () => {
  assert.match(source, /popover\.behavior = \.transient/);
  const show = method('popoverWillShow');
  assert.match(show, /outsideClicks = NSEvent\.addGlobalMonitorForEvents\(matching: \[\.leftMouseDown, \.rightMouseDown/);
  assert.match(show.slice(show.indexOf('addGlobalMonitorForEvents')), /self\?\.popover\.performClose\(nil\)/);
  assert.match(method('popoverWillClose'), /if let m = outsideClicks \{ NSEvent\.removeMonitor\(m\); outsideClicks = nil \}/);
  assert.match(method('togglePanel'), /guard Date\(\)\.timeIntervalSince\(closedAt\) > 0\.3/, 'the click that closes the panel on the icon must not reopen it');
});

// The build used to name arm64 outright, which an Intel Mac cannot run.
test('the build targets the Mac it runs on, so Intel Macs can build it too', () => {
  const build = readFileSync(path.join(here, 'build.sh'), 'utf8');
  assert.match(build, /arch="\$\{ARCH:-\$\(uname -m\)\}"/);
  assert.match(build, /swiftc -O -target "\$arch-apple-macos14"/);
  assert.doesNotMatch(build, /-target arm64/);
});

test('an Intel build compiles, and takes a reading under Rosetta where Rosetta is installed', { timeout: 600000 }, (t) => {
  if (spawnSync('which', ['swiftc']).status !== 0) return t.skip('swiftc not installed');
  const out = mkdtempSync(path.join(os.tmpdir(), 'barometer-x86-'));
  try {
    const r = spawnSync('bash', [path.join(here, 'build.sh')], { env: { ...process.env, OUT_DIR: out, ARCH: 'x86_64' }, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    const exe = path.join(out, 'Barometer.app', 'Contents', 'MacOS', 'Barometer');
    assert.equal(spawnSync('lipo', ['-archs', exe], { encoding: 'utf8' }).stdout.trim(), 'x86_64');
    if (spawnSync('arch', ['-x86_64', '/usr/bin/true']).status !== 0) return;  // no Rosetta, or an Intel Mac already covered above
    const run = spawnSync('arch', ['-x86_64', exe, '--sample'], { encoding: 'utf8', timeout: 30000 });
    assert.equal(run.status, 0, run.stderr);
    assert.equal(JSON.parse(run.stdout).cores, Number(sysctl('hw.logicalcpu')));
  } finally {
    rmSync(out, { recursive: true, force: true });
  }
});

test('the build stamps its identity, and one reading agrees with sysctl and vm_stat', { timeout: 600000 }, (t) => {
  if (spawnSync('which', ['swiftc']).status !== 0) return t.skip('swiftc not installed');
  const out = mkdtempSync(path.join(os.tmpdir(), 'barometer-'));
  try {
    const r = spawnSync('bash', [path.join(here, 'build.sh')], { env: { ...process.env, OUT_DIR: out }, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    const app = path.join(out, 'Barometer.app');
    const exe = path.join(app, 'Contents', 'MacOS', 'Barometer');
    assert.ok(existsSync(exe));
    const plist = readFileSync(path.join(app, 'Contents', 'Info.plist'), 'utf8');
    const key = (k) => plist.match(new RegExp(`<key>${k}</key>\\s*<string>([^<]*)</string>`))?.[1];
    assert.equal(key('CFBundleIdentifier'), 'com.ivdezine.barometer');
    assert.match(key('CFBundleShortVersionString'), /^\d+\.\d+\.\d+$/);
    assert.equal(key('CFBundleVersion'), git('rev-list', '--count', 'HEAD'));
    assert.equal(key('GitCommit').replace(/-dirty$/, ''), git('rev-parse', '--short=7', 'HEAD'));
    assert.match(plist, /<key>LSUIElement<\/key><true\/>/, 'menu bar only, no Dock icon');

    // Values that move between two reads are bracketed by a read on each side of the sample.
    const before = { swap: swapTotal(), level: Number(sysctl('kern.memorystatus_level')) };
    const run = spawnSync(exe, ['--sample'], { encoding: 'utf8', timeout: 30000 });
    assert.equal(run.status, 0, run.stderr);
    const vm = spawnSync('vm_stat', { encoding: 'utf8' }).stdout;
    const after = { swap: swapTotal(), level: Number(sysctl('kern.memorystatus_level')) };
    const s = JSON.parse(run.stdout);

    assert.equal(s.cores, Number(sysctl('hw.logicalcpu')));
    assert.equal(s.memoryTotal, Number(sysctl('hw.memsize')));
    assert.ok(s.cpu >= 0 && s.cpu <= 1, `cpu ${s.cpu}`);
    assert.ok(Math.abs(s.user + s.system - s.cpu) < 1e-9);
    // Intel Macs report no clusters; where there are any, they account for every core.
    if (s.clusters.length) assert.equal(s.clusters.reduce((n, c) => n + c.cores, 0), s.cores, 'the clusters account for every core');
    assert.ok(s.app + s.wired + s.compressed + s.cached <= s.memoryTotal);
    assert.ok([1, 2, 4].includes(s.pressureLevel), `pressure level ${s.pressureLevel}`);
    assert.ok(s.available >= Math.min(before.level, after.level) - 5 && s.available <= Math.max(before.level, after.level) + 5);
    assert.ok([before.swap, after.swap].includes(s.swapTotal), `swap total ${s.swapTotal}`);
    assert.ok(s.swapUsed <= s.swapTotal);
    assert.equal(s.loadAverage.length, 3);

    // A wrong page size or a wrong counter shows up here as a factor of four or worse; the tolerance
    // only absorbs what moves in the second between the sample and vm_stat.
    const page = Number(vm.match(/page size of (\d+) bytes/)[1]);
    const pages = (label) => Number(vm.match(new RegExp(`${label}:\\s+(\\d+)`))[1]) * page;
    const near = (name, ours, theirs) =>
      assert.ok(Math.abs(ours - theirs) < s.memoryTotal * 0.05, `${name}: ${ours} against vm_stat ${theirs}`);
    near('wired', s.wired, pages('Pages wired down'));
    near('compressed', s.compressed, pages('Pages occupied by compressor'));
    near('app', s.app, pages('Anonymous pages') - pages('Pages purgeable'));
    near('cached', s.cached, pages('File-backed pages') + pages('Pages purgeable'));

    // top's MEM column is the same physical footprint Activity Monitor shows. The five can add up to
    // more than the machine holds, since footprint counts what sits in swap, so no total is asserted.
    assert.ok(s.consumers.length > 0 && s.consumers.length <= 5, `${s.consumers.length} consumers`);
    s.consumers.forEach((c, i) => {
      assert.ok(c.name.length > 0 && c.processes >= 1 && c.leadBytes <= c.bytes, JSON.stringify(c));
      if (i > 0) assert.ok(c.bytes <= s.consumers[i - 1].bytes, 'largest first');
    });
    const unit = { B: 1, K: 1024, M: 1048576, G: 1073741824 };
    let compared = 0;
    for (const c of s.consumers) {
      const row = spawnSync('top', ['-l', '1', '-pid', String(c.leadPID), '-stats', 'pid,mem'], { encoding: 'utf8' }).stdout
        .split('\n').find((l) => l.trim().startsWith(`${c.leadPID} `));
      if (!row) continue;  // the process ended between the two reads
      const [, n, u] = row.trim().split(/\s+/)[1].match(/^([\d.]+)([BKMG])/);
      const theirs = Number(n) * unit[u];
      assert.ok(Math.abs(c.leadBytes - theirs) < Math.max(64 * 1048576, theirs * 0.1), `${c.name} pid ${c.leadPID}: ${c.leadBytes} against top ${theirs}`);
      compared++;
    }
    assert.ok(compared > 0, 'at least one listed process was still running for top to read');
  } finally {
    rmSync(out, { recursive: true, force: true });
  }
});
