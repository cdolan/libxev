//! Backend to use kqueue. This is currently only tested on macOS but
//! support for BSDs is planned (if it doesn't already work).
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const os = std.os;
const queue = @import("../queue.zig");
const queue_mpsc = @import("../queue_mpsc.zig");
const heap = @import("../heap.zig");
const main = @import("../main.zig");
const xev = main.Kqueue;
const ThreadPool = main.ThreadPool;

const log = std.log.scoped(.libxev_kqueue);

pub const Loop = struct {
    const TimerHeap = heap.Intrusive(Timer, void, Timer.less);
    const TaskCompletionQueue = queue_mpsc.Intrusive(Completion);

    /// The fd of the kqueue.
    kqueue_fd: os.fd_t,

    /// The mach port that this kqueue always has a filter for. Writing
    /// an empty message to this port can be used to wake up the loop
    /// at any time. Waking up the loop via this port won't trigger any
    /// particular completion, it just forces tick to cycle.
    mach_port: os.system.mach_port_name_t,
    mach_port_buffer: [32]u8 = undefined,

    /// The number of active completions. This DOES NOT include completions that
    /// are queued in the submissions queue.
    active: usize = 0,

    /// Our queue of submissions that we want to enqueue on the next tick.
    /// These are NOT started, they are NOT submitted to kqueue. They are
    /// pending.
    submissions: queue.Intrusive(Completion) = .{},

    /// The queue of cancellation requests. These will point to the
    /// completion that we need to cancel. We don't queue the exact completion
    /// to cancel because it may be in another queue.
    cancellations: queue.Intrusive(Completion) = .{},

    /// Our queue of completed completions where the callback hasn't been
    /// called yet, but the "result" field should be set on every completion.
    /// This is used to delay completion callbacks until the next tick.
    /// Values in the completion queue must not be in the kqueue.
    completions: queue.Intrusive(Completion) = .{},

    /// Heap of timers. We use heaps instead of the EVFILT_TIMER because
    /// it avoids a lot of syscalls in the case where there are a LOT of
    /// timers.
    timers: TimerHeap = .{ .context = {} },

    /// The thread pool to use for blocking operations that kqueue can't do.
    thread_pool: ?*ThreadPool,

    /// The MPSC queue for completed completions from the thread pool.
    thread_pool_completions: TaskCompletionQueue,

    /// Cached time
    cached_now: os.timespec,

    /// Some internal fields we can pack for better space.
    flags: packed struct {
        /// True once it is initialized.
        init: bool = false,

        /// Whether we're in a run or not (to prevent nested runs).
        in_run: bool = false,

        /// Whether our loop is in a stopped state or not.
        stopped: bool = false,
    } = .{},

    /// Initialize a new kqueue-backed event loop. See the Options docs
    /// for what options matter for kqueue.
    pub fn init(options: xev.Options) !Loop {
        // This creates a new kqueue fd
        const fd = try os.kqueue();
        errdefer os.close(fd);

        // Create our mach port that we use for wakeups.
        const mach_self = os.system.mach_task_self();
        var mach_port: os.system.mach_port_name_t = undefined;
        switch (os.system.getKernError(os.system.mach_port_allocate(
            mach_self,
            @enumToInt(os.system.MACH_PORT_RIGHT.RECEIVE),
            &mach_port,
        ))) {
            .SUCCESS => {}, // Success
            else => return error.MachPortAllocFailed,
        }
        errdefer _ = os.system.mach_port_deallocate(mach_self, mach_port);

        var res: Loop = .{
            .kqueue_fd = fd,
            .mach_port = mach_port,
            .thread_pool = options.thread_pool,
            .thread_pool_completions = undefined,
            .cached_now = undefined,
        };
        res.update_now();
        return res;
    }

    /// Deinitialize the loop, this closes the kqueue. Any events that
    /// were unprocessed are lost -- their callbacks will never be called.
    pub fn deinit(self: *Loop) void {
        os.close(self.kqueue_fd);
        _ = os.system.mach_port_deallocate(
            os.system.mach_task_self(),
            self.mach_port,
        );
    }

    /// Stop the loop. This can only be called from the main thread.
    /// This will stop the loop forever. Future ticks will do nothing.
    ///
    /// This does NOT stop any completions that are queued to be executed
    /// in the thread pool. If you are using a thread pool, completions
    /// are not safe to recover until the thread pool is shut down. If
    /// you're not using a thread pool, all completions are safe to
    /// read/write once any outstanding `run` or `tick` calls are returned.
    pub fn stop(self: *Loop) void {
        self.flags.stopped = true;
    }

    /// Add a completion to the loop. The completion is not started until
    /// the loop is run (`run`, `tick`) or an explicit submission request
    /// is made (`submit`).
    pub fn add(self: *Loop, completion: *Completion) void {
        // If this is a cancellation, we special case it and add it to
        // a separate queue so we can handle them first.
        if (completion.op == .cancel) {
            assert(!self.start(completion, undefined));
            return;
        }

        // We just add the completion to the queue. Failures can happen
        // at submission or tick time.
        completion.flags.state = .adding;
        self.submissions.push(completion);
    }

    /// Submit any enqueue completions. This does not fire any callbacks
    /// for completed events (success or error). Callbacks are only fired
    /// on the next tick.
    ///
    /// If an error is returned, some events might be lost. Errors are
    /// exceptional and should generally not happen. If we could recover
    /// which completions were not submitted and restore them we would,
    /// but the kqueue API doesn't provide that level of clarity.
    pub fn submit(self: *Loop) !void {
        // We try to submit as many events at once as we can.
        var events: [256]Kevent = undefined;
        var events_len: usize = 0;

        // Submit all the submissions. We copy the submission queue so that
        // any resubmits don't cause an infinite loop.
        var queued = self.submissions;
        self.submissions = .{};

        // On error, we have to restore the queue because we may be batching.
        errdefer self.submissions = queued;

        while (true) {
            queue_pop: while (queued.pop()) |c| {
                switch (c.flags.state) {
                    // If we're adding then we start the event.
                    .adding => if (self.start(c, &events[events_len])) {
                        events_len += 1;
                        if (events_len >= events.len) break :queue_pop;
                    },

                    // If we're deleting then we create a deletion event and
                    // queue the completion to notify cancellation.
                    .deleting => if (c.kevent()) |ev| {
                        c.result = c.syscall_result(-1 * @intCast(i32, @enumToInt(os.system.E.CANCELED)));
                        c.flags.state = .dead;
                        self.completions.push(c);

                        events[events_len] = ev;
                        events[events_len].flags = os.system.EV_DELETE;
                        events_len += 1;
                        if (events_len >= events.len) break :queue_pop;
                    },

                    // This is set if the completion was canceled while in the
                    // submission queue. This is a special case where we still
                    // want to call the callback to tell it it was canceled.
                    .dead => self.stop_completion(c),

                    // Shouldn't happen if our logic is all correct.
                    .active => log.err(
                        "invalid state in submission queue state={}",
                        .{c.flags.state},
                    ),
                }
            }

            // If we have no events then we have to have gone through the entire
            // submission queue and we're done.
            if (events_len == 0) break;

            // Zero timeout so that kevent returns immediately.
            var timeout = std.mem.zeroes(os.timespec);
            const completed = try kevent_syscall(
                self.kqueue_fd,
                events[0..events_len],
                events[0..events.len],
                &timeout,
            );
            events_len = 0;

            // Go through the completed events and queue them.
            // NOTE: we currently never process completions (we set
            // event list to zero length) because it was leading to
            // memory corruption we need to investigate.
            for (events[0..completed]) |ev| {
                const c = @intToPtr(*Completion, @intCast(usize, ev.udata));

                // We handle deletions separately.
                if (ev.flags & os.system.EV_DELETE != 0) continue;

                // If EV_ERROR is set, then submission failed for this
                // completion. We get the syscall errorcode from data and
                // store it.
                if (ev.flags & os.system.EV_ERROR != 0) {
                    c.result = c.syscall_result(@intCast(i32, ev.data));

                    // We reset the state so that we know that it never
                    // registered with kevent.
                    c.flags.state = .adding;
                } else {
                    // No error, means that this completion is ready to work.
                    c.result = c.perform(&ev);
                }

                assert(c.result != null);
                self.completions.push(c);
            }
        }
    }

    /// Process the cancellations queue. This doesn't call any callbacks
    /// or perform any syscalls. This just shuffles state around and sets
    /// things up for cancellation to occur.
    fn process_cancellations(self: *Loop) void {
        while (self.cancellations.pop()) |c| {
            const target = c.op.cancel.c;
            switch (target.flags.state) {
                // If the target is dead already we do nothing.
                .dead => {},

                // If the targeting is in the process of being removed
                // from the kqueue we do nothing because its already done.
                .deleting => {},

                // If they are in the submission queue, mark them as dead
                // so they will never be submitted.
                .adding => target.flags.state = .dead,

                // If it is active we need to schedule the deletion.
                .active => self.stop_completion(target),
            }

            // We completed the cancellation.
            c.result = .{ .cancel = {} };
            self.completions.push(c);
        }
    }

    /// Run the event loop. See RunMode documentation for details on modes.
    /// Once the loop is run, the pointer MUST remain stable.
    pub fn run(self: *Loop, mode: xev.RunMode) !void {
        switch (mode) {
            .no_wait => try self.tick(0),
            .once => try self.tick(1),
            .until_done => while (!self.done()) try self.tick(1),
        }
    }

    /// Tick through the event loop once, waiting for at least "wait" completions
    /// to be processed by the loop itself.
    pub fn tick(self: *Loop, wait: u32) !void {
        // If we're stopped then the loop is fully over.
        if (self.flags.stopped) return;

        // We can't nest runs.
        if (self.flags.in_run) return error.NestedRunsNotAllowed;
        self.flags.in_run = true;
        defer self.flags.in_run = false;

        // Initialize
        if (!self.flags.init) {
            self.flags.init = true;

            if (self.thread_pool != null) {
                self.thread_pool_completions.init();
            }

            // Add our event so that we wake up when our mach port receives an
            // event. We have to add here because we need a stable self pointer.
            const events = [_]Kevent{.{
                .ident = @intCast(usize, self.mach_port),
                .filter = os.system.EVFILT_MACHPORT,
                .flags = os.system.EV_ADD | os.system.EV_ENABLE,
                .fflags = os.system.MACH_RCV_MSG,
                .data = 0,
                .udata = 0,
                .ext = .{
                    @ptrToInt(&self.mach_port_buffer),
                    self.mach_port_buffer.len,
                },
            }};
            const n = kevent_syscall(
                self.kqueue_fd,
                &events,
                events[0..0],
                null,
            ) catch |err| {
                // We reset initialization because we can't do anything
                // safely unless we get this mach port registered!
                self.flags.init = false;
                return err;
            };
            assert(n == 0);
        }

        // The list of events, used as both a changelist and eventlist.
        var events: [256]Kevent = undefined;

        // The number of events in the events array to submit as changes
        // on repeat ticks. Used mostly for efficient disarm.
        var changes: usize = 0;

        var wait_rem = @intCast(usize, wait);

        // Handle all of our cancellations first because we may be able
        // to stop submissions from even happening if its still queued.
        // Plus, cancellations sometimes add more to the submission queue
        // (to remove from kqueue)
        self.process_cancellations();

        // TODO(mitchellh): an optimization in the future is for the last
        // batch of submissions to return the changelist, because we can
        // reuse that for the kevent call later...
        try self.submit();

        // Explaining the loop condition: we want to loop only if we have
        // active handles (because it means we have something to do)
        // and we have stuff we want to wait for still (wait_rem > 0) or
        // we requested just a nowait tick (because we have to loop at least
        // once).
        //
        // We also loop if there are any requested changes. Requested
        // changes are only ever deletions currently, so we just process
        // those until we have no more.
        while (true) {
            // If we're stopped then the loop is fully over.
            if (self.flags.stopped) return;

            // We must update our time no matter what
            self.update_now();

            // NOTE(mitchellh): This is a hideous boolean statement we should
            // clean it up.
            if (!((self.active > 0 and (wait == 0 or wait_rem > 0)) or
                changes > 0 or
                !self.completions.empty())) break;

            // Run our expired timers
            const now_timer: Timer = .{ .next = self.cached_now };
            while (self.timers.peek()) |t| {
                if (!Timer.less({}, t, &now_timer)) break;

                // Remove the timer
                assert(self.timers.deleteMin().? == t);

                // Mark completion as done
                const c = t.c;
                c.flags.state = .dead;

                // We mark it as inactive here because if we rearm below
                // the start() function will reincrement this.
                self.active -= 1;

                // Lower our remaining count since we have processed something.
                wait_rem -|= 1;

                // Invoke
                const action = c.callback(c.userdata, self, c, .{ .timer = .expiration });
                switch (action) {
                    .disarm => {},

                    // We use undefined as the second param because timers
                    // never set a kevent, and we assert false for the same
                    // reason.
                    .rearm => assert(!self.start(c, undefined)),
                }
            }

            // Migrate our completions from the thread pool MPSC queue to our
            // completion queue.
            // TODO: unify the queues
            if (self.thread_pool != null) {
                while (self.thread_pool_completions.pop()) |c| {
                    self.completions.push(c);
                }
            }

            // Process the completions we already have completed.
            while (self.completions.pop()) |c| {
                // disarm_ev is the Kevent to use for disarming if the
                // completion wants to disarm. We have to calculate this up
                // front because c can be reused in callback.
                const disarm_ev: ?Kevent = ev: {
                    // If we're not active then we were never part of the kqueue.
                    // If we are part of a threadpool we also never were part
                    // of the kqueue.
                    if (c.flags.state != .active or
                        c.flags.threadpool) break :ev null;

                    break :ev c.kevent();
                };

                // We store whether this completion was active so we can decrement
                // the active count later
                const c_active = c.flags.state == .active;
                c.flags.state = .dead;

                // Decrease our waiters because we are definitely processing one.
                wait_rem -|= 1;

                // Completion queue items MUST have a result set.
                const action = c.callback(c.userdata, self, c, c.result.?);
                switch (action) {
                    // If we're active we have to schedule a delete. Otherwise
                    // we do nothing because we were never part of the kqueue.
                    .disarm => {
                        if (disarm_ev) |ev| {
                            events[changes] = ev;
                            events[changes].flags = os.system.EV_DELETE;
                            events[changes].udata = 0;
                            changes += 1;
                            assert(changes <= events.len);
                        }

                        if (c_active) self.active -= 1;
                    },

                    // Only resubmit if we aren't already active (in the queue)
                    .rearm => if (!c_active) self.submissions.push(c),
                }
            }

            // Determine our next timeout based on the timers
            const timeout: ?os.timespec = timeout: {
                if (wait_rem == 0) break :timeout std.mem.zeroes(os.timespec);

                // If we have a timer, we want to set the timeout to our next
                // timer value. If we have no timer, we wait forever.
                const t = self.timers.peek() orelse break :timeout null;

                // Determine the time in milliseconds.
                const ms_now = @intCast(u64, self.cached_now.tv_sec) * std.time.ms_per_s +
                    @intCast(u64, self.cached_now.tv_nsec) / std.time.ns_per_ms;
                const ms_next = @intCast(u64, t.next.tv_sec) * std.time.ms_per_s +
                    @intCast(u64, t.next.tv_nsec) / std.time.ns_per_ms;
                const ms = ms_next -| ms_now;

                break :timeout .{
                    .tv_sec = @intCast(isize, ms / std.time.ms_per_s),
                    .tv_nsec = @intCast(isize, ms % std.time.ms_per_s),
                };
            };

            // Wait for changes. Note that we ALWAYS attempt to get completions
            // back even if are done waiting (wait_rem == 0) because if we have
            // to make a syscall to submit changes, we might as well also check
            // for done events too.
            const completed = completed: while (true) {
                break :completed kevent_syscall(
                    self.kqueue_fd,
                    events[0..changes],
                    events[0..events.len],
                    if (timeout) |*t| t else null,
                ) catch |err| switch (err) {
                    // This should never happen because we always have
                    // space in our event list. If I'm reading the BSD source
                    // right (and Apple does something similar...) then ENOENT
                    // is always put into the eventlist if there is space:
                    // https://github.com/freebsd/freebsd-src/blob/5a4a83fd0e67a0d7787d2f3e09ef0e5552a1ffb6/sys/kern/kern_event.c#L1668
                    error.EventNotFound => unreachable,

                    // Any other error is fatal
                    else => return err,
                };
            };

            // Reset changes since they're not submitted
            changes = 0;

            // Go through the completed events and queue them.
            for (events[0..completed]) |ev| {
                // Zero udata values are internal events that we do nothing
                // on such as the mach port wakeup.
                if (ev.udata == 0) continue;

                // Ignore any successful deletions. This can only happen
                // from disarms below and in that case we already processed
                // their callback.
                if (ev.flags & os.system.EV_DELETE != 0) continue;

                // This can only be set during changelist processing so
                // that means that this event was never actually active.
                // Therefore, we only decrement the waiters by 1 if we
                // processed an active change.
                if (ev.flags & os.system.EV_ERROR != 0) {
                    // We cannot use c here because c is already dead
                    // at this point for this event.
                    continue;
                }
                wait_rem -|= 1;

                const c = @intToPtr(*Completion, @intCast(usize, ev.udata));

                // c is ready to be reused rigt away if we're dearming
                // so we mark it as dead.
                c.flags.state = .dead;

                const result = c.perform(&ev);
                const action = c.callback(c.userdata, self, c, result);
                switch (action) {
                    .disarm => {
                        // Mark this event for deletion, it'll happen
                        // on the next tick.
                        events[changes] = ev;
                        events[changes].flags = os.system.EV_DELETE;
                        events[changes].udata = 0;
                        changes += 1;
                        assert(changes <= events.len);

                        self.active -= 1;
                    },

                    // We rearm by default with kqueue so we just have to make
                    // sure that the state is correct.
                    .rearm => {
                        c.flags.state = .active;
                    },
                }
            }

            // If we ran through the loop once we break if we don't care.
            if (wait == 0) break;
        }
    }

    /// Returns the "loop" time in milliseconds. The loop time is updated
    /// once per loop tick, before IO polling occurs. It remains constant
    /// throughout callback execution.
    ///
    /// You can force an update of the "now" value by calling update_now()
    /// at any time from the main thread.
    ///
    /// The clock that is used is not guaranteed. In general, a monotonic
    /// clock source is always used if available. This value should typically
    /// just be used for relative time calculations within the loop, such as
    /// answering the question "did this happen <x> ms ago?".
    pub fn now(self: *Loop) i64 {
        // If anything overflows we just return the max value.
        const max = std.math.maxInt(i64);

        // Calculate all the values, being careful about overflows in order
        // to just return the maximum value.
        const sec = std.math.mul(isize, self.cached_now.tv_sec, std.time.ms_per_s) catch return max;
        const nsec = @divFloor(self.cached_now.tv_nsec, std.time.ns_per_ms);
        return std.math.lossyCast(i64, sec +| nsec);
    }

    /// Update the cached time.
    pub fn update_now(self: *Loop) void {
        os.clock_gettime(os.CLOCK.MONOTONIC, &self.cached_now) catch {};
    }

    /// Add a timer to the loop. The timer will execute in "next_ms". This
    /// is oneshot: the timer will not repeat. To repeat a timer, either
    /// schedule another in your callback or return rearm from the callback.
    pub fn timer(
        self: *Loop,
        c: *Completion,
        next_ms: u64,
        userdata: ?*anyopaque,
        comptime cb: xev.Callback,
    ) void {
        c.* = .{
            .op = .{
                .timer = .{
                    .next = self.timer_next(next_ms),
                },
            },
            .userdata = userdata,
            .callback = cb,
        };

        self.add(c);
    }

    /// See io_uring.timer_reset for docs.
    pub fn timer_reset(
        self: *Loop,
        c: *Completion,
        c_cancel: *Completion,
        next_ms: u64,
        userdata: ?*anyopaque,
        comptime cb: xev.Callback,
    ) void {
        switch (c.flags.state) {
            .dead, .deleting => {
                self.timer(c, next_ms, userdata, cb);
                return;
            },

            // Adding state we can just modify the metadata and return
            // since the timer isn't in the heap yet.
            .adding => {
                c.op.timer.next = self.timer_next(next_ms);
                c.userdata = userdata;
                c.callback = cb;
                return;
            },

            .active => {
                // Update the reset time for the timer to the desired time
                // along with all the callbacks.
                c.op.timer.reset = self.timer_next(next_ms);
                c.userdata = userdata;
                c.callback = cb;

                // If the cancellation is active, we assume its for this timer
                // and do nothing.
                if (c_cancel.state() == .active) return;
                assert(c_cancel.state() == .dead and c.state() == .active);
                c_cancel.* = .{ .op = .{ .cancel = .{ .c = c } } };
                self.add(c_cancel);
            },
        }
    }

    fn timer_next(self: Loop, next_ms: u64) std.os.timespec {
        // Get the timestamp of the absolute time that we'll execute this timer.
        // There are lots of failure scenarios here in math. If we see any
        // of them we just use the maximum value.
        const max: std.os.timespec = .{
            .tv_sec = std.math.maxInt(isize),
            .tv_nsec = std.math.maxInt(isize),
        };

        const next_s = std.math.cast(isize, next_ms / std.time.ms_per_s) orelse
            return max;
        const next_ns = std.math.cast(
            isize,
            (next_ms % std.time.ms_per_s) * std.time.ns_per_ms,
        ) orelse return max;

        return .{
            .tv_sec = std.math.add(isize, self.cached_now.tv_sec, next_s) catch
                return max,
            .tv_nsec = std.math.add(isize, self.cached_now.tv_nsec, next_ns) catch
                return max,
        };
    }

    fn done(self: *Loop) bool {
        return self.flags.stopped or (self.active == 0 and
            self.submissions.empty() and
            self.completions.empty());
    }

    /// Start the completion. This returns true if the Kevent was set
    /// and should be queued.
    fn start(self: *Loop, c: *Completion, ev: *Kevent) bool {
        const StartAction = union(enum) {
            /// We have set the kevent out parameter
            kevent: void,

            // We are a timer,
            timer: void,

            // We are a cancellation
            cancel: void,

            // We want to run on the threadpool
            threadpool: void,

            /// We have a result code from making a system call now.
            result: i32,
        };

        const action: StartAction = if (c.flags.threadpool) .{
            .threadpool = {},
        } else switch (c.op) {
            .noop => {
                c.flags.state = .dead;
                return false;
            },

            .cancel => action: {
                // Queue the cancel
                break :action .{ .cancel = {} };
            },

            .accept => action: {
                ev.* = c.kevent().?;
                break :action .{ .kevent = {} };
            },

            .connect => |*v| action: {
                while (true) {
                    const result = os.system.connect(v.socket, &v.addr.any, v.addr.getOsSockLen());
                    switch (os.errno(result)) {
                        // Interrupt, try again
                        .INTR => continue,

                        // This means the connect is blocked and in progress.
                        // We register for the write event which will let us know
                        // when it is complete.
                        .AGAIN, .INPROGRESS => {
                            ev.* = c.kevent().?;
                            break :action .{ .kevent = {} };
                        },

                        // Any other error we report
                        else => break :action .{ .result = result },
                    }
                }
            },

            .write => action: {
                ev.* = c.kevent().?;
                break :action .{ .kevent = {} };
            },

            .read => action: {
                ev.* = c.kevent().?;
                break :action .{ .kevent = {} };
            },

            .send => action: {
                ev.* = c.kevent().?;
                break :action .{ .kevent = {} };
            },

            .recv => action: {
                ev.* = c.kevent().?;
                break :action .{ .kevent = {} };
            },

            .sendto => action: {
                ev.* = c.kevent().?;
                break :action .{ .kevent = {} };
            },

            .recvfrom => action: {
                ev.* = c.kevent().?;
                break :action .{ .kevent = {} };
            },

            .machport => action: {
                ev.* = c.kevent().?;
                break :action .{ .kevent = {} };
            },

            .proc => action: {
                ev.* = c.kevent().?;
                break :action .{ .kevent = {} };
            },

            .shutdown => |v| action: {
                const result = os.system.shutdown(v.socket, switch (v.how) {
                    .recv => os.SHUT.RD,
                    .send => os.SHUT.WR,
                    .both => os.SHUT.RDWR,
                });

                break :action .{ .result = result };
            },

            .close => |v| action: {
                std.os.close(v.fd);
                break :action .{ .result = 0 };
            },

            .timer => |*v| action: {
                // Point back to completion since we need this. In the future
                // we want to use @fieldParentPtr but https://github.com/ziglang/zig/issues/6611
                v.c = c;

                // Insert the timer into our heap.
                self.timers.insert(v);

                // We always run timers
                break :action .{ .timer = {} };
            },
        };

        switch (action) {
            .kevent,
            .timer,
            => {
                // Increase our active count so we now wait for this. We
                // assume it'll successfully queue. If it doesn't we handle
                // that later (see submit)
                self.active += 1;
                c.flags.state = .active;

                // We only return true if this is a kevent, since other
                // actions can come in here.
                return action == .kevent;
            },

            .cancel => {
                // We are considered an active completion.
                self.active += 1;
                c.flags.state = .active;

                self.cancellations.push(c);
                return false;
            },

            .threadpool => {
                // We need to mark this completion as active no matter
                // what happens below so that we mark is inactive with
                // completion handling.
                self.active += 1;
                c.flags.state = .active;

                // We need a thread pool otherwise we set an error on
                // our result and queue the completion.
                const pool = self.thread_pool orelse {
                    // We use EPERM as a way to note there is no thread
                    // pool. We can change this in the future if there is
                    // a better choice.
                    c.result = c.syscall_result(@enumToInt(os.E.PERM));
                    self.completions.push(c);
                    return false;
                };

                // Setup our completion state so that the thread can
                // communicate back to our main thread.
                c.task_loop = self;
                c.task = .{ .callback = thread_perform };

                // Schedule it, from this point forward its not safe to touch c.
                pool.schedule(ThreadPool.Batch.from(&c.task));

                return false;
            },

            // A result is immediately available. Queue the completion to
            // be invoked.
            .result => |result| {
                c.result = c.syscall_result(result);
                self.completions.push(c);

                return false;
            },
        }
    }

    fn stop_completion(self: *Loop, c: *Completion) void {
        if (c.flags.state == .active) {
            // If there is a result already, then we're already in the
            // completion queue and we can be done. Items in the completion
            // queue can NOT be in the kqueue too.
            if (c.result != null) return;

            // If this completion has a kevent associated with it, then
            // we must remove the kevent. We remove the kevent by adding it
            // to the submission queue (because its the same syscall) but
            // setting the state to deleting.
            if (c.kevent() != null) {
                c.flags.state = .deleting;
                self.submissions.push(c);
                return;
            }
        }

        // Inspect other operations. WARNING: the state can be ANYTHING
        // here so per op be sure to check the state flag.
        switch (c.op) {
            .timer => |*v| {
                if (c.flags.state == .active) {
                    // Remove from the heap so it never fires...
                    self.timers.remove(v);

                    // If we have reset set AND we got a cancellation result,
                    // that means that we were canceled so that we can update
                    // our expiration time.
                    if (v.reset) |r| {
                        v.next = r;
                        v.reset = null;
                        self.active -= 1;
                        self.add(c);
                        return;
                    }
                }

                // Add to our completions so we trigger the callback.
                c.result = .{ .timer = .cancel };
                self.completions.push(c);

                // Note the timers state purposely remains ACTIVE so that
                // when we process the completion we decrement the
                // active count.
            },

            else => {},
        }
    }

    /// This is the main callback for the threadpool to perform work
    /// on completions for the loop.
    fn thread_perform(t: *ThreadPool.Task) void {
        const c = @fieldParentPtr(Completion, "task", t);

        // Do our task
        c.result = c.perform(null);

        // Add to our completion queue
        c.task_loop.thread_pool_completions.push(c);

        // Wake up our main loop
        c.task_loop.wakeup() catch {};
    }

    /// Sends an empty message to this loop's mach port so that it wakes
    /// up if it is blocking on kevent().
    fn wakeup(self: *Loop) !void {
        // This constructs an empty mach message. It has no data.
        var msg: os.system.mach_msg_header_t = .{
            .msgh_bits = @enumToInt(os.system.MACH_MSG_TYPE.MAKE_SEND_ONCE),
            .msgh_size = @sizeOf(os.system.mach_msg_header_t),
            .msgh_remote_port = self.mach_port,
            .msgh_local_port = os.system.MACH_PORT_NULL,
            .msgh_voucher_port = undefined,
            .msgh_id = undefined,
        };

        return switch (os.system.getMachMsgError(
            os.system.mach_msg(
                &msg,
                os.system.MACH_SEND_MSG,
                msg.msgh_size,
                0,
                os.system.MACH_PORT_NULL,
                os.system.MACH_MSG_TIMEOUT_NONE,
                os.system.MACH_PORT_NULL,
            ),
        )) {
            .SUCCESS => {},
            .SEND_NO_BUFFER => {}, // Buffer full, will wake up
            else => error.MachMsgFailed,
        };
    }
};

