# ladybird end-to-end scenarios (elate)

[`elate`](https://github.com/dakra/elate) scenarios that drive ladybird in a sandboxed
Emacs against `tools/mock-server.py`: the commands, their prompts and the keys a user
types, with the mock server's log as the oracle for what arrived.

```sh
test/elate/run.sh                                   # every scenario, every variant
test/elate/run.sh test/elate/matrix/ui.json         # one scenario
test/elate/run.sh -v unix,tcp test/elate/matrix/reconnect.json
uvx elate run --keep-going --variant tcp test/elate/matrix/connect.json
```

`run.sh` runs each scenario once per variant and exits non-zero when a group failed.
It needs `uvx` (or `ELATE` naming the elate command, 0.16 or later) and `python3`;
`LADYBIRD_ELATE_PYTHON` names the Python that runs the mock server.  The sessions load the
native module from the checkout and fall back to `test/ladybird-fake-module.el`.

| Scenario | Variants | Covers |
|---|---|---|
| `connect` | stdio, unix, tcp | opening a page, navigation, a second buffer, closing |
| `input` | stdio, unix | insert mode keys, text, paste, selection, scroll commands |
| `size` | stdio, tcp | viewport after window and frame changes, visibility, focus |
| `ui` | stdio, unix | dialogs, pickers, permissions, withdrawn requests, a prompt that waits for the minibuffer, page events, find |
| `reconnect` | unix, tcp | a lost connection, another server process, a second client, server exit |
| `limit` | stdio | a server that shows one page: a second page loads in the first |
| `mouse` | (graphical frame) | clicks, wheel and movement at canvas positions |

A variant is how the mock server is reached: started by the connection on standard
input and output, or started first and listening on a Unix socket or a TCP port.
`lib/ladybird-setup.el` has the helpers, also for a session started by hand:

```sh
uvx elate start --name lady --ui gui --eval-file "$PWD/test/elate/lib/ladybird-setup.el"
uvx elate -s lady eval "(ladybird-elate-start 'stdio)"
```
