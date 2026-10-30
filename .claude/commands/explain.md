# /explain <path>
Delegates to the `doc-explorer` agent to explain the role and logic of a specific file.

## Arguments
- `path`: Absolute or relative path to the file.

## Sequence
1. Invoke `doc-explorer` agent.
2. Provide the file content at `path` and relevant documentation from `ARCHITECTURE.md`.
