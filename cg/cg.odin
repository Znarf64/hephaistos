package hephaistos_cg

import "base:runtime"

import "core:fmt"
import "core:reflect"
import "core:slice"
import "core:strings"

import "../ast"
import "../types"
import "../tokenizer"
import "../checker"

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
	Workgroup,
	Uniform_Constant,
	Storage_Buffer,
	Physical_Storage_Buffer,
	Ray_Payload,
	Incoming_Ray_Payload,
	Hit_Attribute,
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
	types, annotations: string, // really []u32, but strings can be hashed and compared
}

get_type_cache_key :: proc(type: ^types.Type, flags: Type_Flags) -> (key: Type_Cache_Key) {
	#partial switch type.kind {
	case .Invalid:
		unreachable()
	case .Uint, .Int, .Bool, .Float:
		return { variant = Type_Cache_Key_Basic{ size = type.size, kind = type.kind, }, }
	case .Array:
		elem := types.array_elem(type)
		#partial switch elem.kind {
		case .Uint, .Int, .Bool, .Float:
			return { variant = Type_Cache_Key_Array{ size = type.size, elem_kind = elem.kind, }, }
		}
	}

	return {
		variant = type,
		flags   = flags,
	}
}

Type_Cache_Key_Basic :: struct {
	size: int,
	kind: types.Kind,
}

Type_Cache_Key_Array :: struct {
	size:      int, // elem_size * count
	elem_kind: types.Kind,
}

Type_Cache_Key :: struct {
	variant: union {
		Type_Cache_Key_Basic,
		Type_Cache_Key_Array,
		^types.Type,
	},
	flags: Type_Flags,
}

Type_Registry :: struct {
	cache:    map[Type_Cache_Key]^Type_Info,
	registry: map[Type_Key]^Type_Info,
}

Image_Type :: struct {
	dimensions: int,
	sampled:    bool,
	format:     string,
	texel_type: struct {
		size: int,
		kind: types.Kind,
	},
}

Proc_Lit_Info :: struct {
	expr:      ^ast.Expr_Proc_Lit,
	id:        spv.Id,
	link_name: string,
}

Constant_Key :: struct {
	value: types.Const_Value,
	type:  spv.Id,
}

Constant_Cache :: map[Constant_Key]spv.Id

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
	constant_cache:      Constant_Cache,
	string_cache:        map[string]spv.Id,
	type_registry:       Type_Registry,
	type_void:           spv.Id,
	type_void_proc:      spv.Id,

	runtime_procs:       [Runtime_Proc]spv.Id,

	meta:                spv.Builder,
	ext_inst:            spv.Builder,
	memory_model:        spv.Builder,
	entry_points:        spv.Builder,
	execution_modes:     spv.Builder,
	debug_a:             spv.Builder,
	debug_b:             spv.Builder,
	annotations:         spv.Builder,
	types:               spv.Builder,
	globals:             spv.Builder,
	functions:           spv.Builder,

	current_id:          spv.Id,
	checker:             ^checker.Checker,
	scopes:              [dynamic]Scope,
	libraries:           map[string]Library,
	name_prefix:         string,

	extensions:          map[string]struct{},
	capabilities:        map[spv.Capability]struct{},
	referenced_globals:  map[spv.Id]struct{},
	interface_variables: map[spv.BuiltIn]Value,

	procs:               [dynamic]Proc_Lit_Info,

	link_name:           string,
	shader_stage:        ast.Shader_Stage,
	debug_file:          spv.Id,

	local_size:          [3]i32,

	spirv_version:       u32,
}

Value :: struct {
	id:              spv.Id,
	storage_class:   Storage_Class,
	type:            ^types.Type,
	real_type:       ^types.Type, // non swizzled type
	swizzle:         []u32,
	group_members:   []spv.Id,
	explicit_layout: bool,
	discard:         bool,
	coord:           spv.Id, // texel reference for ImageStore
}

Scope_Kind :: enum {
	Block,
	Loop,
	Switch,
}

Library :: struct {
	entities: map[string]Value,
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

cg_lookup_entity :: proc(ctx: ^Context, name: string, library: string = "") -> Value {
	if library != "" {
		return ctx.libraries[library].entities[name] or_else panic("cg_lookup_entity failed (library)")
	}
	#reverse for scope in ctx.scopes {
		return scope.entities[name] or_continue
	}
	panic("cg_lookup_entity failed")
}

cg_insert_entity :: proc(ctx: ^Context, name: string, storage_class: Storage_Class, type: ^types.Type, id: spv.Id) {
	cg_insert_entity_value(ctx, name, {
		type          = type,
		id            = id,
		storage_class = storage_class,
	})
}

