on run
    set helperApp to POSIX path of (path to me)
    set bundledHelper to helperApp & "../../puffroute-killswitch"
    set commandText to "helper_path=" & quoted form of bundledHelper & "; if [ ! -x \"$helper_path\" ]; then console_user=$(/usr/bin/stat -f%Su /dev/console); user_home=$(/usr/bin/dscl . -read /Users/$console_user NFSHomeDirectory | /usr/bin/awk '{print $2}'); helper_path=\"$user_home/.local/bin/puffroute-killswitch\"; fi; /bin/mkdir -p /var/run/puffroute; /bin/chmod 755 /var/run/puffroute; { \"$helper_path\" on; action_status=$?; /bin/echo __RUN__=$$; /bin/echo __STATUS__=$action_status; } > /var/run/puffroute/admin-result 2>&1; /bin/chmod 644 /var/run/puffroute/admin-result"
    «event sysoexec» commandText given «class badm»:true
end run
