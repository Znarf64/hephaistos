package hephaistos_checker

import "base:intrinsics"
import "base:runtime"

import "core:fmt"
import "core:mem"
import "core:reflect"

import "../ast"
import "../tokenizer"
import "../types"
import spv "../spirv-odin"

@(require)
import vk "vendor:vulkan"

Flag :: enum {
	Auto_Map_Locations,
	Auto_Bind_Uniforms,
	Enable_Reflection,
}

Flags :: bit_set[Flag]

Library :: struct {
	entities: map[string]^Entity,
}

to_library :: proc(checker: Checker) -> Library {
	return {
		entities = checker.scope.elements,
	}
}

Checker :: struct {
	allocator:        runtime.Allocator,
	errors:           [dynamic]tokenizer.Error,
	error_allocator:  runtime.Allocator,

	libraries:        map[string]Library,
	shared_types:     map[string]^types.Type,
	config_vars:      map[string]types.Const_Value,
	flags:            Flags,

	scope:            ^Scope,
	shader_stage:     ast.Shader_Stage,
	current_location: int,
	current_binding:  int,

	reflection:       struct {
		interface:    map[string]Reflection_Info,
		entry_points: map[string]Entry_Point_Info,
	},
}

Entry_Point_Info :: struct {
	inputs:  []Reflection_Info,
	outputs: []Reflection_Info,
	stage:   ast.Shader_Stage,
}

Reflection_Info :: struct {
	type:              ^types.Type,
	interface:         ast.Interface_Kind,
	binding, location: int,
}

Buffer_Address :: struct($T: typeid) #raw_union {
	address: vk.DeviceAddress,
	_:       ^T `hephaistos:"buffer_device_address"`,
}

Addressing_Mode :: enum {
	Invalid = 0,
	RValue,
	NoValue,
	LValue,
	Const,
	Proc,
	Type,
	Builtin,
	Library,
}

@(rodata)
addressing_mode_string := [Addressing_Mode]string {
	.Invalid  = "<invalid>",
	.NoValue  = "no value",
	.RValue   = "rvalue",
	.LValue   = "lvalue",
	.Const    = "const",
	.Proc     = "proc",
	.Type     = "type",
	.Builtin  = "builtin",
	.Library  = "library",
}

@(rodata)
builtin_names: [ast.Builtin_Id]string = {
	.Invalid      = "invalid",
	.Dot          = "dot",
	.Cross        = "cross",
	.Min          = "min",
	.Max          = "max",
	.Clamp        = "clamp",
	.Inverse      = "inverse",
	.Transpose    = "transpose",
	.Determinant  = "determinant",
	.Pow          = "pow",
	.Sqrt         = "sqrt",
	.Sin          = "sin",
	.Cos          = "cos",
	.Tan          = "tan",
	.Normalize    = "normalize",
	.Length       = "length",
	.Exp          = "exp",
	.Log          = "log",
	.Exp2         = "exp2",
	.Log2         = "log2",
	.Fract        = "fract",
	.Floor        = "floor",
	.Ceil         = "ceil",
	.Lerp         = "lerp",
	.Round        = "round",
	.Trunc        = "trunc",
	.Smooth_Step  = "smooth_step",
	.Distance     = "distance",
	.Inverse_Sqrt = "inverse_sqrt",
	.Abs          = "abs",
	.Bit_Count    = "bit_count",
	.Bit_Reverse  = "bit_reverse",
	.Real         = "real",
	.Imag         = "imag",
	.Jmag         = "jmag",
	.Kmag         = "kmag",

	.Texture_Size = "texture_size",
	.Image_Size   = "image_size",

	.Discard      = "discard",

	.Ddx          = "ddx",
	.Ddy          = "ddy",

	.Size_Of      = "size_of",
	.Align_Of     = "align_of",
	.Type_Of      = "type_of",
}

Operand :: struct {
	expr:       ^ast.Expr,
	type:       ^types.Type,
	mode:       Addressing_Mode,
	value:      types.Const_Value,
	builtin_id: ast.Builtin_Id,
	library:    string,
	is_call:    bool,
}

Scope_Proc_Info :: struct {
	type: ^types.Proc,
	lit:  ^ast.Expr_Proc_Lit,
}

Scope :: struct {
	parent:    ^Scope,
	elements:  map[string]^Entity,
	procedure: Maybe(Scope_Proc_Info),
	label:     Maybe(tokenizer.Token),
	kind:      Scope_Kind,
}

Scope_Kind :: enum {
	Global,
	Proc,
	Block, // if or {}
	Loop,
	Switch,
}

@(require_results)
scope_new :: proc(parent: ^Scope, kind: Scope_Kind, allocator: mem.Allocator) -> ^Scope {
	s, _ := new(Scope, allocator)
	s.parent = parent
	s.kind   = kind
	s.elements.allocator = allocator
	return s
}

@(require_results)
scope_lookup :: proc(checker: ^Checker, name: string) -> (e: ^Entity, ok: bool) {
	s := checker.scope
	for s != nil {
		e, ok = s.elements[name]
		if ok {
			resolve_constant(checker, e)
			return
		}
		s = s.parent
	}
	return
}

@(require_results)
scope_lookup_label :: proc(checker: ^Checker, name: string) -> (s: ^Scope, ok: bool) {
	s = checker.scope
	for s != nil {
		if label, ok := s.label.?; ok && label.text == name {
			return s, true
		}
		s = s.parent
	}

	return
}

@(require_results)
lookup_proc_type :: proc(checker: ^Checker) -> (e: ^types.Proc, ok: bool) {
	s := checker.scope
	for s != nil {
		p, ok := s.procedure.?
		if ok {
			return p.type, true
		}
		s = s.parent
	}

	return
}

@(require_results)
lookup_scope_by_kind :: proc(checker: ^Checker, mask: bit_set[Scope_Kind]) -> (s: ^Scope, ok: bool) {
	s = checker.scope
	for s != nil {
		if s.kind in mask {
			return s, true
		}
		s = s.parent
	}

	return
}

scope_push :: proc(c: ^Checker, kind: Scope_Kind) -> ^Scope {
	c.scope = scope_new(c.scope, kind, c.allocator)
	return c.scope
}

scope_pop :: proc(c: ^Checker) -> ^Scope {
	s := c.scope
	c.scope = s.parent
	return s
}

scope_insert_entity :: proc(checker: ^Checker, e: ^Entity) -> bool {
	if e == nil {
		return true
	}

	assert(e.name  != "")
	assert(checker.scope != nil)
	if e.name in checker.scope.elements {
		error(checker, e.ident, "'%s' has already been defined in this scope", e.name)
		return false
	}

	checker.scope.elements[e.name] = e
	return true
}