/// A completion is a request to perform some work with the loop.
pub const Completion = struct {
    /// Operation to execute.
    op: Operation = .{ .noop = {} },

    /// Userdata and callback for when the completion is finished.
    userdata: ?*anyopaque = null,
    callback: xev.Callback = xev.noopCallback,

    //---------------------------------------------------------------
    // Internal fields

    /// Intrusive queue field
    next: ?*Completion = null,

    /// Result code of the syscall. Only used internally in certain
    /// scenarios, should not be relied upon by program authors.
    result: ?Result = null,

    flags: packed struct {
        /// Watch state of this completion. We use this to determine whether
        /// we're active, adding, deleting, etc. This lets us add and delete
        /// multiple times before a loop tick and handle the state properly.
        state: State = .dead,

        /// Set this to true to schedule this operation on the thread pool.
        /// This can be set by anyone. If the operation is scheduled on
        /// the thread pool then it will NOT be registered with kqueue even
        /// if it is supported.
        threadpool: bool = false,
    } = .{},

    /// If scheduled on a thread pool, this will be set. This is NOT a
    /// reliable way to get access to the loop and shouldn't be used
    /// except internally.
    task: ThreadPool.Task = undefined,
    task_loop: *Loop = undefined,

    const State = enum(u3) {
        /// completion is not part of any loop
        dead = 0,

        /// completion is in the submission queue
        adding = 1,

        /// completion is in the deletion queue
        deleting = 2,

        /// completion is submitted with kqueue successfully
        active = 3,
    };

    /// Returns the state of this completion. There are some things to
    /// be caution about when calling this function.
    ///
    /// First, this is only safe to call from the main thread. This cannot
    /// be called from any other thread.
    ///
    /// Second, if you are using default "undefined" completions, this will
    /// NOT return a valid value if you access it. You must zero your
    /// completion using ".{}". You only need to zero the completion once.
    /// Once the completion is in use, it will always be valid.
    ///
    /// Third, if you stop the loop (loop.stop()), the completions registered
    /// with the loop will NOT be reset to a dead state.
    pub fn state(self: Completion) xev.CompletionState {
        return switch (self.flags.state) {
            .dead => .dead,
            .adding, .deleting, .active => .active,
        };
    }

    /// Returns a kevent for this completion, if any. Note that the
    /// kevent isn't immediately useful for all event types. For example,
    /// "connect" requires you to initiate the connection first.
    fn kevent(self: *Completion) ?Kevent {
        return switch (self.op) {
            .noop => unreachable,

            .cancel,
            .close,
            .timer,
            .shutdown,
            => null,

            .accept => |v| kevent_init(.{
                .ident = @intCast(usize, v.socket),
                .filter = os.system.EVFILT_READ,
                .flags = os.system.EV_ADD | os.system.EV_ENABLE,
                .fflags = 0,
                .data = 0,
                .udata = @ptrToInt(self),
            }),

            .connect => |v| kevent_init(.{
                .ident = @intCast(usize, v.socket),
                .filter = os.system.EVFILT_WRITE,
                .flags = os.system.EV_ADD | os.system.EV_ENABLE,
                .fflags = 0,
                .data = 0,
                .udata = @ptrToInt(self),
            }),

            .machport => kevent: {
                // We can't use |*v| above because it crahses the Zig
                // compiler (as of 0.11.0-dev.1413). We can retry another time.
                const v = &self.op.machport;
                const slice: []u8 = switch (v.buffer) {
                    .slice => |slice| slice,
                    .array => |*arr| arr,
                };

                // The kevent below waits for a machport to have a message
                // available AND automatically reads the message into the
                // buffer since MACH_RCV_MSG is set.
                break :kevent .{
                    .ident = @intCast(usize, v.port),
                    .filter = os.system.EVFILT_MACHPORT,
                    .flags = os.system.EV_ADD | os.system.EV_ENABLE,
                    .fflags = os.system.MACH_RCV_MSG,
                    .data = 0,
                    .udata = @ptrToInt(self),
                    .ext = .{ @ptrToInt(slice.ptr), slice.len },
                };
            },

            .proc => |v| kevent_init(.{
                .ident = @intCast(usize, v.pid),
                .filter = os.system.EVFILT_PROC,
                .flags = os.system.EV_ADD | os.system.EV_ENABLE,
                .fflags = v.flags,
                .data = 0,
                .udata = @ptrToInt(self),
            }),

            inline .write, .send, .sendto => |v| kevent_init(.{
                .ident = @intCast(usize, v.fd),
                .filter = os.system.EVFILT_WRITE,
                .flags = os.system.EV_ADD | os.system.EV_ENABLE,
                .fflags = 0,
                .data = 0,
                .udata = @ptrToInt(self),
            }),

            inline .read, .recv, .recvfrom => |v| kevent_init(.{
                .ident = @intCast(usize, v.fd),
                .filter = os.system.EVFILT_READ,
                .flags = os.system.EV_ADD | os.system.EV_ENABLE,
                .fflags = 0,
                .data = 0,
                .udata = @ptrToInt(self),
            }),
        };
    }

    /// Perform the operation associated with this completion. This will
    /// perform the full blocking operation for the completion.
    fn perform(self: *Completion, ev_: ?*const Kevent) Result {
        return switch (self.op) {
            .cancel,
            .close,
            .noop,
            .timer,
            .shutdown,
            => {
                log.warn("perform op={s}", .{@tagName(self.op)});
                unreachable;
            },

            .accept => |*op| .{
                .accept = if (os.accept(
                    op.socket,
                    &op.addr,
                    &op.addr_size,
                    op.flags,
                )) |v|
                    v
                else |err|
                    err,
            },

            .connect => |*op| .{
                .connect = if (os.getsockoptError(op.socket)) {} else |err| err,
            },

            .write => |*op| .{
                .write = switch (op.buffer) {
                    .slice => |v| os.write(op.fd, v),
                    .array => |*v| os.write(op.fd, v.array[0..v.len]),
                },
            },

            .send => |*op| .{
                .send = switch (op.buffer) {
                    .slice => |v| os.send(op.fd, v, 0),
                    .array => |*v| os.send(op.fd, v.array[0..v.len], 0),
                },
            },

            .sendto => |*op| .{
                .sendto = switch (op.buffer) {
                    .slice => |v| os.sendto(op.fd, v, 0, &op.addr.any, op.addr.getOsSockLen()),
                    .array => |*v| os.sendto(op.fd, v.array[0..v.len], 0, &op.addr.any, op.addr.getOsSockLen()),
                },
            },

            .read => |*op| res: {
                const n_ = switch (op.buffer) {
                    .slice => |v| os.read(op.fd, v),
                    .array => |*v| os.read(op.fd, v),
                };

                break :res .{
                    .read = if (n_) |n|
                        if (n == 0) error.EOF else n
                    else |err|
                        err,
                };
            },

            .recv => |*op| res: {
                const n_ = switch (op.buffer) {
                    .slice => |v| os.recv(op.fd, v, 0),
                    .array => |*v| os.recv(op.fd, v, 0),
                };

                break :res .{
                    .recv = if (n_) |n|
                        if (n == 0) error.EOF else n
                    else |err|
                        err,
                };
            },

            .recvfrom => |*op| res: {
                const n_ = switch (op.buffer) {
                    .slice => |v| os.recvfrom(op.fd, v, 0, &op.addr, &op.addr_size),
                    .array => |*v| os.recvfrom(op.fd, v, 0, &op.addr, &op.addr_size),
                };

                break :res .{
                    .recvfrom = if (n_) |n|
                        if (n == 0) error.EOF else n
                    else |err|
                        err,
                };
            },

            // Our machport operation ALWAYS has MACH_RCV set so there
            // is no operation to perform. kqueue automatically reads in
            // the mach message into the read buffer.
            .machport => .{
                .machport = {},
            },

            // For proc watching, it is identical to the syscall result.
            .proc => res: {
                const ev = ev_ orelse break :res .{ .proc = ProcError.MissingKevent };

                // If we have the exit status, we read it.
                if (ev.fflags & (os.system.NOTE_EXIT | os.system.NOTE_EXITSTATUS) > 0) {
                    const data = @intCast(u32, ev.data);
                    if (os.W.IFEXITED(data)) break :res .{
                        .proc = os.W.EXITSTATUS(data),
                    };
                }

                break :res .{ .proc = 0 };
            },
        };
    }

    /// Returns the error result for the given result code. This is called
    /// in the situation that kqueue fails to enqueue the completion or
    /// a raw syscall fails.
    fn syscall_result(c: *Completion, r: i32) Result {
        const errno = os.errno(r);
        return switch (c.op) {
            .noop => unreachable,

            .accept => .{
                .accept = switch (errno) {
                    .SUCCESS => r,
                    else => |err| os.unexpectedErrno(err),
                },
            },

            .connect => .{
                .connect = switch (errno) {
                    .SUCCESS => {},
                    else => |err| os.unexpectedErrno(err),
                },
            },

            .write => .{
                .write = switch (errno) {
                    .SUCCESS => @intCast(usize, r),
                    else => |err| os.unexpectedErrno(err),
                },
            },

            .read => .{
                .read = switch (errno) {
                    .SUCCESS => if (r == 0) error.EOF else @intCast(usize, r),
                    else => |err| os.unexpectedErrno(err),
                },
            },

            .send => .{
                .send = switch (errno) {
                    .SUCCESS => @intCast(usize, r),
                    else => |err| os.unexpectedErrno(err),
                },
            },

            .recv => .{
                .recv = switch (errno) {
                    .SUCCESS => if (r == 0) error.EOF else @intCast(usize, r),
                    else => |err| os.unexpectedErrno(err),
                },
            },

            .sendto => .{
                .sendto = switch (errno) {
                    .SUCCESS => @intCast(usize, r),
                    else => |err| os.unexpectedErrno(err),
                },
            },

            .recvfrom => .{
                .recvfrom = switch (errno) {
                    .SUCCESS => @intCast(usize, r),
                    else => |err| os.unexpectedErrno(err),
                },
            },

            .machport => .{
                .machport = switch (errno) {
                    .SUCCESS => {},
                    else => |err| os.unexpectedErrno(err),
                },
            },

            .proc => .{
                .proc = switch (errno) {
                    .SUCCESS => @intCast(u32, r),
                    else => |err| os.unexpectedErrno(err),
                },
            },

            .shutdown => .{
                .shutdown = switch (errno) {
                    .SUCCESS => {},
                    else => |err| os.unexpectedErrno(err),
                },
            },

            .close => .{
                .close = switch (errno) {
                    .SUCCESS => {},
                    else => |err| os.unexpectedErrno(err),
                },
            },

            .timer => .{
                .timer = switch (errno) {
                    // Success is impossible because timers don't execute syscalls.
                    .SUCCESS => unreachable,
                    else => |err| os.unexpectedErrno(err),
                },
            },

            .cancel => .{
                .cancel = switch (errno) {
                    .SUCCESS => {},

                    // Syscall errors should not be possible since cancel
                    // doesn't run any syscalls.
                    else => |err| {
                        os.unexpectedErrno(err) catch {};
                        unreachable;
                    },
                },
            },
        };
    }
};

