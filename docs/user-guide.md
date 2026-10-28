# User guide

## First launch

Download `Vaken.dmg`, open it and drag `Vaken.app` onto the `Applications` shortcut. Eject the image and open Vaken from Applications before registering the helper. Do not launch the app directly from the read-only image. Choose **Set up helper…**; macOS may request administrator approval or direct you to Login Items & Extensions. Vaken must show **Helper connected** before starting a session.

The outline sun means system sleep is disabled. The moon means normal sleep is allowed. An attention icon means a state read or operation failed; open the dropdown for the error rather than assuming protection is active.

## Modes

| Mode | On AC | On battery |
|---|---|---|
| Manual | You start and stop sessions | Sessions may run until the battery cutoff or Low Power Mode stops them |
| Follow power source | Enables automatically unless manually paused | Restores normal sleep |
| Manual + safety net | You start and stop sessions | Restores normal sleep |

The battery cutoff defaults to 15% and is adjustable from 5% to 50%. It applies on battery in every mode. Unknown power readings are handled conservatively for AC-only sessions. A manual Off or completed timer/process session pauses Follow until a verified power transition or explicit On.

## Timers and processes

The main switch starts without a time limit. The dropdown presets start timed sessions. Selecting a new timer while already awake updates the active session without another enable prompt. **+15 min** extends a deadline; for an indefinite session it creates a 15-minute deadline. **End session** cancels all end conditions and restores normal sleep. **Remove time limit** clears a deadline and keeps the session running. If Keep awake was on when Vaken quit or the Mac restarted, Vaken turns it on again the next time it opens, keeping any remaining time limit. Turn on **Launch at login** for this to work after a restart. It asks for Touch ID or password first when that is required. Sessions that end with an app, sessions whose time ran out and Follow power source mode are not resumed. Until Vaken opens again, normal sleep applies.

**More…** accepts custom minutes, a future clock time, a running app or a PID. A process session tracks both the PID and its start identity, so PID reuse does not prolong it. An application remaining open is not proof that its background jobs are active. Select the actual build or download process when needed.

## Authentication

The default **Touch ID or password** method uses the native device-owner prompt. Available biometrics are offered first; the account password is a fallback. **Administrator password** uses the system administrator authorization flow instead. Vaken does not collect passwords.

**Require Touch ID or password** is On by default. Turning it Off authenticates once and stores the preference per user in the privileged helper. Later starts can then be silent. Turning it back On restores prompting for the next new session. Timer changes within an active session and sleep restoration remain prompt-free.

A disabled requirement switch usually means the helper is missing or older than the app. End the current session, choose **Update…** or **Set up…**, and complete system approval. If an update reports a registration error and the service is no longer registered, retry **Set up…**. Do not interpret a grey switch as a saved opt-out.

## Other preferences

- **Keep display awake** holds a temporary display assertion only during the session. It does not unlock the screen. It is Off by default.
- **Launch at login** uses macOS Login Items and may need approval there.
- **State notifications** use macOS notification permissions.
- **Keyboard shortcut** records Command or Control plus another modifier. Escape cancels recording; conflicts are reported rather than saved.

## Updates

In a release-configured build, the arrow icon in the menu and **Settings → About** offer **Check for Updates…** and **Automatically check for updates**. Sparkle owns the schedule and preference. By default it asks for automatic-check permission on the second launch and checks roughly daily once enabled.

Automatic installation is disabled. Let pending actions finish before installing. Keep awake may stay on: installing quits Vaken through the normal restore, and the relaunched app resumes the session. An offered update temporarily blocks new sessions until it is finished or dismissed. Quitting for an update still requires verified normal sleep. After relaunch, helper compatibility is checked separately; macOS may require another helper approval.

**Updates are not configured** means this local build has no production feed/key pair. It is not an indication that the installed version is current. Replacing such a build manually requires a trusted signed copy. Current pre-release builds have no published feed.

## Troubleshooting and removal

| Symptom | Action |
|---|---|
| Helper setup required | Check the app location, click Set up and approve Vaken in Login Items & Extensions |
| Helper update needed | End the session, then update; retry Set up if registration failed |
| Enable cancelled | Try again manually; Follow remains paused to avoid repeated prompts |
| Sleep restoration failed | Keep Vaken open, read the error and use the manual recovery command below if needed |
| Update network/signature error | Retry later or obtain a trusted release manually; never disable signature checks |
| Remote connection dropped | Check power, networking, thermal conditions and actual system sleep state; Vaken cannot guarantee connectivity |

To restore normal sleep manually:

```sh
sudo /usr/bin/pmset -a disablesleep 0
```

Before removing the app, end the session, verify normal sleep and quit. Disable launch at login if enabled. There is not yet an in-app helper uninstaller; macOS background-item management and SMAppService registration are separate from deleting the app. Do not delete helper policy/recovery files as a troubleshooting shortcut. Older restore-only sudoers rules are not used by the current app and are not removed automatically.
