-- Read-only snapshot of Mail state the harness must see before it acts.
-- Output, one value per line:
--   1. number of outgoing messages (informational only: Mail keeps sent
--      plain-text messages in this list until it is relaunched)
--   2. number of messages in the Outbox
--   3. number of messages selected in main viewers
--   4+. one line per window that is not a main viewer's window (window id and
--       title, separated by ASCII 31)
-- A value that cannot be read is printed as "?", which the harness refuses.
-- Compose windows, standalone .eml viewers and the Settings window share
-- Mail's generic window class, so all of them are reported.
on run
	set fieldSeparator to character id 31
	tell application "Mail"
		set outgoingCount to "?"
		try
			set outgoingCount to (count of outgoing messages) as text
		end try
		set outboxCount to "?"
		try
			set outboxCount to (count of messages of outbox) as text
		end try
		set selectedCount to 0
		set viewerWindowIDs to {}
		try
			set viewerList to every message viewer
			repeat with oneViewer in viewerList
				set end of viewerWindowIDs to id of (window of oneViewer)
				set viewerSelection to selected messages of oneViewer
				if viewerSelection is not missing value then set selectedCount to selectedCount + (count of viewerSelection)
			end repeat
		on error
			set selectedCount to "?"
		end try
		set report to outgoingCount & linefeed & outboxCount & linefeed & (selectedCount as text) & linefeed
		set allWindowIDs to id of every window
		repeat with windowID in allWindowIDs
			set currentID to contents of windowID
			if viewerWindowIDs does not contain currentID then
				set windowTitle to ""
				try
					set windowTitle to name of window id currentID
				end try
				set report to report & (currentID as text) & fieldSeparator & windowTitle & linefeed
			end if
		end repeat
	end tell
	return report
end run
