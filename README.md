# openbubbles-installer

A shell script that handles installing, updating, and launching [OpenBubbles](https://github.com/OpenBubbles/openbubbles-app) on Linux.

The official release tarball ships a bare binary alongside its shared libraries, but no installer or desktop integration. The Flatpak is seemingly not maintained. This script fills that gap.

## What it does

- Installs `jq` and `libmpv` if missing (with confirmation prompts)
- Downloads the latest release tarball from GitHub
- Extracts and installs to `~/opt/openbubbles/`
- Creates a `.desktop` entry and app icon
- Copies itself to `~/.local/bin/openbubbles` so it works as a launcher going forward
- On subsequent launches, checks for new releases in the background
- Handles the `libmpv.so.1` → `libmpv.so.2` symlink that most distros need

## Usage

```bash
# Download and run
curl -LO https://raw.githubusercontent.com/<you>/openbubbles-installer/main/openbubbles.sh
chmod +x openbubbles.sh
./openbubbles.sh install
```

After:

```
openbubbles              # launch (checks for updates in background)
openbubbles update       # update to latest release
openbubbles uninstall    # remove everything
openbubbles --help       # show usage
```

All commands accept `--yes` / `-y` to skip confirmation prompts.

## What gets installed where

| Path | Contents |
|---|---|
| `~/opt/openbubbles/` | App binary, shared libraries, assets |
| `~/.local/bin/openbubbles` | Launcher script (this script) |
| `~/.local/share/applications/openbubbles.desktop` | Desktop entry |
| `~/.local/share/icons/openbubbles.png` | App icon |

User data (messages, settings) is stored by the app itself in `~/.local/share/app.bluebubbles.BlueBubbles/`.

## libmpv

OpenBubbles is built against `libmpv.so.1`, but most current distros ship `libmpv.so.2`. The installer creates a compatibility symlink. This works in practice but is a cross-ABI link.

## Uninstalling

`openbubbles uninstall` removes the app, desktop entry, icon, user data, and the libmpv symlink (if the installer created it). It also offers to remove the libmpv package itself.

## License

MIT

## Todo
* Make updating automatically carry over user data (probably easy). For now export messages and settings in Openbubbles settings before updating, then after restore from backup.
