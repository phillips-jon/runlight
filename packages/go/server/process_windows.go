//go:build windows

package server

import "os"

// running is whether a process with this id is running. Windows answers
// FindProcess only for a process that exists.
func running(pid int) bool {
	p, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	p.Release()
	return true
}

// inode is 0 on Windows, which has no inodes, so a rotation shows itself by
// the log's first bytes alone.
func inode(os.FileInfo) uint64 { return 0 }
