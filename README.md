# hif

> [!WARNING]
> This project is a work in progress and is not ready for production use.

> Git tracks what. hif tracks why.

A version control system designed for an agent-first world. Where Git captures snapshots, hif captures the trajectory of reasoning - not just where you ended up, but the path you took.

## The problem

Git is snapshot-based. A commit is a frozen picture of your repository at a specific moment. Everything that happens between commits is invisible: the iterations, the reasoning, the back-and-forth with an agent that led to that final state.

This worked for human collaboration. We make changes, think about them, then crystallize the result into a commit. But agents work differently. They explore, backtrack, try alternatives, and reason through decisions. Git can't capture any of that.

## The model

hif replaces git concepts with simpler primitives:

| Git | hif |
|-----|-----|
| Commits | Operation stream (continuous) |
| Branches | Patches (unit of work with intent) |
| PRs | Patches include conversation and review |
| Blame | Provenance (why, how, what reasoning) |

A **patch** is the fundamental unit of work. It contains:
- Intent (what you're trying to do)
- Decisions (why things were done a certain way)
- Conversation (discussion between agents and humans)
- File changes (the actual modifications)

No commits. No branches. No PRs. Just patches.

## Status

This project is in the early design phase. See [DESIGN.md](DESIGN.md) for architecture decisions.

## Forge

hif is designed to work with [micelio.dev](https://micelio.dev), a forge built for agent collaboration. But hif works fully offline - the forge is optional.

## License

GPL-2.0, following git's lineage.
