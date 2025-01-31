const std = @import("std");
const builtin = @import("builtin");
const stdx = @import("stdx");
const t = stdx.testing;
const cy = @import("cyber.zig");
const fmt = @import("fmt.zig");
const v = fmt.v;

const vm_ = @import("vm.zig");

const log = stdx.log.scoped(.sema);

const TypeTag = enum {
    any,
    boolean,
    number,
    int,
    list,
    map,
    fiber,
    string,
    staticString,
    box,
    tag,
    tagLiteral,
    undefined,
};

pub const Type = struct {
    typeT: TypeTag,
    rcCandidate: bool,
    inner: packed union {
        tag: packed struct {
            tagId: u8,
        },
        number: packed struct {
            canRequestInteger: bool,
        },
    } = undefined,
};

pub const UndefinedType = Type{
    .typeT = .undefined,
    .rcCandidate = false,
};

pub const AnyType = Type{
    .typeT = .any,
    .rcCandidate = true,
};

pub const BoolType = Type{
    .typeT = .boolean,
    .rcCandidate = false,
};

pub const IntegerType = Type{
    .typeT = .int,
    .rcCandidate = false,
};

pub const NumberType = Type{
    .typeT = .number,
    .rcCandidate = false,
    .inner = .{
        .number = .{
            .canRequestInteger = false,
        },
    },
};

/// Number constants are numbers by default, but some constants can be requested as an integer during codegen.
/// Once a constant has been assigned to a variable, it becomes a `NumberType`.
const NumberOrRequestIntegerType = Type{
    .typeT = .number,
    .rcCandidate = false,
    .inner = .{
        .number = .{
            .canRequestInteger = true,
        },
    },
};

pub const StaticStringType = Type{
    .typeT = .staticString,
    .rcCandidate = false,
};

pub const StringType = Type{
    .typeT = .string,
    .rcCandidate = true,
};

pub const FiberType = Type{
    .typeT = .fiber,
    .rcCandidate = true,
};

pub const ListType = Type{
    .typeT = .list,
    .rcCandidate = true,
};

pub const TagLiteralType = Type{
    .typeT = .tagLiteral,
    .rcCandidate = false,
};

pub fn initTagType(tagId: u32) Type {
    return .{
        .typeT = .tag,
        .rcCandidate = false,
        .inner = .{
            .tag = .{
                .tagId = @intCast(u8, tagId),
            },
        },
    };
}

pub const MapType = Type{
    .typeT = .map,
    .rcCandidate = true,
};

const ValueAddrType = enum {
    frameOffset,
};

const ValueAddr = struct {
    addrT: ValueAddrType,
    inner: union {
        frameOffset: u32,
    },
};

const RegisterId = u8;

pub const LocalVarId = u32;

/// Represents a variable in a block.
/// If the variable was declared `static`, references to it will use a static symbol instead.
/// Other variables are given reserved registers on the stack frame.
/// Captured variables have box values at runtime.
pub const LocalVar = struct {
    /// The current type of the var as the ast is traversed.
    /// This is updated when there is a variable assignment or a child block returns.
    vtype: Type,

    /// Whether this var is a captured function param.
    isCaptured: bool = false,

    /// Whether this var references a static variable.
    isStaticAlias: bool = false,

    /// Whether the variable references a captured/static var from a modifier or implicity from a read reference.
    hasCaptureOrStaticModifier: bool = false,

    /// Currently a captured var always needs to be boxed.
    /// In the future, the concept of a const variable could change this.
    isBoxed: bool = false,

    /// Whether this is a function param. (Does not include captured vars.)
    isParam: bool = false,

    /// Indicates that at some point during the vars lifetime it was an rcCandidate.
    /// Since all exit paths jump to the same release inst, this flag is used to determine
    /// which vars need a release.
    lifetimeRcCandidate: bool,

    /// There are two cases where the compiler needs to implicitly generate var initializers.
    /// 1. Var is first assigned in a branched block. eg. Assigned inside if block.
    ///    Since the var needs to be released at the end of the root block,
    ///    it needs to have a defined value.
    /// 2. Var is first assigned in an iteration block.
    /// At the beginning of codegen for this block, these vars will be inited to the `none` value.
    genInitializer: bool = false,

    /// Local register offset assigned to this var.
    /// Locals are relative to the stack frame's start position.
    local: RegisterId = undefined,

    /// Since the same sema var is used later by codegen,
    /// use a flag to indicate whether the var has been loosely defined in the block. (eg. assigned to lvalue)
    /// Note that assigning inside a branch counts as defined.
    /// Entering an iter block will auto mark those as defined since the var could have been assigned by a previous iteration.
    genIsDefined: bool = false,

    inner: extern union {
        symId: SymId,
    } = undefined,

    name: if (builtin.mode == .Debug) []const u8 else void,
};

pub const CapVarDesc = packed union {
    /// The user of a captured var contains the SemaVarId back to the owner's var.
    user: LocalVarId,
};

const VarAndType = struct {
    id: LocalVarId,
    vtype: Type,
};

pub const SubBlockId = u32;

pub const SubBlock = struct {
    /// Save var start types for entering a codegen iter block.
    /// This can only be determined after the sema pass.
    /// This is used to initialize the var type when entering the codegen iter block so
    /// that the first `genSetVar` produces the correct `set` op.
    iterVarBeginTypes: std.ArrayListUnmanaged(VarAndType),

    /// Track which vars were assigned to in the current sub block.
    /// If the var was first assigned in a parent sub block, the type is saved in the map to
    /// be merged later with the ending var type.
    /// Can be freed after the end of block.
    prevVarTypes: std.AutoHashMapUnmanaged(LocalVarId, Type),

    /// Start of vars assigned in this block in `assignedVarStack`.
    /// When leaving this block, all assigned var types in this block are merged
    /// back to the parent scope.
    assignedVarStart: u32,

    /// Previous sema sub block.
    /// When this sub block ends, the previous sub block id is set as the current.
    prevSubBlockId: SubBlockId,

    pub fn init(prevSubBlockId: SubBlockId, assignedVarStart: usize) SubBlock {
        return .{
            .assignedVarStart = @intCast(u32, assignedVarStart),
            .iterVarBeginTypes = .{},
            .prevVarTypes = .{},
            .prevSubBlockId = prevSubBlockId,
        };
    }

    pub fn deinit(self: *SubBlock, alloc: std.mem.Allocator) void {
        self.iterVarBeginTypes.deinit(alloc);
    }
};

pub const BlockId = u32;

pub const Block = struct {
    /// Local vars defined in this block. Does not include function params.
    locals: std.ArrayListUnmanaged(LocalVarId),

    /// Param vars for function blocks. Includes captured vars for closures.
    /// Captured vars are always at the end since the function params are known from the start.
    /// Codegen will reserve these first for the calling convention layout.
    params: std.ArrayListUnmanaged(LocalVarId),

    /// Name to var.
    /// This can be deinited after ending the sema block.
    nameToVar: std.StringHashMapUnmanaged(LocalVarId),

    /// First sub block id is recorded so the rest can be obtained by advancing
    /// the id in the same order it was traversed in the sema pass.
    firstSubBlockId: SubBlockId,

    /// Current sub block depth.
    subBlockDepth: u32,

    /// Index into `CompileChunk.funcDecls`. Main block if `NullId`.
    funcDeclId: u32,

    /// If the return type is not provided, sema tries to infer it.
    /// It won't try to infer non-trivial cases.
    /// Return type is updated only if `inferRetType` is true while iterating the body statements.
    retType: Type,
    hasRetType: bool,
    inferRetType: bool,

    /// Whether this block belongs to a static function.
    isStaticFuncBlock: bool,

    /// Whether temporaries (nameToVar) was deinit.
    deinitedTemps: bool,

    pub fn init(funcDeclId: cy.NodeId, firstSubBlockId: SubBlockId, isStaticFuncBlock: bool) Block {
        return .{
            .nameToVar = .{},
            .locals = .{},
            .params = .{},
            .subBlockDepth = 0,
            .funcDeclId = funcDeclId,
            .hasRetType = false,
            .inferRetType = false,
            .firstSubBlockId = firstSubBlockId,
            .retType = undefined,
            .isStaticFuncBlock = isStaticFuncBlock,
            .deinitedTemps = false,
        };
    }

    pub fn deinit(self: *Block, alloc: std.mem.Allocator) void {
        self.locals.deinit(alloc);
        self.params.deinit(alloc);

        // Deinit for CompileError during sema.
        self.deinitTemps(alloc);
    }

    fn deinitTemps(self: *Block, alloc: std.mem.Allocator) void {
        if (!self.deinitedTemps) {
            self.nameToVar.deinit(alloc);
            self.deinitedTemps = true;
        }
    }

    fn getReturnType(self: *const Block) Type {
        if (self.hasRetType) {
            return self.retType;
        } else {
            return AnyType;
        }
    }
};

pub const NameSymId = u32;

pub const Name = struct {
    ptr: [*]const u8,
    len: u32,
    owned: bool,

    pub fn getName(self: Name) []const u8 {
        return self.ptr[0..self.len];
    }
};

pub const SymId = u32;

/// Represents a sema symbol in the current module. It can be an intermediate sym in a sym path or a sym leaf.
/// Since module namespaces use the same accessor operator as local variables, a symbol doesn't always get resolved post sema.
pub const Sym = struct {
    /// key.parentId points to the parent sym in the current module.
    /// If key.parentId == cy.NullId, then this sym is at the root of the module.
    key: AbsLocalSymKey,

    /// After the sema pass, the rSymId will be updated.
    /// If `rSymId` is cy.NullId at codegen pass, this sym is undefined.
    rSymId: ResolvedSymId = cy.NullId,

    /// Whether this sym is used in the script.
    /// TODO: This might not be necessary once resolving syms ends up using the parent path symbol.
    used: bool,

    /// Used for static vars to track whether it has already generated code for the initializer
    /// in a DFS traversal of its dependencies.
    visited: bool,

    inline fn isFuncSym(self: *const Sym) bool {
        return self.key.absLocalSymKey.numParams != cy.NullId;
    }
};

pub fn getName(c: *const cy.VMcompiler, nameId: NameSymId) []const u8 {
    const name = c.semaNameSyms.items[nameId];
    return name.ptr[0..name.len];
}

pub fn getSymName(c: *const cy.VMcompiler, sym: *const Sym) []const u8 {
    const name = c.semaNameSyms.items[sym.key.absLocalSymKey.nameId];
    return name.ptr[0..name.len];
}

/// This is only called after symbol resolving.
pub fn symHasStaticInitializer(c: *const cy.CompileChunk, sym: *const Sym) bool {
    if (sym.rSymId != cy.NullId) {
        const rsym = c.compiler.semaResolvedSyms.items[sym.rSymId];
        if (rsym.symT == .variable) {
            return rsym.inner.variable.declId != cy.NullId;
        } else if (rsym.symT == .func) {
            if (sym.key.absLocalSymKey.funcSigId != cy.NullId) {
                const rFuncSigId = c.semaFuncSigs.items[sym.key.absLocalSymKey.funcSigId].rFuncSigId;
                const key = AbsResolvedFuncSymKey{
                    .absResolvedFuncSymKey = .{
                        .rSymId = sym.rSymId,
                        .rFuncSigId = rFuncSigId,
                    },
                };
                const fsymId = c.compiler.semaResolvedFuncSymMap.get(key).?;
                return c.compiler.semaResolvedFuncSyms.items[fsymId].hasStaticInitializer;
            }
        }
    }
    return false;
}

pub fn isResolvedVarSym(c: *const cy.VMcompiler, sym: *const Sym) bool {
    if (sym.rSymId != cy.NullId) {
        return c.semaResolvedSyms.items[sym.rSymId].symT == .variable;
    }
    return false;
}

pub const ResolvedFuncSymId = u32;
pub const ResolvedFuncSym = struct {
    chunkId: CompileChunkId,
    /// DeclId can be the cy.NullId for native functions.
    declId: u32,

    /// Can be used to update a local sym to point to this func sym.
    rFuncSigId: ResolvedFuncSigId,

    /// Return type.
    retType: Type,

    /// Whether this func has a static initializer.
    hasStaticInitializer: bool,
};

const ResolvedSymType = enum {
    func,
    variable,
    object,
    module,
    builtinType,
};

pub const ResolvedSymId = u32;

/// Local symbols are resolved during and after the sema pass.
/// Not all module members from builtins are resolved, only ones that are used.
pub const ResolvedSym = struct {
    symT: ResolvedSymType,
    /// Used to backtrack and build the full sym name.
    key: AbsResolvedSymKey,
    inner: extern union {
        func: extern struct {
            /// Refers to exactly one resolved func sym.
            /// rFuncSymId == cy.NullId indicates this sym is overloaded;
            /// more than one func shares the same symbol. To disambiguate,
            /// `resolvedFuncSymMap` must be queried with a absResolvedFuncSymKey.
            rFuncSymId: ResolvedFuncSymId,
        },
        variable: extern struct {
            chunkId: CompileChunkId,
            declId: cy.NodeId,
        },
        object: extern struct {
            /// If chunkId is NullId, it is declared outside of the user script. (eg. anonymous object type, builtin object types)
            chunkId: CompileChunkId,
            declId: cy.NodeId,
        },
        module: extern struct {
            id: ModuleId,
        },
        builtinType: extern struct {
            // TypeTag.
            typeT: u8,
        },
    },
    /// Whether the symbol is exported.
    exported: bool,
    /// Whether the symbol has been or is in the process of generating it's static initializer.
    genStaticInitVisited: bool = false,

    pub fn getObjectTypeId(self: ResolvedSym, vm: *cy.VM) ?cy.TypeId {
        return vm.getObjectTypeId(self.key.absResolvedSymKey.rParentSymId, self.key.absResolvedSymKey.nameId);
    }
};

const SymRefType = enum {
    module,
    moduleMember,

    // Local sym.
    sym,
};

/// Represents a mapping to another symbol.
pub const SymRef = struct {
    refT: SymRefType,
    inner: union {
        module: ModuleId,

        /// Points to a member sym of a module. (Import all.)
        moduleMember: struct {
            modId: ModuleId,
        },

        /// Points to another local sym. (Type alias.)
        sym: struct {
            symId: SymId,
        },
    },
};

/// Additional info attached to a initializer symbol.
pub const InitializerSym = struct {
    /// This points to a list of sema sym ids in `bufU32` that it depends on for initialization.
    depsStart: u32,
    depsEnd: u32,
};

const RelModuleSymKey = vm_.KeyU64;
const CompileChunkId = u32;

