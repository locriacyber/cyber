const std = @import("std");
const lib  = @import("../src/lib.zig");

const cy = @cImport({
    @cInclude("cyber.h");
});

/// Run with:
///   zig build wasm-test -Dtarget=wasm32-freestanding -Drelease-fast
///   wasm3 zig-out/test/test.wasm
export fn _start() void {
    _ = lib;
    runTest(
        \\import os 'os'
        \\import t 'test'
        \\try t.eq(os.system, 'wasm')
    );
    runTest(@embedFile("astring_slice_test.cy"));
    runTest(@embedFile("astring_test.cy"));
    runTest(@embedFile("bitwise_op_test.cy"));
    runTest(@embedFile("compare_eq_test.cy"));
    runTest(@embedFile("compare_neq_test.cy"));
    runTest(@embedFile("compare_num_test.cy"));
    runTest(@embedFile("core_test.cy"));
    runTest(@embedFile("for_iter_test.cy"));
    runTest(@embedFile("for_opt_test.cy"));
    runTest(@embedFile("for_range_test.cy"));
    runTest(@embedFile("list_test.cy"));
    runTest(@embedFile("logic_op_test.cy"));
    runTest(@embedFile("map_test.cy"));
    runTest(@embedFile("math_test.cy"));
    runTest(@embedFile("number_test.cy"));
    runTest(@embedFile("object_test.cy"));
    runTest(@embedFile("rawstring_slice_test.cy"));
    runTest(@embedFile("rawstring_test.cy"));
    runTest(@embedFile("static_astring_test.cy"));
    runTest(@embedFile("static_func_test.cy"));
    runTest(@embedFile("static_ustring_test.cy"));
    runTest(@embedFile("string_interpolation_test.cy"));
    runTest(@embedFile("truthy_test.cy"));
    runTest(@embedFile("try_test.cy"));
    runTest(@embedFile("ustring_slice_test.cy"));
    runTest(@embedFile("ustring_test.cy"));
    runTest(@embedFile("while_cond_test.cy"));
    runTest(@embedFile("while_inf_test.cy"));
}

fn runTest(src: []const u8) void {
    const vm = cy.cyVmCreate();
    defer cy.cyVmDestroy(vm);
    const val = cy.cyVmEval(vm, src.ptr, src.len);
    if (cy.cyValueIsPanic(val)) {
        @panic("error");
    }
}

export fn hostFileWrite(fid: u32, str: [*]const u8, strLen: usize) void {
    _ = fid;
    _ = str;
    _ = strLen;
}

export fn jsLog(ptr: [*]const u8, len: usize) void {
    _ = ptr;
    _ = len;
}

export fn jsErr(ptr: [*]const u8, len: usize) void {
    _ = ptr;
    _ = len;
}

export fn jsPerformanceNow() f64 {
    return 0;
}