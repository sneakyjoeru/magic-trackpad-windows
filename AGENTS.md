# Agent notes

## graphify

This repo has a graphify knowledge graph in `graphify-out/` (git-ignored, built on the NAS DSH host;
upstream https://github.com/Graphify-Labs/graphify). Use it before grepping or reading whole files:

- `graphify query "<question>"` - cited subgraph (`src=<file> loc=L<line>`) for a code/architecture question
- `graphify path "<A>" "<B>"`, `graphify explain "<symbol>"`, `graphify affected "<symbol>"` (blast radius before an edit)
- `graphify-out/GRAPH_REPORT.md` - communities, god nodes, surprising connections (broad overview only)
- after changing code: `graphify update .` (AST only, seconds, no LLM). Commits made on the NAS DSH rebuild it
  automatically through the graphify git hooks.

On the NAS DSH the CLI is `/volume1/docker/dsh/home/tools/bin/graphify` (also `graphify` on PATH after the next
image rebuild); the DSH skill `graphify` lists every graphed repo and the full refresh script. If `graphify-out/`
is missing (a fresh clone on another host), skip it and read the code directly.
