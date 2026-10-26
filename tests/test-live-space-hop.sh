#!/usr/bin/env bash
# Live regression for issue #63: a jump to a tab whose window is on another
# Space must take you to that Space, not bring the window to yours.
#
# Needs a desk, not a person. It opens one Ghostty window of its own, parks it
# on a neighbouring Space of a display none of your Ghostty windows is on, and
# asks the agent to jump to its background tab the way a click would — the
# `--focus` mode runs the same jump. Then it checks that the window stayed on
# its Space, that the Space came into view, and that the tab is selected. The
# display's Space is switched away and back and the pointer is parked for a
# moment; both are put back, and the window is closed.
#
# The jump needs the Accessibility permission. A shell inside Ghostty has it
# whenever Ghostty does, which is what lets this run without the resident app
# being granted it. The resident needs its own grant; that part a click tests.
#
# Usage: bash tests/test-live-space-hop.sh [path/to/ghostty-notify-agent]
# The default binary is the installed app's. Needs Ghostty with
# `macos-applescript` on, Automation consent for this shell, and the default
# Control-Left/Right shortcuts for moving between Spaces.
set -euo pipefail

APP="${GHOSTTY_NOTIFY_NATIVE_APP:-$HOME/Library/Application Support/claude-ghostty-notify/ClaudeGhosttyNotify.app}"
BIN="${1:-$APP/Contents/MacOS/ghostty-notify-agent}"
[[ -x "$BIN" ]] || { echo "agent binary missing: $BIN" >&2; exit 2; }
LOG="$HOME/.claude/notifications/ghostty-agent/agent.log"
SESSION_DIR="${GHOSTTY_NOTIFY_SESSION_DIR:-$HOME/.claude/notifications/ghostty-sessions}"
SESSION=$(uuidgen | tr 'A-Z' 'a-z')
BINDING="$SESSION_DIR/$SESSION.json"

START_CONTROL=""; WIN=""; FIRST=""; BG=""; SEL=""; HELPER=""; HELPER_TAB=""; DISPLAY_ID=""; HOME_SPACE=""; AWAY_KEY=""; POINTER=""; START_SPACES=""
fail() { echo "FAIL: $*" >&2; exit 1; }

where() { "$BIN" --where "$1" 2>/dev/null || true; }
# `display <id> current=<space> spaces=<a,b,c> bounds=<x,y,w,h>` lines.
display_field() { where "$1" | awk -v id="$2" -v key="$3" '$1=="display" && $2==id { for (i=3;i<=NF;i++) if (index($i, key"=")==1) print substr($i, length(key)+2) }'; }
space_of_window() { where "$1" | awk -v n="$2" '$1=="ordered" && $2==n { sub("spaces=","",$3); print $3 }'; }
place_of() { where "$1" | sed -nE 's/^tab .* place=//p'; }

