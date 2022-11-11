// Copyright 2022 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Also licensed under MIT license, at your choice.

// Fine rasterizer. This can run in simple (just path rendering) and full
// modes, controllable by #define.

// This is a cut'n'paste w/ backdrop.
struct Tile {
    backdrop: i32,
    segments: u32,
}

#import segment
#import config

@group(0) @binding(0)
var<storage> config: Config;

@group(0) @binding(1)
var<storage> tiles: array<Tile>;

@group(0) @binding(2)
var<storage> segments: array<Segment>;

// This will become a texture, but keeping things simple for now
@group(0) @binding(3)
var<storage, read_write> output: array<u32>;

#ifdef full
#import ptcl

let GRADIENT_WIDTH = 512;
let BLEND_STACK_SPLIT = 4u;

@group(0) @binding(4)
var<storage> ptcl: array<u32>;

@group(0) @binding(5)
var gradients: texture_2d<f32>;

fn read_fill(cmd_ix: u32) -> CmdFill {
    let tile = ptcl[cmd_ix + 1u];
    let backdrop = i32(ptcl[cmd_ix + 2u]);
    return CmdFill(tile, backdrop);
}

fn read_stroke(cmd_ix: u32) -> CmdStroke {
    let tile = ptcl[cmd_ix + 1u];
    let half_width = bitcast<f32>(ptcl[cmd_ix + 2u]);
    return CmdStroke(tile, half_width);
}

fn read_color(cmd_ix: u32) -> CmdColor {
    let rgba_color = ptcl[cmd_ix + 1u];
    return CmdColor(rgba_color);
}

fn read_lin_grad(cmd_ix: u32) -> CmdLinGrad {
    let index = ptcl[cmd_ix + 1u];
    let line_x = bitcast<f32>(ptcl[cmd_ix + 2u]);
    let line_y = bitcast<f32>(ptcl[cmd_ix + 3u]);
    let line_c = bitcast<f32>(ptcl[cmd_ix + 4u]);
    return CmdLinGrad(index, line_x, line_y, line_c);
}

fn read_rad_grad(cmd_ix: u32) -> CmdRadGrad {
    let index = ptcl[cmd_ix + 1u];
    let m0 = bitcast<f32>(ptcl[cmd_ix + 2u]);
    let m1 = bitcast<f32>(ptcl[cmd_ix + 3u]);
    let m2 = bitcast<f32>(ptcl[cmd_ix + 4u]);
    let m3 = bitcast<f32>(ptcl[cmd_ix + 5u]);
    let matrx = vec4<f32>(m0, m1, m2, m3);
    let xlat = vec2<f32>(bitcast<f32>(ptcl[cmd_ix + 6u]), bitcast<f32>(ptcl[cmd_ix + 7u]));
    let c1 = vec2<f32>(bitcast<f32>(ptcl[cmd_ix + 8u]), bitcast<f32>(ptcl[cmd_ix + 9u]));
    let ra = bitcast<f32>(ptcl[cmd_ix + 10u]);
    let roff = bitcast<f32>(ptcl[cmd_ix + 11u]);
    return CmdRadGrad(index, matrx, xlat, c1, ra, roff);
}

fn mix_blend_compose(backdrop: vec4<f32>, src: vec4<f32>, mode: u32) -> vec4<f32> {
    // TODO: ALL the blend modes. This is just vanilla src-over.
    return backdrop * (1.0 - src.a) + src;
}
#endif

let PIXELS_PER_THREAD = 4u;

