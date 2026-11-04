"""A small language server over real stdio, for scripts/lsp_check.lua.

It speaks enough of the protocol to exercise the host's client end to end
through the native process module: Content-Length framing in both directions,
initialize, document sync, diagnostics, hover, completion and definition.
Standard library only.

    python -u fake_lsp_server.py [mode]

Modes:
    ok      (default) behave
    crash   exit with code 7 right after initialize
    deaf    answer initialize, then stop reading stdin (a stalled server)

A document's diagnostics are one warning per line containing "TODO".
"""
import json
import sys
import time

MODE = sys.argv[1] if len(sys.argv) > 1 else "ok"
stdin = sys.stdin.buffer
stdout = sys.stdout.buffer
documents = {}


def send(message):
    message["jsonrpc"] = "2.0"
    body = json.dumps(message).encode("utf-8")
    stdout.write(b"Content-Length: %d\r\n\r\n" % len(body))
    stdout.write(body)
    stdout.flush()


def read_message():
    length = None
    while True:
        line = stdin.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            break
        name, _, value = line.partition(b":")
        if name.strip().lower() == b"content-length":
            length = int(value.strip())
    if length is None:
        return None
    return json.loads(stdin.read(length).decode("utf-8"))


def publish(uri):
    diagnostics = []
    for number, line in enumerate(documents.get(uri, "").split("\n")):
        column = line.find("TODO")
        if column >= 0:
            # Columns are UTF-16 code units, as the protocol says.
            start = len(line[:column].encode("utf-16-le")) // 2
            diagnostics.append({
                "range": {"start": {"line": number, "character": start},
                          "end": {"line": number, "character": start + 4}},
                "severity": 2, "source": "fake", "code": "todo", "message": "TODO left in the file",
            })
    send({"method": "textDocument/publishDiagnostics", "params": {"uri": uri, "diagnostics": diagnostics}})


def word_at(uri, position):
    lines = documents.get(uri, "").split("\n")
    if position["line"] >= len(lines):
        return ""
    line = lines[position["line"]]
    units = line.encode("utf-16-le")
    index = len(units[: position["character"] * 2].decode("utf-16-le"))
    start = end = index
    while start > 0 and (line[start - 1].isalnum() or line[start - 1] == "_"):
        start -= 1
    while end < len(line) and (line[end].isalnum() or line[end] == "_"):
        end += 1
    return line[start:end]


def main():
    while True:
        message = read_message()
        if message is None:
            return 0
        method = message.get("method")
        params = message.get("params") or {}
        ident = message.get("id")

        if method == "initialize":
            send({"id": ident, "result": {
                "capabilities": {
                    "textDocumentSync": 1,
                    "hoverProvider": True,
                    "completionProvider": {"triggerCharacters": ["."]},
                    "definitionProvider": True,
                },
                "serverInfo": {"name": "fake-lsp", "version": "1"},
            }})
            if MODE == "crash":
                sys.stderr.write("fake-lsp: crashing on purpose\n")
                sys.stderr.flush()
                return 7
            if MODE == "deaf":
                time.sleep(600)
        elif method == "textDocument/didOpen":
            doc = params["textDocument"]
            documents[doc["uri"]] = doc["text"]
            publish(doc["uri"])
        elif method == "textDocument/didChange":
            uri = params["textDocument"]["uri"]
            documents[uri] = params["contentChanges"][-1]["text"]
            publish(uri)
        elif method == "textDocument/didClose":
            uri = params["textDocument"]["uri"]
            documents.pop(uri, None)
            send({"method": "textDocument/publishDiagnostics", "params": {"uri": uri, "diagnostics": []}})
        elif method == "textDocument/hover":
            word = word_at(params["textDocument"]["uri"], params["position"])
            result = {"contents": {"kind": "markdown", "value": "**%s**\n\nfake hover" % word}} if word else None
            send({"id": ident, "result": result})
        elif method == "textDocument/completion":
            send({"id": ident, "result": {"isIncomplete": False, "items": [
                {"label": "alpha", "kind": 3, "detail": "function"},
                {"label": "beta", "kind": 6, "detail": "variable"},
            ]}})
        elif method == "textDocument/definition":
            uri = params["textDocument"]["uri"]
            send({"id": ident, "result": {"uri": uri, "range": {
                "start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 5}}}})
        elif method == "shutdown":
            send({"id": ident, "result": None})
        elif method == "exit":
            return 0
        elif ident is not None and method:
            send({"id": ident, "error": {"code": -32601, "message": "unhandled: " + method}})


if __name__ == "__main__":
    sys.exit(main())
