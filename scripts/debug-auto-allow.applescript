property browserProcessNames : {"Google Chrome", "Google Chrome Canary", "Chromium"}
property requiredTerms : {"remote debugging", "DevTools", "Developer Tools", "CDP", "chrome-devtools", "MCP", "remote debugging connection", "another program is trying", "远程调试", "遠端偵錯", "遠端調試"}
property confirmationTerms : {"wants full control", "debug it", "saved data", "cookies and site data", "trusted apps", "external app", "navigate to any URL", "完全控制", "调试", "調試", "已保存的数据", "已儲存的資料", "可信的应用", "可信的應用"}
property automationBannerTerms : {"Chrome is being controlled by automated test software", "Chrome 正受到自动测试软件的控制", "Chrome 目前受到自動測試軟體控制"}
property allowButtonNames : {"Allow", "允许", "允許", "OK", "确定", "確定", "確認", "好"}
property denyButtonNames : {"Cancel", "取消", "Deny", "拒绝", "拒絕"}
property infobarNames : {"Infobar", "Info bar", "Infobar Container", "信息栏", "資訊欄", "資訊列"}
property dismissButtonNames : {"Close", "关闭", "關閉"}
property minimumActionInterval : 3
property maximumTreeDepth : 9
property dryRunEnabled : false
property focusStealEnabled : false
property pollingInterval : 0.4
property cooldownLengthTicks : 8
property cooldownTicksRemaining : 0

on run argv
	if (count of argv) ≥ 2 and (item 1 of argv as text) is "--match" then
		if my matchesDialogTerms(item 2 of argv as text) then return "match"
		return "no-match"
	end if
	if (count of argv) ≥ 2 and (item 1 of argv as text) is "--allow-button" then
		if my textIsOneOf(item 2 of argv as text, my allowButtonNames) then return "match"
		return "no-match"
	end if

	set dryRunEnabled to false
	set focusStealEnabled to false
	set pollingInterval to 0.4
	set argumentIndex to 1
	repeat while argumentIndex ≤ (count of argv)
		set argumentText to (item argumentIndex of argv) as text
		if argumentText is "--dry-run" then set dryRunEnabled to true
		if argumentText is "--allow-focus-steal" then set focusStealEnabled to true
		if argumentText is "--interval" and argumentIndex < (count of argv) then
			set intervalText to (item (argumentIndex + 1) of argv) as text
			try
				set pollingInterval to intervalText as real
			on error
				set pollingInterval to 0.4
			end try
			if pollingInterval < 0.2 then set pollingInterval to 0.2
			if pollingInterval > 5 then set pollingInterval to 5
			set argumentIndex to argumentIndex + 1
		end if
		set argumentIndex to argumentIndex + 1
	end repeat
	my updateCooldownLength()

	my logMessage("Started; dry-run=" & (dryRunEnabled as text) & "; focus-steal=" & (focusStealEnabled as text) & "; interval=" & (pollingInterval as text))
end run

on idle
	if cooldownTicksRemaining > 0 then set cooldownTicksRemaining to cooldownTicksRemaining - 1
	try
		my scanBrowsers()
	on error errorMessage number errorNumber
		my logMessage("Scan error " & (errorNumber as text) & ": " & errorMessage)
	end try
	return pollingInterval
end idle

on updateCooldownLength()
	set cooldownLengthTicks to (minimumActionInterval / pollingInterval) as integer
	if cooldownLengthTicks < 1 then set cooldownLengthTicks to 1
	if (cooldownLengthTicks * pollingInterval) < minimumActionInterval then set cooldownLengthTicks to cooldownLengthTicks + 1
end updateCooldownLength

on matchesDialogTerms(dialogText)
	set hasRequiredTerm to my containsAny(dialogText, my requiredTerms)
	set hasConfirmationTerm to my containsAny(dialogText, my confirmationTerms)
	return hasRequiredTerm and hasConfirmationTerm
end matchesDialogTerms

on matchesAutomationInfobar(markerText, bannerText, buttonLabel)
	return my textIsOneOf(markerText, my infobarNames) and my containsAny(bannerText, my automationBannerTerms) and my textIsOneOf(buttonLabel, my dismissButtonNames)
end matchesAutomationInfobar

on containsAny(theText, termList)
	set haystack to theText as text
	repeat with termRef in termList
		set needle to contents of termRef as text
		ignoring case
			if haystack contains needle then return true
		end ignoring
	end repeat
	return false
end containsAny

on textIsOneOf(theText, termList)
	set candidateText to theText as text
	repeat with termRef in termList
		set expectedText to contents of termRef as text
		ignoring case
			if candidateText is expectedText then return true
		end ignoring
	end repeat
	return false
