**English** · [Español](README.es.md)

# TokScribe

A macOS app that transcribes TikTok videos — and any video or audio file on your
disk. All speech recognition runs **on your Mac**, using the `SpeechAnalyzer`
engine introduced in macOS 26. Nothing is uploaded to any server, and there are
no multi-gigabyte Whisper-style models to download.

The app's interface is in Spanish; menu and button names below are given in
English with the Spanish label in parentheses where it helps.

## How it works

1. Paste **one or more** TikTok links into the left column, one per line, and
   click **Transcribe** (*Transcribir*). You can also drag several videos or audio files onto
   the window, or add them with ⌘O.
2. Each item joins a **queue** and is processed in turn: `yt-dlp` downloads the
   file, AVFoundation extracts the audio as 16 kHz mono, and the system speech
   engine transcribes it with per-sentence timestamps.
3. Each item shows its own progress in the list; click any of them to see its
   transcript on the right.
4. Export a single transcript, or **all of them at once** to a folder (one file
   per video), as `.txt`, `.srt` subtitles or `.vtt` web subtitles.

You can keep adding links while the queue is running, skip an item that gets
stuck, retry failed ones and clear finished ones. The divider between the two
columns can be dragged if you want more room for the text.

**Transcripts survive quitting the app.** Each one is saved to
`~/Library/Application Support/TokScribe/library.json` as soon as its video
finishes, and they reappear in the queue the next time you open the app. Saving
happens *after every video*, not at the end of the batch, so a crash halfway
through a long queue doesn't lose the work already done. The latest 300 are
kept, and you can clear the history from **File → Delete saved history**
(*Archivo → Borrar historial guardado*).

Only the **text** is stored: the video and the intermediate audio are deleted as
soon as each job finishes.

## Requirements

- macOS 26 or later (the transcription engine is new in that release).
- To build: **Xcode** on macOS 27 or later (the Command Line Tools no longer
  ship the SwiftUI macro plugin); on macOS 26 the Command Line Tools are enough.
  `build.sh` picks up Xcode automatically when it's installed.
- `yt-dlp`, only for downloading from a URL. It can be **bundled inside the app**
  (see below) or installed system-wide with `brew install yt-dlp`.

**ffmpeg is not needed.** Audio conversion is native, through AVFoundation. If
ffmpeg happens to be installed, the app uses it as a fallback for unusual
formats macOS can't open on its own, such as `.webm`.

## Building

```bash
./build.sh
```

This produces `build/TokScribe.app`. To install it:

```bash
cp -R build/TokScribe.app /Applications/
```

The script refuses to report success if the bundle is missing its executable or
`Info.plist`, so a failed compile can't be mistaken for a working build.

## Bundling yt-dlp inside the app

To ship the app to someone without Homebrew:

```bash
./bundle-deps.sh && ./build.sh
```

`bundle-deps.sh` downloads the official standalone yt-dlp binary into
`Resources/bin/`, and `build.sh` copies it into
`TokScribe.app/Contents/Resources/bin/`. The app always prefers that copy and
only falls back to a system install when it's missing, so the resulting app
works on a fresh Mac.

The binary itself is not committed to this repository; run `bundle-deps.sh`
after cloning. Re-run it every so often, too: TikTok changes its internals
frequently and yt-dlp is updated to keep up. An outdated copy shows up as errors
like *"Unexpected response from webpage request"*.

## Licensing, if you plan to sell it

- **yt-dlp** is released under the Unlicense (public domain) and can be
  redistributed without conditions.
- **ffmpeg** is deliberately not bundled. The Homebrew build is compiled with
  `--enable-gpl`, and shipping it inside a closed-source app would violate the
  GPL. That's why audio conversion is done with AVFoundation.
- The speech engine is part of macOS and adds no obligations.

The Mac App Store is not an option: it requires sandboxing, and a sandboxed app
can't launch external binaries such as yt-dlp. The realistic route is direct
distribution, with the app notarized through an Apple Developer account.

The app is signed locally (ad-hoc). The first time it's opened, if macOS
complains about an unidentified developer, right-click it and choose **Open**.

## Languages

The language menu lists the languages supported by the system engine. The first
transcription in a new language downloads its model (a few seconds), which then
stays installed.