check_stmt :: proc(checker: ^Checker, stmt: ^ast.Stmt) -> (diverging: bool) {
	switch v in stmt.derived_stmt {
	case ^ast.Stmt_Return:
		proc_type, ok := lookup_proc_type(checker)
		if !ok {
			error(checker, v, "unexpected return statement outside of procedure body")
			return true
		}
		return_index := 0
		for e in v.values {
			value := check_expr(checker, e, type_hint = proc_type.returns[return_index].type)
			if return_index >= len(proc_type.returns) {
				continue
			}

			if value.type.kind == .Tuple {
				for type in value.type.variant.(^types.Struct).fields {
					if !types.implicitly_castable(type.type, proc_type.returns[return_index].type) {
						error(checker, value, "mismatched type in return statement: %v vs %v", proc_type.returns[return_index].type, type.type)
					}
					return_index += 1
				}
			} else {
				if !types.implicitly_castable(value.type, proc_type.returns[return_index].type) {
					error(checker, value, "mismatched type in return statement: %v vs %v", proc_type.returns[return_index].type, value.type)
				}
				return_index += 1
			}
		}

		if return_index != 0 && return_index != len(proc_type.returns) {
			error(checker, v, "expected %d values for return statements but got %d", len(proc_type.returns), return_index)
		}

		return true
	case ^ast.Stmt_Break:
		if v.label.text != "" {
			_, ok := scope_lookup_label(checker, v.label.text)
			if !ok {
				error(checker, v, "unknown label: '%s'", v.label.text)
			}
		} else {
			_, ok := lookup_scope_by_kind(checker, { .Loop, .Switch, })
			if !ok {
				error(checker, v, "break can only be used in loops and switches")
			}
		}

		return true
	case ^ast.Stmt_Continue:
		if v.label.text != "" {
			scope, ok := scope_lookup_label(checker, v.label.text)
			if !ok {
				error(checker, v, "unknown label: '%s'", v.label.text)
			}
			if scope.kind != .Loop {
				error(checker, v, "continue can only be used in loops")
			}
		} else {
			_, ok := lookup_scope_by_kind(checker, { .Loop, })
			if !ok {
				error(checker, v, "continue can only be used in loops")
			}
		}

		return true
	case ^ast.Stmt_For_Range:
		scope_push(checker, .Loop).label = v.label
		defer scope_pop(checker)

		start := check_expr(checker, v.start_expr)
		end   := check_expr(checker, v.end_expr, type_hint = start.type)
		if !types.is_numeric(start.type) {
			error(checker, v.end, "non-numeric type in range statment: %v", start.type)
		}
		iter_type        := types.op_result_type(start.type, end.type)
		iter_type         = types.default_type(iter_type)
		v.start_expr.type = iter_type
		v.end_expr.type   = iter_type
		if iter_type.kind == .Invalid {
			error(checker, v.end, "mismatched types in range stmt: %v vs %v", start.type, end.type)
		}
		if var, ok := v.variable.derived_expr.(^ast.Expr_Ident); ok {
			e := entity_new(.Var, var.ident, iter_type, flags = { .Readonly, .Resolved, }, allocator = checker.allocator)
			scope_insert_entity(checker, e)
			v.variable.type = iter_type
		} else {
			error(checker, v.variable, "iterator variable expression has to be an identifier")
		}

		scope_push(checker, .Block)
		defer scope_pop(checker)
		check_stmt_list(checker, v.body)
		return false
	case ^ast.Stmt_For:
		scope_push(checker, .Loop).label = v.label
		defer scope_pop(checker)

		if v.init != nil {
			check_stmt(checker, v.init)
		}

		if v.cond != nil {
			cond := check_expr(checker, v.cond)
			if cond.type.kind != .Bool {
				error(checker, cond, "expected a boolean expression in if statement condition but got: %v", cond.type)
			}
		}

		if v.post != nil {
			check_stmt(checker, v.post)
		}

		scope_push(checker, .Block)
		defer scope_pop(checker)
		check_stmt_list(checker, v.body)
		return false
	case ^ast.Stmt_Block:
		scope_push(checker, .Block).label = v.label
		defer scope_pop(checker)

		return check_stmt_list(checker, v.body)
	case ^ast.Stmt_If:
		scope_push(checker, .Block).label = v.label
		defer scope_pop(checker)

		if v.init != nil {
			check_stmt(checker, v.init)
		}

		cond := check_expr(checker, v.cond)
		if cond.type.kind != .Bool {
			error(checker, cond, "expected a boolean expression in if statement condition but got expression of type %v", cond.type)
		}

		then_diverging := check_stmt_list(checker, v.then_block)
		else_diverging := check_stmt_list(checker, v.else_block)
		return then_diverging && else_diverging
	case ^ast.Stmt_When:
		cond := check_expr(checker, v.cond)
		if c, ok := cond.value.(bool); ok {
			if c {
				return check_stmt_list(checker, v.then_block, true)
			} else {
				return check_stmt_list(checker, v.else_block, true)
			}
		} else {
			error(checker, cond, "expected a constant boolean expression in when statement condition")
		}
		return false

	case ^ast.Stmt_Switch:
		scope_push(checker, .Block).label = v.label
		defer scope_pop(checker)

		if v.init != nil {
			check_stmt(checker, v.init)
		}

		cond            := check_expr(checker, v.cond)
		cond.type        = types.default_type(cond.type)
		seen_default    := false
		v.constant_cases = true
		for c in v.cases {
			if c.value == nil {
				if seen_default {
					error(checker, c.token, "switch statement can only have one default case")
					seen_default = true
				}

				scope_push(checker, .Switch).label = v.label
				defer scope_pop(checker)

				check_stmt_list(checker, c.body)
				continue
			}

			scope_push(checker, .Switch).label = v.label
			defer scope_pop(checker)

			value := check_expr(checker, c.value, type_hint = cond.type)
			if !types.implicitly_castable(value.type, cond.type) {
				error(checker, value, "type of case value does not match selector type: %v vs %v", cond.type, value.type)
			}
			if value.mode != .Const {
				v.constant_cases = false
			}
			check_stmt_list(checker, c.body)
		}

	case ^ast.Stmt_Assign:
		lhs := make([]Operand, len(v.lhs), checker.allocator)
		for &lhs, i in lhs {
			lhs = check_expr(checker, v.lhs[i])
		}

		for &l in lhs {
			if l.mode != .LValue {
				error(checker, l, "cannot assign to %s expression", addressing_mode_string[l.mode])
			}
		}

		v.types = make([]^types.Type, len(lhs), checker.allocator)

		lhs_i := 0
		check_assignment_types: for &r_expr in v.rhs {
			type_hint: ^types.Type
			if lhs_i < len(lhs) {
				type_hint = lhs[lhs_i].type
			}
			r := check_expr(checker, r_expr, type_hint = type_hint)
			if r.type.kind == .Tuple {
				for field in r.type.variant.(^types.Struct).fields {
					if lhs_i >= len(lhs) {
						lhs_i += 1
						continue
					}
					if !types.implicitly_castable(field.type, lhs[lhs_i].type) {
						error(checker, v, "mismatched types in assign statement: %v vs %v", lhs[lhs_i].type, field.type)
					}
					v.types[lhs_i] = types.op_result_type(lhs[lhs_i].type, field.type)
					lhs_i         += 1
				}
			} else {
				if lhs_i >= len(lhs) {
					lhs_i += 1
					continue
				}
				result_type := types.op_result_type(lhs[lhs_i].type, r.type)
				if !types.implicitly_castable(r.type, lhs[lhs_i].type) {
					error(checker, v, "mismatched types in assign statement: %v vs %v", lhs[lhs_i].type, r.type)
				}
				v.types[lhs_i] = result_type
				r_expr.type    = result_type
				lhs_i         += 1
			}
		}
		if lhs_i != len(lhs) {
			error(checker, v, "assignment count mismatch: %v vs %v", len(lhs), lhs_i)
		}
		
	case ^ast.Stmt_Expr:
		operand := check_expr(checker, v.expr, allow_no_value = true)
		if !operand.is_call {
			error(checker, v.expr, "expression is not used")
		}
		if operand.builtin_id == .Discard {
			return true
		}

	case ^ast.Decl_Value:
		if checker.scope.kind == .Global || !v.mutable {
			break
		}

		check_decl_attributes(checker, v, false)

		names  := make([]tokenizer.Token, len(v.lhs),    checker.allocator)
		values := make([]Operand,         len(v.values), checker.allocator)

		for &name, i in names {
			if ident, ok := v.lhs[i].derived_expr.(^ast.Expr_Ident); ok {
				name = ident.ident
			} else {
				error(checker, v.lhs[i], "variable declaration must be an identifier")
			}
		}

		explicit_type: ^types.Type
		if v.type_expr != nil {
			explicit_type = check_type(checker, v.type_expr)
		}

		for &values, i in values {
			values = check_expr(checker, v.values[i], stmt.attributes, explicit_type)
		}

		v.types = make([]^types.Type, len(v.lhs), checker.allocator)

		flags: Entity_Flags = { .Resolved, }
		if v.readonly {
			flags += { .Readonly, }
		}
		if len(values) == 0 {
			if explicit_type == nil {
				explicit_type = types.t_invalid
			}
			check_decl_interface_type(checker, v, explicit_type)
			for name in names {
				entity_kind := Entity_Kind.Var
				scope_insert_entity(checker, entity_new(entity_kind, name, explicit_type, decl = v, flags = flags, allocator = checker.allocator))
			}
			for &t in v.types {
				t = explicit_type
			}
			return
		}

		name_i := 0
		check_decl_types: for &r in values {
			if r.type.kind == .Tuple {
				for field in r.type.variant.(^types.Struct).fields {
					if name_i >= len(names) {
						name_i += 1
						continue
					}
					name        := names[name_i]
					entity_kind := Entity_Kind.Var

					type := explicit_type
					if type == nil {
						type = field.type
						if entity_kind != .Const {
							type = types.default_type(type)
						}
					} else {
						if !types.implicitly_castable(field.type, explicit_type) {
							error(checker, stmt, "mismatched types in value declaration: %v vs %v", explicit_type, field.type)
						}
					}
					v.types[name_i] = type

					scope_insert_entity(checker, entity_new(
						entity_kind,
						name,
						type,
						decl      = v,
						flags     = flags,
						allocator = checker.allocator,
					))
					name_i += 1
				}
			} else {
				if name_i >= len(names) {
					name_i += 1
					continue
				}
				name        := names[name_i]
				entity_kind := Entity_Kind.Var
				value: types.Const_Value

				type := explicit_type
				if type == nil {
					type = r.type
					if entity_kind != .Const {
						type = types.default_type(type)
					}
				} else {
					if !types.implicitly_castable(r.type, explicit_type) {
						error(checker, stmt, "mismatched types in value declaration: %v vs %v", explicit_type, r.type)
					}
				}
				v.types[name_i]       = type
				v.values[name_i].type = type

				scope_insert_entity(checker, entity_new(
					entity_kind,
					name,
					type,
					value     = value,
					decl      = v,
					flags     = flags,
					allocator = checker.allocator,
				))
				name_i += 1
			}
		}
		if name_i != len(names) {
			error(checker, v, "assignment count mismatch: %v vs %v", len(names), name_i)
		}
	case ^ast.Decl_Import:
	}

	diverging = false
	return
}

check_decl_interface_type :: proc(checker: ^Checker, decl: ^ast.Decl_Value, type: ^types.Type) {
	@(static, rodata)
	interface_kind_names := [ast.Interface_Kind]string {
		.None           = "none",
		.Uniform        = "uniform",
		.Uniform_Buffer = "uniform buffer",
		.Push_Constant  = "push constant",
		.Storage_Buffer = "storage buffer",
	}

	if decl.interface == .None || type == nil || type.kind == .Invalid {
		return
	}

	location_required := false
	binding_required  := false

	switch decl.interface {
	case .Uniform:
		location_required = true

		if decl.binding != -1 {
			location_required = false
			binding_required  = true
		}
	case .Uniform_Buffer:
		binding_required = true
	case .Storage_Buffer:
		binding_required = true
	case .Push_Constant:
	case .None:
		unreachable()
	}

	if binding_required && decl.binding == -1 {
		if .Auto_Bind_Uniforms in checker.flags {
			decl.binding             = checker.current_binding
			checker.current_binding += 1
		} else {
			error(
				checker,
				decl,
				"variable with '%s' attribute requires an explicit binding to be specified",
				interface_kind_names[decl.interface],
			)
		}
	}

	if location_required && decl.location == -1 {
		if .Auto_Map_Locations in checker.flags {
			decl.location             = checker.current_location
			checker.current_location += 1
		} else {
			error(
				checker,
				decl,
				"variable with '%s' attribute requires an explicit location to be specified",
				interface_kind_names[decl.interface],
			)
		}
	}

	if decl.interface == .Uniform {
		if types.is_buffer(type) || types.is_struct(type) {
			error(checker, decl.type_expr, "type of uniform variable can not be a composite type")
		}
	} else {
		if !(types.is_buffer(type) || types.is_struct(type)) {
			error(checker, decl.type_expr, "type of %s variable has to be a composite type", interface_kind_names[decl.interface])
		}
	}

	if .Enable_Reflection not_in checker.flags {
		return
	}
	
	for lhs in decl.lhs {
		ident := lhs.derived_expr.(^ast.Expr_Ident).ident.text
		checker.reflection.interface[ident] = {
			type      = type,
			interface = decl.interface,
			binding   = decl.binding,
			location  = decl.location,
		}
	}
}