pub const ModuleId = u32;
pub const Module = struct {
    syms: std.HashMapUnmanaged(RelModuleSymKey, ModuleSym, vm_.KeyU64Context, 80),

    /// Attached chunk id. `NullId` if this module is a builtin.
    chunkId: CompileChunkId,

    /// The root resolved symbol for this Module.
    /// This is duped from CompileChunk for user modules, but for builtins, it's only available here.
    resolvedRootSymId: ResolvedSymId,

    pub fn setNativeFunc(self: *Module, c: *cy.VMcompiler, name: []const u8, numParams: u32, func: *const fn (*cy.UserVM, [*]const cy.Value, u8) cy.Value) !void {
        const nameId = try ensureNameSym(c, name);

        // AnyType for params and return.
        const rFuncSigId = try ensureResolvedUntypedFuncSig(c, numParams);
        const key = RelModuleSymKey{
            .relModuleSymKey = .{
                .nameId = nameId,
                .rFuncSigId = rFuncSigId,
            },
        };
        const res = try self.syms.getOrPut(c.alloc, key);
        res.value_ptr.* = .{
            .symT = .nativeFunc1,
            .inner = .{
                .nativeFunc1 = .{
                    .func = func,
                },
            },
        };
        if (!res.found_existing) {
            try self.addFuncToSym(c, nameId, rFuncSigId);
        }
    }

    fn addFuncToSym(self: *Module, c: *cy.VMcompiler, nameId: NameSymId, rFuncSigId: ResolvedFuncSigId) !void {
        const key = RelModuleSymKey{
            .relModuleSymKey = .{
                .nameId = nameId,
                .rFuncSigId = cy.NullId,
            },
        };
        const res = try self.syms.getOrPut(c.alloc, key);
        if (res.found_existing) {
            if (res.value_ptr.*.symT == .symToOneFunc) {
                const first = try c.alloc.create(ModuleFuncNode);
                first.* = .{
                    .rFuncSigId = res.value_ptr.*.inner.symToOneFunc.rFuncSigId,
                    .next = null,
                };
                const new = try c.alloc.create(ModuleFuncNode);
                new.* = .{
                    .rFuncSigId = rFuncSigId,
                    .next = first,
                };
                res.value_ptr.* = .{
                    .symT = .symToManyFuncs,
                    .inner = .{
                        .symToManyFuncs = .{
                            .head = new,
                        },
                    },
                };
            } else if (res.value_ptr.*.symT == .symToManyFuncs) {
                const new = try c.alloc.create(ModuleFuncNode);
                new.* = .{
                    .rFuncSigId = rFuncSigId,
                    .next = res.value_ptr.*.inner.symToManyFuncs.head,
                };
                res.value_ptr.*.inner.symToManyFuncs.head = new;
            } else {
                stdx.panicFmt("Unexpected symT: {}", .{res.value_ptr.*.symT});
            }
        } else {
            res.value_ptr.* = .{
                .symT = .symToOneFunc,
                .inner = .{
                    .symToOneFunc = .{
                        .rFuncSigId = rFuncSigId,
                    },
                },
            };
        }
    }

    pub fn getVarVal(self: *const Module, c: *cy.VMcompiler, name: []const u8) !?cy.Value {
        const nameId = try ensureNameSym(c, name);
        const key = RelModuleSymKey{
            .relModuleSymKey = .{
                .nameId = nameId,
                .rFuncSigId = cy.NullId,
            },
        };
        if (self.syms.get(key)) |sym| {
            return sym.inner.variable.val;
        } else return null;
    }

    pub fn setVar(self: *Module, c: *cy.VMcompiler, name: []const u8, val: cy.Value) !void {
        const nameId = try ensureNameSym(c, name);
        const key = RelModuleSymKey{
            .relModuleSymKey = .{
                .nameId = nameId,
                .rFuncSigId = cy.NullId,
            },
        };
        try self.syms.put(c.alloc, key, .{
            .symT = .variable,
            .inner = .{
                .variable = .{
                    .val = val,
                },
            },
        });
    }

    pub fn setObject(self: *Module, c: *cy.VMcompiler, name: []const u8, typeId: cy.TypeId) !void {
        const nameId = try ensureNameSym(c, name);
        const key = RelModuleSymKey{
            .relModuleSymKey = .{
                .nameId = nameId,
                .rFuncSigId = cy.NullId,
            },
        };
        try self.syms.put(c.alloc, key, .{
            .symT = .object,
            .inner = .{
                .object = .{
                    .typeId = typeId,
                },
            },
        });
    }

    pub fn setUserFunc(self: *Module, c: *cy.VMcompiler, name: []const u8, numParams: u32, declId: cy.NodeId) !void {
        const nameId = try ensureNameSym(c, name);

        const rFuncSigId = try ensureResolvedUntypedFuncSig(c, numParams);
        const key = RelModuleSymKey{
            .relModuleSymKey = .{
                .nameId = nameId,
                .rFuncSigId = rFuncSigId, 
            },
        };
        const res = try self.syms.getOrPut(c.alloc, key);
        res.value_ptr.* = .{
            .symT = .userFunc,
            .inner = .{
                .userFunc = .{
                    .declId = declId,
                },
            },
        };
        if (!res.found_existing) {
            try self.addFuncToSym(c, nameId, rFuncSigId);
        }
    }

    pub fn setUserVar(self: *Module, c: *cy.VMcompiler, name: []const u8, declId: cy.NodeId) !void {
        const nameId = try ensureNameSym(c, name);
        const key = RelModuleSymKey{
            .relModuleSymKey = .{
                .nameId = nameId,
                .rFuncSigId = cy.NullId,
            },
        };
        try self.syms.put(c.alloc, key, .{
            .symT = .userVar,
            .inner = .{
                .userVar = .{
                    .declId = declId,
                },
            },
        });
    }

    pub fn deinit(self: *Module, alloc: std.mem.Allocator) void {
        var iter = self.syms.iterator();
        while (iter.next()) |e| {
            const sym = e.value_ptr.*;
            if (sym.symT == .symToManyFuncs) {
                var cur: ?*ModuleFuncNode = sym.inner.symToManyFuncs.head;
                while (cur != null) {
                    const next = cur.?.next;
                    alloc.destroy(cur.?);
                    cur = next;
                }
            }
        }
        self.syms.deinit(alloc);
    }
};

const ModuleSymType = enum {
    variable,
    nativeFunc1,

    /// Symbol that points to one function signature.
    symToOneFunc,

    /// Symbol that points to multiple overloaded functions.
    symToManyFuncs,

    userVar,
    userFunc,
    object,
    userObject,
};

const ModuleSym = struct {
    symT: ModuleSymType,
    inner: union {
        nativeFunc1: struct {
            func: *const fn (*cy.UserVM, [*]const cy.Value, u8) cy.Value,
        },
        variable: struct {
            val: cy.Value,
        },
        symToOneFunc: struct {
            rFuncSigId: ResolvedFuncSigId,
        },
        symToManyFuncs: struct {
            head: *ModuleFuncNode,
        },
        userVar: struct {
            declId: cy.NodeId,
        },
        userFunc: struct {
            declId: cy.NodeId,
        },
        object: struct {
            typeId: cy.TypeId,
        },
        userObject: struct {
            declId: cy.NodeId,
        },
    },
};

const ModuleFuncNode = struct {
    next: ?*ModuleFuncNode,
    rFuncSigId: ResolvedFuncSigId,
};

/// Relative symbol signature key. RelFuncSigKey is repurposed for variable syms when `numParams` == cy.NullId.
const RelSymSigKey = cy.RelFuncSigKey;
const RelSymSigKeyContext = cy.RelFuncSigKeyContext;

/// Absolute symbol signature key. AbsFuncSigKey is repurposed for variable syms when `numParams` == cy.NullId.
pub const AbsSymSigKey = vm_.KeyU64;
pub const AbsResolvedSymKey = vm_.KeyU64;
pub const AbsResolvedFuncSymKey = vm_.KeyU64;
pub const AbsSymSigKeyContext = cy.AbsFuncSigKeyContext;
pub const AbsLocalSymKey = vm_.KeyU128;

pub fn semaStmts(self: *cy.CompileChunk, head: cy.NodeId, comptime attachEnd: bool) anyerror!void {
    var cur_id = head;
    while (cur_id != cy.NullId) {
        const node = self.nodes[cur_id];
        if (attachEnd) {
            if (node.next == cy.NullId) {
                try semaStmt(self, cur_id, false);
            } else {
                try semaStmt(self, cur_id, true);
            }
        } else {
            try semaStmt(self, cur_id, true);
        }
        cur_id = node.next;
    }
}

pub fn semaStmt(c: *cy.CompileChunk, nodeId: cy.NodeId, comptime discardTopExprReg: bool) !void {
    // log.debug("sema stmt {}", .{node.node_t});
    c.curNodeId = nodeId;
    const node = c.nodes[nodeId];
    switch (node.node_t) {
        .pass_stmt => {
            return;
        },
        .expr_stmt => {
            _ = try semaExpr(c, node.head.child_head, discardTopExprReg);
        },
        .breakStmt => {
            return;
        },
        .continueStmt => {
            return;
        },
        .opAssignStmt => {
            const left = c.nodes[node.head.opAssignStmt.left];
            if (left.node_t == .ident) {
                const rtype = try semaExpr(c, node.head.opAssignStmt.right, false);
                _ = try assignVar(c, node.head.opAssignStmt.left, rtype, .assign);
            } else if (left.node_t == .accessExpr) {
                const accessLeft = try semaExpr(c, left.head.accessExpr.left, false);
                const accessRight = try semaExpr(c, left.head.accessExpr.right, false);
                const right = try semaExpr(c, node.head.opAssignStmt.right, false);
                _ = accessLeft;
                _ = accessRight;
                _ = right;
            } else {
                return c.reportErrorAt("Assignment to the left {} is not allowed.", &.{fmt.v(left.node_t)}, nodeId);
            }
        },
        .assign_stmt => {
            const left = c.nodes[node.head.left_right.left];
            if (left.node_t == .ident) {
                const right = c.nodes[node.head.left_right.right];
                if (right.node_t == .matchBlock) {
                    const rtype = try semaMatchBlock(c, node.head.left_right.right, true);
                    _ = try assignVar(c, node.head.left_right.left, rtype, .assign);
                } else {
                    const rtype = try semaExpr(c, node.head.left_right.right, false);
                    _ = try assignVar(c, node.head.left_right.left, rtype, .assign);
                }
            } else if (left.node_t == .arr_access_expr) {
                _ = try semaExpr(c, left.head.left_right.left, false);
                _ = try semaExpr(c, left.head.left_right.right, false);
                _ = try semaExpr(c, node.head.left_right.right, false);
            } else if (left.node_t == .accessExpr) {
                _ = try semaExpr(c, left.head.accessExpr.left, false);
                _ = try semaExpr(c, left.head.accessExpr.right, false);
                _ = try semaExpr(c, node.head.left_right.right, false);
            } else {
                return c.reportErrorAt("Assignment to the left {} is not allowed.", &.{fmt.v(left.node_t)}, nodeId);
            }
        },
        .exportStmt => {
            const stmt = node.head.child_head;
            switch (c.nodes[stmt].node_t) {
                .varDecl => {
                    try semaVarDecl(c, stmt, true);
                    const left = c.nodes[c.nodes[stmt].head.varDecl.left];
                    const name = c.getNodeTokenString(left);
                    try c.compiler.modules.items[c.modId].setUserVar(c.compiler, name, stmt);
                },
                .funcDecl => {
                    try semaFuncDecl(c, stmt, true);
                    const funcId = c.nodes[stmt].head.func.decl_id;
                    const func = c.funcDecls[funcId];
                    const name = func.getName(c);
                    const numParams = @intCast(u16, func.params.end - func.params.start);
                    try c.compiler.modules.items[c.modId].setUserFunc(c.compiler, name, numParams, stmt);
                },
                .funcDeclInit => {
                    try semaFuncDeclInit(c, stmt, true);
                    const funcId = c.nodes[stmt].head.funcDeclInit.declId;
                    const func = c.funcDecls[funcId];
                    const name = func.getName(c);
                    const numParams = @intCast(u16, func.params.end - func.params.start);
                    try c.compiler.modules.items[c.modId].setUserFunc(c.compiler, name, numParams, stmt);
                },
                .objectDecl => {
                    try semaObjectDecl(c, stmt, true);
                },
                else => {
                    return c.reportErrorAt("Unsupported export {}", &.{v(c.nodes[stmt].node_t)}, nodeId);
                },
            }
        },
        .varDecl => {
            try semaVarDecl(c, nodeId, false);
        },
        .captureDecl => {
            const left = c.nodes[node.head.left_right.left];
            std.debug.assert(left.node_t == .ident);
            if (node.head.left_right.right != cy.NullId) {
                const rtype = try semaExpr(c, node.head.left_right.right, false);
                _ = try assignVar(c, node.head.left_right.left, rtype, .captureAssign);
            } else {
                _ = try assignVar(c, node.head.left_right.left, UndefinedType, .captureAssign);
            }
        },
        .staticDecl => {
            const left = c.nodes[node.head.left_right.left];
            std.debug.assert(left.node_t == .ident);
            if (node.head.left_right.right != cy.NullId) {
                const rtype = try semaExpr(c, node.head.left_right.right, false);
                _ = try assignVar(c, node.head.left_right.left, rtype, .staticAssign);
            } else {
                _ = try assignVar(c, node.head.left_right.left, UndefinedType, .staticAssign);
            }
        },
        .typeAliasDecl => {
            const nameN = c.nodes[node.head.typeAliasDecl.name];
            const name = c.getNodeTokenString(nameN);
            const nameId = try ensureNameSym(c.compiler, name);

            const expr = c.nodes[node.head.typeAliasDecl.expr];
            if (expr.node_t == .ident or expr.node_t == .accessExpr) {
                _ = try semaExpr(c, node.head.typeAliasDecl.expr, false);

                var symId: SymId = undefined;
                if (expr.node_t == .ident) {
                    symId = c.nodes[node.head.typeAliasDecl.expr].head.ident.semaSymId;
                } else if (expr.node_t == .accessExpr) {
                    symId = c.nodes[node.head.typeAliasDecl.expr].head.accessExpr.semaSymId;
                } else {
                    stdx.panic("unreachable");
                }

                try c.semaSymToRef.put(c.alloc, nameId, .{
                    .refT = .sym,
                    .inner = .{
                        .sym = .{
                            .symId = symId,
                        },
                    },
                });
            } else {
                return c.reportErrorAt("Unsupported type alias expression: {}", &.{v(expr.node_t)}, node.head.typeAliasDecl.expr);
            }
        },
        .tagDecl => {
            const nameN = c.nodes[node.head.tagDecl.name];
            const name = c.getNodeTokenString(nameN);

            const tid = try c.compiler.vm.ensureTagType(name);

            var i: u32 = 0;
            var memberId = node.head.tagDecl.memberHead;
            while (memberId != cy.NullId) : (i += 1) {
                const member = c.nodes[memberId];
                memberId = member.next;
            }
            const numMembers = i;
            c.compiler.vm.tagTypes.buf[tid].numMembers = numMembers;

            i = 0;
            memberId = node.head.tagDecl.memberHead;
            while (memberId != cy.NullId) : (i += 1) {
                const member = c.nodes[memberId];
                const mName = c.getNodeTokenString(member);
                const symId = try c.compiler.vm.ensureTagLitSym(mName);
                c.compiler.vm.setTagLitSym(tid, symId, i);
                memberId = member.next;
            }
        },
        .objectDecl => {
            try semaObjectDecl(c, nodeId, false);
        },
        .funcDeclInit => {
            try semaFuncDeclInit(c, nodeId, false);
        },
        .funcDecl => {
            try semaFuncDecl(c, nodeId, false);
        },
        .whileCondStmt => {
            try pushIterSubBlock(c);

            _ = try semaExpr(c, node.head.whileCondStmt.cond, false);
            try semaStmts(c, node.head.whileCondStmt.bodyHead, false);

            try endIterSubBlock(c);
        },
        .forOptStmt => {
            try pushIterSubBlock(c);

            const optt = try semaExpr(c, node.head.forOptStmt.opt, false);
            if (node.head.forOptStmt.as != cy.NullId) {
                _ = try ensureLocalBodyVar(c, node.head.forOptStmt.as, AnyType);
                _ = try assignVar(c, node.head.forOptStmt.as, optt, .assign);
            }

            try semaStmts(c, node.head.forOptStmt.bodyHead, false);

            try endIterSubBlock(c);
        },
        .whileInfStmt => {
            try pushIterSubBlock(c);
            try semaStmts(c, node.head.child_head, false);
            try endIterSubBlock(c);
        },
        .for_iter_stmt => {
            try pushIterSubBlock(c);

            _ = try semaExpr(c, node.head.for_iter_stmt.iterable, false);

            const eachClause = c.nodes[node.head.for_iter_stmt.eachClause];
            if (eachClause.head.eachClause.key != cy.NullId) {
                const keyv = try ensureLocalBodyVar(c, eachClause.head.eachClause.key, AnyType);
                c.vars.items[keyv].genInitializer = true;
            }
            const valv = try ensureLocalBodyVar(c, eachClause.head.eachClause.value, AnyType);
            c.vars.items[valv].genInitializer = true;

            try semaStmts(c, node.head.for_iter_stmt.body_head, false);
            try endIterSubBlock(c);
        },
        .for_range_stmt => {
            try pushIterSubBlock(c);

            if (node.head.for_range_stmt.eachClause != cy.NullId) {
                const eachClause = c.nodes[node.head.for_range_stmt.eachClause];
                _ = try ensureLocalBodyVar(c, eachClause.head.eachClause.value, NumberType);
            }

            const range_clause = c.nodes[node.head.for_range_stmt.range_clause];
            _ = try semaExpr(c, range_clause.head.left_right.left, false);
            _ = try semaExpr(c, range_clause.head.left_right.right, false);

            try semaStmts(c, node.head.for_range_stmt.body_head, false);
            try endIterSubBlock(c);
        },
        .matchBlock => {
            _ = try semaMatchBlock(c, nodeId, false);
        },
        .if_stmt => {
            _ = try semaExpr(c, node.head.left_right.left, false);

            try pushSubBlock(c);
            try semaStmts(c, node.head.left_right.right, false);
            try endSubBlock(c);

            var elseClauseId = node.head.left_right.extra;
            while (elseClauseId != cy.NullId) {
                const elseClause = c.nodes[elseClauseId];
                if (elseClause.head.else_clause.cond == cy.NullId) {
                    try pushSubBlock(c);
                    try semaStmts(c, elseClause.head.else_clause.body_head, false);
                    try endSubBlock(c);
                    break;
                } else {
                    _ = try semaExpr(c, elseClause.head.else_clause.cond, false);

                    try pushSubBlock(c);
                    try semaStmts(c, elseClause.head.else_clause.body_head, false);
                    try endSubBlock(c);
                    elseClauseId = elseClause.head.else_clause.else_clause;
                }
            }
        },
        .importStmt => {
            const ident = c.nodes[node.head.left_right.left];
            const name = c.getNodeTokenString(ident);
            const nameId = try ensureNameSym(c.compiler, name);
            _ = try referenceSym(c, null, name, null, node.head.left_right.left, true);

            const spec = c.nodes[node.head.left_right.right];
            const specPath = c.getNodeTokenString(spec);

            const modId = try getOrLoadModule(c, specPath, nodeId);
            try c.semaSymToRef.put(c.alloc, nameId, .{
                .refT = .module,
                .inner = .{
                    .module = modId,
                },
            });
        },
        .return_stmt => {
            return;
        },
        .return_expr_stmt => {
            const childT = try semaExpr(c, node.head.child_head, false);
            const block = curBlock(c);
            if (block.inferRetType) {
                if (block.hasRetType) {
                    block.retType = childT;
                    block.hasRetType = true;
                } else {
                    if (block.retType.typeT != .any) {
                        if (block.retType.typeT != childT.typeT) {
                            block.retType = AnyType;
                        }
                    }
                }
            }
        },
        .atStmt => {
            return;
        },
        else => return c.reportErrorAt("Unsupported node: {}", &.{v(node.node_t)}, nodeId),
    }
}

