# Barometer

Claude plan usage on the MacBook Pro's Touch Bar: the five-hour session and the week, how much of each is spent and left, and when each resets. Clawd comes along.

This is the prototype stage: five themes drawn with three.js at the Touch Bar's real size (2008 × 60 pixels), driven by simulated usage.

```
npm install
npm run dev
```

Then open http://127.0.0.1:5188. The controls at the top set the scenario, the numbers and the time to each reset. Working plays Claude working, and Time-lapse plays a made-up working day, five hours in 75 seconds. `?solo=<theme>` shows a single bar filling the window.

## Themes

- **Walk**: Clawd, in voxels, walks the session. Behind it is spent, ahead is what's left.
- **Phosphor**: a vacuum fluorescent display. The lit segments are what's left, so it dims as you spend.
- **Engraving**: two scales, like a slide rule. What's left is cut in white lines, and a pointer marks an even pace.
- **Marquee**: an LED sign that now and then spells the numbers out. Its lamps chase while Claude works.
- **Incense**: an incense clock. The ash is what's spent, and it burns toward Clawd.

Every theme marks an even pace: how far through the window's time you are. Spending ahead of that mark means you'll run out before the reset.

Plans differ. The bar shows the 5-hour session and the week, or, on a plan with no session limit, the week and the next weekly limit (one model's, say).

## The Touch Bar app

```
npm run app
npm run install-app -- --open-at-login
```

The first builds `build/Barometer.app`; the second copies it to `~/Applications`, starts it there and makes it open at login (it's listed in System Settings › General › Login Items). Leave out `--open-at-login` to update an installed copy.

The app shows a theme on the Touch Bar while the Claude app is in front. The menu bar icon (Clawd) picks the theme, shows it with every app, turns Open at Login on and off, and quits. Each new build asks once more for keychain access, since the permission belongs to the build.

It reads usage from the same API Claude Code's `/usage` command reads, signed in as Claude Code: it reads Claude Code's sign-in from your login keychain, and macOS asks you to allow that the first time. If you only use the Claude desktop app, sign in to Claude Code in a terminal once (run `claude`). Claude Code renews that sign-in whenever it runs; if it lapses, the bar says so. Barometer never stores or logs the sign-in. It saves the usage numbers to `~/Library/Application Support/Barometer/usage.json`, which the gallery's Live button reads, and checks once a minute while it's showing, every five minutes otherwise.

`--demo` shows made-up numbers, and `--always` shows the bar with every app for one run. The log is `~/Library/Logs/Barometer.log`.

### How it works

- A Touch Bar shown over every app's is a private macOS API, the one [Pock](https://github.com/pock/pock) uses. Apple could change it.
- WebKit draws in a separate process, which the Touch Bar can't show. So the theme runs in an invisible, click-through window, and the app copies each frame it draws onto the Touch Bar: 24 a second while something moves, 6 otherwise. On an M1 that costs about a sixth of one core; drawing natively would cost less.

Barometer is not made by or affiliated with Anthropic. Clawd is Anthropic's.