end textIsOneOf

on scanBrowsers()
	tell application "System Events"
		repeat with processNameRef in my browserProcessNames
			set processName to contents of processNameRef as text
			try
				set processRef to first application process whose name is processName
				set windowRefs to windows of processRef
			on error
				set processRef to missing value
				set windowRefs to {}
			end try

			if processRef is not missing value then
				repeat with windowRef in windowRefs
					set currentWindow to contents of windowRef
					set sheetRefs to {}
					try
						set sheetRefs to sheets of currentWindow
					end try

					repeat with sheetRef in sheetRefs
						my inspectContainer(contents of sheetRef, processRef, processName, "sheet")
					end repeat

					if (count of sheetRefs) is 0 then
						my inspectStandaloneWindow(currentWindow, processRef, processName)
					end if

					my inspectAutomationBanner(currentWindow, processRef, processName)
				end repeat
			end if
		end repeat
	end tell
end scanBrowsers

on inspectAutomationBanner(theWindow, processRef, processName)
	my inspectAutomationInfobar(theWindow, processRef, processName, 0)
end inspectAutomationBanner

on inspectAutomationInfobar(theElement, processRef, processName, currentDepth)
	if currentDepth > maximumTreeDepth then return false
	set elementRole to ""
	tell application "System Events"
		try
			set elementRole to (role of theElement) as text
		end try
	end tell
	if elementRole is "AXWebArea" or elementRole is "AXDocument" then return false

	set infobarLabel to my matchingExactLabel(theElement, my infobarNames)
	if infobarLabel is not missing value then
		set bannerText to my collectAccessibilityText(theElement, 0)
		set buttonRefs to my collectButtonReferences(theElement, 0)
		repeat with buttonRef in buttonRefs
			set currentButton to contents of buttonRef
			set dismissButtonLabel to my matchingExactLabel(currentButton, my dismissButtonNames)
			if dismissButtonLabel is not missing value then
				if my matchesAutomationInfobar(infobarLabel, bannerText, dismissButtonLabel) then
					my dismissAutomationBanner(currentButton, processRef, processName)
					return true
				end if
			end if
		end repeat
	end if

	set childRefs to {}
	tell application "System Events"
		try
			set childRefs to UI elements of theElement
		end try
	end tell
	repeat with childRef in childRefs
		if my inspectAutomationInfobar(contents of childRef, processRef, processName, currentDepth + 1) then return true
	end repeat
	return false
end inspectAutomationInfobar

on inspectStandaloneWindow(theWindow, processRef, processName)
	set windowSubrole to ""
	set windowWidth to 0
	set windowHeight to 0
	set unnamedWindow to true
	tell application "System Events"
		try
			set windowSubrole to (subrole of theWindow) as text
		end try
		try
			set windowSize to size of theWindow
			set windowWidth to item 1 of windowSize as integer
			set windowHeight to item 2 of windowSize as integer
		end try
		try
			set windowName to name of theWindow
			if windowName is not missing value and (windowName as text) is not "" then set unnamedWindow to false
		end try
	end tell

	set isSmallUnknownWindow to false
	ignoring case
		if windowSubrole is "AXUnknown" and windowWidth > 0 and windowHeight > 0 and windowWidth < 600 and windowHeight < 600 then set isSmallUnknownWindow to true
	end ignoring
	if isSmallUnknownWindow then
		my inspectContainer(theWindow, processRef, processName, "small-window")
	else if unnamedWindow then
		my inspectContainer(theWindow, processRef, processName, "unnamed-window")
	end if
end inspectStandaloneWindow

on inspectContainer(theContainer, processRef, processName, containerKind)
	set dialogText to my collectAccessibilityText(theContainer, 0)
	if not my matchesDialogTerms(dialogText) then return

	set buttonRefs to my collectButtonReferences(theContainer, 0)
	set allowButtonRef to missing value
	set hasDenyButton to false
	repeat with buttonRef in buttonRefs
		set currentButton to contents of buttonRef
		if allowButtonRef is missing value and my elementHasExactLabel(currentButton, my allowButtonNames) then set allowButtonRef to currentButton
		if my elementHasExactLabel(currentButton, my denyButtonNames) then set hasDenyButton to true
	end repeat
	if allowButtonRef is missing value then return
	if containerKind is "unnamed-window" and not hasDenyButton then return

	my performApproval(allowButtonRef, processRef, processName, containerKind)
end inspectContainer