fn semaMatchBlock(c: *cy.CompileChunk, nodeId: cy.NodeId, canBreak: bool) !Type {
    const node = c.nodes[nodeId];
    _ = try semaExpr(c, node.head.matchBlock.expr, false);

    var curCase = node.head.matchBlock.firstCase;
    while (curCase != cy.NullId) {
        const case = c.nodes[curCase];
        var curCond = case.head.caseBlock.firstCond;
        while (curCond != cy.NullId) {
            const cond = c.nodes[curCond];
            if (cond.node_t != .elseCase) {
                _ = try semaExpr(c, curCond, false);
            }
            curCond = cond.next;
        }
        curCase = case.next;
    }

    curCase = node.head.matchBlock.firstCase;
    while (curCase != cy.NullId) {
        const case = c.nodes[curCase];
        try pushSubBlock(c);
        try semaStmts(c, case.head.caseBlock.firstChild, false);
        try endSubBlock(c);
        curCase = case.next;
    }

    if (canBreak) {
        return AnyType;
    } else {
        return UndefinedType;
    }
}

fn semaObjectDecl(c: *cy.CompileChunk, nodeId: cy.NodeId, exported: bool) !void {
    const node = c.nodes[nodeId];
    const nameN = c.nodes[node.head.objectDecl.name];
    const name = c.getNodeTokenString(nameN);
    const nameId = try ensureNameSym(c.compiler, name);

    if (c.compiler.vm.getObjectTypeId(c.semaResolvedRootSymId, nameId) != null) {
        return c.reportErrorAt("Object type `{}` already exists", &.{v(name)}, nodeId);
    }

    const objSymId = try ensureSym(c, null, nameId, null);
    const robjSymId = try resolveLocalObjectSym(c, objSymId, c.semaResolvedRootSymId, name, nodeId, exported);
    // Object type should be constructed during sema so it's available for static initializer codegen.
    const sid = try c.compiler.vm.ensureObjectType(c.semaResolvedRootSymId, nameId);

    // Persist local sym for codegen.
    c.nodes[node.head.objectDecl.name].head.ident.semaSymId = objSymId;

    var i: u32 = 0;
    var fieldId = node.head.objectDecl.fieldsHead;
    while (fieldId != cy.NullId) : (i += 1) {
        const field = c.nodes[fieldId];
        const fieldName = c.getNodeTokenString(field);
        const fieldSymId = try c.compiler.vm.ensureFieldSym(fieldName);
        try c.compiler.vm.addFieldSym(sid, fieldSymId, @intCast(u16, i));
        fieldId = field.next;
    }
    const numFields = i;
    c.compiler.vm.structs.buf[sid].numFields = numFields;

    var funcId = node.head.objectDecl.funcsHead;
    while (funcId != cy.NullId) {
        const func = c.nodes[funcId];
        const decl = &c.funcDecls[func.head.func.decl_id];

        if (decl.params.end > decl.params.start) {
            const param = c.funcParams[decl.params.start];
            const paramName = c.src[param.name.start..param.name.end];
            if (std.mem.eql(u8, paramName, "self")) {
                // Struct method.
                const blockId = try pushBlock(c, func.head.func.decl_id);
                decl.semaBlockId = blockId;
                errdefer endBlock(c) catch stdx.fatal();
                try pushMethodParamVars(c, decl);
                try semaStmts(c, func.head.func.body_head, false);
                try endBlock(c);
                funcId = func.next;
                continue;
            }
        }

        // Object function.
        const funcName = decl.getName(c);
        const funcNameId = try ensureNameSym(c.compiler, funcName);
        const numParams = @intCast(u16, decl.params.end - decl.params.start);

        const blockId = try pushBlock(c, func.head.func.decl_id);
        decl.semaBlockId = blockId;
        errdefer endBlock(c) catch stdx.fatal();
        try pushFuncParamVars(c, decl);
        try semaStmts(c, func.head.func.body_head, false);
        const retType = curBlock(c).getReturnType();
        try endFuncSymBlock(c, numParams);

        const funcSigId = try ensureUntypedFuncSig(c, numParams);
        const symId = try ensureSym(c, objSymId, funcNameId, funcSigId);
        // Export all static funcs in the object's namespace since `export` may be removed later on.
        _ = try resolveLocalFuncSym(c, symId, robjSymId, funcNameId, func.head.func.decl_id, retType, true);

        funcId = func.next;
    }
}

fn semaFuncDeclInit(c: *cy.CompileChunk, nodeId: cy.NodeId, exported: bool) !void {
    const node = c.nodes[nodeId];
    const declId = node.head.funcDeclInit.declId;
    const func = c.funcDecls[declId];
    var retType: ?Type = null;
    if (func.return_type) |slice| {
        const retTypeName = c.src[slice.start..slice.end];
        if (c.compiler.typeNames.get(retTypeName)) |vtype| {
            retType = vtype;
        }
    }

    const numParams = @intCast(u16, func.params.end - func.params.start);
    const name = func.getName(c);
    const nameId = try ensureNameSym(c.compiler, name);
    // Link to local symbol.
    const funcSigId = try ensureUntypedFuncSig(c, numParams);
    const symId = try ensureSym(c, null, nameId, funcSigId);
    // Mark as used since there is an initializer that could alter state.
    c.semaSyms.items[symId].used = true;
    c.nodes[nodeId].head.funcDeclInit.semaSymId = symId;

    c.curSemaSymVar = symId;
    c.semaVarDeclDeps.clearRetainingCapacity();
    defer c.curSemaSymVar = cy.NullId;

    _ = semaExpr(c, node.head.funcDeclInit.right, false) catch |err| {
        if (err == error.CanNotUseLocal) {
            const local = c.nodes[c.compiler.errorPayload];
            const localName = c.getNodeTokenString(local);
            return c.reportErrorAt("The declaration initializer of static function `{}` can not reference the local variable `{}`.", &.{v(name), v(localName)}, nodeId);
        } else {
            return err;
        }
    };

    const res = try resolveLocalFuncSym(c, symId, c.semaResolvedRootSymId, nameId, declId, retType orelse AnyType, exported);
    c.compiler.semaResolvedFuncSyms.items[res.rFuncSymId].hasStaticInitializer = true;
    // `semaBlockId` is repurposed to save the nodeId.
    c.funcDecls[declId].semaBlockId = nodeId;
}

fn semaFuncDecl(c: *cy.CompileChunk, nodeId: cy.NodeId, exported: bool) !void {
    const node = c.nodes[nodeId];
    const declId = node.head.func.decl_id;
    const func = &c.funcDecls[declId];
    var retType: ?Type = null;
    if (func.return_type) |slice| {
        const retTypeName = c.src[slice.start..slice.end];
        if (c.compiler.typeNames.get(retTypeName)) |vtype| {
            retType = vtype;
        }
    }

    const blockId = try pushBlock(c, declId);
    if (retType == null) {
        curBlock(c).inferRetType = true;
    }
    try pushFuncParamVars(c, func);
    try semaStmts(c, node.head.func.body_head, false);
    const sblock = curBlock(c);
    if (retType == null) {
        retType = sblock.getReturnType();
    }
    const name = func.getName(c);
    const nameId = try ensureNameSym(c.compiler, name);
    const numParams = @intCast(u16, func.params.end - func.params.start);
    try endFuncSymBlock(c, numParams);

    const funcSigId = try ensureUntypedFuncSig(c, numParams);
    const symId = try ensureSym(c, null, nameId, funcSigId);
    linkNodeToSym(c, nodeId, symId);
    _ = try resolveLocalFuncSym(c, symId, c.semaResolvedRootSymId, nameId, declId, retType.?, exported);
    func.semaBlockId = blockId;
}

fn semaVarDecl(c: *cy.CompileChunk, nodeId: cy.NodeId, exported: bool) !void {
    const node = c.nodes[nodeId];
    const left = c.nodes[node.head.varDecl.left];
    if (left.node_t == .ident) {
        const name = c.getNodeTokenString(left);

        const nameId = try ensureNameSym(c.compiler, name);
        const symId = try ensureSym(c, null, nameId, null);

        // Mark as used since there is an initializer that could alter state.
        c.semaSyms.items[symId].used = true;
        c.nodes[nodeId].head.varDecl.semaSymId = symId;

        _ = try resolveLocalVarSym(c, symId, c.semaResolvedRootSymId, nameId, nodeId, exported);

        c.curSemaSymVar = symId;
        c.semaVarDeclDeps.clearRetainingCapacity();
        defer c.curSemaSymVar = cy.NullId;

        const right = c.nodes[node.head.varDecl.right];
        if (right.node_t == .matchBlock) {
            _ = try semaMatchBlock(c, node.head.varDecl.right, true);
        } else {
            _ = semaExpr(c, node.head.varDecl.right, false) catch |err| {
                if (err == error.CanNotUseLocal) {
                    const local = c.nodes[c.compiler.errorPayload];
                    const localName = c.getNodeTokenString(local);
                    return c.reportErrorAt("The declaration of static variable `{}` can not reference the local variable `{}`.", &.{v(name), v(localName)}, nodeId);
                } else {
                    return err;
                } 
            };
        }
    } else {
        return c.reportErrorAt("Static variable declarations can only have an identifier as the name. Parsed {} instead.", &.{fmt.v(left.node_t)}, nodeId);
    }
}