check_decl_attributes :: proc(checker: ^Checker, decl: ^ast.Decl_Value, constant: bool) {
	decl.location = -1
	decl.binding  = -1
	seen := make(map[string]struct{}, context.temp_allocator)

	@(static, rodata)
	interface_kind_names := [ast.Interface_Kind]string {
		.None           = "none",
		.Uniform        = "uniform",
		.Uniform_Buffer = "uniform_buffer",
		.Push_Constant  = "push_constant",
		.Storage_Buffer = "storage_buffer",
	}

	for a in decl.attributes {
		if a.ident.text in seen {
			error(checker, a.ident, "duplicate attribute: '%v'", a.ident.text)
		}
		seen[a.ident.text] = {}

		switch a.ident.text {
		case "uniform_buffer":
			if decl.interface != nil {
				error(checker, a.ident, "the '%s' and '%s' attributes are mutually exclusive", interface_kind_names[decl.interface], a.ident.text)
			} else {
				decl.interface = .Uniform_Buffer
			}
			if a.value != nil {
				error(checker, a.value, "'%s' attribute does not accept a value", a.ident.text)
			}
		case "uniform":
			if decl.interface != nil {
				error(checker, a.ident, "the '%s' and '%s' attributes are mutually exclusive", interface_kind_names[decl.interface], a.ident.text)
			} else {
				decl.interface = .Uniform
			}
			if a.value != nil {
				error(checker, a.value, "'%s' attribute does not accept a value", a.ident.text)
			}
		case "storage_buffer":
			if decl.interface != nil {
				error(checker, a.ident, "the '%s' and '%s' attributes are mutually exclusive", interface_kind_names[decl.interface], a.ident.text)
			} else {
				decl.interface = .Storage_Buffer
			}
			if a.value != nil {
				error(checker, a.value, "'%s' attribute does not accept a value", a.ident.text)
			}
		case "push_constant":
			if decl.interface != nil {
				error(checker, a.ident, "the '%s' and '%s' attributes are mutually exclusive", interface_kind_names[decl.interface], a.ident.text)
			} else {
				decl.interface = .Push_Constant
			}
			if a.value != nil {
				error(checker, a.value, "'%s' attribute does not accept a value", a.ident.text)
			}
		case "readonly":
			decl.readonly = true
			if a.value != nil {
				error(checker, a.value, "'%s' attribute does not accept a value", a.ident.text)
			}
		case "binding":
			if a.value == nil {
				error(checker, a.ident, "'binding' attribute requires a value")
				break
			}
			value := check_expr(checker, a.value)
			if val, ok := value.value.(i64); ok && val >= 0 {
				decl.binding = int(val)
			} else {
				error(checker, value, "'binding' attribute value must be a constant non-negative integer")
			}
		case "location":
			if a.value == nil {
				error(checker, a.ident, "'location' attribute requires a value")
				break
			}
			value := check_expr(checker, a.value)
			if val, ok := value.value.(i64); ok && val >= 0 {
				decl.location = int(val)
			} else {
				error(checker, value, "'location' attribute value must be a constant non-negative integer")
			}
		case "descriptor_set":
			if a.value == nil {
				error(checker, a.ident, "'descriptor_set' attribute requires a value")
				break
			}
			value := check_expr(checker, a.value)
			if val, ok := value.value.(i64); ok && val >= 0 {
				decl.descriptor_set = int(val)
			} else {
				error(checker, value, "'descriptor_set' attribute value must be a constant non-negative integer")
			}
		case "link_name":
			if a.value == nil {
				error(checker, a.ident, "'link_name' attribute requires a value")
				break
			}
			value := check_expr(checker, a.value)
			if val, ok := value.value.(string); ok {
				decl.link_name = val
			} else {
				error(checker, value, "'descriptor_set' attribute value must be a constant string")
			}
		case "local_size":
			if a.value == nil {
				error(checker, a.ident, "'local_size' attribute requires a value")
				break
			}
			if comp, ok := a.value.derived_expr.(^ast.Expr_Compound); ok {
				if len(comp.fields) != 3 {
					error(checker, a.value, "'local_size' attribute value must be a compount literal of three constant integers")
					break
				}
				for field, i in comp.fields {
					value := check_expr(checker, field.value)
					if x, ok := value.value.(i64); ok {
						if x <= 0 {
							error(checker, field.value, "'local_size' values must be positive integers, got %v", x)
						}
						decl.local_size[i] = i32(x)
					} else {
						error(checker, field.value, "'local_size' values must be constant integers, got %v", value.type)
					}
				}
			} else {
				error(checker, a.value, "'local_size' attribute value must be a compount literal of three constant integers")
			}
		case:
			found: bool
			for name, stage in ast.shader_stage_names {
				if name == a.ident.text {
					if decl.shader_stage != nil {
						error(checker, a.ident, "procedures can only be annotated with one shader stage")
					}
					decl.shader_stage = stage
					found             = true
					break
				}
			}
			if !found {
				error(checker, a.ident, "unknown attribute '%s' in value declaration", a.ident.text)
			}
		}
	}

	if decl.shader_stage == .Compute {
		if decl.local_size == 0 {
			decl.local_size = 1
		}
	} else if decl.local_size != 0 {
		error(checker, decl, "'local_size' attribute can only be applied to compute shaders")
	}

	if decl.interface == .None {
		if decl.location != -1 {
			error(checker, decl, "attribute 'location' can only be applied to interface variables")
		}
		if decl.binding != -1 {
			error(checker, decl, "attribute 'binding' can only be applied to interface variables")
		}
		if decl.descriptor_set != 0 {
			error(checker, decl, "attribute 'descriptor_set' can only be applied to interface variables")
		}
	} else {
		if len(decl.values) != 0 {
			error(
				checker,
				decl,
				"variable with '%s' attribute can not have any values",
				interface_kind_names[decl.interface],
			)
		} else if len(decl.lhs) != 1 {
			error(
				checker,
				decl,
				"attribute '%s' can not be applied to a declaration of multiple variables",
				interface_kind_names[decl.interface],
			)
		}
	}
}

collect_decls :: proc(checker: ^Checker, stmts: []^ast.Stmt, global: bool, entities: ^[dynamic]^Entity) {
	for stmt in stmts {
		if v, ok := stmt.derived_stmt.(^ast.Decl_Import); ok {
			if checker.scope.kind != .Global {
				error(checker, v, "Imports must be placed at file scope")
				return
			}

			library_name := v.library.text[1:len(v.library.text) - 1]
			if library, ok := checker.libraries[library_name]; !ok {
				error(checker, v.library, "Imported library does not exist: \"%v\"", library_name)
			} else {
				t        := v.library
				t.text    = library_name
				e        := entity_new(.Library, t, nil, allocator = checker.allocator)
				e.library = library_name
				e.flags   = { .Resolved, }
				scope_insert_entity(checker, e)
			}
			continue
		}
		d, ok := stmt.derived_stmt.(^ast.Decl_Value)
		if !ok {
			continue
		}
		if d.mutable && !global {
			continue
		}

		check_decl_attributes(checker, d, true)

		d.types = make([]^types.Type, len(d.lhs), checker.allocator)

		names := make([]tokenizer.Token, len(d.lhs), checker.allocator)
		for &name, i in names {
			if ident, ok := d.lhs[i].derived_expr.(^ast.Expr_Ident); ok {
				name = ident.ident
			} else {
				error(checker, d.lhs[i], "variable declaration must be an identifier")
			}
		}

		flags: Entity_Flags
		if d.readonly {
			flags += { .Readonly, }
		}
		entity_kind := Entity_Kind.Invalid
		for name in names {
			type := types.new_any(checker.allocator)
			e    := entity_new(entity_kind, name, type, decl = d, flags = flags, allocator = checker.allocator)
			scope_insert_entity(checker, e)
			append(entities, e)
		}
	}

	for stmt in stmts {
		v    := stmt.derived_stmt.(^ast.Stmt_When) or_continue
		cond := check_expr(checker, v.cond)
		if c, ok := cond.value.(bool); ok {
			if c {
				collect_decls(checker, v.then_block, global, entities)
			} else {
				collect_decls(checker, v.else_block, global, entities)
			}
		} else {
			error(checker, cond, "expected a constant boolean expression in when statement condition")
		}
	}
}

resolve_constant :: proc(checker: ^Checker, e: ^Entity) {
	if .Resolved in e.flags {
		return
	}
	if .In_Progress in e.flags {
		error(checker, e.ident, "illegal dependency cycle")
		e.flags += { .Resolved, }
		return
	}
	e.flags += { .In_Progress, }

	defer {
		e.flags -= { .In_Progress, }
		e.flags += { .Resolved, }
	}

	assert(e.decl != nil)
	d           := e.decl.derived_decl.(^ast.Decl_Value)
	value_index := -1
	for lhs, i in d.lhs {
		ident := lhs.derived_expr.(^ast.Expr_Ident) or_else {}
		if ident.ident.text == e.name {
			value_index = i
			break
		}
	}
	assert(value_index != -1)

	type: ^types.Type
	if d.type_expr != nil {
		type = check_type(checker, d.type_expr)
	}

	assign_type :: proc(dst, src: ^types.Type) {
		size := size_of(types.Type)
		switch v in src.variant {
		case ^types.Struct:
			size = size_of(types.Struct)
		case ^types.Matrix:
			size = size_of(types.Matrix)
		case ^types.Vector:
			size = size_of(types.Vector)
		case ^types.Buffer:
			size = size_of(types.Buffer)
		case ^types.Proc:
			size = size_of(types.Proc)
		case ^types.Image:
			size = size_of(types.Image)
		case ^types.Enum:
			size = size_of(types.Enum)
		case ^types.Bit_Set:
			size = size_of(types.Bit_Set)
		case ^types.Complex:
			size = size_of(types.Complex)
		}
		mem.copy(dst, src, size)
	}

	if len(d.values) == 0 {
		check_decl_interface_type(checker, e.decl.derived_decl.(^ast.Decl_Value), type)
		e.kind               = .Var
		d.types[value_index] = type
		assign_type(e.type, type)
		return
	}

	v := check_expr_or_type(checker, d.values[value_index], d.attributes, type)

	#partial switch v.mode {
	case .Type:
		e.kind = .Type
	case .Proc:
		e.kind = .Proc
	case .Const:
		if d.mutable {
			e.kind  = .Var
		} else {
			e.kind  = .Const
			e.value = v.value
		}
	case:
		if d.mutable {
			error(checker, v, "Expected a constant expression in global variable declaration")
		} else {
			error(checker, v, "Expected a constant expression or type in constant declaration")
		}
		e.kind = .Invalid
	}

	if type == nil {
		type = v.type
		if e.kind != .Const {
			type = types.default_type(type)
		}
	} else {
		if !types.implicitly_castable(v.type, type) {
			error(checker, v, "mismatched types in value declaration: %v vs %v", type, v.type)
		}
	}

	if .Enable_Reflection not_in checker.flags && d.shader_stage != nil {
		type    := type.variant.(^types.Proc)
		inputs  := make([]Reflection_Info, len(type.args),    checker.allocator)
		outputs := make([]Reflection_Info, len(type.returns), checker.allocator)

		for input, i in type.args {
			inputs[i] = {
				type     = input.type,
				location = input.location,
			}
		}

		for output, i in type.returns {
			outputs[i] = {
				type     = output.type,
				location = output.location,
			}
		}

		checker.reflection.entry_points[e.ident.text] = {
			inputs  = inputs,
			outputs = outputs,
			stage   = d.shader_stage,
		}
	}

	d.types[value_index]       = type
	d.values[value_index].type = type

	assign_type(e.type, type)
}

check_const_stmts :: proc(checker: ^Checker, stmts: []^ast.Stmt) {
	entities := make([dynamic]^Entity, context.temp_allocator)
	collect_decls(checker, stmts, checker.scope.kind == .Global, &entities)
	for e in entities {
		resolve_constant(checker, e)
	}
}

check_stmt_list :: proc(checker: ^Checker, stmts: []^ast.Stmt, ignore_constants := false) -> (diverging: bool) {
	if !ignore_constants {
		check_const_stmts(checker, stmts)
	}

	for stmt, i in stmts {
		d := check_stmt(checker, stmt)
		if d && !diverging && i != len(stmts) - 1 {
			error(checker, stmt, "statements after this statement are never executed")
			diverging = true
		}
	}

	return diverging
}

@(private = "file")
checker_init :: proc(
	checker:       ^Checker,
	defines:       map[string]types.Const_Value,
	shared_types:  []Shared_Type,
	libraries:     map[string]Library,
	flags:         Flags,
	allocator       := context.allocator,
	error_allocator := context.allocator,
) {
	checker.allocator                         = allocator
	checker.reflection.interface.allocator    = allocator
	checker.reflection.entry_points.allocator = allocator
	checker.error_allocator                   = error_allocator
	checker.errors                            = make([dynamic]tokenizer.Error, error_allocator)
	checker.flags                             = flags
	checker.libraries                         = libraries

	scope_push(checker, .Global)

	scope_insert_entity(checker, entity_new(.Type, { text = "bool", }, types.t_bool, allocator = allocator))

	scope_insert_entity(checker, entity_new(.Type, { text = "i8",   }, types.t_i8 ,  allocator = allocator))
	scope_insert_entity(checker, entity_new(.Type, { text = "i16",  }, types.t_i16,  allocator = allocator))
	scope_insert_entity(checker, entity_new(.Type, { text = "i32",  }, types.t_i32,  allocator = allocator))
	scope_insert_entity(checker, entity_new(.Type, { text = "i64",  }, types.t_i64,  allocator = allocator))

	scope_insert_entity(checker, entity_new(.Type, { text = "u8",   }, types.t_u8 ,  allocator = allocator))
	scope_insert_entity(checker, entity_new(.Type, { text = "u16",  }, types.t_u16,  allocator = allocator))
	scope_insert_entity(checker, entity_new(.Type, { text = "u32",  }, types.t_u32,  allocator = allocator))
	scope_insert_entity(checker, entity_new(.Type, { text = "u64",  }, types.t_u64,  allocator = allocator))

	scope_insert_entity(checker, entity_new(.Type, { text = "f16",  }, types.t_f16,  allocator = allocator))
	scope_insert_entity(checker, entity_new(.Type, { text = "f32",  }, types.t_f32,  allocator = allocator))
	scope_insert_entity(checker, entity_new(.Type, { text = "f64",  }, types.t_f64,  allocator = allocator))

	scope_insert_entity(checker, entity_new(.Type, { text = "complex64",  }, types.t_complex64,  allocator = allocator))
	scope_insert_entity(checker, entity_new(.Type, { text = "complex128", }, types.t_complex128, allocator = allocator))

	scope_insert_entity(checker, entity_new(.Type, { text = "quaternion128", }, types.t_quaternion128, allocator = allocator))
	scope_insert_entity(checker, entity_new(.Type, { text = "quaternion256", }, types.t_quaternion256, allocator = allocator))

	for name, builtin in builtin_names {
		scope_insert_entity(checker, entity_new(.Builtin, { text = name, }, nil, builtin_id = builtin, allocator = allocator))
	}

	checker.shared_types.allocator = allocator
	for s in shared_types {
		// scope_insert_entity(checker, entity_new(.Type, { text = s.name, }, s.type, allocator = allocator))
		checker.shared_types[s.name] = s.type
	}

	for _, &e in checker.scope.elements {
		e.flags += { .Resolved, }
	}

	checker.config_vars = defines
}

