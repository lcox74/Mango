
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

    config=()
    if [ "{{target}}" = "release" ]; then
        config=(-c release)
    fi

    {{swift}} build "${config[@]}"

# Run the tests suite
test:
    {{swift}} test

# Launch the emulator, this needs the `Spy vs Spy.nes` rom in the root
# directory of the project to actually run.
[doc('Launch the emulator (debug or release)')]
run target="debug":
    #!/usr/bin/env bash

    config=()
    if [ "{{target}}" = "release" ]; then
        config=(-c release)
    fi

    {{swift}} run "${config[@]}" Mango

# Launch the profiler to see what is chewing the time between frames
[doc('Profile the emulator (debug or release)')]
profile target="debug":
    #!/usr/bin/env bash

    report=/tmp/mango-sample.txt
    duration=15   # seconds to sample
    rows=29       # functions to print

    config=()
    if [ "{{target}}" = "release" ]; then
        config=(-c release)
    fi

    {{swift}} build "${config[@]}" --product Profiler
    bin="$({{swift}} build "${config[@]}" --product Profiler --show-bin-path)"

    "$bin/Profiler" &
    pid=$!
    disown   # stop bash reporting "Terminated" when we kill it below
    sleep 1
    sample "$pid" "$duration" -file "$report"
    kill "$pid" 2>/dev/null || true

    echo
    # Reprint the "top of stack" section as "<samples>  <function>",
    # sorted as the report already is, stopping after $rows lines.
    awk -v rows="$rows" '
        /Sort by top of stack/ { capture = 1; next }
        capture && NF {
            samples = $NF; $NF = ""
            sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "")
            printf "%8s  %s\n", samples, $0
            if (++shown == rows) exit
        }
    ' "$report"

# Remove build artifacts
clean:
    rm -rf .build

