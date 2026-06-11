# Mango

A toy project of playing with swift, specifically writing a simple emulator to
play the Spy vs Spy NES game. I do want to attempt to statically recompile
parts of the game as I go on, but at the moment we have a playable game.

I did originally write this in Golang, but because of WWDC 2026 this week and
the cool things they are releasing, I wanted to attempt to learn Swift and play
with what it could do. I think trying new languages every so often is generally
a good idea as it helps keep the brain stretchy.

This project plays with using a SwiftUI shell and a Metal renderer for video
output. Because of the metal renderer, I believe that forces this to only run
on macOS.

## Structure

The project is currently split into two Swift targets:

- **NESCore:** the emulation library
- **Mango:** the macOS app that drives NESCore

This will be extended with additional tooling and probably a recompilation
library, though I haven't thought about how I would do it as of yet.

## Requirements

You'll want a Mac and a Swift toolchain. The short list:

- macOS 26 (Tahoe) or newer
- Swift 6.3 toolchain
- just

I don't have enough storage on my device to be able to install a full XCode
install, so I've had to install it directly from the Swift site using [Swiftly].
If you have Swift installed as well as the toolchain which can handle testing
then you dont need it. The `justfile` reaches for the swiftly binaries first
but falls back to the system default.

## Building

Debug is the default, but it runs terribly due to the Swift runtime. Building in
release mode makes it significantly better but it removes all the debug symbols.

```sh
just build            # debug build
just build release    # release build
```

## Running

Due to the nature of ROMs and the Law, I'm not shipping the ROM in this repo.
You'll have to get your own copy of it and place it in the root of this project.
Once it is there then you can run it.

```sh
just run              # debug
just run release      # release
```

## Controls

Keyboard only for now, I might play with the swift game controler packages
later. The mapping leans on the classic emulator layout, with `Z` and `X` as
the face buttons:

| Key            | NES Button |
| -------------- | ---------- |
| Arrow keys     | D-pad      |
| `X`            | A          |
| `Z`            | B          |
| `Return`       | Start      |
| `Shift`        | Select     |
| `` ` `` (backtick) | Toggle the performance overlay |

That backtick overlay is handy when I'm poking at whether the release build is
actually pulling its weight.

## Testing

There's a test suite. I do need to extend on it.

```sh
just test
```

## License

Released under the [MIT License](LICENSE).

[Swiftly]: https://www.swift.org/install/
