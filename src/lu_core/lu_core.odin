/*
    2026 (c) Zaya, https://github.com/zm69

    Small generic building blocks used by Lu_Brain.
*/
package lu_core

// Base
    import "base:runtime"

///////////////////////////////////////////////////////////////////////////////
//
    VALIDATIONS :: #config(LU_VALIDATIONS, true)

    Core_Error :: enum {
        None = 0,
        Container_Is_Full,
        Not_Found,
        Already_Freed,
        Out_Of_Bounds,
    }

    Error :: union #shared_nil {
        Core_Error,
        runtime.Allocator_Error,
    }
