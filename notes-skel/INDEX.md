# Notes index

The durable task ledger for this container. **Read this first, every session.**
Pi's own context does not survive a restart; this tree does.

Location: `/state/pi-notes` (on the state volume). Never inside the git worktree.

## Layout

```
/state/pi-notes/
  INDEX.md                                  this file - one line per task, newest first
  BOM.md                                    pinned versions and image digest
  principal/
    YYYY-MM-DD.md                           the principal's daily log
    tasks/YYYY-MM-DD__<slug>.md             one file per task the principal owns
  <agent-id>/
    YYYY-MM-DD.md                           that agent's daily log
    tasks/YYYY-MM-DD__<slug>.md             one file per task it was given
  reviews/
    YYYY-MM-DD__<slug>__review.md           standard review
    YYYY-MM-DD__<slug>__adversarial.md      adversarial review
```

## Rules

- **Append, dated. Never rewrite history.** A wrong earlier entry gets a correction below it, not
  an edit.
- Every deliverable gets **both** review files before it is reported as done.
- No secrets, tokens or `.env` content. Redact before writing.
- An agent writes only its own note file, plus the review files it was asked to produce.

## Tasks

| Date | Slug | Owner | Status | Reviews |
| --- | --- | --- | --- | --- |
| - | - | - | - | - |