pub const OperationType = enum {
    noop,
    accept,
    connect,
    read,
    write,
    send,
    recv,
    sendto,
    recvfrom,
    close,
    shutdown,
    timer,
    cancel,
    machport,
    proc,
};

/// All the supported operations of this event loop. These are always
/// backend-specific and therefore the structure and types change depending
/// on the underlying system in use. The high level operations are
/// done by initializing the request handles.
pub const Operation = union(OperationType) {
    noop: void,

    accept: struct {
        socket: os.socket_t,
        addr: os.sockaddr = undefined,
        addr_size: os.socklen_t = @sizeOf(os.sockaddr),
        flags: u32 = os.SOCK.CLOEXEC,
    },

    connect: struct {
        socket: os.socket_t,
        addr: std.net.Address,
    },

    send: struct {
        fd: os.fd_t,
        buffer: WriteBuffer,
    },

    recv: struct {
        fd: os.fd_t,
        buffer: ReadBuffer,
    },

    // Note: this is making our Completion quite large. We can follow
    // the pattern of io_uring and require another user-provided pointer
    // here for state to move all this stuff out to a pointer.
    sendto: struct {
        fd: os.fd_t,
        buffer: WriteBuffer,
        addr: std.net.Address,
    },

    recvfrom: struct {
        fd: os.fd_t,
        buffer: ReadBuffer,
        addr: os.sockaddr = undefined,
        addr_size: os.socklen_t = @sizeOf(os.sockaddr),
    },

    write: struct {
        fd: std.os.fd_t,
        buffer: WriteBuffer,
    },

    read: struct {
        fd: std.os.fd_t,
        buffer: ReadBuffer,
    },

    machport: struct {
        port: os.system.mach_port_name_t,
        buffer: ReadBuffer,
    },

    shutdown: struct {
        socket: std.os.socket_t,
        how: std.os.ShutdownHow = .both,
    },

    close: struct {
        fd: std.os.fd_t,
    },

    proc: struct {
        pid: std.os.pid_t,
        flags: u32 = os.system.NOTE_EXIT | os.system.NOTE_EXITSTATUS,
    },

    timer: Timer,

    cancel: struct {
        c: *Completion,
    },
};