@(require_results)
type_info_to_type :: proc(ti: ^reflect.Type_Info, allocator := context.allocator) -> ^types.Type {
	switch v in ti.variant {
	case reflect.Type_Info_Named:
		return type_info_to_type(v.base, allocator)
	case reflect.Type_Info_Integer:
		switch ti.size {
		case 1:
			return types.t_i8  if v.signed else types.t_u8
		case 2:
			return types.t_i16 if v.signed else types.t_u16
		case 4:
			return types.t_i32 if v.signed else types.t_u32
		case 8:
			return types.t_i64 if v.signed else types.t_u64
		case:
			fmt.panicf("integer types have to be either 1, 2, 4 or 8 bytes wide, got %v", ti.size)
		}
	case reflect.Type_Info_Rune:
		return types.t_i32
	case reflect.Type_Info_Float:
		switch ti.size {
		case 4:
			return types.t_f32
		case 8:
			return types.t_f64
		case:
			fmt.panicf("float types have to be either 4 or 8 bytes wide, got %v", ti.size)
		}
	case reflect.Type_Info_Complex:
		elem: ^types.Type
		switch ti.size {
		case 8:
			elem = types.t_f32
		case 16:
			elem = types.t_f64
		case:
			fmt.panicf("complex types have to be either 8 or 16 bytes wide, got %v", ti.size)
		}
		return types.vector_new(elem, 2, allocator)
	case reflect.Type_Info_Quaternion:
		elem: ^types.Type
		switch ti.size {
		case 16:
			elem = types.t_f32
		case 32:
			elem = types.t_f64
		case:
			fmt.panicf("quaternion types have to be either 16 or 32 bytes wide, got %v", ti.size)
		}
		return types.vector_new(elem, 4, allocator)
	case reflect.Type_Info_String:
		panic("string types can not be shared")
	case reflect.Type_Info_Boolean:
		switch ti.size {
		case 1:
			return types.t_bool
		case 2:
			return types.t_i16
		case 4:
			return types.t_i32
		case 8:
			return types.t_i64
		case:
			fmt.panicf("boolean types have to be either 1, 2, 4 or 8 bytes wide, got %v", ti.size)
		}
	case reflect.Type_Info_Any:
		panic("any types can not be shared")
	case reflect.Type_Info_Type_Id:
		panic("typeid types can not be shared")
	case reflect.Type_Info_Pointer:
		panic("pointer types can not be shared")
	case reflect.Type_Info_Multi_Pointer:
		panic("multi pointer types can not be shared")
	case reflect.Type_Info_Procedure:
		panic("procedure types can not be shared")
	case reflect.Type_Info_Array:
		return types.vector_new(type_info_to_type(v.elem, allocator), v.count, allocator)
	case reflect.Type_Info_Enumerated_Array:
		unimplemented()
	case reflect.Type_Info_Dynamic_Array, reflect.Type_Info_Fixed_Capacity_Dynamic_Array:
		panic("dynamic array types can not be shared")
	case reflect.Type_Info_Slice:
		panic("slice types can not be shared")
	case reflect.Type_Info_Parameters:
		panic("???")
	case reflect.Type_Info_Struct:
		if .raw_union in v.flags {
			if v.field_count != 2 {
				panic("structs with the #raw_union can not be shared")
			}
			if ti.size != 8 {
				panic("structs with the #raw_union can not be shared")
			}
			tag, ok := reflect.struct_tag_lookup(auto_cast v.tags[1], "hephaistos")
			if !ok {
				panic("structs with the #raw_union can not be shared")
			}
			if tag != "buffer_device_address" {
				panic("structs with the #raw_union can not be shared")
			}
			ptr  := v.types[1].variant.(reflect.Type_Info_Pointer)
			elem := type_info_to_type(ptr.elem, allocator)
			return types.buffer_new(elem, true, allocator)
		}
		fields := make([]types.Field, v.field_count, allocator)
		for &f, i in fields {
			f.name.text = v.names[i]
			f.type      = type_info_to_type(v.types[i], allocator)
			f.offset    = int(v.offsets[i])
		}
		s       := types.new(.Struct, types.Struct, allocator)
		s.size   = ti.size
		s.align  = ti.align
		s.fields = fields
		return s
	case reflect.Type_Info_Union:
		panic("union types can not be shared")
	case reflect.Type_Info_Enum:
		e      := types.new(.Enum, types.Enum, allocator)
		values := make([]types.Enum_Value, len(v.values), allocator)
		for value, i in v.values {
			values[i] = {
				value = int(value),
				name  = { text = v.names[i], },
			}
		}
		e.backing = type_info_to_type(v.base, allocator)
		e.size    = e.backing.size
		e.align   = e.backing.align
		e.values  = values
		return e
	case reflect.Type_Info_Map:
		panic("map types can not be shared")
	case reflect.Type_Info_Bit_Set:
		return type_info_to_type(v.underlying, allocator)
	case reflect.Type_Info_Simd_Vector:
		return types.vector_new(type_info_to_type(v.elem, allocator), v.count, allocator)
	case reflect.Type_Info_Matrix:
		elem := type_info_to_type(v.elem, allocator)
		col  := types.vector_new(elem, v.row_count, allocator)
		return types.matrix_new(col, v.column_count, allocator)
	case reflect.Type_Info_Soa_Pointer:
		panic("soa pointer types can not be shared")
	case reflect.Type_Info_Bit_Field:
		return type_info_to_type(v.backing_type, allocator)
	}
	unreachable()
}

Shared_Type :: struct {
	name: string,
	type: ^types.Type,
}

@(require_results)
shared_types_from_typeids :: proc(typeids: []typeid, allocator := context.allocator) -> []Shared_Type {
	output := make([]Shared_Type, len(typeids), allocator)
	for t, i in typeids {
		ti    := type_info_of(t)
		named := ti.variant.(reflect.Type_Info_Named) or_else panic("only named types can be shared")
		type  := type_info_to_type(named.base, allocator)
		output[i] = { name = named.name, type = type}
	}
	return output
}

@(require_results)
check_library :: proc(
	stmts:     []^ast.Stmt,
	defines:   map[string]types.Const_Value,
	types:     []typeid,
	libraries: map[string]Library,
	flags           := Flags{},
	allocator       := context.allocator,
	error_allocator := context.allocator,
) -> (checker: Checker, errors: []tokenizer.Error) {
	return
}

@(require_results)
check :: proc(
	stmts:     []^ast.Stmt,
	defines:   map[string]types.Const_Value,
	types:     []typeid,
	libraries: map[string]Library,
	flags           := Flags{},
	allocator       := context.allocator,
	error_allocator := context.allocator,
) -> (checker: Checker, errors: []tokenizer.Error) {
	shared_types := shared_types_from_typeids(types, allocator)
	checker_init(&checker, defines, shared_types, libraries, flags, allocator, error_allocator)
	check_stmt_list(&checker, stmts)
	return checker, checker.errors[:]
}

@(require_results)
op_is_relation :: proc(token_kind: tokenizer.Token_Kind) -> bool {
	#partial switch token_kind {
	case .Equal, .Not_Equal, .Less_Equal, .Greater_Equal, .Less, .Greater:
		return true
	}
	return false
}

@(require_results)
evaluate_const_binary_op :: proc(checker: ^Checker, lhs, rhs: types.Const_Value, expr: ^ast.Expr_Binary) -> types.Const_Value {
	assert(lhs != nil)
	assert(rhs != nil)

	lhs := lhs
	rhs := rhs

	lhs_tag := (^intrinsics.type_union_tag_type(types.Const_Value))(uintptr(&lhs) + intrinsics.type_union_tag_offset(types.Const_Value))^
	rhs_tag := (^intrinsics.type_union_tag_type(types.Const_Value))(uintptr(&rhs) + intrinsics.type_union_tag_offset(types.Const_Value))^

	// Const_Value :: union {
	// 	i64,  tag = 1
	// 	f64,  tag = 2
	// 	bool, tag = 3
	// }
	if lhs_tag != rhs_tag {
		if lhs_tag < 3 && rhs_tag < 3 {
			if lhs_int, ok := lhs.(i64); ok {
				lhs = f64(lhs_int)
			} else if rhs_int, ok := rhs.(i64); ok {
				rhs = f64(rhs_int)
			}
		}
	}

	type_assert_2 :: proc(lhs, rhs: $V, $T: typeid) -> (T, T, bool) {
		x, x_ok := lhs.(T)
		y, y_ok := rhs.(T)
		return x, y, x_ok & y_ok
	}

	if l, r, ok := type_assert_2(lhs, rhs, i64); ok {
		#partial switch expr.op {
		case .Bit_And:
			return l & r
		case .Bit_Or:
			return l | r
		case .Xor:
			return l ~ r
		case .Add:
			return l + r
		case .Subtract:
			return l - r
		case .Multiply:
			return l * r
		case .Divide:
			if r == 0 {
				error(checker, expr, "division by zero")
				return nil
			}
			return l / r
		case .Modulo:
			if r == 0 {
				error(checker, expr, "modulo with zero")
				return nil
			}
			return l % r
		case .Modulo_Floored:
			if r == 0 {
				error(checker, expr, "modulo with zero")
				return nil
			}
			return l %% r
		case .Less:
			return l < r
		case .Greater:
			return l > r

		case .Equal:
			return l == r
		case .Not_Equal:
			return l != r
		case .Less_Equal:
			return l <= r
		case .Greater_Equal:
			return l >= r

		case .Shift_Left:
			if r < 0 {
				error(checker, expr, "shift by a negative amount: %v < 0", r)
			}
			return l << uint(r)
		case .Shift_Right:
			if r < 0 {
				error(checker, expr, "shift by a negative amount: %v < 0", r)
			}
			return l >> uint(r)
		}
	}

	if l, r, ok := type_assert_2(lhs, rhs, f64); ok {
		#partial switch expr.op {
		case .Add:
			return l + r
		case .Subtract:
			return l - r
		case .Multiply:
			return l * r
		case .Divide:
			return l / r
		case .Less:
			return l < r
		case .Greater:
			return l > r

		case .Equal:
			return l == r
		case .Not_Equal:
			return l != r
		case .Less_Equal:
			return l <= r
		case .Greater_Equal:
			return l >= r
		}
	}

	if l, r, ok := type_assert_2(lhs, rhs, bool); ok {
		#partial switch expr.op {
		case .Bit_And:
			return l & r
		case .Bit_Or:
			return l | r
		case .Xor:
			return l ~ r
		case .Equal:
			return l == r
		case .Not_Equal:
			return l != r
		case .And:
			return l && r
		case .Or:
			return l || r
		}
	}

	error(checker, expr, "mismatched types in constant binary expression: %v vs %v", lhs, rhs)
	return nil
}

