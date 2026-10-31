import Darwin

/// mach_host_self acquires a send-right reference on every call, even when its name is unchanged.
final class MachHostPort: @unchecked Sendable {
    let name: mach_port_t = mach_host_self()
    deinit { mach_port_deallocate(mach_task_self_, name) }
}