pub const Result = union(OperationType) {
    noop: void,
    accept: AcceptError!os.socket_t,
    connect: ConnectError!void,
    close: CloseError!void,
    send: WriteError!usize,
    recv: ReadError!usize,
    sendto: WriteError!usize,
    recvfrom: ReadError!usize,
    write: WriteError!usize,
    read: ReadError!usize,
    machport: MachPortError!void,
    proc: ProcError!u32,
    shutdown: ShutdownError!void,
    timer: TimerError!TimerTrigger,
    cancel: CancelError!void,
};

pub const CancelError = error{};

pub const AcceptError = os.KEventError || os.AcceptError || error{
    Unexpected,
};

pub const ConnectError = os.KEventError || os.ConnectError || error{
    Unexpected,
};

pub const ReadError = os.KEventError ||
    os.ReadError ||
    os.RecvFromError ||
    error{
    EOF,
    Unexpected,
};

pub const WriteError = os.KEventError ||
    os.WriteError ||
    os.SendError ||
    os.SendMsgError ||
    os.SendToError ||
    error{
    Unexpected,
};

pub const MachPortError = os.KEventError || error{
    Unexpected,
};

pub const ProcError = os.KEventError || error{
    MissingKevent,
    Unexpected,
};

pub const ShutdownError = os.ShutdownError || error{
    Unexpected,
};

