package dialog

// PickFolder opens a native folder picker dialog and returns the selected path.
// Returns ("", nil) if the user canceled.
func PickFolder() (string, error) {
	return pickFolder()
}

// PickFiles opens a native multi-file picker dialog and returns selected paths.
// Returns (nil, nil) if the user canceled.
func PickFiles() ([]string, error) {
	return pickFiles()
}