cg_insert_entity_value :: proc(ctx: ^Context, name: string, value: Value) {
	if value.id != 0 {
		spv.OpName(&ctx.debug_b, value.id, strings.concatenate({ ctx.name_prefix, name, }))
	}
	ctx.scopes[len(ctx.scopes) - 1].entities[name] = value
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

cg_string :: proc(ctx: ^Context, str: string) -> spv.Id {
	if id, ok := ctx.string_cache[str]; ok {
		return id
	}
	id := spv.OpString(&ctx.debug_a, str)
	ctx.string_cache[str] = id
	return id
}

cg_value_decl :: proc(ctx: ^Context, builder: ^spv.Builder, decl: ^ast.Decl_Value, global: bool) {
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

	v, ok := decl.derived_decl.(^ast.Decl_Value)
	if !ok {
		return
	}

	switch v.interface {
	case .None:
	case .Uniform, .Uniform_Buffer:
		value_builder     = nil
		decl_builder      = &ctx.globals
		storage_class     = .Uniform
		spv_storage_class = .Uniform
		flags             = { .Block, .Explicit_Layout, }
		has_nil_value     = false
		annotate          = true
	case .Push_Constant:
		value_builder     = nil
		decl_builder      = &ctx.globals
		storage_class     = .Push_Constant
		spv_storage_class = .PushConstant
		flags             = { .Block, .Explicit_Layout, }
		has_nil_value     = false
	case .Storage_Buffer:
		ctx.extensions["SPV_KHR_storage_buffer_storage_class"] = {}

		value_builder     = nil
		decl_builder      = &ctx.globals
		storage_class     = .Storage_Buffer
		spv_storage_class = .StorageBuffer
		flags             = { .Block, .Explicit_Layout, }
		has_nil_value     = false
		annotate          = true
	case .Shared:
		value_builder     = nil
		decl_builder      = &ctx.globals
		has_nil_value     = false
		storage_class     = .Workgroup
		spv_storage_class = .Workgroup
	case .Ray_Payload:
		value_builder     = nil
		decl_builder      = &ctx.globals
		storage_class     = .Ray_Payload
		spv_storage_class = .RayPayloadKHR
		has_nil_value     = false
	case .Hit_Attribute:
		value_builder     = nil
		decl_builder      = &ctx.globals
		storage_class     = .Hit_Attribute
		spv_storage_class = .HitAttributeKHR
		has_nil_value     = false
	case .Incoming_Ray_Payload:
		value_builder     = nil
		decl_builder      = &ctx.globals
		storage_class     = .Incoming_Ray_Payload
		spv_storage_class = .IncomingRayPayloadKHR
		has_nil_value     = false
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

				if types.is_opaque(type) && types.opaque_kind(type) == .Acceleration_Structure {
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
			if global {
				for value, i in v.values {
					type      := v.types[i]
					type_info := cg_type(ctx, type, flags)
					init      := cg_expr(ctx, nil, value).id
					id        := spv.OpVariable(decl_builder, cg_type_ptr(ctx, type_info, storage_class), spv_storage_class, init)
					name      := v.lhs[i].derived_expr.(^ast.Expr_Ident).ident.text
					cg_insert_entity(ctx, name, storage_class, type, id)
				}
			} else {
				lhs_i: int
				for value in v.values {
					init := cg_expr(ctx, value_builder, value)
					values: []Value = { init, }
					deconstruct_tuple(ctx, value_builder, value.type, &values)

					for value in values {
						type_info := cg_type(ctx, value.type, flags)
						ptr       := spv.OpVariable(decl_builder, cg_type_ptr(ctx, type_info, storage_class), spv_storage_class)
						spv.OpStore(value_builder, ptr, value.id)

						name := v.lhs[lhs_i].derived_expr.(^ast.Expr_Ident).ident.text
						cg_insert_entity(ctx, name, storage_class, value.type, ptr)

						lhs_i += 1
					}
				}
			}
		}
	} else {
		for value, i in v.values {
			name := v.lhs[i].derived_expr.(^ast.Expr_Ident).ident.text

			#partial switch value.type.kind {
			case .Proc:
				prev_link_name := ctx.link_name
				if v.link_name == "" {
					ctx.link_name = name
				}
				defer if v.link_name == "" {
					ctx.link_name = prev_link_name
				}

				val := cg_expr(ctx, nil, value)
				cg_insert_entity_value(ctx, name, val)
			case .Proc_Group:
				val := cg_expr(ctx, nil, value)
				cg_insert_entity_value(ctx, name, val)
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

	for name, lib in checker.libraries {
		scope := scope_push(&ctx, kind = .Block)
		defer scope_pop(&ctx)

		ctx.name_prefix = strings.concatenate({ name, "::", })

		for _, e in lib.entities {
			cg_stmt(&ctx, &b, e.decl, true)
		}

		for p in ctx.procs {
			cg_proc_internal(&ctx, p.expr, p.id, strings.concatenate({ ctx.name_prefix, p.link_name, }))
		}
		clear(&ctx.procs)

		ctx.libraries[name] = {
			entities = scope.entities,
		}
	}
	ctx.name_prefix = ""

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
		_ = spv.OpFunction(&ctx.functions, return_type_id, { .Inline, .Pure, .Const, }, cg_type(&ctx, proc_type).type)
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
			elem_type: spv.Id
			if runtime_proc == .Quaternion128_Mul {
				elem_type = cg_type(&ctx, types.t_f32).type
			} else {
				elem_type = cg_type(&ctx, types.t_f64).type
			}

			// q0, q1, q2, q3 := real(q), imag(q), jmag(q), kmag(q)
			// r0, r1, r2, r3 := real(r), imag(r), jmag(r), kmag(r)

			// t0 := r0*q0 - r1*q1 - r2*q2 - r3*q3
			// t1 := r0*q1 + r1*q0 - r2*q3 + r3*q2
			// t2 := r0*q2 + r1*q3 + r2*q0 - r3*q1
			// t3 := r0*q3 - r1*q2 + r2*q1 + r3*q0

			// return quaternion(w=t0, x=t1, y=t2, z=t3)

			q := args[0]
			r := args[0]

			q0 := spv.OpCompositeExtract(&ctx.functions, elem_type, q, 3)
			q1 := spv.OpCompositeExtract(&ctx.functions, elem_type, q, 0)
			q2 := spv.OpCompositeExtract(&ctx.functions, elem_type, q, 1)
			q3 := spv.OpCompositeExtract(&ctx.functions, elem_type, q, 2)

			r0 := spv.OpCompositeExtract(&ctx.functions, elem_type, r, 3)
			r1 := spv.OpCompositeExtract(&ctx.functions, elem_type, r, 0)
			r2 := spv.OpCompositeExtract(&ctx.functions, elem_type, r, 1)
			r3 := spv.OpCompositeExtract(&ctx.functions, elem_type, r, 2)

			r0_q0 := spv.OpFMul(&ctx.functions, elem_type, r0, q0)
			r1_q0 := spv.OpFMul(&ctx.functions, elem_type, r1, q0)
			r2_q0 := spv.OpFMul(&ctx.functions, elem_type, r2, q0)
			r3_q0 := spv.OpFMul(&ctx.functions, elem_type, r3, q0)

			r0_q1 := spv.OpFMul(&ctx.functions, elem_type, r0, q1)
			r1_q1 := spv.OpFMul(&ctx.functions, elem_type, r1, q1)
			r2_q1 := spv.OpFMul(&ctx.functions, elem_type, r2, q1)
			r3_q1 := spv.OpFMul(&ctx.functions, elem_type, r3, q1)

			r0_q2 := spv.OpFMul(&ctx.functions, elem_type, r0, q2)
			r1_q2 := spv.OpFMul(&ctx.functions, elem_type, r1, q2)
			r2_q2 := spv.OpFMul(&ctx.functions, elem_type, r2, q2)
			r3_q2 := spv.OpFMul(&ctx.functions, elem_type, r3, q2)

			r0_q3 := spv.OpFMul(&ctx.functions, elem_type, r0, q3)
			r1_q3 := spv.OpFMul(&ctx.functions, elem_type, r1, q3)
			r2_q3 := spv.OpFMul(&ctx.functions, elem_type, r2, q3)
			r3_q3 := spv.OpFMul(&ctx.functions, elem_type, r3, q3)

			real := spv.OpFSub(&ctx.functions, elem_type, spv.OpFSub(&ctx.functions, elem_type, spv.OpFSub(&ctx.functions, elem_type, r0_q0, r1_q1), r2_q2), r3_q3)
			imag := spv.OpFAdd(&ctx.functions, elem_type, spv.OpFSub(&ctx.functions, elem_type, spv.OpFAdd(&ctx.functions, elem_type, r0_q1, r1_q0), r2_q3), r3_q2)
			jmag := spv.OpFSub(&ctx.functions, elem_type, spv.OpFAdd(&ctx.functions, elem_type, spv.OpFAdd(&ctx.functions, elem_type, r0_q2, r1_q3), r2_q0), r3_q1)
			kmag := spv.OpFAdd(&ctx.functions, elem_type, spv.OpFAdd(&ctx.functions, elem_type, spv.OpFSub(&ctx.functions, elem_type, r0_q3, r1_q2), r2_q1), r3_q0)

			ret := spv.OpCompositeConstruct(&ctx.functions, return_type_id, imag, jmag, kmag, real)
			spv.OpReturnValue(&ctx.functions, ret)

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

		case .Invalid,
		     .Struct,
		     .Sampler,
		     .Image,
		     .Buffer,
		     .Proc,
		     .Proc_Group,
		     .Tuple,
		     .Enum,
		     .Bit_Set,
		     .Complex,
		     .Quaternion,
		     .Opaque:
			fmt.panicf("Tried to generate constant with type", type)

		case .Matrix:
			type = types.matrix_elem(type)
		case .Array:
			type = types.array_elem(type)
		}
	}

	ti := cg_type(ctx, type)

	key := Constant_Key {
		type  = ti.type,
		value = value,
	}
	if cached, ok := ctx.constant_cache[key]; ok {
		return {
			id   = cached,
			type = type,
		}
	}

	id: spv.Id
	switch v in value {
	case i64:
		if type.size == 8 {
			value_bits: u64
			if types.is_float(type) {
				value_bits = transmute(u64)f64(v)
			} else {
				value_bits = u64(v)
			}
			id = spv.OpConstant(&ctx.types, ti.type, u32(value_bits), u32(value_bits >> 32))
		} else {
			value_bits: u32
			if types.is_float(type) {
				value_bits = transmute(u32)f32(v)
			} else {
				value_bits = u32(v)
			}
			id = spv.OpConstant(&ctx.types, ti.type, value_bits)
		}
	case f64:
		if type.size == 8 {
			value_bits: u64
			if types.is_float(type) {
				value_bits = transmute(u64)f64(v)
			} else {
				value_bits = u64(v)
			}
			id = spv.OpConstant(&ctx.types, ti.type, u32(value_bits), u32(value_bits >> 32))
		} else {
			value_bits: u32
			if types.is_float(type) {
				value_bits = transmute(u32)f32(v)
			} else {
				value_bits = u32(v)
			}
			id = spv.OpConstant(&ctx.types, ti.type, value_bits)
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

	ctx.constant_cache[key] = id

	return { id = id, type = type, }
}

cg_nil_value :: proc {
	cg_nil_value_from_type,
	cg_nil_value_from_type_info,
}

@(require_results)
cg_nil_value_from_type_info :: proc(ctx: ^Context, type_info: ^Type_Info) -> spv.Id {
	if type_info.nil_value == 0 {
		type_info.nil_value = spv.OpConstantNull(&ctx.types, type_info.type)
	}
	return type_info.nil_value
}

@(require_results)
cg_nil_value_from_type :: proc(ctx: ^Context, type: ^types.Type) -> spv.Id {
	return cg_nil_value_from_type_info(ctx, cg_type(ctx, type))
}

cg_type_ptr :: proc {
	cg_type_ptr_from_type,
	cg_type_ptr_from_type_info,
}

@(require_results)
cg_type_ptr_from_type_info :: proc(ctx: ^Context, type_info: ^Type_Info, storage_class: Storage_Class) -> spv.Id {
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
		case .Workgroup:
			spv_storage_class = .Workgroup
		case .Uniform_Constant:
			spv_storage_class = .UniformConstant
		case .Storage_Buffer:
			spv_storage_class = .StorageBuffer
		case .Physical_Storage_Buffer:
			spv_storage_class = .PhysicalStorageBuffer
		case .Image:
			spv_storage_class = .Image
		case .Ray_Payload:
			spv_storage_class = .RayPayloadKHR
		case .Hit_Attribute:
			spv_storage_class = .HitAttributeKHR
		case .Incoming_Ray_Payload:
			spv_storage_class = .IncomingRayPayloadKHR
		}
		type_info.ptr_types[storage_class] = spv.OpTypePointer(&ctx.types, spv_storage_class, type_info.type)
	}
	return type_info.ptr_types[storage_class]
}

@(require_results)
cg_type_ptr_from_type :: proc(ctx: ^Context, type: ^types.Type, storage_class: Storage_Class) -> spv.Id {
	return cg_type_ptr_from_type_info(ctx, cg_type(ctx, type), storage_class)
}

Type_Flag :: enum {
	Block,
	Explicit_Layout,
}

Type_Flags :: bit_set[Type_Flag]

// NOTE(Franz): This just generates the spirv for the type and hashes the resulting spirv code to deduplicate the types
@(require_results)
cg_type :: proc(ctx: ^Context, type: ^types.Type, flags: Type_Flags = {}) -> (info: ^Type_Info) {
	assert(type != nil)
	assert(.Block not_in flags || .Explicit_Layout in flags)

	type := types.base_type(type)

	cache_key := get_type_cache_key(type, flags)

	ok: bool
	info, ok = ctx.type_registry.cache[cache_key]
	if ok {
		return
	}

	current_id:         spv.Id      = 0
	type_builder:       spv.Builder = { current_id = &current_id, }
	annotation_builder: spv.Builder = { current_id = &current_id, }
	_ = cg_type_internal(ctx, &type_builder, &annotation_builder, type, flags)

	key := Type_Key {
		types       = string(slice.to_bytes(type_builder.data[:])), // []u32 is not a valid hash key...
		annotations = string(slice.to_bytes(annotation_builder.data[:])),
	}

	if info, ok = ctx.type_registry.registry[key]; ok {
		return info
	}

	info  = new(Type_Info)
	info^ = cg_type_internal(ctx, &ctx.types, &ctx.annotations, type, flags)

	ctx.type_registry.cache[cache_key] = info
	ctx.type_registry.registry[key]    = info

	return info
}

@(require_results)
cg_type_internal :: proc(
	ctx:                ^Context,
	type_builder:       ^spv.Builder,
	annotation_builder: ^spv.Builder,
	type:               ^types.Type,
	flags:              Type_Flags,
) -> (info: Type_Info) {
	assert(type != nil)
	assert(.Block not_in flags || .Explicit_Layout in flags)
	type := types.base_type(type)

	switch type.kind {
	case .Uint:
		assert(type.size != 0)
		info.type = spv.OpTypeInt(type_builder, u32(type.size * 8), 0)
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
		info.type = spv.OpTypeInt(type_builder, u32(type.size * 8), 1)
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
		info.type = spv.OpTypeFloat(type_builder, u32(type.size * 8))
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
		info.type = spv.OpTypeBool(type_builder)
	case .Struct, .Tuple:
		type := type.variant.(^types.Struct)
		if len(type.fields) != 0 {
			fields := make([]spv.Id, len(type.fields))
			for &f, i in fields {
				f = cg_type(ctx, type.fields[i].type, flags - { .Block, }).type
			}
			info.type = spv.OpTypeStruct(type_builder, ..fields)
			for f, i in type.fields {
				i := u32(i)
				// spv.OpMemberName(&ctx.debug_b, info.type, i, f.name.text)

				if .Explicit_Layout not_in flags {
					continue
				}
				spv.OpMemberDecorate(annotation_builder, info.type, u32(i), .Offset, u32(f.offset))
				type_matrix := type.fields[i].type.variant.(^types.Matrix) or_continue
				spv.OpMemberDecorate(annotation_builder, info.type, i, .MatrixStride, u32(type_matrix.col_type.size))
				spv.OpMemberDecorate(annotation_builder, info.type, i, .ColMajor)
			}
			if .Block in flags {
				spv.OpDecorate(annotation_builder, info.type, .Block)
			}
		} else {
			info.type = ctx.type_void
		}
	case .Array:
		type := type.variant.(^types.Array)
		if type.count >= 2 && type.count <= 4 && types.is_numeric(type.elem) {
			info.type = spv.OpTypeVector(type_builder, cg_type(ctx, type.elem).type, u32(type.count))
		} else {
			info.type = spv.OpTypeArray(type_builder, cg_type(ctx, type.elem).type, cg_constant(ctx, i64(type.count), nil).id)
		}
	case .Matrix:
		type     := type.variant.(^types.Matrix)
		info.type = spv.OpTypeMatrix(type_builder, cg_type(ctx, type.col_type).type, u32(type.cols))
		ctx.capabilities[.Matrix] = {}
	case .Proc:
		type := type.variant.(^types.Proc)
		args := make([]spv.Id, len(type.args))
		for &arg, i in args {
			arg = cg_type(ctx, type.args[i].type).type
		}
		info.type = spv.OpTypeFunction(type_builder, cg_type(ctx, type.return_type).type, ..args)
	case .Sampler:
		type := type.variant.(^types.Image)
		sampled_type: ^types.Type
		if types.is_numeric(type.texel_type) {
			sampled_type = type.texel_type
		} else {
			assert(types.is_array(type.texel_type))
			sampled_type = types.array_elem(type.texel_type)
		}

		info.image_type = spv.OpTypeImage(type_builder, cg_type(ctx, sampled_type).type, spv.Dim(type.dimensions - 1), 0, 0, 0, 1, .Unknown)
		info.type       = spv.OpTypeSampledImage(type_builder, info.image_type)
	case .Image:
		type := type.variant.(^types.Image)
		texel_type: ^types.Type
		if types.is_numeric(type.texel_type) {
			texel_type = type.texel_type
		} else {
			assert(types.is_array(type.texel_type))
			texel_type = types.array_elem(type.texel_type)
		}

		image_format: spv.ImageFormat
		if type.format != "" {
			for name, format in image_format_names {
				if type.format == name {
					image_format = format
					break
				}
			}
		}

		#partial switch image_format {
		case .Rg32f,     .Rg16f,    .R11fG11fB10f, .R16f,
		     .Rgba16,    .Rgb10A2,  .Rg16,         .Rg8,
		     .R16,       .R8,       .Rgba16Snorm,  .Rg16Snorm,
		     .Rg8Snorm,  .R16Snorm, .R8Snorm,      .Rg32i,
		     .Rg16i,     .Rg8i,     .R16i,         .R8i,
		     .Rgb10a2ui, .Rg32ui,   .Rg16ui,       .Rg8ui,
		     .R16ui,     .R8ui:
			ctx.capabilities[.StorageImageExtendedFormats] = {}
		case .R64ui, .R64i:
			ctx.capabilities[.Int64ImageEXT] = {}
		}

		info.type = spv.OpTypeImage(type_builder, cg_type(ctx, texel_type).type, spv.Dim(type.dimensions - 1), 0, 0, 0, 2, image_format)
	case .Buffer:
		type := type.variant.(^types.Buffer)
		elem := cg_type(ctx, type.elem, { .Explicit_Layout, })
		if type.physical {
			ctx.extensions["SPV_KHR_physical_storage_buffer"] = {}
			ctx.capabilities[.PhysicalStorageBufferAddresses] = {}
			info.type = spv.OpTypePointer(type_builder, .PhysicalStorageBuffer, elem.type)
			spv.OpDecorate(annotation_builder, info.type, .ArrayStride, u32(type.elem.size))
			if .Block in flags {
				spv.OpDecorate(annotation_builder, info.type, .Block)
				spv.OpMemberDecorate(annotation_builder, info.type, 0, .Offset, 0)
			}
		} else {
			info.array_type = spv.OpTypeRuntimeArray(type_builder, elem.type)
			info.type       = spv.OpTypeStruct(type_builder, info.array_type)
			info.array_ptr  = spv.OpTypePointer(type_builder, .StorageBuffer, info.array_type)
			spv.OpDecorate(annotation_builder, info.array_type, .ArrayStride, u32(type.elem.size))
			if .Block in flags {
				spv.OpDecorate(annotation_builder, info.type, .Block)
				spv.OpMemberDecorate(annotation_builder, info.type, 0, .Offset, 0)
			}
		}
	case .Opaque:
		type := type.variant.(^types.Opaque)
		switch type.opaque_kind {
		case .Acceleration_Structure:
			info.type = spv.OpTypeAccelerationStructureKHR(type_builder)
		}
	case .Invalid, .Enum, .Bit_Set, .Complex, .Quaternion, .Proc_Group:
		unreachable()
	}

	return
}

