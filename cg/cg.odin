package hephaistos_cg

import "base:runtime"

import "core:fmt"
import "core:reflect"
import "core:slice"

import "../ast"
import "../types"
import "../tokenizer"
import "../checker"
import "../hashmap"

import spv      "../spirv-odin"
import spv_glsl "../spirv-odin/spirv_glsl"

Storage_Class :: enum {
	By_Value = 0,
	Global,
	Function,
	Uniform,
	Input,
	Output,
	Push_Constant,
	Uniform_Constant,
	Storage_Buffer,
	Physical_Storage_Buffer,
	Image,
}

Type_Info :: struct {
	type:       spv.Id,
	nil_value:  spv.Id,
	image_type: spv.Id, // for sampler types: the type of the sampled image
	array_type: spv.Id,
	array_ptr:  spv.Id,
	ptr_types:  [Storage_Class]spv.Id,
}

Type_Key :: struct {
	type:  ^types.Type,
	flags: Type_Flags,
}

Type_Registry :: hashmap.Hash_Map(Type_Key, ^Type_Info)

Image_Type :: struct {
	dimensions:   int,
	texel_type: struct {
		size: int,
		kind: types.Kind,
	},
	sampled: bool,
}

Proc_Lit_Info :: struct {
	expr:      ^ast.Expr_Proc_Lit,
	id:        spv.Id,
	link_name: string,
}

Constant_Key :: struct {
	value: types.Const_Value,
	type: ^types.Type,
}

Constant_Cache :: hashmap.Hash_Map(Constant_Key, spv.Id)

Runtime_Proc :: enum {
	Complex64_Mul = 1,
	Complex64_Div,
	Complex128_Mul,
	Complex128_Div,

	Quaternion128_Mul,
	Quaternion256_Mul,
	Quaternion128_Div,
	Quaternion256_Div,
}

Context :: struct {
	constant_cache:     Constant_Cache,
	string_cache:       map[string]spv.Id,
	type_registry:      Type_Registry,
	image_types:        map[Image_Type]struct {
		image:   spv.Id,
		sampler: spv.Id,
	},
	type_void:          spv.Id,
	type_void_proc:     spv.Id,

	runtime_procs:      [Runtime_Proc]spv.Id,

	meta:               spv.Builder,
	ext_inst:           spv.Builder,
	memory_model:       spv.Builder,
	entry_points:       spv.Builder,
	execution_modes:    spv.Builder,
	debug_a:            spv.Builder,
	debug_b:            spv.Builder,
	annotations:        spv.Builder,
	types:              spv.Builder,
	globals:            spv.Builder,
	functions:          spv.Builder,

	current_id:         spv.Id,
	checker:            ^checker.Checker,
	scopes:             [dynamic]Scope,

	extensions:         map[string]struct{},
	capabilities:       map[spv.Capability]struct{},
	referenced_globals: map[spv.Id]struct{},

	procs:              [dynamic]Proc_Lit_Info,

	link_name:          string,
	shader_stage:       ast.Shader_Stage,
	debug_file:         spv.Id,

	local_size:         [3]i32,

	spirv_version:      u32,
}

Value :: struct {
	id:              spv.Id,
	storage_class:   Storage_Class,
	type:            ^types.Type,
	real_type:       ^types.Type, // non swizzled type
	swizzle:         []u32,
	explicit_layout: bool,
	discard:         bool,
	coord:           spv.Id, // texel reference for ImageStore
}

Scope_Kind :: enum {
	Block,
	Loop,
	Switch,
}

Scope :: struct {
	entities:     map[string]Value,
	label:        string,
	label_id:     spv.Id,
	end_id:       spv.Id,
	continue_id:  spv.Id,
	return_value: spv.Id, // 0 when the return values are shader stage outputs
	return_type:  ^types.Type,
	outputs:      []spv.Id,
	kind:         Scope_Kind,
}

cg_lookup_entity :: proc(ctx: ^Context, name: string) -> ^Value {
	#reverse for scope in ctx.scopes {
		e := &scope.entities[name]
		if e != nil {
			return e
		}
	}
	panic("cg_lookup_entity failed")
}

cg_insert_entity :: proc(ctx: ^Context, name: string, storage_class: Storage_Class, type: ^types.Type, id: spv.Id) {
	spv.OpName(&ctx.debug_b, id, name)
	ctx.scopes[len(ctx.scopes) - 1].entities[name] = {
		type          = type,
		id            = id,
		storage_class = storage_class,
	}
}

scope_push :: proc(ctx: ^Context, label: string = "", kind: Scope_Kind = .Block) -> ^Scope {
	append(&ctx.scopes, Scope {
		label = label,
		kind  = kind,
	})
	return &ctx.scopes[len(ctx.scopes) - 1]
}

scope_pop :: proc(ctx: ^Context) -> Scope {
	return pop(&ctx.scopes)
}

cg_scope :: proc(
	ctx:     ^Context,
	builder: ^spv.Builder,
	stmts:   []^ast.Stmt,
	end:     spv.Id     = 0,
	label:   string     = "",
	kind:    Scope_Kind = .Block,
) -> (start_label: spv.Id, diverged: bool) {
	scope := scope_push(ctx, label, kind)
	defer scope_pop(ctx)

	start_label    = spv.OpLabel(builder)
	scope.label_id = start_label
	scope.end_id   = end
	diverged       = cg_stmt_list(ctx, builder, stmts)
	if !diverged && end != 0 {
		spv.OpBranch(builder, end)
	}

	return
}

find_scope_by_label :: proc(
	ctx:   ^Context,
	label: string,
) -> ^Scope {
	assert(label != {})
	#reverse for &scope in ctx.scopes {
		if scope.label == label {
			return &scope
		}
	}
	return nil
}

find_scope_by_kind :: proc(
	ctx:   ^Context,
	kinds: bit_set[Scope_Kind],
) -> ^Scope {
	#reverse for &scope in ctx.scopes {
		if scope.kind in kinds {
			return &scope
		}
	}
	return nil
}

register_type :: proc(registry: ^Type_Registry, key: Type_Key) -> (type_info: ^Type_Info, ok: bool) {
	ti := hashmap.get(registry^, key)
	if ti != nil {
		return ti^, true
	} else {
		type_info = new(Type_Info)
		hashmap.insert(registry, key, type_info)
		return
	}
}

cg_string :: proc(ctx: ^Context, str: string) -> spv.Id {
	if id, ok := ctx.string_cache[str]; ok {
		return id
	}
	id := spv.OpString(&ctx.debug_a, str)
	ctx.string_cache[str] = id
	return id
}

cg_decl :: proc(ctx: ^Context, builder: ^spv.Builder, decl: ^ast.Decl, global: bool) {
	value_builder     := builder
	decl_builder      := &ctx.functions
	storage_class     := Storage_Class.Function
	spv_storage_class := spv.StorageClass.Function
	has_nil_value     := true
	annotate          := false
	flags: Type_Flags

	if global {
		value_builder     = nil
		decl_builder      = &ctx.globals
		storage_class     = .Global
		spv_storage_class = .Private
	}

	switch v in decl.derived_decl {
	case ^ast.Decl_Value:
		if v.interface == .Uniform || v.interface == .Uniform_Buffer {
			value_builder     = nil
			decl_builder      = &ctx.globals
			storage_class     = .Uniform
			spv_storage_class = .Uniform
			flags             = { .Block, .Explicit_Layout, }
			has_nil_value     = false
			annotate          = true
		}

		if v.interface == .Push_Constant {
			value_builder     = nil
			decl_builder      = &ctx.globals
			storage_class     = .Push_Constant
			spv_storage_class = .PushConstant
			flags             = { .Block, .Explicit_Layout, }
			has_nil_value     = false
		}

		if v.interface == .Storage_Buffer {
			ctx.extensions["SPV_KHR_storage_buffer_storage_class"] = {}

			value_builder     = nil
			decl_builder      = &ctx.globals
			storage_class     = .Storage_Buffer
			spv_storage_class = .StorageBuffer
			flags             = { .Block, .Explicit_Layout, }
			has_nil_value     = false
			annotate          = true
		}

		prev_link_name := ctx.link_name
		if v.link_name != "" {
			ctx.link_name = v.link_name
		}
		defer if v.link_name != "" {
			ctx.link_name = prev_link_name
		}

		if v.local_size != 0 {
			ctx.local_size = v.local_size
		}

		if v.mutable {
			if len(v.values) == 0 {
				for type, i in v.types {
					if types.is_sampler(type) || types.is_image(type) && v.interface == .Uniform {
						assert(len(v.types) == 1)
						storage_class     = .Uniform_Constant
						spv_storage_class = .UniformConstant
						has_nil_value     = false
						annotate          = true
					}

					type_info := cg_type(ctx, type, flags)
					init: Maybe(spv.Id)
					if has_nil_value {
						init = cg_nil_value(ctx, type_info)
					}
					id   := spv.OpVariable(decl_builder, cg_type_ptr(ctx, type_info, storage_class), spv_storage_class, init)
					name := v.lhs[i].derived_expr.(^ast.Expr_Ident).ident.text
					cg_insert_entity(ctx, name, storage_class, type, id)

					if annotate {
						if v.binding != -1 {
							spv.OpDecorate(&ctx.annotations, id, .Binding, u32(v.binding))
						}
						if v.descriptor_set != -1 {
							spv.OpDecorate(&ctx.annotations, id, .DescriptorSet, u32(v.descriptor_set))
						}
						if v.location != -1 {
							spv.OpDecorate(&ctx.annotations, id, .Location, u32(v.location))
						}
					}
				}
			} else {
				for value, i in v.values {
					type      := v.types[i]
					type_info := cg_type(ctx, type, flags)
					init: spv.Id
					if global {
						init = cg_expr(ctx, nil, value).id
					} else {
						init = cg_nil_value(ctx, type_info)
					}
					id := spv.OpVariable(decl_builder, cg_type_ptr(ctx, type_info, storage_class), spv_storage_class, init)
					if !global {
						assert(value_builder != nil)
						init := cg_expr(ctx, value_builder, value)
						// if v.type_expr != nil {
						// 	init.id = cg_cast(ctx, builder, init, v.type_expr.type)
						// } else if value.type.size != 0 {
						// 	init.id = cg_cast(ctx, builder, init, value.type)
						// }
						spv.OpStore(value_builder, id, init.id)
					}
					name := v.lhs[i].derived_expr.(^ast.Expr_Ident).ident.text
					cg_insert_entity(ctx, name, storage_class, type, id)
				}
			}
		} else {
			for value, i in v.values {
				if value.type.kind != .Proc {
					continue
				}

				name := v.lhs[i].derived_expr.(^ast.Expr_Ident).ident.text

				prev_link_name := ctx.link_name
				if v.link_name == "" {
					ctx.link_name = name
				}
				defer if v.link_name == "" {
					ctx.link_name = prev_link_name
				}

				id := cg_expr(ctx, nil, value)
				cg_insert_entity(ctx, name, nil, value.type, id.id)
			}
		}
	}
}

