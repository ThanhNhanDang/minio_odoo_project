//go:build windows

//go:generate goversioninfo -64 -o resource.syso

package main

// hideConsoleWindow is a no-op — console hiding temporarily disabled.
// ebitengine/hideconsole's FreeConsole() interferes with systray init.
func hideConsoleWindow() {}
