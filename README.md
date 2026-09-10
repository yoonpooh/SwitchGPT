<p align="center">
  <img src="Assets/SwitchGPT.png" width="128" alt="SwitchGPT icon">
</p>

# SwitchGPT

A lightweight macOS menu bar app for switching between accounts in the **ChatGPT desktop app**.

Save accounts, check remaining usage, and switch from one compact panel. SwitchGPT is an independent utility and is not affiliated with or endorsed by OpenAI.

[Download the latest release](https://github.com/yoonpooh/SwitchGPT/releases/latest)

## Features

- Add accounts through browser sign-in without replacing the current ChatGPT session.
- Store sign-in credentials in macOS Keychain.
- Show account email addresses and plan badges.
- Display the usage windows returned by the service, remaining percentages, and reset times.
- Show available usage resets and the nearest expiration date. Hover over the date for its time.
- Switch accounts after confirmation; ChatGPT and its local background server restart as part of the switch.
- Reorder accounts by dragging cards, with the current account highlighted.
- Use a template menu bar icon that follows light and dark appearance.
- Follow the Mac's preferred language: English, Korean, Simplified Chinese, or Japanese. Other languages fall back to English. Chinese language variants use Simplified Chinese in this release.
- Format dates for the selected language and the Mac's time zone.

## Requirements

- macOS 14 or later.
- An Apple silicon Mac for the downloadable `arm64` build. Intel builds are not included or verified in this release.
- The current ChatGPT desktop app installed and signed in.
- The default file-based credential store at `~/.codex/auth.json`.

SwitchGPT targets the current ChatGPT desktop app, which brings Chat, Work, and Codex together ([OpenAI documentation](https://help.openai.com/en/articles/20001275-chatgpt-work-and-codex)). It locates the app by its existing bundle identifier `com.openai.codex` and uses the CLI bundled with it; a separate CLI installation is not required. Browser sessions are not changed.

## Install

1. Download `SwitchGPT-v0.1.2-macos-arm64.zip` from [Releases](https://github.com/yoonpooh/SwitchGPT/releases).
2. Extract the ZIP and move **SwitchGPT.app** into **Applications**.
3. Open the app. Its double-arrow icon appears in the menu bar; it has no regular window or Dock icon.
4. Click the menu bar icon, choose **Add account**, and finish signing in in your browser.

### Ask ChatGPT to install it

In a ChatGPT session with access to local files and terminal tools, paste this prompt:

```text
Install the latest SwitchGPT release from https://github.com/yoonpooh/SwitchGPT on this Mac.

Check that the release supports my Mac, download the app ZIP and its published
SHA256SUMS.txt, and verify the checksum before installing. Quit any running
SwitchGPT instance, install the app in /Applications, and open it. Preserve all
existing saved accounts and Keychain entries. Do not sign in or switch accounts
for me. If macOS blocks the first launch, guide me through Apple's per-app
Open Anyway steps without disabling system security settings.
```

If local tools are unavailable, use the manual installation steps above.

### First launch

The release uses an **ad-hoc signature** and is **not notarized by Apple**. If macOS blocks it, verify that you downloaded the intended release, attempt to open it, then use **System Settings → Privacy & Security → Open Anyway** if that option is offered. Follow [Apple's instructions for opening an app from an unknown developer](https://support.apple.com/en-ca/guide/mac-help/mh40616/mac). Managed Macs may restrict this override.

The release also includes `SHA256SUMS.txt`. With both downloads in the same directory, verify the archive with:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

### Update

Quit SwitchGPT from its menu bar panel, replace the app in Applications with the new version, and open it again. The saved account index and Keychain entries are kept outside the app bundle.

## Use

1. **Add account:** complete the browser sign-in for each account you want to save. The email is read from the sign-in credentials.
2. **Refresh:** use the refresh button to retrieve current usage and reset availability.
3. **Switch:** finish any active ChatGPT work, click another account's card, and confirm the restart. Clicking the current account does not switch it.
4. **Reorder:** drag one account card onto another to change the saved order.
5. **Remove:** click the trash icon and confirm removal from SwitchGPT's saved list. This does not delete the OpenAI account.

The usage reset section is **display-only**. SwitchGPT does not redeem or consume resets.

Language changes take effect when the app is reopened. No in-app language selector is provided.

## Build from source

Install Xcode with Swift 6 and a macOS SDK, and select its command-line tools. Then:

```sh
git clone https://github.com/yoonpooh/SwitchGPT.git
cd SwitchGPT
./script/build_and_run.sh --verify
```

This builds a local app at `dist/SwitchGPT.app`, signs it ad hoc, launches it, and checks that the process is running. It does not install the app into Applications. To install your build, quit SwitchGPT and move the generated app into Applications using Finder.

Available commands:

```sh
./script/build_and_run.sh           # Build and launch a debug app
./script/build_and_run.sh --verify  # Build, launch, and verify the process
./script/build_and_run.sh --build   # Build a debug app without launching
./script/build_and_run.sh --release # Build an optimized app without launching
swift test                         # Run the test suite
```

Keep the checkout outside iCloud Drive when possible. If a synchronized folder causes a code-signing error about Finder information or resource forks, run tests using an isolated build directory:

```sh
swift test --scratch-path /tmp/switchgpt-tests
```

### Package a release

The script builds for the host architecture. The published v0.1.2 artifact is an Apple silicon build.

```sh
./script/build_and_run.sh --release
ditto -c -k --norsrc --keepParent dist/SwitchGPT.app dist/SwitchGPT-v0.1.2-macos-arm64.zip
(cd dist && shasum -a 256 SwitchGPT-v0.1.2-macos-arm64.zip > SHA256SUMS.txt)
```

The Swift package and executable target retain the internal name `CodexAccountSwitch`; the app bundle and UI use `SwitchGPT`.

## Data and compatibility

| Data | Location |
| --- | --- |
| Saved sign-in credentials | macOS Keychain, service `local.codex-account-switch.credentials` |
| Account index and ordering | `~/Library/Application Support/CodexAccountSwitch/accounts.json` |
| Active desktop credentials | `~/.codex/auth.json` |

Before switching, the app saves the current credentials and replaces the active credential file using a temporary file with `0600` permissions. If restarting ChatGPT fails, it attempts to restore the previous credentials and reports recovery failures.

Usage information is retrieved directly from OpenAI's private `chatgpt.com/backend-api/wham/` endpoints. There is no SwitchGPT backend. These endpoints and the desktop app's local server behavior can change, and expired credentials may require signing in again. A successful local restart alone does not prove that the server accepted the new session.

Current limitations:

- API-key authentication, keyring/auto credential storage, custom `CODEX_HOME`, and remote hosts are not supported.
- There is no automatic account switching or built-in updater.
- Switching may affect CLI sessions that share the desktop app's local server. Finish active work before switching.
- Missing usage or expiration data is shown as unavailable rather than as zero.
- Building successfully does not establish compatibility with every ChatGPT desktop version or every supported macOS version.

Do not include credentials, the account index, or personal account screenshots in issues or commits.

## Source layout

```text
Assets/                         App and menu bar icons
Sources/CodexAccountSwitch/
  App/                          Menu bar app entry point
  Models/                       Accounts, usage models, localization helper
  Resources/                    English, Korean, Chinese, Japanese strings
  Services/                     Login, Keychain, usage, and desktop session handling
  Stores/                       Account state and ordering
  Views/                        Account panel and usage display
Tests/CodexAccountSwitchTests/   Credential, login, server, ordering, and localization tests
script/build_and_run.sh          Build and app packaging entry point
```

Tests use synthetic credentials and temporary files; they do not perform a live account switch or redeem usage resets. Live authentication and server compatibility need separate verification.
