# List available recipes
default:
    @just --list

# Build, sign, package, and install ClaudeUsage.app [ --no-install --no-package ]
build *args:
    ./Scripts/build.sh {{args}}

# Build, sign, and package a Developer ID release [ --notary-profile ]
release *args:
    ./Scripts/release.sh {{args}}

# Re-sign a build product with the stable certificate-backed identity
sign target=".build/debug/ClaudeUsage":
    ./Scripts/dev-sign.sh "{{target}}"

# print the resolved Claude windows
dump:
    ClaudeUsage --dump

dump-codex:
    ClaudeUsage --dump-codex 

verify-refresh:
    ClaudeUsage --verify-refresh
