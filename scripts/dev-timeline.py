#!/usr/bin/env python3
"""Read Claude Pool's developer recording as one timeline.

Every channel (privacy, http, session, events) is merged in the order records were made (`seq`).
Request numbers start again at each launch, so the latest launch is read unless --launch or
--all-launches says otherwise. Pick what to follow with --req, --run, --conversation or --review: a request brings in the runs
that served it, and a run brings in its terminal, stream, transcript and hook records.

  scripts/dev-timeline.py --list
  scripts/dev-timeline.py --req 12
  scripts/dev-timeline.py --run 0a1b2c3d --kinds pty.,tap.
  scripts/dev-timeline.py --req 12 --bundle /tmp/req-12.jsonl
  scripts/dev-timeline.py --privacy --req 12

A conversation is recorded as its change from the last record of the same thread (`kept` leading
messages, then the new ones; instructions and tools "same" until they change). Records are read in
order and each gets its whole request back under "whole"; a bundle carries it. A thread whose earlier
records were let go for the channel's size limit is marked incomplete. A large item (a message or
a tool of 1 KB or more) is kept the first time and named after. Closed files are raw DEFLATE
(`.jsonl.deflate`) and read as they are; the client's transcript is kept by its rows' shape.
"""
import argparse
import json
from pathlib import Path
import sys
import zlib

DEFAULT_ROOT = Path.home() / "Library/Application Support/Claude Pool/developer-records"
CHANNELS = ("privacy", "http", "session", "events")


def load(root):
    records = []
    for channel in CHANNELS:
        folder = root / channel
        if not folder.is_dir():
            continue
        for path in sorted(list(folder.glob(channel + "-*.jsonl")) + list(folder.glob(channel + "-*.jsonl.deflate"))):
            raw_bytes = path.read_bytes()
            if path.name.endswith(".deflate"):
                try:
                    raw_bytes = zlib.decompress(raw_bytes, -15)  # raw DEFLATE, as the recorder writes a closed file
                except zlib.error:
                    print("%s could not be read" % path.name, file=sys.stderr)
                    continue
            for raw in raw_bytes.splitlines():
                try:
                    record = json.loads(raw)
                except ValueError:
                    continue  # a line cut by a full disk or a quit
                record["channel"] = channel
                records.append(record)
    # Launches in the order they began; within one, records in the order they were made.
    began = {}
    for r in records:
        launch = r.get("launch", "-")
        if launch not in began or r.get("t", "") < began[launch]:
            began[launch] = r.get("t", "")
    records.sort(key=lambda r: (began.get(r.get("launch", "-"), ""), r.get("seq", 0)))
    return records, sorted(began, key=began.get)


def conversations(record):
    """The conversation changes a record carries: the gateway's request body, the request a run was told."""
    data = record.get("data") or {}
    for holder in (data.get("body"), data.get("sent_to_run")):
        if isinstance(holder, dict) and isinstance(holder.get("conversation"), dict):
            yield holder["conversation"]


def rebuild(records):
    """Puts each recorded conversation back whole, under "whole", from its thread's records before it.
    A large item recorded once ({"as": digest, "item": ...}) stands for each later {"same_as": digest}."""
    threads, items = {}, {}
    def resolve(values):
        out, ok = [], True
        for v in values or []:
            if isinstance(v, dict) and set(v) == {"as", "item"}:
                items[v["as"]] = v["item"]; out.append(v["item"])
            elif isinstance(v, dict) and set(v) == {"same_as"}:
                ok = ok and v["same_as"] in items; out.append(items.get(v["same_as"], v))
            else:
                out.append(v)
        return out, ok
    for r in records:
        if r.get("kind") == "log.devrecord.started":
            items.clear()
        for change in conversations(r):
            key = (r.get("launch", "-"), change.get("thread"))
            last = threads.get(key, {"messages": None, "system": None, "tools": None})
            kept = int(change.get("kept", 0))
            complete = kept == 0 or last["messages"] is not None and len(last["messages"]) >= kept
            new, found = resolve(change.get("messages", []))
            complete = complete and found
            messages = (last["messages"] or [])[:kept] + new
            whole = {"messages": messages, "complete": complete}
            for part in ("system", "tools"):
                value = change.get(part)
                if value == "same":
                    whole[part] = last[part]
                elif part == "tools" and isinstance(value, list):
                    whole[part], found = resolve(value); whole["complete"] = whole["complete"] and found
                else:
                    whole[part] = value
            threads[key] = {"messages": messages if complete else None, "system": whole["system"], "tools": whole["tools"]}
            change["whole"] = whole


def select(records, args):
    if not (args.req or args.run or args.conversation or args.review):
        return records
    reqs, runs = set(args.req or []), set(args.run or [])
    conversations, reviews = set(args.conversation or []), set(args.review or [])
    # Grow the set of ids until it stops: a request names its runs and reviews, a run its requests.
    changed = True
    while changed:
        changed = False
        for r in records:
            data = r.get("data") or {}
            hit = (r.get("req") in reqs or r.get("run") in runs or r.get("review") in reviews
                   or r.get("conversation") in conversations or data.get("conversation") in conversations)
            if not hit:
                continue
            for key, bucket in (("req", reqs), ("run", runs), ("review", reviews)):
                value = r.get(key)
                if value and value not in bucket:
                    bucket.add(value); changed = True
    def keep(r):
        data = r.get("data") or {}
        path = data.get("path", "") if isinstance(data, dict) else ""
        return (r.get("req") in reqs or r.get("run") in runs or r.get("review") in reviews
                or r.get("conversation") in conversations or data.get("conversation") in conversations
                or any(run in path for run in runs))
    return [r for r in records if keep(r)]


