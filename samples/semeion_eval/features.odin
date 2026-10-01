/*
    2026 (c) Zaya, https://github.com/zm69

    Input features for the hybrid experiments (brain and kNN get exactly the same features):

      - deskew:     shear every digit upright using its second-order moments
      - directions: stroke orientation channels from image gradients, one rec component each
                    (rec depth > 1), next to the intensity channel

    Feature layout: channel-major, values[z * W * H + y * W + x], all values in [0, 1].
*/
package semeion_eval

// Core
    import "core:math"

// Lu
    import lu "../../src"

///////////////////////////////////////////////////////////////////////////////
// Globals (set once in main, read-only while folds run)

    FEATURE_DEPTH := 1
    FEATURE_BLANK: []lu.Value

///////////////////////////////////////////////////////////////////////////////
// Deskew

    // Shears the digit so that its main axis is vertical: dst(x, y) = src(x + alpha * (y - cy), y),
    // alpha = mu11 / mu02 of the intensity moments. Bilinear sampling, zero outside.
    pixels__deskew :: proc(src: ^Pixels) -> (dst: Pixels) {
        total, mx, my: f64
        for y in 0..<DIGIT__H {
            for x in 0..<DIGIT__W {
                v := src[y * DIGIT__W + x]
                total += v
                mx += v * f64(x)
                my += v * f64(y)
            }
        }
        if total <= 0 do return src^

        cx, cy := mx / total, my / total

        mu11, mu02: f64
        for y in 0..<DIGIT__H {
            for x in 0..<DIGIT__W {
                v := src[y * DIGIT__W + x]
                mu11 += v * (f64(x) - cx) * (f64(y) - cy)
                mu02 += v * (f64(y) - cy) * (f64(y) - cy)
            }
        }
        if mu02 <= 0 do return src^

        alpha := mu11 / mu02

        sample :: proc(src: ^Pixels, x, y: int) -> f64 {
            if x < 0 || y < 0 || x >= DIGIT__W || y >= DIGIT__H do return 0
            return src[y * DIGIT__W + x]
        }

        for y in 0..<DIGIT__H {
            for x in 0..<DIGIT__W {
                sx := f64(x) + alpha * (f64(y) - cy)
                x0 := int(math.floor(sx))
                t := sx - f64(x0)
                dst[y * DIGIT__W + x] = (1 - t) * sample(src, x0, y) + t * sample(src, x0 + 1, y)
            }
        }
        return
    }

///////////////////////////////////////////////////////////////////////////////
// Features

    // Intensity channel (unless dir_only) followed by `dirs` orientation channels.
    // Orientation is undirected (0..pi), soft-assigned to the two nearest of `dirs` bins and
    // weighted by the gradient magnitude, normalized so the strongest edge of the digit is 1.
    features__build :: proc(p: ^Pixels, dirs: int, dir_only: bool, allocator := context.allocator) -> []lu.Value {
        depth := features__depth(dirs, dir_only)
        out := make([]lu.Value, DIGIT__PIXEL_COUNT * depth, allocator)

        z := 0
        if !dir_only {
            copy(out[:DIGIT__PIXEL_COUNT], p[:])
            z = 1
        }
        if dirs == 0 do return out

        at :: proc(p: ^Pixels, x, y: int) -> f64 {
            return p[clamp(y, 0, DIGIT__H - 1) * DIGIT__W + clamp(x, 0, DIGIT__W - 1)]
        }

        mags: [DIGIT__PIXEL_COUNT]f64
        angles: [DIGIT__PIXEL_COUNT]f64
        max_mag: f64

        for y in 0..<DIGIT__H {
            for x in 0..<DIGIT__W {
                gx := (at(p, x + 1, y - 1) + 2 * at(p, x + 1, y) + at(p, x + 1, y + 1)) -
                      (at(p, x - 1, y - 1) + 2 * at(p, x - 1, y) + at(p, x - 1, y + 1))
                gy := (at(p, x - 1, y + 1) + 2 * at(p, x, y + 1) + at(p, x + 1, y + 1)) -
                      (at(p, x - 1, y - 1) + 2 * at(p, x, y - 1) + at(p, x + 1, y - 1))
                i := y * DIGIT__W + x
                mags[i] = math.sqrt(gx * gx + gy * gy)
                a := math.atan2(gy, gx)
                if a < 0 do a += math.PI
                if a >= math.PI do a -= math.PI
                angles[i] = a
                max_mag = max(max_mag, mags[i])
            }
        }
        if max_mag <= 0 do return out

        bin_width := math.PI / f64(dirs)
        for i in 0..<DIGIT__PIXEL_COUNT {
            m := mags[i] / max_mag
            if m <= 0 do continue
            pos := angles[i] / bin_width
            b0 := int(math.floor(pos)) % dirs
            b1 := (b0 + 1) % dirs
            t := pos - math.floor(pos)
            out[(z + b0) * DIGIT__PIXEL_COUNT + i] += m * (1 - t)
            out[(z + b1) * DIGIT__PIXEL_COUNT + i] += m * t
        }

        return out
    }

    features__depth :: proc(dirs: int, dir_only: bool) -> int {
        return (dir_only ? 0 : 1) + dirs
    }

    // Zero-filled shift of every channel: dst(x, y) = src(x - dx, y - dy).
    features__shift :: proc(src: []lu.Value, dst: []lu.Value, dx, dy: int) {
        for &v in dst do v = 0
        depth := len(src) / DIGIT__PIXEL_COUNT
        for z in 0..<depth {
            base := z * DIGIT__PIXEL_COUNT
            for y in 0..<DIGIT__H {
                for x in 0..<DIGIT__W {
                    sx, sy := x - dx, y - dy
                    if sx < 0 || sy < 0 || sx >= DIGIT__W || sy >= DIGIT__H do continue
                    dst[base + y * DIGIT__W + x] = src[base + sy * DIGIT__W + sx]
                }
            }
        }
    }

    // Squared L2 distance, minimum over the shifted versions of the test features.
    features__distance :: proc(shifted: [][]lu.Value, t: []lu.Value) -> f64 {
        best := max(f64)
        for sp in shifted {
            dist: f64
            for v, i in sp {
                diff := v - t[i]
                dist += diff * diff
            }
            best = min(best, dist)
        }
        return best
    }
