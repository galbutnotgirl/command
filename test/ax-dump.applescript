-- Read-only accessibility tree dumper for Command UI smoke tests.
-- Usage: osascript test/ax-dump.applescript <pid>

on run argv
    if (count of argv) is not 1 then error "usage: ax-dump.applescript <pid>"
    set targetPID to (item 1 of argv) as integer
    tell application "System Events"
        set targetProcess to first process whose unix id is targetPID
        if (count of windows of targetProcess) is 0 then error "target process has no windows"
        set targetWindow to front window of targetProcess
        set allElements to entire contents of targetWindow
    end tell
    set output to ""
    repeat with targetElement in allElements
        set output to output & my safeAttribute(targetElement, "AXRole") & " | " & my safeAttribute(targetElement, "AXTitle") & " | " & my safeAttribute(targetElement, "AXDescription") & " | " & my safeAttribute(targetElement, "AXValue") & linefeed
    end repeat
    return output
end run

on safeAttribute(targetElement, attributeName)
    tell application "System Events"
        try
            set attributeValue to value of attribute attributeName of targetElement
            if attributeValue is missing value then return ""
            return attributeValue as text
        on error
            return ""
        end try
    end tell
end safeAttribute
