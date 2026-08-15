# Sticky notes open-notes aggregate

ViddyDictate owns the Option+N sticky-note runtime store. Agents and companion apps should read the
generated aggregate instead of walking or writing the per-note files directly:

```text
~/Library/Application Support/ViddyDictate/sticky-notes/_open-notes.md
```

The file is auto-generated, read-only from outside the app, and ordered to match the open tab order.
The active tab is marked in its heading.

## Format

The aggregate starts with an HTML comment identifying it as generated, followed by one Markdown
section per materialized open note:

```markdown
## Note title (active)

note body

**Attachments:**
- /absolute/path/to/image.png
- /absolute/path/to/video.mov
```

`**Attachments:**` is additive and appears only when the note has sidecar media. Paths are absolute
paths to app-managed copies under the sticky-notes `attachments/<note-id>/` directory. The list may
contain images and videos; consumers should treat these as local file paths, not embedded file bytes.

Empty tabs stay lazy. A tab with no body and no assets is not materialized as a note file and does not
appear in `_open-notes.md` until it receives content or media.

## Consumer contract

- ViddyDictate is the only writer.
- Codex and Claude should read `_open-notes.md` when the user asks about open sticky notes, then inspect any
  listed image/video paths when he asks them to look at or work from those assets.
- The external `read_open_notes` tool returns the Markdown text, including attachment paths, as a path-only
  read. It does not upload or return image/video bytes.
