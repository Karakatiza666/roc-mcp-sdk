# Feasibility spikes

Each spike was checked with the real compiler, nightly-2026-11-14-a87808d, and basic-cli 0.28.1. The results are in `DESIGN.md` section 11. Run every command from the repository root through `research/spikes/roc.sh`. The script adds the memory cap, the timeout, `TMPDIR` and a local cache under `.tmp/`.

| Dir | Question | Commands |
| --- | --- | --- |
| `s1_callbacks/` | Can a package keep effectful handlers in a List or a Dict, with a generic `state`, and call them in a loop? Can `expect` call them? | `roc.sh build research/spikes/s1_callbacks/app.roc --output=.tmp/s1`, then `printf 'count\nhello\n' \| .tmp/s1`. `roc.sh test research/spikes/s1_callbacks/test_effects.roc` must fail with "effectful expect". `dict_handlers.roc` uses the echo host. |
| `s2_json/` | A dynamic `JsonValue`: parser, serializer, `\u` escapes, surrogates, numbers. Its speed. A typed bridge to `Encoding.Json`. | `roc.sh test research/spikes/s2_json/test.roc`. `roc.sh build research/spikes/s2_json/perf.roc --output=.tmp/s2perf && .tmp/s2perf`. `wrap_app.roc` reproduces a compiler bug. |
| `s3_engine/` | The architecture: a pure engine, an effectful stdio driver, threaded state, typed tool arguments, and `input_required` served as server-to-client requests while other requests are answered. | `roc.sh test research/spikes/s3_engine/test_engine.roc`. `roc.sh build research/spikes/s3_engine/app.roc --output=.tmp/s3 && .tmp/s3 < research/spikes/s3_engine/session.jsonl`. |
| `s4_api/` | The whole public API of DESIGN.md as signatures with stub bodies, and a sketch of the roc-syntax-mcp port that type-checks against it. | `roc.sh check research/spikes/s4_api/package/main.roc`. `roc.sh check research/spikes/s4_api/port_sketch.roc`. |

Do not use `roc file.roc` (run) on this machine. It needs an inotify instance, and every instance is in use (`max_user_instances` = 128). Use `roc build`, then run the binary. `roc check` and `roc test` work.
