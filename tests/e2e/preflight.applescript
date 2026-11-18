-- Read-only: lists every Mail account, SMTP server and rule. One record per
-- line, fields separated by ASCII 31 (unit separator, so empty fields
-- survive the shell's read); the first field names the record type:
--   account, name, enabled, comma-joined email addresses, incoming host,
--     incoming port, outgoing (SMTP) host, outgoing port, POP server-copy
--     deletion ("never", days after download, or empty for non-POP accounts)
--   smtp, name, enabled, host, port
--   rule, name, enabled
-- A value that cannot be read is printed as "?", which the harness refuses.
on run
	set fieldSeparator to character id 31
	set report to ""
	tell application "Mail"
		repeat with acct in (every account)
			set acctName to name of acct
			set acctEnabled to "?"
			try
				set acctEnabled to enabled of acct as text
			end try
			set AppleScript's text item delimiters to ","
			set acctAddresses to (email addresses of acct) as text
			set incomingHost to ""
			set incomingPort to ""
			set outgoingHost to ""
			set outgoingPort to ""
			set popDeletion to ""
			try
				set incomingHost to server name of acct
				set incomingPort to (port of acct) as text
			end try
			try
				set smtpServer to delivery account of acct
				if smtpServer is not missing value then
					set outgoingHost to server name of smtpServer
					set outgoingPort to (port of smtpServer) as text
				end if
			end try
			try
				if delete mail on server of acct then
					set popDeletion to (delayed message deletion interval of acct) as text
				else
					set popDeletion to "never"
				end if
			end try
			set AppleScript's text item delimiters to fieldSeparator
			set report to report & ({"account", acctName, acctEnabled, acctAddresses, incomingHost, incomingPort, outgoingHost, outgoingPort, popDeletion} as text) & linefeed
		end repeat
		repeat with oneServer in (every smtp server)
			set serverName to "?"
			set serverEnabled to "?"
			set serverHost to "?"
			set serverPort to "?"
			try
				set serverName to name of oneServer
			end try
			try
				set serverEnabled to enabled of oneServer as text
			end try
			try
				set serverHost to server name of oneServer
			end try
			try
				set serverPort to (port of oneServer) as text
			end try
			set AppleScript's text item delimiters to fieldSeparator
			set report to report & ({"smtp", serverName, serverEnabled, serverHost, serverPort} as text) & linefeed
		end repeat
		repeat with oneRule in (every rule)
			set ruleName to "?"
			set ruleEnabled to "?"
			try
				set ruleName to name of oneRule
			end try
			try
				set ruleEnabled to enabled of oneRule as text
			end try
			set AppleScript's text item delimiters to fieldSeparator
			set report to report & ({"rule", ruleName, ruleEnabled} as text) & linefeed
		end repeat
	end tell
	return report
end run
