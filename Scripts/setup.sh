#!/usr/bin/env bash
# First run, in one command.
#
# Everything here could be done by hand from the README, and that is the
# problem: the steps are guessable but numerous, and the two that are easy to
# skip — checking the gh scopes, and clearing a login item left behind by a
# previous identifier — both fail *later*, as an app that quietly shows less
# than it should. Doing them up front is worth more than the keystrokes saved.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Prompts are skipped when there is no terminal to answer them, so this stays
# usable from a script or a fresh-machine bootstrap. Every default is printed
# rather than assumed silently.
INTERACTIVE=0
[ -t 0 ] && INTERACTIVE=1

say()  { printf '==> %s\n' "$1"; }
warn() { printf '    !! %s\n' "$1" >&2; }
die()  { printf 'error: %s\n' "$1" >&2; exit 1; }

ask() {  # ask <prompt> <default>
  local prompt="$1" default="$2" answer
  if [ "$INTERACTIVE" -eq 0 ]; then
    printf '    %s: %s (no terminal; using default)\n' "$prompt" "$default" >&2
    printf '%s' "$default"
    return
  fi
  read -r -p "    $prompt [$default]: " answer </dev/tty
  printf '%s' "${answer:-$default}"
}

# --- 1. prerequisites ------------------------------------------------------
say "checking prerequisites"

command -v swift >/dev/null || die "swift not found. Install Xcode or the Command Line Tools: xcode-select --install"
printf '    swift %s\n' "$(swift --version 2>/dev/null | head -1 | sed 's/.*version //;s/ .*//')"

GH="$(command -v gh || true)"
if [ -z "$GH" ]; then
  warn "gh not found. PR Radar can read a token from the Keychain instead:"
  warn "  security add-generic-password -s PRRadar -a token -w <your token>"
  warn "Continuing, but nothing will load until one of the two is in place."
else
  if gh auth status >/dev/null 2>&1; then
    # Named per account, because a machine can be signed into several and this
    # app now reads all of them.
    gh auth status --json hosts 2>/dev/null \
      | /usr/bin/python3 -c '
import json,sys
try: hosts = json.load(sys.stdin).get("hosts", {})
except Exception: sys.exit(0)
for host, entries in hosts.items():
    for e in entries:
        login = e.get("login", "?")
        scopes = [s.strip() for s in (e.get("scopes") or "").split(",") if s.strip()]
        mark = " (active)" if e.get("active") else ""
        print("    %s@%s%s" % (login, host, mark))
        if scopes and "read:org" not in scopes:
            print("    !! %s has no read:org - reviews requested of a team will not appear" % login)
        if scopes and "repo" not in scopes:
            print("    !! %s has no repo - private repositories will not appear" % login)
' || true
  else
    warn "gh is installed but not logged in. Run: gh auth login"
  fi
fi

# --- 2. the bundle identifier ----------------------------------------------
# Asks for a *name* and builds the identifier from it.
#
# A reverse-DNS string is a format, not a decision, and a tool that can
# construct one should not make a person type one. Asking for the identifier
# directly got exactly what asking invites: a bare login, accepted because it
# broke no rule, which is a legal-but-unconventional identifier — and, because
# the identifier is also the preferences domain, one that silently stranded
# every setting stored under the previous one.
#
# A name cannot be malformed. Anything unusable in one is removed rather than
# rejected, because there is nothing here a person could get wrong that the
# script cannot simply fix.
say "choosing a bundle identifier"

slug() {  # a name -> the middle segment of an identifier
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-'
}

DEFAULT_NAME="example"
if [ -n "$GH" ]; then
  LOGIN="$(gh api user --jq .login 2>/dev/null || true)"
  [ -n "$(slug "${LOGIN:-}")" ] && DEFAULT_NAME="$LOGIN"
fi

printf '    Used for the app identifier, your preferences, and the login item.\n'
NAME="$(ask "your GitHub login or a short name" "$DEFAULT_NAME")"

case "$NAME" in
  *.*)
    # Already reverse-DNS. Someone who typed com.acme.prradar meant it, so it
    # is kept — cleaned of anything illegal, never replaced.
    BUNDLE_ID="$(printf '%s' "$NAME" | tr -cd 'A-Za-z0-9.-' \
                 | sed 's/^\.*//; s/\.*$//; s/\.\{2,\}/./g')"
    ;;
  *)
    BUNDLE_ID="com.$(slug "$NAME").prradar"
    ;;
esac

# Reachable when a name was all punctuation, leaving nothing to build from.
# Falling back beats failing: nothing here is worth stopping an install over,
# and the identifier is printed below either way.
case "$BUNDLE_ID" in
  ""|com..prradar) BUNDLE_ID="com.example.prradar" ;;
  *.*)             : ;;
  *)               BUNDLE_ID="com.example.prradar" ;;
esac

printf '    identifier: %s\n' "$BUNDLE_ID"

# --- 3. a login item left by a previous identifier -------------------------
# The failure this prevents is confusing out of proportion to how rare it is:
# the old agent keeps launching a binary that may no longer be there, and
# nothing connects that to having changed an identifier weeks earlier.
if [ -d /Applications/PRRadar.app ]; then
  OLD_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            /Applications/PRRadar.app/Contents/Info.plist 2>/dev/null || true)"
  if [ -n "$OLD_ID" ] && [ "$OLD_ID" != "$BUNDLE_ID" ]; then
    say "an existing install uses a different identifier"
    printf '    installed: %s\n    new:       %s\n' "$OLD_ID" "$BUNDLE_ID"
    OLD_PLIST="$HOME/Library/LaunchAgents/$OLD_ID.plist"
    if [ -f "$OLD_PLIST" ]; then
      REPLY="$(ask "remove the old login item? (y/n)" "y")"
      if [ "$REPLY" = "y" ]; then
        launchctl unload "$OLD_PLIST" 2>/dev/null || true
        rm -f "$OLD_PLIST"
        printf '    removed %s\n' "$OLD_PLIST"
      else
        warn "left in place; it will keep launching the old bundle at login"
      fi
    fi
  fi
fi

# --- 4. review leads -------------------------------------------------------
# The one thing that cannot be inferred. Skippable, and skipping is a real
# answer: a team with no lead concept should leave it empty.
say "review leads"
printf '    Logins whose approval unblocks a merge on your team.\n'
printf '    Blank to skip — the My PRs tab then always reads "lead needed".\n'
LEADS="$(ask "leads (space separated)" "")"
if [ -n "$LEADS" ]; then
  # shellcheck disable=SC2086
  defaults write "$BUNDLE_ID" leads.logins -array $LEADS
  printf '    set: %s\n' "$LEADS"
else
  printf '    skipped\n'
fi

# --- 5. build, test, install ----------------------------------------------
say "running tests"
if ! swift test >/tmp/prradar-setup-test.log 2>&1; then
  tail -20 /tmp/prradar-setup-test.log >&2
  die "tests failed — full output in /tmp/prradar-setup-test.log"
fi
printf '    %s\n' "$(grep -E 'Executed [0-9]+ tests' /tmp/prradar-setup-test.log \
                      | tail -1 | sed 's/^[[:space:]]*//')"

say "installing"
make install BUNDLE_ID="$BUNDLE_ID"

cat <<DONE

==> done

    Right-click the badge for the menu.
    Change leads later with:  defaults write $BUNDLE_ID leads.logins -array alice bob
    Reinstall with:           make install BUNDLE_ID=$BUNDLE_ID
DONE
