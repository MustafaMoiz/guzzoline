# Guzzoline

Claude plan usage on the MacBook Pro's Touch Bar. In *Mad Max*, guzzoline is the fuel everyone scrambles for; here it's your tokens: how much of the five-hour session and the week you've spent, what's left, and when each fills up again. Clawd comes along, with one more for each of your Claude Code sessions, acting out what each is doing.

Five themes, each designed in three.js in a gallery that runs on simulated or live usage, and drawn natively on the Touch Bar by a small Mac app.

```
npm install
npm run dev
```

Then open http://127.0.0.1:5188. The controls at the top set the scenario, the numbers and the time to each reset. Working plays Claude working, Time-lapse plays a made-up working day, five hours in 75 seconds, and Sessions adds the crew, with made-up sessions or yours. `?solo=<theme>` shows a single bar filling the window, and `?width=2170` lays the bars out for the earlier Touch Bars, which were 2170 pixels wide rather than 2008.

## Themes

- **Walk**: Clawd, in voxels, walks the session. Behind it is spent, ahead is what's left.
- **Phosphor**: a vacuum fluorescent display. The lit segments are what's left, so it dims as you spend.
- **Engraving**: two scales, like a slide rule. What's left is cut in white lines, and a pointer marks an even pace. Set in Barlow Condensed.
- **Marquee**: an LED sign that now and then spells the numbers out. Its lamps chase while Claude works.
- **Incense**: an incense clock. The ash is what's spent, and it burns toward Clawd.

Every theme marks an even pace: how far through the window's time you are. Spending ahead of that mark means you'll run out before the reset. Every layout is worked out from the bar's width, so each fills the bar with even margins.

