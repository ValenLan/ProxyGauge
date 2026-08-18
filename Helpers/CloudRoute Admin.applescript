on run argv
    if (count of argv) is not 2 then error "Invalid CloudRoute administrator arguments"

    set helperPath to item 1 of argv
    set actionName to item 2 of argv
    if actionName is not in {"on", "off", "status"} then
        error "Invalid CloudRoute administrator action"
    end if

    set commandText to (quoted form of helperPath) & " " & (quoted form of actionName)
    «event sysoexec» commandText given «class badm»:true
end run
