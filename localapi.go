// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

package main

/*
#include "tailscale.h"
#include <errno.h>
void tailscale_localapi_deliver(tailscale_localapi_callback callback, uint64_t context,
    int event, int status, const void *bytes, size_t length);
*/
import "C"

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
)

// NOVA_MOD: LocalAPI uses tsnet's in-process client. No Loopback(), socketpair,
// OS pipe, or network listener is involved in Swift's control-plane transport.
const (
	localAPIHeaders  = 1
	localAPIData     = 2
	localAPIComplete = 3
	localAPIMaxBytes = 32 << 20
)

type localAPIEvent struct {
	kind   int
	status int
	data   []byte
}

type localAPIOperation struct {
	owner  *server
	cancel context.CancelCauseFunc
}

var localAPIOperations = struct {
	sync.Mutex
	next   uint64
	active map[uint64]*localAPIOperation
}{active: make(map[uint64]*localAPIOperation)}

// Registration shares the server-map lock with TsnetClose. A request either
// belongs to the live node and is cancelled by its close, or fails with EBADF.
func startLocalAPIOperation(sd int32, method, path string, body []byte, timeout time.Duration,
	watchMask *ipn.NotifyWatchOpt, emit func(localAPIEvent)) (uint64, error) {
	if timeout <= 0 || timeout > 24*time.Hour || len(body) > localAPIMaxBytes {
		return 0, syscall.EINVAL
	}
	u, err := url.ParseRequestURI(path)
	if err != nil || u.IsAbs() || u.Host != "" || !strings.HasPrefix(u.Path, "/localapi/v0/") || strings.ContainsAny(path, "\x00\r\n") {
		return 0, syscall.EINVAL
	}
	if watchMask != nil && (method != http.MethodGet || u.Path != "/localapi/v0/watch-ipn-bus") {
		return 0, syscall.EINVAL
	}
	switch method {
	case http.MethodGet, http.MethodPost, http.MethodPatch, http.MethodPut, http.MethodDelete:
	default:
		return 0, syscall.EINVAL
	}
	servers.mu.Lock()
	s := servers.m[C.int(sd)]
	if s == nil || !s.started.Load() {
		servers.mu.Unlock()
		return 0, syscall.EBADF
	}
	ctx, cancel := context.WithCancelCause(context.Background())
	localAPIOperations.Lock()
	localAPIOperations.next++
	id := localAPIOperations.next
	localAPIOperations.active[id] = &localAPIOperation{owner: s, cancel: cancel}
	localAPIOperations.Unlock()
	servers.mu.Unlock()

	go func() {
		// Requests have an overall deadline. Watches have a startup deadline,
		// removed after the initial snapshot (when requested); an idle/suspended subscription has no TTL.
		timer := time.AfterFunc(timeout, func() { cancel(context.DeadlineExceeded) })
		err := runLocalAPIOperation(ctx, s, method, path, body, watchMask, timer.Stop, emit)
		timer.Stop()
		if cause := context.Cause(ctx); cause != nil {
			err = cause
		}
		cancel(context.Canceled)
		localAPIOperations.Lock()
		delete(localAPIOperations.active, id)
		localAPIOperations.Unlock()
		terminal := localAPIEvent{kind: localAPIComplete}
		if err != nil {
			terminal.status = localAPIErrorCode(err)
			terminal.data = []byte(err.Error())
		}
		// Exactly one final callback, including cancellation and node shutdown.
		emit(terminal)
	}()
	return id, nil
}

func runLocalAPIOperation(ctx context.Context, s *server, method, path string, body []byte,
	watchMask *ipn.NotifyWatchOpt, stopStartupTimer func() bool, emit func(localAPIEvent)) error {
	lc, err := s.s.LocalClient()
	if err != nil {
		return err
	}
	return runLocalAPIClient(ctx, lc, method, path, body, watchMask, stopStartupTimer, emit)
}

