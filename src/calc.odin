/*
    2026 (c) Zaya, https://github.com/zm69
*/
package lu_brain

// Base
    import "base:runtime"

// Core
    import "core:fmt"
    import "core:math"

///////////////////////////////////////////////////////////////////////////////
// Calcs

    calc__hash_comb :: #force_inline proc "contextless" (seed, value: u64) -> u64 {
        seed := seed
        seed ~= value + 0x9e3779b9 + (seed << 6) + (seed >> 2)
        return seed
    }

    calc__layers_count :: proc(w, h: int) -> int {
        when VALIDATIONS do assert(w > 0 && h > 0)

        w, h := w, h
        if w > 1 do w -= 1
        if h > 1 do h -= 1

        y := w * h
        if y > 1 do y -= 1

        return y
    }

    calc__expected_child_size :: proc(w, h: int) -> int {
        when VALIDATIONS do assert(w > 0 && h > 0)

        if w == 1 && h == 1 do return 1
        if w == 1 || h == 1 do return 2
        return 4
    }

    calc__is_last_layer :: proc(w, h: int) -> bool {
        return calc__expected_child_size(w, h) == w * h
    }

///////////////////////////////////////////////////////////////////////////////
// Comp_Calc -- maps a component value in [min, max] onto one of `cells_size` discrete steps.

    Comp_Calc :: struct {
        allocator: runtime.Allocator,

        orig_min: Value,
        orig_max: Value,
        max: Value,

        step: Value,
        steps: []Value,  // precalculated steps
        cells_size: int,
    }

    comp_calc__init :: proc(self: ^Comp_Calc, min, max: Value, cells_size: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
        when VALIDATIONS do assert(max > min && cells_size > 0)

        self.allocator = allocator
        self.cells_size = cells_size
        self.orig_min = min
        self.orig_max = max
        self.max = max - min
        self.step = self.max / Value(cells_size)

        self.steps = make([]Value, cells_size, allocator) or_return
        for i in 0..<cells_size do self.steps[i] = Value(i) * self.step

        return nil
    }

    comp_calc__terminate :: proc(self: ^Comp_Calc) -> runtime.Allocator_Error {
        err := delete(self.steps, self.allocator)
        self.steps = nil
        return err
    }

    comp_calc__norm :: #force_inline proc "contextless" (self: ^Comp_Calc, request: Value) -> Value {
        return clamp(request - self.orig_min, 0, self.max)
    }

    comp_calc__ix :: #force_inline proc(self: ^Comp_Calc, norm_val: Value) -> int {
        ix := int(math.floor(norm_val / self.step))
        if ix >= self.cells_size do ix -= 1

        when VALIDATIONS do assert(ix < self.cells_size)

        return ix
    }

    comp_calc__calc_sig :: #force_inline proc(self: ^Comp_Calc, val_step_i: int, val: Value) -> Value {
        return 1.0 - math.abs(self.steps[val_step_i] - val) / self.max
    }

    comp_calc__digitalize_value :: proc(self: ^Comp_Calc, v: Value) -> Value {
        return self.steps[comp_calc__ix(self, comp_calc__norm(self, v))]
    }

    comp_calc__digitalize_data :: proc(self: ^Comp_Calc, data: ^Data, z: int) {
        z_shift := z * data.w * data.h
        for i in z_shift..<z_shift + data.w * data.h {
            data.values[i] = comp_calc__digitalize_value(self, data.values[i])
        }
    }

    comp_calc__print :: proc(self: ^Comp_Calc) {
        fmt.printf("\nComp_Calc steps: ")
        for s in self.steps do fmt.printf("| %.2f ", s)
        fmt.printf("\n")
    }
