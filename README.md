# Eufy Doorbell for Omarchy

Someone presses your eufy video doorbell, and a big ringing bell takes over your screen: a chime, the doorbell's snapshot, and a few seconds later the live camera view. Nobody at the screen? After a minute it closes itself and leaves a "Missed the doorbell" notification with the picture.

The bar gets a bell that shows whether the doorbell is being listened to. Click it to set up; middle-click it to ring the bell as a test.

## You need a second eufy account

eufy allows one active login per account. If this plugin logged in with your own account, the eufy app on your phone and Omarchy would keep logging each other out. Give Omarchy an account of its own and share the doorbell with it:

1. **Create a second eufy account** with another email address, in the eufy app or on the eufy website. An alias of your own address (for example `you+doorbell@example.com`, if your mail provider supports it) is enough.
2. **Share the doorbell with it.** In the eufy app on your phone, logged in as yourself, open *Family & Guests* (in some app versions *Sharing*), invite the new address, select the doorbell and the HomeBase it is paired with, and allow live view.
3. **Accept the invitation.** Log in to the eufy app as the new account once, on a tablet or a second phone or briefly on your own phone, and accept. While you are there, check that doorbell notifications are on for this account: the plugin receives the same push notifications the app would. Log back in as yourself afterwards.
4. **Log in in Omarchy.** Click the bell in the bar, fill in the second account's email, password and country (the two-letter country the account was made in, such as `NL`), and enter the verification code eufy emails you.

The panel shows the same steps.

## Install

Needs Omarchy 4.5 or newer, Node.js 24.5 or newer on your `PATH` (for example `mise use -g node@lts`), and ffmpeg (Omarchy ships it).

```bash
omarchy plugin add <git-url-of-this-repo> --enable
```

Or, from a local checkout:

```bash
ln -s ~/Projects/omarchy-plugins/eufy-doorbell ~/.config/omarchy/plugins/eufy-doorbell
omarchy plugin enable eufy-doorbell --section right
```

Then click the bell and choose **Install eufy-sdk**. That runs `scripts/install-backend.sh`, which installs [eufy-sdk](https://github.com/mega-yfue/eufy-sdk), pinned by `backend/package-lock.json`, into `~/.local/share/omarchy-eufy-doorbell`.

Ring the bell without a doorbell press:

```bash
omarchy-shell eufy-doorbell ring
```

## How it works

```
eufy cloud ──push──▶ backend/doorbell.mjs ──JSON line──▶ Service.qml ──▶ Ring.qml (overlay) + chime
                     (eufy-sdk, Node.js)                                   ▲
                     snapshot, live H.264 ──ffmpeg remux──▶ MPEG-TS on 127.0.0.1 ┘
```

- **Fast first.** The backend writes the `ring` line before it does any network work, and the overlay is mounted at shell start (`keepLoaded`), so the bell appears as soon as eufy's push arrives. The snapshot follows in milliseconds and the live view, depending on the doorbell, within a few seconds.
- **Live view** is the doorbell's own H.264/H.265 stream, remuxed (not transcoded) by ffmpeg and played by the shell from `127.0.0.1` behind a random token. It stops when you close the bell, and after 90 seconds at most, because battery doorbells pay for every second of video.
- **Stays connected.** The backend restarts itself with a growing delay when eufy or the network has a hiccup. When eufy needs you (a new verification code, a password), the bell in the bar shows a crossed-out bell and you get a notification.

## What is stored where

| What | Where |
|---|---|
| Password of the second account | Your desktop keyring (`secret-tool`, service `omarchy-eufy-doorbell`) |
| Email, country, eufy session token, push registration | `~/.local/share/omarchy-eufy-doorbell/` (mode 700) |
| The eufy-sdk runtime | `~/.local/share/omarchy-eufy-doorbell/node_modules` |
| Doorbell snapshots, the latest few | `$XDG_RUNTIME_DIR/omarchy-eufy-doorbell/` (gone at logout) |

## Good to know

- **Unofficial.** eufy has no public API. eufy-sdk speaks the protocol of the current eufy app, and eufy can change that without notice. Its predecessor, eufy-security-client, was retired in 2026 when eufy started shutting down the APIs it used.
- **Your computer has to be on.** The bell rings on this machine only while you are logged in.
- **Logs** go to the shell's journal: `journalctl --user -f _COMM=quickshell | grep eufy-doorbell`.

## Remove

```bash
omarchy plugin remove eufy-doorbell
secret-tool clear service omarchy-eufy-doorbell account <email-of-the-second-account>
rm -rf ~/.local/share/omarchy-eufy-doorbell
```

Or click **Log out** in the panel first, which forgets the password and the session.