func runLocalAPIClient(ctx context.Context, lc *local.Client, method, path string, body []byte,
	watchMask *ipn.NotifyWatchOpt, stopStartupTimer func() bool, emit func(localAPIEvent)) error {
	if watchMask != nil {
		watch, err := lc.WatchIPNBus(ctx, *watchMask)
		if err != nil {
			return err
		}
		defer watch.Close()
		if *watchMask&ipn.NotifyInitialState == 0 {
			stopStartupTimer()
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		emit(localAPIEvent{kind: localAPIHeaders, status: http.StatusOK})
		for {
			notify, err := watch.Next()
			if err != nil {
				return err
			}
			stopStartupTimer()
			data, err := json.Marshal(notify)
			if err != nil {
				return err
			}
			if len(data) > localAPIMaxBytes {
				return syscall.EFBIG
			}
			if err := ctx.Err(); err != nil {
				return err
			}
			emit(localAPIEvent{kind: localAPIData, data: data})
		}
	}
	req, err := http.NewRequestWithContext(ctx, method, "http://local-tailscaled.sock"+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	if len(body) > 0 {
		req.Header.Set("Content-Type", "application/json")
	}
	res, err := lc.DoLocalRequest(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	emit(localAPIEvent{kind: localAPIHeaders, status: res.StatusCode})
	data, err := io.ReadAll(io.LimitReader(res.Body, localAPIMaxBytes+1))
	if err != nil {
		return err
	}
	if len(data) > localAPIMaxBytes {
		return syscall.EFBIG
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	emit(localAPIEvent{kind: localAPIData, data: data})
	return nil
}

func localAPIErrorCode(err error) int {
	switch {
	case errors.Is(err, context.Canceled):
		return int(syscall.ECANCELED)
	case errors.Is(err, context.DeadlineExceeded):
		return int(syscall.ETIMEDOUT)
	}
	var code syscall.Errno
	if errors.As(err, &code) {
		return int(code)
	}
	return int(syscall.EIO)
}

func cancelLocalAPIOperation(id uint64) {
	localAPIOperations.Lock()
	op := localAPIOperations.active[id]
	localAPIOperations.Unlock()
	if op != nil {
		op.cancel(context.Canceled)
	}
}

func cancelNodeLocalAPIOperations(s *server) {
	localAPIOperations.Lock()
	defer localAPIOperations.Unlock()
	for _, op := range localAPIOperations.active {
		if op.owner == s {
			op.cancel(syscall.EBADF)
		}
	}
}

//export TsnetLocalAPIStart
func TsnetLocalAPIStart(sd C.int, method, path *C.char, body unsafe.Pointer, bodyLen C.size_t,
	timeoutMS C.int, watchMask C.longlong, callback C.tailscale_localapi_callback, callbackContext C.uint64_t, idOut *C.uint64_t) C.int {
	if method == nil || path == nil || callback == nil || idOut == nil || bodyLen > localAPIMaxBytes || (bodyLen != 0 && body == nil) {
		return C.EINVAL
	}
	*idOut = 0
	var mask *ipn.NotifyWatchOpt
	if watchMask >= 0 {
		value := ipn.NotifyWatchOpt(watchMask)
		mask = &value
	}
	// Copy caller memory before returning; asynchronous Go work never retains
	// Swift's argument buffers. Callback bytes are borrowed only during delivery.
	data := C.GoBytes(body, C.int(bodyLen))
	id, err := startLocalAPIOperation(int32(sd), C.GoString(method), C.GoString(path), data,
		time.Duration(timeoutMS)*time.Millisecond, mask, func(event localAPIEvent) {
			var ptr unsafe.Pointer
			if len(event.data) != 0 {
				ptr = unsafe.Pointer(&event.data[0])
			}
			C.tailscale_localapi_deliver(callback, callbackContext, C.int(event.kind), C.int(event.status), ptr, C.size_t(len(event.data)))
		})
	if err != nil {
		return C.int(localAPIErrorCode(fmt.Errorf("start LocalAPI: %w", err)))
	}
	*idOut = C.uint64_t(id)
	return 0
}

//export TsnetLocalAPICancel
func TsnetLocalAPICancel(id C.uint64_t) { cancelLocalAPIOperation(uint64(id)) }
