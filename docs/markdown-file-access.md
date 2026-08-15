# Markdown file access and its privacy boundary

Opening a `.md` file with ViddyDictate turns it into a file-backed Sticky Notes tab: typing edits the
real file on disk. Because that is a write path into arbitrary user documents, every handed-in path is
classified before anything is opened, backed up, or written.

`PathClassifier` (`Sources/App/PathClassifier.swift`) returns exactly one of four decisions:

| Decision | When | Effect |
|---|---|---|
| `refuseDeniedRoot` | the path is inside a denied root | refused outright, nothing is read or backed up |
| `readOnlyVault` | the path is inside a vault registered with Obsidian | opens read-only |
| `readOnlyFailClosed` | Obsidian's registry is missing or unparseable | opens read-only |
| `readWriteLoose` | anywhere else | opens read-write |

Two properties are deliberate. Denied roots are checked *before* Obsidian's registry is read, so the
refusal does not depend on a mutable third-party config file. And an unreadable or malformed registry
degrades to read-only rather than to read-write, so a broken config cannot silently widen access.

Both the candidate path and the roots are symlink-resolved and standardized before comparison, so
`..` traversal and symlink aliases cannot walk into a denied root.

## The denied root

`AppPaths.deniedRoots` currently contains a single hardcoded entry:

```
~/Documents/private
```

This is a personal convention of the original author, who keeps a sensitive corpus at that path and
wanted a refusal that no configuration mistake could switch off. It ships as a constant rather than a
setting for exactly that reason: a hardcoded deny cannot be disabled by editing a preferences file.

Two consequences worth knowing:

- If you keep a folder at `~/Documents/private`, ViddyDictate will refuse to open markdown from it and
  will show "Private vault files are refused." That is the intended behavior, not a bug.
- If your own sensitive material lives somewhere else, this deny does **not** cover it. It is not a
  general-purpose privacy feature, and it is not a substitute for filesystem permissions.

The refused path is never written to the log, because the filename itself may be sensitive.

Making the deny list user-configurable would be a reasonable enhancement. It has not been done, and
the constant is kept as-is rather than removed, because removing it would weaken a live protection
without replacing it.
