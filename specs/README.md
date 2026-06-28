# cluade BDD Specifications

Three Behavior-Driven Development specifications for cluade, at different fidelity levels.
Each can be given to an LLM as a black-box contract for re-implementation in any language/stack.

## Directory Index

| Directory | Fidelity | Size | Use case |
|-----------|----------|------|----------|
| `A-exact-clone/` | Drop-in replacement | ~1930 lines | Run the existing test suite unmodified. Every flag, edge case, and quirk preserved. |
| `B-faithful-port/` | Same architecture, cleaned up | ~1430 lines | Same 12-tool set and UX. Better HTTP, token counting, Unicode, streaming. |
| `C-loose-inspiration/` | Redesigned from essence | ~1030 lines | What you'd build today. New features: daemon mode, pipe input, multi-provider, tool extensions. |

## How to Use

1. Pick a tier based on your goal
2. Give the spec to an LLM along with: "Implement this system in <language>"
3. The spec is the contract — the LLM chooses implementation details

## Spec Format

Each spec uses **Gherkin** (Given/When/Then) for behavioral scenarios plus:
- **System boundaries** (what's inside vs. outside the system)
- **Interface contracts** (CLI flags, config schema, tool schemas, session format)
- **Invariants** (what must always be true)
- **Edge cases** (what happens when things go wrong)

## Validity

These specs were derived from:
- Full source code read of cluade (cluade.lua, agent.lua, tools.lua, provider.lua, store.lua, loopdetect.lua, dangercheck.lua, lineedit.lua, colors.lua, skillimport.lua, marketplace.lua)
- The README.md specification document
- The test suite (18 test files)