fn semaExpr(c: *cy.CompileChunk, nodeId: cy.NodeId, comptime discardTopExprReg: bool) anyerror!Type {
    c.curNodeId = nodeId;
    const node = c.nodes[nodeId];
    // log.debug("sema expr {}", .{node.node_t});
    switch (node.node_t) {
        .true_literal => {
            return BoolType;
        },
        .false_literal => {
            return BoolType;
        },
        .none => {
            return AnyType;
        },
        .arr_literal => {
            var expr_id = node.head.child_head;
            var i: u32 = 0;
            while (expr_id != cy.NullId) : (i += 1) {
                var expr = c.nodes[expr_id];
                _ = try semaExpr(c, expr_id, discardTopExprReg);
                expr_id = expr.next;
            }

            return ListType;
        },
        .tagLiteral => {
            return TagLiteralType;
        },
        .tagInit => {
            const nameN = c.nodes[node.head.left_right.left];
            const name = c.getNodeTokenString(nameN);
            const tid = try c.compiler.vm.ensureTagType(name);
            return initTagType(tid);
        },
        .objectInit => {
            _ = try semaExpr(c, node.head.objectInit.name, discardTopExprReg);
            const nameN = c.nodes[node.head.objectInit.name];
            if (nameN.node_t == .ident) {
                c.nodes[nodeId].head.objectInit.semaSymId = nameN.head.ident.semaSymId;
            } else if (nameN.node_t == .accessExpr) {
                c.nodes[nodeId].head.objectInit.semaSymId = nameN.head.accessExpr.semaSymId;
            }

            const initializer = c.nodes[node.head.objectInit.initializer];
            var i: u32 = 0;
            var entry_id = initializer.head.child_head;
            while (entry_id != cy.NullId) : (i += 1) {
                var entry = c.nodes[entry_id];
                _ = try semaExpr(c, entry.head.mapEntry.right, discardTopExprReg);
                entry_id = entry.next;
            }
            return AnyType;
        },
        .map_literal => {
            var i: u32 = 0;
            var entry_id = node.head.child_head;
            while (entry_id != cy.NullId) : (i += 1) {
                var entry = c.nodes[entry_id];

                _ = try semaExpr(c, entry.head.mapEntry.right, discardTopExprReg);
                entry_id = entry.next;
            }
            return MapType;
        },
        .nonDecInt => {
            const literal = c.getNodeTokenString(node);
            var val: u64 = undefined;
            if (literal[1] == 'x') {
                val = try std.fmt.parseInt(u64, literal[2..], 16);
            } else if (literal[1] == 'o') {
                val = try std.fmt.parseInt(u64, literal[2..], 8);
            } else if (literal[1] == 'b') {
                val = try std.fmt.parseInt(u64, literal[2..], 2);
            }
            if (std.math.cast(i32, val) != null) {
                return NumberOrRequestIntegerType;
            }
            return NumberType;
        },
        .number => {
            const literal = c.getNodeTokenString(node);
            const val = try std.fmt.parseFloat(f64, literal);
            if (cy.Value.floatCanBeInteger(val)) {
                const int = @floatToInt(i64, val);
                if (std.math.cast(i32, int) != null) {
                    return NumberOrRequestIntegerType;
                }
            }
            return NumberType;
        },
        .string => {
            return StaticStringType;
        },
        .stringTemplate => {
            var expStringPart = true;
            var curId = node.head.stringTemplate.partsHead;
            while (curId != cy.NullId) {
                const cur = c.nodes[curId];
                if (!expStringPart) {
                    _ = try semaExpr(c, curId, discardTopExprReg);
                }
                curId = cur.next;
                expStringPart = !expStringPart;
            }
            return StringType;
        },
        .ident => {
            const name = c.getNodeTokenString(node);
            const res = try getOrLookupVar(c, name, .read);
            if (res.isLocal) {
                c.nodes[nodeId].head.ident.semaVarId = res.varId;
                return c.vars.items[res.varId].vtype;
            } else {
                const symId = try referenceSym(c, null, name, null, nodeId, true);
                c.nodes[nodeId].head.ident.semaSymId = symId;
                return AnyType;
            }
        },
        .if_expr => {
            _ = try semaExpr(c, node.head.if_expr.cond, false);

            _ = try semaExpr(c, node.head.if_expr.body_expr, discardTopExprReg);

            if (node.head.if_expr.else_clause != cy.NullId) {
                const else_clause = c.nodes[node.head.if_expr.else_clause];
                _ = try semaExpr(c, else_clause.head.child_head, discardTopExprReg);
            }
            return AnyType;
        },
        .arr_range_expr => {
            _ = try semaExpr(c, node.head.arr_range_expr.arr, discardTopExprReg);

            if (node.head.arr_range_expr.left == cy.NullId) {
                // nop
            } else {
                _ = try semaExpr(c, node.head.arr_range_expr.left, discardTopExprReg);
            }
            if (node.head.arr_range_expr.right == cy.NullId) {
                // nop
            } else {
                _ = try semaExpr(c, node.head.arr_range_expr.right, discardTopExprReg);
            }

            return ListType;
        },
        .accessExpr => {
            return semaAccessExpr(c, nodeId, discardTopExprReg);
        },
        .arr_access_expr => {
            _ = try semaExpr(c, node.head.left_right.left, discardTopExprReg);

            const index = c.nodes[node.head.left_right.right];
            if (index.node_t == .unary_expr and index.head.unary.op == .minus) {
                _ = try semaExpr(c, index.head.unary.child, discardTopExprReg);
            } else {
                _ = try semaExpr(c, node.head.left_right.right, discardTopExprReg);
            }
            return AnyType;
        },
        .comptExpr => {
            _ = try semaExpr(c, node.head.child_head, discardTopExprReg);
            return AnyType;
        },
        .tryExpr => {
            _ = try semaExpr(c, node.head.child_head, discardTopExprReg);
            return AnyType;
        },
        .unary_expr => {
            const op = node.head.unary.op;
            switch (op) {
                .minus => {
                    _ = try semaExpr(c, node.head.unary.child, discardTopExprReg);
                    return NumberType;
                },
                .not => {
                    _ = try semaExpr(c, node.head.unary.child, discardTopExprReg);
                    return BoolType;
                },
                .bitwiseNot => {
                    _ = try semaExpr(c, node.head.unary.child, discardTopExprReg);
                    return NumberType;
                },
                // else => return self.reportErrorAt("Unsupported unary op: {}", .{op}, node),
            }
        },
        .group => {
            return semaExpr(c, node.head.child_head, discardTopExprReg);
        },
        .binExpr => {
            const left = node.head.binExpr.left;
            const right = node.head.binExpr.right;

            const op = node.head.binExpr.op;
            switch (op) {
                .plus => {
                    const ltype = try semaExpr(c, left, discardTopExprReg);
                    _ = try semaExpr(c, right, discardTopExprReg);
                    if (ltype.typeT == .string) {
                        return StringType;
                    } else {
                        return NumberType;
                    }
                },
                .star => {
                    _ = try semaExpr(c, left, discardTopExprReg);
                    _ = try semaExpr(c, right, discardTopExprReg);
                    return NumberType;
                },
                .slash => {
                    _ = try semaExpr(c, left, discardTopExprReg);
                    _ = try semaExpr(c, right, discardTopExprReg);
                    return NumberType;
                },
                .percent => {
                    _ = try semaExpr(c, left, discardTopExprReg);
                    _ = try semaExpr(c, right, discardTopExprReg);
                    return NumberType;
                },
                .caret => {
                    _ = try semaExpr(c, left, discardTopExprReg);
                    _ = try semaExpr(c, right, discardTopExprReg);
                    return NumberType;
                },
                .minus => {
                    _ = try semaExpr(c, left, discardTopExprReg);
                    _ = try semaExpr(c, right, discardTopExprReg);
                    return NumberType;
                },
                .bitwiseAnd => {
                    _ = try semaExpr(c, left, discardTopExprReg);
                    _ = try semaExpr(c, right, discardTopExprReg);
                    return NumberType;
                },
                .bitwiseOr => {
                    _ = try semaExpr(c, left, discardTopExprReg);
                    _ = try semaExpr(c, right, discardTopExprReg);
                    return NumberType;
                },
                .bitwiseXor => {
                    _ = try semaExpr(c, left, discardTopExprReg);
                    _ = try semaExpr(c, right, discardTopExprReg);
                    return NumberType;
                },
                .bitwiseLeftShift => {
                    _ = try semaExpr(c, left, discardTopExprReg);
                    _ = try semaExpr(c, right, discardTopExprReg);
                    return NumberType;
                },
                .bitwiseRightShift => {
                    _ = try semaExpr(c, left, discardTopExprReg);
                    _ = try semaExpr(c, right, discardTopExprReg);
                    return NumberType;
                },
                .and_op => {
                    const ltype = try semaExpr(c, left, discardTopExprReg);
                    const rtype = try semaExpr(c, right, discardTopExprReg);
                    if (ltype.typeT == rtype.typeT) {
                        return ltype;
                    } else return AnyType;
                },
                .or_op => {
                    const ltype = try semaExpr(c, left, discardTopExprReg);
                    const rtype = try semaExpr(c, right, discardTopExprReg);
                    if (ltype.typeT == rtype.typeT) {
                        return ltype;
                    } else return AnyType;
                },
                .bang_equal => {
                    _ = try semaExpr(c, left, discardTopExprReg);
                    _ = try semaExpr(c, right, discardTopExprReg);
                    return BoolType;
                },
                .equal_equal => {
                    _ = try semaExpr(c, left, discardTopExprReg);
                    _ = try semaExpr(c, right, discardTopExprReg);
                    return BoolType;
                },
                .less => {
                    const leftT = try semaExpr(c, left, discardTopExprReg);
                    const rightT = try semaExpr(c, right, discardTopExprReg);
                    const canRequestLeftInt = leftT.typeT == .int or (leftT.typeT == .number and leftT.inner.number.canRequestInteger);
                    const canRequestRightInt = rightT.typeT == .int or (rightT.typeT == .number and rightT.inner.number.canRequestInteger);
                    if (canRequestLeftInt and canRequestRightInt) {
                        c.nodes[nodeId].head.binExpr.semaCanRequestIntegerOperands = true;
                    }
                    return BoolType;
                },
                .less_equal => {
                    _ = try semaExpr(c, left, discardTopExprReg);
                    _ = try semaExpr(c, right, discardTopExprReg);
                    return BoolType;
                },
                .greater => {
                    _ = try semaExpr(c, left, discardTopExprReg);
                    _ = try semaExpr(c, right, discardTopExprReg);
                    return BoolType;
                },
                .greater_equal => {
                    _ = try semaExpr(c, left, discardTopExprReg);
                    _ = try semaExpr(c, right, discardTopExprReg);
                    return BoolType;
                },
                else => return c.reportErrorAt("Unsupported binary op: {}", &.{fmt.v(op)}, nodeId),
            }
        },
        .coyield => {
            return AnyType;
        },
        .coresume => {
            _ = try semaExpr(c, node.head.child_head, false);
            return AnyType;
        },
        .coinit => {
            _ = try semaExpr(c, node.head.child_head, false);
            return FiberType;
        },
        .callExpr => {
            const callee = c.nodes[node.head.callExpr.callee];
            if (!node.head.callExpr.has_named_arg) {
                if (callee.node_t == .accessExpr) {
                    _ = try semaExpr(c, callee.head.accessExpr.left, false);

                    var numArgs: u32 = 0;
                    var arg_id = node.head.callExpr.arg_head;
                    while (arg_id != cy.NullId) : (numArgs += 1) {
                        const arg = c.nodes[arg_id];
                        _ = try semaExpr(c, arg_id, false);
                        arg_id = arg.next;
                    }

                    const left = c.nodes[callee.head.accessExpr.left];
                    var leftSymId: u32 = cy.NullId;
                    if (left.node_t == .ident) {
                        leftSymId = left.head.ident.semaSymId;
                    } else if (left.node_t == .accessExpr) {
                        leftSymId = left.head.accessExpr.semaSymId;
                    }
                    if (leftSymId != cy.NullId) {
                        // Left is a sym candidate.
                        const right = c.nodes[callee.head.accessExpr.right];
                        const name = c.getNodeTokenString(right);

                        const funcSigId = try ensureUntypedFuncSig(c, numArgs);
                        const symId = try referenceSym(c, leftSymId, name, funcSigId, callee.head.accessExpr.right, true);
                        c.nodes[node.head.callExpr.callee].head.accessExpr.semaSymId = symId;
                    }

                    return AnyType;
                } else if (callee.node_t == .ident) {
                    const name = c.getNodeTokenString(callee);
                    const res = try getOrLookupVar(c, name, .read);
                    if (res.isLocal) {
                        c.nodes[node.head.callExpr.callee].head.ident.semaVarId = res.varId;

                        var numArgs: u32 = 1;
                        var arg_id = node.head.callExpr.arg_head;
                        while (arg_id != cy.NullId) : (numArgs += 1) {
                            const arg = c.nodes[arg_id];
                            _ = try semaExpr(c, arg_id, false);
                            arg_id = arg.next;
                        }

        //                 // Load callee after args so it can be easily discarded.
        //                 try self.genLoadLocal(info);
                        return AnyType;
                    } else {
                        var numArgs: u32 = 0;
                        var arg_id = node.head.callExpr.arg_head;
                        while (arg_id != cy.NullId) : (numArgs += 1) {
                            const arg = c.nodes[arg_id];
                            _ = try semaExpr(c, arg_id, false);
                            arg_id = arg.next;
                        }

                        // Ensure func sym.
                        const funcSigId = try ensureUntypedFuncSig(c, numArgs);
                        const symId = try referenceSym(c, null, name, funcSigId, node.head.callExpr.callee, true);
                        c.nodes[node.head.callExpr.callee].head.ident.semaSymId = symId;

                        return AnyType;
                    }
                } else {
                    // All other callees are treated as function value calls.
                    var numArgs: u32 = 0;
                    var arg_id = node.head.callExpr.arg_head;
                    while (arg_id != cy.NullId) : (numArgs += 1) {
                        const arg = c.nodes[arg_id];
                        _ = try semaExpr(c, arg_id, false);
                        arg_id = arg.next;
                    }

                    _ = try semaExpr(c, node.head.callExpr.callee, false);
                    return AnyType;
                }
            } else return c.reportErrorAt("Unsupported named args", &.{}, nodeId);
        },
        .lambda_multi => {
            if (!discardTopExprReg) {
                const blockId = try pushBlock(c, node.head.func.decl_id);

                // Generate function body.
                const func = &c.funcDecls[node.head.func.decl_id];
                func.semaBlockId = blockId;
                try pushFuncParamVars(c, func);
                try semaStmts(c, node.head.func.body_head, false);

                const numParams = func.params.len();
                try endFuncBlock(c, numParams);

                const rFuncSigId = try ensureResolvedUntypedFuncSig(c.compiler, numParams);
                func.inner.lambda.rFuncSigId = rFuncSigId;
            }
            return AnyType;
        },
        .lambda_expr => {
            if (!discardTopExprReg) {
                const blockId = try pushBlock(c, node.head.func.decl_id);

                // Generate function body.
                const func = &c.funcDecls[node.head.func.decl_id];
                func.semaBlockId = blockId;
                try pushFuncParamVars(c, func);
                _ = try semaExpr(c, node.head.func.body_head, false);

                const numParams = func.params.len();
                try endFuncBlock(c, numParams);

                const rFuncSigId = try ensureResolvedUntypedFuncSig(c.compiler, numParams);
                func.inner.lambda.rFuncSigId = rFuncSigId;
            }
            return AnyType;
        },
        else => return c.reportErrorAt("Unsupported node", &.{}, nodeId),
    }
}

