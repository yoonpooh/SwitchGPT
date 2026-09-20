<p align="center">
  <img src="Assets/SwitchGPT.png" width="128" alt="SwitchGPT icon">
</p>

# SwitchGPT

**English** · [한국어](README.ko.md) · [日本語](README.ja.md) · [简体中文](README.zh-CN.md)

**Keep your plugins and Remote connection. Switch only the account running your models.**

SwitchGPT is a macOS menu bar app that keeps your ChatGPT desktop account signed in while choosing which account handles Codex model requests. Your connected plugins, including GitHub, and Remote access to this Mac keep using their existing sign-in while you use the remaining quota of your saved accounts.

Choose an account yourself, or let SwitchGPT move to another available account when a usage limit is reached.

[Download v0.2.4](https://github.com/yoonpooh/SwitchGPT/releases/tag/v0.2.4) · [Latest release](https://github.com/yoonpooh/SwitchGPT/releases/latest)

## What's new in 0.2.4

- **Automatic token refresh:** saved accounts refresh shortly before access-token expiry or once after a usage-query 401. Rotated tokens are saved before retrying.
- **Desktop sign-in stays in sync:** copy the desktop app's latest credentials without independently refreshing its shared token.
- **Compact panel:** smaller account rows, usage bars, plan badges, and reset-credit controls.

## Core features introduced in 0.2.0

- **Keep desktop sign-in:** choosing a model account preserves the desktop credentials used for existing plugin connections and Remote access.
- **Switch without restarting:** after initial setup, account changes apply to new model requests. A successful response already in progress finishes with its original account.
- **Switch automatically at the limit:** when either the 5-hour or weekly quota is exhausted, select an available account in your saved list order.
- **See selection and actual usage separately:** the panel shows the next request account, the account that last completed a response, and your desktop sign-in.

Account cards also show remaining usage, reset times, plan badges, available profile photos, and reset credits. Rename accounts, drag to reorder them, and manage them from one compact panel. Credentials are stored in macOS Keychain. The interface supports English, Korean, Japanese, and Simplified Chinese.

## How the accounts work

| Connection | Account used |
| --- | --- |
| ChatGPT desktop sign-in | Your existing desktop account |
| Connected plugins, such as GitHub | The service account already connected to the app |
| Remote access to this Mac | Your existing desktop sign-in and Remote setup |
| Codex model requests on this Mac | The account selected in SwitchGPT |

For example, keep desktop account A signed in with its existing GitHub connection and Remote setup, and run model requests with saved account B. If B reaches its limit, automatic switching can select C without changing desktop sign-in or reconnecting plugins.

This applies to Codex requests using the built-in `openai` provider on this Mac, including Remote requests executed on this Mac. It does not change ordinary Chat conversations, separate providers, or model requests executed on other computers or in the cloud.

## Install and connect

Requirements: **Apple silicon, macOS 14 or later**, and the current ChatGPT desktop app installed and signed in, using the default file-based credential store at `~/.codex/auth.json`. SwitchGPT uses the app's bundled CLI; no separate CLI installation is required.

1. Download `SwitchGPT-v0.2.4-macos-arm64.zip` and `SHA256SUMS.txt` from the [release page](https://github.com/yoonpooh/SwitchGPT/releases/tag/v0.2.4).
2. Verify the checksum below, extract the ZIP, and move **SwitchGPT.app** into **Applications**.
3. Open SwitchGPT and click its menu bar icon. Choose **+** to add an account through browser sign-in. Repeat for each account you want to save.
4. For initial account selection, turn automatic switching off in `⋯`, then click an account card. Enable automatic switching again to follow list order. If prompted, finish active work before restarting ChatGPT.
5. Send a Codex request in the desktop app and confirm that the response completes.

With the ZIP and checksum file in the same directory:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

SwitchGPT has no regular window or Dock icon. Keep it running in the menu bar while using model routing.

### First launch and updates

The release is **signed ad hoc and is not notarized by Apple**. If macOS blocks it, verify the download, try opening the app, then use **System Settings → Privacy & Security → Open Anyway** if offered. Follow [Apple's instructions](https://support.apple.com/en-ca/guide/mac-help/mh40616/mac). Managed Macs may restrict this option.

To update, finish active model responses, quit SwitchGPT from `⋯`, replace the app in Applications, and open it again. Saved accounts and Keychain entries are kept outside the app bundle. When upgrading from 0.1.x, follow the initial connection steps if prompted.

### Ask ChatGPT to install it

Paste this into a ChatGPT session with local file and terminal tools:

```text
Install the latest SwitchGPT release from https://github.com/yoonpooh/SwitchGPT on this Mac. Check that the release supports my Mac, download the app ZIP and its published SHA256SUMS.txt, and verify the checksum before installing. Preserve all saved accounts and Keychain entries. If SwitchGPT is running, wait for active model responses to finish before quitting it, replacing the app in /Applications, and opening it again. Do not sign in, switch accounts, or restart ChatGPT for me. If macOS blocks first launch, guide me through Apple's per-app Open Anyway steps without disabling system security settings.
```

If local tools are unavailable, use the manual steps above.

## Use the panel

- **Selected account:** highlighted in the list. Click to change it in manual mode.
- **Desktop sign-in:** your desktop account, shown separately in the footer.
- **Automatic switching:** enabled by default in `⋯`; the header shows Auto or Manual.
- **Refresh:** retrieve usage and reset availability. Usage also refreshes 60 seconds after each refresh completes, even with the panel closed; login, switching, and overlapping refreshes are skipped.
- **Manage accounts:** drag cards to set their order; use `⋯` or right-click to rename or remove a saved account. An empty display name restores its email. Removing it from the list does not delete the OpenAI account itself.

Select **Reset** on an account card and confirm the account and consumption of one credit. The button is disabled when a reset cannot currently be used or usage data is stale. Afterward, usage and credit counts are fetched again, and automatic mode reapplies account priority. If a response or follow-up refresh fails, **Check result** continues the same request. Pending request IDs survive app restarts, and credits are never consumed automatically.

Dates follow the Mac's time zone and interface language. Reopen the app after changing the Mac's preferred language. Unsupported languages fall back to English; Chinese language variants use Simplified Chinese.

## Automatic switching

1. In automatic mode, prefer the first account in list order with recently confirmed available quota. If account 1 recovers while account 3 is in use, use account 1 from the next model request after a quota check confirms recovery. A scheduled reset time passing is not enough to return to an account.
2. If the server rejects a model request with `usage_limit_reached`, retry on an available account before forwarding a response, at most once per account for that request.
3. Successful responses already streaming finish with their original account and are not replayed.
4. Temporary rate limits and authentication errors are returned without switching. Failed or stale usage checks make an account ineligible as an automatic alternative.
5. If the selected account is exhausted and no available alternative can be confirmed, stop the request. Wait for quota to reset or select/add an available account. Reset credits are never consumed automatically.

Turn automatic switching off in `⋯` to keep using the selected account and receive its limit errors directly. In automatic mode, card order takes precedence over manual selection, and reordering applies to the next request. Quotas remain separate for each account.

## Troubleshooting

- **Requests fail after quitting SwitchGPT:** reopen it, or remove routing as described below.
- **Initial connection stays pending:** use the restart button if shown, then complete a real desktop Codex request. Usage refreshes and CLI requests do not verify the desktop connection.
- **An account needs to sign in again:** add it again through the browser. Saved accounts refresh automatically. Sign in again if the refresh token has expired or been revoked.
- **Usage is unavailable:** missing information is shown as unknown, not zero remaining.
- **An existing custom endpoint is configured:** SwitchGPT reports a conflict instead of overwriting another relay's setting.

## Data and compatibility

Credentials are stored in macOS Keychain. Account selection keeps `~/.codex/auth.json` unchanged, and reads the selected model account's credentials into memory. SwitchGPT sends model requests directly to OpenAI through a relay at `127.0.0.1:19565`; there is no external SwitchGPT server.

| Local data | Location |
| --- | --- |
| Account list and order | `~/Library/Application Support/SwitchGPT/accounts.json` |
| Selected model account | `~/Library/Application Support/SwitchGPT/routing-selection.json` |
| Automatic switching and connection status | `~/Library/Application Support/SwitchGPT/routing-preferences.json` |
| Pending reset request IDs | `~/Library/Application Support/SwitchGPT/reset-credit-attempts.json` (with a `.lock` file for concurrent saves) |
| Request metadata | `~/Library/Application Support/SwitchGPT/relay-events.jsonl` |
| Existing desktop credentials | `~/.codex/auth.json` — preserved |

A managed block in `~/.codex/config.toml` sets `openai_base_url`. HTTP streaming lets subsequent requests use the selected account. Local logs contain an opaque account fingerprint, path, model, HTTP status, completion state, token counts, client type, timestamps, and quota-exhaustion status. Prompts, response content, and authentication tokens are not logged.

To disconnect, finish active work, remove only the `BEGIN/END SwitchGPT model routing` block from `~/.codex/config.toml`, and restart ChatGPT. Preserve other settings. You can then quit or remove SwitchGPT; deleting the app bundle alone leaves the routing setting in place.

Usage is retrieved from OpenAI's private `chatgpt.com/backend-api/wham/` endpoints. These endpoints and desktop behavior may change. Legacy account lists are copied into the current location if no current list exists; original files and Keychain entries are preserved.

Current limitations:

- The release includes an Apple silicon build only; Intel is not verified.
- API-key authentication, keyring/auto credential storage, a custom `CODEX_HOME`, and configuring other Remote hosts are not supported. Remote access into this Mac keeps using its existing setup.
- Routing also applies to CLI sessions using this Mac's built-in `openai` provider and configuration.
- There is no built-in app updater. The active desktop session relies on Codex for token refresh; SwitchGPT synchronizes its latest credentials.
- Successful builds do not establish compatibility with every desktop or macOS version. Live plugin and Remote behavior require separate verification.

Do not include credentials, account lists, or screenshots exposing personal accounts in issues or commits. SwitchGPT is an independent utility and is not affiliated with or endorsed by OpenAI.

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

The script builds for the host architecture. The published v0.2.4 artifact is an Apple silicon build.

```sh
./script/build_and_run.sh --release
ditto -c -k --norsrc --keepParent dist/SwitchGPT.app dist/SwitchGPT-v0.2.4-macos-arm64.zip
(cd dist && shasum -a 256 SwitchGPT-v0.2.4-macos-arm64.zip > SHA256SUMS.txt)
```

## Source layout

```text
Assets/                         App and menu bar icons
Sources/SwitchGPT/
  App/                          Menu bar app entry point
  Models/                       Accounts, usage models, localization helper
  Resources/                    English, Korean, Chinese, Japanese strings
  Services/                     Login, Keychain, usage, and desktop session handling
  Stores/                       Account state and ordering
  Views/                        Account panel and usage display
Tests/SwitchGPTTests/            Credential, login, server, ordering, and localization tests
script/build_and_run.sh          Build and app packaging entry point
```

Tests use synthetic credentials and temporary files; they do not perform a live account switch or redeem usage resets. Live authentication and server compatibility need separate verification.