pointer() {
    osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); const p = $.CGEventGetLocation($.CGEventCreate(null)); p.x + " " + p.y'
}
# The pointer and the key go the way the agent sends them: a posted mouse move,
# then the key with exactly the registered modifiers — Control plus the
# keypad flag arrow keys carry. System Events' `key code … using control down`
# switched Spaces only some of the time.
warp() {
    # As the agent does: a warp, the event a mouse would send, then a short
    # wait until the pointer is seen there, because the shortcut acts on the
    # display the window server thinks the pointer is on.
    osascript -l JavaScript -e "ObjC.import('CoreGraphics');
const to = {x: $1, y: $2};
\$.CGWarpMouseCursorPosition(to);
\$.CGEventPost(0, \$.CGEventCreateMouseEvent(null, 5, to, 0));
for (let i = 0; i < 30; i++) {
    const at = \$.CGEventGetLocation(\$.CGEventCreate(null));
    if (Math.abs(at.x - to.x) < 2 && Math.abs(at.y - to.y) < 2) break;
    delay(0.01);
}
''" >/dev/null
}
press() {
    # As the agent does: the key up carries only the modifiers physically held
    # (a foot pedal holding Control, say). One that carried the shortcut's own
    # would leave Control held.
    osascript -l JavaScript -e "ObjC.import('CoreGraphics');
const held = \$.CGEventSourceFlagsState(1) & 0x9e0000;
for (const down of [true, false]) {
    const e = \$.CGEventCreateKeyboardEvent(null, $1, down);
    \$.CGEventSetFlags(e, down ? (0x840000 | held) : held);
    \$.CGEventPost(0, e);
}
''" >/dev/null
}
# Control released. Only called when this run left it held: a Control the
# user holds, by hand or with a pedal, is theirs.
release_modifiers() {
    osascript -l JavaScript -e "ObjC.import('CoreGraphics');
const e = \$.CGEventCreateKeyboardEvent(null, 59, false);
\$.CGEventSetFlags(e, 0);
\$.CGEventPost(0, e);
''" >/dev/null
}
modifier_flags() { osascript -l JavaScript -e 'ObjC.import("Cocoa"); $.NSEvent.modifierFlags'; }
frontmost_app() { osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true'; }

# `<display> <space>` for every display.
current_spaces() { where tab-none | awk '$1=="display" { sub("current=","",$3); print $2, $3 }'; }

# Puts every display back on the Space it showed when the run started. The
# shortcut acts on the display under the pointer, so the pointer goes there
# before each press; a display whose Space no longer exists is reported.
restore_spaces() {
    local pass line id cur spaces bounds home want cur_index key x y w h moved
    for pass in 1 2 3 4 5 6 7 8; do
        moved=0
        while read -r line; do
            id=$(awk '{print $2}' <<<"$line")
            cur=$(sed -nE 's/.* current=([0-9]+).*/\1/p' <<<"$line")
            spaces=$(sed -nE 's/.* spaces=([0-9,]+).*/\1/p' <<<"$line")
            bounds=$(sed -nE 's/.* bounds=([-0-9,]+).*/\1/p' <<<"$line")
            home=$(awk -v id="$id" '$1==id {print $2}' <<<"$START_SPACES")
            [[ -n "$home" && -n "$cur" && "$cur" != "$home" ]] || continue
            want=$(tr , '\n' <<<"$spaces" | grep -nx "$home" | cut -d: -f1)
            cur_index=$(tr , '\n' <<<"$spaces" | grep -nx "$cur" | cut -d: -f1)
            if [[ -z "$want" || -z "$cur_index" || -z "$bounds" ]]; then
                echo "cannot put display $id back on Space $home" >&2
                continue
            fi
            if (( want < cur_index )); then key=123; else key=124; fi
            IFS=, read -r x y w h <<<"$bounds"
            [[ $pass == 1 ]] && echo "putting display $id back on Space $home"
            warp "$((x + w / 2))" "$((y + h / 2))"; sleep 0.3
            press "$key"; sleep 1
            moved=1
        done < <(where tab-none | awk '$1=="display"')
        [[ $moved == 1 ]] || break
    done
    local now
    now=$(current_spaces)
    [[ "$now" == "$START_SPACES" ]] || echo "Spaces not as they were; started: $START_SPACES now: $now" >&2
}

cleanup() {
    local status=$?
    trap - EXIT
    # Finish the cleanup even if whoever read the output has gone away: a
    # broken pipe must not leave the test window open or the Space switched.
    trap '' PIPE
    set +e
    rm -f "$BINDING"
    if [[ -n "$WIN" ]]; then
        # Close only the window this run made, re-checked by id and by its
        # tabs, which must all be ones this run made.
        local tabs ours=yes tab
        tabs=$(osascript -e "tell application \"Ghostty\" to get id of every tab of (first window whose id is \"$WIN\")" 2>/dev/null || true)
        [[ -n "$tabs" ]] || ours=no
        for tab in ${tabs//,/ }; do
            [[ "$tab" == "$FIRST" || ( -n "$SEL" && "$tab" == "$SEL" ) ]] || ours=no
        done
        if [[ $ours == yes ]]; then
            osascript -e "tell application \"Ghostty\" to close window (first window whose id is \"$WIN\")" >/dev/null 2>&1 \
                && echo "closed the test window $WIN" || echo "could not close the test window $WIN" >&2
        else
            echo "not closing $WIN: its tabs are now '$tabs', not only the ones this run made" >&2
        fi
    fi
    if [[ -n "$HELPER" ]]; then
        local helper_tabs
        helper_tabs=$(osascript -e "tell application \"Ghostty\" to get id of every tab of (first window whose id is \"$HELPER\")" 2>/dev/null || true)
        if [[ -n "$HELPER_TAB" && "$helper_tabs" == "$HELPER_TAB" ]]; then
            osascript -e "tell application \"Ghostty\" to close window (first window whose id is \"$HELPER\")" >/dev/null 2>&1 \
                && echo "closed the helper window $HELPER" || echo "could not close the helper window $HELPER" >&2
        else
            echo "not closing $HELPER: its tabs are now '$helper_tabs', not the one this run made" >&2
        fi
    fi
    [[ -n "$START_SPACES" ]] && restore_spaces
    if [[ -n "$POINTER" ]]; then read -r px py <<<"$POINTER"; warp "$px" "$py"; fi
    local now_modifiers
    now_modifiers=$(modifier_flags 2>/dev/null || echo 0)
    if [[ "$START_CONTROL" == no && "$now_modifiers" =~ ^[0-9]+$ ]] && (( (now_modifiers & 0x40000) != 0 )); then
        echo "releasing the Control this run left held"
        release_modifiers
    fi
    exit "$status"
}
trap cleanup EXIT

echo "agent: $BIN"
GHOSTTY_PID=$(osascript -e 'tell application "System Events" to get unix id of first process whose bundle identifier is "com.mitchellh.ghostty"') \
    || fail "Ghostty is not running"
BEFORE=$(where tab-none)
grep -q '^accessibility=granted' <<<"$BEFORE" || fail "this shell has no Accessibility permission; run it inside a Ghostty that has one"
BEFORE_WINDOWS=$(awk '$1=="ordered" {print $2}' <<<"$BEFORE" | tr '\n' ' ')
POINTER=$(pointer)
# Whether Control is held before anything is pressed: a pedal or a hand may
# hold it, and then whether the jump left it held cannot be told.
START_MODIFIERS=$(modifier_flags)
[[ "$START_MODIFIERS" =~ ^[0-9]+$ ]] || fail "could not read the modifier flags"
if (( (START_MODIFIERS & 0x40000) != 0 )); then START_CONTROL=yes; else START_CONTROL=no; fi
START_SPACES=$(current_spaces)
[[ -n "$START_SPACES" ]] || fail "the agent reports no displays"

# One window, two tabs: the second tab is selected, the first is the
# background tab the jump must reach. Made in two steps, so a window whose
# second tab never comes is still known to be this run's and gets closed.
MADE=$(osascript <<'AS'
tell application "Ghostty"
    set seen to {}
    repeat with w in windows
        set end of seen to (id of w)
    end repeat
    -- The window the command returns is the one it made; a window someone
    -- else opens meanwhile is never taken for it.
    set newWin to new window
    if newWin is missing value then error "no new window"
    if seen contains (id of newWin) then error "new window returned an existing window"
    if (count of tabs of newWin) is not 1 then error "the new window should have one tab"
    return (id of newWin) & " " & (id of first tab of newWin)
end tell
AS
) || fail "could not open the test window: $MADE"
read -r WIN FIRST <<<"$MADE"
[[ "$WIN" == tab-group-* && "$FIRST" == tab-* ]] || { WIN=""; fail "unexpected ids: $MADE"; }
BG=$FIRST
SEL=$(osascript - "$WIN" "$FIRST" <<'AS'
on run argv
    set {winID, firstID} to {item 1 of argv, item 2 of argv}
    tell application "Ghostty"
        set win to first window whose id is winID
        focus (focused terminal of (first tab of win whose id is firstID))
        delay 0.4
        new tab in win
        repeat 60 times
            delay 0.1
            if (count of tabs of win) is 2 then exit repeat
        end repeat
        if (count of tabs of win) is not 2 then error "the second tab did not appear"
        repeat with t in tabs of win
            if (id of t) is not firstID then return (id of t)
        end repeat
    end tell
end run
AS
) || fail "could not add the second tab: $SEL"
SEL=${SEL//[[:space:]]/}
echo "test window $WIN: background tab $BG, selected tab $SEL"
sleep 0.5

# Its window number: the ordered window that was not there before.
# Exactly one, or nothing is moved: a window someone else opened meanwhile,
# titled like this one, must not be taken for it.
new_numbers() {
    local n found=""
    for n in $(where "$BG" | awk '$1=="ordered" {print $2}'); do
        case " $1 " in *" $n "*) ;; *) found="$found $n" ;; esac
    done
    echo "$found"
}
read -r -a FRESH <<<"$(new_numbers "$BEFORE_WINDOWS")"
[[ ${#FRESH[@]} == 1 ]] || fail "expected one new window in the window server, found: ${FRESH[*]:-none}"
NUMBER=${FRESH[0]}

# A display none of the other Ghostty windows is on, with a Space to go to.
OTHERS=$(where "$BG" | awk -v n="$NUMBER" '$1=="ordered" && $2!=n { sub("spaces=","",$3); print $3 }' | tr '\n' ',')
DISPLAY_ID=""
while read -r line; do
    id=$(awk '{print $2}' <<<"$line")
    current=$(sed -nE 's/.* current=([0-9?]+).*/\1/p' <<<"$line")
    spaces=$(sed -nE 's/.* spaces=([0-9,]+).*/\1/p' <<<"$line")
    [[ ",$OTHERS" == *",$current,"* ]] && continue
    [[ "$spaces" == *,* ]] || continue
    DISPLAY_ID=$id; HOME_SPACE=$current; HOME_SPACES=$spaces
    break
done < <(where "$BG" | awk '$1=="display"')
[[ -n "$DISPLAY_ID" ]] || fail "no display with two Spaces that is free of your other Ghostty windows"
BOUNDS=$(display_field "$BG" "$DISPLAY_ID" bounds)
IFS=, read -r bx by bw bh <<<"$BOUNDS"
echo "using display $DISPLAY_ID (Spaces $HOME_SPACES, showing $HOME_SPACE)"

# Moves one of this run's windows, given its id, window number and a target
# point. Never by "front window" or an index: that once moved the user's own
# window. The window is matched by its title and the frame the window server
# reports for its number, the match must be unique, and afterwards every other
# Ghostty window must still be where it was.
move_own_window() {
    local id=$1 number=$2 nx=$3 ny=$4 title wx wy ww wh others_before others_after moved
    title=$(osascript -e "tell application \"Ghostty\" to get name of (first window whose id is \"$id\")")
    IFS=, read -r wx wy ww wh <<<"$(where "$BG" | awk -v n="$number" '$1=="ordered" && $2==n { sub("bounds=","",$4); print $4 }')"
    others_before=$(where "$BG" | awk -v n="$number" '$1=="ordered" && $2!=n' | sort)
    moved=$(osascript - "$title" "$wx" "$wy" "$ww" "$wh" "$nx" "$ny" <<'AS'
on run argv
    set {wanted, x, y, w, h, nx, ny} to {item 1 of argv, (item 2 of argv) as integer, (item 3 of argv) as integer, (item 4 of argv) as integer, (item 5 of argv) as integer, (item 6 of argv) as integer, (item 7 of argv) as integer}
    tell application "System Events" to tell process "Ghostty"
        set matches to {}
        repeat with win in windows
            if (name of win) is wanted and (position of win) is {x, y} and (size of win) is {w, h} then set end of matches to win
        end repeat
        if (count of matches) is not 1 then return "matched " & (count of matches)
        set position of item 1 of matches to {nx, ny}
        return "moved"
    end tell
end run
AS
)
    [[ "$moved" == moved ]] || fail "could not single out window $id in System Events ($moved)"
    sleep 0.6
    others_after=$(where "$BG" | awk -v n="$number" '$1=="ordered" && $2!=n' | sort)
    [[ "$others_before" == "$others_after" ]] || fail "another Ghostty window moved; before: $others_before after: $others_after"
}

# Park the test window there.
move_own_window "$WIN" "$NUMBER" "$((bx + 60))" "$((by + 80))"
[[ "$(space_of_window "$BG" "$NUMBER")" == "$HOME_SPACE" ]] || fail "the test window did not land on Space $HOME_SPACE of display $DISPLAY_ID"

# Put the keyboard focus on another display, in a one-tab window of this run's:
# the jump has to switch the test window's display while the key window is
# elsewhere — you working in a window on one screen, the session's window
# hidden on the other. Skipped with a single display.
OTHER_DISPLAY=$(where "$BG" | awk -v id="$DISPLAY_ID" '$1=="display" && $2!=id {print $2; exit}')
KEY_ELSEWHERE=no
if [[ -n "$OTHER_DISPLAY" ]]; then
    BEFORE_HELPER=$(where "$BG" | awk '$1=="ordered" {print $2}' | tr '\n' ' ')
    MADE_HELPER=$(osascript <<'AS'
tell application "Ghostty"
    set seen to {}
    repeat with w in windows
        set end of seen to (id of w)
    end repeat
    -- The window the command returns is the one it made; a window someone
    -- else opens meanwhile is never taken for it.
    set newWin to new window
    if newWin is missing value then error "no new window"
    if seen contains (id of newWin) then error "new window returned an existing window"
    return (id of newWin) & " " & (id of first tab of newWin)
end tell
AS
) || fail "could not open the helper window: $MADE_HELPER"
    read -r HELPER HELPER_TAB <<<"$MADE_HELPER"
    [[ "$HELPER" == tab-group-* && "$HELPER_TAB" == tab-* ]] || { HELPER=""; fail "unexpected helper ids: $MADE_HELPER"; }
    sleep 0.5
    read -r -a FRESH <<<"$(new_numbers "$BEFORE_HELPER")"
    [[ ${#FRESH[@]} == 1 ]] || fail "expected one new helper window in the window server, found: ${FRESH[*]:-none}"
    HELPER_NUMBER=${FRESH[0]}
    IFS=, read -r ox oy ow oh <<<"$(display_field "$BG" "$OTHER_DISPLAY" bounds)"
    move_own_window "$HELPER" "$HELPER_NUMBER" "$((ox + 80))" "$((oy + 120))"
    echo "helper window $HELPER on display $OTHER_DISPLAY"
fi

# The frontmost app and the position of its front window, read only.
key_window() {
    osascript <<'AS' 2>/dev/null || true
tell application "System Events"
    set p to first application process whose frontmost is true
    set pos to position of window 1 of p
    return (name of p) & " " & ((item 1 of pos) as text) & "," & ((item 2 of pos) as text)
end tell
AS
}

# Switch that display one Space over, so the window is out of view. With the
# key window on the other display, this press is itself a check of which
# display the shortcut acts on.
if [[ "$HOME_SPACES" == *",$HOME_SPACE" ]]; then AWAY_KEY=123; else AWAY_KEY=124; fi
warp "$((bx + bw / 2))" "$((by + bh / 2))"; sleep 0.3
press "$AWAY_KEY"
for _ in $(seq 1 20); do sleep 0.2; [[ "$(place_of "$BG")" == hidden* ]] && break; done
AWAY_SPACE=$(display_field "$BG" "$DISPLAY_ID" current)
[[ "$AWAY_SPACE" != "$HOME_SPACE" ]] || fail "Control-arrow did not switch display $DISPLAY_ID's Space (is the shortcut the default?)"
read -r px py <<<"$POINTER"; warp "$px" "$py"
PLACE=$(place_of "$BG")
echo "display now on Space $AWAY_SPACE; the agent places the test window as: $PLACE"
# The placement pairs Ghostty's window list with the window server's by
# position, so say where the test window stands in each, and how many other
# windows share its title (titles alone cannot tell those apart).
LISTING=$(where "$BG")
position() { awk -v want="$1" '{ for (i = 1; i <= NF; i++) if ($i == want) { print i; exit } }' <<<"$2"; }
SCRIPTED_IDS=$(awk '$1=="window" {print $2}' <<<"$LISTING" | tr '\n' ' ')
ORDERED_NUMBERS=$(awk '$1=="ordered" {print $2}' <<<"$LISTING" | tr '\n' ' ')
SHARED=$(awk -v w="$WIN" '$1=="window" { t=$0; sub(/^window [^ ]+ title=/, "", t); title[$2]=t } END { n=0; for (k in title) if (k != w && title[k] == title[w]) n++; print n }' <<<"$LISTING")
echo "test window: #$(position "$WIN" "$SCRIPTED_IDS") of $(awk '{print NF}' <<<"$SCRIPTED_IDS") in Ghostty's list, #$(position "$NUMBER" "$ORDERED_NUMBERS") of $(awk '{print NF}' <<<"$ORDERED_NUMBERS") in the window server's; its title is shared by $SHARED other window(s)"
[[ "$PLACE" == "hidden candidates=$NUMBER"* ]] || fail "expected the window to be placed as hidden with candidate $NUMBER"

# Hand the keyboard focus to the helper, after the Space switch so that the
# switch cannot hand it to whatever the new Space shows: focus its terminal,
# then activate Ghostty, whose key window it now is. Both its windows still in
# view are on the other display, so activating moves no Space.
if [[ -n "$HELPER" ]]; then
    osascript -e "tell application \"Ghostty\" to focus (focused terminal of (first tab of (first window whose id is \"$HELPER\")))" >/dev/null
    open -a Ghostty
    sleep 0.6
    KEY_AT=$(key_window)
    # Ghostty in front, its front window anywhere on the other display: the
    # name comes back in lower case, and the window need not sit exactly
    # where it was put.
    read -r key_app key_position <<<"$KEY_AT"
    IFS=, read -r kx ky <<<"$key_position"
    if [[ "$(tr '[:upper:]' '[:lower:]' <<<"$key_app")" == ghostty && "$kx" =~ ^-?[0-9]+$ && "$ky" =~ ^-?[0-9]+$ ]] \
        && (( kx >= ox && kx < ox + ow && ky >= oy && ky < oy + oh )); then
        KEY_ELSEWHERE=yes
    fi
    echo "key window: ${KEY_AT:-unknown} (on the other display: $KEY_ELSEWHERE)"
    [[ "$KEY_ELSEWHERE" == yes ]] || fail "could not hand the keyboard focus to the helper window"
    [[ "$(place_of "$BG")" == hidden* ]] || fail "handing the focus to the helper brought the test window into view"
fi

# The jump, as a click would make it.
mkdir -p "$SESSION_DIR"
(umask 077; jq -nc --arg tab "$BG" --arg cwd "$PWD" --arg pid "$GHOSTTY_PID" \
    '{tab_id: $tab, cwd: $cwd, ghostty_pid: $pid}' >"$BINDING")
LOG_LINES=$(wc -l <"$LOG" 2>/dev/null || echo 0)
# Selecting the background tab orders a different window in — every native
# tab is a window of its own — so after the jump the test window is found as
# the ordered window that is none of the others.
OTHER_NUMBERS=$(where "$BG" | awk -v n="$NUMBER" '$1=="ordered" && $2!=n {print $2}' | tr '\n' ' ')
echo "frontmost before the jump: $(frontmost_app); Spaces: $(current_spaces | tr '\n' ' ')"
echo "jumping to ${BG}…"
"$BIN" --focus "$SESSION"
sleep 0.3

# What happened.
AFTER_NUMBERS=""
for n in $(where "$BG" | awk '$1=="ordered" {print $2}'); do
    case " $OTHER_NUMBERS " in *" $n "*) ;; *) AFTER_NUMBERS="$AFTER_NUMBERS $n" ;; esac
done
read -r -a AFTER_LIST <<<"$AFTER_NUMBERS"
[[ ${#AFTER_LIST[@]} == 1 ]] || fail "expected one test window ordered in after the jump, found: ${AFTER_NUMBERS:-none}"
AFTER_SPACE=$(space_of_window "$BG" "${AFTER_LIST[0]}")
SHOWING=$(display_field "$BG" "$DISPLAY_ID" current)
SELECTED=$(osascript -e "tell application \"Ghostty\" to get selected of (first tab of (first window whose id is \"$WIN\") whose id is \"$BG\")")
JUMP_LINE=$(tail -n +"$((LOG_LINES + 1))" "$LOG" 2>/dev/null | grep 'jump:' | tail -1 || true)
echo "window Space: $HOME_SPACE -> $AFTER_SPACE; display shows: $SHOWING; tab selected: $SELECTED; frontmost: $(frontmost_app)"
echo "log: ${JUMP_LINE:-<no jump line>}"
# Read before anything else sends a key: a key up that carried Control would
# have left it held, and every click would arrive as a Control-click.
MODIFIERS=$(modifier_flags)
echo "modifier flags after the jump: $MODIFIERS (Control held before the run: $START_CONTROL)"
[[ "$MODIFIERS" =~ ^[0-9]+$ ]] || fail "could not read the modifier flags"
if [[ "$START_CONTROL" == no ]]; then
    (( (MODIFIERS & 0x40000) == 0 )) || fail "Control is left held after the jump"
else
    echo "Control was already held when the run began; not checked"
fi
OTHER_DISPLAYS_NOW=$(current_spaces | awk -v id="$DISPLAY_ID" '$1!=id')
OTHER_DISPLAYS_START=$(awk -v id="$DISPLAY_ID" '$1!=id' <<<"$START_SPACES")
[[ "$OTHER_DISPLAYS_NOW" == "$OTHER_DISPLAYS_START" ]] || fail "another display switched Space: $OTHER_DISPLAYS_START -> $OTHER_DISPLAYS_NOW"
[[ "$AFTER_SPACE" == "$HOME_SPACE" ]] || fail "the window was pulled to Space $AFTER_SPACE (issue #63)"
[[ "$SHOWING" == "$HOME_SPACE" ]] || fail "display $DISPLAY_ID still shows Space $SHOWING, not the window's $HOME_SPACE"
[[ "$SELECTED" == true ]] || fail "the background tab is not selected"
[[ "$JUMP_LINE" == *"travelled"*"verified selected"* ]] || fail "the log does not say the jump travelled and verified"
echo "PASS: the jump went to the window's Space and selected the tab (key window elsewhere: $KEY_ELSEWHERE)"