def text_of(value):
    if isinstance(value, dict):
        if "text" in value:
            return value["text"]
        if "base64" in value:
            return "<%d bytes base64>" % (len(value["base64"]) * 3 // 4)
    return json.dumps(value, ensure_ascii=False)


def summary(r, width):
    data = r.get("data") or {}
    kind = r.get("kind", "?")
    if kind in ("pty.out", "pty.in", "http.sent") or kind == "transcript.read" and "bytes" in data:
        body = text_of(data.get("bytes"))
    elif kind == "transcript.read":
        body = "offset=%s bytes=%s rows=%s" % (data.get("offset"), data.get("count"),
                                              ",".join(str((row or {}).get("type", "?")) for row in data.get("rows", [])))
    elif kind == "http.request":
        change = next(conversations(r), None)
        if change:
            body = "%s %s messages=%s new=%s%s" % (data.get("method"), data.get("path"), change.get("count"),
                                                   len(change.get("messages", [])), "" if change.get("whole", {}).get("complete", True) else " incomplete")
        else:
            body = "%s %s %s" % (data.get("method"), data.get("path"), text_of(data.get("body")))
    elif kind == "privacy.prepared":
        read = data.get("read", {})
        body = "texts=%s read=%s partial=%s read_ms=%s categories=%s" % (
            read.get("texts"), read.get("read"), read.get("partial"), read.get("read_ms"),
            json.dumps(data.get("categories", {}), ensure_ascii=False))
    elif kind.startswith("privacy.reply"):
        body = json.dumps({k: v for k, v in data.items()}, ensure_ascii=False)
    elif kind.startswith("log."):
        body = " ".join("%s=%s" % item for item in data.items())
    else:
        body = json.dumps(data, ensure_ascii=False)
    body = body.replace("\r", "\\r").replace("\n", "\\n").replace("\x1b", "\\e")
    return body if width <= 0 or len(body) <= width else body[:width] + " …"


def privacy_report(records):
    """Each prepared request: what the model and the rules found in every text it read, and each replacement."""
    for r in records:
        if r.get("kind") != "privacy.prepared":
            continue
        data = r.get("data") or {}
        print("=" * 100)
        print("review %s  req %s  conversation %s  %s" % (r.get("review"), r.get("req"), r.get("conversation"), r.get("t")))
        print("read: %s" % json.dumps(data.get("read"), ensure_ascii=False))
        for entry in data.get("model_texts", []):
            text = entry.get("text", "")
            print("-" * 100)
            for source in ("model", "rules"):
                spans = entry.get(source)
                if spans is None:
                    print("  %-5s not read" % source)
                    continue
                for span in spans:
                    piece = span["text"] if "text" in span else utf16_slice(text, span["start"], span["end"])
                    print("  %-5s %-10s %.2f  %r" % (source, span["category"], span.get("score", 1), piece))
        for field in data.get("review", []):
            print("  review %s" % field.get("location"))
            for segment in field.get("segments", []):
                if "original" in segment:
                    print("    %r -> %s (%s)" % (segment["original"], segment["placeholder"], segment["category"]))


def utf16_slice(text, start, end):
    encoded = text.encode("utf-16-le")
    return encoded[start * 2:end * 2].decode("utf-16-le", errors="replace")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--launch", help="the launch to read (default: the latest)")
    parser.add_argument("--all-launches", action="store_true")
    parser.add_argument("--req", action="append")
    parser.add_argument("--run", action="append")
    parser.add_argument("--conversation", action="append")
    parser.add_argument("--review", action="append")
    parser.add_argument("--kinds", help="comma-separated kind prefixes to show, e.g. log.,privacy.")
    parser.add_argument("--width", type=int, default=160, help="cut each line to this many characters; 0 for whole")
    parser.add_argument("--list", action="store_true", help="list the requests recorded")
    parser.add_argument("--privacy", action="store_true", help="redaction report for the selected requests")
    parser.add_argument("--bundle", type=Path, help="write the selected records, whole, to this JSON-lines file")
    args = parser.parse_args()
    if not args.root.is_dir():
        sys.exit("No developer recording at %s" % args.root)
    records, launches = load(args.root)
    if not records:
        sys.exit("The developer recording is empty.")
    rebuild(records)
    if not args.all_launches:
        launch = args.launch or launches[-1]
        records = [r for r in records if r.get("launch", "-") == launch]
        print("launch %s (%d records; launches: %s)" % (launch, len(records), ", ".join(launches)), file=sys.stderr)
    if args.list:
        for r in records:
            if r.get("kind") == "log.gateway.request":
                d = r.get("data", {})
                print("req %-5s %s %-11s conv %-16s %-7s %s ms  %s" % (r.get("req"), r.get("t"), d.get("kind"), d.get("conv"),
                                                                     d.get("outcome"), d.get("total_ms"), d.get("reason")))
        return
    selected = select(records, args)
    if args.kinds:
        prefixes = tuple(p for p in args.kinds.split(",") if p)
        selected = [r for r in selected if r.get("kind", "").startswith(prefixes)]
    if args.bundle:
        with args.bundle.open("w") as out:
            for r in selected:
                out.write(json.dumps(r, ensure_ascii=False) + "\n")
        print("%d records written to %s" % (len(selected), args.bundle))
        return
    if args.privacy:
        privacy_report(selected)
        return
    start = selected[0].get("mono_ns", 0) if selected else 0
    for r in selected:
        offset = (r.get("mono_ns", start) - start) / 1e6
        ids = " ".join("%s=%s" % (k, r[k]) for k in ("req", "run", "review", "account") if r.get(k))
        print("%9.1fms %-8s %-26s %-28s %s" % (offset, r["channel"], r.get("kind", "?"), ids, summary(r, args.width)))


if __name__ == "__main__":
    main()
