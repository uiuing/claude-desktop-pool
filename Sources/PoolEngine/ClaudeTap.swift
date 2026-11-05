import Foundation
import Darwin
import PoolCore
import PoolRuntime

/// Claude Code's replies as Anthropic streams them. The transcript has a message only once it ends, so on its
/// own a reply is told a whole message at a time. Claude Code is a Bun program, and Bun loads a
/// script BUN_OPTIONS names (`--preload`) before it: the script copies the main turn's replies
/// (`x-claude-code-request-class: main`), as they stream, to a private file of the run's, a JSON
/// line an event. The requests, and what Claude Code reads and writes, are its own: the script
/// reads a tee of each reply's body. A client that is not Bun, or does not load it, writes nothing
/// there, and its replies are told whole from the transcript as before.
struct ClaudeTap {
    /// The script: it knows itself by `claude-pool-tap` in
    /// the path BUN_OPTIONS gives it, and takes itself and its file's name out of what Claude
    /// Code hands on.
    static let script = #"""
    // Claude Pool's tap on Claude Code's stream. Claude
    // Code, a Bun program, loads this before itself (BUN_OPTIONS --preload). Its requests to
    // Anthropic go through Bun.FetchSession: this makes that a FetchSession whose fetch is the
    // real one's, the request, connection and TLS untouched, and copies the reply of each of the
    // main turn's requests (x-claude-code-request-class: main), as it streams, to the file
    // CLAUDE_POOL_TAP names: a JSON line an event. Claude Code reads its own copy of the stream
    // as before.
    (() => {
      const file = process.env.CLAUDE_POOL_TAP;
      if (!file) return;
      // none of it is handed on to what Claude Code runs, nor says it is here
      delete process.env.CLAUDE_POOL_TAP;
      const ours = /(^|\s)--preload(=|\s+)\S*claude-pool-tap\S*/;
      const opts = (process.env.BUN_OPTIONS || "").replace(ours, "").trim();
      if (opts) process.env.BUN_OPTIONS = opts;
      else delete process.env.BUN_OPTIONS;
      const argv = process.execArgv;
      for (let i = argv.length - 1; i >= 0; i--) {
        if (!/claude-pool-tap/.test(argv[i])) continue;
        if (argv[i].startsWith("--preload=")) argv.splice(i, 1);
        else if (argv[i - 1] === "--preload") argv.splice(--i, 2);
      }

      const fs = require("fs");
      let fd;
      try {
        fd = fs.openSync(file, "a");
      } catch {
        return;
      }
      const put = (v) => {
        try {
          fs.writeSync(fd, JSON.stringify(v) + "\n");
        } catch {}
      };
      const Real = globalThis.Bun && Bun.FetchSession;
      if (typeof Real !== "function") {
        put({ tap: "none" });
        return;
      }
      let streams = 0;
      // read tells each event of stream s, then its end: cut when it broke
      // off, as a dropped connection or Claude Code's own Esc ends it
      const read = async (s, body) => {
        const dec = new TextDecoder();
        let buf = "";
        const event = (text) => {
          const data = text
            .split("\n")
            .filter((l) => l.startsWith("data:"))
            .map((l) => l.slice(5).replace(/^ /, ""))
            .join("\n");
          if (!data) return;
          let e;
          try {
            e = JSON.parse(data);
          } catch {
            return;
          }
          if (e && e.type !== "ping") put({ s, e });
        };
        try {
          for await (const chunk of body) {
            buf = (buf + dec.decode(chunk, { stream: true })).replace(/\r\n?/g, "\n");
            let i;
            while ((i = buf.indexOf("\n\n")) >= 0) {
              event(buf.slice(0, i));
              buf = buf.slice(i + 2);
            }
          }
          if (buf.trim()) event(buf);
          put({ s, end: "done" });
        } catch (err) {
          put({ s, end: "cut" });
        }
      };
      class FetchSession extends Real {
        async fetch(input, init) {
          const res = await super.fetch(input, init);
          try {
            const url = String((input && input.url) || input);
            const headers = new Headers((init && init.headers) || (input && input.headers) || undefined);
            if (
              headers.get("x-claude-code-request-class") === "main" &&
              /\/v1\/messages(\?|$)/.test(url) &&
              res.body &&
              /^text\/event-stream/.test(res.headers.get("content-type") || "")
            ) {
              const [theirs, mine] = res.body.tee();
              Object.defineProperty(res, "body", { value: theirs, configurable: true });
              // told before Claude Code has the reply, so the helper knows a
              // stream is coming before any of its messages
              const s = ++streams;
              put({ s, open: true });
              read(s, mine);
            }
          } catch {}
          return res;
        }
      }
      try {
        Bun.FetchSession = FetchSession;
      } catch {}
      put({ tap: Bun.FetchSession === FetchSession ? "on" : "none" });
    })();