pub fn pushBlock(self: *cy.CompileChunk, funcDeclId: u32) !BlockId {
    self.curSemaBlockId = @intCast(u32, self.semaBlocks.items.len);
    const nextSubBlockId = @intCast(u32, self.semaSubBlocks.items.len);
    var isStaticFuncBlock = false;
    if (funcDeclId != cy.NullId) {
        isStaticFuncBlock = self.funcDecls[funcDeclId].isStatic;
    }
    try self.semaBlocks.append(self.alloc, Block.init(funcDeclId, nextSubBlockId, isStaticFuncBlock));
    try self.semaBlockStack.append(self.alloc, self.curSemaBlockId);
    try pushSubBlock(self);
    return self.curSemaBlockId;
}

fn pushSubBlock(self: *cy.CompileChunk) !void {
    curBlock(self).subBlockDepth += 1;
    const prev = self.curSemaSubBlockId;
    self.curSemaSubBlockId = @intCast(u32, self.semaSubBlocks.items.len);
    try self.semaSubBlocks.append(self.alloc, SubBlock.init(prev, self.assignedVarStack.items.len));
}

fn pushMethodParamVars(c: *cy.CompileChunk, func: *const cy.FuncDecl) !void {
    const sblock = curBlock(c);

    if (func.params.end > func.params.start) {
        for (c.funcParams[func.params.start + 1..func.params.end]) |param| {
            const paramName = c.src[param.name.start..param.name.end];
            const paramT = AnyType;
            const id = try pushLocalVar(c, paramName, paramT);
            try sblock.params.append(c.alloc, id);
        }
    }

    // Add self receiver param.
    var id = try pushLocalVar(c, "self", AnyType);
    try sblock.params.append(c.alloc, id);
}

fn pushFuncParamVars(c: *cy.CompileChunk, func: *const cy.FuncDecl) !void {
    const sblock = curBlock(c);

    if (func.params.end > func.params.start) {
        for (c.funcParams[func.params.start..func.params.end]) |param| {
            const paramName = c.src[param.name.start..param.name.end];
            var paramT = AnyType;
            if (param.typeSpec != cy.NullId) {
                const spec = c.nodes[param.typeSpec];
                const typeName = c.getNodeTokenString(spec);
                if (c.compiler.typeNames.get(typeName)) |vtype| {
                    paramT = vtype;
                }
            }
            const id = try pushLocalVar(c, paramName, paramT);
            try sblock.params.append(c.alloc, id);
        }
    }
}

fn pushLocalVar(c: *cy.CompileChunk, name: []const u8, vtype: Type) !LocalVarId {
    const sblock = curBlock(c);
    const id = @intCast(u32, c.vars.items.len);
    const res = try sblock.nameToVar.getOrPut(c.alloc, name);
    if (res.found_existing) {
        return c.reportError("Var `{}` already exists", &.{v(name)});
    } else {
        res.value_ptr.* = id;
        try c.vars.append(c.alloc, .{
            .name = if (builtin.mode == .Debug) name else {},
            .vtype = toLocalType(vtype),
            .lifetimeRcCandidate = vtype.rcCandidate,
        });
        return id;
    }
}

fn getVarPtr(self: *cy.CompileChunk, name: []const u8) ?*LocalVar {
    if (curBlock(self).nameToVar.get(name)) |varId| {
        return &self.vars.items[varId];
    } else return null;
}

fn pushStaticVarAlias(c: *cy.CompileChunk, name: []const u8, varSymId: SymId) !LocalVarId {
    const id = try pushLocalVar(c, name, AnyType);
    c.vars.items[id].isStaticAlias = true;
    c.vars.items[id].inner.symId = varSymId;
    return id;
}

fn pushCapturedVar(self: *cy.CompileChunk, name: []const u8, parentVarId: LocalVarId, vtype: Type) !LocalVarId {
    const id = try pushLocalVar(self, name, vtype);
    self.vars.items[id].isCaptured = true;
    self.vars.items[id].isBoxed = true;
    try self.capVarDescs.put(self.alloc, id, .{
        .user = parentVarId,
    });
    try curBlock(self).params.append(self.alloc, id);
    return id;
}

fn pushLocalBodyVar(self: *cy.CompileChunk, name: []const u8, vtype: Type) !LocalVarId {
    const id = try pushLocalVar(self, name, vtype);
    try curBlock(self).locals.append(self.alloc, id);
    return id;
}

fn ensureLocalBodyVar(self: *cy.CompileChunk, ident: cy.NodeId, vtype: Type) !LocalVarId {
    const node = self.nodes[ident];
    const name = self.getNodeTokenString(node);
    if (curBlock(self).nameToVar.get(name)) |varId| {
        self.nodes[ident].head.ident.semaVarId = varId;
        return varId;
    } else {
        const id = try pushLocalBodyVar(self, name, vtype);
        self.nodes[ident].head.ident.semaVarId = id;
        return id;
    }
}

fn referenceSym(c: *cy.CompileChunk, parentId: ?SymId, name: []const u8, funcSigId: ?FuncSigId, nodeId: cy.NodeId, trackDep: bool) !SymId {
    const nameId = try ensureNameSym(c.compiler, name);
    const symId = try ensureSym(c, parentId, nameId, funcSigId);
    
    // Mark as used so it is compiled.
    c.semaSyms.items[symId].used = true;

    // Link a node to this sym for error reporting.
    linkNodeToSym(c, nodeId, symId);

    if (trackDep) {
        if (c.curSemaSymVar != cy.NullId) {
            // Record this symbol as a dependency.
            const res = try c.semaInitializerSyms.getOrPut(c.alloc, c.curSemaSymVar);
            if (res.found_existing) {
                const depRes = try c.semaVarDeclDeps.getOrPut(c.alloc, symId);
                if (!depRes.found_existing) {
                    try c.bufU32.append(c.alloc, symId);
                    res.value_ptr.*.depsEnd = @intCast(u32, c.bufU32.items.len);
                    depRes.value_ptr.* = {};
                }
            } else {
                const start = @intCast(u32, c.bufU32.items.len);
                try c.bufU32.append(c.alloc, symId);
                res.value_ptr.* = .{
                    .depsStart = start,
                    .depsEnd = @intCast(u32, c.bufU32.items.len),
                };
            }
        }
    }

    return symId;
}

const VarLookupStrategy = enum {
    // Look upwards for a parent local. If no such local exists, assume a static var.
    read,
    // Assume a static var.
    staticAssign,
    // Look upwards for a parent local. If no such local exists, a compile error is returned.
    captureAssign,
    // If missing in the current block, a new local is created.
    assign,
};

const VarLookupResult = struct {
    /// If `isLocal` is false, varId is cy.NullId.
    varId: LocalVarId,
    isLocal: bool,
    /// Whether the local var was created.
    created: bool,
};

fn getOrLookupVar(self: *cy.CompileChunk, name: []const u8, strat: VarLookupStrategy) !VarLookupResult {
    const sblock = curBlock(self);
    if (sblock.nameToVar.get(name)) |varId| {
        const svar = self.vars.items[varId];
        switch (strat) {
            .read => {
                if (!svar.isStaticAlias) {
                    // Can not reference local var in a static var decl unless it's in a nested block.
                    // eg. a = 0
                    //     var b = a
                    if (self.isInStaticInitializer() and self.semaBlockDepth() == 1) {
                        self.compiler.errorPayload = self.curNodeId;
                        return error.CanNotUseLocal;
                    }
                    return VarLookupResult{
                        .varId = varId,
                        .isLocal = true,
                        .created = false,
                    };
                } else {
                    return VarLookupResult{
                        .varId = cy.NullId,
                        .isLocal = false,
                        .created = false,
                    };
                }
            },
            .assign => {
                if (svar.isStaticAlias) {
                    // Assumes static variables can only exist in the main block.
                    if (svar.hasCaptureOrStaticModifier or self.semaBlockDepth() == 1) {
                        return VarLookupResult{
                            .varId = cy.NullId,
                            .isLocal = false,
                            .created = false,
                        };
                    } else {
                        return self.reportError("`{}` already references a static variable. The variable must be declared with `static` before assigning to it.", &.{v(name)});
                    }
                } else if (svar.isCaptured) {
                    if (svar.hasCaptureOrStaticModifier) {
                        return VarLookupResult{
                            .varId = varId,
                            .isLocal = true,
                            .created = false,
                        };
                    } else {
                        return self.reportError("`{}` already references a captured variable. The variable must be declared with `capture` before assigning to it.", &.{v(name)});
                    }
                } else {
                    return VarLookupResult{
                        .varId = varId,
                        .isLocal = true,
                        .created = false,
                    };
                }
            },
            .captureAssign => {
                if (!svar.isCaptured) {
                    // Previously not captured, update to captured.
                    return self.reportError("TODO: update to captured variable", &.{});
                } else {
                    return VarLookupResult{
                        .varId = varId,
                        .isLocal = true,
                        .created = false,
                    };
                }
            },
            .staticAssign => {
                if (!svar.isStaticAlias) {
                    // Previously not static alias, update to static alias.
                    return self.reportError("TODO: update to static alias", &.{});
                } else {
                    return VarLookupResult{
                        .varId = cy.NullId,
                        .isLocal = false,
                        .created = false,
                    };
                }
            },
            // When typed declaration is implemented, that can create a new local if the variable was previously implicity captured.
            // // Create a new local var and update mapping so any references after will refer to the local var.
            // const sblock = curBlock(self);
            // _ = sblock.nameToVar.remove(name);
            // const id = try pushLocalBodyVar(self, name, vtype);
            // if (sblock.subBlockDepth > 1) {
            //     self.vars.items[id].genInitializer = true;
            // }
        }
    }

    // Perform lookup based on the strategy. See `VarLookupStrategy`.
    switch (strat) {
        .read => {
            if (lookupParentLocal(self, name)) |res| {
                if (self.isInStaticInitializer()) {
                    // Can not capture local before this block.
                    if (res.blockDepth == 1) {
                        self.compiler.errorPayload = self.curNodeId;
                        return error.CanNotUseLocal;
                    }
                } else if (sblock.isStaticFuncBlock) {
                    // Can not capture local before static function block.
                    const funcDecl = self.funcDecls[sblock.funcDeclId];
                    const funcName = funcDecl.getName(self);
                    return self.reportErrorAt("Can not capture the local variable `{}` from static function `{}`.\nOnly lambdas (function values) can capture local variables.", &.{v(name), v(funcName)}, self.curNodeId);
                }

                // Create a local captured variable.
                const parentVar = self.vars.items[res.varId];
                const id = try pushCapturedVar(self, name, res.varId, parentVar.vtype);
                return VarLookupResult{
                    .varId = id,
                    .isLocal = true,
                    .created = true,
                };
            } else {
                const nameId = try ensureNameSym(self.compiler, name);
                const symId = try ensureSym(self, null, nameId, null);
                _ = try pushStaticVarAlias(self, name, symId);
                return VarLookupResult{
                    .varId = cy.NullId,
                    .isLocal = false,
                    .created = false,
                };
            }
        },
        .staticAssign => {
            const nameId = try ensureNameSym(self.compiler, name);
            const symId = try ensureSym(self, null, nameId, null);
            const id = try pushStaticVarAlias(self, name, symId);
            self.vars.items[id].hasCaptureOrStaticModifier = true;
            return VarLookupResult{
                .varId = cy.NullId,
                .isLocal = false,
                .created = true,
            };
        },
        .captureAssign => {
            if (lookupParentLocal(self, name)) |res| {
                if (self.isInStaticInitializer()) {
                    if (res.blockDepth == 1) {
                        return self.reportError("Can not use local in static variable initializer.", &.{});
                    }
                } else if (sblock.isStaticFuncBlock) {
                    // Can not capture local before static function block.
                    const funcDecl = self.funcDecls[sblock.funcDeclId];
                    const funcName = funcDecl.getName(self);
                    return self.reportErrorAt("Can not capture the local variable `{}` from static function `{}`.\nOnly lambdas (function values) can capture local variables.", &.{v(name), v(funcName)}, self.curNodeId);
                }
                // Create a local captured variable.
                const parentVar = self.vars.items[res.varId];
                const id = try pushCapturedVar(self, name, res.varId, parentVar.vtype);
                self.vars.items[id].hasCaptureOrStaticModifier = true;
                return VarLookupResult{
                    .varId = id,
                    .isLocal = true,
                    .created = true,
                };
            } else {
                return self.reportError("Could not find a parent local named `{}`.", &.{v(name)});
            }
        },
        .assign => {
            // Prefer static variable in the same block.
            // For now, only do this for main block.
            if (self.semaBlockDepth() == 1) {
                const nameId = try ensureNameSym(self.compiler, name);
                if (hasLocalSym(self, null, nameId)) {
                    return VarLookupResult{
                        .varId = cy.NullId,
                        .isLocal = false,
                        .created = false,
                    };
                }
            }
            const id = try pushLocalBodyVar(self, name, UndefinedType);
            if (sblock.subBlockDepth > 1) {
                self.vars.items[id].genInitializer = true;
            }
            return VarLookupResult{
                .varId = id,
                .isLocal = true,
                .created = true,
            };
        },
    }
}

const LookupParentLocalResult = struct {
    varId: LocalVarId,

    // Main block starts at 1.
    blockDepth: u32,
};

fn lookupParentLocal(c: *cy.CompileChunk, name: []const u8) ?LookupParentLocalResult {
    // Only check one block above.
    if (c.semaBlockDepth() > 1) {
        const prevId = c.semaBlockStack.items[c.semaBlockDepth() - 1];
        const prev = c.semaBlocks.items[prevId];
        if (prev.nameToVar.get(name)) |varId| {
            if (!c.vars.items[varId].isStaticAlias) {
                return .{
                    .varId = varId,
                    .blockDepth = c.semaBlockDepth(),
                };
            }
        }
    }
    return null;
}

pub const SymBuiltinAny: SymId = 0;

fn getResolvedBuiltinTypeSym(typeT: TypeTag) SymId {
    switch (typeT) {
        .any => {
            return SymBuiltinAny;
        },
        else => stdx.panicFmt("Unsupported builtin type: {}", .{typeT}),
    }
}

pub fn addResolvedBuiltinSym(c: *cy.VMcompiler, typeT: TypeTag, literal: []const u8) !ResolvedSymId {
    const nameId = try ensureNameSym(c, literal);
    const key = AbsResolvedSymKey{
        .absResolvedSymKey = .{
            .rParentSymId = cy.NullId,
            .nameId = nameId,
        },
    };

    const id = @intCast(u32, c.semaResolvedSyms.items.len);
    try c.semaResolvedSyms.append(c.alloc, .{
        .key = key,
        .symT = .builtinType,
        .inner = .{
            .builtinType = .{
                .typeT = @enumToInt(typeT),
            },
        },
        .exported = true,
    });
    try c.semaResolvedSymMap.put(c.alloc, key, id);
    return id;
}

