on run argv
    if (count of argv) < 2 then error "Invalid CloudCheck administrator arguments"

    set helperPath to item 1 of argv
    set actionName to item 2 of argv
    if actionName is not in {"install", "setup-on", "on", "off", "status"} then
        error "Invalid CloudCheck administrator action"
    end if

    if actionName is "install" or actionName is "setup-on" then
        if (count of argv) is not 4 then error "Invalid CloudCheck install arguments"
        set serverIPv4 to item 3 of argv
        set interfaceNames to item 4 of argv
        set commandText to (quoted form of helperPath) & " " & (quoted form of actionName) & " " & (quoted form of serverIPv4) & " " & (quoted form of interfaceNames)
    else
        if (count of argv) is not 2 then error "Invalid CloudCheck administrator arguments"
        set commandText to (quoted form of helperPath) & " " & (quoted form of actionName)
    end if
    «event sysoexec» commandText given «class badm»:true
end run