    """#

    static let scriptName = "claude-pool-tap.js"
    static let outputName = "claude-pool-tap.jsonl"
    /// The folder a tap is made in when the run's own path cannot be carried by BUN_OPTIONS.
    static let folderPrefix = "claude-pool-tap-"
    private static let maximumLine = 16 * 1024 * 1024

    let folder: URL
    let scriptURL: URL
    let output: URL
    /// What the run's client is given to load it: BUN_OPTIONS and the file it writes to.
    let environment: [String: String]
    private let madeFolder: Bool
    private var offset: UInt64 = 0
    private var partial = Data()
    private var skipping = false
    /// What the script said of itself: "on" once it taps Claude Code's requests, "none" when it
    /// could not; nil while it said nothing (a client that does not load it).
    private(set) var state: String?
    var on: Bool { state == "on" }
    /// The streams going, by the script's number: the id of the message each is, once its
    /// message_start came.
    private var open: [Int: Stream] = [:]
    private var ended: Set<Int> = []
    private(set) var started: Set<String> = []
    /// Messages told whole, as their stream came late: their stream says nothing.
    private(set) var dropped: Set<String> = []

    private struct Stream { var id = ""; var stopped = false }

    private init(folder: URL, madeFolder: Bool, environment: [String: String]) {
        self.folder = folder; self.madeFolder = madeFolder; self.environment = environment
        scriptURL = folder.appendingPathComponent(Self.scriptName)
        output = folder.appendingPathComponent(Self.outputName)
    }

    /// Writes the script and the file it writes to in the run's private folder (newTap), or, where
    /// that folder's path has whitespace BUN_OPTIONS cannot carry (it is split at whitespace, with
    /// no quoting), in a private folder of the app's made under `temporary`: nil, with no tap,
    /// where neither can be done.
    static func make(run: URL, temporary: URL) -> ClaudeTap? {
        var folder = run, made = false
        if hasWhitespace(run.path) {
            sweep(temporary)
            guard !hasWhitespace(temporary.path), let created = makeFolder(in: temporary) else { return nil }
            folder = created; made = true
        }
        let script = folder.appendingPathComponent(scriptName), output = folder.appendingPathComponent(outputName)
        guard let environment = OfficialCLI.tapEnvironment(preload: script.path, output: output.path),
              create(script, Data(Self.script.utf8)), create(output, Data()) else {
            unlink(script.path); unlink(output.path)
            if made { live.forget(folder.path); rmdir(folder.path) }
            return nil
        }
        return ClaudeTap(folder: folder, madeFolder: made, environment: environment)
    }

    /// Removes the script, its file and a folder made for them; nothing else that may be there.
    func remove() {
        unlink(scriptURL.path); unlink(output.path)
        if madeFolder { rmdir(folder.path); Self.live.forget(folder.path) }
    }

    /// The temporary folders this app's runs have their taps in: never swept while a run has one.
    /// A reader that keeps the file open would go on reading a folder removed under it; this
    /// one opens it by its path at each read.
    private static let live = LiveFolders()
    private final class LiveFolders: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []
        func hold(_ path: String) { lock.withLock { _ = paths.insert(path) } }
        func forget(_ path: String) { lock.withLock { _ = paths.remove(path) } }
        func holds(_ path: String) -> Bool { lock.withLock { paths.contains(path) } }
    }

    /// A client started again in the same run numbers its streams from one again: what the one
    /// before wrote says nothing more.
    mutating func restart() {
        state = nil; open = [:]; ended = []; partial = Data(); skipping = false
        var info = stat()
        offset = lstat(output.path, &info) == 0 ? UInt64(max(0, info.st_size)) : 0
    }

    /// The stream events written since the last read, in order: each an Anthropic event of a
    /// message not told whole, and a `message_stop` of Pool's own for a stream cut short.
    mutating func read() -> [JSONValue] {
        let descriptor = Darwin.open(output.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return [] }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { return [] }
        let size = UInt64(max(0, info.st_size))
        if size < offset { offset = 0; partial = Data(); skipping = false }
        var events: [JSONValue] = [], taken = 0
        while size > offset, taken < 16 * 1024 * 1024 {
            let length = Int(min(size - offset, 4 * 1024 * 1024))
            var chunk = Data(count: length)
            let count = chunk.withUnsafeMutableBytes { raw in pread(descriptor, raw.baseAddress!, length, off_t(offset)) }
            guard count > 0 else { break }
            offset += UInt64(count); taken += count
            events += lines(chunk.prefix(count))
        }
        return events
    }

    /// Whether a stream is open; one with no message yet if `bare`.
    func going(bare: Bool) -> Bool {
        open.values.contains { !bare || $0.id.isEmpty }
    }

    /// Whether a transcript message may still have a stream to wait for (`before`): the script is
    /// on, and the message's stream has neither begun nor been dropped. It waits only while a
    /// stream with no message yet is open; a message no stream can be (Claude Code asked again
    /// without one) waits for none.
    func waits(for id: String) -> Bool { on && !started.contains(id) && !dropped.contains(id) }

    /// The message is told whole: its stream, come late, says nothing.
    mutating func drop(_ id: String) { dropped.insert(id) }

    /// Ends the streams still going at a turn's end (`settle`), each as Claude Code ends a stream
    /// cut short: a `message_stop` and no `message_delta`.
    mutating func endAll() -> [JSONValue] {
        open.keys.sorted().flatMap { end($0) }
    }

    /// Empties the file once all of it is read and no stream is going, between turns while the
    /// client waits for its next message: the copy is kept no longer than it is needed.
    mutating func compact() {
        guard open.isEmpty, partial.isEmpty, !skipping, offset > 0 else { return }
        let descriptor = Darwin.open(output.path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              UInt64(info.st_size) == offset else { return }
        if ftruncate(descriptor, 0) == 0 { offset = 0 }
    }

    private mutating func lines(_ chunk: Data) -> [JSONValue] {
        var events: [JSONValue] = []
        var rest = chunk[...]
        while let newline = rest.firstIndex(of: 10) {
            let piece = rest[..<newline]
            rest = rest[rest.index(after: newline)...]
            if skipping { skipping = false; partial = Data(); continue }
            partial.append(contentsOf: piece)
            if !partial.isEmpty { events += line(partial) }
            partial = Data()
        }
        if !skipping { partial.append(contentsOf: rest) }
        // a line too long to keep is skipped to its end rather than held without bound
        if partial.count > Self.maximumLine { partial = Data(); skipping = true }
        return events
    }

    private mutating func line(_ data: Data) -> [JSONValue] {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), value.objectValue != nil else { return [] }
        let number = value["s"]?.doubleValue.flatMap { $0.isFinite && abs($0) < 1e9 ? Int($0) : nil } ?? 0
        guard !ended.contains(number) else { return [] }
        if let tap = value["tap"]?.stringValue, !tap.isEmpty {
            state = tap == "on" ? "on" : "none"
            return []
        }
        if value["open"]?.boolValue == true {
            open[number] = Stream()
            return []
        }
        if let event = value["e"], event.objectValue != nil {
            var stream = open[number]
            if event["type"]?.stringValue == "message_start" {
                let id = event["message"]?["id"]?.stringValue ?? ""
                stream = Stream(id: id)
                open[number] = stream
                if dropped.contains(id) { return [] }
                started.insert(id)
            }
            guard var current = stream, !current.id.isEmpty, !dropped.contains(current.id) else { return [] }
            if event["type"]?.stringValue == "message_stop" { current.stopped = true; open[number] = current }
            return [event]
        }
        if let end = value["end"]?.stringValue, !end.isEmpty { return self.end(number) }
        return []
    }

    /// Ends stream `number`: one cut short ends as Claude Code ends such a stream, with a
    /// `message_stop` and no `message_delta`, which the reply takes as an attempt Claude Code
    /// asks again after.
    private mutating func end(_ number: Int) -> [JSONValue] {
        let stream = open.removeValue(forKey: number)
        ended.insert(number)
        guard let stream, !stream.id.isEmpty, !stream.stopped, !dropped.contains(stream.id) else { return [] }
        return [.object(["type": .string("message_stop")])]
    }

    // MARK: Files

    private static func hasWhitespace(_ path: String) -> Bool {
        path.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    /// A new private file: 0600, never one that was there or a link.
    private static func create(_ url: URL, _ data: Data) -> Bool {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return data.withUnsafeBytes { raw -> Bool in
            var written = 0
            while written < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: written), raw.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                written += count
            }
            return true
        }
    }

    /// A private folder (0700) under `parent`, which must be the user's own and not a link.
    private static func makeFolder(in parent: URL) -> URL? {
        var info = stat()
        guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { return nil }
        var template = Array(parent.appendingPathComponent(folderPrefix + "XXXXXXXX").path.utf8CString)
        let path = template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let made = mkdtemp(buffer.baseAddress!) else { return nil }
            return String(cString: made)
        }
        guard let path else { return nil }
        live.hold(URL(fileURLWithPath: path, isDirectory: true).path)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Removes the tap folders a run that ended without its cleanup left a day or more ago:
    /// only the user's own folders of this name that no run of this
    /// app has now, and only the two files a tap writes in them.
    private static func sweep(_ parent: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return }
        let old = Date().addingTimeInterval(-86_400).timeIntervalSince1970
        for name in names.prefix(4096) where name.hasPrefix(folderPrefix) {
            let folder = parent.appendingPathComponent(name)
            var info = stat()
            guard !live.holds(folder.path), lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
                  Double(info.st_mtimespec.tv_sec) < old else { continue }
            unlink(folder.appendingPathComponent(scriptName).path); unlink(folder.appendingPathComponent(outputName).path)
            rmdir(folder.path)
        }
    }
}
