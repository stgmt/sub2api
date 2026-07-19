Option Explicit

Dim shell, command, index, exitCode

If WScript.Arguments.Count = 0 Then
  WScript.Quit 64
End If

command = QuoteArgument(WScript.Arguments(0))
For index = 1 To WScript.Arguments.Count - 1
  command = command & " " & QuoteArgument(WScript.Arguments(index))
Next

Set shell = CreateObject("WScript.Shell")
exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode

Function QuoteArgument(value)
  Dim quote
  quote = Chr(34)
  QuoteArgument = quote & Replace(CStr(value), quote, quote & quote) & quote
End Function