@(require_results)
check_proc_type :: proc(checker: ^Checker, p: $T) -> ^types.Proc {
	check_field_list :: proc(checker: ^Checker, fields: []ast.Field, usage: string) -> (out_fields: [dynamic]types.Field) {
		out_fields.allocator = checker.allocator
		reserve(&out_fields, len(fields))

		locations          := make(map[int]tokenizer.Token, context.temp_allocator)
		names_seen         := make(map[string]struct{},     context.temp_allocator)
		explicit_locations := false

		for i := 0; i < len(fields); {
			start := i
			type: ^types.Type
			for i < len(fields) {
				defer i += 1
				field := fields[i]
				if field.ident.text in names_seen {
					error(checker, field.ident, "duplicate name: '%s'", field.ident.text)
					return
				}
				names_seen[field.ident.text] = {}

				location := i
				if field.location != nil {
					// TODO: matrices with mutliple locations

					loc := check_expr(checker, field.location)
					if l, ok := loc.value.(i64); ok && l != -1 {
						if i == 0 {
							explicit_locations = true
						}

						if !explicit_locations {
							error(checker, field.location, "location specifiers have to be specified for either all or none of the %ss", usage)
						}

						location = int(l)

						if prev, prev_found := locations[location]; prev_found {
							error(checker, field.location, "duplicate location specifier: location %v is already used by '%s'", location, prev.text)
						}
						locations[location] = field.ident
					} else {
						error(checker, field.location, "location specifier has to be a constant integer")
					}
				} else {
					if explicit_locations {
						error(checker, field.ident, "location specifiers have to be specified for either all or none of the %ss", usage)
					}
				}

				append(&out_fields, types.Field {
					name     = field.ident,
					type     = nil, // patched later
					location = location,
				})
				
				if field.type == nil {
					if field.value != nil {
						type = check_expr(checker, field.value).type
						break
					}
					continue
				}

				type = check_type(checker, field.type)

				if field.value == nil {
					break
				}

				if i != start {
					error(checker, field.value, "default values can only be applied to single values")
				}

				value := check_expr(checker, field.value)
				if !types.implicitly_castable(value.type, type) {
					error(
						checker,
						field.ident.location,
						field.value.end,
						"default value type does not match declared type: %v vs %v",
						type,
						value.type,
					)
				}
				break
			}

			for i in start ..< i {
				out_fields[i].type = type
			}
		}

		return
	}

	args    := check_field_list(checker, p.args,    "input")
	returns := check_field_list(checker, p.returns, "output")

	t        := types.new(.Proc, types.Proc, checker.allocator)
	t.args    = args[:]
	t.returns = returns[:]

	return_type       := types.new(.Tuple, types.Struct, checker.allocator)
	return_type.fields = returns[:]
	t.return_type      = return_type

	return t
}