pub const CloseError = error{
    Unexpected,
};

pub const TimerError = error{
    Unexpected,
};

pub const TimerTrigger = enum {
    /// Unused with epoll
    request,

    /// Timer expired.
    expiration,

    /// Timer was canceled.
    cancel,
};

/// ReadBuffer are the various options for reading.
pub const ReadBuffer = union(enum) {
    /// Read into this slice.
    slice: []u8,

    /// Read into this array, just set this to undefined and it will
    /// be populated up to the size of the array. This is an option because
    /// the other union members force a specific size anyways so this lets us
    /// use the other size in the union to support small reads without worrying
    /// about buffer allocation.
    ///
    /// To know the size read you have to use the return value of the
    /// read operations (i.e. recv).
    ///
    /// Note that the union at the time of this writing could accomodate a
    /// much larger fixed size array here but we want to retain flexiblity
    /// for future fields.
    array: [32]u8,

    // TODO: future will have vectors
};

/// WriteBuffer are the various options for writing.
pub const WriteBuffer = union(enum) {
    /// Write from this buffer.
    slice: []const u8,

    /// Write from this array. See ReadBuffer.array for why we support this.
    array: struct {
        array: [32]u8,
        len: usize,
    },

    // TODO: future will have vectors
};

/// Timer that is inserted into the heap.
const Timer = struct {
    /// The absolute time to fire this timer next.
    next: os.timespec,

    /// Only used internally. If this is non-null and timer is
    /// CANCELLED, then the timer is rearmed automatically with this
    /// as the next time. The callback will not be called on the
    /// cancellation.
    reset: ?os.timespec = null,

    /// Internal heap fields.
    heap: heap.IntrusiveField(Timer) = .{},

    /// We point back to completion for now. When issue[1] is fixed,
    /// we can juse use that from our heap fields.
    /// [1]: https://github.com/ziglang/zig/issues/6611
    c: *Completion = undefined,

    fn less(_: void, a: *const Timer, b: *const Timer) bool {
        return a.ns() < b.ns();
    }

    /// Returns the nanoseconds of this timer. Note that maxInt(u64) ns is
    /// 584 years so if we get any overflows we just use maxInt(u64). If
    /// any software is running in 584 years waiting on this timer...
    /// shame on me I guess... but I'll be dead.
    fn ns(self: *const Timer) u64 {
        assert(self.next.tv_sec >= 0);
        assert(self.next.tv_nsec >= 0);

        const max = std.math.maxInt(u64);
        const s_ns = std.math.mul(
            u64,
            @intCast(u64, self.next.tv_sec),
            std.time.ns_per_s,
        ) catch return max;
        return std.math.add(u64, s_ns, @intCast(u64, self.next.tv_nsec)) catch
            return max;
    }
};