pub fn ensureUntypedFuncSig(c: *cy.CompileChunk, numParams: u32) !FuncSigId {
    if (numParams < c.semaUntypedFuncSigs.items.len) {
        var funcSigId = c.semaUntypedFuncSigs.items[numParams];
        if (funcSigId == cy.NullId) {
            funcSigId = try addUntypedFuncSig(c, numParams);
        }
        return funcSigId;
    }

    const end = c.semaUntypedFuncSigs.items.len;
    try c.semaUntypedFuncSigs.resize(c.alloc, numParams + 1);
    for (end..c.semaUntypedFuncSigs.items.len) |i| {
        c.semaUntypedFuncSigs.items[i] = cy.NullId;
    }
    const funcSigId = try addUntypedFuncSig(c, numParams);
    c.semaUntypedFuncSigs.items[numParams] = funcSigId;
    return funcSigId;
}

fn addUntypedFuncSig(c: *cy.CompileChunk, numParams: u32) !FuncSigId {
    const anyName = try ensureNameSym(c.compiler, "any");
    const anySym = try ensureSym(c, null, anyName, null);

    try c.compiler.tempSyms.resize(c.alloc, numParams + 1);
    for (c.compiler.tempSyms.items) |*symId| {
        symId.* = anySym;
    }
    return ensureFuncSig(c, c.compiler.tempSyms.items);
}

fn ensureFuncSig(c: *cy.CompileChunk, sig: []const SymId) !ResolvedFuncSigId {
    const res = try c.semaFuncSigMap.getOrPut(c.alloc, sig);
    if (res.found_existing) {
        return res.value_ptr.*;
    } else {
        const id = @intCast(u32, c.semaFuncSigs.items.len);
        const new = try c.alloc.dupe(SymId, sig);
        try c.semaFuncSigs.append(c.alloc, .{
            .sig = new,
            .rFuncSigId = cy.NullId,
        });
        res.value_ptr.* = id;
        res.key_ptr.* = new;
        return id;
    }
}

fn addResolvedUntypedFuncSig(c: *cy.VMcompiler, numParams: u32) !ResolvedFuncSigId {
    // AnyType for params and return.
    try c.tempTypes.resize(c.alloc, numParams + 1);
    for (c.tempTypes.items) |*stype| {
        stype.* = AnyType;
    }
    return ensureResolvedFuncSigTypes(c, c.tempTypes.items);
}

pub fn ensureResolvedUntypedFuncSig(c: *cy.VMcompiler, numParams: u32) !ResolvedFuncSigId {
    if (numParams < c.semaResolvedUntypedFuncSigs.items.len) {
        var rFuncSigId = c.semaResolvedUntypedFuncSigs.items[numParams];
        if (rFuncSigId == cy.NullId) {
            rFuncSigId = try addResolvedUntypedFuncSig(c, numParams);
            c.semaResolvedUntypedFuncSigs.items[numParams] = rFuncSigId;
        }
        return rFuncSigId;
    }
    const end = c.semaResolvedUntypedFuncSigs.items.len;
    try c.semaResolvedUntypedFuncSigs.resize(c.alloc, numParams + 1);
    for (end..c.semaResolvedUntypedFuncSigs.items.len) |i| {
        c.semaResolvedUntypedFuncSigs.items[i] = cy.NullId;
    }
    const rFuncSigId = try addResolvedUntypedFuncSig(c, numParams);
    c.semaResolvedUntypedFuncSigs.items[numParams] = rFuncSigId;
    return rFuncSigId;
}

fn ensureResolvedFuncSigTypes(c: *cy.VMcompiler, types: []const Type) !ResolvedFuncSigId {
    try c.tempSyms.resize(c.alloc, types.len);
    for (types, 0..) |stype, i| {
        const rsymId = getResolvedBuiltinTypeSym(stype.typeT);
        c.tempSyms.items[i] = rsymId;
    }
    return ensureResolvedFuncSig(c, c.tempSyms.items);
}

fn ensureResolvedFuncSig(c: *cy.VMcompiler, sig: []const ResolvedSymId) !ResolvedFuncSigId {
    const res = try c.semaResolvedFuncSigMap.getOrPut(c.alloc, sig);
    if (res.found_existing) {
        return res.value_ptr.*;
    } else {
        const id = @intCast(u32, c.semaResolvedFuncSigs.items.len);
        const new = try c.alloc.dupe(ResolvedSymId, sig);
        var isTyped = false;
        for (sig) |rSymId| {
            const rSym = c.semaResolvedSyms.items[rSymId];
            if (rSym.symT != .builtinType or rSym.inner.builtinType.typeT != @enumToInt(TypeTag.any)) {
                isTyped = true;
                break;
            }
        }
        try c.semaResolvedFuncSigs.append(c.alloc, .{
            .sigPtr = new.ptr,
            .sigLen = @intCast(u32, new.len),
            .isTyped = isTyped,
        });
        res.value_ptr.* = id;
        res.key_ptr.* = new;
        return id;
    }
}

fn resolveFuncSig(self: *cy.CompileChunk, funcSigId: SymId) !ResolvedFuncSigId {
    const funcSig = self.semaFuncSigs.items[funcSigId];

    try self.compiler.tempSyms.resize(self.alloc, funcSig.sig.len);
    for (funcSig.sig, 0..) |symId, i| {
        const paramSym = self.semaSyms.items[symId];
        var rParamSymId = paramSym.rSymId;
        if (rParamSymId == cy.NullId) {
            try resolveSym(self, symId);
            rParamSymId = self.semaSyms.items[symId].rSymId;
            if (rParamSymId == cy.NullId) {
                const name = getName(self.compiler, paramSym.key.absLocalSymKey.nameId);
                return self.reportError("Cannot resolve param type: `{}`.", &.{v(name)});
            }
        }
        self.compiler.tempSyms.items[i] = rParamSymId;
    }
    const id = try ensureResolvedFuncSig(self.compiler, self.compiler.tempSyms.items);
    self.semaFuncSigs.items[funcSigId].rFuncSigId = id;
    return id;
}

/// Format: (Type, ...) RetType
pub fn getResolvedFuncSigTempStr(c: *cy.VMcompiler, rFuncSigId: ResolvedFuncSigId) ![]const u8 {
    c.vm.u8Buf.clearRetainingCapacity();
    const w = c.vm.u8Buf.writer(c.alloc);
    try writeResolvedFuncSigStr(c, w, rFuncSigId);
    return c.vm.u8Buf.items();
}

pub fn writeResolvedFuncSigStr(c: *cy.VMcompiler, w: anytype, rFuncSigId: ResolvedFuncSigId) !void {
    const rFuncSig = c.semaResolvedFuncSigs.items[rFuncSigId];
    try w.writeAll("(");

    if (rFuncSig.sigLen > 1) {
        var rParamSym = c.semaResolvedSyms.items[rFuncSig.sigPtr[0]];
        var name = getName(c, rParamSym.key.absResolvedSymKey.nameId);
        try w.writeAll(name);

        if (rFuncSig.sigLen > 2) {
            for (rFuncSig.sigPtr[1..rFuncSig.sigLen-1]) |rParamSymId| {
                try w.writeAll(", ");
                rParamSym = c.semaResolvedSyms.items[rParamSymId];
                name = getName(c, rParamSym.key.absResolvedSymKey.nameId);
                try w.writeAll(name);
            }
        }
    }
    try w.writeAll(") ");

    var rRetSym = c.semaResolvedSyms.items[rFuncSig.sigPtr[rFuncSig.sigLen-1]];
    var name = getName(c, rRetSym.key.absResolvedSymKey.nameId);
    try w.writeAll(name);
}

pub fn resolveSym(self: *cy.CompileChunk, symId: SymId) anyerror!void {
    const sym = &self.semaSyms.items[symId];
    log.debug("resolving {} {}.{s}, sig: {}", .{symId, sym.key.absLocalSymKey.parentSymId, getSymName(self.compiler, sym), sym.key.absLocalSymKey.funcSigId});
    defer {
        if (sym.rSymId != cy.NullId) {
            const rsym = self.compiler.semaResolvedSyms.items[sym.rSymId];
            const key = rsym.key.absResolvedSymKey;
            log.debug("resolved id: {}, rParentSymId: {}, type: {}", .{sym.rSymId, key.rParentSymId, rsym.symT});
        }
    }
    const nameId = sym.key.absLocalSymKey.nameId;

    // Get resolved func sig id.
    var rFuncSigId: ResolvedFuncSigId = undefined;
    if (sym.key.absLocalSymKey.funcSigId == cy.NullId) {
        rFuncSigId = cy.NullId;
    } else {
        const funcSig = self.semaFuncSigs.items[sym.key.absLocalSymKey.funcSigId];
        if (funcSig.rFuncSigId == cy.NullId) {
            rFuncSigId = try resolveFuncSig(self, sym.key.absLocalSymKey.funcSigId);
        } else {
            rFuncSigId = funcSig.rFuncSigId;
        }
        // const str = try getResolvedFuncSigTempStr(self.compiler, rFuncSigId);
        // log.debug("rFuncSig {s}, {}", .{str, funcSig.sig.len});
    }

    const firstNodeId = self.semaSymFirstNodes.items[symId];
    self.curNodeId = firstNodeId;
    errdefer {
        if (builtin.mode == .Debug) {
            if (firstNodeId == cy.NullId) {
                // Builtin type syms don't have any attribution but they shouldn't get any errors either.
                stdx.panicFmt("No source attribution for local sym {s} {}.", .{getSymName(self.compiler, sym), rFuncSigId});
            }
        }
    }

    if (sym.key.absLocalSymKey.parentSymId == cy.NullId) {
        log.debug("no parent", .{});
        var key = AbsResolvedSymKey{
            .absResolvedSymKey = .{
                .rParentSymId = self.semaResolvedRootSymId,
                .nameId = nameId,
            },
        };
        // First check for a local declared symbol.
        if (try getAndCheckResolvedSymBySig(self, key, rFuncSigId, firstNodeId)) |rsymId| {
            sym.rSymId = rsymId;
            return;
        }

        // Check alias map. eg. Imported modules, module members.
        if (self.semaSymToRef.get(nameId)) |ref| {
            switch (ref.refT) {
                .moduleMember => {
                    const modId = ref.inner.moduleMember.modId;
                    if (try getVisibleResolvedSymFromModule(self, modId, nameId, rFuncSigId, firstNodeId)) |resolvedId| {
                        sym.rSymId = resolvedId;
                        return;
                    }
                    if (try resolveSymFromModule(self, modId, nameId, rFuncSigId, firstNodeId)) |resolvedId| {
                        sym.rSymId = resolvedId;
                        return;
                    }
                },
                .module => {
                    const modId = ref.inner.module;
                    sym.rSymId = self.compiler.modules.items[modId].resolvedRootSymId;
                    return;
                },
                .sym => {
                    if (self.semaSyms.items[ref.inner.sym.symId].rSymId != cy.NullId) {
                        sym.rSymId = self.semaSyms.items[ref.inner.sym.symId].rSymId;
                        return;
                    } else {
                        const name = getName(self.compiler, nameId);
                        return self.reportError("Type alias `{}` can not point to an unresolved symbol.", &.{v(name)});
                    }
                },
                // else => {
                //     return self.reportError("Unsupported {}", &.{fmt.v(ref.refT)});
                // }
            }
        }

        // Check builtin type.
        if (nameId < BuiltinTypes.len) {
            const typeT = BuiltinTypes[nameId];
            sym.rSymId = getResolvedBuiltinTypeSym(typeT);
            return;
        }
    } else {
        // Has parent symbol.
        
        const psym = self.semaSyms.items[sym.key.absLocalSymKey.parentSymId];
        if (psym.rSymId == cy.NullId) {
            // If the parent isn't resolved, this sym won't be resolved either.
            return;
        }

        var key = AbsResolvedSymKey{
            .absResolvedSymKey = .{
                .rParentSymId = psym.rSymId,
                .nameId = sym.key.absLocalSymKey.nameId,
            },
        };
        // First check for a local declared symbol.
        if (try getAndCheckResolvedSymBySig(self, key, rFuncSigId, firstNodeId)) |rsymId| {
            if (isResolvedSymVisibleFromMod(self.compiler, rsymId, self.modId)) {
                sym.rSymId = rsymId;
                return;
            } else {
                const name = getName(self.compiler, nameId);
                return self.reportErrorAt("Symbol is not exported: `{}`", &.{v(name)}, firstNodeId);
            }
        }

        const rpsym = self.compiler.semaResolvedSyms.items[psym.rSymId];
        if (rpsym.symT == .module) {
            const modId = rpsym.inner.module.id;
            if (try resolveSymFromModule(self, modId, nameId, rFuncSigId, firstNodeId)) |resolvedId| {
                sym.rSymId = resolvedId;
                return;
            } else {
                const name = getName(self.compiler, nameId);
                return self.reportErrorAt("Missing symbol: `{}`", &.{v(name)}, firstNodeId);
            }
        }
    }
}

fn isResolvedSymVisibleFromMod(c: *cy.VMcompiler, id: ResolvedSymId, modId: ModuleId) bool {
    const rsym = c.semaResolvedSyms.items[id];
    if (rsym.exported) {
        return true;
    }
    return modId == getResolvedSymRootMod(c, id);
}

fn getResolvedSymRootMod(c: *cy.VMcompiler, id: ResolvedSymId) ModuleId {
    const rsym = c.semaResolvedSyms.items[id];
    if (rsym.key.absResolvedSymKey.rParentSymId == cy.NullId) {
        return rsym.inner.module.id;
    } else {
        return getResolvedSymRootMod(c, rsym.key.absResolvedSymKey.rParentSymId);
    }
}

fn getVisibleResolvedSymFromModule(c: *cy.CompileChunk, modId: ModuleId, nameId: NameSymId, rFuncSigId: ResolvedFuncSigId, firstNodeId: cy.NodeId) !?ResolvedSymId {
    const mod = c.compiler.modules.items[modId];
    const key = AbsResolvedSymKey{
        .absResolvedSymKey = .{
            .nameId = nameId,
            .rParentSymId = mod.resolvedRootSymId,
        },
    };
    if (try getAndCheckResolvedSymBySig(c, key, rFuncSigId, firstNodeId)) |rsymId| {
        if (isResolvedSymVisibleFromMod(c.compiler, rsymId, c.modId)) {
            return rsymId;
        } else {
            const name = getName(c.compiler, nameId);
            return c.reportErrorAt("Symbol is not exported: `{}`", &.{v(name)}, firstNodeId);
        }
    }
    return null;
}