@(require_results)
generate :: proc(
	checker:     ^checker.Checker,
	stmts:       []^ast.Stmt,
	file_name:   Maybe(string) = nil,
	file_source: Maybe(string) = nil,
	spirv_version := u32(spv.VERSION),
	allocator     := context.allocator,
) -> []u32 {
	context.allocator = context.temp_allocator

	ctx: Context = {
		checker       = checker,
		spirv_version = spirv_version,
	}
	hashmap.init(
		&ctx.type_registry,
		proc(key: Type_Key, seed: uintptr) -> uintptr {
			h := seed
			if key.type.kind == .Struct {
				flags := key.flags
				h      = runtime.default_hasher(&flags, seed, size_of(flags))
			}
			return uintptr(types.type_hash(key.type, u64(h)))
		},
		proc(a, b: Type_Key) -> bool {
			if a.type.kind == .Struct && b.type.kind == .Struct {
				if a.flags != b.flags {
					return false
				}
			}
			return types.equal(a.type, b.type)
		},
	)
	hashmap.init(
		&ctx.constant_cache,
		proc(key: Constant_Key, seed: uintptr) -> uintptr {
			h     := seed
			value := key.value
			h      = runtime.default_hasher(&value, seed, size_of(value))
			return uintptr(types.type_hash(key.type, u64(h)))
		},
		proc(a, b: Constant_Key) -> bool {
			return a.value == b.value && types.equal(a.type, b.type)
		},
	)

	for b := cast([^]spv.Builder)&ctx.meta; b != cast([^]spv.Builder)&ctx.current_id; b = b[1:] {
		b[0].current_id = &ctx.current_id
	}

	append(&ctx.meta.data, spv.MAGIC_NUMBER)
	append(&ctx.meta.data, spirv_version)
	append(&ctx.meta.data, 'H' << 0 | 'E' << 8 | 'P' << 16 | 'H' << 24)
	append(&ctx.meta.data, 4194303)
	append(&ctx.meta.data, 0)
	scope_push(&ctx)

	ctx.type_void              = spv.OpTypeVoid(&ctx.types)
	void_proc_type            := types.new(.Proc, types.Proc, context.temp_allocator)
	void_proc_type.return_type = types.new(.Tuple, types.Struct, context.temp_allocator)
	ctx.type_void_proc         = cg_type(&ctx, void_proc_type).type
	spv.OpName(&ctx.debug_b, ctx.type_void,      "$VOID")
	spv.OpName(&ctx.debug_b, ctx.type_void_proc, "$VOID_PROC")

	if file_name, ok := file_name.?; ok {
		ctx.debug_file = cg_string(&ctx, file_name)
		spv.OpSource(&ctx.debug_a, .Unknown, 0, ctx.debug_file, file_source)
	}

	ctx.capabilities[.Shader] = {}

	spv_glsl.extension_id = spv.OpExtInstImport(&ctx.ext_inst, "GLSL.std.450")
	if ctx.spirv_version < spv_version(1, 6) {
		ctx.extensions["SPV_KHR_non_semantic_info"] = {}
	}

	spv.OpMemoryModel(&ctx.memory_model, .Logical, .Simple)

	b: spv.Builder = { current_id = &ctx.current_id }
	cg_stmt_list(&ctx, &b, stmts, true)

	for id, runtime_proc in ctx.runtime_procs {
		if id == 0 {
			continue
		}

		spv.OpName(&ctx.debug_b, id, fmt.tprintf("$BUILTIN_%v", runtime_proc))

		return_type: ^types.Type
		arg_types:   []types.Field
		switch runtime_proc {
		case .Complex64_Mul, .Complex64_Div:
			return_type = types.t_complex64
			arg_types   = {
				{ type = types.t_complex64, },
				{ type = types.t_complex64, },
			}
		case .Complex128_Mul, .Complex128_Div:
			return_type = types.t_complex128
			arg_types   = {
				{ type = types.t_complex128, },
				{ type = types.t_complex128, },
			}

		case .Quaternion128_Mul, .Quaternion128_Div:
			return_type = types.t_quaternion128
			arg_types   = {
				{ type = types.t_quaternion128, },
				{ type = types.t_quaternion128, },
			}
		case .Quaternion256_Mul, .Quaternion256_Div:
			return_type = types.t_quaternion256
			arg_types   = {
				{ type = types.t_quaternion256, },
				{ type = types.t_quaternion256, },
			}
		}

		proc_type            := types.new(.Proc, types.Proc, checker.allocator)
		proc_type.args        = arg_types
		proc_type.return_type = return_type

		return_type_id := cg_type(&ctx, return_type).type

		id := id - 1
		ctx.functions.current_id = &id
		_ = spv.OpFunction(&ctx.functions, return_type_id, {}, cg_type(&ctx, proc_type).type)
		ctx.functions.current_id = &ctx.current_id

		_args: [10]spv.Id
		args := _args[:len(arg_types)]
		for &arg, i in args {
			arg = spv.OpFunctionParameter(&ctx.functions, cg_type(&ctx, arg_types[i].type).type)
		}

		spv.OpLabel(&ctx.functions)

		switch runtime_proc {
		case .Complex64_Mul, .Complex128_Mul:
			elem_type: spv.Id
			if runtime_proc == .Complex64_Mul {
				elem_type = cg_type(&ctx, types.t_f32).type
			} else {
				elem_type = cg_type(&ctx, types.t_f64).type
			}

			a0    := spv.OpCompositeExtract(&ctx.functions, elem_type, args[0], 0)
			b0    := spv.OpCompositeExtract(&ctx.functions, elem_type, args[0], 1)
			a1    := spv.OpCompositeExtract(&ctx.functions, elem_type, args[1], 0)
			b1    := spv.OpCompositeExtract(&ctx.functions, elem_type, args[1], 1)

			a0_a1 := spv.OpFMul(&ctx.functions, elem_type, a0, a1)
			b0_b1 := spv.OpFMul(&ctx.functions, elem_type, b0, b1)

			a0_b1 := spv.OpFMul(&ctx.functions, elem_type, a0, b1)
			a1_b0 := spv.OpFMul(&ctx.functions, elem_type, a1, b0)

			real  := spv.OpFSub(&ctx.functions, elem_type, a0_a1, b0_b1)
			imag  := spv.OpFAdd(&ctx.functions, elem_type, a0_b1, a1_b0)

			ret   := spv.OpCompositeConstruct(&ctx.functions, return_type_id, real, imag)
			spv.OpReturnValue(&ctx.functions, ret)

		case .Complex64_Div, .Complex128_Div:
			elem_type: spv.Id
			if runtime_proc == .Complex64_Div {
				elem_type = cg_type(&ctx, types.t_f32).type
			} else {
				elem_type = cg_type(&ctx, types.t_f64).type
			}

			a0       := spv.OpCompositeExtract(&ctx.functions, elem_type, args[0], 0)
			b0       := spv.OpCompositeExtract(&ctx.functions, elem_type, args[0], 1)
			a1       := spv.OpCompositeExtract(&ctx.functions, elem_type, args[1], 0)
			b1       := spv.OpCompositeExtract(&ctx.functions, elem_type, args[1], 1)

			a0_a1    := spv.OpFMul(&ctx.functions, elem_type, a0, a1)
			b0_b1    := spv.OpFMul(&ctx.functions, elem_type, b0, b1)
			b0_a1    := spv.OpFMul(&ctx.functions, elem_type, b0, a1)
			a0_b1    := spv.OpFMul(&ctx.functions, elem_type, a0, b1)
			a1_a1    := spv.OpFMul(&ctx.functions, elem_type, a1, a1)
			b1_b1    := spv.OpFMul(&ctx.functions, elem_type, b1, b1)

			denom    := spv.OpFAdd(&ctx.functions, elem_type, a1_a1, b1_b1)

			real_num := spv.OpFAdd(&ctx.functions, elem_type, a0_a1, b0_b1)
			imag_num := spv.OpFSub(&ctx.functions, elem_type, b0_a1, a0_b1)

			real     := spv.OpFDiv(&ctx.functions, elem_type, real_num, denom)
			imag     := spv.OpFDiv(&ctx.functions, elem_type, imag_num, denom)

			ret      := spv.OpCompositeConstruct(&ctx.functions, return_type_id, real, imag)
			spv.OpReturnValue(&ctx.functions, ret)

		case .Quaternion128_Mul, .Quaternion256_Mul:
			unimplemented()

		case .Quaternion128_Div, .Quaternion256_Div:
			unimplemented()
		}

		spv.OpFunctionEnd(&ctx.functions)
	}

	for c in ctx.capabilities {
		spv.OpCapability(&ctx.meta, c)
	}
	for e in ctx.extensions {
		spv.OpExtension(&ctx.meta, e)
	}

	spirv := slice.concatenate([][]u32{
		ctx.meta.data[:],
		ctx.ext_inst.data[:],
		ctx.memory_model.data[:],
		ctx.entry_points.data[:],
		ctx.execution_modes.data[:],
		ctx.debug_a.data[:],
		ctx.debug_b.data[:],
		ctx.annotations.data[:],
		ctx.types.data[:],
		ctx.globals.data[:],
		ctx.functions.data[:],
		b.data[:],
	}, allocator)
	spirv[spv.ID_BOUND_INDEX] = u32(ctx.current_id + 1)
	return spirv
}

cg_constant :: proc(ctx: ^Context, value: types.Const_Value, type: ^types.Type) -> Value {
	type := type

	if type == nil {
		switch v in value {
		case i64:
			type = types.t_i32
		case f64:
			type = types.t_f32
		case bool:
			type = types.t_bool
		case string:
			panic("String constant used as value")
		}
	} else {
		type = types.default_type(types.base_type(type))
		switch type.kind {
		case .Uint, .Int, .Bool, .Float:
			// fine

		case .Invalid:
			panic("Tried to generate constant with invalid type")
		case .Struct:
			panic("Tried to generate constant with struct type")
		case .Sampler:
			panic("Tried to generate constant with sampler type")
		case .Image:
			panic("Tried to generate constant with image type")
		case .Buffer:
			panic("Tried to generate constant with buffer type")
		case .Proc:
			panic("Tried to generate constant with proc type")
		case .Tuple:
			panic("Tried to generate constant with tuple type")
		case .Enum:
			panic("Tried to generate constant with enum type")
		case .Bit_Set:
			panic("Tried to generate constant with bit_set type")
		case .Complex:
			panic("Tried to generate constant with complex type")
		case .Quaternion:
			panic("Tried to generate constant with quaternion type")

		case .Matrix:
			type = types.matrix_elem(type)
		case .Vector:
			type = types.vector_elem(type)
		}
	}

	key := Constant_Key {
		type  = type,
		value = value,
	}
	cached := hashmap.get(ctx.constant_cache, key)
	if cached != nil {
		return {
			id   = cached^,
			type = type,
		},
	}

	ti := cg_type(ctx, type)

	id: spv.Id
	switch v in value {
	case i64:
		if types.is_float(type) {
			id = spv.OpConstant(&ctx.types, ti.type, transmute(u32)f32(v))
		} else {
			id = spv.OpConstant(&ctx.types, ti.type, u32(v))
		}
	case f64:
		if types.is_float(type) {
			id = spv.OpConstant(&ctx.types, ti.type, transmute(u32)f32(v))
		} else {
			id = spv.OpConstant(&ctx.types, ti.type, u32(v))
		}
	case bool:
		if v {
			id = spv.OpConstantTrue(&ctx.types, ti.type)
		} else {
			id = spv.OpConstantFalse(&ctx.types, ti.type)
		}
	case string:
		panic("")
	}

	hashmap.insert(&ctx.constant_cache, key, id)

	return { id = id, type = type, }
}

cg_nil_value :: proc {
	cg_nil_value_from_type,
	cg_nil_value_from_type_info,
}

@(require_results)
cg_nil_value_from_type :: proc(ctx: ^Context, type_info: ^Type_Info) -> spv.Id {
	if type_info.nil_value == 0 {
		type_info.nil_value = spv.OpConstantNull(&ctx.types, type_info.type)
	}
	return type_info.nil_value
}

@(require_results)
cg_nil_value_from_type_info :: proc(ctx: ^Context, type: ^types.Type) -> spv.Id {
	return cg_nil_value_from_type(ctx, cg_type(ctx, type))
}

cg_type_ptr :: proc {
	cg_type_ptr_from_type,
	cg_type_ptr_from_type_info,
}

