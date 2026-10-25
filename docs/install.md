# Installing Find My Crew

Find My Crew needs macOS 15 or later. Every release is one universal app (Apple silicon and Intel) with the `fmc`
command-line tool inside it (`Find My Crew.app/Contents/Helpers/fmc`), so installing the app installs the CLI.
Releases are signed with a Developer ID (team `QWD87G9T3P`) and notarized by Apple.

```sh
curl -fsSL https://raw.githubusercontent.com/arkaydeus/find-my-crew/main/scripts/install.sh | bash
```

The installer downloads the latest release's `FindMyCrew.zip`, checks it against the release's SHA-256 file,
checks that it's signed by team `QWD87G9T3P` and accepted by Gatekeeper, puts the app in `/Applications` (`~/Applications` if that isn't writable, or wherever it's
already installed) and links `~/.local/bin/fmc` to the `fmc` inside the app. Updating the app therefore updates
`fmc`. Run it again to update; quit the app first.

Options go after `bash -s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/arkaydeus/find-my-crew/main/scripts/install.sh | bash -s -- --version 1.2.0
```

| Option | |
| --- | --- |
| `--version V` | a specific release instead of the latest |
| `--from PATH` | a local `FindMyCrew.zip` or `Find My Crew.app` instead of downloading |
| `--app-dir DIR` | where the app goes |
| `--bin-dir DIR` | where the `fmc` link goes (default `~/.local/bin`) |
| `--no-cli` | app only |
| `--uninstall` | remove the app and the `fmc` link; settings in `~/Library/Containers/com.findmycrew.app` are kept |

The installer won't replace something at the destination that isn't Find My Crew, or an `fmc` there that's a
plain file rather than its own link. If `~/.local/bin` isn't on your `PATH` it says so.

## Downloading by hand

Download `FindMyCrew.zip` from [Releases](https://github.com/arkaydeus/find-my-crew/releases), unzip it and drag
**Find My Crew** into Applications. It's notarized, so it opens like any other downloaded app. For the CLI:

```sh
mkdir -p ~/.local/bin && ln -s "/Applications/Find My Crew.app/Contents/Helpers/fmc" ~/.local/bin/fmc
```

## From source

```sh
mise install          # once: xcodegen
mise run install      # build a release from this checkout and install it the same way
mise run uninstall
```

Installer options go after `--`, e.g. `mise run install -- --bin-dir ~/bin`. Source builds are signed ad hoc and
skip notarization. That's fine on the Mac that built them, but don't hand the zip to anyone else.

## Releasing

```sh
mise run release -- 1.2.0
```

Releases are built on your Mac; there's no CI. `scripts/release/publish.sh` first checks that `gh` is logged in
and that you're on a clean `main` in sync with `origin`. Then it runs the tests (skip them with
`SKIP_TESTS=1`) and builds with `scripts/release/build.sh 1.2.0`, signed and notarized. Finally `gh release create` makes the tag
`v1.2.0` on that commit and publishes the release with generated notes and two assets: `FindMyCrew.zip` and
`FindMyCrew.zip.sha256`. Asset names don't change between releases, so `releases/latest/download/FindMyCrew.zip`
always points at the newest one.

The release version comes from the command. `MARKETING_VERSION` in `project.yml` is only for development builds, and the build
number is the commit count. Versions are `MAJOR.MINOR[.PATCH]`, because macOS bundle versions can't carry
pre-release suffixes.

To check a release build locally without publishing, run `mise run release:build -- 1.2.0`. The output goes to
`build/release/`. The build script fails unless both binaries are universal, the signature verifies, the model
is bundled and `fmc --version` matches the app's version.

### Signing and notarization

`build.sh` picks its signing with `SIGNING`. The default, `auto`, uses Developer ID when the team's
**Developer ID Application** certificate is in the keychain and falls back to ad hoc when it isn't.
`publish.sh` forces `developer-id`. In that mode Xcode signs `fmc` and the app with the hardened runtime and a
secure timestamp. The script then submits the zip with
`xcrun notarytool submit --keychain-profile orkestrator-notary --wait`, staples the ticket to the app and fails
unless `spctl` accepts it. Notarization usually takes a few minutes.

You need two things on the Mac you release from:

- the Developer ID Application certificate for team `QWD87G9T3P` in the login keychain
  (`security find-identity -v -p codesigning`)
- a notarytool profile named `orkestrator-notary`
  (`xcrun notarytool store-credentials orkestrator-notary --apple-id <id> --team-id QWD87G9T3P`, which asks for an
  app-specific password from account.apple.com)

`TEAM_ID` and `NOTARY_PROFILE` override both, for example in a fork. A fork also has to change `TEAM_ID` in
`scripts/install.sh`, which refuses downloads signed by anyone else. If notarization fails, the error gives the
submission ID; `xcrun notarytool log <id> --keychain-profile orkestrator-notary` names the files Apple
rejected.