on collectAccessibilityText(theElement, currentDepth)
	if currentDepth > maximumTreeDepth then return ""
	set collectedText to ""
	set childRefs to {}
	tell application "System Events"
		try
			set elementName to name of theElement
			if elementName is not missing value then set collectedText to collectedText & " " & (elementName as text)
		end try
		try
			set elementValue to value of theElement
			if elementValue is not missing value then set collectedText to collectedText & " " & (elementValue as text)
		end try
		try
			set elementDescription to description of theElement
			if elementDescription is not missing value then set collectedText to collectedText & " " & (elementDescription as text)
		end try
		try
			set childRefs to UI elements of theElement
		end try
	end tell

	repeat with childRef in childRefs
		set collectedText to collectedText & " " & my collectAccessibilityText(contents of childRef, currentDepth + 1)
	end repeat
	return collectedText
end collectAccessibilityText

on collectButtonReferences(theElement, currentDepth)
	if currentDepth > maximumTreeDepth then return {}
	set collectedButtons to {}
	set directButtons to {}
	set childRefs to {}
	tell application "System Events"
		try
			set directButtons to buttons of theElement
		end try
		try
			set childRefs to UI elements of theElement
		end try
	end tell
	repeat with buttonRef in directButtons
		set end of collectedButtons to contents of buttonRef
	end repeat
	repeat with childRef in childRefs
		set collectedButtons to collectedButtons & my collectButtonReferences(contents of childRef, currentDepth + 1)
	end repeat
	return collectedButtons
end collectButtonReferences

on elementHasExactLabel(theElement, expectedLabels)
	set matchedLabel to my matchingExactLabel(theElement, expectedLabels)
	return matchedLabel is not missing value
end elementHasExactLabel

on matchingExactLabel(theElement, expectedLabels)
	set foundLabels to {}
	tell application "System Events"
		try
			set elementName to name of theElement
			if elementName is not missing value then set end of foundLabels to (elementName as text)
		end try
		try
			set elementDescription to description of theElement
			if elementDescription is not missing value then set end of foundLabels to (elementDescription as text)
		end try
		try
			set elementValue to value of theElement
			if elementValue is not missing value then set end of foundLabels to (elementValue as text)
		end try
	end tell

	repeat with foundLabelRef in foundLabels
		set foundLabel to contents of foundLabelRef as text
		if my textIsOneOf(foundLabel, expectedLabels) then return foundLabel
	end repeat
	return missing value
end matchingExactLabel

on performApproval(targetButton, processRef, processName, containerKind)
	if cooldownTicksRemaining > 0 then return
	set cooldownTicksRemaining to cooldownLengthTicks

	if dryRunEnabled then
		my logMessage("Matched " & containerKind & " in " & processName & "; would click Allow (dry-run).")
		return
	end if

	try
		tell application "System Events" to click targetButton
		my logMessage("Clicked Allow in " & processName & " without activating Chrome.")
	on error clickError number clickErrorNumber
		if focusStealEnabled then
			try
				tell application "System Events" to set frontmost of processRef to true
				tell application "System Events" to click targetButton
				my logMessage("Clicked Allow in " & processName & " after explicit focus-steal fallback.")
			on error retryError number retryErrorNumber
				my logMessage("Click failed in " & processName & " (" & (retryErrorNumber as text) & "): " & retryError)
			end try
		else
			my logMessage("Click failed in " & processName & " (" & (clickErrorNumber as text) & "); retrying after cooldown: " & clickError)
		end if
	end try
end performApproval

on dismissAutomationBanner(targetButton, processRef, processName)
	if cooldownTicksRemaining > 0 then return
	set cooldownTicksRemaining to cooldownLengthTicks

	if dryRunEnabled then
		my logMessage("Matched automation info bar in " & processName & "; would click its Close button (dry-run).")
		return
	end if

	try
		tell application "System Events" to click targetButton
		my logMessage("Dismissed automation info bar in " & processName & " without activating Chrome.")
	on error clickError number clickErrorNumber
		if focusStealEnabled then
			try
				tell application "System Events" to set frontmost of processRef to true
				tell application "System Events" to click targetButton
				my logMessage("Dismissed automation info bar in " & processName & " after explicit focus-steal fallback.")
			on error retryError number retryErrorNumber
				my logMessage("Dismissal failed in " & processName & " (" & (retryErrorNumber as text) & "): " & retryError)
			end try
		else
			my logMessage("Dismissal failed in " & processName & " (" & (clickErrorNumber as text) & "); retrying after cooldown: " & clickError)
		end if
	end try
end dismissAutomationBanner

on logMessage(messageText)
	log messageText
end logMessage