@(require_results)
cg_type_ptr_from_type :: proc(ctx: ^Context, type_info: ^Type_Info, storage_class: Storage_Class) -> spv.Id {
	if type_info.ptr_types[storage_class] == 0 {
		spv_storage_class: spv.StorageClass
		switch storage_class {
		case .By_Value:
			panic("")
		case .Global:
			spv_storage_class = .Private
		case .Function:
			spv_storage_class = .Function
		case .Uniform:
			spv_storage_class = .Uniform
		case .Input:
			spv_storage_class = .Input
		case .Output:
			spv_storage_class = .Output
		case .Push_Constant:
			spv_storage_class = .PushConstant
		case .Uniform_Constant:
			spv_storage_class = .UniformConstant
		case .Storage_Buffer:
			spv_storage_class = .StorageBuffer
		case .Physical_Storage_Buffer:
			spv_storage_class = .PhysicalStorageBuffer
		case .Image:
			spv_storage_class = .Image
		}
		type_info.ptr_types[storage_class] = spv.OpTypePointer(&ctx.types, spv_storage_class, type_info.type)
	}
	return type_info.ptr_types[storage_class]
}

@(require_results)
cg_type_ptr_from_type_info :: proc(ctx: ^Context, type: ^types.Type, storage_class: Storage_Class) -> spv.Id {
	return cg_type_ptr_from_type(ctx, cg_type(ctx, type), storage_class)
}

Type_Flag :: enum {
	Block,
	Explicit_Layout,
}

Type_Flags :: bit_set[Type_Flag]

@(require_results)
cg_type :: proc(ctx: ^Context, type: ^types.Type, flags: Type_Flags = {}) -> ^Type_Info {
	assert(type != nil)
	assert(.Block not_in flags || .Explicit_Layout in flags)
	type := types.base_type(type)

	registry := &ctx.type_registry
	info, ok := register_type(registry, { type, flags, })
	if ok {
		assert(info.type != 0)
		return info
	}

	switch type.kind {
	case .Uint:
		assert(type.size != 0)
		info.type = spv.OpTypeInt(&ctx.types, u32(type.size * 8), 0)
		cap: spv.Capability
		switch type.size {
		case 1:
			cap = .Int8
		case 2:
			cap = .Int16
		case 8:
			cap = .Int64
		}
		if cap != nil {
			ctx.capabilities[cap] = {}
		}
	case .Int:
		assert(type.size != 0)
		info.type = spv.OpTypeInt(&ctx.types, u32(type.size * 8), 1)
		cap: spv.Capability
		switch type.size {
		case 1:
			cap = .Int8
		case 2:
			cap = .Int16
		case 8:
			cap = .Int64
		}
		if cap != nil {
			ctx.capabilities[cap] = {}
		}
	case .Float:
		assert(type.size != 0)
		info.type = spv.OpTypeFloat(&ctx.types, u32(type.size * 8))
		cap: spv.Capability
		switch type.size {
		case 2:
			cap = .Float16
		case 8:
			cap = .Float64
		}
		if cap != nil {
			ctx.capabilities[cap] = {}
		}
	case .Bool:
		info.type = spv.OpTypeBool(&ctx.types)
	case .Struct, .Tuple:
		type := type.variant.(^types.Struct)
		if len(type.fields) != 0 {
			fields := make([]spv.Id, len(type.fields))
			for &f, i in fields {
				f = cg_type(ctx, type.fields[i].type, flags - { .Block, }).type
			}
			info.type = spv.OpTypeStruct(&ctx.types, ..fields)
			for f, i in type.fields {
				i := u32(i)
				spv.OpMemberName(&ctx.debug_b, info.type, i, f.name.text)

				if .Explicit_Layout not_in flags {
					continue
				}
				spv.OpMemberDecorate(&ctx.annotations, info.type, u32(i), .Offset, u32(f.offset))
				type_matrix := type.fields[i].type.variant.(^types.Matrix) or_continue
				spv.OpMemberDecorate(&ctx.annotations, info.type, i, .MatrixStride, u32(type_matrix.col_type.size))
				spv.OpMemberDecorate(&ctx.annotations, info.type, i, .ColMajor)
			}
			if .Block in flags {
				spv.OpDecorate(&ctx.annotations, info.type, .Block)
			}
		} else {
			info.type = ctx.type_void
		}
	case .Vector:
		type := type.variant.(^types.Vector)
		info.type = spv.OpTypeVector(&ctx.types, cg_type(ctx, type.elem).type, u32(type.count))
	case .Matrix:
		type := type.variant.(^types.Matrix)
		info.type = spv.OpTypeMatrix(&ctx.types, cg_type(ctx, type.col_type).type, u32(type.cols))
		ctx.capabilities[.Matrix] = {}
	case .Proc:
		type := type.variant.(^types.Proc)
		args := make([]spv.Id, len(type.args))
		for &arg, i in args {
			arg = cg_type(ctx, type.args[i].type).type
		}
		info.type = spv.OpTypeFunction(&ctx.types, cg_type(ctx, type.return_type).type, ..args)
	case .Sampler:
		type := type.variant.(^types.Image)
		sampled_type: ^types.Type
		if types.is_numeric(type.texel_type) {
			sampled_type = type.texel_type
		} else {
			assert(types.is_vector(type.texel_type))
			sampled_type = types.vector_elem(type.texel_type)
		}
		image_type := Image_Type {
			dimensions = type.dimensions,
			texel_type = {
				size = sampled_type.size,
				kind = sampled_type.kind,
			},
			sampled = true,
		}

		if cached, ok := ctx.image_types[image_type]; ok {
			info.image_type = cached.image
			info.type       = cached.sampler
			break
		}

		info.image_type = spv.OpTypeImage(&ctx.types, cg_type(ctx, sampled_type).type, spv.Dim(type.dimensions - 1), 0, 0, 0, 1, .Unknown)
		info.type       = spv.OpTypeSampledImage(&ctx.types, info.image_type)
		ctx.image_types[image_type] = { info.image_type, info.type, }
	case .Image:
		type := type.variant.(^types.Image)
		texel_type: ^types.Type
		if types.is_numeric(type.texel_type) {
			texel_type = type.texel_type
		} else {
			assert(types.is_vector(type.texel_type))
			texel_type = types.vector_elem(type.texel_type)
		}
		image_type := Image_Type {
			dimensions = type.dimensions,
			texel_type = {
				size = texel_type.size,
				kind = texel_type.kind,
			},
			sampled = false,
		}

		if cached, ok := ctx.image_types[image_type]; ok {
			info.type = cached.image
			break
		}

		info.type = spv.OpTypeImage(&ctx.types, cg_type(ctx, texel_type).type, spv.Dim(type.dimensions - 1), 0, 0, 0, 2, .Unknown)
		ctx.image_types[image_type] = { image = info.type, }
	case .Buffer:
		type := type.variant.(^types.Buffer)
		elem := cg_type(ctx, type.elem, { .Explicit_Layout, })
		if type.physical {
			ctx.extensions["SPV_KHR_physical_storage_buffer"] = {}
			ctx.capabilities[.PhysicalStorageBufferAddresses] = {}
			info.type = spv.OpTypePointer(&ctx.types, .PhysicalStorageBuffer, elem.type)
			spv.OpDecorate(&ctx.annotations, info.type, .ArrayStride, u32(type.elem.size))
			if .Block in flags {
				spv.OpDecorate(&ctx.annotations, info.type, .Block)
				spv.OpMemberDecorate(&ctx.annotations, info.type, 0, .Offset, 0)
			}
		} else {
			info.array_type = spv.OpTypeRuntimeArray(&ctx.types, elem.type)
			info.type       = spv.OpTypeStruct(&ctx.types, info.array_type)
			info.array_ptr  = spv.OpTypePointer(&ctx.types, .StorageBuffer, info.array_type)
			spv.OpDecorate(&ctx.annotations, info.array_type, .ArrayStride, u32(type.elem.size))
			if .Block in flags {
				spv.OpDecorate(&ctx.annotations, info.type, .Block)
				spv.OpMemberDecorate(&ctx.annotations, info.type, 0, .Offset, 0)
			}
		}
	case .Invalid, .Enum, .Bit_Set, .Complex, .Quaternion:
		unreachable()
	}

	return info
}

cg_proc_internal :: proc(ctx: ^Context, p: ^ast.Expr_Proc_Lit, id: spv.Id, link_name: string) {
	ctx.shader_stage  = p.shader_stage
	type             := p.type.variant.(^types.Proc)
	return_type_info := cg_type(ctx, type.return_type)
	proc_type_id     := cg_type(ctx, type).type
	return_type_id   := return_type_info.type
	if p.shader_stage != nil {
		proc_type_id   = ctx.type_void_proc
		return_type_id = ctx.type_void
	}

	{
		// somewhat hacky, not sure if there is a nicer way of doing this
		// maybe we should at least make ids be post incremented
		// or maybe there should be a way of explicitly setting result-ids
		id := id - 1
		ctx.functions.current_id = &id
		_ = spv.OpFunction(&ctx.functions, return_type_id, {}, proc_type_id)
		ctx.functions.current_id = &ctx.current_id
	}

	scope := scope_push(ctx)
	defer scope_pop(ctx)

	return_value: spv.Id
	body := spv.Builder { current_id = &ctx.current_id, }

	outputs: [dynamic]spv.Id
	if p.shader_stage != nil {
		for arg, i in type.args {
			id := spv.OpVariable(&ctx.globals, cg_type_ptr(ctx, arg.type, .Input), .Input, nil)
			cg_insert_entity(ctx, p.args[i].ident.text, .Input, arg.type, id)
			ctx.referenced_globals[id] = {}
			location := u32(i)
			if arg.location != -1 {
				location = u32(arg.location)
			}
			spv.OpDecorate(&ctx.annotations, id, .Location, location)
			if types.is_integer(arg.type) || (types.is_vector(arg.type) && types.is_integer(types.vector_elem(arg.type))) {
				spv.OpDecorate(&ctx.annotations, id, .Flat)
			}
		}
		label := spv.OpLabel(&ctx.functions)
		spv.OpName(&ctx.debug_b, label, "$FN_SETUP")
		if len(type.returns) != 0 {
			for ret, i in type.returns {
				type_info := cg_type(ctx, ret.type)
				id        := spv.OpVariable(&ctx.globals, cg_type_ptr(ctx, type_info, .Output), .Output, nil)
				name      := ret.name.text
				if ret.value != nil {
					init := cg_constant(ctx, ret.value, ret.type)
					spv.OpStore(&body, id, init.id)
				}
				cg_insert_entity(ctx, name, .Output, ret.type, id)
				ctx.referenced_globals[id] = {}
				append(&outputs, id)
				location := u32(i)
				if ret.location != -1 {
					location = u32(ret.location)
				}
				spv.OpDecorate(&ctx.annotations, id, .Location, location)
				if types.is_integer(ret.type) || (types.is_vector(ret.type) && types.is_integer(types.vector_elem(ret.type))) {
					spv.OpDecorate(&ctx.annotations, id, .Flat)
				}
			}
		}
	} else {
		for arg, i in type.args {
			id := spv.OpFunctionParameter(&ctx.functions, cg_type(ctx, arg.type).type)
			cg_insert_entity(ctx, p.args[i].ident.text, nil, arg.type, id)
		}
		label := spv.OpLabel(&ctx.functions)
		spv.OpName(&ctx.debug_b, label, "$FN_SETUP")
		if len(type.returns) != 0 {
			return_value = spv.OpVariable(&ctx.functions, cg_type_ptr(ctx, return_type_info, .Function), .Function, cg_nil_value(ctx, return_type_info))
			spv.OpName(&ctx.debug_b, return_value, "$return_tuple")
			for ret, i in type.returns {
				type_info := cg_type(ctx, ret.type)
				id        := spv.OpAccessChain(&body, cg_type_ptr(ctx, type_info, .Function), return_value, cg_constant(ctx, i64(i), nil).id)
				name      := ret.name.text
				if ret.value != nil {
					init := cg_constant(ctx, ret.value, ret.type)
					spv.OpStore(&body, id, init.id)
				}
				cg_insert_entity(ctx, name, .Function, ret.type, id)
			}
		}
	}

	scope.return_value = return_value
	scope.return_type  = type.return_type
	scope.outputs      = outputs[:]

	returned := cg_stmt_list(ctx, &body, p.body)
	if !returned {
		proc_scope  := cg_lookup_proc_scope(ctx)
		return_type := cg_type(ctx, proc_scope.return_type)
		if proc_scope.return_value != 0 {
			spv.OpReturnValue(&body, spv.OpLoad(&body, return_type.type, proc_scope.return_value))
		} else {
			spv.OpReturn(&body)
		}
	}

	append(&ctx.functions.data, ..body.data[:])
	spv.OpFunctionEnd(&ctx.functions)

	if p.shader_stage != nil {
		execution_mode: spv.ExecutionModel
		#partial switch p.shader_stage {
		case .Vertex:
			execution_mode = .Vertex
		case .Fragment:
			execution_mode = .Fragment
		case .Geometry:
			execution_mode = .Geometry
		case .Tesselation:
			execution_mode = .TessellationControl
		case .Compute:
			execution_mode = .GLCompute
		}
		interface := make([dynamic]spv.Id, 0, len(ctx.referenced_globals))
		for g in ctx.referenced_globals {
			append(&interface, g)
		}
		clear(&ctx.referenced_globals)
		spv.OpEntryPoint(&ctx.entry_points, execution_mode, id, link_name, ..interface[:])
		#partial switch p.shader_stage {
		case .Fragment:
			spv.OpExecutionMode(&ctx.execution_modes, id, .OriginUpperLeft)
		case .Compute:
			spv.OpExecutionMode(&ctx.execution_modes, id, .LocalSize, u32(ctx.local_size.x), u32(ctx.local_size.y), u32(ctx.local_size.z))
		}
	}
}

