/// Registering libmicrohttpd's own threads with the D runtime.
///
/// MHD creates and owns the threads that run our callbacks, so they must be
/// attached to the runtime before any GC allocation happens on them. druntime
/// keeps attached threads in a global list and signals every entry when it
/// stops the world; a thread that exits while still listed leaves a dangling
/// entry behind, and the next collection then blocks forever waiting for a
/// suspend acknowledgement from a thread that no longer exists.
///
/// MHD offers no thread-exit hook, so detaching is done from a thread-local
/// storage destructor, which the platform runs as the thread terminates.
module ddhttpd.thread;

import core.thread.osthread : Thread, thread_attachThis;
import core.thread.threadbase : thread_detachThis;

version (Posix)
{
    import core.sys.posix.pthread : pthread_key_t, pthread_key_create, pthread_setspecific;

    private __gshared pthread_key_t detach_key;

    private extern (C) void detach_this_thread(void *) nothrow
    {
        // NOTE: Module TLS destructors are not run, since attach_this_thread
        //       does not run their constructors either.
        thread_detachThis();
    }

    shared static this()
    {
        if (pthread_key_create(&detach_key, &detach_this_thread))
            throw new Exception("pthread_key_create failed");
    }
}
else version (Windows)
{
    import core.sys.windows.windef : BOOL, DWORD;

    // Fiber local storage, available since Vista, is the only thread-local
    // storage on Windows with a destructor callback. Not in druntime's
    // bindings, so declare what we need.
    private alias PFLS_CALLBACK_FUNCTION = extern (Windows) void function(void*) nothrow;
    private enum FLS_OUT_OF_INDEXES = 0xFFFF_FFFF;

    private extern (Windows) nothrow @nogc
    {
        DWORD FlsAlloc(PFLS_CALLBACK_FUNCTION callback);
        BOOL FlsSetValue(DWORD index, void *data);
    }

    private __gshared DWORD detach_slot = FLS_OUT_OF_INDEXES;

    private extern (Windows) void detach_this_thread(void *) nothrow
    {
        thread_detachThis();
    }

    shared static this()
    {
        detach_slot = FlsAlloc(&detach_this_thread);
        if (detach_slot == FLS_OUT_OF_INDEXES)
            throw new Exception("FlsAlloc failed");
    }
}

/// Register the calling thread with the D runtime, if it is a foreign thread,
/// and arrange for it to be deregistered when it exits.
package(ddhttpd) void attach_this_thread()
{
    if (Thread.getThis())
        return;

    thread_attachThis();

    // Any non-null value will do, the destructor only runs when the slot is set
    version (Posix)
        pthread_setspecific(detach_key, cast(void*)1);
    else version (Windows)
        FlsSetValue(detach_slot, cast(void*)1);
}
