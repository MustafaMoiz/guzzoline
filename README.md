# Guzzoline

Guzzoline puts your Claude usage on the Touch Bar of a MacBook Pro.

If you use Claude a lot, you've probably wondered how much of your plan is left, and when it resets. Guzzoline answers that without your having to ask. The Touch Bar shows how much of each limit you've used, when it fills up again, and where you'd be if you spent evenly. If you're ahead of that mark, you'll run out before the reset.

It shows your Claude Code sessions too. Each session in the Claude app gets a Clawd, Claude's little mascot, on the right of the Touch Bar. Its color tells you what the session is doing:

- **Red, walking**: working.
- **Amber, waving**: waiting for you, to allow something or to answer a question.
- **Green**: finished in the last hour.
- **Blue, dozing**: finished longer ago.

When a session finishes or needs you, your Mac plays a sound. So you can walk away while Claude works, and come back when it's your turn.

And you can talk to a session. Hold its Clawd, say what you want, and let go. Guzzoline opens that session in the Claude app, types what you said, and sends it.

The name comes from *Mad Max*, where guzzoline is the fuel everyone fights over. Here the fuel is your tokens.

## What you need

- A MacBook Pro with a Touch Bar, on macOS 12 or later.
- The Claude app, for your sessions.
- Claude Code, signed in, for your usage. If you only use the Claude app, [install Claude Code](https://claude.com/claude-code) and run `claude` once in Terminal to sign in.

## Install

Open Terminal and run:

```
git clone https://github.com/MustafaMoiz/guzzoline.git
cd guzzoline
./install.sh
```

That builds Guzzoline on your Mac, puts it in your Applications folder, and starts it. From macOS 13 on, it also starts by itself when you log in.

If macOS offers to install the command line developer tools, say yes, and run `./install.sh` again once they're in. They're free, from Apple, and they're what builds Guzzoline.

The first time, the installer also makes a signing certificate that's only for your Mac, so that when you update Guzzoline, macOS remembers the permissions you gave it. macOS asks for your password once to let the installer use that certificate. Choose Always Allow.

To update, run `git pull && ./install.sh`. To remove Guzzoline and everything it made, run `./uninstall.sh`.

## Why you build it yourself

macOS blocks apps downloaded from the internet unless their developer pays Apple to sign them. Apps you build on your own Mac aren't blocked. So Guzzoline comes as source, and building it takes about a minute. It also means you can read everything you're about to run.

## Using it

- **Touch a Clawd** to see its session's title, and slide along to see the others. Lift your finger to open that session in Claude.
- **Hold a Clawd** for half a second to talk to it. Claude comes to the front on that session, and the Touch Bar shows your voice as a waveform, with your words as they're heard. Let go to send. To cancel, slide your finger off the Clawds before you let go.
- **Click Clawd in the menu bar** for the panel. There you choose which sessions get a Clawd (up to five), when the Touch Bar shows (only in Claude, while Claude is open, or in every app), the sound, and the theme.
- **Stay awake with the lid shut**, in the panel, keeps your Mac awake while a session is working or waiting for you, even with the lid closed, so you can close it and go. It works only while the Mac is plugged in or has a fifth of its battery left, and lets it sleep again two minutes after the last session finishes. Turning it on asks for your password once, to install a small helper.

There are five themes. Walk: Clawd walks along the bar. Phosphor: a fluorescent display. Engraving: two scales, like a slide rule. Marquee: an LED sign. Incense: an incense clock, burning down.

## What it sees, and what it does with it

- **Your usage.** Guzzoline runs Claude Code's own `/usage` command and reads the numbers it prints, so it never sees your sign-in. (Only if the `claude` command isn't installed, or stops answering for several reads in a row, does it read Claude Code's sign-in from your keychain, with your permission, to ask Anthropic itself.) When Claude Code is signed out, the bar's Sign in button starts Claude Code's own sign-in, in your browser.
- **Your sessions.** It reads the list the Claude app keeps on your Mac: each session's title, and whether it's working. Not your conversations.
- **The microphone**, only while you hold a Clawd. macOS turns your speech into text on your Mac. (Before macOS 26, that's Dictation, which has to be on and may send the audio to Apple.)
- **Accessibility**, to type into Claude's message box and press Return. Guzzoline types only when it can see the cursor is in Claude's message box, and presses Return only when the box holds exactly what you said, so it never sends a draft of yours.

Apart from that fallback, Guzzoline itself sends nothing anywhere; the usage request is Claude Code's own. Its log, `~/Library/Logs/Guzzoline.log`, never contains what you said.

## If something's off

- **The Touch Bar dims while you talk.** macOS dims the Touch Bar when your keyboard's backlight goes off, and at its shortest setting that's five seconds after your last key or click. In System Settings › Keyboard, set the backlight to turn off after a minute or more. If it does dim, Guzzoline keeps listening, and sends when you pause.
- **It says it needs Accessibility, but Guzzoline is already on in the list.** That entry is from an older build. In System Settings › Privacy & Security › Accessibility, select Guzzoline, remove it with –, and send again; macOS will ask, and you switch it on.
- **It says Claude Code is signed out.** Tap Sign in. Claude Code's sign-in page opens in your browser, and once you've approved it there, your numbers come back. A Claude Code sign-in only lasts so long, so this comes up now and then.

## For developers

Each theme was designed in three.js, in a gallery that runs on made-up or live usage. The app draws them natively.

```
npm install
npm run dev
```

Then open http://127.0.0.1:5188. The controls at the top set the scenario, the numbers and the time to each reset; Working plays Claude working, Time-lapse plays a made-up working day, and Sessions adds the crew. `panel.html` is the panel. `?solo=<theme>` shows one bar, and `?width=2170` lays the bars out for the earliest Touch Bars.

The app needs no Node: `sh mac/build.sh` builds `build/Guzzoline.app` for this Mac's chip (`--universal` for both), and `sh mac/install.sh` installs a build. Flags for screenshots: `--demo` (made-up numbers and sessions), `--note <text>` (the bar before it has numbers), `--always`, `--touch <n>` and `--ring <0-1>` (a finger on the nth Clawd), `--listening <n>`, `--cancelling` and `--sent <n>` (talking, in a made-up voice), `--panel` and `--panel-png <folder>`, and `--sign-in <needed|waiting|reading>` (signing in from the bar).

How it works:

- The Touch Bar over every app's is a private macOS API, the one [Pock](https://github.com/pock/pock) uses. Apple could change it.
- Themes are drawn with Core Graphics and Metal shaders ported from the WebGL ones (`mac/*Theme.swift`), at 60 frames a second while something moves and 6 while it's still. On an M1 a still bar costs about 1.5% of one core.
- Usage comes from Claude Code's `/usage` report, read into the API's shape (`mac/UsageReport.swift`), every five minutes while the bar shows, and never while it's hidden. A read the command doesn't answer (the Mac asleep or offline) keeps the last numbers, and the next read tries it again. Signed out, `/usage` still answers, with a $0 cost summary in place of the limits, so a reply without numbers is checked against `claude auth status`. If that says signed out, the bar says so, with a Sign in button, instead of showing old numbers or the crew. The button runs `claude auth login`, which opens the sign-in page in your browser and hears back from it on your Mac, and the bar shows no numbers until the first read after that. Without the `claude` command, or after three reads in a row it didn't answer, Guzzoline reads Claude Code's sign-in from the keychain and asks the API directly; then macOS asks you to allow each new build, since the keychain knows an app by its build unless Apple signed it.
- Sessions come from the files the Claude app keeps in `~/Library/Application Support/Claude/claude-code-sessions`. That's the app's own format, not a published one, so an update to the app could break it. Opening one uses the app's `claude://code/continue?session=` link.
- macOS doesn't say which app one of its own prompts is for, so while one is on screen, every working session turns amber. Guzzoline reads only the name of the system agent that owns the window, never its title.
- Talking (`mac/Voice.swift`) uses macOS's SpeechAnalyzer from macOS 26, and SFSpeechRecognizer before it. The words are typed as keystrokes that carry the text itself, so the keyboard layout doesn't matter and the clipboard is left alone. The Claude app has no link that carries a message, so typing is the only way in.
- The lid-shut helper is a short script, written out of `mac/Awake.swift` when you turn the feature on, that launchd runs as root when Guzzoline changes its request, and once a minute. The request lives in `/Library/Application Support/Guzzoline`, which only root can change, so no other account on the Mac can tamper with it. macOS sleeps when the lid closes unless its `SleepDisabled` setting is on, which only root can change; the helper turns it on only while Guzzoline asks and is running, and the Mac is plugged in or has 20% of its battery, and off in every other case. `./uninstall.sh` removes it, or right-click the menu bar icon.

Guzzoline is not made by or affiliated with Anthropic. Clawd is Anthropic's.

MIT licensed; see [LICENSE](LICENSE).
