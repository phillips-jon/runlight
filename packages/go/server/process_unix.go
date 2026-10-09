//go:build !windows

package server

import (
	"errors"
	"os"
	"syscall"
)

// running is whether a process with this id is running on this machine.
func running(pid int) bool {
	err := syscall.Kill(pid, 0)
	// EPERM: it runs, as someone else.
	return err == nil || errors.Is(err, syscall.EPERM)
}

// inode is a file's inode number, which a rename keeps and a new file does not.
func inode(info os.FileInfo) uint64 {
	if stat, ok := info.Sys().(*syscall.Stat_t); ok {
		return uint64(stat.Ino)
	}
	return 0
}