fn fill_path(tile: Tile, xy: vec2<f32>) -> array<f32, PIXELS_PER_THREAD> {
    var area: array<f32, PIXELS_PER_THREAD>;
    let backdrop_f = f32(tile.backdrop);
    for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
        area[i] = backdrop_f;
    }
    var segment_ix = tile.segments;
    while segment_ix != 0u {
        let segment = segments[segment_ix];
        let y = segment.origin.y - xy.y;
        let y0 = clamp(y, 0.0, 1.0);
        let y1 = clamp(y + segment.delta.y, 0.0, 1.0);
        let dy = y0 - y1;
        if dy != 0.0 {
            let vec_y_recip = 1.0 / segment.delta.y;
            let t0 = (y0 - y) * vec_y_recip;
            let t1 = (y1 - y) * vec_y_recip;
            let startx = segment.origin.x - xy.x;
            let x0 = startx + t0 * segment.delta.x;
            let x1 = startx + t1 * segment.delta.x;
            let xmin0 = min(x0, x1);
            let xmax0 = max(x0, x1);
            for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
                let i_f = f32(i);
                let xmin = min(xmin0 - i_f, 1.0) - 1.0e-6;
                let xmax = xmax0 - i_f;
                let b = min(xmax, 1.0);
                let c = max(b, 0.0);
                let d = max(xmin, 0.0);
                let a = (b + 0.5 * (d * d - c * c) - xmin) / (xmax - xmin);
                area[i] += a * dy;
            }
        }
        let y_edge = sign(segment.delta.x) * clamp(xy.y - segment.y_edge + 1.0, 0.0, 1.0);
        for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
            area[i] += y_edge;
        }
        segment_ix = segment.next;
    }
    // nonzero winding rule
    for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
        area[i] = abs(area[i]);
    }
    return area;
}

fn stroke_path(seg: u32, half_width: f32, xy: vec2<f32>) -> array<f32, PIXELS_PER_THREAD> {
    var df: array<f32, PIXELS_PER_THREAD>;
    for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
        df[i] = 1e9;
    }
    var segment_ix = seg;
    while segment_ix != 0u {
        let segment = segments[segment_ix];
        let delta = segment.delta;
        let dpos0 = xy + vec2<f32>(0.5, 0.5) - segment.origin;
        let scale = 1.0 / dot(delta, delta);
        for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
            let dpos = vec2<f32>(dpos0.x + f32(i), dpos0.y);
            let t = clamp(dot(dpos, delta) * scale, 0.0, 1.0);
            // performance idea: hoist sqrt out of loop
            df[i] = min(df[i], length(delta * t - dpos));
        }
        segment_ix = segment.next;
    }
    for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
        // reuse array; return alpha rather than distance
        df[i] = clamp(half_width + 0.5 - df[i], 0.0, 1.0);
    }
    return df;
}