image_format_names: [spv.ImageFormat]string

@(init)
image_format_table_init :: proc "contextless" () {
	context = runtime.default_context()

	for &name, image_format in image_format_names {
		name = strings.to_lower(reflect.enum_name_from_value(image_format) or_else panic(""))
	}
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
			if types.is_integer(arg.type) || (types.is_array(arg.type) && types.is_integer(types.array_elem(arg.type))) {
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
				if types.is_integer(ret.type) || (types.is_array(ret.type) && types.is_integer(types.array_elem(ret.type))) {
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

		switch len(type.returns) {
		case 0: // do nothing
		case 1:
			return_value = spv.OpVariable(&ctx.functions, cg_type_ptr(ctx, return_type_info, .Function), .Function, cg_nil_value(ctx, return_type_info))
			spv.OpName(&ctx.debug_b, return_value, "$return_value")
			cg_insert_entity(ctx, type.returns[0].name.text, .Function, type.return_type, return_value)
		case:
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

	execution_mode: spv.ExecutionModel
	switch p.shader_stage {
	case .Invalid:
		return
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
	case .Ray_Generation:
		execution_mode = .RayGenerationKHR
	case .Intersection:
		execution_mode = .IntersectionKHR
	case .Any_Hit:
		execution_mode = .AnyHitKHR
	case .Closest_Hit:
		execution_mode = .ClosestHitKHR
	case .Miss:
		execution_mode = .MissKHR
	}
	interface := make([dynamic]spv.Id, 0, len(ctx.referenced_globals))
	for g in ctx.referenced_globals {
		append(&interface, g)
	}
	clear(&ctx.referenced_globals)
	clear(&ctx.interface_variables)
	spv.OpEntryPoint(&ctx.entry_points, execution_mode, id, link_name, ..interface[:])
	#partial switch p.shader_stage {
	case .Fragment:
		spv.OpExecutionMode(&ctx.execution_modes, id, .OriginUpperLeft)
	case .Compute:
		spv.OpExecutionMode(&ctx.execution_modes, id, .LocalSize, u32(ctx.local_size.x), u32(ctx.local_size.y), u32(ctx.local_size.z))
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
			texel_type = types.array_new(value.type, 4, context.temp_allocator)
		} else if types.is_array(value.type) {
			vector_len = types.array_len(value.type)
			if vector_len == 4 {
				texel_type = value.type
			} else {
				texel_type = types.array_new(types.array_elem(value.type), 4, context.temp_allocator)
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

	type^ = types.op_result_type(lhs_type, rhs_type, op == .Multiply, context.temp_allocator)

	cg_binary_op :: proc(
		ctx:         ^Context,
		builder:     ^spv.Builder,
		result_type: spv.Id,
		lhs, rhs:    Value,
		type:        ^types.Type,
		op:          tokenizer.Token_Kind,
	) -> spv.Id {
		runtime_proc:   Runtime_Proc
		binary_op_proc: proc(builder: ^spv.Builder, result_type: spv.Id, operand_1, operand_2: spv.Id) -> (result: spv.Id)

		#partial switch type.kind {
		case .Int:
			#partial switch op {
			case .Add:
				binary_op_proc = spv.OpIAdd
			case .Subtract:
				binary_op_proc = spv.OpISub
			case .Multiply:
				binary_op_proc = spv.OpIMul
			case .Divide:
				binary_op_proc = spv.OpSDiv
			case .Modulo:
				binary_op_proc = spv.OpSMod
			case .Bit_Or:
				binary_op_proc = spv.OpBitwiseOr
			case .Bit_And:
				binary_op_proc = spv.OpBitwiseAnd
			case .Xor:
				binary_op_proc = spv.OpBitwiseXor
			}
		case .Uint:
			#partial switch op {
			case .Add:
				binary_op_proc = spv.OpIAdd
			case .Subtract:
				binary_op_proc = spv.OpISub
			case .Multiply:
				binary_op_proc = spv.OpIMul
			case .Divide:
				binary_op_proc = spv.OpUDiv
			case .Modulo:
				binary_op_proc = spv.OpUMod
			case .Bit_Or:
				binary_op_proc = spv.OpBitwiseOr
			case .Bit_And:
				binary_op_proc = spv.OpBitwiseAnd
			case .Xor:
				binary_op_proc = spv.OpBitwiseXor
			}
		case .Float:
			#partial switch op {
			case .Add:
				binary_op_proc = spv.OpFAdd
			case .Subtract:
				binary_op_proc = spv.OpFSub
			case .Multiply:
				binary_op_proc = spv.OpFMul
			case .Modulo:
				binary_op_proc = spv.OpFMod
			case .Divide:
				binary_op_proc = spv.OpFDiv
			}
		case .Bool:
			#partial switch op {
			case .And:
				binary_op_proc = spv.OpLogicalAnd
			case .Or:
				binary_op_proc = spv.OpLogicalOr
			}
		case .Matrix:
			#partial switch op {
			case .Multiply:
				binary_op_proc = spv.OpMatrixTimesMatrix
			}
		case .Array:
			if lhs.type.kind == .Matrix || rhs.type.kind == .Matrix {
				assert(op == .Multiply)

				if lhs.type.kind == .Matrix {
					binary_op_proc = spv.OpMatrixTimesVector
					break
				} else {
					panic("")
					// assert(rhs_type.kind == .Matrix)
					// return spv.OpVectorTimesMatrix(builder, type_info.type, lhs, rhs)
				}
			}

			if lhs.type.kind == .Array && rhs.type.kind == .Array {
				len := types.array_len(lhs.type)

				if len < 4 {
					return cg_binary_op(
						ctx,
						builder,
						result_type,
						{ id = lhs.id, type = types.array_elem(lhs.type), },
						{ id = rhs.id, type = types.array_elem(rhs.type), },
						types.array_elem(type),
						op,
					)
				}

				elem    := types.array_elem(type)
				elem_id := cg_type(ctx, elem).type

				values := make([]spv.Id, len, context.temp_allocator)
				for i in 0 ..< len {
					l        := spv.OpCompositeExtract(builder, elem_id, lhs.id, u32(i))
					r        := spv.OpCompositeExtract(builder, elem_id, rhs.id, u32(i))
					values[i] = cg_binary_op(
						ctx,
						builder,
						elem_id,
						{ id = l, type = elem, },
						{ id = r, type = elem, },
						elem,
						op,
					)
				}
				return spv.OpCompositeConstruct(builder, result_type, ..values)
			}
		case .Complex:
			#partial switch op {
			case .Add, .Subtract:
				return cg_binary_op(
					ctx,
					builder,
					result_type,
					{ id = lhs.id, type = types.complex_elem(lhs.type), },
					{ id = rhs.id, type = types.complex_elem(rhs.type), },
					types.complex_elem(type),
					op,
				)
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
				return cg_binary_op(
					ctx,
					builder,
					result_type,
					{ id = lhs.id, type = types.complex_elem(lhs.type), },
					{ id = rhs.id, type = types.complex_elem(rhs.type), },
					types.complex_elem(type),
					op,
				)
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

		if binary_op_proc != nil {
			return binary_op_proc(builder, result_type, lhs.id, rhs.id)
		}

		if runtime_proc != nil {
			runtime_proc_id := get_runtime_proc(ctx, runtime_proc)
			return spv.OpFunctionCall(builder, result_type, runtime_proc_id, lhs.id, rhs.id)
		}

		panic("Failed to generated binary operation")
	}

	return cg_binary_op(ctx, builder, cg_type(ctx, type^).type, lhs_value, rhs_value, type^, op)
}

