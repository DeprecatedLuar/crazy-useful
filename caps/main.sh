#!/usr/bin/env sh
BIN="$HOME/.cache/caps-toggle"

if [ ! -f "$BIN" ]; then
    src=$(mktemp caps_XXXXXX.go)
    cat > "$src" << 'EOF'
package main

import (
	"os"
	"syscall"
	"time"
	"unsafe"
)

const (
	uiSetEvbit   = 0x40045564
	uiSetKeybit  = 0x40045565
	uiDevSetup   = 0x405c5503
	uiDevCreate  = 0x5501
	uiDevDestroy = 0x5502
	evSyn        = 0
	evKey        = 1
	synReport    = 0
	keyCaps      = 58
	busUSB       = 3
)

type inputID struct{ Bustype, Vendor, Product, Version uint16 }
type uinputSetup struct {
	ID           inputID
	Name         [80]byte
	FFEffectsMax uint32
}
type inputEvent struct {
	Sec, Usec    int64
	Type, Code   uint16
	Value        int32
}

func ioctl(fd, req, arg uintptr) {
	syscall.Syscall(syscall.SYS_IOCTL, fd, req, arg)
}

func emit(f *os.File, typ, code uint16, val int32) {
	ev := inputEvent{Type: typ, Code: code, Value: val}
	f.Write((*[24]byte)(unsafe.Pointer(&ev))[:])
}

func main() {
	f, err := os.OpenFile("/dev/uinput", os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		panic(err)
	}
	defer f.Close()
	fd := f.Fd()

	ioctl(fd, uiSetEvbit, evKey)
	ioctl(fd, uiSetKeybit, keyCaps)

	var setup uinputSetup
	setup.ID = inputID{Bustype: busUSB, Vendor: 1, Product: 1}
	copy(setup.Name[:], "caps-toggle")
	ioctl(fd, uiDevSetup, uintptr(unsafe.Pointer(&setup)))
	ioctl(fd, uiDevCreate, 0)
	time.Sleep(50 * time.Millisecond)

	emit(f, evKey, keyCaps, 1)
	emit(f, evSyn, synReport, 0)
	emit(f, evKey, keyCaps, 0)
	emit(f, evSyn, synReport, 0)
	time.Sleep(10 * time.Millisecond)

	ioctl(fd, uiDevDestroy, 0)
}
EOF
    go build -o "$BIN" "$src"
    rm -f "$src"
fi

exec "$BIN"