**Automatic** (*Automático*, the default): before transcribing each video, the app takes a
short sample of the audio and tries it against the languages **you already have
installed**, keeping whichever fits best. It combines two signals: the
confidence reported by each speech model, and whether the resulting text is
coherent according to the NaturalLanguage framework. This lets you mix Spanish
and English videos in the same queue and have each come out in its own language.

Detection only chooses among installed languages, so it never triggers
multi-gigabyte downloads without warning. With only one language installed
there's nothing to choose between: install another by transcribing once with it
picked manually, and automatic mode will consider it from then on. If you know
the language in advance, pick it explicitly and skip the probing.

## Why H.264 is requested instead of "best quality"

TikTok offers each video in several formats. The ones encoded in **H.265
(`bytevc1`)** arrive **without an audio track**, even though yt-dlp reports
`acodec=aac` for them. Because they're usually the highest resolution, a normal
format selector picks them and the file arrives silent: the app used to fail
with "no audio track" on videos that clearly had sound.

That's why `formatSelectors` in `MediaFetcher.swift` asks for **H.264 first**.
If the file still arrives without audio, the app automatically retries with a
different format before giving up. The user only sees an error when no format
carries sound at all — the genuine case of a photo slideshow or a silent video.

To diagnose a specific video:

```bash
yt-dlp -F "<url>"
```

If every row in the `ACODEC` column says `aac` but the downloaded file has no
audio, it's this same issue. Check with:

```bash
ffprobe -v error -show_entries stream=codec_type,codec_name -of csv=p=0 file.mp4
```

## Cookies

TikTok sometimes blocks anonymous downloads (*"Your IP address is blocked from
accessing this post"*). When that happens, pick your browser in the **Cookies**
menu and yt-dlp will reuse your signed-in TikTok session. It's off by default:
with Chromium-based browsers macOS asks for your login password to unlock the
cookie store, and with Safari it requires Full Disk Access.

## Diagnostics

`build/tokscribe-cli` transcribes a file straight from the terminal. It helps
tell whether a problem comes from the download or from speech recognition:

```bash
./build/tokscribe-cli /path/to/audio.wav es-MX
```

## Project layout

| File | Purpose |
| --- | --- |
| `Sources/TokScribeApp.swift` | Entry point and menus |
| `Sources/ContentView.swift` | Two-column UI: queue and transcript |
| `Sources/AppModel.swift` | The queue, its serial processing, and export |
| `Sources/TranscriptionJob.swift` | A single queue item, with its state and result |
| `Sources/MediaFetcher.swift` | Runs yt-dlp, reports progress, translates errors |
| `Sources/AudioExtractor.swift` | Extracts 16 kHz WAV audio with AVFoundation |
| `Sources/Transcriber.swift` | On-device speech engine, segmentation, output formats |
| `Sources/LanguageDetector.swift` | Guesses the language by probing models + NaturalLanguage |
| `Sources/LibraryStore.swift` | Saves and reloads finished transcripts |
| `Tools/MakeIcon.swift` | Draws the app icon |
| `Tools/TranscribeCLI.swift` | Diagnostics: transcribes a single file |
| `Tools/BatchTest.swift` | Diagnostics: exercises the queue with several files |
| `Tools/DetectTest.swift` | Diagnostics: reports the detected language per file |
| `Tools/KeepTest.swift` | Diagnostics: checks the "keep downloaded video" copy logic |
| `Tools/PersistTest.swift` | Diagnostics: simulates quitting and reopening the app |

The files in `Tools/` are not part of the app; they're compiled separately when
needed. For example, to check persistence:

```bash
xcrun swiftc -parse-as-library -swift-version 5 \
  -target arm64-apple-macos26.0 -sdk "$(xcrun --show-sdk-path)" \
  Sources/AppModel.swift Sources/TranscriptionJob.swift Sources/Transcriber.swift \
  Sources/AudioExtractor.swift Sources/LanguageDetector.swift \
  Sources/MediaFetcher.swift Sources/LibraryStore.swift Tools/PersistTest.swift \
  -o build/persist-test && codesign --force --sign - build/persist-test
```

`PersistTest` backs up your real library before running and restores it
afterwards, so it never loses your work.

Only download videos you have the right to use; TikTok content belongs to its
creators.