Plans differ. The bar shows the 5-hour session and the week, or, on a plan with no session limit, the week and the next weekly limit (one model's, say).

## Sessions

To the right of the usage stands a Clawd for each of your Claude Code sessions in the Claude app, in the order they began, coloured and moving as its session is:

- **Red**, walking: working.
- **Amber**, hopping and waving: waiting on you, for a permission in the Claude app, or for a password or permission in one of macOS's own prompts.
- **Green**: finished within the hour. It cheers for the first two minutes, or shakes its head if the turn failed.
- **Blue**, dimmed and dozing: finished longer ago.

The theme narrows to make room. A finished session's hour starts when you're next at the Mac (the next time you touch the keyboard or trackpad), so one that finishes while you're out is still green when you're back.

Touch a Clawd to read its session's title across the bar, and slide along to read the others; the one under your finger stands on a lit line. Lift to open that session in the Claude app, or slide off the row first to open nothing.

The panel lists your recent sessions, each with its Clawd: lit if it's on the bar, a dim silhouette if not. Click one to show or hide it. A new session joins by itself; one you hide stays off until you show it again. Five fit, so a sixth bumps the one you've been away from longest, which comes back when you next write to it.

When a session finishes or starts waiting on you, the Mac plays a sound, even for the session on your screen, since you may have walked away. It plays for every session you haven't hidden. The sound is your Mac's alert sound (System Settings › Sound) until you pick another of the Mac's in the panel, where each square plays its sound as you pick it and the speaker turns sound off.

## The Touch Bar app

You need a MacBook Pro with a Touch Bar on macOS 12 or later (13 for opening at login), Node, and Xcode's command line tools to build it; Claude Code signed in for your usage, and the Claude app for your sessions.

```
npm run app
npm run install-app -- --open-at-login
```

The first builds `build/Guzzoline.app`; the second copies it to `~/Applications`, starts it there and makes it open at login (it's listed in System Settings › General › Login Items). Leave out `--open-at-login` to update an installed copy.

The app shows a theme on the Touch Bar while the Claude app is in front. Clicking the menu bar icon (Clawd) opens a panel dressed in the theme you've picked: your sessions, when the bar shows (only in Claude, while Claude is open, or in every app), its sound, the themes (each as the Touch Bar itself, live, with your crew), Open at login, Stay awake with the lid shut, and Quit. Clicking in it never closes it; a click outside, Escape or the icon again does. A right click on the icon has Refresh Now and Quit. The panel was designed in the gallery first (`panel.html`). Each new build asks once more for keychain access, since the permission belongs to the build.

It reads usage from the same API Claude Code's `/usage` command reads, signed in as Claude Code: it reads Claude Code's sign-in from your login keychain, and macOS asks you to allow that the first time. If you only use the Claude desktop app, sign in to Claude Code in a terminal once (run `claude`). Claude Code renews that sign-in whenever it runs; if it lapses, the bar says so. Guzzoline never stores or logs the sign-in. It saves the usage numbers to `~/Library/Application Support/Guzzoline/usage.json`, which the gallery's Live button reads and the bar shows as it opens, and checks once a minute while it's showing, every five minutes otherwise. The API refuses checks that come too close together, so the bar keeps the last numbers until the next check.

### Awake with the lid shut

"Stay awake with the lid shut", in the panel, keeps the Mac awake while an agent is working or waiting on you, even with the lid closed, so you can close it on an agent and go. It lets the Mac sleep again two minutes after the last session finishes, and the screen sleeps as soon as the lid shuts.

macOS sleeps when the lid closes whatever apps ask, unless its `SleepDisabled` setting is on, and only root can change that. So the first time, Guzzoline installs a small helper (`mac/awake`), and macOS asks for your password once. The helper is a short script that launchd runs as root whenever Guzzoline changes its request, and once a minute. It turns `SleepDisabled` on only while Guzzoline asks, Guzzoline is running, and the Mac is plugged in or has 20% of its battery; in every other case it turns it off. A Mac working in a closed bag still gets warm.

Right-click the menu bar icon to remove the helper, or remove it by hand:

```
sudo launchctl bootout system/app.guzzoline.awake
sudo rm /Library/LaunchDaemons/app.guzzoline.awake.plist /Library/PrivilegedHelperTools/app.guzzoline.awake
sudo pmset -a disablesleep 0
```

`--demo` shows made-up numbers and sessions, `--always` shows the bar with every app for one run, `--touch 2` holds a finger on the second Clawd, and `--panel` opens the panel at launch (`--panel-png <folder>` also draws it there in each theme), for screenshots. The log is `~/Library/Logs/Guzzoline.log`.

### How it works

- A Touch Bar shown over every app's is a private macOS API, the one [Pock](https://github.com/pock/pock) uses. Apple could change it.
- Every theme is drawn natively (`mac/*Theme.swift`): Core Graphics paints the shapes and type, and Metal shaders ported line for line from the WebGL ones do the glow, the hatching, the lamps, the smoke and Walk's lit voxels. They match the web versions, apart from text antialiasing and the random detail in noise.
- The web themes in `src/` are where designs get worked out, since the gallery reloads as you edit. `--web` shows them on the Touch Bar instead, for comparing. WebKit draws in a separate process, which the Touch Bar can't show, so the page runs in an invisible, click-through window and the app copies each frame onto the Touch Bar.
- Themes draw 60 frames a second while something moves (Clawd walking, smoke, a crawling sentence, Claude working) and 6 while the bar is still, since those frames would be the same. On an M1, natively, a still bar costs about 1.5% of one core and a moving one 7–9%; Incense's smoke never stops, so it's always moving. As web pages they cost 15–33%, even at 24 frames a second.
- Tapping Marquee on the Touch Bar spells its sentence out.
- Sessions come from the files the Claude app keeps for them in `~/Library/Application Support/Claude/claude-code-sessions`, read every second and a half while the Claude app is open: their titles, whether each is working, waiting on you or finished, how its last turn ended, and when you last switched to it. Guzzoline keeps which sessions you've shown or hidden, and when each finished turn's green hour began, in its preferences. That's the app's own format, not a published one, so an update to the app could break it. Opening one uses the app's `claude://code/continue?session=` link.
- macOS doesn't say which app one of its prompts is for, so while one is on screen, every session that's working turns amber. Guzzoline tells them apart by the system agent that owns the window (SecurityAgent for passwords, and the agents for permissions, Accessibility, Touch ID and downloaded apps), reading only the owner's name, never a window's title.
- The crew keeps its own pace: 60 frames a second while a Clawd moves, 6 while they all doze. With one walking beside a still theme, the app uses about 6.5% of one core.

Guzzoline is not made by or affiliated with Anthropic. Clawd is Anthropic's.

MIT licensed; see [LICENSE](LICENSE).