@(require_results)
check_expr_internal :: proc(checker: ^Checker, expr: ^ast.Expr, attributes: []ast.Field, type_hint: ^types.Type = nil) -> (operand: Operand) {
	operand.expr = expr

	defer {
		expr.type        = operand.type
		expr.const_value = operand.value
	}

	switch v in expr.derived_expr {
	case ^ast.Expr_Constant:
		switch val in v.value {
		case i64:
			operand.type  = types.t_int
			operand.value = val
		case f64:
			operand.type  = types.t_float
			operand.value = val
		case bool:
			operand.type  = types.t_bool
			operand.value = val
		case string:
			operand.type  = types.t_invalid
			operand.value = val
		}

		operand.mode = .RValue
		switch v.imaginary {
		case .i:
			operand.type = types.t_complex64
		case .j, .k:
			operand.type = types.t_quaternion128
		case .real:
			operand.mode = .Const
		}

		return

	case ^ast.Expr_Config:
		default := check_expr(checker, v.default)
		switch _ in default.value {
		case i64, f64, bool:
		case string:
			error(checker, default, "default value for config variable has to be a constant boolean or number, got: %v")
			return
		}
		operand.value = default.value
		if definition, ok := checker.config_vars[v.ident.text]; ok {
			if reflect.get_union_variant_raw_tag(definition) != reflect.get_union_variant_raw_tag(default.value) {
				error(checker, v, "type of defined value does not have same type as the default value")
				return
			}
			operand.value = definition
		}
		operand.type = default.type
		operand.mode = .Const

	case ^ast.Expr_Binary:
		lhs := check_expr(checker, v.lhs)
		rhs := check_expr(checker, v.rhs, type_hint = lhs.type if v.op != .Multiply else nil)

		operand.type = types.op_result_type(lhs.type, rhs.type, v.op == .Multiply, checker.allocator)
		if operand.type.kind == .Invalid {
			error(checker, expr, "mismatched types in binary expression: %v vs %v", lhs.type, rhs.type)
			operand.mode = .Invalid
			return
		}

		if v.op != .Multiply || !(types.is_matrix(lhs.type) || types.is_matrix(rhs.type)) {
			v.lhs.type = operand.type
			v.rhs.type = operand.type
		}

		if !types.operator_applicable(operand.type, v.op) {
			error(checker, v, "operator `%v` is not defined for `%v %v %v`", tokenizer.to_string(v.op), lhs.type, tokenizer.to_string(v.op), rhs.type)
			return
		}

		operand.mode = .RValue
		if lhs.mode == .Const && rhs.mode == .Const {
			operand.mode  = .Const
			operand.value = evaluate_const_binary_op(checker, lhs.value, rhs.value, v)
		}

		if op_is_relation(v.op) {
			operand.type = types.t_bool
			operand.mode = .RValue
		}

	case ^ast.Expr_Ident:
		e, ok := scope_lookup(checker, v.ident.text)
		if !ok {
			error(checker, expr, "unknown identifier: '%s'", v.ident.text)
			operand.type = types.t_invalid
			operand.mode = .Invalid
			return
		}
		return entity_to_operand(e)

	case ^ast.Expr_Interface:
		e, ok := reflect.enum_from_name(spv.BuiltIn, v.ident.text)
		if !ok {
			error(checker, v.ident, "unknown builtin: '%s'", v.ident.text)
			return
		}

		if info, ok := interface_infos[e]; ok {
			switch info.usage[checker.shader_stage] {
			case nil:
				error(checker, v.ident, "builtin %s can not be used in %s", v.ident.text, ast.shader_stage_names[checker.shader_stage])
			case .In:
				operand.mode = .RValue
			case .Out:
				operand.mode = .LValue
			}
			operand.type = info.type
		} else {
			error(checker, v.ident, "unknown builtin: '%s'", v.ident.text)
			return
		}

	case ^ast.Expr_Proc_Lit:
		shader_stage: ast.Shader_Stage
		for attribute in attributes {
			s: ast.Shader_Stage
			for name, kind in ast.shader_stage_names {
				if name == attribute.ident.text {
					s = kind
					break
				}
			}
			if s == nil {
				continue
			}
			if shader_stage != nil {
				error(
					checker,
					attribute.ident,
					"the attributes '%s' and '%s' are mutually exclusive",
					ast.shader_stage_names[shader_stage],
					ast.shader_stage_names[s],
				)
			}
			shader_stage = s
		}

		prev_shader_stage         := checker.shader_stage
		defer checker.shader_stage = prev_shader_stage

		v.shader_stage       = shader_stage
		checker.shader_stage = shader_stage

		type := check_proc_type(checker, v)

		operand.type = type
		operand.mode = .Proc

		scope_push(checker, .Proc).procedure = Scope_Proc_Info { type = type, lit = v, }
		defer scope_pop(checker)

		for arg in type.args {
			if arg.name.text != "" {
				scope_insert_entity(checker, entity_new(.Var, arg.name, arg.type, flags = { .Readonly, .Resolved, }, allocator = checker.allocator))
			}
		}

		scope_push(checker, .Block)
		defer scope_pop(checker)

		for ret in type.returns {
			if ret.name.text != "" {
				scope_insert_entity(checker, entity_new(.Var, ret.name, ret.type, flags = { .Resolved, }, allocator = checker.allocator))
			}
		}
		check_stmt_list(checker, v.body)

	case ^ast.Expr_Proc_Sig:
		operand.type = check_proc_type(checker, v)
		operand.mode = .Type
	case ^ast.Expr_Paren:
		return check_expr_internal(checker, v.expr, {})
	case ^ast.Expr_Selector:
		if v.lhs == nil {
			if type_hint == nil {
				error(checker, v, "missing type in implicit selector")
				return
			}

			if type_hint.kind != .Enum {
				error(checker, v, "implicit selectors can only be used for enum types, got '%v'", type_hint)
				return
			}

			for val in type_hint.variant.(^types.Enum).values {
				if val.name.text == v.selector.text {
					operand.type  = type_hint
					operand.value = i64(val.value)
					operand.mode  = .Const
					return
				}
			}

			error(checker, v, "%s is not a variant of the enum type %v", v.selector.text, type_hint)
			return
		}

		lhs := check_expr_internal(checker, v.lhs, {})

		#partial switch lhs.mode {
		case .Builtin:
			error(checker, operand, "expected an expression, got builtin")
			return
		case .NoValue:
			error(checker, operand, "expected an expression, got no value")
			return
		}

		if lhs.mode == .Library {
			v.library = lhs.library
			if e, ok := checker.libraries[lhs.library].entities[v.selector.text]; ok {
				return entity_to_operand(e)
			} else {
				error(checker, v.selector, "'%s' is not declared by '%s'", v.selector.text, lhs.library)
				return
			}
		}

		if lhs.mode == .Type {
			if lhs.type.kind != .Enum {
				error(checker, v, "expected an expression or an enum type, got '%v'", lhs.type)
				return
			}

			for val in lhs.type.variant.(^types.Enum).values {
				if val.name.text == v.selector.text {
					operand.type  = lhs.type
					operand.value = i64(val.value)
					operand.mode  = .Const
					return
				}
			}

			error(checker, v, "'%s' is not a variant of the enum type '%v'", v.selector.text, lhs.type)
			return
		}

		if lhs.type.kind == .Vector {
			duplicates := false
			seen: [4]bool
			for char in v.selector.text {
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
				if index == -1 || index > types.vector_len(lhs.type) {
					error(checker, v, "can not swizzle vector of type '%s' with coordinate '%v'", lhs.type, char)
				}
				if index != -1 {
					if seen[index] {
						duplicates = true
					}
					seen[index] = true
				}
			}

			if len(v.selector.text) == 1 {
				operand.type = types.vector_elem(lhs.type)
				operand.mode = lhs.mode
				return
			}

			operand.type = types.vector_new(types.vector_elem(lhs.type), len(v.selector.text), checker.allocator)
			operand.mode = lhs.mode
			if duplicates {
				operand.mode = .RValue
			}
			return
		}

		if lhs.type.kind == .Struct {
			for field in lhs.type.variant.(^types.Struct).fields {
				if field.name.text == v.selector.text {
					operand.type = field.type
					operand.mode = lhs.mode
					return
				}
			}
		}
		error(checker, v, "expression of type %v has no field called '%s'", lhs.type, v.selector.text)

	case ^ast.Expr_Call:
		fn := check_expr_internal(checker, v.lhs, {})
		#partial switch fn.mode {
		case .Invalid:
			return
		case .Builtin:
			v.builtin          = fn.builtin_id
			operand.builtin_id = fn.builtin_id

			allow_types := false
			#partial switch v.builtin {
			case .Size_Of, .Align_Of, .Min, .Max:
				allow_types = true
			}
			
			args := make([]Operand, len(v.args), context.temp_allocator)
			for &arg, i in args {
				if allow_types {
					arg = check_expr_or_type(checker, v.args[i].value)
				} else {
					arg = check_expr(checker, v.args[i].value)
				}
			}

			switch v.builtin {
			case .Invalid:
				panic("invalid builtin")
			case .Size_Of, .Align_Of:
				if len(v.args) != 1 {
					error(checker, v, "builtin '%s' expects one argument, got %d", builtin_names[v.builtin], len(v.args))
					break
				}
				type := types.default_type(args[0].type)
				if v.builtin == .Size_Of {
					operand.value = i64(type.size)
				} else {
					operand.value = i64(type.align)
				}
				operand.mode = .Const
				operand.type = types.t_int
			case .Type_Of:
				if len(v.args) != 1 {
					error(checker, v, "builtin '%s' expects one argument, got %d", builtin_names[v.builtin], len(v.args))
					break
				}
				operand.type = args[0].type
				operand.mode = .Type
			case .Dot:
				if len(v.args) != 2 {
					error(checker, v, "builtin 'dot' expects two arguments, got %d", len(v.args))
					break
				}
				a    := args[0]
				b    := args[1]
				type := types.op_result_type(a.type, b.type)
				if !types.is_vector(type) {
					error(checker, v, "builtin 'dot' expects two vectors of the same type, got %v and %v", a.type, b.type)
					break
				}
				v.args[0].value.type = type
				v.args[1].value.type = type
				operand.type = types.vector_elem(type)
				operand.mode = .RValue
			case .Cross:
				if len(v.args) != 2 {
					error(checker, v, "builtin 'cross' expects two arguments, got %d", len(v.args))
					break
				}
				a    := args[0]
				b    := args[1]
				type := types.op_result_type(a.type, b.type)
				if vec, ok := type.variant.(^types.Vector); !ok || vec.count != 3 {
					error(checker, v, "builtin 'cross' expects two 3 dimensional vectors, got %v and %v", a.type, b.type)
					break
				}
				v.args[0].value.type = type
				v.args[1].value.type = type
				operand.type = type
				operand.mode = .RValue
			case .Min, .Max:
				if len(v.args) < 2 {
					error(checker, v, "builtin '%s' expects at least two arguments", builtin_names[v.builtin])
					break
				}
				type := args[0].type
				for arg in args[1:] {
					prev := type
					type  = types.op_result_type(type, arg.type)
					if type.kind == .Invalid {
						error(checker, arg, "builtin '%s' expects all arguments to be of the same type, expected %v, got %v", builtin_names[v.builtin], prev, arg.type)
						return
					}
				}
				for &arg in v.args {
					arg.value.type = type
				}
				if !types.is_numeric(type) && !types.is_vector(type) {
					error(checker, v, "builtin '%s' expects at least two vectors or scalars of the same type, got %v", builtin_names[v.builtin], type)
					break
				}
				operand.type = type
				operand.mode = .RValue
			case .Clamp:
				if len(v.args) != 3 {
					error(checker, v, "builtin 'clamp' expects three arguments, got %d", len(v.args))
					break
				}
				type := args[0].type
				for arg in args[1:] {
					prev := type
					type  = types.op_result_type(type, arg.type)
					if type.kind == .Invalid {
						error(checker, arg, "builtin 'clamp' expects all arguments to be of the same type, expected %v, got %v", prev, arg.type)
						return
					}
				}
				if !types.is_numeric(type) && !types.is_vector(type) {
					error(checker, v, "builtin 'clamp' expects 3 vectors or scalars of the same type, got %v", type)
					break
				}
				for arg in v.args {
					arg.value.type = type
				}
				operand.type = type
				operand.mode = .RValue
			case .Lerp, .Smooth_Step:
				if len(v.args) != 3 {
					error(checker, v, "builtin '%s' expects three arguments, got %d", builtin_names[v.builtin], len(v.args))
					break
				}
				a, b, t := args[0].type, args[1].type, args[2].type
				type    := types.default_type(types.op_result_type(a, b))
				if type.kind == .Invalid {
					error(checker, v, "type mismatch in builtin '%s': %v vs %v", builtin_names[v.builtin], a, b)
					break
				}
				if !types.is_numeric(type) && !types.is_vector(type) {
					error(checker, v, "builtin '%s' expects two vectors or scalars of the same type, got %v", builtin_names[v.builtin], type)
					break
				}
				t_valid := types.is_float(t)
				if types.is_vector(t) && types.is_vector(type) {
					t_valid = types.op_result_type(t, type).kind != .Invalid
				}
				if !t_valid {
					error(checker, v, "builtin '%s' expects a float for the interpolation value, got %v", builtin_names[v.builtin], t)
					break
				}
				for arg in v.args[:2] {
					arg.value.type = type
				}
				v.args[2].value.type = types.default_type(type)
				operand.type         = type
				operand.mode         = .RValue
			case .Inverse:
				if len(v.args) != 1 {
					error(checker, v, "builtin 'inverse' expects one argument, got %d", len(args))
					break
				}
				type := args[0].type
				if !types.is_matrix(type) {
					error(checker, v, "builtin 'inverse' expects a matrix, got %d", len(args))
					break
				}
				if !types.matrix_is_square(type) {
					error(checker, v, "builtin 'inverse' expects a square matrix, got %v", type)
					break
				}
				operand.type = type
				operand.mode = .RValue
			case .Transpose:
				if len(v.args) != 1 {
					error(checker, v, "builtin 'transpose' expects one argument, got %d", len(args))
					break
				}
				type := args[0].type
				if !types.is_matrix(type) {
					error(checker, v, "builtin 'transpose' expects a matrix, got %d", len(args))
					break
				}
				if !types.matrix_is_square(type) {
					m   := type.variant.(^types.Matrix)
					type = types.matrix_new(types.vector_new(types.matrix_elem(type), m.cols, checker.allocator), m.col_type.count, checker.allocator)
				}
				operand.type = type
				operand.mode = .RValue
			case .Determinant:
				if len(v.args) != 1 {
					error(checker, v, "builtin 'determinant' expects one argument, got %d", len(args))
					break
				}
				type := args[0].type
				if !types.is_matrix(type) {
					error(checker, v, "builtin 'determinant' expects a matrix, got %v", type)
					break
				}
				if !types.matrix_is_square(type) {
					error(checker, v, "builtin 'determinant' expects a square matrix, got %v", type)
					break
				}
				operand.type = types.matrix_elem(type)
				operand.mode = .RValue
			case .Ddx, .Ddy:
				if checker.shader_stage != .Fragment {
					error(checker, v, "builtin '%s' can only be used in fragment shaders", builtin_names[v.builtin])
					break
				}
				fallthrough
			case .Sqrt, .Sin, .Cos, .Tan, .Exp, .Exp2, .Log, .Log2, .Floor, .Fract, .Ceil, .Round, .Trunc, .Inverse_Sqrt:
				if len(v.args) != 1 {
					error(checker, v, "builtin '%s' expects one argument, got %d", builtin_names[v.builtin], len(args))
					break
				}
				arg  := args[0]
				type := types.op_result_type(arg.type, types.t_f32)
				if type.kind == .Invalid || type.kind == .Matrix {
					error(checker, v, "builtin '%s' expects a float or vector, got %v", builtin_names[v.builtin], arg.type)
					return
				}
				v.args[0].value.type = type
				operand.mode         = .RValue
				operand.type         = type
			case .Abs:
				if len(v.args) != 1 {
					error(checker, v, "builtin '%s' expects one argument, got %d", builtin_names[v.builtin], len(args))
					break
				}
				type := types.default_type(args[0].type)
				t    := type
				if types.is_vector(type) {
					t = types.vector_elem(type)
				}
				#partial switch t.kind {
				case .Float, .Int:
					error(checker, v, "builtin '%s' expects a signed scalar or a vector, got %v", builtin_names[v.builtin], type)
					return
				}
				v.args[0].value.type = type
				operand.mode         = .RValue
				operand.type         = type
			case .Pow:
				if len(v.args) != 2 {
					error(checker, v, "builtin 'pow' expects two arguments, got %d", len(args))
					break
				}
				x         := args[0]
				y         := args[1]
				type      := types.op_result_type(x.type, y.type)
				elem_type := type
				if types.is_vector(type) {
					elem_type = types.vector_elem(type)
				}
				if type.kind == .Invalid || !types.is_float(elem_type) {
					error(checker, v, "builtin 'tan' expects two float vectors or scalars, got %v and %v", x.type, y.type)
					return
				}
				v.args[0].value.type = type
				v.args[1].value.type = type
				operand.mode = .RValue
				operand.type = type
			case .Normalize, .Length:
				if len(v.args) != 1 {
					error(checker, v, "builtin '%v' expects one argument, got %d", builtin_names[v.builtin], len(v.args))
					return
				}
				x    := args[0]
				type := types.base_type(x.type)
				if !types.is_vector(type) || !types.is_float(types.vector_elem(type)) {
					error(checker, x, "builtin '%v' expects a vector of floats, got %v", builtin_names[v.builtin], type)
					return
				}
				operand.mode = .RValue
				operand.type = x.type
				if v.builtin == .Length {
					operand.type = types.vector_elem(type)
				}
			case .Distance:
				if len(v.args) != 2 {
					error(checker, v, "builtin 'distance' expects two arguments, got %d", len(v.args))
					return
				}
				a, b := args[0].type, args[1].type
				type := types.op_result_type(a, b)
				if type.kind == .Invalid {
					error(checker, v, "type mismatch in builtin 'distance': %v vs %v", a, b)
					break
				}
				if !types.is_vector(type) {
					error(checker, v, "builtin 'distance' expects a two vectors of the same type, got %v", type)
					break
				}
				v.args[0].value.type = type
				v.args[1].value.type = type
				operand.mode         = .RValue
				operand.type         = types.vector_elem(type)
			case .Discard:
				if len(v.args) != 0 {
					error(checker, v, "builtin 'discard' expects no arguments, got %d", len(v.args))
					return
				}
				operand.type    = types.t_invalid
				operand.mode    = .NoValue
				operand.is_call = true
			case .Texture_Size:
				if len(v.args) != 1 {
					error(checker, v, "builtin 'texture_size' expects one argument, got %d", len(v.args))
					return
				}
				if args[0].type.kind != .Sampler {
					error(checker, v, "builtin 'texture_size' expects a sampler, got %v", args[0].type)
					return
				}
				sampler     := args[0].type.variant.(^types.Image)
				operand.type = types.vector_new(types.t_i32, sampler.dimensions, checker.allocator)
				operand.mode = .RValue
			case .Image_Size:
				if len(v.args) != 1 {
					error(checker, v, "builtin 'image_size' expects one argument, got %d", len(v.args))
					return
				}
				if args[0].type.kind != .Image {
					error(checker, v, "builtin 'image_size' expects a sampler, got %v", args[0].type)
					return
				}
				sampler     := args[0].type.variant.(^types.Image)
				operand.type = types.vector_new(types.t_i32, sampler.dimensions, checker.allocator)
				operand.mode = .RValue
			case .Bit_Count, .Bit_Reverse:
				if len(v.args) != 1 {
					error(checker, v, "builtin '%s' expects one argument, got %d", builtin_names[v.builtin], len(v.args))
					return
				}
				type := args[0].type
				if types.is_vector(type) {
					type = types.vector_elem(type)
				}
				type = types.default_type(type)
				if !types.is_integer(type) {
					error(checker, v, "builtin '%s' expects an integer scalar or vector, got %v", builtin_names[v.builtin], v.args[0].type)
					return
				}
				operand.type = args[0].type
				operand.mode = .RValue
			case .Real, .Imag:
				if len(v.args) != 1 {
					error(checker, v, "builtin '%s' expects one argument, got %d", builtin_names[v.builtin], len(v.args))
					return
				}
				type := args[0].type
				if !types.is_quaternion(type) && !types.is_complex(type) {
					error(checker, v, "builtin '%s' expects a complex number or quaternion, got %v", builtin_names[v.builtin], type)
					return
				}
				operand.type = types.complex_elem(type)
				operand.mode = .RValue
			case .Jmag, .Kmag:
				if len(v.args) != 1 {
					error(checker, v, "builtin '%s' expects one argument, got %d", builtin_names[v.builtin], len(v.args))
					return
				}
				type := args[0].type
				if !types.is_quaternion(type) {
					error(checker, v, "builtin '%s' expects a quaternion, got %v", builtin_names[v.builtin], type)
					return
				}
				operand.type = types.complex_elem(type)
				operand.mode = .RValue
			}
			
		case .Type:
			v.is_cast = true
			
			if len(v.args) != 1 {
				error(checker, v, "too many arguments in cast to %v", fn.type)
				return
			}
			value := check_expr(checker, v.args[0].value)
			if !types.castable(value.type, fn.type) {
				error(checker, v, "can not cast expression from type %v to %v", value.type, fn.type)
			}
			operand.type = fn.type
			operand.mode = .RValue
		case:
			if fn.type.kind != .Proc {
				error(checker, v, "expected a procedure in call expression")
				return
			}

			proc_type := fn.type.variant.(^types.Proc)

			arg_index := 0
			for e in v.args {
				type_hint: ^types.Type
				if arg_index < len(proc_type.args) {
					type_hint = proc_type.args[arg_index].type
				}
				value := check_expr(checker, e.value, type_hint = type_hint)
				if arg_index >= len(proc_type.args) {
					continue
				}

				if value.type.kind == .Tuple {
					for field_type in value.type.variant.(^types.Struct).fields {
						if arg_index >= len(proc_type.args) {
							break
						}
						if !types.implicitly_castable(field_type.type, proc_type.args[arg_index].type) {
							error(checker, value, "mismatched type in at argument %d: %v vs %v", arg_index, proc_type.args[arg_index].type, value.type)
						}
						e.value.type = proc_type.args[arg_index].type
						arg_index += 1
					}
				} else {
					if !types.implicitly_castable(value.type, proc_type.args[arg_index].type) {
						error(checker, value, "mismatched type in at argument %d: %v vs %v", arg_index, proc_type.args[arg_index].type, value.type)
					}
					e.value.type = proc_type.args[arg_index].type
					arg_index += 1
				}
			}

			if arg_index != len(proc_type.args) {
				error(checker, v, "expected %d arguments but got %d", len(proc_type.args), arg_index)
			}

			operand.type    = proc_type.return_type
			operand.mode    = .RValue
			operand.is_call = true
		}
	case ^ast.Expr_Compound:
		type: ^types.Type
		if v.type_expr != nil {
			type = check_type(checker, v.type_expr)
		} else {
			type = type_hint
		}
		if type == nil {
			error(checker, v, "missing type in compound literal")
			return
		}
		v.type = type

		operand.type = type
		operand.mode = .RValue
		if len(v.fields) == 0 { // {}
			return
		}

		named: bool
		for f, i in v.fields {
			if i == 0 {
				named = len(f.ident.text) != 0
			}
			if named != (len(f.ident.text) != 0) {
				error(checker, f.value, "mixture of 'field = value' and value elements is not allowed")
			}
		}
		v.named = named

		#partial switch type.kind {
		case .Struct:
			type := type.variant.(^types.Struct)

			if named {
				seen := make(map[string]struct{}, context.temp_allocator)
				for field in v.fields {
					if field.ident.text in seen {
						error(checker, field.ident, "duplicate values in compound literal: %v", field.ident.text)
					}
					seen[field.ident.text] = {}

					find_struct_field :: proc(type: ^types.Struct, name: string) -> ^types.Field {
						for &field in type.fields {
							if field.name.text == name {
								return &field
							}
						}
						return nil
					}

					struct_field := find_struct_field(type, field.ident.text)
					if struct_field == nil {
						error(checker, field.ident, "struct type %v has no field %s", type, field.ident.text)
						continue
					}

					field_operand := check_expr(checker, field.value, type_hint = struct_field.type)
					if !types.implicitly_castable(field_operand.type, struct_field.type) {
						error(checker, field.value, "expected value of type %v but got %v", struct_field.type, field_operand.type)
						return
					}
					field.value.type = struct_field.type
				}
			} else {
				if len(v.fields) != len(type.fields) {
					error(checker, v, "expected %d values in compound literal but got %d", len(type.fields), len(v.fields))
					return
				}

				for field, i in v.fields {
					struct_field := type.fields[i]

					field_operand := check_expr(checker, field.value, type_hint = struct_field.type)
					if !types.implicitly_castable(field_operand.type, struct_field.type) {
						error(checker, field.value, "expected value of type %v but got %v", struct_field.type, field_operand.type)
						return
					}
					field.value.type = struct_field.type
				}
			}
		case .Vector:
			type := type.variant.(^types.Vector)
			if named {
				error(checker, v, "named values are not supported for vector literals")
				return
			}

			n_values := 0
			for field in v.fields {
				f := check_expr(checker, field.value, type_hint = type.elem)
				t := f.type
				if types.is_vector(t) {
					v        := f.type.variant.(^types.Vector)
					t         = v.elem
					n_values += v.count
				} else if types.is_tuple(t) {
					tuple := t.variant.(^types.Struct)
					for sf in tuple.fields {
						t := sf.type
						if types.is_vector(sf.type) {
							v        := sf.type.variant.(^types.Vector)
							t         = v.elem
							n_values += v.count
						} else {
							n_values += 1
						}
						if !types.implicitly_castable(t, type.elem) {
							error(checker, field.value, "expected value of type %v but got %v", type.elem, f.type)
							return
						}
					}
					continue
				} else {
					n_values        += 1
					field.value.type = type.elem
				}
				if !types.implicitly_castable(t, type.elem) {
					error(checker, field.value, "expected value of type %v but got %v", type.elem, f.type)
					return
				}
			}

			if n_values != type.count {
				error(checker, v, "expected %d values in compound literal but got %d", type.count, len(v.fields))
				return
			}
		case .Matrix:
			type := type.variant.(^types.Matrix)
			if named {
				error(checker, v, "named values are not supported for matrix literals")
				return
			}
			if len(v.fields) != type.col_type.count * type.cols {
				error(checker, v, "expected %d values in compound literal but got %d", type.col_type.count * type.cols, len(v.fields))
				return
			}
			for field in v.fields {
				f := check_expr(checker, field.value, type_hint = type.col_type.elem)
				if !types.implicitly_castable(f.type, type.col_type.elem) {
					error(checker, field.value, "expected value of type %v but got %v", type.col_type.elem, f.type)
					return
				}
				field.value.type = type.col_type.elem
			}
		case:
			error(checker, v, "illegal type in compound literal: %v", type)
		}

		return

	case ^ast.Expr_Index:
		lhs := check_expr(checker, v.lhs)
		rhs := check_expr(checker, v.rhs)
		v.rhs.type = types.default_type(rhs.type)

		operand.mode = lhs.mode
		operand.type = types.t_invalid
		#partial switch lhs.type.kind {
		case .Matrix:
			if !types.is_integer(rhs.type) {
				error(checker, rhs, "expected an integer as the index, but got %v", rhs.type)
			}
			operand.type = types.matrix_elem(lhs.type)
		case .Vector:
			if !types.is_integer(rhs.type) {
				error(checker, rhs, "expected an integer as the index, but got %v", rhs.type)
			}
			operand.type = types.vector_elem(lhs.type)
		case .Buffer:
			if !types.is_integer(rhs.type) {
				error(checker, rhs, "expected an integer as the index, but got %v", rhs.type)
			}
			operand.type = types.buffer_elem(lhs.type)
		case .Sampler:
			sampler := lhs.type.variant.(^types.Image)
			if sampler.dimensions == 1 {
				if !types.is_numeric(rhs.type) {
					error(
						checker,
						rhs,
						"expected a scalar to sample texture of type %v, got: %v",
						sampler,
						rhs.type,
					)
				}
			} else {
				if !types.is_vector(rhs.type) || types.vector_len(rhs.type) != sampler.dimensions {
					error(
						checker,
						rhs,
						"expected a %d dimensional vector to sample texture of type %v, got: %v",
						sampler.dimensions,
						sampler,
						rhs.type,
					)
				}
			}

			operand.type = sampler.texel_type
			operand.mode = .RValue
		case .Image:
			image := lhs.type.variant.(^types.Image)
			if image.dimensions == 1 {
				if !types.is_integer(rhs.type) {
					error(
						checker,
						rhs,
						"expected an integer to access texel from image of type %v, got: %v",
						image,
						rhs.type,
					)
				}
			} else {
				if types.is_integer(rhs.type) {
					v.rhs.type = types.vector_new(types.default_type(rhs.type), image.dimensions, checker.allocator)
				} else if !types.is_vector(rhs.type) || !types.is_numeric(types.vector_elem(rhs.type)) || types.vector_len(rhs.type) != image.dimensions {
					error(
						checker,
						rhs,
						"expected a %d dimensional vector of integers to access texel from image of type %v, got: %v",
						image.dimensions,
						image,
						rhs.type,
					)
				}
			}

			operand.type = image.texel_type
		}

		if operand.type.kind == .Invalid {
			error(checker, v, "expression of type %v can not be indexed", lhs.type)
			return
		}
		
	case ^ast.Expr_Cast:
		value       := check_expr(checker, v.value)
		operand.type = check_type(checker, v.type_expr)
		if !types.castable(value.type, operand.type) {
			error(checker, v, "can not cast expression from type %v to %v", value.type, operand.type)
		}
		operand.mode = .RValue
	case ^ast.Expr_Unary:
		is_valid_unary_operator :: proc(op: tokenizer.Token_Kind) -> bool {
			#partial switch op {
			case .Xor, .Not, .Add, .Subtract:
				return true
			}
			return false
		}
		expr := check_expr(checker, v.expr)
		if !types.operator_applicable(expr.type, v.op) && is_valid_unary_operator(v.op) {
			error(checker, v, "operator `%v` is not defined for `%v%v`", tokenizer.to_string(v.op), tokenizer.to_string(v.op), expr.type)
		}
		operand.mode  = .RValue
		operand.type  = expr.type
		operand.value = expr.value
		if expr.mode == .Const {
			operand.mode = .Const
			#partial switch v.op {
			case .Xor:
				operand.value = ~operand.value.(i64)
			case .Not:
				operand.value = !operand.value.(bool)
			case .Add:
			case .Subtract:
				#partial switch v in operand.value {
				case i64:
					operand.value = -v
				case f64:
					operand.value = -v
				case:
					unreachable()
				}
			case:
				unreachable()
			}
		}
	case ^ast.Expr_Ternary:
		cond       := check_expr(checker, v.cond)
		then_value := check_expr(checker, v.then_expr)
		else_value := check_expr(checker, v.else_expr)

		if cond.type.kind != .Bool {
			error(checker, cond, "expected a boolean as the condition in ternary, got %v", cond.type)
			return
		}

		operand.type = types.default_type(types.op_result_type(then_value.type, else_value.type))
		if operand.type.kind == .Invalid {
			error(checker, cond, "mismatched types in ternary expr: %v vs %v", then_value.type, else_value.type)
			return
		}
		v.then_expr.type = operand.type
		v.else_expr.type = operand.type

	case ^ast.Type_Matrix:
		rows := check_expr(checker, v.rows)
		if rows.mode != .Const || (rows.type.kind != .Int && rows.type.kind != .Uint) {
			error(checker, rows, "expected a constant integer")
		}
		cols: int
		if v.cols == nil {
			cols = int(rows.value.(i64) or_else 0)
		} else {
			cols_expr := check_expr(checker, v.cols)
			if cols_expr.mode != .Const || (cols_expr.type.kind != .Int && cols_expr.type.kind != .Uint) {
				error(checker, cols_expr, "expected a constant integer")
			} else {
				cols = int(cols_expr.value.(i64))
			}
		}

		col_type    := types.vector_new(types.default_type(check_type(checker, v.elem)), int(rows.value.(i64) or_else 0), checker.allocator)
		operand.type = types.matrix_new(col_type, cols, checker.allocator)
		operand.mode = .Type
	case ^ast.Type_Array:
		elem := types.default_type(check_type(checker, v.elem))
		if v.count == nil {
			if elem.size == 0 {
				error(checker, v.elem, "buffer element type must have a non-zero size, got %v", elem)
				return
			}
			operand.type = types.buffer_new(elem, v.physical, checker.allocator)
			operand.mode = .Type
		} else {
			count := check_expr(checker, v.count)
			if c, ok := count.value.(i64); ok {
				if c < 2 || c > 4 {
					error(checker, count, "vector size has to be between 2 and 4, got %d", c)
					return
				}
				operand.type = types.vector_new(elem, int(c), checker.allocator)
				operand.mode = .Type
			} else {
				error(checker, count, "expected a constant integer as the count of an array")
			}
		}

	case ^ast.Type_Struct:
		operand.mode = .Type

		type        := types.new(.Struct, types.Struct, checker.allocator)
		fields      := make([dynamic]types.Field, 0, len(v.fields), checker.allocator)
		fields_seen := make(map[string]struct{}, context.temp_allocator)
		offset      := 0
		align       := 1
		for i := 0; i < len(v.fields); {
			start := i
			type: ^types.Type
			for ; i < len(v.fields); i += 1 {
				field := v.fields[i]
				if field.ident.text in fields_seen {
					error(checker, field.ident, "duplicate field name: '%s'", field.ident.text)
					operand.mode = .Type
					operand.type = types.t_invalid
					return
				}
				fields_seen[field.ident.text] = {}
				if field.type == nil {
					continue
				}
				type = check_type(checker, field.type)
				i   += 1
				break
			}

			if type == nil && i == len(v.fields) {
				error(checker, v.fields[len(v.fields) - 1].ident, "struct field is missing a type")
				operand.mode = .Type
				operand.type = types.t_invalid
				return
			}

			if type.align != 0 {
				offset = mem.align_forward_int(offset, type.align)
			}

			align = max(align, type.align)
			for i in start ..< i {
				append(&fields, types.Field {
					name   = v.fields[i].ident,
					type   = type,
					offset = offset,
				})

				offset += type.size
				offset  = mem.align_forward_int(offset, align)
			}
		}

		offset = mem.align_forward_int(offset, align)

		type.fields = fields[:]
		type.size   = offset
		type.align  = align

		operand.type = type
		operand.mode = .Type
	case ^ast.Type_Enum:
		operand.mode = .Type

		type          := types.new(.Enum, types.Enum, checker.allocator)
		values        := make([dynamic]types.Enum_Value, 0, len(v.values), checker.allocator)
		values_seen   := make(map[string]struct{}, context.temp_allocator)
		max_value     := 0
		min_value     := 0
		current_value := 0
		for value in v.values {
			if value.ident.text in values_seen {
				error(checker, value.ident, "duplicate enum value name: '%s'", value.ident.text)
			}
			values_seen[value.ident.text] = {}

			if value.value == nil {
				append(&values, types.Enum_Value {
					name  = value.ident,
					value = current_value,
				})
				max_value      = max(max_value, current_value)
				current_value += 1
				continue
			}

			enum_value := check_expr(checker, value.value)
			if val, ok := enum_value.value.(i64); ok {
				append(&values, types.Enum_Value {
					name  = value.ident,
					value = int(val),
				})
				max_value     = max(max_value, int(val))
				min_value     = min(min_value, int(val))
				current_value = int(val)
			} else {
				error(checker, enum_value, "enum value has to be a constant integer")
			}
		}

		backing: ^types.Type
		if v.backing != nil {
			backing = check_type(checker, v.backing)
		} else {
			backing = types.t_i32
		}

		type.values  = values[:]
		type.size    = backing.size
		type.align   = backing.align
		type.backing = backing

		operand.type = type
		operand.mode = .Type
	case ^ast.Type_Import:
		type, ok := checker.shared_types[v.ident.text]
		if !ok {
			error(checker, v.ident, "unknown shared type: %s", v.ident.text)
			operand.mode = .Type
			operand.type = types.t_invalid
			return
		}
		operand.type = type
		operand.mode = .Type
	case ^ast.Type_Image:
		dimensions := check_expr(checker, v.dimensions)
		if dim, ok := dimensions.value.(i64); ok {
			if dim < 1 || dim > 3 {
				error(checker, dimensions, "sampler dimension has to be between 1 and 3, got %d", dim)
				return
			}
			texel_type := types.default_type(check_type(checker, v.texel_type))
			if !(types.is_numeric(texel_type) || types.is_vector(texel_type)) {
				error(checker, v.texel_type, "texel type of sampler has to be either a numeric type or a vector, got: %v", texel_type)
				return
			}
			if v.is_sampler {
				operand.type = types.sampler_new(texel_type, int(dim), checker.allocator)
			} else {
				operand.type = types.image_new(texel_type, int(dim), checker.allocator)
			}
			operand.mode = .Type
		} else {
			error(checker, dimensions, "expected a constant integer as the dimension of a sampler")
		}
	case ^ast.Type_Bit_Set:
		enum_type   := check_type(checker, v.enum_type)
		backing     := check_type(checker, v.backing)
		operand.type = types.bit_set_new(enum_type, backing, checker.allocator)
		operand.mode = .Type
	}

	return
}