/// Kevent is either kevent_s or kevent64_s depending on the target platform.
/// This lets us support both Mac and non-Mac platforms.
const Kevent = switch (builtin.os.tag) {
    .macos => os.system.kevent64_s,
    else => @compileError("kqueue not supported yet for target OS"),
};

/// kevent calls either kevent or kevent64 depending on the
/// target platform.
fn kevent_syscall(
    kq: i32,
    changelist: []const Kevent,
    eventlist: []Kevent,
    timeout: ?*const os.timespec,
) os.KEventError!usize {
    // Normaly Kevent? Just use the normal os.kevent call.
    if (Kevent == os.Kevent) return try os.kevent(
        kq,
        changelist,
        eventlist,
        timeout,
    );

    // Otherwise, we have to call the kevent64 variant.
    while (true) {
        const rc = os.system.kevent64(
            kq,
            changelist.ptr,
            std.math.cast(c_int, changelist.len) orelse return error.Overflow,
            eventlist.ptr,
            std.math.cast(c_int, eventlist.len) orelse return error.Overflow,
            0,
            timeout,
        );
        switch (os.errno(rc)) {
            .SUCCESS => return @intCast(usize, rc),
            .ACCES => return error.AccessDenied,
            .FAULT => unreachable,
            .BADF => unreachable, // Always a race condition.
            .INTR => continue,
            .INVAL => unreachable,
            .NOENT => return error.EventNotFound,
            .NOMEM => return error.SystemResources,
            .SRCH => return error.ProcessNotFound,
            else => unreachable,
        }
    }
}

