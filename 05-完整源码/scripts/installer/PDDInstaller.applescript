on run
    set installerApp to path to me
    tell application "Finder"
        set installFolder to container of installerApp as alias
        set packageFolder to container of installFolder as alias
    end tell
    set packagePOSIX to POSIX path of packageFolder
    set sourceApp to packagePOSIX & "02-正式程序/pinduodou_automation.app"
    set targetApp to "/Applications/pinduodou_automation.app"
    try
        set timeStamp to do shell script "/bin/date +%Y%m%d-%H%M%S"
        set backupApp to targetApp & ".安装前备份-" & timeStamp
        do shell script "test -d " & quoted form of sourceApp
        do shell script "if test -d " & quoted form of targetApp & "; then mv " & quoted form of targetApp & " " & quoted form of backupApp & "; fi; /usr/bin/ditto --rsrc --extattr " & quoted form of sourceApp & " " & quoted form of targetApp
        do shell script "/usr/bin/open " & quoted form of targetApp
        display dialog "安装完成。程序已经打开；请按照 00-把这个文件交给Codex 中的说明完成权限和兼容性检查。\n\nInstallation complete. The app is open; follow the guide in 00-把这个文件交给Codex to finish permissions and compatibility checks." buttons {"好 / OK"} default button "好 / OK"
    on error messageText number messageNumber
        display dialog "安装失败（" & messageNumber & "）：" & messageText & "\nInstallation failed (" & messageNumber & "): " & messageText buttons {"好 / OK"} default button "好 / OK" with icon stop
    end try
end run