@(require_results)
cg_proc_lit :: proc(ctx: ^Context, p: ^ast.Expr_Proc_Lit) -> Value {
	ctx.current_id += 1
	id := ctx.current_id

	append(&ctx.procs, Proc_Lit_Info {
		expr      = p,
		id        = id,
		link_name = ctx.link_name,
	})

	return { id = id, }
}

@(require_results)
cg_deref :: proc(ctx: ^Context, builder: ^spv.Builder, value: Value) -> spv.Id {
	if len(value.swizzle) != 0 {
		id := value.id
		if value.storage_class != .By_Value {
			id = spv.OpLoad(builder, cg_type(ctx, value.real_type).type, value.id)
		}
		return spv.OpVectorShuffle(builder, cg_type(ctx, value.type).type, id, id, ..value.swizzle)
	}
	if value.explicit_layout && types.is_struct(value.type) {
		type    := value.type.variant.(^types.Struct)
		members := make([dynamic]spv.Id, 0, len(type.fields), context.temp_allocator)
		// TODO: handle members that are structs
		for f, i in type.fields {
			field_ti  := cg_type(ctx, f.type)
			field_ptr := spv.OpAccessChain(builder, cg_type_ptr(ctx, field_ti, value.storage_class), value.id, cg_constant(ctx, i64(i), nil).id)
			if value.storage_class == .Physical_Storage_Buffer {
				append(&members, spv.OpLoad(builder, field_ti.type, field_ptr, spv.MemoryAccess{ .Aligned, }, u32(f.type.align)))
			} else {
				append(&members, spv.OpLoad(builder, field_ti.type, field_ptr))
			}
		}
		return spv.OpCompositeConstruct(builder, cg_type(ctx, value.type).type, ..members[:])
	}
	#partial switch value.storage_class {
	case .Image:
		ctx.capabilities[.StorageImageReadWithoutFormat] = {}

		texel_type: ^types.Type
		vector_len: int
		if types.is_numeric(value.type) {
			vector_len = 1
			texel_type = types.vector_new(value.type, 4, context.temp_allocator)
		} else if types.is_vector(value.type) {
			vector_len = types.vector_len(value.type)
			if vector_len == 4 {
				texel_type = value.type
			} else {
				texel_type = types.vector_new(types.vector_elem(value.type), 4, context.temp_allocator)
			}
		} else {
			panic("")
		}
		texel := spv.OpImageRead(builder, cg_type(ctx, texel_type).type, value.id, value.coord)
		switch vector_len {
		case 1:
			return spv.OpCompositeExtract(builder, cg_type(ctx, value.type).type, texel, 0)
		case 2:
			indices := [2]u32{ 0, 1, }
			return spv.OpVectorShuffle(builder, cg_type(ctx, value.type).type, texel, texel, ..indices[:])
		case 3:
			indices := [3]u32{ 0, 1, 2, }
			return spv.OpVectorShuffle(builder, cg_type(ctx, value.type).type, texel, texel, ..indices[:])
		case 4:
			return texel
		}
		return texel
	case .By_Value:
		return value.id
	case .Physical_Storage_Buffer:
		return spv.OpLoad(builder, cg_type(ctx, value.type).type, value.id, spv.MemoryAccess { .Aligned, }, u32(value.type.align))
	case:
		return spv.OpLoad(builder, cg_type(ctx, value.type).type, value.id)
	}
}

@(require_results)
cg_expr_binary :: proc(
	ctx:                  ^Context,
	builder:              ^spv.Builder,
	op:                   tokenizer.Token_Kind,
	lhs_value, rhs_value: Value,
	type:                ^^types.Type,
) -> spv.Id {
	lhs      := lhs_value.id
	rhs      := rhs_value.id
	lhs_type := lhs_value.type
	rhs_type := rhs_value.type

	if checker.op_is_relation(op) {
		type^      = types.t_bool
		type_info := cg_type(ctx, type^)

		t: ^types.Type
		if lhs_type.kind == .Float {
			t   = lhs_type
			rhs = cg_cast(ctx, builder, { id = rhs, type = rhs_type, }, t)
		} else {
			t   = rhs_type
			lhs = cg_cast(ctx, builder, { id = lhs, type = lhs_type, }, t)
		}
		#partial switch t.kind {
		case .Int:
			#partial switch op {
			case .Equal:
				return spv.OpIEqual(builder, type_info.type, lhs, rhs)
			case .Not_Equal:
				return spv.OpINotEqual(builder, type_info.type, lhs, rhs)
			case .Less:
				return spv.OpSLessThan(builder, type_info.type, lhs, rhs)
			case .Less_Equal:
				return spv.OpSLessThanEqual(builder, type_info.type, lhs, rhs)
			case .Greater:
				return spv.OpSGreaterThan(builder, type_info.type, lhs, rhs)
			case .Greater_Equal:
				return spv.OpSGreaterThanEqual(builder, type_info.type, lhs, rhs)
			}
		case .Uint:
			#partial switch op {
			case .Equal:
				return spv.OpIEqual(builder, type_info.type, lhs, rhs)
			case .Not_Equal:
				return spv.OpINotEqual(builder, type_info.type, lhs, rhs)
			case .Less:
				return spv.OpULessThan(builder, type_info.type, lhs, rhs)
			case .Less_Equal:
				return spv.OpULessThanEqual(builder, type_info.type, lhs, rhs)
			case .Greater:
				return spv.OpUGreaterThan(builder, type_info.type, lhs, rhs)
			case .Greater_Equal:
				return spv.OpUGreaterThanEqual(builder, type_info.type, lhs, rhs)
			}
		case .Float:
			#partial switch op {
			case .Equal:
				return spv.OpFOrdEqual(builder, type_info.type, lhs, rhs)
			case .Not_Equal:
				return spv.OpFOrdNotEqual(builder, type_info.type, lhs, rhs)
			case .Less:
				return spv.OpFOrdLessThan(builder, type_info.type, lhs, rhs)
			case .Less_Equal:
				return spv.OpFOrdLessThanEqual(builder, type_info.type, lhs, rhs)
			case .Greater:
				return spv.OpFOrdGreaterThan(builder, type_info.type, lhs, rhs)
			case .Greater_Equal:
				return spv.OpFOrdGreaterThanEqual(builder, type_info.type, lhs, rhs)
			}
		case .Bool:
			#partial switch op {
			case .Equal:
				return spv.OpLogicalEqual(builder, type_info.type, lhs, rhs)
			case .Not_Equal:
				return spv.OpLogicalNotEqual(builder, type_info.type, lhs, rhs)
			}
		}
		panic("")
	}

	type^      = types.op_result_type(lhs_type, rhs_type, op == .Multiply, context.temp_allocator)
	type_info := cg_type(ctx, type^)

	Binary_Op_Proc :: proc(builder: ^spv.Builder, result_type: spv.Id, operand_1, operand_2: spv.Id) -> (result: spv.Id)

	binary_op_inst :: proc(ctx: ^Context, lhs_type, rhs_type, type: ^types.Type, op: tokenizer.Token_Kind) -> Binary_Op_Proc {
		runtime_proc: Runtime_Proc
		#partial switch type.kind {
		case .Int:
			#partial switch op {
			case .Add:
				return spv.OpIAdd
			case .Subtract:
				return spv.OpISub
			case .Multiply:
				return spv.OpIMul
			case .Divide:
				return spv.OpSDiv
			case .Modulo:
				return spv.OpSMod
			case .Bit_Or:
				return spv.OpBitwiseOr
			case .Bit_And:
				return spv.OpBitwiseAnd
			case .Xor:
				return spv.OpBitwiseXor
			}
		case .Uint:
			#partial switch op {
			case .Add:
				return spv.OpIAdd
			case .Subtract:
				return spv.OpISub
			case .Multiply:
				return spv.OpIMul
			case .Divide:
				return spv.OpUDiv
			case .Modulo:
				return spv.OpUMod
			case .Bit_Or:
				return spv.OpBitwiseOr
			case .Bit_And:
				return spv.OpBitwiseAnd
			case .Xor:
				return spv.OpBitwiseXor
			}
		case .Float:
			#partial switch op {
			case .Add:
				return spv.OpFAdd
			case .Subtract:
				return spv.OpFSub
			case .Multiply:
				return spv.OpFMul
			case .Modulo:
				return spv.OpFMod
			case .Divide:
				return spv.OpFDiv
			}
		case .Bool:
			#partial switch op {
			case .And:
				return spv.OpLogicalAnd
			case .Or:
				return spv.OpLogicalOr
			}
			unimplemented()
		case .Matrix:
			#partial switch op {
			case .Multiply:
				return spv.OpMatrixTimesMatrix
			}
			unimplemented()
		case .Vector:
			if lhs_type.kind == .Matrix || rhs_type.kind == .Matrix {
				assert(op == .Multiply)

				if lhs_type.kind == .Matrix {
					return spv.OpMatrixTimesVector
				} else {
					panic("")
					// assert(rhs_type.kind == .Matrix)
					// return spv.OpVectorTimesMatrix(builder, type_info.type, lhs, rhs)
				}
			}

			if lhs_type.kind == .Vector && rhs_type.kind == .Vector {
				return binary_op_inst(ctx, types.vector_elem(lhs_type), types.vector_elem(rhs_type), types.vector_elem(type), op)
			}
		case .Complex:
			#partial switch op {
			case .Add, .Subtract:
				return binary_op_inst(ctx, types.complex_elem(lhs_type), types.complex_elem(rhs_type), types.complex_elem(type), op)
			case .Multiply:
				switch types.complex_elem(type).size {
				case 4:
					runtime_proc = .Complex64_Mul
				case 8:
					runtime_proc = .Complex128_Mul
				}
			case .Divide:
				switch types.complex_elem(type).size {
				case 4:
					runtime_proc = .Complex64_Div
				case 8:
					runtime_proc = .Complex128_Div
				}
			}

		case .Quaternion:
			#partial switch op {
			case .Add, .Subtract:
				return binary_op_inst(ctx, types.complex_elem(lhs_type), types.complex_elem(rhs_type), types.complex_elem(type), op)
			case .Multiply:
				switch types.complex_elem(type).size {
				case 4:
					runtime_proc = .Quaternion128_Mul
				case 8:
					runtime_proc = .Quaternion256_Mul
				}
			case .Divide:
				switch types.complex_elem(type).size {
				case 4:
					runtime_proc = .Quaternion128_Div
				case 8:
					runtime_proc = .Quaternion256_Div
				}
			}
		}

		if runtime_proc != nil {
			@(static)
			runtime_proc_id: spv.Id
			runtime_proc_id = get_runtime_proc(ctx, runtime_proc)

			return proc(builder: ^spv.Builder, result_type: spv.Id, operand_1, operand_2: spv.Id) -> (result: spv.Id) {
				return spv.OpFunctionCall(builder, result_type, runtime_proc_id, operand_1, operand_2)
			}
		}

		return nil
	}

	op_fn := binary_op_inst(ctx, lhs_type, rhs_type, type^, op)
	assert(op_fn != nil)
	return op_fn(builder, type_info.type, lhs, rhs)
}

