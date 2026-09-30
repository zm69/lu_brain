/*
    2026 (c) Zaya, https://github.com/zm69
*/
package lu_brain

///////////////////////////////////////////////////////////////////////////////
// Rec -- receiver: a w x h x d input of the brain (an image with d components, for example).
//
// Recs are owned by the brain; ^Rec stays valid for the brain's lifetime.

    Rec :: struct {
        brain: ^Brain,
        id: int,

        width: int,
        height: int,
        depth: int,

        config: Rec_Config,
        view: Rec_View,
    }

    rec__set_dest_start_pos :: proc "contextless" (self: ^Rec, dest_x, dest_y: int) {
        self.view.dest_start_x = dest_x
        self.view.dest_start_y = dest_y
    }

    rec__set_src_start_pos :: proc "contextless" (self: ^Rec, src_x, src_y: int) {
        self.view.src_start_x = src_x
        self.view.src_start_y = src_y
    }

    rec__set_src_end_pos :: proc "contextless" (self: ^Rec, src_x, src_y: int) {
        self.view.src_end_x = src_x
        self.view.src_end_y = src_y
    }

    rec__set_src_start_z :: proc "contextless" (self: ^Rec, src_z: int) {
        self.view.src_start_z = src_z
    }

    rec__set_src_end_z :: proc "contextless" (self: ^Rec, src_z: int) {
        self.view.src_end_z = src_z
    }