@(require_results)
check_expr_or_type :: proc(checker: ^Checker, expr: ^ast.Expr, attributes: []ast.Field = {}, type_hint: ^types.Type = nil) -> (operand: Operand) {
	operand = check_expr_internal(checker, expr, attributes, type_hint)
	switch operand.mode {
	case .RValue, .LValue, .Const, .Type, .Proc:
		assert(operand.type != nil)
		return
	case .Builtin:
		error(checker, operand, "expected an expression, got builtin")
	case .NoValue:
		error(checker, operand, "expected an expression, got no value")
	case .Library:
		error(checker, operand, "expected an expression, got library")
	case .Invalid:
	}

	
	operand.mode = .Invalid
	operand.type = types.t_invalid
	return
}

@(require_results)
check_expr :: proc(checker: ^Checker, expr: ^ast.Expr, attributes: []ast.Field = {}, type_hint: ^types.Type = nil, allow_no_value := false) -> (operand: Operand) {
	operand = check_expr_internal(checker, expr, attributes, type_hint)
	switch operand.mode {
	case .RValue, .LValue, .Const, .Proc:
		assert(operand.type != nil)
		return
	case .Builtin:
		error(checker, operand, "expected an expression, got builtin")
	case .Type:
		error(checker, operand, "expected an expression, got type")
	case .NoValue:
		if allow_no_value {
			return
		}
		error(checker, operand, "expected an expression, got no value")
	case .Library:
		error(checker, operand, "expected an expression, got library")
	case .Invalid:
	}

	operand.mode = .Invalid
	operand.type = types.t_invalid
	return
}

