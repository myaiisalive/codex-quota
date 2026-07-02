# AGENTS.md

## Release Rules

- A version release is only complete when both the GitHub Release and the Homebrew tap are updated in the same publishing run.
- Do not publish a GitHub Release without updating `myaiisalive/homebrew-tap`, and do not update the tap to a version that does not already exist as a GitHub Release.
- After updating the tap, verify the published version with `brew update` and `brew info --cask --json=v2 codex-quota`.

## Update Channel Rules

- A Homebrew-managed app must only check for and install updates through Homebrew.
- A manually installed app must only check for and install updates from the GitHub installer packages.
- Do not automatically fall back from one install channel to the other.
