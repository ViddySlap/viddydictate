# Documentation index

Start with the repository [README](../README.md) for requirements, installation, setup, and basic
troubleshooting.

## User and operator reference

- [Code signing and TCC permissions](signing-and-tcc.md): what `setup-signing.sh` creates, why
  permissions survive rebuilds, the security tradeoff that buys, and how to install without it.
- [Local STT daemon](stt-daemon.md): how local transcription is installed, started, and checked.
- [Dictation history](dictation-history.md): the optional append-only history format and location.
- [Sticky notes open-notes aggregate](sticky-notes-open-notes.md): the read-only integration contract
  for agents and companion apps.
- [Markdown file access](markdown-file-access.md): how an opened `.md` is classified read-write,
  read-only, or refused, and what the hardcoded denied root does.

## Contributor and maintainer reference

- [Verification rail](verification.md): deterministic, services, GUI, and full verification tiers.
- [Codex isolation](codex-isolation.md): the security boundary for Codex transforms.
- [Model residency](model-residency.md): LM Studio loading, eviction, and residency verification.
- [Sticky Skill trigger verification](sticky-skill-triggers.md): manual QA for the two UI triggers.