@(require_results)
cg_interface :: proc(
	ctx:     ^Context,
	builtin: string,
) -> (value: Value) {
	defer ctx.referenced_globals[value.id] = {}

	builtin, ok := reflect.enum_from_name(spv.BuiltIn, builtin)
	assert(ok)

	info := checker.interface_infos[builtin]
	storage_class:     Storage_Class
	spv_storage_class: spv.StorageClass
	switch info.usage[ctx.shader_stage] {
	case .In:
		storage_class     = .Input
		spv_storage_class = .Input
	case .Out:
		storage_class     = .Output
		spv_storage_class = .Output
	case:
		panic("")
	}

	value.storage_class = storage_class
	value.type          = info.type
	type_info          := cg_type(ctx, value.type)
	value.id            = spv.OpVariable(&ctx.globals, cg_type_ptr(ctx, type_info, storage_class), spv_storage_class)
	spv.OpDecorate(&ctx.annotations, value.id, .BuiltIn, u32(builtin))

	return
}

@(require_results)
cg_expr :: proc(
	ctx:     ^Context,
	builder: ^spv.Builder,
	expr:    ^ast.Expr,
	deref:   bool = true,
) -> (value: Value) {
	assert(expr      != nil)
	assert(expr.type != nil)

	value = _cg_expr(ctx, builder, expr)
	if value.type == nil {
		value.type = expr.type
	}

	if !deref {
		// assert(value.storage_class != nil)
		return value
	}
	value.id            = cg_cast(ctx, builder, value, expr.type)
	value.storage_class = nil
	value.type          = expr.type
	return
}

@(require_results)
cg_cast :: proc(
	ctx:     ^Context,
	builder: ^spv.Builder,
	value:    Value,
	type:    ^types.Type,
) -> spv.Id {
	type               := types.base_type(type, true)
	v_type             := types.base_type(value.type)
	value              := value
	value.id            = cg_deref(ctx, builder, value)
	value.storage_class = nil

	if types.equal(v_type, types.base_type(type)) {
		return value.id
	}

	ti := cg_type(ctx, type)

	Cast_Op_Proc :: proc(builder: ^spv.Builder, result_type: spv.Id, value: spv.Id) -> (result: spv.Id)
	numeric_cast_op_inst :: proc(from, to: ^types.Type) -> Cast_Op_Proc {
		if from.size == to.size && types.is_integer(from) && types.is_integer(to) {
			return spv.OpBitcast
		}

		#partial switch to.kind {
		case .Float:
			#partial switch from.kind {
			case .Float:
				return spv.OpFConvert
			case .Uint:
				return spv.OpConvertUToF
			case .Int:
				return spv.OpConvertSToF
			case:
				unreachable()
			}
		case .Int:
			#partial switch from.kind {
			case .Float:
				return spv.OpConvertFToS
			case .Uint:
				return spv.OpSConvert
			case .Int:
				return spv.OpSConvert
			case:
				unreachable()
			}
		case .Uint:
			#partial switch from.kind {
			case .Float:
				return spv.OpConvertFToU
			case .Uint:
				return spv.OpUConvert
			case .Int:
				return spv.OpSConvert
			case:
				unreachable()
			}
		}
		return nil
	}

	op_inst := numeric_cast_op_inst(v_type, type)
	if op_inst != nil {
		return op_inst(builder, ti.type, value.id)
	}

	#partial switch type.kind {
	case .Complex:
		zero := cg_nil_value(ctx, ti)
		return spv.OpCompositeInsert(builder, ti.type, value.id, zero, 0)
	case .Vector:
		type := type.variant.(^types.Vector)
		if types.is_numeric(v_type) {
			values := make([]spv.Id, type.count, context.temp_allocator)
			casted := cg_cast(ctx, builder, value, type.elem)
			for &v in values {
				v = casted
			}
			return spv.OpCompositeConstruct(builder, ti.type, ..values)
		} else {
			op_inst := numeric_cast_op_inst(types.vector_elem(v_type), type.elem)
			assert(op_inst != nil)
			return op_inst(builder, ti.type, value.id)
		}
	case .Matrix:
		assert(types.is_numeric(v_type))
		type    := type.variant.(^types.Matrix)
		cols    := make([]spv.Id, type.cols, context.temp_allocator)
		col_ti  := cg_type(ctx, type.col_type)
		elem_ti := cg_type(ctx, type.col_type)
		for &col, col_i in cols {
			values := make([]spv.Id, type.col_type.count, context.temp_allocator)
			for &v, i in values {
				if i == col_i {
					v = value.id
				} else {
					v = cg_nil_value(ctx, elem_ti)
				}
			}
			col = spv.OpCompositeConstruct(builder, col_ti.type, ..values)
		}
		return spv.OpCompositeConstruct(builder, ti.type, ..cols)
	}

	unreachable()
}

spv_version :: proc(major, minor: u32) -> u32 {
	return (major << 16) | (minor << 8)
}