/// kevent_init initializes a Kevent from an os.Kevent. This is used when
/// the "ext" fields are zero.
inline fn kevent_init(ev: os.Kevent) Kevent {
    if (Kevent == os.Kevent) return ev;

    return .{
        .ident = ev.ident,
        .filter = ev.filter,
        .flags = ev.flags,
        .fflags = ev.fflags,
        .data = ev.data,
        .udata = ev.udata,
        .ext = .{ 0, 0 },
    };
}

comptime {
    if (@sizeOf(Completion) != 256) {
        @compileLog(@sizeOf(Completion));
        unreachable;
    }
}

test "kqueue: loop time" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // should never init zero
    var now = loop.now();
    try testing.expect(now > 0);

    // should update on a loop tick
    while (now == loop.now()) try loop.run(.no_wait);
}

test "kqueue: stop" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // Add the timer
    var called = false;
    var c1: Completion = undefined;
    loop.timer(&c1, 1_000_000, &called, (struct {
        fn callback(ud: ?*anyopaque, l: *xev.Loop, _: *xev.Completion, r: xev.Result) xev.CallbackAction {
            _ = l;
            _ = r;
            const b = @ptrCast(*bool, ud.?);
            b.* = true;
            return .disarm;
        }
    }).callback);

    // Tick
    try loop.run(.no_wait);
    try testing.expect(!called);

    // Stop
    loop.stop();
    try loop.run(.until_done);
    try testing.expect(!called);
}

test "kqueue: timer" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // Add the timer
    var called = false;
    var c1: xev.Completion = undefined;
    loop.timer(&c1, 1, &called, (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            _ = r;
            const b = @ptrCast(*bool, ud.?);
            b.* = true;
            return .disarm;
        }
    }).callback);

    // Add another timer
    var called2 = false;
    var c2: xev.Completion = undefined;
    loop.timer(&c2, 100_000, &called2, (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            _ = r;
            const b = @ptrCast(*bool, ud.?);
            b.* = true;
            return .disarm;
        }
    }).callback);

    // State checking
    try testing.expect(c1.state() == .active);
    try testing.expect(c2.state() == .active);

    // Tick
    while (!called) try loop.run(.no_wait);
    try testing.expect(called);
    try testing.expect(!called2);

    // State checking
    try testing.expect(c1.state() == .dead);
    try testing.expect(c2.state() == .active);
}

test "kqueue: timer reset" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    const cb: xev.Callback = (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            const v = @ptrCast(*?TimerTrigger, ud.?);
            v.* = r.timer catch unreachable;
            return .disarm;
        }
    }).callback;

    // Add the timer
    var trigger: ?TimerTrigger = null;
    var c1: Completion = undefined;
    loop.timer(&c1, 100_000, &trigger, cb);

    // We know timer won't be called from the timer test previously.
    try loop.run(.no_wait);
    try testing.expect(trigger == null);

    // Reset the timer
    var c_cancel: Completion = .{};
    loop.timer_reset(&c1, &c_cancel, 1, &trigger, cb);
    try testing.expect(c1.state() == .active);
    try testing.expect(c_cancel.state() == .active);

    // Run
    try loop.run(.until_done);
    try testing.expect(trigger.? == .expiration);
    try testing.expect(c1.state() == .dead);
    try testing.expect(c_cancel.state() == .dead);
}

test "kqueue: timer reset before tick" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    const cb: xev.Callback = (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            const v = @ptrCast(*?TimerTrigger, ud.?);
            v.* = r.timer catch unreachable;
            return .disarm;
        }
    }).callback;

    // Add the timer
    var trigger: ?TimerTrigger = null;
    var c1: Completion = undefined;
    loop.timer(&c1, 100_000, &trigger, cb);

    // Reset the timer
    var c_cancel: Completion = .{};
    loop.timer_reset(&c1, &c_cancel, 1, &trigger, cb);
    try testing.expect(c1.state() == .active);
    try testing.expect(c_cancel.state() == .dead);

    // Run
    try loop.run(.until_done);
    try testing.expect(trigger.? == .expiration);
    try testing.expect(c1.state() == .dead);
    try testing.expect(c_cancel.state() == .dead);
}

test "kqueue: timer reset after trigger" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    const cb: xev.Callback = (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            const v = @ptrCast(*?TimerTrigger, ud.?);
            v.* = r.timer catch unreachable;
            return .disarm;
        }
    }).callback;

    // Add the timer
    var trigger: ?TimerTrigger = null;
    var c1: Completion = undefined;
    loop.timer(&c1, 1, &trigger, cb);

    // Run the timer
    try loop.run(.until_done);
    try testing.expect(trigger.? == .expiration);
    try testing.expect(c1.state() == .dead);
    trigger = null;

    // Reset the timer
    var c_cancel: Completion = .{};
    loop.timer_reset(&c1, &c_cancel, 1, &trigger, cb);
    try testing.expect(c1.state() == .active);
    try testing.expect(c_cancel.state() == .dead);

    // Run
    try loop.run(.until_done);
    try testing.expect(trigger.? == .expiration);
    try testing.expect(c1.state() == .dead);
    try testing.expect(c_cancel.state() == .dead);
}

test "kqueue: timer cancellation" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // Add the timer
    var trigger: ?TimerTrigger = null;
    var c1: xev.Completion = undefined;
    loop.timer(&c1, 100_000, &trigger, (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            const ptr = @ptrCast(*?TimerTrigger, @alignCast(@alignOf(?TimerTrigger), ud.?));
            ptr.* = r.timer catch unreachable;
            return .disarm;
        }
    }).callback);

    // Tick and verify we're not called.
    try loop.run(.no_wait);
    try testing.expect(trigger == null);

    // Cancel the timer
    var called = false;
    var c_cancel: xev.Completion = .{
        .op = .{
            .cancel = .{
                .c = &c1,
            },
        },

        .userdata = &called,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.cancel catch unreachable;
                const ptr = @ptrCast(*bool, @alignCast(@alignOf(bool), ud.?));
                ptr.* = true;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_cancel);

    // Tick
    try loop.run(.until_done);
    try testing.expect(called);
    try testing.expect(trigger.? == .cancel);
}

test "kqueue: canceling a completed operation" {
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // Add the timer
    var trigger: ?TimerTrigger = null;
    var c1: xev.Completion = undefined;
    loop.timer(&c1, 1, &trigger, (struct {
        fn callback(
            ud: ?*anyopaque,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            _ = l;
            const ptr = @ptrCast(*?TimerTrigger, @alignCast(@alignOf(?TimerTrigger), ud.?));
            ptr.* = r.timer catch unreachable;
            return .disarm;
        }
    }).callback);

    // Tick and verify we're not called.
    try loop.run(.until_done);
    try testing.expect(trigger.? == .expiration);

    // Cancel the timer
    var called = false;
    var c_cancel: xev.Completion = .{
        .op = .{
            .cancel = .{
                .c = &c1,
            },
        },

        .userdata = &called,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.cancel catch unreachable;
                const ptr = @ptrCast(*bool, @alignCast(@alignOf(bool), ud.?));
                ptr.* = true;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_cancel);

    // Tick
    try loop.run(.until_done);
    try testing.expect(called);
    try testing.expect(trigger.? == .expiration);
}

