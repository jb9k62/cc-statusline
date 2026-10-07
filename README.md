# cc-statusline

A two-line status line for [Claude Code](https://claude.com/claude-code).

- **Line 1:** model · effort · repo/worktree · branch · PR · lines added/removed
- **Line 2:** context bar · 5h limit · weekly limit · session cost

The `│` inside a limit bar marks even-consumption pace: a bar past the marker
means you are burning the window faster than the clock.

## Requirements

- `bash` (works with the 3.2 that ships with macOS)
- `jq`
- `git`

The branch cache uses `stat -f %m`, so it is macOS/BSD only as written.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/jb9k62/cc-statusline/main/statusline.sh \
  -o ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Then add this to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```
