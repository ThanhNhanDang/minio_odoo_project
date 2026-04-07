//go:build !windows

package dialog

import (
	"github.com/ncruces/zenity"
)

// pickFolder falls back to zenity on non-Windows platforms.
func pickFolder() (string, error) {
	path, err := zenity.SelectFile(zenity.Directory())
	if err == zenity.ErrCanceled {
		return "", nil
	}
	return path, err
}

// pickFiles falls back to zenity on non-Windows platforms.
func pickFiles() ([]string, error) {
	paths, err := zenity.SelectFileMultiple()
	if err == zenity.ErrCanceled {
		return nil, nil
	}
	return paths, err
}