test "kqueue: socket accept/connect/send/recv/close" {
    const mem = std.mem;
    const net = std.net;
    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // Create a TCP server socket
    const address = try net.Address.parseIp4("127.0.0.1", 3131);
    const kernel_backlog = 1;
    var ln = try os.socket(address.any.family, os.SOCK.STREAM | os.SOCK.CLOEXEC, 0);
    errdefer os.closeSocket(ln);
    try os.setsockopt(ln, os.SOL.SOCKET, os.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    try os.bind(ln, &address.any, address.getOsSockLen());
    try os.listen(ln, kernel_backlog);

    // Create a TCP client socket
    var client_conn = try os.socket(
        address.any.family,
        os.SOCK.NONBLOCK | os.SOCK.STREAM | os.SOCK.CLOEXEC,
        0,
    );
    errdefer os.closeSocket(client_conn);

    // Accept
    var server_conn: os.socket_t = 0;
    var c_accept: Completion = .{
        .op = .{
            .accept = .{
                .socket = ln,
            },
        },

        .userdata = &server_conn,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                const conn = @ptrCast(*os.socket_t, @alignCast(@alignOf(os.socket_t), ud.?));
                conn.* = r.accept catch unreachable;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_accept);

    // Connect
    var connected = false;
    var c_connect: xev.Completion = .{
        .op = .{
            .connect = .{
                .socket = client_conn,
                .addr = address,
            },
        },

        .userdata = &connected,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.connect catch unreachable;
                const b = @ptrCast(*bool, ud.?);
                b.* = true;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_connect);

    // Wait for the connection to be established
    try loop.run(.until_done);
    try testing.expect(server_conn > 0);
    try testing.expect(connected);

    // Send
    var c_send: xev.Completion = .{
        .op = .{
            .send = .{
                .fd = client_conn,
                .buffer = .{ .slice = &[_]u8{ 1, 1, 2, 3, 5, 8, 13 } },
            },
        },

        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.send catch unreachable;
                _ = ud;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_send);

    // Receive
    var recv_buf: [128]u8 = undefined;
    var recv_len: usize = 0;
    var c_recv: xev.Completion = .{
        .op = .{
            .recv = .{
                .fd = server_conn,
                .buffer = .{ .slice = &recv_buf },
            },
        },

        .userdata = &recv_len,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                const ptr = @ptrCast(*usize, @alignCast(@alignOf(usize), ud.?));
                ptr.* = r.recv catch unreachable;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_recv);

    // Wait for the send/receive
    try loop.run(.until_done);
    try testing.expectEqualSlices(u8, c_send.op.send.buffer.slice, recv_buf[0..recv_len]);

    // Shutdown
    var shutdown = false;
    var c_client_shutdown: xev.Completion = .{
        .op = .{
            .shutdown = .{
                .socket = client_conn,
            },
        },

        .userdata = &shutdown,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.shutdown catch unreachable;
                const ptr = @ptrCast(*bool, @alignCast(@alignOf(bool), ud.?));
                ptr.* = true;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_client_shutdown);
    try loop.run(.until_done);
    try testing.expect(shutdown);

    // Read should be EOF
    var eof: ?bool = null;
    c_recv = .{
        .op = .{
            .recv = .{
                .fd = server_conn,
                .buffer = .{ .slice = &recv_buf },
            },
        },

        .userdata = &eof,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                const ptr = @ptrCast(*?bool, @alignCast(@alignOf(?bool), ud.?));
                ptr.* = if (r.recv) |_| false else |err| switch (err) {
                    error.EOF => true,
                    else => false,
                };
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_recv);

    try loop.run(.until_done);
    try testing.expect(eof.? == true);

    // Close
    var c_client_close: xev.Completion = .{
        .op = .{
            .close = .{
                .fd = client_conn,
            },
        },

        .userdata = &client_conn,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.close catch unreachable;
                const ptr = @ptrCast(*os.socket_t, @alignCast(@alignOf(os.socket_t), ud.?));
                ptr.* = 0;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_client_close);

    var c_server_close: xev.Completion = .{
        .op = .{
            .close = .{
                .fd = ln,
            },
        },

        .userdata = &ln,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.close catch unreachable;
                const ptr = @ptrCast(*os.socket_t, @alignCast(@alignOf(os.socket_t), ud.?));
                ptr.* = 0;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_server_close);

    // Wait for the sockets to close
    try loop.run(.until_done);
    try testing.expect(ln == 0);
    try testing.expect(client_conn == 0);
}

test "kqueue: file IO on thread pool" {
    const testing = std.testing;

    var tpool = main.ThreadPool.init(.{});
    defer tpool.deinit();
    defer tpool.shutdown();
    var loop = try Loop.init(.{ .thread_pool = &tpool });
    defer loop.deinit();

    // Create our file
    const path = "test_watcher_file";
    const f = try std.fs.cwd().createFile(path, .{
        .read = true,
        .truncate = true,
    });
    defer f.close();
    defer std.fs.cwd().deleteFile(path) catch {};

    // Perform a write and then a read
    var write_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    var c_write: xev.Completion = .{
        .op = .{
            .write = .{
                .fd = f.handle,
                .buffer = .{ .slice = &write_buf },
            },
        },

        .flags = .{ .threadpool = true },

        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = ud;
                _ = l;
                _ = c;
                _ = r.write catch unreachable;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_write);

    // Wait for the write
    try loop.run(.until_done);

    // Make sure the data is on disk
    try f.sync();

    const f2 = try std.fs.cwd().openFile(path, .{});
    defer f2.close();

    // Read
    var read_buf: [128]u8 = undefined;
    var read_len: usize = 0;
    var c_read: xev.Completion = .{
        .op = .{
            .read = .{
                .fd = f2.handle,
                .buffer = .{ .slice = &read_buf },
            },
        },

        .flags = .{ .threadpool = true },

        .userdata = &read_len,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                const ptr = @ptrCast(*usize, @alignCast(@alignOf(usize), ud.?));
                ptr.* = r.read catch unreachable;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_read);

    // Wait for the send/receive
    try loop.run(.until_done);
    try testing.expectEqualSlices(u8, &write_buf, read_buf[0..read_len]);
}

test "kqueue: mach port" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const testing = std.testing;

    var loop = try Loop.init(.{});
    defer loop.deinit();

    // Allocate the port
    const mach_self = os.system.mach_task_self();
    var mach_port: os.system.mach_port_name_t = undefined;
    try testing.expectEqual(
        os.system.KernE.SUCCESS,
        os.system.getKernError(os.system.mach_port_allocate(
            mach_self,
            @enumToInt(os.system.MACH_PORT_RIGHT.RECEIVE),
            &mach_port,
        )),
    );
    defer _ = os.system.mach_port_deallocate(mach_self, mach_port);

    // Add the waiter
    var called = false;
    var c_wait: xev.Completion = .{
        .op = .{
            .machport = .{
                .port = mach_port,
                .buffer = .{ .array = undefined },
            },
        },

        .userdata = &called,
        .callback = (struct {
            fn callback(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = r.machport catch unreachable;
                const b = @ptrCast(*bool, ud.?);
                b.* = true;
                return .disarm;
            }
        }).callback,
    };
    loop.add(&c_wait);

    // Tick so we submit... should not call since we never sent.
    try loop.run(.no_wait);
    try testing.expect(!called);

    // Send a message to the port
    var msg: os.system.mach_msg_header_t = .{
        .msgh_bits = @enumToInt(os.system.MACH_MSG_TYPE.MAKE_SEND_ONCE),
        .msgh_size = @sizeOf(os.system.mach_msg_header_t),
        .msgh_remote_port = mach_port,
        .msgh_local_port = os.system.MACH_PORT_NULL,
        .msgh_voucher_port = undefined,
        .msgh_id = undefined,
    };
    try testing.expectEqual(os.system.MachMsgE.SUCCESS, os.system.getMachMsgError(
        os.system.mach_msg(
            &msg,
            os.system.MACH_SEND_MSG,
            msg.msgh_size,
            0,
            os.system.MACH_PORT_NULL,
            os.system.MACH_MSG_TIMEOUT_NONE,
            os.system.MACH_PORT_NULL,
        ),
    ));

    // We should receive now!
    try loop.run(.until_done);
    try testing.expect(called);

    // We should not receive again
    called = false;
    loop.add(&c_wait);

    // Tick so we submit... should not call since we never sent.
    try loop.run(.no_wait);
    try testing.expect(!called);
}
