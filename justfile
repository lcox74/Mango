
# Prefer the swiftly-managed toolchain as it has the test frameworks. I
# don't have enough storage on my device for xcode so I am living the
# jank life?
home := env_var('HOME')
swift := if path_exists(home / ".swiftly/bin/swift") == "true" { home / ".swiftly/bin/swift" } else { "swift" }


# Show available recipes.
default:
     @just --list

# Build of the whole project. Defaults to a debug build, but you can set the
# target to release.
[doc('Build the project (debug or release)')]
build target="debug":
    #!/usr/bin/env bash
    set -o pipefail

    config=()
    if [ "{{target}}" = "release" ]; then
        config=(-c release)
    fi

    {{swift}} build "${config[@]}"

# Run the tests suite
test:
    {{swift}} test

# Launch the emulator, this needs the `Spy vs Spy.nes` rom in the
# `Sources/Mango/` directory so it gets bundled into the build at compile time.
[doc('Launch the emulator (debug or release)')]
run target="debug":
    #!/usr/bin/env bash
    set -o pipefail

    config=()
    if [ "{{target}}" = "release" ]; then
        config=(-c release)
    fi

    {{swift}} run "${config[@]}" Mango

# Profile the emulator with the macOS `sample` tool, one report per
# predefined scene
[doc('Profile the emulator (debug or release)')]
profile target="debug":
    #!/usr/bin/env bash
    set -o pipefail

    duration=8   # seconds to sample each region

    config=()
    if [ "{{target}}" = "release" ]; then
        config=(-c release)
    fi

    {{swift}} build "${config[@]}" --product Profiler
    bin="$({{swift}} build "${config[@]}" --product Profiler --show-bin-path)/Profiler"

    scenes=(start menu autoplay)

    # Sample each scene in turn
    sampleFiles=()
    for scene in "${scenes[@]}"; do
        sampleFile="/tmp/mango-sample-${scene}.txt"
        readyFile="/tmp/mango-sample-${scene}.ready"

        # Clean previous run
        rm -f "$sampleFile" "/tmp/mango-sample-${scene}.stats.json" "$readyFile"

        # Run the workload a bit longer to outlive the sampler
        "$bin" "$scene" "$(( duration + 2 ))" &
        pid=$!

        # Wait until workload is ready
        while [ ! -f "$readyFile" ] && kill -0 "$pid" 2>/dev/null; do
            sleep 0.05
        done

        # Sample the workload
        sample "$pid" "$duration" -file "$sampleFile" >/dev/null
        wait "$pid"

        sampleFiles+=("$sampleFile")
    done

    # Render results
    "$bin" report "${sampleFiles[@]}"

# Remove build artifacts
clean:
    rm -rf .build