/// Get the resolved sym that matches a signature.
fn getAndCheckResolvedSymBySig(c: *cy.CompileChunk, key: AbsResolvedSymKey, rFuncSigId: ResolvedFuncSigId, nodeId: cy.NodeId) !?ResolvedSymId {
    if (c.compiler.semaResolvedSymMap.get(key)) |id| {
        const rsym = c.compiler.semaResolvedSyms.items[id];
        if (rFuncSigId == cy.NullId) {
            // Searching for a non-func reference.
            if (rsym.symT == .func) {
                if (rsym.inner.func.rFuncSymId != cy.NullId) {
                    // When the signature is for a non-func reference,
                    // a non overloaded function symbol can be used.
                    return id;
                } else {
                    return c.reportErrorAt("Can not disambiguate the symbol `{}`.", &.{v(getName(c.compiler, key.absResolvedSymKey.nameId))}, nodeId);
                }
            } else {
                return id;
            }
        } else {
            // Searching for function reference.
            if (rsym.symT == .variable) {
                // When the signature is for a func reference,
                // a variable symbol can be used.
                return id;
            } else if (rsym.symT == .func) {
                // Function signature must match exactly.
                const funcKey = AbsResolvedFuncSymKey{
                    .absResolvedFuncSymKey = .{
                        .rSymId = id,
                        .rFuncSigId = rFuncSigId,
                    },
                };
                if (c.compiler.semaResolvedFuncSymMap.contains(funcKey)) {
                    return id;
                } else {
                    return null;
                }
            } else {
                return c.reportErrorAt("Can not use `{}` as a function reference.", &.{v(getName(c.compiler, key.absResolvedSymKey.nameId))}, nodeId);
            }
        }
    } else return null;
}

fn resolveSymFromModule(chunk: *cy.CompileChunk, modId: ModuleId, nameId: NameSymId, rFuncSigId: ResolvedFuncSigId, nodeId: cy.NodeId) !?ResolvedSymId {
    const self = chunk.compiler;
    const relKey = RelModuleSymKey{
        .relModuleSymKey = .{
            .nameId = nameId,
            .rFuncSigId = rFuncSigId,
        },
    };

    const mod = self.modules.items[modId];
    if (mod.syms.get(relKey)) |modSym| {
        const key = AbsResolvedSymKey{
            .absResolvedSymKey = .{
                .rParentSymId = mod.resolvedRootSymId,
                .nameId = nameId,
            },
        };

        switch (modSym.symT) {
            .nativeFunc1 => {
                const rtSymId = try self.vm.ensureFuncSym(mod.resolvedRootSymId, nameId, rFuncSigId);

                const rFuncSig = chunk.compiler.semaResolvedFuncSigs.items[rFuncSigId];
                const rtSym = cy.FuncSymbolEntry.initNativeFunc1(modSym.inner.nativeFunc1.func, rFuncSig.isTyped, rFuncSig.numParams(), rFuncSigId);
                self.vm.setFuncSym(rtSymId, rtSym);

                const res = try setResolvedFunc(chunk, key, rFuncSigId, cy.NullId, AnyType, true);
                return res.rSymId;
            },
            .variable => {
                const id = @intCast(u32, self.semaResolvedSyms.items.len);
                const rtSymId = try self.vm.ensureVarSym(mod.resolvedRootSymId, nameId);
                const rtSym = cy.VarSym.init(modSym.inner.variable.val);
                cy.arc.retain(self.vm, rtSym.value);
                self.vm.setVarSym(rtSymId, rtSym);
                try self.semaResolvedSyms.append(self.alloc, .{
                    .symT = .variable,
                    .key = key,
                    .inner = .{
                        .variable = .{
                            .chunkId = cy.NullId,
                            .declId = cy.NullId,
                        },
                    },
                    .exported = true,
                });
                try self.semaResolvedSymMap.put(self.alloc, key, id);
                return id;
            },
            .userVar => {
                const id = @intCast(u32, self.semaResolvedSyms.items.len);
                _ = try self.vm.ensureVarSym(mod.resolvedRootSymId, nameId);
                try self.semaResolvedSyms.append(self.alloc, .{
                    .symT = .variable,
                    .key = key,
                    .inner = .{
                        .variable = .{
                            .chunkId = self.modules.items[modId].chunkId,
                            .declId = modSym.inner.userVar.declId,
                        },
                    },
                    .exported = true,
                });
                try self.semaResolvedSymMap.put(self.alloc, key, id);
                return id;
            },
            .userFunc => {
                _ = try self.vm.ensureFuncSym(mod.resolvedRootSymId, nameId, rFuncSigId);
                // Func sym entry will be updated when the func is generated later.

                const res = try setResolvedFunc(chunk, key, rFuncSigId, modSym.inner.userFunc.declId, AnyType, true);
                return res.rFuncSymId;
            },
            .object => {
                const id = @intCast(u32, self.semaResolvedSyms.items.len);
                try self.semaResolvedSyms.append(self.alloc, .{
                    .symT = .object,
                    .key = key,
                    .inner = .{
                        .object = .{
                            .chunkId = cy.NullId,
                            .declId = cy.NullId,
                        },
                    },
                    .exported = true,
                });
                try self.semaResolvedSymMap.put(self.alloc, key, id);

                return id;
            },
            .symToManyFuncs => {
                // More than one func for sym.
                const name = getName(chunk.compiler, nameId);
                return chunk.reportErrorAt("Symbol `{}` is ambiguous. There are multiple functions with the same name.", &.{v(name)}, nodeId);
            },
            .symToOneFunc => {
                const sigId = modSym.inner.symToOneFunc.rFuncSigId;
                return resolveSymFromModule(chunk, modId, nameId, sigId, nodeId);
            },
            .userObject => {
                return chunk.reportErrorAt("Unsupported module sym: userObject", &.{}, nodeId);
            },
        }
    }
    return null;
}

pub fn ensureNameSym(c: *cy.VMcompiler, name: []const u8) !NameSymId {
    return ensureNameSymExt(c, name, false);
}

pub fn ensureNameSymExt(c: *cy.VMcompiler, name: []const u8, dupe: bool) !NameSymId {
    const res = try @call(.never_inline, c.semaNameSymMap.getOrPut, .{c.alloc, name});
    if (res.found_existing) {
        return res.value_ptr.*;
    } else {
        const id = @intCast(u32, c.semaNameSyms.items.len);
        if (dupe) {
            const new = try c.alloc.dupe(u8, name);
            try c.semaNameSyms.append(c.alloc, .{
                .ptr = new.ptr,
                .len = @intCast(u32, new.len),
                .owned = true,
            });
        } else {
            try c.semaNameSyms.append(c.alloc, .{
                .ptr = name.ptr,
                .len = @intCast(u32, name.len),
                .owned = false,
            });
        }
        res.value_ptr.* = id;
        return id;
    }
}

pub fn linkNodeToSym(c: *cy.CompileChunk, nodeId: cy.NodeId, symId: SymId) void {
    if (c.semaSymFirstNodes.items[symId] == cy.NullId) {
        c.semaSymFirstNodes.items[symId] = nodeId;
    }
}

/// TODO: This should also return true for local function symbols.
fn hasLocalSym(self: *const cy.CompileChunk, parentId: ?u32, nameId: NameSymId) bool {
    const key = AbsLocalSymKey{
        .absLocalSymKey = .{
            .parentSymId = parentId orelse cy.NullId,
            .nameId = nameId,
            .funcSigId = cy.NullId,
        },
    };
    return self.semaSymMap.contains(key);
}

pub fn ensureSym(c: *cy.CompileChunk, parentId: ?SymId, nameId: NameSymId, optFuncSigId: ?FuncSigId) !SymId {
    var key = AbsLocalSymKey{
        .absLocalSymKey = .{
            .parentSymId = parentId orelse cy.NullId,
            .nameId = nameId,
            .funcSigId = optFuncSigId orelse cy.NullId,
        },
    };
    const res = try c.semaSymMap.getOrPut(c.alloc, key);
    if (res.found_existing) {
        return res.value_ptr.*;
    } else {
        const id = @intCast(u32, c.semaSyms.items.len);
        try c.semaSyms.append(c.alloc, .{
            .key = key,
            .used = false,
            .visited = false,
        });
        try c.semaSymFirstNodes.append(c.alloc, cy.NullId);
        res.value_ptr.* = id;
        return id;
    }
}

pub fn getVarName(self: *cy.VMcompiler, varId: LocalVarId) []const u8 {
    if (builtin.mode == .Debug) {
        return self.vars.items[varId].name;
    } else {
        return "";
    }
}

pub fn curSubBlock(self: *cy.CompileChunk) *SubBlock {
    return &self.semaSubBlocks.items[self.curSemaSubBlockId];
}

pub fn curBlock(self: *cy.CompileChunk) *Block {
    return &self.semaBlocks.items[self.curSemaBlockId];
}

pub fn endBlock(self: *cy.CompileChunk) !void {
    try endSubBlock(self);
    const sblock = curBlock(self);
    sblock.deinitTemps(self.alloc);
    self.semaBlockStack.items.len -= 1;
    self.curSemaBlockId = self.semaBlockStack.items[self.semaBlockStack.items.len-1];
}

fn semaAccessExpr(self: *cy.CompileChunk, nodeId: cy.NodeId, comptime discardTopExprReg: bool) !Type {
    const node = self.nodes[nodeId];
    const right = self.nodes[node.head.accessExpr.right];
    if (right.node_t == .ident) {
        var left = self.nodes[node.head.accessExpr.left];
        if (left.node_t == .ident) {
            const name = self.getNodeTokenString(left);
            const res = try getOrLookupVar(self, name, .read);
            if (!res.isLocal) {
                const symId = try referenceSym(self, null, name, null, node.head.accessExpr.left, true);
                self.nodes[node.head.accessExpr.left].head.ident.semaSymId = symId;

                const rightName = self.getNodeTokenString(right);
                const rightSymId = try referenceSym(self, symId, rightName, null, node.head.accessExpr.right, true);
                self.nodes[nodeId].head.accessExpr.semaSymId = rightSymId;
            } else {
                self.nodes[node.head.accessExpr.left].head.ident.semaVarId = res.varId;
            }
        } else if (left.node_t == .accessExpr) {
            _ = try semaAccessExpr(self, node.head.accessExpr.left, discardTopExprReg);

            left = self.nodes[node.head.accessExpr.left];
            if (left.head.accessExpr.semaSymId != cy.NullId) {
                const rightName = self.getNodeTokenString(right);
                const symId = try referenceSym(self, left.head.accessExpr.semaSymId, rightName, null, node.head.accessExpr.right, true);
                self.nodes[nodeId].head.accessExpr.semaSymId = symId;
            }
        } else {
            _ = try semaExpr(self, node.head.accessExpr.left, discardTopExprReg);
        }
    }
    return AnyType;
}

const VarResult = struct {
    id: LocalVarId,
    fromParentBlock: bool,
};

/// To a local type before assigning to a local variable.
fn toLocalType(vtype: Type) Type {
    if (vtype.typeT == .number and vtype.inner.number.canRequestInteger) {
        return NumberType;
    } else {
        return vtype;
    }
}

fn assignVar(self: *cy.CompileChunk, ident: cy.NodeId, vtype: Type, strat: VarLookupStrategy) !void {
    // log.debug("set var {s}", .{name});
    const node = self.nodes[ident];
    const name = self.getNodeTokenString(node);

    const res = try getOrLookupVar(self, name, strat);
    if (res.isLocal) {
        const svar = &self.vars.items[res.varId];
        if (svar.isCaptured) {
            if (!svar.isBoxed) {
                // Becomes boxed so codegen knows ahead of time.
                svar.isBoxed = true;
            }
        }

        if (!res.created) {
            const ssblock = curSubBlock(self);
            if (!ssblock.prevVarTypes.contains(res.varId)) {
                // Same variable but branched to sub block.
                try ssblock.prevVarTypes.put(self.alloc, res.varId, svar.vtype);
            }
        }

        // Update current type after checking for branched assignment.
        if (svar.vtype.typeT != vtype.typeT) {
            svar.vtype = toLocalType(vtype);
            if (!svar.lifetimeRcCandidate and vtype.rcCandidate) {
                svar.lifetimeRcCandidate = true;
            }
        }

        try self.assignedVarStack.append(self.alloc, res.varId);
        self.nodes[ident].head.ident.semaVarId = res.varId;
    } else {
        const symId = try referenceSym(self, null, name, null, ident, true);
        self.nodes[ident].head.ident.semaSymId = symId;
    }
}

fn endSubBlock(self: *cy.CompileChunk) !void {
    const sblock = curBlock(self);
    const ssblock = curSubBlock(self);

    const curAssignedVars = self.assignedVarStack.items[ssblock.assignedVarStart..];
    self.assignedVarStack.items.len = ssblock.assignedVarStart;

    if (sblock.subBlockDepth > 1) {
        const pssblock = self.semaSubBlocks.items[ssblock.prevSubBlockId];

        // Merge types to parent sub block.
        for (curAssignedVars) |varId| {
            const svar = &self.vars.items[varId];
            // log.debug("merging {s}", .{self.getVarName(varId)});
            if (ssblock.prevVarTypes.get(varId)) |prevt| {
                // Update current var type by merging.
                if (svar.vtype.typeT != prevt.typeT) {
                    svar.vtype = AnyType;

                    // Previous sub block hasn't recorded the var assignment.
                    if (!pssblock.prevVarTypes.contains(varId)) {
                        try self.assignedVarStack.append(self.alloc, varId);
                    }
                }
            } else {
                // New variable assignment, propagate to parent block.
                try self.assignedVarStack.append(self.alloc, varId);
            }
        }
    }
    ssblock.prevVarTypes.deinit(self.alloc);

    self.curSemaSubBlockId = ssblock.prevSubBlockId;
    sblock.subBlockDepth -= 1;
}

fn pushIterSubBlock(self: *cy.CompileChunk) !void {
    try pushSubBlock(self);
}

fn endIterSubBlock(self: *cy.CompileChunk) !void {
    const ssblock = curSubBlock(self);
    for (self.assignedVarStack.items[ssblock.assignedVarStart..]) |varId| {
        const svar = self.vars.items[varId];
        if (ssblock.prevVarTypes.get(varId)) |prevt| {
            if (svar.vtype.typeT != prevt.typeT) {
                // Type differs from prev scope type. Record change for iter block codegen.
                try ssblock.iterVarBeginTypes.append(self.alloc, .{
                    .id = varId,
                    .vtype = AnyType,
                });
            }
        } else {
            // First assigned in iter block. Record change for iter block codegen.
            try ssblock.iterVarBeginTypes.append(self.alloc, .{
                .id = varId,
                .vtype = svar.vtype,
            });
        }
    }
    try endSubBlock(self);
}

pub fn importAllFromModule(self: *cy.CompileChunk, modId: ModuleId) !void {
    const mod = self.compiler.modules.items[modId];
    var iter = mod.syms.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*.relModuleSymKey;

        try self.semaSymToRef.put(self.alloc, key.nameId, .{
            .refT = .moduleMember,
            .inner = .{
                .moduleMember = .{
                    .modId = modId,
                }
            }
        });
    }
}