_cg_expr :: proc(
	ctx:     ^Context,
	builder: ^spv.Builder,
	expr:    ^ast.Expr,
) -> (value: Value) {
	assert(expr      != nil)
	assert(expr.type != nil)

	if expr.const_value != nil {
		if v, ok := expr.derived_expr.(^ast.Expr_Constant); ok && v.imaginary != nil {
			val  := cg_constant(ctx, expr.const_value, types.complex_elem(expr.type))
			ti   := cg_type(ctx, expr.type)
			zero := cg_nil_value(ctx, ti)
			index: u32
			#partial switch v.imaginary {
			case .i:
				index = 1
			case .j:
				index = 2
			case .k:
				index = 3
			}
			value.id   = spv.OpCompositeInsert(builder, ti.type, val.id, zero, index)
			value.type = expr.type
			return
		}
		return cg_constant(ctx, expr.const_value, expr.type)
	}

	switch v in expr.derived_expr {
	case ^ast.Expr_Interface:
		return cg_interface(ctx, v.ident.text)
	case ^ast.Expr_Constant:
		panic("Constant expr without a constant value")
	case ^ast.Expr_Binary:
		lhs, rhs := cg_expr(ctx, builder, v.lhs), cg_expr(ctx, builder, v.rhs)
		value.id  = cg_expr_binary(ctx, builder, v.op, lhs, rhs, &value.type)
		return
	case ^ast.Expr_Ident:
		value = cg_lookup_entity(ctx, v.ident.text)^
		#partial switch value.storage_class {
		case .Push_Constant, .Storage_Buffer, .Uniform, .Uniform_Constant:
			value.explicit_layout = true
			fallthrough
		case .Global:
			if ctx.spirv_version > spv_version(1, 3) {
				ctx.referenced_globals[value.id] = {}
			}
		}
		return
	case ^ast.Expr_Proc_Lit:
		return cg_proc_lit(ctx, v)
	case ^ast.Expr_Proc_Sig:
	case ^ast.Expr_Paren:
		return cg_expr(ctx, builder, v.expr)
	case ^ast.Expr_Selector:
		lhs := cg_expr(ctx, builder, v.lhs, false)

		lhs_type := v.lhs.type
		if lhs.type.kind == .Struct {
			field_index: int = -1
			type_info:   ^Type_Info
			field_type:  ^types.Type
			for field, i in lhs_type.variant.(^types.Struct).fields {
				if field.name.text == v.selector.text {
					field_index = i
					type_info   = cg_type(ctx, field.type)
					field_type  = field.type
					break
				}
			}
			assert(field_index != -1)

			ptr := spv.OpAccessChain(builder, cg_type_ptr(ctx, type_info, lhs.storage_class), lhs.id, cg_constant(ctx, i64(field_index), nil).id)

			return { id = ptr, storage_class = lhs.storage_class, type = field_type, }
		}

		assert(lhs.type.kind == .Vector)

		indices := make([dynamic]u32, 0, len(v.selector.text))
		for char in v.selector.text {
			switch char {
			case 'x', 'r':
				append(&indices, 0)
			case 'y', 'g':
				append(&indices, 1)
			case 'z', 'b':
				append(&indices, 2)
			case 'w', 'a':
				append(&indices, 3)
			}
		}

		if len(indices) == 1 && lhs.storage_class != .Image {
			t := types.vector_elem(lhs.type)
			if lhs.storage_class != nil {
				id    := spv.OpAccessChain(builder, cg_type_ptr(ctx, t, lhs.storage_class), lhs.id, cg_constant(ctx, i64(indices[0]), nil).id)
				value := Value { id = id, storage_class = lhs.storage_class, type = t, }
				return value
			}

			return { id = spv.OpCompositeExtract(builder, cg_type(ctx, t).type, lhs.id, indices[0]), type = t, }
		}

		return {
			id            = lhs.id,
			type          = v.type,
			real_type     = lhs.type,
			swizzle       = indices[:],
			storage_class = lhs.storage_class,
			coord         = lhs.coord,
		}

	case ^ast.Expr_Call:
		if v.builtin != nil {
			ti := cg_type(ctx, v.type)
			switch v.builtin {
			case .Invalid, .Size_Of, .Align_Of, .Type_Of:
				fmt.panicf("invalid builtin: %v", v.builtin)
			case .Dot:
				t := types.op_result_type(v.args[0].value.type, v.args[1].value.type)
				a := cg_cast(ctx, builder, cg_expr(ctx, builder, v.args[0].value), t)
				b := cg_cast(ctx, builder, cg_expr(ctx, builder, v.args[1].value), t)
				id: spv.Id
				#partial switch types.vector_elem(t).kind {
				case .Float:
					id = spv.OpDot (builder, ti.type, a, b)
				case .Int:
					id = spv.OpSDot(builder, ti.type, a, b)
				case .Uint:
					id = spv.OpUDot(builder, ti.type, a, b)
				case:
					unreachable()
				}
				return { id = id, }
			case .Cross:
				a   := cg_cast(ctx, builder, cg_expr(ctx, builder, v.args[0].value), v.type)
				b   := cg_cast(ctx, builder, cg_expr(ctx, builder, v.args[1].value), v.type)
				e   := types.vector_elem(v.type)
				eti := cg_type(ctx, e)
				id: spv.Id
				#partial switch e.kind {
				case .Float:
					id = spv_glsl.OpCross(builder, ti.type, a, b)
				case .Int, .Uint:
					a0 := spv.OpCompositeExtract(builder, eti.type, a, 0)
					a1 := spv.OpCompositeExtract(builder, eti.type, a, 1)
					a2 := spv.OpCompositeExtract(builder, eti.type, a, 2)

					b0 := spv.OpCompositeExtract(builder, eti.type, b, 0)
					b1 := spv.OpCompositeExtract(builder, eti.type, b, 1)
					b2 := spv.OpCompositeExtract(builder, eti.type, b, 2)

					x := spv.OpISub(builder, eti.type, spv.OpIMul(builder, eti.type, a1, b2), spv.OpIMul(builder, eti.type, b1, a2))
					y := spv.OpISub(builder, eti.type, spv.OpIMul(builder, eti.type, a2, b0), spv.OpIMul(builder, eti.type, b2, a0))
					z := spv.OpISub(builder, eti.type, spv.OpIMul(builder, eti.type, a0, b1), spv.OpIMul(builder, eti.type, b0, a1))

					id = spv.OpCompositeConstruct(builder, ti.type, x, y, z)
				case:
					unreachable()
				}
				return { id = id, }
			case .Min, .Max:
				f: type_of(spv_glsl.OpFMin)
				elem_type := v.type
				if v.type.kind == .Vector {
					elem_type = types.vector_elem(v.type)
				}

				#partial switch elem_type.kind {
				case .Float:
					f = spv_glsl.OpFMin if v.builtin == .Min else spv_glsl.OpFMax
				case .Int:
					f = spv_glsl.OpSMin if v.builtin == .Min else spv_glsl.OpSMax
				case .Uint:
					f = spv_glsl.OpUMin if v.builtin == .Min else spv_glsl.OpUMax
				}

				running := cg_cast(ctx, builder, cg_expr(ctx, builder, v.args[0].value), v.type)
				for arg in v.args[1:] {
					current := cg_cast(ctx, builder, cg_expr(ctx, builder, arg.value), v.type)
					running  = f(builder, ti.type, running, current)
				}

				return { id = running, }
			case .Sqrt:
				return { id = spv_glsl.OpSqrt(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Sin:
				return { id = spv_glsl.OpSin(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Cos:
				return { id = spv_glsl.OpCos(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Tan:
				return { id = spv_glsl.OpTan(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Exp:
				return { id = spv_glsl.OpExp(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Log:
				return { id = spv_glsl.OpLog(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Exp2:
				return { id = spv_glsl.OpExp2(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Log2:
				return { id = spv_glsl.OpLog2(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Fract:
				return { id = spv_glsl.OpFract(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Floor:
				return { id = spv_glsl.OpFloor(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Ceil:
				return { id = spv_glsl.OpCeil(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Round:
				return { id = spv_glsl.OpRound(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Trunc:
				return { id = spv_glsl.OpTrunc(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Inverse_Sqrt:
				return { id = spv_glsl.OpInverseSqrt(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Abs:
				t := v.args[0].value.type
				if types.is_vector(t) {
					t = types.vector_elem(t)
				}
				if types.is_integer(t) {
					return { id = spv_glsl.OpSAbs(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
				} else {
					return { id = spv_glsl.OpFAbs(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
				}
			case .Pow:
				x := cg_cast(ctx, builder, cg_expr(ctx, builder, v.args[0].value), v.type)
				y := cg_cast(ctx, builder, cg_expr(ctx, builder, v.args[1].value), v.type)
				return { id = spv_glsl.OpPow(builder, ti.type, x, y), }
			case .Normalize:
				v := cg_expr(ctx, builder, v.args[0].value)
				return { id = spv_glsl.OpNormalize(builder, cg_type(ctx, v.type).type, v.id), }
			case .Length:
				v := cg_expr(ctx, builder, v.args[0].value)
				t: ^types.Type
				if types.is_vector(v.type) {
					t = types.vector_elem(v.type)
				} else {
					t = types.complex_elem(v.type)
				}
				return { id = spv_glsl.OpLength(builder, cg_type(ctx, t).type, v.id), }
			case .Distance:
				a := cg_expr(ctx, builder, v.args[0].value).id
				b := cg_expr(ctx, builder, v.args[1].value).id
				return { id = spv_glsl.OpDistance(builder, ti.type, a, b), }
			case .Clamp:
				elem_type := v.type
				if v.type.kind == .Vector {
					elem_type = types.vector_elem(v.type)
				}

				value := cg_cast(ctx, builder, cg_expr(ctx, builder, v.args[0].value), v.type)
				min   := cg_cast(ctx, builder, cg_expr(ctx, builder, v.args[1].value), v.type)
				max   := cg_cast(ctx, builder, cg_expr(ctx, builder, v.args[2].value), v.type)

				id: spv.Id
				#partial switch elem_type.kind {
				case .Float:
					id = spv_glsl.OpFClamp(builder, cg_type(ctx, v.type).type, value, min, max)
				case .Int:
					id = spv_glsl.OpSClamp(builder, cg_type(ctx, v.type).type, value, min, max)
				case .Uint:
					id = spv_glsl.OpUClamp(builder, cg_type(ctx, v.type).type, value, min, max)
				}
				return { id = id, }
			case .Lerp:
				x := cg_expr(ctx, builder, v.args[0].value)
				y := cg_expr(ctx, builder, v.args[1].value)
				a := cg_expr(ctx, builder, v.args[2].value)
				return { id = spv_glsl.OpFMix(builder, ti.type, x.id, y.id, cg_cast(ctx, builder, a, v.type)), }
			case .Smooth_Step:
				x := cg_expr(ctx, builder, v.args[0].value)
				y := cg_expr(ctx, builder, v.args[1].value)
				a := cg_expr(ctx, builder, v.args[2].value)
				return { id = spv_glsl.OpSmoothStep(builder, ti.type, x.id, y.id, a.id), }
			case .Determinant:
				return { id = spv_glsl.OpDeterminant  (builder, cg_type(ctx, v.type).type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Inverse:
				return { id = spv_glsl.OpMatrixInverse(builder, cg_type(ctx, v.type).type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Transpose:
				return { id = spv.OpTranspose         (builder, cg_type(ctx, v.type).type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Ddx:
				return { id = spv.OpDPdx(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Ddy:
				return { id = spv.OpDPdy(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Discard:
				spv.OpKill(builder)
				return { discard = true, }
			case .Texture_Size:
				ctx.capabilities[.ImageQuery] = {}
				sampler := cg_expr(ctx, builder, v.args[0].value)
				image   := spv.OpImage(builder, cg_type(ctx, sampler.type).image_type, sampler.id)
				lod: spv.Id
				if len(v.args) == 1 {
					lod = cg_constant(ctx, i64(0), nil).id
				} else {
					lod = cg_expr(ctx, builder, v.args[1].value).id
				}
				return { id = spv.OpImageQuerySizeLod(builder, cg_type(ctx, v.type).type, image, lod), }
			case .Image_Size:
				ctx.capabilities[.ImageQuery] = {}
				image := cg_expr(ctx, builder, v.args[0].value).id
				if len(v.args) == 1 {
					return { id = spv.OpImageQuerySize(builder, cg_type(ctx, v.type).type, image), }
				} else {
					lod := cg_expr(ctx, builder, v.args[1].value).id
					return { id = spv.OpImageQuerySizeLod(builder, cg_type(ctx, v.type).type, image, lod), }
				}
			case .Bit_Count:
				return { id = spv.OpBitCount(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Bit_Reverse:
				return { id = spv.OpBitReverse(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Real, .Imag, .Jmag, .Kmag:
				coord := u32(v.builtin - .Real)
				return { id = spv.OpCompositeExtract(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id, coord), }
			}

			unreachable()
		}

		if v.is_cast {
			return { id = cg_cast(ctx, builder, cg_expr(ctx, builder, v.args[0].value), v.type), }
		}

		fn        := cg_expr(ctx, builder, v.lhs)
		args      := make([]spv.Id, len(v.args))
		proc_type := v.lhs.type.variant.(^types.Proc)
		for &arg, i in args {
			arg = cg_cast(ctx, builder, cg_expr(ctx, builder, v.args[i].value), proc_type.args[i].type)
		}

		return_type_info := cg_type(ctx, proc_type.return_type)
		ret              := spv.OpFunctionCall(builder, return_type_info.type, fn.id, ..args)

		if len(proc_type.returns) == 1 {
			type_info := cg_type(ctx, proc_type.returns[0].type)
			copy      := spv.OpVariable(&ctx.functions, cg_type_ptr(ctx, return_type_info, .Function), .Function)
			spv.OpStore(builder, copy, ret)
			ptr       := spv.OpAccessChain(builder, cg_type_ptr(ctx, type_info, .Function), copy, cg_constant(ctx, i64(0), nil).id)
			return { id = spv.OpLoad(builder, type_info.type, ptr), }
		}
		return { id = ret, }
	case ^ast.Expr_Compound:
		if len(v.fields) == 0 {
			return { id = cg_nil_value(ctx, cg_type(ctx, v.type)), }
		}

		if v.named {
			type   := v.type.variant.(^types.Struct)
			values := make([]spv.Id, len(type.fields), context.temp_allocator)
			for field in v.fields {
				find_struct_field_index :: proc(type: ^types.Struct, name: string) -> int {
					for field, i in type.fields {
						if field.name.text == name {
							return i
						}
					}
					return -1
				}

				index        := find_struct_field_index(type, field.ident.text)
				value        := cg_expr(ctx, builder, field.value)
				values[index] = cg_cast(ctx, builder, value, type.fields[index].type)
			}

			for field, i in type.fields {
				if values[i] != 0 {
					continue
				}
				values[i] = cg_nil_value(ctx, cg_type(ctx, field.type))
			}
			return { id = spv.OpCompositeConstruct(builder, cg_type(ctx, v.type).type, ..values), }
		} else {
			values := make([dynamic]spv.Id, len(v.fields), context.temp_allocator)
			i := 0
			for field in v.fields {
				type: ^types.Type
				#partial switch v.type.kind {
				case .Vector:
					type = types.vector_elem(v.type)
				case .Matrix:
					type = types.matrix_elem(v.type)
				case .Struct:
					type = v.type.variant.(^types.Struct).fields[i].type
				}
				value := cg_expr(ctx, builder, field.value)
				if types.is_tuple(value.type) {
					t := value.type.variant.(^types.Struct)
					for field_type in t.fields {
						field_value := Value {
							id   = value.id, // totally wrong!!! only works for tuples with one value
							type = field_type.type,
						}
						if types.is_vector(field_type.type) && types.is_vector(v.type) {
							values[i] = cg_deref(ctx, builder, field_value)
						} else {
							// TODO: wrong for struct fields, the checker does not let that through anyway, it should tho
							values[i] = cg_cast(ctx, builder, field_value, type)
						}
						i += 1
					}
					continue
				}
				if types.is_vector(value.type) && types.is_vector(v.type) {
					values[i] = cg_deref(ctx, builder, value)
				} else {
					values[i] = cg_cast(ctx, builder, value, type)
				}
				i += 1
			}
			return { id = spv.OpCompositeConstruct(builder, cg_type(ctx, v.type).type, ..values[:]), }
		}
	case ^ast.Expr_Index:
		lhs := cg_expr(ctx, builder, v.lhs, false)
		rhs := cg_expr(ctx, builder, v.rhs)

		if types.is_vector(lhs.type) && len(lhs.swizzle) != 0 {
			lhs.id            = cg_deref(ctx, builder, lhs)
			lhs.storage_class = {}
			lhs.swizzle       = {}
		}

		if types.is_sampler(lhs.type) {
			sampler    := lhs.type.variant.(^types.Image)
			count      := 1
			texel_type := sampler.texel_type
			if v, ok := sampler.texel_type.variant.(^types.Vector); ok {
				count = v.count
				if v.count != 4 {
					texel_type = types.vector_new(v.elem, 4, context.temp_allocator)
				}
			} else {
				texel_type = types.vector_new(sampler.texel_type, 4, context.temp_allocator)
			}

			image := cg_deref(ctx, builder, lhs)
			texel := spv.OpImageSampleExplicitLod(builder, cg_type(ctx, texel_type).type, image, rhs.id, { .Lod, }, u32(cg_constant(ctx, f64(0), nil).id))
			
			switch count {
			case 1:
				return { id = spv.OpCompositeExtract(builder, cg_type(ctx, v.type).type, texel, 0), }
			case 2:
				indices := [2]u32{ 0, 1, }
				return { id = spv.OpVectorShuffle(builder, cg_type(ctx, v.type).type, texel, texel, ..indices[:]), }
			case 3:
				indices := [3]u32{ 0, 1, 2, }
				return { id = spv.OpVectorShuffle(builder, cg_type(ctx, v.type).type, texel, texel, ..indices[:]), }
			case 4:
				return { id = texel, }
			}
		}

		if types.is_image(lhs.type) {
			sampler    := lhs.type.variant.(^types.Image)
			count      := 1
			texel_type := sampler.texel_type
			if v, ok := sampler.texel_type.variant.(^types.Vector); ok {
				count = v.count
				if v.count != 4 {
					texel_type = types.vector_new(v.elem, 4, context.temp_allocator)
				}
			} else {
				texel_type = types.vector_new(sampler.texel_type, 4, context.temp_allocator)
			}

			return {
				storage_class = .Image,
				id            = cg_deref(ctx, builder, lhs),
				coord         = rhs.id,
			}
		}

		if types.is_buffer(lhs.type) {
			buffer := lhs.type.variant.(^types.Buffer)
			elem   := cg_type(ctx, buffer.elem, { .Explicit_Layout, })

			if buffer.physical {
				ctx.capabilities[.VariablePointersStorageBuffer] = {}
				lhs := cg_deref(ctx, builder, lhs)
				id  := spv.OpPtrAccessChain(
					builder,
					cg_type_ptr(ctx, elem, .Physical_Storage_Buffer),
					lhs,
					rhs.id,
				)
				return {
					id              = id,
					storage_class   = .Physical_Storage_Buffer,
					type            = buffer.elem,
					explicit_layout = true,
				}
			}
			id := spv.OpAccessChain(builder, cg_type_ptr(ctx, elem, .Storage_Buffer), lhs.id, cg_constant(ctx, i64(0), nil).id, rhs.id)
			return {
				id              = id,
				storage_class   = .Storage_Buffer,
				type            = buffer.elem,
				explicit_layout = true,
			}
		}

		if lhs.storage_class != nil {
			return {
				id              = spv.OpAccessChain(builder, cg_type_ptr(ctx, v.type, lhs.storage_class), lhs.id, rhs.id),
				storage_class   = lhs.storage_class,
				explicit_layout = lhs.explicit_layout,
			}
		}

		return { id = spv.OpVectorExtractDynamic(builder, cg_type(ctx, v.type).type, lhs.id, rhs.id), }
	case ^ast.Expr_Cast:
		return { id = cg_cast(ctx, builder, cg_expr(ctx, builder, v.value), v.type), }
	case ^ast.Expr_Unary:
		e    := cg_expr(ctx, builder, v.expr)
		type := types.base_type(expr.type)
		ti   := cg_type(ctx, type)
		#partial switch v.op {
		case .Xor:
			return { id = spv.OpNot(builder, ti.type, e.id), }
		case .Subtract:
			#partial switch type.kind {
			case .Matrix:
				#partial switch types.matrix_elem(type).kind {
				case .Int, .Uint:
					return { id = spv.OpISub(builder, ti.type, cg_nil_value(ctx, ti), e.id), }
				case .Float:
					return { id = spv.OpFSub(builder, ti.type, cg_nil_value(ctx, ti), e.id), }
				}
			case .Vector:
				#partial switch types.vector_elem(type).kind {
				case .Int, .Uint:
					return { id = spv.OpISub(builder, ti.type, cg_nil_value(ctx, ti), e.id), }
				case .Float:
					return { id = spv.OpFSub(builder, ti.type, cg_nil_value(ctx, ti), e.id), }
				}
			case .Int, .Uint:
				return { id = spv.OpISub(builder, ti.type, cg_nil_value(ctx, ti), e.id), }
			case .Float:
				return { id = spv.OpFSub(builder, ti.type, cg_nil_value(ctx, ti), e.id), }
			}
		case .Add:
			return e
		}
	case ^ast.Expr_Ternary:
		cond       := cg_expr(ctx, builder, v.cond).id
		then_value := cg_expr(ctx, builder, v.then_expr).id
		else_value := cg_expr(ctx, builder, v.else_expr).id
		return { id = spv.OpSelect(builder, cg_type(ctx, v.type).type, cond, then_value, else_value), }
	case ^ast.Type_Struct, ^ast.Type_Array, ^ast.Type_Matrix, ^ast.Type_Import, ^ast.Type_Image, ^ast.Type_Enum, ^ast.Type_Bit_Set:
		panic("tried to cg type as expression")
	case ^ast.Expr_Config:
		panic("tried to cg config var as expression")
	}

	fmt.panicf("unimplemented: %v", reflect.union_variant_typeid(expr.derived_expr))
}

cg_lookup_proc_scope :: proc(ctx: ^Context) -> ^Scope {
	#reverse for &scope in ctx.scopes {
		if scope.return_type != nil {
			return &scope
		}
	}
	panic("")
}

cg_lookup_return_value :: proc(ctx: ^Context) -> spv.Id {
	return cg_lookup_proc_scope(ctx).return_value
}

cg_lookup_return_type :: proc(ctx: ^Context) -> ^types.Type {
	return cg_lookup_proc_scope(ctx).return_type
}

cg_lookup_label :: proc(ctx: ^Context, label: string) -> ^Scope {
	#reverse for &scope in ctx.scopes {
		if scope.label == label {
			return &scope
		}
	}
	panic("")
}

stmt_requires_line_info :: proc(stmt: ^ast.Stmt) -> bool {
	#partial switch v in stmt.derived_stmt {
	case ^ast.Decl_Value:
		return v.mutable
	case ^ast.Stmt_When:
		return false
	case ^ast.Stmt_Block:
		return false
	}
	return true
}

cg_stmt :: proc(ctx: ^Context, builder: ^spv.Builder, stmt: ^ast.Stmt, global := false) -> (diverged: bool) {
	if stmt == nil {
		return
	}

	if ctx.debug_file != 0 {
		if !global && stmt_requires_line_info(stmt) {
			spv.OpLine(builder, ctx.debug_file, u32(stmt.start.line), 0)
		}
	}

	switch v in stmt.derived_stmt {
	case ^ast.Stmt_Return:
		if len(v.values) == 0 {
			proc_scope  := cg_lookup_proc_scope(ctx)
			return_type := cg_type(ctx, proc_scope.return_type)
			if proc_scope.return_value != 0 {
				spv.OpReturnValue(builder, spv.OpLoad(builder, return_type.type, proc_scope.return_value))
			} else {
				spv.OpReturn(builder)
			}
			return true
		}

		proc_scope   := cg_lookup_proc_scope(ctx)
		return_value := proc_scope.return_value
		type         := proc_scope.return_type.variant.(^types.Struct)

		if return_value == 0 {
			for value, i in v.values {
				v   := cg_expr(ctx, builder, value)
				ptr := proc_scope.outputs[i]
				spv.OpStore(builder, ptr, v.id)
			}
			spv.OpReturn(builder)
		} else {
			return_ti := cg_type(ctx, type)
			for value, i in v.values {
				v   := cg_expr(ctx, builder, value)
				ptr := spv.OpAccessChain(builder, cg_type_ptr(ctx, type.fields[i].type, .Function), return_value, cg_constant(ctx, i64(i), nil).id)
				spv.OpStore(builder, ptr, cg_cast(ctx, builder, v, type.fields[i].type))
			}
			spv.OpReturnValue(builder, spv.OpLoad(builder, return_ti.type, return_value))
		}

		return true
	case ^ast.Stmt_Break:
		target: spv.Id
		if len(v.label.text) != 0 {
			target = find_scope_by_label(ctx, v.label.text).end_id
		} else {
			target = find_scope_by_kind(ctx, { .Loop, .Switch, }).end_id
		}
		spv.OpBranch(builder, target)
		return true
	case ^ast.Stmt_Continue:
		target: spv.Id
		if len(v.label.text) != 0 {
			target = find_scope_by_label(ctx, v.label.text).continue_id
		} else {
			target = find_scope_by_kind(ctx, { .Loop, }).continue_id
		}
		spv.OpBranch(builder, target)
		return true
	case ^ast.Stmt_For_Range:
		scope_push(ctx, v.label.text)
		defer scope_pop(ctx)

		iter_type := v.variable.type
		iter_ti   := cg_type(ctx, v.variable.type)
		iter_var  := spv.OpVariable(&ctx.functions, cg_type_ptr(ctx, iter_ti, .Function), .Function)
		iter_init := cg_expr(ctx, builder, v.start_expr).id
		spv.OpStore(builder, iter_var, iter_init)

		cg_insert_entity(ctx, v.variable.derived_expr.(^ast.Expr_Ident).ident.text, .Function, v.variable.type, iter_var)

		body_builder   := &spv.Builder{ current_id = &ctx.current_id, }
		header_builder := &spv.Builder{ current_id = &ctx.current_id, }
		end_builder    := &spv.Builder{ current_id = &ctx.current_id, }
		post_builder   := &spv.Builder{ current_id = &ctx.current_id, }

		spv.OpBranch(builder, ctx.current_id + 1)
		jump_back_target := spv.OpLabel(builder)

		header := spv.OpLabel(header_builder)
		spv.OpName(&ctx.debug_b, header, "header")
		end    := spv.OpLabel(end_builder)
		spv.OpName(&ctx.debug_b, end, "end")

		iter_value := spv.OpLoad(header_builder, iter_ti.type, iter_var)
		end_value  := cg_expr(ctx, header_builder, v.end_expr).id

		condition: spv.Id
		#partial switch iter_type.kind {
		case .Uint:
			if v.inclusive {
				condition = spv.OpULessThanEqual(header_builder, cg_type(ctx, types.t_bool).type, iter_value, end_value)
			} else {
				condition = spv.OpULessThan     (header_builder, cg_type(ctx, types.t_bool).type, iter_value, end_value)
			}
		case .Int:
			if v.inclusive {
				condition = spv.OpSLessThanEqual(header_builder, cg_type(ctx, types.t_bool).type, iter_value, end_value)
			} else {
				condition = spv.OpSLessThan     (header_builder, cg_type(ctx, types.t_bool).type, iter_value, end_value)
			}
		case .Float:
			if v.inclusive {
				condition = spv.OpFOrdLessThanEqual(header_builder, cg_type(ctx, types.t_bool).type, iter_value, end_value)
			} else {
				condition = spv.OpFOrdLessThan     (header_builder, cg_type(ctx, types.t_bool).type, iter_value, end_value)
			}
		}
		assert(condition != 0)

		post_label := spv.OpLabel(post_builder)
		#partial switch iter_type.kind {
		case .Uint, .Int:
			one       := cg_constant(ctx, i64(1), iter_type)
			new_value := spv.OpIAdd(post_builder, iter_ti.type, iter_value, one.id)
			spv.OpStore(post_builder, iter_var, new_value)
		case .Float:
			one       := cg_constant(ctx, f64(1), iter_type)
			new_value := spv.OpFAdd(post_builder, iter_ti.type, iter_value, one.id)
			spv.OpStore(post_builder, iter_var, new_value)
		}
		spv.OpBranch(post_builder, jump_back_target)

		body, _ := cg_scope(ctx, body_builder, v.body, end = post_label, kind = .Loop)

		spv.OpLoopMerge(builder, end, post_label, {})
		spv.OpBranch(builder, header)
		spv.OpBranchConditional(header_builder, condition, body, end)

		append(&builder.data, ..header_builder.data[:])
		append(&builder.data, ..body_builder.data[:])
		append(&builder.data, ..post_builder.data[:])
		append(&builder.data, ..end_builder.data[:])

	case ^ast.Stmt_For:
		scope_push(ctx, v.label.text, .Loop)
		defer scope_pop(ctx)

		cg_stmt(ctx, builder, v.init)

		body_builder   := &spv.Builder{ current_id = &ctx.current_id, }
		header_builder := &spv.Builder{ current_id = &ctx.current_id, }
		end_builder    := &spv.Builder{ current_id = &ctx.current_id, }
		post_builder   := &spv.Builder{ current_id = &ctx.current_id, }

		spv.OpBranch(builder, ctx.current_id + 1)
		jump_back_target := spv.OpLabel(builder)

		header := spv.OpLabel(header_builder)
		spv.OpName(&ctx.debug_b, header, "header")
		end    := spv.OpLabel(end_builder)
		spv.OpName(&ctx.debug_b, end, "end")

		post_label := spv.OpLabel(post_builder)
		cg_stmt(ctx, post_builder, v.post)
		spv.OpBranch(post_builder, jump_back_target)

		body, _ := cg_scope(ctx, body_builder, v.body, end = post_label)

		condition: spv.Id
		if v.cond != nil {
			condition = cg_expr(ctx, header_builder, v.cond).id
		} else {
			condition = cg_constant(ctx, true, nil).id
		}

		spv.OpLoopMerge(builder, end, post_label, {})
		spv.OpBranch(builder, header)
		spv.OpBranchConditional(header_builder, condition, body, end)

		append(&builder.data, ..header_builder.data[:])
		append(&builder.data, ..body_builder.data[:])
		append(&builder.data, ..post_builder.data[:])
		append(&builder.data, ..end_builder.data[:])

	case ^ast.Stmt_Block:
		block_builder := spv.Builder{ current_id = &ctx.current_id, }
		end_builder   := spv.Builder{ current_id = &ctx.current_id, }

		end := spv.OpLabel(&end_builder)
		spv.OpName(&ctx.debug_b, end, "$BLOCK_END")

		label: spv.Id
		label, diverged = cg_scope(ctx, &block_builder, v.body, end = end, label = v.label.text)

		spv.OpName(&ctx.debug_b, label, v.label.text)
		spv.OpBranch(builder, label)

		append(&builder.data, ..block_builder.data[:])
		append(&builder.data, ..end_builder.data[:])

	case ^ast.Stmt_If:
		scope_push(ctx, v.label.text)
		defer scope_pop(ctx)

		cg_stmt(ctx, builder, v.init)
		cond := cg_expr(ctx, builder, v.cond)

		then_block := &spv.Builder{ current_id = &ctx.current_id, }
		else_block := &spv.Builder{ current_id = &ctx.current_id, }
		end_block  := &spv.Builder{ current_id = &ctx.current_id, }

		end_label := spv.OpLabel(end_block)

		then_label, _ := cg_scope(ctx, then_block, v.then_block, end = end_label)
		else_label, _ := cg_scope(ctx, else_block, v.else_block, end = end_label)
		spv.OpName(&ctx.debug_b, then_label, "$THEN")
		spv.OpName(&ctx.debug_b, else_label, "$ELSE")
		spv.OpName(&ctx.debug_b, end_label,  "$ENDIF")

		spv.OpSelectionMerge(builder, end_label, {})
		spv.OpBranchConditional(builder, cond.id, then_label, else_label)

		append(&builder.data, ..then_block.data[:])
		append(&builder.data, ..else_block.data[:])
		append(&builder.data, ..end_block.data[:])
	case ^ast.Stmt_When:
		if v.cond.const_value.(bool) {
			return cg_stmt_list(ctx, builder, v.then_block, global = global)
		} else {
			return cg_stmt_list(ctx, builder, v.else_block, global = global)
		}
	case ^ast.Stmt_Switch:
		scope_push(ctx, v.label.text)
		defer scope_pop(ctx)

		cg_stmt(ctx, builder, v.init)
		cond := cg_expr(ctx, builder, v.cond)
		assert(v.constant_cases)

		body_block := &spv.Builder{ current_id = &ctx.current_id, }
		end_block  := &spv.Builder{ current_id = &ctx.current_id, }
		end_label  := spv.OpLabel(end_block)
		spv.OpSelectionMerge(builder, end_label, {})

		default := end_label

		if v.cond.type.size == 8 {
			targets := make([dynamic]spv.Pair(u64, spv.Id), 0, len(v.cases))
			for c in v.cases {
				if c.value == nil {
					default, _ = cg_scope(ctx, body_block, c.body, end_label, kind = .Switch)
					continue
				}
				scope, _ := cg_scope(ctx, body_block, c.body, end_label, kind = .Switch)
				append(&targets, spv.Pair(u64, spv.Id) {
					a = u64(c.value.const_value.(i64)),
					b = scope,
				})
			}
			spv.OpSwitch(builder, cond.id, default, ..targets[:])
		} else {
			targets := make([dynamic]spv.Pair(u32, spv.Id), 0, len(v.cases))
			for c in v.cases {
				if c.value == nil {
					default, _ = cg_scope(ctx, body_block, c.body, end_label, kind = .Switch)
					continue
				}
				scope, _ := cg_scope(ctx, body_block, c.body, end_label, kind = .Switch)
				append(&targets, spv.Pair(u32, spv.Id) {
					a = u32(c.value.const_value.(i64)),
					b = scope,
				})
			}
			spv.OpSwitch(builder, cond.id, default, ..targets[:])
		}

		append(&builder.data, ..body_block.data[:])
		append(&builder.data, ..end_block.data[:])

	case ^ast.Stmt_Assign:
		lhs_i := 0
		for value in v.rhs {
			values := []Value{ cg_expr(ctx, builder, value), }
			deconstruct_tuple: if value.type.kind == .Tuple {
				type := value.type.variant.(^types.Struct)
				v    := values[0]

				if len(type.fields) == 1 {
					values[0] = {
						type = type.fields[0].type,
						id   = v.id,
					}
					break deconstruct_tuple
				}

				values = make([]Value, len(type.fields), context.temp_allocator)
				for &val, i in values {
					ti := cg_type(ctx, type.fields[i].type)
					val = {
						type = type.fields[i].type,
						id   = spv.OpCompositeExtract(builder, ti.type, v.id, u32(i)),
					}
				}
			}
			for rhs in values {
				lhs := cg_expr(ctx, builder, v.lhs[lhs_i], deref = false)
				if lhs.explicit_layout {
					type := lhs.type.variant.(^types.Struct)
					// TODO: handle members that are structs
					for f, i in type.fields {
						assert(f.type.kind != .Struct)
						field_ti  := cg_type(ctx, f.type, { .Explicit_Layout, })
						val       := spv.OpCompositeExtract(builder, field_ti.type, rhs.id, u32(i))
						field_ptr := spv.OpAccessChain(builder, cg_type_ptr(ctx, field_ti, lhs.storage_class), lhs.id, cg_constant(ctx, i64(i), nil).id)
						if lhs.storage_class == .Physical_Storage_Buffer {
							spv.OpStore(builder, field_ptr, val, spv.MemoryAccess{ .Aligned, }, u32(f.type.align))
						} else {
							spv.OpStore(builder, field_ptr, val)
						}
					}
					continue
				}

				if len(lhs.swizzle) != 0 {
					type := cg_type(ctx, lhs.real_type)
					elem := cg_type(ctx, types.vector_elem(lhs.real_type))

					lhs_ptr       := lhs.id
					storage_class := lhs.storage_class
					if lhs.storage_class == .Image {
						lhs_ptr  = spv.OpVariable(&ctx.functions, cg_type_ptr(ctx, type, .Function), .Function)
						read    := spv.OpImageRead(builder, type.type, lhs.id, lhs.coord)
						spv.OpStore(builder, lhs_ptr, read)
						spv.OpName(&ctx.debug_b, lhs_ptr, "__tmp_image_texel")

						storage_class = .Function
					}

					elem_ptr := cg_type_ptr(ctx, elem, storage_class)
					if len(lhs.swizzle) == 1 {
						ptr := spv.OpAccessChain(builder, elem_ptr, lhs_ptr, cg_constant(ctx, i64(lhs.swizzle[0]), nil).id)
						spv.OpStore(builder, ptr, rhs.id)
					} else {
						for dst_component, src_component in lhs.swizzle {
							value := spv.OpCompositeExtract(builder, elem.type, rhs.id, u32(src_component))
							ptr   := spv.OpAccessChain(builder, elem_ptr, lhs_ptr, cg_constant(ctx, i64(dst_component), nil).id)
							spv.OpStore(builder, ptr, value)
						}
					}

					if lhs.storage_class == .Image {
						ctx.capabilities[.StorageImageWriteWithoutFormat] = {}
						spv.OpImageWrite(builder, lhs.id, lhs.coord, spv.OpLoad(builder, type.type, lhs_ptr))
					}

					continue
				}

				if lhs.storage_class == .Image {
					ctx.capabilities[.StorageImageWriteWithoutFormat] = {}
					spv.OpImageWrite(builder, lhs.id, lhs.coord, rhs.id)
					continue
				}

				if v.op == nil {
					if lhs.storage_class == .Physical_Storage_Buffer {
						spv.OpStore(builder, lhs.id, cg_cast(ctx, builder, rhs, lhs.type), spv.MemoryAccess{ .Aligned, }, u32(lhs.type.align))
					} else {
						spv.OpStore(builder, lhs.id, cg_cast(ctx, builder, rhs, lhs.type))
					}
					continue
				}

				t: ^types.Type
				value := cg_expr_binary(
					ctx,
					builder,
					v.op,
					{ id = cg_deref(ctx, builder, lhs), type = lhs.type, },
					rhs,
					&t,
				)
				if lhs.storage_class == .Physical_Storage_Buffer {
					spv.OpStore(builder, lhs.id, value, spv.MemoryAccess{ .Aligned, }, u32(lhs.type.align))
				} else {
					spv.OpStore(builder, lhs.id, value)
				}
				lhs_i += 1
			}
		}
	case ^ast.Stmt_Expr:
		e := cg_expr(ctx, builder, v.expr)
		if e.discard {
			return true
		}

	case ^ast.Decl_Value:
		cg_decl(ctx, builder, v, global)
	}

	return
}

cg_stmt_list :: proc(ctx: ^Context, builder: ^spv.Builder, stmts: []^ast.Stmt, global := false) -> (returned: bool) {
	for stmt in stmts {
		if cg_stmt(ctx, builder, stmt, global) {
			returned = true
		}
	}
	if global {
		for p in ctx.procs {
			cg_proc_internal(ctx, p.expr, p.id, p.link_name)
		}
		clear(&ctx.procs)
	}
	return returned
}

get_runtime_proc :: proc(ctx: ^Context, runtime_proc: Runtime_Proc) -> spv.Id {
	assert(runtime_proc != nil)

	if ctx.runtime_procs[runtime_proc] == 0 {
		ctx.current_id                 += 1
		ctx.runtime_procs[runtime_proc] = ctx.current_id
	}

	return ctx.runtime_procs[runtime_proc]
}
