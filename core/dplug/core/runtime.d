/**
 * This file provides `ScopedForeignCallback` to be used in every callback, and use to provide runtime initialization (now unused).
 *
 * Copyright: Copyright Auburn Sounds 2015-2016.
 * License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Authors:   Guillaume Piolat
 */
module dplug.core.runtime;

import core.stdc.stdlib;
import std.traits;
import std.functional: toDelegate;

import dplug.core.fpcontrol;
import dplug.core.nogc;
import dplug.core.cpuid;


/// RAII struct to cover extern callbacks.
/// This only deals with CPU identification and FPU control words save/restore.
struct ScopedForeignCallback(bool dummyDeprecated, bool saveRestoreFPU)
{
public:
nothrow:
@nogc:

    /// Thread that shouldn't be attached are eg. the audio threads.
    void enter()
    {
        debug _entered = true;

        static if (saveRestoreFPU)
            _fpControl.initialize();

        // Just detect the CPU in case it's the first ever callback
        initializeCpuid();
    }

    ~this()
    {
        // Ensure enter() was called.
        debug assert(_entered);
    }

    @disable this(this);

private:

    static if (saveRestoreFPU)
        FPControl _fpControl;

    debug bool _entered = false;
}



/// This encloses the runtime initialization and finalization.
/// Returns: a callback Voldement inside which you can use the runtime, but you can't escape GC memory.
auto runtimeSection(F)(F functionOrDelegateThatCanBeGC) nothrow @nogc if (isCallable!(F))
{
    // turn that into a delegate for simplicity purposes
    auto myGCDelegate = toDelegate(functionOrDelegateThatCanBeGC);
    alias T = typeof(myGCDelegate);

    enum attrs = functionAttributes!T | FunctionAttribute.nogc;        

    static ReturnType!T internalFunc(T fun, Parameters!T params) nothrow
    {
        try
        {
            import core.stdc.stdio;
            ScopedRuntimeSection section;
            section.enter();
            return fun(params);

            // Leaving runtime here
            // all GC objects will get collected, no reference may escape safely
        }
        catch(Exception e)
        {
            // runtime initialization failed
            // this should never happen
            assert(false);
        }            
    }      

    // We return this callable Voldemort type, this allow guaranteed clean-up

    static struct ManualDelegate
    {
        typeof(myGCDelegate.ptr) ptr;
        typeof(myGCDelegate.funcptr) funcptr;
        
        ReturnType!T opCall(Parameters!T params) nothrow @nogc
        {
            T dg;
            dg.funcptr = funcptr;
            dg.ptr = ptr;
            return assumeNoGC(&internalFunc)(dg, params);
        }

        @disable this(this);
    }

    ManualDelegate fakeDg;
    fakeDg.funcptr = myGCDelegate.funcptr;
    fakeDg.ptr = myGCDelegate.ptr;
    return fakeDg;
}

/// RAII struct for runtime initialization, to be used once by the plug-in client.
struct ScopedRuntime
{
public:
nothrow:
@nogc:
    import core.runtime;

    void initialize()
    {
        try
        {
            bool initOK = assumeNoGC(&Runtime.initialize)();

            if (!initOK)
                assert(false, "Runtime initialization shouldn't fail");
        }
        catch(Exception e)
        {
            assert(false, "Runtime initialization shouldn't fail");
        }

        _initialized = true;
    }

    ~this()
    {
        if (_initialized)
        {
            bool terminated;
            try
            {
                terminated = assumeNoGC(&Runtime.terminate)();
            }
            catch(Exception e)
            {
                terminated = false;
            }
            assert(terminated);  

            _initialized = false;
        }
    }

    @disable this(this);

private:
    bool _initialized = false;
}


private:




/// RAII struct to ensure thread attacment is initialized and usable
/// => that allow to use GC, TLS etc in a single function.
/// This isn't meant to be used directly, and it should certainly only be used in a scoped 
/// manner without letting a registered thread exit.
struct ScopedRuntimeSection
{
    import core.thread: thread_attachThis, thread_detachThis;

public:
    /// Thread that shouldn't be attached are eg. the audio threads.
    void enter()
    {
        // shoud allow reentrant threads
        bool alreadyAttached = isThisThreadAttached();
        if (!alreadyAttached)
        {
            thread_attachThis();
            _threadWasAttached = true;
        }
    }

    ~this()
    {
        // Detach current thread if it was attached by this runtime section
        if (_threadWasAttached)
        {
            thread_detachThis();
            _threadWasAttached = false;
        }

        // By collecting here we avoid correctness by coincidence for someone
        // that would rely on things remaining valid out of the ScopedRuntimeSection
        import core.memory;
        GC.collect();
    }

    @disable this(this);

private:

    bool _threadWasAttached = false;

    static bool isThisThreadAttached() nothrow
    {
        import core.memory;
        import core.thread;
        GC.disable(); scope(exit) GC.enable();
        if (auto t = Thread.getThis())
            return true;
        else
            return false;
    }
}



