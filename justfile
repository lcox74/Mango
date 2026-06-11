
# Prefer the swiftly-managed toolchain as it has the test frameworks. I
# don't have enough storage on my device for xcode so I am living the
# jank life?
home := env_var('HOME')
swift := if path_exists(home / ".swiftly/bin/swift") == "true" { home / ".swiftly/bin/swift" } else { "swift" }


# Show available recipes.
default:
     @just --list

# Build of the whole project. Defaults to a debug build, but you can
# set the target to release.
[doc('Build the project (debug or release)')]
build target="debug":
    #!/usr/bin/env bash
    if [ "{{target}}" = "release" ]; then
        {{swift}} build -c release
    else
        {{swift}} build
    fi

# Run the tests suite
test:
    {{swift}} test

# Launch the emulator, this needs the `Spy vs Spy.nes` rom in the root
# directory of the project to actually run.
[doc('Launch the emulator (debug or release)')]
run target="debug":
    #!/usr/bin/env bash
    if [ "{{target}}" = "release" ]; then
        {{swift}} run -c release Mango
    else
        {{swift}} run Mango
    fi

profile:
    {{swift}} run Profiler

# Remove build artifacts
clean:
    rm -rf .build