@compute @workgroup_size(4, 16)
fn main(
    @builtin(global_invocation_id) global_id: vec3<u32>,
    @builtin(local_invocation_id) local_id: vec3<u32>,
    @builtin(workgroup_id) wg_id: vec3<u32>,
) {
    let tile_ix = wg_id.y * config.width_in_tiles + wg_id.x;
    let xy = vec2<f32>(f32(global_id.x * PIXELS_PER_THREAD), f32(global_id.y));
#ifdef full
    var rgba: array<vec4<f32>, PIXELS_PER_THREAD>;
    var blend_stack: array<array<u32, BLEND_STACK_SPLIT>, PIXELS_PER_THREAD>;
    var clip_depth = 0u;
    var area: array<f32, PIXELS_PER_THREAD>;
    var cmd_ix = tile_ix * PTCL_INITIAL_ALLOC;

    // main interpretation loop
    while true {
        let tag = ptcl[cmd_ix];
        if tag == CMD_END {
            break;
        }
        switch tag {
            // CMD_FILL
            case 1u: {
                let fill = read_fill(cmd_ix);
                let tile = Tile(fill.backdrop, fill.tile);
                area = fill_path(tile, xy);
                cmd_ix += 3u;
            }
            // CMD_STROKE
            case 2u: {
                let stroke = read_stroke(cmd_ix);
                area = stroke_path(stroke.tile, stroke.half_width, xy);
                cmd_ix += 3u;
            }
            // CMD_SOLID
            case 3u: {
                for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
                    area[i] = 1.0;
                }
                cmd_ix += 1u;
            }
            // CMD_COLOR
            case 5u: {
                let color = read_color(cmd_ix);
                let fg = unpack4x8unorm(color.rgba_color).wzyx;
                for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
                    let fg_i = fg * area[i];
                    rgba[i] = rgba[i] * (1.0 - fg_i.a) + fg_i;
                }
                cmd_ix += 2u;
            }
            // CMD_LIN_GRAD
            case 6u: {
                let lin = read_lin_grad(cmd_ix);
                let d = lin.line_x * xy.x + lin.line_y * xy.y + lin.line_c;
                for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
                    let my_d = d + lin.line_x * f32(i);
                    let x = i32(round(clamp(my_d, 0.0, 1.0) * f32(GRADIENT_WIDTH - 1)));
                    let fg_rgba = textureLoad(gradients, vec2<i32>(x, i32(lin.index)), 0);
                    let fg_i = fg_rgba * area[i];
                    rgba[i] = rgba[i] * (1.0 - fg_i.a) + fg_i;
                }
                cmd_ix += 12u;
            }
            // CMD_RAD_GRAD
            case 7u: {
                let rad = read_rad_grad(cmd_ix);
                for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
                    let my_xy = vec2<f32>(xy.x + f32(i), xy.y);
                    // TODO: can hoist y, but for now stick to piet-gpu
                    let xy_xformed = rad.matrx.xz * my_xy.x + rad.matrx.yw * my_xy.y - rad.xlat;
                    let ba = dot(xy_xformed, rad.c1);
                    let ca = rad.ra * dot(xy_xformed, xy_xformed);
                    let t = sqrt(ba * ba + ca) - ba - rad.roff;
                    let x = i32(round(clamp(t, 0.0, 1.0) * f32(GRADIENT_WIDTH - 1)));
                    let fg_rgba = textureLoad(gradients, vec2<i32>(x, i32(rad.index)), 0);
                    let fg_i = fg_rgba * area[i];
                    rgba[i] = rgba[i] * (1.0 - fg_i.a) + fg_i;
                }
                cmd_ix += 12u;
            }
            // CMD_BEGIN_CLIP
            case 9u: {
                if clip_depth < BLEND_STACK_SPLIT {
                    for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
                        blend_stack[clip_depth][i] = pack4x8unorm(rgba[i]);
                        rgba[i] = vec4<f32>(0.0);
                    }
                } else {
                    // TODO: spill to memory
                }
                clip_depth += 1u;
                cmd_ix += 1u;
            }
            // CMD_END_CLIP
            case 10u: {
                let blend = ptcl[cmd_ix + 1u];
                clip_depth -= 1u;
                for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
                    var bg_rgba: u32;
                    if clip_depth < BLEND_STACK_SPLIT {
                        bg_rgba = blend_stack[clip_depth][i];
                    } else {
                        // load from memory
                    }
                    let bg = unpack4x8unorm(bg_rgba);
                    let fg = rgba[i] * area[i];
                    rgba[i] = mix_blend_compose(bg, fg, blend);
                }
                cmd_ix += 2u;
            }
            // CMD_JUMP
            case 11u: {
                cmd_ix = ptcl[cmd_ix + 1u];
            }
            default: {}
        }
    }
    let out_ix = global_id.y * (config.width_in_tiles * TILE_WIDTH) + global_id.x * PIXELS_PER_THREAD;
    for (var i = 0u; i < PIXELS_PER_THREAD; i += 1u) {
        let fg = rgba[i];
        let a_inv = 1.0 / (fg.a + 1e-6);
        let rgba_sep = vec4<f32>(fg.r * a_inv, fg.g * a_inv, fg.b * a_inv, fg.a);
        let bytes = pack4x8unorm(rgba_sep);
        output[out_ix + i] = bytes;
    }
#else
    let tile = tiles[tile_ix];
    let area = fill_path(tile, xy);

    let bytes = pack4x8unorm(vec4<f32>(area[0], area[1], area[2], area[3]));
    let out_ix = global_id.y * (config.width_in_tiles * 4u) + global_id.x;
    output[out_ix] = bytes;
#endif
}