/// Writes resolved spec to temp buf.
fn resolveSpecTemp(self: *cy.CompileChunk, spec: []const u8, outBuiltin: *bool) ![]const u8 {
    if (self.compiler.moduleLoaders.contains(spec)) {
        outBuiltin.* = true;
        return spec;
    }

    if (cy.isWasm) {
        return error.NotSupported;
    }

    if (std.mem.startsWith(u8, spec, "http://") or std.mem.startsWith(u8, spec, "https://")) {
        outBuiltin.* = false;
        const uri = try std.Uri.parse(spec);
        if (std.mem.endsWith(u8, uri.host.?, "github.com")) {
            if (std.mem.count(u8, uri.path, "/") == 2 and uri.path[uri.path.len-1] != '/') {
                self.tempBufU8.clearRetainingCapacity();
                try self.tempBufU8.appendSlice(self.alloc, uri.scheme);
                try self.tempBufU8.appendSlice(self.alloc, "://raw.githubusercontent.com");
                try self.tempBufU8.appendSlice(self.alloc, uri.path);
                try self.tempBufU8.appendSlice(self.alloc, "/master/mod.cys");
                std.debug.print("{s}\n", .{self.tempBufU8.items});
                return self.tempBufU8.items;
            }
        }
        return spec;
    }

    self.tempBufU8.clearRetainingCapacity();

    // Create path from the current script.
    // There should always be a parent directory since `srcUri` should be absolute when dealing with file modules.
    const dir = std.fs.path.dirname(self.srcUri) orelse return error.NoParentDir;
    try self.tempBufU8.ensureTotalCapacity(self.alloc, dir.len + 1 + spec.len + std.fs.MAX_PATH_BYTES);
    try self.tempBufU8.appendSlice(self.alloc, dir);
    try self.tempBufU8.append(self.alloc, '/');
    try self.tempBufU8.appendSlice(self.alloc, spec);
    const path = self.tempBufU8.items;

    // Get canonical path.
    self.tempBufU8.items.len += std.fs.MAX_PATH_BYTES;
    outBuiltin.* = false;
    return std.fs.cwd().realpath(path, self.tempBufU8.items[path.len..]) catch |err| {
        if (err == error.FileNotFound) {
            return self.reportError("Import path does not exist: `{}`", &.{v(path)});
        } else {
            return err;
        }
    };
}

pub fn getOrLoadModule(self: *cy.CompileChunk, spec: []const u8, nodeId: cy.NodeId) !ModuleId {
    var isBuiltin: bool = undefined;
    const absSpec = try resolveSpecTemp(self, spec, &isBuiltin);

    const res = try self.compiler.moduleMap.getOrPut(self.alloc, absSpec);
    if (res.found_existing) {
        return res.value_ptr.*;
    } else {
        const absSpecDupe = try self.alloc.dupe(u8, absSpec);

        // Add empty module placeholder.
        const id = @intCast(u32, self.compiler.modules.items.len);
        try self.compiler.modules.append(self.alloc, .{
            .syms = .{},
            .chunkId = cy.NullId,
            .resolvedRootSymId = cy.NullId,
        });

        // Queue import task.
        try self.compiler.importTasks.append(self.alloc, .{
            .chunkId = self.id,
            .nodeId = nodeId,
            .absSpec = absSpecDupe,
            .modId = id,
            .builtin = isBuiltin,
        });

        res.key_ptr.* = absSpecDupe;
        res.value_ptr.* = id;
        return id;
    }
}

/// Given the local sym path, add a resolved object sym entry.
/// Assumes parent is resolved.
fn resolveLocalObjectSym(chunk: *cy.CompileChunk, symId: SymId, rParentSymId: ResolvedSymId, name: []const u8, declId: cy.NodeId, exported: bool) !u32 {
    const c = chunk.compiler;
    const nameId = try ensureNameSym(c, name);
    const key = AbsResolvedSymKey{
        .absResolvedSymKey = .{
            .rParentSymId = rParentSymId,
            .nameId = nameId,
        },
    };
    if (c.semaResolvedSymMap.contains(key)) {
        return chunk.reportErrorAt("The symbol `{}` was already declared.", &.{v(name)}, declId);
    }

    // Resolve the symbol.
    const resolvedId = @intCast(u32, c.semaResolvedSyms.items.len);
    try c.semaResolvedSyms.append(chunk.alloc, .{
        .symT = .object,
        .key = key,
        .inner = .{
            .object = .{
                .chunkId = chunk.id,
                .declId = declId,
            },
        },
        .exported = exported,
    });
    try @call(.never_inline, c.semaResolvedSymMap.put, .{chunk.alloc, key, resolvedId});

    chunk.semaSyms.items[symId].rSymId = resolvedId;
    return resolvedId;
}

/// A root module symbol is used as the parent for it's members.
pub fn resolveRootModuleSym(self: *cy.VMcompiler, name: []const u8, modId: ModuleId) !ResolvedSymId {
    const nameId = try ensureNameSym(self, name);
    const key = vm_.KeyU64{
        .absResolvedSymKey = .{
            .rParentSymId = cy.NullId,
            .nameId = nameId,
        },
    };
    if (self.semaResolvedSymMap.contains(key)) {
        // Assume no existing symbol, since each module has a unique srcUri.
        log.debug("Root symbol {s} already exists.", .{name});
        stdx.fatal();
    }

    // Resolve the symbol.
    const resolvedId = @intCast(u32, self.semaResolvedSyms.items.len);
    try self.semaResolvedSyms.append(self.alloc, .{
        .symT = .module,
        .key = key,
        .inner = .{
            .module = .{
                .id = modId,
            },
        },
        .exported = true,
    });
    try @call(.never_inline, self.semaResolvedSymMap.put, .{self.alloc, key, resolvedId});

    return resolvedId;
}

/// Given the local sym path, add a resolved var sym entry.
/// Fail if there is already a symbol in this path with the same name.
fn resolveLocalVarSym(self: *cy.CompileChunk, symId: SymId, rParentSymId: ResolvedSymId, nameId: NameSymId, declId: cy.NodeId, exported: bool) !ResolvedSymId {
    const key = AbsResolvedSymKey{
        .absResolvedSymKey = .{
            .rParentSymId = rParentSymId,
            .nameId = nameId,
        },
    };
    if (self.compiler.semaResolvedSymMap.contains(key)) {
        return self.reportErrorAt("The symbol `{}` was already declared.", &.{v(getName(self.compiler, nameId))}, declId);
    }

    if (rParentSymId == self.semaResolvedRootSymId) {
        // Root symbol, check that it's not a local alias.
        if (self.semaSymToRef.contains(nameId)) {
            const node = self.nodes[declId];
            return self.reportErrorAt("The symbol `{}` was already declared.", &.{v(getName(self.compiler, nameId))}, node.head.varDecl.left);
        }
    }

    // Resolve the symbol.
    const resolvedId = @intCast(u32, self.compiler.semaResolvedSyms.items.len);
    try self.compiler.semaResolvedSyms.append(self.alloc, .{
        .symT = .variable,
        .key = key,
        .inner = .{
            .variable = .{
                .chunkId = self.id,
                .declId = declId,
            },
        },
        .exported = exported,
    });

    try @call(.never_inline, self.compiler.semaResolvedSymMap.put, .{self.alloc, key, resolvedId});

    // Link to local symbol.
    self.semaSyms.items[symId].rSymId = resolvedId;

    return resolvedId;
}

/// Dump the full path of a resolved sym.
fn dumpAbsResolvedSymName(self: *cy.VMcompiler, id: ResolvedSymId) !void {
    const sym = self.semaResolvedSyms.items[id];
    if (sym.key.absResolvedSymKey.rParentSymId != cy.NullId) {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        defer buf.deinit(self.alloc);
        try dumpAbsResolvedSymNameR(self, &buf, sym.key.absResolvedSymKey.rParentSymId);
        try buf.append(self.alloc, '.');
        try buf.appendSlice(self.alloc, getName(self, sym.key.absResolvedSymKey.nameId));
        log.debug("{s}", .{buf.items});
    } else {
        log.debug("{s}", .{getName(self, sym.key.absResolvedSymKey.nameId)});
    }
}

fn dumpAbsResolvedSymNameR(self: *cy.VMcompiler, buf: *std.ArrayListUnmanaged(u8), id: ResolvedSymId) !void {
    const sym = self.semaResolvedSyms.items[id];
    if (sym.key.absResolvedSymKey.rParentSymId == cy.NullId) {
        try buf.appendSlice(self.alloc, getName(self, sym.key.absResolvedSymKey.nameId));
    } else {
        try dumpAbsResolvedSymNameR(self, buf, sym.key.absResolvedSymKey.rParentSymId);
        try buf.append(self.alloc, '.');
        try buf.appendSlice(self.alloc, getName(self, sym.key.absResolvedSymKey.nameId));
    }
}

const ResolveFuncSymResult = struct {
    rSymId: ResolvedSymId,
    rFuncSymId: ResolvedFuncSymId,
};

fn setResolvedFunc(self: *cy.CompileChunk, key: AbsResolvedSymKey, rFuncSigId: ResolvedFuncSigId, declId: u32, retType: Type, exported: bool) !ResolveFuncSymResult {
    const c = self.compiler;
    var rsymId: ResolvedSymId = undefined;
    var createdSym = false;
    if (c.semaResolvedSymMap.get(key)) |id| {
        const rsym = c.semaResolvedSyms.items[id];
        if (rsym.symT != .func) {
            // Only fail if the symbol already exists and isn't a function.
            const name = getName(c, key.absResolvedSymKey.nameId);
            return self.reportError("The symbol `{}` was already declared.", &.{v(name)});
        }
        rsymId = id;
    } else {
        rsymId = @intCast(u32, c.semaResolvedSyms.items.len);
        try c.semaResolvedSyms.append(c.alloc, .{
            .symT = .func,
            .key = key,
            .inner = .{
                .func = .{
                    .rFuncSymId = undefined,
                },
            },
            .exported = exported,
        });
        try @call(.never_inline, c.semaResolvedSymMap.put, .{c.alloc, key, rsymId});
        createdSym = true;
    }

    // Now check resolved function syms.
    const funcKey = AbsResolvedFuncSymKey{
        .absResolvedFuncSymKey = .{
            .rSymId = rsymId,
            .rFuncSigId = rFuncSigId,
        },
    };
    if (c.semaResolvedFuncSymMap.contains(funcKey)) {
        const name = getName(c, key.absResolvedSymKey.nameId);
        return self.reportError("The function symbol `{}` with the same signature was already declared.", &.{v(name)});
    }

    const rfsymId = @intCast(u32, c.semaResolvedFuncSyms.items.len);
    try c.semaResolvedFuncSyms.append(c.alloc, .{
        .chunkId = self.id,
        .declId = declId,
        .rFuncSigId = rFuncSigId,
        .retType = retType,
        .hasStaticInitializer = false,
    });
    try @call(.never_inline, c.semaResolvedFuncSymMap.put, .{c.alloc, funcKey, rfsymId});

    if (createdSym) {
        c.semaResolvedSyms.items[rsymId].inner.func.rFuncSymId = rfsymId;
    } else {
        // Mark sym as overloaded.
        c.semaResolvedSyms.items[rsymId].inner.func.rFuncSymId = cy.NullId;
    }

    return ResolveFuncSymResult{
        .rSymId = rsymId,
        .rFuncSymId = rfsymId,
    };
}

/// Given the local sym path, add a resolved func sym entry.
/// Assumes parent local sym is resolved.
fn resolveLocalFuncSym(self: *cy.CompileChunk, symId: SymId, rParentSymId: ?ResolvedSymId, nameId: NameSymId, declId: u32, retType: Type, exported: bool) !ResolveFuncSymResult {
    const func = self.funcDecls[declId];
    const numParams = func.params.len();

    const key = AbsResolvedSymKey{
        .absResolvedSymKey = .{
            .rParentSymId = rParentSymId orelse cy.NullId,
            .nameId = nameId,
        },
    };

    if (key.absResolvedSymKey.rParentSymId == self.semaResolvedRootSymId) {
        // Root symbol, check that it's not a local alias.
        if (self.semaSymToRef.contains(nameId)) {
            return self.reportErrorAt("The symbol `{}` was already declared.", &.{v(getName(self.compiler, key.absResolvedSymKey.nameId))}, func.name);
        }
    }

    const rFuncSigId = try ensureResolvedUntypedFuncSig(self.compiler, numParams);

    const res = try setResolvedFunc(self, key, rFuncSigId, declId, retType, exported);
    dumpAbsResolvedSymName(self.compiler, res.rSymId) catch stdx.fatal();

    self.funcDecls[declId].inner.staticFunc = .{
        .semaResolvedSymId = res.rSymId,
        .semaResolvedFuncSymId = res.rFuncSymId,
    };
    self.semaSyms.items[symId].rSymId = res.rSymId;

    // FuncSig can be resolved.
    const funcSigId = self.semaSyms.items[symId].key.absLocalSymKey.funcSigId;
    self.semaFuncSigs.items[funcSigId].rFuncSigId = rFuncSigId;

    return res;
}

fn endFuncBlock(self: *cy.CompileChunk, numParams: u32) !void {
    const sblock = curBlock(self);
    const numCaptured = @intCast(u8, sblock.params.items.len - numParams);
    if (numCaptured > 0) {
        for (sblock.params.items) |varId| {
            const svar = self.vars.items[varId];
            if (svar.isCaptured) {
                const pId = self.capVarDescs.get(varId).?.user;
                const pvar = &self.vars.items[pId];

                if (!pvar.isBoxed) {
                    pvar.isBoxed = true;
                    pvar.lifetimeRcCandidate = true;
                }
            }
        }
    }
    try endBlock(self);
}

fn endFuncSymBlock(self: *cy.CompileChunk, numParams: u32) !void {
    const sblock = curBlock(self);
    const numCaptured = @intCast(u8, sblock.params.items.len - numParams);
    if (builtin.mode == .Debug and numCaptured > 0) {
        stdx.panicFmt("Captured var in static func.", .{});
    }
    try endBlock(self);
}

pub const ResolvedFuncSigId = u32;
pub const ResolvedFuncSig = struct {
    /// Last elem is the return type sym.
    sigPtr: [*]const ResolvedSymId,
    sigLen: u32,

    isTyped: bool,

    pub fn slice(self: ResolvedFuncSig) []const ResolvedSymId {
        return self.sigPtr[0..self.sigLen];
    }

    pub fn numParams(self: ResolvedFuncSig) u8 {
        return @intCast(u8, self.sigLen - 1);
    }
};

pub const FuncSigId = u32;
pub const FuncSig = struct {
    sig: []const SymId,
    rFuncSigId: ResolvedFuncSigId,
};

pub const NameAny = 0;
const BuiltinTypes = [_]TypeTag{
    .any,
};

test "Internals." {
    try t.eq(@sizeOf(LocalVar), 32);
    try t.eq(@sizeOf(Sym), 24);
    try t.eq(@sizeOf(ResolvedFuncSym), 16);
    try t.eq(@sizeOf(ResolvedSym), 24);
    try t.eq(@sizeOf(Type), 3);
    try t.eq(@sizeOf(Name), 16);
    try t.eq(@sizeOf(ModuleFuncNode), 16);
}
