-- Sends the one open Mail compose window whose title is argv item 1, by
-- clicking Message > Send. Refuses (without clicking) unless Mail becomes
-- frontmost and exactly one Mail window has that title and is frontmost,
-- re-checked immediately before the click, so it never sends another window.
-- The title is the run's unique subject (it embeds a per-run timestamp and
-- random number), so matching by title cannot hit an unrelated window.
on run argv
	set wantedTitle to item 1 of argv
	tell application "Mail" to activate
	tell application "System Events"
		tell process "Mail"
			set frontmost to true
			set frontDeadline to (current date) + 5
			repeat until frontmost
				if (current date) > frontDeadline then error "Mail did not become frontmost within 5s; not clicking Send"
				delay 0.05
			end repeat
			-- Not "titled": that is a System Events window property, so inside
			-- this tell block `set titled to ...` sets a property of the process.
			set matchingWindows to (every window whose name is wantedTitle)
			if (count of matchingWindows) is not 1 then error "expected exactly one Mail window titled \"" & wantedTitle & "\", found " & (count of matchingWindows)
			perform action "AXRaise" of (item 1 of matchingWindows)
			delay 0.3
			if not frontmost then error "Mail lost focus; not clicking Send"
			if (count of (every window whose name is wantedTitle)) is not 1 then error "the window titled \"" & wantedTitle & "\" changed; not clicking Send"
			if name of window 1 is not wantedTitle then error "the window titled \"" & wantedTitle & "\" is not frontmost; not clicking Send"
			click menu item "Send" of menu "Message" of menu bar 1
		end tell
	end tell
end run