@(require_results)
check_type :: proc(checker: ^Checker, expr: ^ast.Expr, attributes: []ast.Field = {}) -> ^types.Type {
	operand := check_expr_internal(checker, expr, attributes)
	switch operand.mode {
	case .RValue, .LValue, .Const, .Proc:
		error(checker, operand, "expected a type, got expression")
	case .Builtin:
		error(checker, operand, "expected a type, got builtin")
	case .Type:
		assert(operand.type != nil)
		return operand.type
	case .NoValue:
		error(checker, operand, "expected a type, got no value")
	case .Library:
		error(checker, operand, "expected a type, got library")
	case .Invalid:
	}

	return types.t_invalid
}

error_operand :: proc(checker: ^Checker, operand: Operand, message: string, args: ..any) {
	append(&checker.errors, tokenizer.Error {
		location = operand.expr.start,
		end     = operand.expr.end,
		message = fmt.aprintf(message, ..args, allocator = checker.error_allocator),
	})
}

error_location :: proc(checker: ^Checker, location: tokenizer.Location, message: string, args: ..any) {
	append(&checker.errors, tokenizer.Error {
		location = location,
		end      = location,
		message  = fmt.aprintf(message, ..args, allocator = checker.error_allocator),
	})
}

error_start_end :: proc(checker: ^Checker, start, end: tokenizer.Location, message: string, args: ..any) {
	append(&checker.errors, tokenizer.Error {
		location = start,
		end      = end,
		message  = fmt.aprintf(message, ..args, allocator = checker.error_allocator),
	})
}

error_token :: proc(checker: ^Checker, token: tokenizer.Token, message: string, args: ..any) {
	end := token.location
	end.offset += len(token.text)
	end.column += len(token.text)
	append(&checker.errors, tokenizer.Error {
		location = token.location,
		end      = end,
		message  = fmt.aprintf(message, ..args, allocator = checker.error_allocator),
	})
}

error_ast_node :: proc(checker: ^Checker, ast_node: ^ast.Node, message: string, args: ..any) {
	append(&checker.errors, tokenizer.Error {
		location = ast_node.start,
		end      = ast_node.end,
		message  = fmt.aprintf(message, ..args, allocator = checker.error_allocator),
	})
}

error :: proc {
	error_operand,
	error_location,
	error_token,
	error_ast_node,
	error_start_end,
}

@(require_results)
entity_to_operand :: proc(e: ^Entity) -> (operand: Operand) {
	operand.type = e.type
	switch e.kind {
	case .Invalid:
	case .Const:
		operand.mode  = .Const
		operand.value = e.value
	case .Type:
		operand.mode = .Type
	case .Var:
		operand.mode = .LValue
		if .Readonly in e.flags {
			operand.mode = .RValue
		}
	case .Proc:
		operand.mode = .Proc
	case .Builtin:
		operand.mode       = .Builtin
		operand.builtin_id = e.builtin_id
	case .Library:
		operand.mode    = .Library
		operand.library = e.library
	}

	return
}