@(require_results)
cg_interface :: proc(
	ctx:     ^Context,
	builtin: string,
) -> (value: Value) {
	defer ctx.referenced_globals[value.id] = {}

	info := checker.interface_infos[builtin]

	if cached, ok := ctx.interface_variables[info.id]; ok {
		return cached
	}

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
	spv.OpDecorate(&ctx.annotations, value.id, .BuiltIn, u32(info.id))

	ctx.interface_variables[info.id] = value

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

	value = cg_expr_internal(ctx, builder, expr)
	if value.type == nil {
		value.type = expr.type
	}

	if !deref {
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
		case .Opaque:
			to := to.variant.(^types.Opaque)
			switch to.opaque_kind {
			case .Acceleration_Structure:
				return spv.OpConvertUToAccelerationStructureKHR
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
	case .Array:
		type := type.variant.(^types.Array)
		if types.is_numeric(v_type) {
			values := make([]spv.Id, type.count, context.temp_allocator)
			casted := cg_cast(ctx, builder, value, type.elem)
			for &v in values {
				v = casted
			}
			return spv.OpCompositeConstruct(builder, ti.type, ..values)
		} else {
			op_inst := numeric_cast_op_inst(types.array_elem(v_type), type.elem)
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

cg_expr_internal :: proc(
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

	cg_ident :: proc(ctx: ^Context, builder: ^spv.Builder, name: string, library: string = "") -> (value: Value) {
		value = cg_lookup_entity(ctx, name, library)
		#partial switch value.storage_class {
		case .Push_Constant, .Storage_Buffer, .Uniform, .Uniform_Constant:
			value.explicit_layout = true
			fallthrough
		case .Global, .Ray_Payload, .Hit_Attribute, .Incoming_Ray_Payload:
			if ctx.spirv_version > spv_version(1, 3) {
				ctx.referenced_globals[value.id] = {}
			}
		}
		return
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
		return cg_ident(ctx, builder, v.ident.text)
	case ^ast.Expr_Proc_Lit:
		return cg_proc_lit(ctx, v)
	case ^ast.Expr_Proc_Sig:
	case ^ast.Expr_Proc_Group:
		members := make([]spv.Id, len(v.members))
		for m, i in v.members {
			members[i] = cg_expr(ctx, builder, m).id
		}
		value.group_members = members
		return
	case ^ast.Expr_Paren:
		return cg_expr(ctx, builder, v.expr)
	case ^ast.Expr_Ellipsis:
		return cg_expr(ctx, builder, v.expr)
	case ^ast.Expr_Selector:
		if v.library != "" {
			return cg_ident(ctx, builder, v.selector.text, v.library)
		}
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

		assert(lhs.type.kind == .Array)

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
			t := types.array_elem(lhs.type)
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
		if v.is_directive {
			return
		}
		if v.builtin != nil {
			ti: ^Type_Info
			if v.type.kind != .Invalid {
				ti = cg_type(ctx, v.type)
			}
			switch v.builtin {
			case .Invalid,
			     .Size_Of,
			     .Align_Of,
			     .Type_Of,
			     .Type_Is_Array,
			     .Type_Is_Float,
			     .Type_Is_Boolean,
			     .Type_Is_Integer,
			     .Type_Is_Numeric,
			     .Type_Is_Complex,
			     .Type_Is_Quaternion,
			     .Type_Is_Matrix:
				fmt.panicf("invalid builtin: %v", v.builtin)
			case .Dot:
				t := types.op_result_type(v.args[0].value.type, v.args[1].value.type)
				a := cg_cast(ctx, builder, cg_expr(ctx, builder, v.args[0].value), t)
				b := cg_cast(ctx, builder, cg_expr(ctx, builder, v.args[1].value), t)
				id: spv.Id
				#partial switch types.array_elem(t).kind {
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
				e   := types.array_elem(v.type)
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
				if v.type.kind == .Array {
					elem_type = types.array_elem(v.type)
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
			case .Sinh:
				return { id = spv_glsl.OpSinh(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Cosh:
				return { id = spv_glsl.OpCosh(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Tanh:
				return { id = spv_glsl.OpTanh(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Asin:
				return { id = spv_glsl.OpAsin(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Acos:
				return { id = spv_glsl.OpAcos(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Atan:
				return { id = spv_glsl.OpAtan(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Asinh:
				return { id = spv_glsl.OpAsinh(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Acosh:
				return { id = spv_glsl.OpAcosh(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Atanh:
				return { id = spv_glsl.OpAtanh(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Atan2:
				y := cg_expr(ctx, builder, v.args[0].value).id
				x := cg_expr(ctx, builder, v.args[1].value).id
				return { id = spv_glsl.OpAtan2(builder, ti.type, y, x), }
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
			case .Sign:
				return { id = spv_glsl.OpFSign(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Abs:
				t := v.args[0].value.type
				if types.is_array(t) {
					t = types.array_elem(t)
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
				if types.is_array(v.type) {
					t = types.array_elem(v.type)
				} else {
					t = types.complex_elem(v.type)
				}
				return { id = spv_glsl.OpLength(builder, cg_type(ctx, t).type, v.id), }
			case .Distance:
				a := cg_expr(ctx, builder, v.args[0].value).id
				b := cg_expr(ctx, builder, v.args[1].value).id
				return { id = spv_glsl.OpDistance(builder, ti.type, a, b), }
			case .Reflect:
				a := cg_expr(ctx, builder, v.args[0].value).id
				b := cg_expr(ctx, builder, v.args[1].value).id
				return { id = spv_glsl.OpReflect(builder, ti.type, a, b), }
			case .Refract:
				a := cg_expr(ctx, builder, v.args[0].value).id
				b := cg_expr(ctx, builder, v.args[1].value).id
				e := cg_expr(ctx, builder, v.args[2].value).id
				return { id = spv_glsl.OpRefract(builder, ti.type, a, b, e), }
			case .Clamp:
				elem_type := v.type
				if v.type.kind == .Array {
					elem_type = types.array_elem(v.type)
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
			case .Count_Ones:
				return { id = spv.OpBitCount(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Count_Zeros:
				ones := spv.OpBitCount(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id)
				bits := cg_constant(ctx, i64(v.type.size * 8), nil).id
				return { id = spv.OpISub(builder, ti.type, bits, ones), }
			case .Find_Lsb, .Find_Msb, .Count_Leading_Zeros, .Count_Trailing_Zeros, .Count_Leading_Ones, .Count_Trailing_Ones:
				t := v.type
				if types.is_array(t) {
					t = types.array_elem(t)
				}

				arg := cg_expr(ctx, builder, v.args[0].value).id

				#partial switch v.builtin {
				case .Count_Leading_Ones:
					arg = spv.OpNot(builder, ti.type, arg)
					fallthrough
				case .Count_Leading_Zeros:
					ret: spv.Id
					#partial switch t.kind {
					case .Int:
						ret = spv_glsl.OpFindSMsb(builder, ti.type, arg)
					case .Uint:
						ret = spv_glsl.OpFindUMsb(builder, ti.type, arg)
					}

					adjust    := cg_constant(ctx, i64(t.size * 8 - 1), v.type).id
					ret        = spv.OpISub(builder, ti.type, adjust, ret)

					bit_count := cg_constant(ctx, i64(t.size * 8), v.type).id
					zero      := cg_nil_value(ctx, v.type)
					is_zero   := spv.OpIEqual(builder, cg_type(ctx, types.t_bool).type, arg, zero)
					return { id = spv.OpSelect(builder, ti.type, is_zero, bit_count, ret), }

				case .Count_Trailing_Ones:
					arg = spv.OpNot(builder, ti.type, arg)
					fallthrough
				case .Count_Trailing_Zeros:
					ret       := spv_glsl.OpFindILsb(builder, ti.type, arg)
					bit_count := cg_constant(ctx, i64(t.size * 8), v.type).id
					zero      := cg_nil_value(ctx, v.type)
					is_zero   := spv.OpIEqual(builder, cg_type(ctx, types.t_bool).type, arg, zero)
					return { id = spv.OpSelect(builder, ti.type, is_zero, bit_count, ret), }

				case .Find_Lsb:
					return { id = spv_glsl.OpFindILsb(builder, ti.type, arg), }
				case .Find_Msb:
					#partial switch t.kind {
					case .Int:
						return { id = spv_glsl.OpFindSMsb(builder, ti.type, arg), }
					case .Uint:
						return { id = spv_glsl.OpFindUMsb(builder, ti.type, arg), }
					}
				}

				unimplemented()
			case .Reverse_Bits:
				return { id = spv.OpBitReverse(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id), }
			case .Real, .Imag, .Jmag, .Kmag:
				coord := u32(v.builtin - .Real)
				return { id = spv.OpCompositeExtract(builder, ti.type, cg_expr(ctx, builder, v.args[0].value).id, coord), }
			case .Read_Device_Clock, .Read_Subgroup_Clock:
				scope: spv.Scope
				#partial switch v.builtin {
				case .Read_Device_Clock:
					scope = .Device
				case .Read_Subgroup_Clock:
					scope = .Subgroup
				}
				return { id = spv.OpReadClockKHR(builder, ti.type, cg_constant(ctx, i64(scope), nil).id), }
			case .Barrier:
				scope     := cg_constant(ctx, i64(spv.Scope.Workgroup), nil).id
				semantics := cg_constant(ctx, i64(spv.MemorySemantics{ .AcquireRelease, .WorkgroupMemory, }), nil).id
				spv.OpControlBarrier(builder, scope, scope, semantics)
				return
			case .Trace_Ray:
				args := make([]spv.Id, 11, context.temp_allocator)
				types: [11]^types.Type = {
					nil,                // Acceleration Structure
					types.t_Ray_Flags,  // Ray Flags
					types.t_i32,        // Cull Mask
					types.t_i32,        // SBT Offset
					types.t_i32,        // SBT Stride
					types.t_i32,        // Miss Index
					types.t_vec3,       // Ray Origin
					types.t_f32,        // Ray Tmin
					types.t_vec3,       // Ray Direction
					types.t_f32,        // Ray Tmax
					nil,                // Payload
				}
				for &arg, i in args {
					type := types[i]
					val  := cg_expr(ctx, builder, v.args[i].value, i != 10)
					if i == 10 || type == nil {
						arg = val.id
					} else {
						arg = cg_cast(ctx, builder, val, type)
					}
				}
				spv.OpTraceRayKHR(builder, args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10])
				return
			case .Ignore_Intersection:
				spv.OpIgnoreIntersectionKHR(builder)
				return { discard = true, }
			case .Terminate_Ray:
				spv.OpTerminateRayKHR(builder)
				return { discard = true, }
			case .Report_Intersection:
				hit      := cg_expr(ctx, builder, v.args[0].value).id
				hit_kind := cg_expr(ctx, builder, v.args[1].value).id
				return { id = spv.OpReportIntersectionKHR(builder, cg_type(ctx, types.t_bool).type, hit, hit_kind), }
			}

			unreachable()
		}

		if v.is_cast {
			return { id = cg_cast(ctx, builder, cg_expr(ctx, builder, v.args[0].value), v.type), }
		}

		_fn       := cg_expr(ctx, builder, v.lhs)
		fn        := _fn.id
		proc_type := v.lhs.type.variant.(^types.Proc) or_else nil
		if member, ok := v.group_member.?; ok {
			fn        = _fn.group_members[member]
			proc_type = v.lhs.type.variant.(^types.Proc_Group).members[member]
		}

		args := make([dynamic]spv.Id, 0, len(v.args))
		arg_i: int
		for arg in v.args {
			value  := cg_expr(ctx, builder, arg.value)
			values := []Value{ value, }
			deconstruct_tuple(ctx, builder, value.type, &values)

			for value in values {
				append(&args, cg_cast(ctx, builder, value, proc_type.args[arg_i].type))
				arg_i += 1
			}
		}

		return_type_info := cg_type(ctx, proc_type.return_type)
		ret              := spv.OpFunctionCall(builder, return_type_info.type, fn, ..args[:])

		return { id = ret, }
	case ^ast.Expr_Compound:
		if len(v.fields) == 0 {
			return { id = cg_nil_value(ctx, cg_type(ctx, v.type)), }
		}

		if v.type.kind == .Matrix {
			assert(!v.named)

			type := v.type.variant.(^types.Matrix)
			elem := type.col_type.elem

			row_type_id := cg_type(ctx, type.col_type).type

			columns    := make([]spv.Id, type.cols,           context.temp_allocator)
			row_values := make([]spv.Id, type.col_type.count, context.temp_allocator)

			row_i, col_i: int
			for field in v.fields {
				value            := cg_expr(ctx, builder, field.value)
				row_values[row_i] = cg_cast(ctx, builder, value, elem)
				row_i            += 1
				if row_i == type.cols {
					columns[col_i] = spv.OpCompositeConstruct(builder, row_type_id, ..row_values[:])

					row_i  = 0
					col_i += 1
				}
			}

			return { id = spv.OpCompositeConstruct(builder, cg_type(ctx, v.type).type, ..columns[:]), }
		}

		if v.type.kind == .Bit_Set {
			bit_set_id := cg_type(ctx, v.type).type
			value      := cg_nil_value(ctx, v.type)
			one        := cg_constant(ctx, i64(1), v.type).id
			for field in v.fields {
				shift := cg_cast(ctx, builder, cg_expr(ctx, builder, field.value), v.type)
				elem  := spv.OpShiftLeftLogical(builder, bit_set_id, one, shift)

				value = spv.OpBitwiseOr(builder, bit_set_id, value, elem)
			}

			return { id = value, }
		}

		if !v.named {
			values := make([]spv.Id, len(v.fields), context.temp_allocator)
			i: int
			for field in v.fields {
				type: ^types.Type
				#partial switch v.type.kind {
				case .Array:
					type = types.array_elem(v.type)
				case .Matrix:
					type = types.matrix_elem(v.type)
				case .Struct:
					type = v.type.variant.(^types.Struct).fields[i].type
				}
				value := cg_expr(ctx, builder, field.value)
				if types.is_array(value.type) && types.is_array(v.type) {
					values[i] = cg_deref(ctx, builder, value)
				} else {
					values[i] = cg_cast(ctx, builder, value, type)
				}
				i += 1
			}
			if v.constant {
				return { id = spv.OpConstantComposite(&ctx.types, cg_type(ctx, v.type).type, ..values[:]), }
			} else {
				return { id = spv.OpCompositeConstruct(builder, cg_type(ctx, v.type).type, ..values[:]), }
			}
		}

		if vector, ok := v.type.variant.(^types.Array); ok {
			elem_type_id := cg_type(ctx, vector.elem).type
			values       := make([]spv.Id, vector.count, context.temp_allocator)
			for field in v.fields {
				coords: [4]int
				n := len(field.ident.text)
				for char, i in field.ident.text {
					index: int = -1
					switch char {
					case 'r', 'x':
						index = 0
					case 'g', 'y':
						index = 1
					case 'b', 'z':
						index = 2
					case 'a', 'w':
						index = 3
					}
					coords[i] = index
				}

				val := cg_expr(ctx, builder, field.value)
				if n == 1 {
					values[coords[0]] = cg_cast(ctx, builder, val, vector.elem)
				} else {
					vec := types.array_new(vector.elem, n, context.temp_allocator)
					val := cg_cast(ctx, builder, val, vec)

					for dst_coord, src_coord in coords[:n] {
						values[dst_coord] = spv.OpCompositeExtract(builder, elem_type_id, val, u32(src_coord))
					}
				}
			}

			nil_elem := cg_nil_value(ctx, cg_type(ctx, vector.elem))
			for &value in values {
				if value == 0 {
					value = nil_elem
				}
			}
			return { id = spv.OpCompositeConstruct(builder, cg_type(ctx, v.type).type, ..values), }
		}

		fields := v.type.variant.(^types.Struct).fields
		values := make([]spv.Id, len(fields), context.temp_allocator)
		for field in v.fields {
			find_struct_field_index :: proc(fields: []types.Field, name: string) -> int {
				for field, i in fields {
					if field.name.text == name {
						return i
					}
				}
				return -1
			}

			index        := find_struct_field_index(fields, field.ident.text)
			value        := cg_expr(ctx, builder, field.value)
			values[index] = cg_cast(ctx, builder, value, fields[index].type)
		}

		for field, i in fields {
			if values[i] != 0 {
				continue
			}
			values[i] = cg_nil_value(ctx, cg_type(ctx, field.type))
		}
			return { id = spv.OpCompositeConstruct(builder, cg_type(ctx, v.type).type, ..values), }
	case ^ast.Expr_Index:
		lhs := cg_expr(ctx, builder, v.lhs, false)
		rhs := cg_expr(ctx, builder, v.rhs)

		if types.is_array(lhs.type) && len(lhs.swizzle) != 0 {
			lhs.id            = cg_deref(ctx, builder, lhs)
			lhs.storage_class = {}
			lhs.swizzle       = {}
		}

		if types.is_sampler(lhs.type) {
			sampler    := lhs.type.variant.(^types.Image)
			count      := 1
			texel_type := sampler.texel_type
			if v, ok := sampler.texel_type.variant.(^types.Array); ok {
				count = v.count
				if v.count != 4 {
					texel_type = types.array_new(v.elem, 4, context.temp_allocator)
				}
			} else {
				texel_type = types.array_new(sampler.texel_type, 4, context.temp_allocator)
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
			if v, ok := sampler.texel_type.variant.(^types.Array); ok {
				count = v.count
				if v.count != 4 {
					texel_type = types.array_new(v.elem, 4, context.temp_allocator)
				}
			} else {
				texel_type = types.array_new(sampler.texel_type, 4, context.temp_allocator)
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

		type := types.array_elem(lhs.type.variant.(^types.Array))
		return {
			id   = spv.OpVectorExtractDynamic(builder, cg_type(ctx, type).type, lhs.id, rhs.id),
			type = type,
		}

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
			case .Array:
				#partial switch types.array_elem(type).kind {
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
	case ^ast.Type_Struct, ^ast.Type_Array, ^ast.Type_Matrix, ^ast.Type_Image, ^ast.Type_Enum, ^ast.Type_Bit_Set:
		panic("tried to cg type as expression")
	case ^ast.Expr_Directive:
		panic("tried to cg directive as expression")
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
		return_type  := proc_scope.return_type

		if return_value == 0 { // return values are shader stage outputs
			type_fields: []types.Field
			if types.is_tuple(return_type) {
				type_fields = return_type.variant.(^types.Struct).fields
			} else {
				type_fields = { { type = return_type, }, }
			}
			i: int
			for value in v.values {
				values := []Value{ cg_expr(ctx, builder, value), }
				deconstruct_tuple(ctx, builder, value.type, &values)

				for v in values {
					ptr := proc_scope.outputs[i]
					spv.OpStore(builder, ptr, cg_cast(ctx, builder, v, type_fields[i].type))
					i += 1
				}
			}
			spv.OpReturn(builder)
		} else {
			return_ti := cg_type(ctx, return_type)

			if types.is_tuple(return_type) {
				type := return_type.variant.(^types.Struct)

				i: int
				for value in v.values {
					values := []Value{ cg_expr(ctx, builder, value), }
					deconstruct_tuple(ctx, builder, value.type, &values)

					for v in values {
						ptr := spv.OpAccessChain(
							builder,
							cg_type_ptr(ctx, type.fields[i].type, .Function),
							return_value,
							cg_constant(ctx, i64(i), nil).id,
						)
						spv.OpStore(builder, ptr, cg_cast(ctx, builder, v, type.fields[i].type))

						i += 1
					}
				}
			} else {
				assert(len(v.values) == 1)
				value := cg_expr(ctx, builder, v.values[0])
				spv.OpStore(builder, return_value, cg_cast(ctx, builder, value, return_type))
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
			deconstruct_tuple(ctx, builder, value.type, &values)

			for rhs in values {
				lhs   := cg_expr(ctx, builder, v.lhs[lhs_i], deref = false)
				lhs_i += 1

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
					elem := cg_type(ctx, types.array_elem(lhs.real_type))

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
			}
		}
	case ^ast.Stmt_Expr:
		e := cg_expr(ctx, builder, v.expr, false)
		if e.discard {
			return true
		}

	case ^ast.Decl_Value:
		cg_value_decl(ctx, builder, v, global)
	case ^ast.Decl_Import:
		text := v.library.text[1:len(v.library.text) - 1]
		switch text {
		case "extensions:raytracing":
			ctx.extensions["SPV_KHR_ray_tracing"] = {}
			ctx.capabilities[.RayTracingKHR]      = {}
		case "extensions:clock":
			ctx.extensions["SPV_KHR_shader_clock"] = {}
			ctx.capabilities[.ShaderClockKHR]      = {}
		}
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

deconstruct_tuple :: proc(ctx: ^Context, builder: ^spv.Builder, type: ^types.Type, values: ^[]Value) {
	if type.kind != .Tuple {
		return
	}

	type := type.variant.(^types.Struct)
	v    := values[0]

	if len(type.fields) == 1 {
		values[0] = {
			type = type.fields[0].type,
			id   = v.id,
		}
		return
	}

	values^ = make([]Value, len(type.fields), context.temp_allocator)
	for &val, i in values {
		ti := cg_type(ctx, type.fields[i].type)
		val = {
			type = type.fields[i].type,
			id   = spv.OpCompositeExtract(builder, ti.type, v.id, u32(i)),
		}
	}
}
