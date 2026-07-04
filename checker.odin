package hephaistos

import "base:intrinsics"
import "base:runtime"

import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:slice"
import "core:strings"

import spv "spirv-odin"

Checker_Flag :: enum {
	Auto_Map_Locations,
	Auto_Bind_Uniforms,

	Enable_Reflection,
	Enable_References,

	Vet_Unused_Procedures,
	Vet_Unused_Parameters,
	Vet_Unused_Variables,
	Vet_Unused_Imports,
	Vet_Unused_Results,
	Vet_Shadowing,
	Vet_Cast,
}

Checker_Flags :: bit_set[Checker_Flag]

Checker :: struct {
	allocator:        runtime.Allocator,
	errors:           [dynamic]Error,
	error_allocator:  runtime.Allocator,

	libraries:        map[string]^Library,
	used_libraries:   map[^Library]string,
	shared_types:     map[string]^Type,
	config_vars:      map[string]Const_Value,
	flags:            Checker_Flags,

	scope:           ^Scope,
	shader_stage:     Shader_Stage,
	current_location: i64,
	current_binding:  i64,

	reflection:       struct {
		interface:    map[string]Reflection_Info,
		entry_points: map[string]Entry_Point_Info,
	},
}

Entry_Point_Info :: struct {
	inputs:  []Reflection_Info,
	outputs: []Reflection_Info,
	stage:   Shader_Stage,
}

Reflection_Info :: struct {
	type:             ^Type,
	interface:         Interface_Kind,
	binding, location: i64,
}

Addressing_Mode :: enum {
	Invalid = 0,
	RValue,
	No_Value,
	LValue,
	Const,
	Proc,
	Proc_Group,
	Type,
	Builtin,
	Library,
	Ellipsis,
	Label,
}

@(rodata)
addressing_mode_string := [Addressing_Mode]string {
	.Invalid    = "<invalid>",
	.No_Value   = "no value",
	.RValue     = "rvalue",
	.LValue     = "lvalue",
	.Const      = "const",
	.Proc       = "proc",
	.Proc_Group = "proc",
	.Type       = "type",
	.Builtin    = "builtin",
	.Library    = "library",
	.Ellipsis   = "ellipsis",
	.Label      = "label",
}

Operand_Flag :: enum {
	Diverging,
	Constant_Compound,
	Type_Distinct,
}

Operand_Flags :: bit_set[Operand_Flag]

Operand :: struct {
	expr:      ^Ast_Expr,
	type:      ^Type,
	mode:       Addressing_Mode,
	value:      Const_Value,
	builtin_id: Builtin_Id,
	library:   ^Library,
	scope:     ^Scope,
	flags:      Operand_Flags,
}

@(require_results)
scope_new :: proc(parent: ^Scope, kind: Scope_Kind, allocator: mem.Allocator) -> ^Scope {
	s                   := new(Scope, allocator)
	s.parent             = parent
	s.kind               = kind
	s.entities.allocator = allocator
	return s
}

@(require_results)
check_ident :: proc(checker: ^Checker, name: ^Expr_Ident, scope: ^Scope = nil) -> (e: ^Entity, ok: bool) {
	s := scope
	if s == nil {
		s = checker.scope
	}
	for s != nil {
		e, ok = s.entities[name.text]
		if ok {
			decl_resolve(checker, e)
			name.entity = e
			if .Enable_References in checker.flags {
				append(&e.references, name)
			}
			e.flags |= { .Used, }
			return
		}
		s = s.parent
	}
	error(checker, name, "unknown identifier: '%s'", name.text)
	return
}

@(require_results)
lookup_proc_type :: proc(checker: ^Checker) -> (e: ^Type_Proc, ok: bool) {
	s := checker.scope
	for s != nil {
		if s.proc_type != nil {
			return s.proc_type, true
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

@(require_results)
scope_push :: proc(checker: ^Checker, kind: Scope_Kind, label: ^Expr_Ident = nil) -> ^Scope {
	checker.scope = scope_new(checker.scope, kind, checker.allocator)

	if label != nil {
		e      := entity_new(checker, .Label, label, t_invalid, flags = { .Resolved, })
		e.scope = checker.scope
		scope_insert_entity(checker, e)
	}

	return checker.scope
}

check_scope_end :: proc(checker: ^Checker) {
	unused_entities := make([dynamic]^Entity, context.temp_allocator)
	for _, e in checker.scope.entities {
		if .Used in e.flags || get_entity_node(e) == nil {
			continue
		}

		append(&unused_entities, e)
	}

	slice.sort_by(unused_entities[:], proc(a, b: ^Entity) -> bool {
		return get_entity_node(a).start.offset < get_entity_node(b).start.offset
	})

	for e in unused_entities {
		node := get_entity_node(e)
		#partial switch e.kind {
		case .Proc_Param:
			if .Vet_Unused_Parameters in checker.flags {
				error(checker, node, "parameter '%s' declared but not used", e.name)
			}
		case .Proc:
			assert(e.decl != nil)
			if .Vet_Unused_Procedures in checker.flags && (e.decl.derived.(^Decl_Value) or_break).shader_stage == nil {
				error(checker, node, "procedure '%s' declared but not used", e.name)
			}
		case .Var:
			if .Vet_Unused_Variables in checker.flags {
				error(checker, node, "variable '%s' declared but not used", e.name)
			}
		case .Library:
			if .Vet_Unused_Imports in checker.flags {
				error(checker, node, "'%s' imported but not used", e.name)
			}
		}
	}
}

scope_pop :: proc(checker: ^Checker) -> (s: ^Scope) {
	check_scope_end(checker)

	s             = checker.scope
	checker.scope = s.parent
	return
}

scope_insert_entity :: proc(checker: ^Checker, e: ^Entity, scope: ^Scope = nil) -> bool {
	if e == nil {
		return true
	}

	if e.name == "_" {
		return true
	}

	scope := scope
	if scope == nil {
		scope = checker.scope
	}

	assert(e.name != "")
	if e.name in scope.entities {
		error(checker, get_entity_node(e), "'%s' has already been defined in this scope", e.name)
		return false
	}

	if .Vet_Shadowing in checker.flags {
		for s := scope.parent; s != nil; s = s.parent {
			old, ok := s.entities[e.name]
			if ok {
				error(checker, get_entity_node(e), "declaration of '%s' shadows previous declaration on line %d", e.name, get_entity_node(old).start.line)
				break
			}
		}
	}

	scope.entities[e.name] = e
	return true
}

check_assignment :: proc(checker: ^Checker, lhs, rhs: ^Type, node: ^Ast_Node, context_: string) -> (ok: bool) {
	if type_is_invalid(lhs) || type_is_invalid(rhs) {
		return false
	}

	if !implicitly_castable(rhs, lhs) {
		error(checker, node, "mismatched type in %s: expected %v, got %v", context_, lhs, rhs)
	}

	ok = true
	return
}

@(require_results)
check_stmt :: proc(checker: ^Checker, stmt: ^Ast_Stmt) -> (diverging: bool) {
	if checker.scope.kind == .Global {
		#partial switch v in stmt.derived_stmt {
		case ^Decl_Value, ^Decl_Import, ^Decl_Extension, ^Stmt_When:
		case ^Stmt_Expr:
			call, ok := v.expr.derived.(^Expr_Call)
			if !ok {
				error(checker, stmt, "only declaration are allowed at file scope")
				break
			}

			if _, ok := call.lhs.derived.(^Expr_Directive); !ok {
				error(checker, stmt, "only declaration are allowed at file scope")
			}
		case:
			error(checker, stmt, "only declaration are allowed at file scope")
		}
	}

	switch v in stmt.derived_stmt {
	case ^Stmt_Return:
		proc_type, ok := lookup_proc_type(checker)
		if !ok {
			error(checker, v, "unexpected return statement outside of procedure body")
			return true
		}
		return_index := 0
		for e in v.values {
			type_hint: ^Type
			if return_index < len(proc_type.returns) {
				type_hint = proc_type.returns[return_index].type
			}
			value := check_expr(checker, e, type_hint = type_hint)
			if return_index >= len(proc_type.returns) {
				return_index += 1
				continue
			}

			ts := []^Type{ value.type, }
			deconstruct_tuple(checker, &ts)

			for type in ts {
				check_assignment(checker, proc_type.returns[return_index].type, type, value.expr, "return statement")
				if len(ts) == 1 {
					e.type = proc_type.returns[return_index].type
				}
				return_index += 1
			}
		}

		if return_index != 0 && return_index != len(proc_type.returns) {
			error(checker, v, "expected %d values in return statement but got %d", len(proc_type.returns), return_index)
		}

		return true
	case ^Stmt_Break:
		if v.label != nil {
			label := check_expr_internal(checker, v.label, {})
			if label.mode != .Label {
				error(checker, label, "expected a label")
				return
			}
		} else {
			_, ok := lookup_scope_by_kind(checker, { .Loop, .Switch, })
			if !ok {
				error(checker, v, "break can only be used in loops and switches")
			}
		}

		return true
	case ^Stmt_Continue:
		if v.label != nil {
			label := check_expr_internal(checker, v.label, {})
			if label.mode != .Label {
				error(checker, label, "expected a label")
				return
			}
			if label.scope.kind != .Loop {
				error(checker, label, "continue can only be used in loops")
			}
		} else {
			_, ok := lookup_scope_by_kind(checker, { .Loop, })
			if !ok {
				error(checker, v, "continue can only be used in loops")
			}
		}

		return true
	case ^Stmt_For_Range:
		v.init_scope = scope_push(checker, .Loop, v.label)
		defer scope_pop(checker)

		start := check_expr(checker, v.start_expr)
		end   := check_expr(checker, v.end_expr, type_hint = start.type)
		if !type_is_numeric(start.type) {
			error(checker, v.end, "non-numeric type in range statment: %v", start.type)
		}
		iter_type        := op_result_type(start.type, end.type)
		iter_type         = default_type(iter_type)
		v.start_expr.type = iter_type
		v.end_expr.type   = iter_type
		if iter_type.kind == .Invalid {
			error(checker, v.end, "mismatched types in range stmt: %v vs %v", start.type, end.type)
		}

		scope_insert_entity(checker, entity_new(checker, .Var, v.variable, iter_type, flags = { .Readonly, .Resolved, }))
		v.variable.type = iter_type

		v.scope = scope_push(checker, .Block)
		defer scope_pop(checker)
		check_stmt_list(checker, v.body)
		return false
	case ^Stmt_For:
		v.init_scope = scope_push(checker, .Loop, v.label)
		defer scope_pop(checker)

		if v.init != nil {
			diverging := check_stmt(checker, v.init)
			if diverging {
				error(checker, v.init, "for loop init statement can not be diverging")
			}
		}

		if v.cond != nil {
			cond := check_expr(checker, v.cond)
			if cond.type.kind != .Bool && cond.mode != .Invalid {
				error(checker, cond, "expected a boolean expression in for loop condition but got: %v", cond.type)
			}
		}

		if v.post != nil {
			diverging := check_stmt(checker, v.post)
			if diverging {
				error(checker, v.init, "for loop post statement can not be diverging")
			}
		}

		v.scope = scope_push(checker, .Block)
		defer scope_pop(checker)
		check_stmt_list(checker, v.body)
		return false
	case ^Stmt_Block:
		v.scope = scope_push(checker, .Block, v.label)
		defer scope_pop(checker)

		return check_stmt_list(checker, v.body)
	case ^Stmt_If:
		v.init_scope = scope_push(checker, .Block, v.label)
		defer scope_pop(checker)

		if v.init != nil {
			diverging := check_stmt(checker, v.init)
			if diverging {
				error(checker, v.init, "if statement init statement can not be diverging")
			}
		}

		cond := check_expr(checker, v.cond)
		if cond.type.kind != .Bool && cond.mode != .Invalid {
			error(checker, cond, "expected a boolean expression in if statement condition but got expression of type %v", cond.type)
		}

		v.then_scope = scope_push(checker, .Block, v.label)
		then_diverging := check_stmt_list(checker, v.then_block)
		scope_pop(checker)

		v.else_scope = scope_push(checker, .Block, v.label)
		else_diverging := check_stmt_list(checker, v.else_block)
		scope_pop(checker)

		return then_diverging && else_diverging
	case ^Stmt_When:
		cond := check_expr(checker, v.cond)
		if c, ok := cond.value.(bool); ok {
			if c {
				return check_stmt_list(checker, v.then_block, true)
			} else {
				return check_stmt_list(checker, v.else_block, true)
			}
		} else if cond.mode != .Invalid {
			error(checker, cond, "expected a constant boolean expression in when statement condition")
		}
		return false

	case ^Stmt_Switch:
		v.scope = scope_push(checker, .Block, v.label)
		defer scope_pop(checker)

		if v.init != nil {
			diverging := check_stmt(checker, v.init)
			if diverging {
				error(checker, v.init, "if statement init statement can not be diverging")
			}
		}

		cond            := check_expr(checker, v.cond)
		cond.type        = default_type(cond.type)
		seen_default    := false
		v.constant_cases = true
		for &c in v.cases {
			if c.value == nil {
				if seen_default {
					error(checker, c.token, "switch statement can only have one default case")
					seen_default = true
				}

				c.scope = scope_push(checker, .Switch)
				defer scope_pop(checker)

				check_stmt_list(checker, c.body)
				continue
			}

			c.scope = scope_push(checker, .Switch)
			defer scope_pop(checker)

			value := check_expr(checker, c.value, type_hint = cond.type)
			if !implicitly_castable(value.type, cond.type) {
				error(checker, value, "type of case value does not match selector type: expected %v, got %v", cond.type, value.type)
			}
			if value.mode != .Const {
				v.constant_cases = false
				error(checker, value, "switch statement cases have to be constants (for now)")
			}
			check_stmt_list(checker, c.body)
		}

	case ^Stmt_Assign:
		lhs := make([]Operand, len(v.lhs), checker.allocator)
		for &lhs, i in lhs {
			if ident, ok := v.lhs[i].derived.(^Expr_Ident); ok && ident.text == "_" {
				lhs.expr = v.lhs[i]
				lhs.type = nil
				lhs.mode = .LValue
				continue
			}
			lhs = check_expr(checker, v.lhs[i])
		}

		for &l in lhs {
			if l.mode != .LValue && l.mode != .Invalid {
				error(checker, l, "cannot assign to %s expression", addressing_mode_string[l.mode])
			}
		}

		lhs_i := 0
		check_assignment_types: for &r_expr in v.rhs {
			type_hint: ^Type
			if lhs_i < len(lhs) {
				type_hint = lhs[lhs_i].type
			}
			rhs       := check_expr(checker, r_expr, type_hint = type_hint)
			rhs_types := []^Type { rhs.type, }
			deconstruct_tuple(checker, &rhs_types)

			for type in rhs_types {
				defer lhs_i += 1
				if lhs_i >= len(lhs) {
					continue
				}
				if lhs[lhs_i].type == nil {
					lhs[lhs_i].type      = type
					lhs[lhs_i].expr.type = type
				}
				check_assignment(checker, lhs[lhs_i].type, type, rhs.expr, "assign statement") or_continue
				if len(rhs_types) == 1 {
					r_expr.type = lhs[lhs_i].type
				}

				if v.op != .Invalid && !operator_applicable(lhs[lhs_i].type, v.op) {
					error(checker, v, "operator `%v` is not defined for `%v %v= %v`", token_to_string(v.op), lhs[lhs_i].type, token_to_string(v.op), rhs.type)
				}
			}
		}
		if lhs_i != len(lhs) {
			error(checker, v, "assignment count mismatch: %v vs %v", len(lhs), lhs_i)
		}

	case ^Stmt_Expr:
		operand := check_expr(checker, v.expr, allow_no_value = true)
		if operand.mode == .Invalid {
			return
		}
		if .Vet_Unused_Results in checker.flags && operand.mode != .No_Value {
			error(checker, v.expr, "expression is not used")
		} else {
			if _, ok := v.expr.derived.(^Expr_Call); !ok {
				error(checker, v.expr, "expression is not used")
			}
		}
		return .Diverging in operand.flags

	case ^Decl_Value:
		if checker.scope.kind == .Global || !v.mutable {
			break
		}

		flags := check_decl_attributes(checker, v, false)

		values := make([]Operand, len(v.values), checker.allocator)

		explicit_type: ^Type
		if v.type_expr != nil {
			explicit_type = check_type(checker, v.type_expr)
		}

		for &value, i in values {
			value = check_expr(checker, v.values[i], stmt.attributes, explicit_type)
			check_decl_init_value(checker, value, false)
		}

		flags += { .Resolved, }

		if len(values) == 0 {
			if explicit_type == nil {
				explicit_type = t_invalid
			}
			check_decl_interface_type(checker, v, explicit_type)
			for lhs in v.lhs {
				ident: ^Expr_Ident
				ok:    bool
				if ident, ok = lhs.derived_expr.?; !ok {
					error(checker, lhs, "variable declaration must be an identifier")
					continue
				}

				scope_insert_entity(checker, entity_new(checker, .Var, ident, explicit_type, decl = v, flags = flags))

				lhs.type = explicit_type
			}
			return
		}

		lhs_i := 0
		check_decl_types: for &rhs in values {
			rhs_types := []^Type{ rhs.type, }
			tuple     := deconstruct_tuple(checker, &rhs_types)
			for rhs_type in rhs_types {
				defer lhs_i += 1
				if lhs_i >= len(v.lhs) {
					continue
				}

				lhs         := v.lhs[lhs_i]
				entity_kind := Entity_Kind.Var

				type := explicit_type
				if type == nil {
					type = rhs_type
					if entity_kind != .Const {
						type = default_type(type)
					}
				} else {
					check_assignment(checker, explicit_type, rhs_type, rhs.expr, "value declaration")
				}
				v.lhs[lhs_i].type = type
				if !tuple {
					v.values[lhs_i].type = type
				}

				ident: ^Expr_Ident
				ok:    bool
				if ident, ok = lhs.derived_expr.?; !ok {
					continue
				}

				scope_insert_entity(checker, entity_new(
					checker,
					entity_kind,
					ident,
					type,
					decl  = v,
					flags = flags,
				))
			}
		}
		if lhs_i != len(v.lhs) {
			error(checker, v, "assignment count mismatch: %v vs %v", len(v.lhs), lhs_i)
		}
	case ^Decl_Import:
	case ^Decl_Extension:
	}

	diverging = false
	return
}

check_decl_interface_type :: proc(checker: ^Checker, decl: ^Decl_Value, type: ^Type) {
	@(static, rodata)
	interface_kind_names := [Interface_Kind]string {
		.None                 = "none",
		.Uniform              = "uniform",
		.Uniform_Buffer       = "uniform buffer",
		.Push_Constant        = "push constant",
		.Storage_Buffer       = "storage buffer",
		.Shared               = "shared",

		.Input                = "input",
		.Output               = "output",

		.Ray_Payload          = "ray payload",
		.Incoming_Ray_Payload = "incoming ray payload",
		.Hit_Attribute        = "hit attribute",
	}

	if decl.interface == .None || type == nil || type.kind == .Invalid {
		return
	}

	switch decl.interface {
	case .None:
	case .Uniform:
		if type_is_buffer(type) || type_is_struct(type) {
			error(checker, decl.type_expr, "type of uniform variable can not be a composite type")
		}
	case .Shared, .Ray_Payload, .Hit_Attribute, .Incoming_Ray_Payload, .Input, .Output:
	case .Uniform_Buffer, .Storage_Buffer, .Push_Constant:
		if !(type_is_buffer(type) || type_is_struct(type)) {
			error(checker, decl.type_expr, "type of %s variable has to be a composite type", interface_kind_names[decl.interface])
		}
	}

	if .Enable_Reflection not_in checker.flags {
		return
	}

	for lhs in decl.lhs {
		checker.reflection.interface[lhs.text] = {
			type      = type,
			interface = decl.interface,
			binding   = decl.binding,
			location  = decl.location,
		}
	}
}

@(require_results)
check_decl_attributes :: proc(checker: ^Checker, decl: ^Decl_Value, constant: bool) -> (flags: Entity_Flags) {
	decl.location       = -1
	decl.binding        = -1
	decl.descriptor_set = -1
	seen := make(map[string]struct{}, context.temp_allocator)

	interface_ident: ^Ast_Expr

	for a in decl.attributes {
		name, library: string
		if selector, ok := a.name.derived_expr.(^Expr_Selector); ok {
			@(require_results)
			expect_ident :: proc(checker: ^Checker, expr: ^Ast_Expr, ctx: string = "") -> (ident: string, ok: bool) {
				if i, ok := expr.derived_expr.(^Expr_Ident); ok {
					return i.text, true
				}

				if ctx != "" {
					error(checker, expr, "expected an identifier in %s", ctx)
				} else {
					error(checker, expr, "expected an identifier")
				}
				return
			}

			library = expect_ident(checker, selector.lhs) or_continue
			name    = selector.selector.text
		} else {
			name = a.name.text
		}

		if name in seen {
			error(checker, a.name, "duplicate attribute: '%v'", name)
		}
		seen[name] = {}

		interface_kind: Interface_Kind
		for name, interface in interface_kind_names {
			if check_attribute_matches(checker, a, name) {
				interface_kind  = interface
				interface_ident = a.name
				break
			}
		}

		if interface_kind != nil {
			if decl.interface != nil {
				error(checker, a.name, "the '%s' and '%s' attributes are mutually exclusive", interface_kind_names[decl.interface], name)
			}
			if a.value != nil {
				error(checker, a.value, "'%s' attribute does not accept a value", name)
			}
			decl.interface = interface_kind
			continue
		}

		switch name {
		case "readonly":
			flags |= { .Readonly, }
			if a.value != nil {
				error(checker, a.value, "'%s' attribute does not accept a value", name)
			}
		case "binding":
			if a.value == nil {
				error(checker, a.name, "'binding' attribute requires a value")
				break
			}
			value := check_expr(checker, a.value)
			if val, ok := value.value.(i64); ok && val >= 0 || value.mode == .Invalid {
				decl.binding = val
			} else {
				error(checker, value, "'binding' attribute value must be a constant non-negative integer")
			}
		case "location":
			if a.value == nil {
				error(checker, a.name, "'location' attribute requires a value")
				break
			}
			value := check_expr(checker, a.value)
			if val, ok := value.value.(i64); ok && val >= 0 || value.mode == .Invalid {
				decl.location = val
			} else {
				error(checker, value, "'location' attribute value must be a constant non-negative integer")
			}
		case "descriptor_set":
			if a.value == nil {
				error(checker, a.name, "'descriptor_set' attribute requires a value")
				break
			}
			value := check_expr(checker, a.value)
			if val, ok := value.value.(i64); ok && val >= 0 || value.mode == .Invalid {
				decl.descriptor_set = val
			} else {
				error(checker, value, "'descriptor_set' attribute value must be a constant non-negative integer")
			}
		case "link_name":
			if a.value == nil {
				error(checker, a.name, "'link_name' attribute requires a value")
				break
			}
			value := check_expr(checker, a.value)
			(value.mode != .Invalid) or_break
			if val, ok := value.value.(string); ok {
				decl.link_name = val
			} else {
				error(checker, value, "'link_name' attribute value must be a constant string")
			}
		case "local_size":
			if a.value == nil {
				error(checker, a.name, "'local_size' attribute requires a value")
				break
			}
			if comp, ok := a.value.derived_expr.(^Expr_Compound); ok {
				if len(comp.fields) != 3 {
					error(checker, a.value, "'local_size' attribute value must be a compound literal of three constant integers")
					break
				}
				for field, i in comp.fields {
					value := check_expr(checker, field.value)
					if value.mode == .Invalid {
						value.value = 1
					}
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
				error(checker, a.value, "'local_size' attribute value must be a compound literal of three constant integers")
			}
		case "builtin":
			if a.value == nil {
				error(checker, a.name, "'builtin' attribute requires a value")
				break
			}
			value := check_expr(checker, a.value)
			(value.mode != .Invalid) or_break
			if val, ok := value.value.(string); ok {
				decl.builtin, ok = spirv_builtin_names[val]
				if !ok {
					error(checker, value, "'%s' is not a valid builtin", val)
				}
			} else {
				error(checker, value, "'%s' attribute value must be a constant string", a.name.text)
			}
		case:
			found: bool
			for name, stage in shader_stage_names {
				if check_attribute_matches(checker, a, name) {
					if decl.shader_stage != nil {
						error(checker, a.name, "procedures can only be annotated with one shader stage")
					}
					decl.shader_stage = stage
					found             = true
					break
				}
			}
			if !found {
				error(checker, a.name, "unknown attribute '%s' in value declaration", name)
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
		if decl.descriptor_set != -1 {
			error(checker, decl, "attribute 'descriptor_set' can only be applied to interface variables")
		}
		return
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
	case .Input, .Output:
		location_required = decl.builtin == nil
	case .Push_Constant, .Ray_Payload, .Shared, .Hit_Attribute, .Incoming_Ray_Payload:
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
				interface_ident,
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
				interface_ident,
				"variable with '%s' attribute requires an explicit location to be specified",
				interface_kind_names[decl.interface],
			)
		}
	}

	if decl.descriptor_set != -1 {
		return
	}
	#partial switch decl.interface {
	case .Uniform, .Uniform_Buffer, .Storage_Buffer:
		decl.descriptor_set = 0
	}

	return
}

collect_decls :: proc(checker: ^Checker, stmts: []^Ast_Stmt, global: bool, entities: ^[dynamic]^Entity) {
	for stmt in stmts {
		v := stmt.derived_stmt.(^Decl_Import) or_continue

		if !checker.scope.allow_imports {
			error(checker, v, "Imports must be placed at file scope")
			return
		}

		path := v.path.value.(string)
		name := path
		if v.alias != nil {
			name = v.alias.text
		} else {
			cut := strings.last_index_any(name, ":/")
			if cut != -1 && cut != len(name) - 1 {
				name = name[cut + 1:]
			}

			name_valid := true
			for char in name {
				switch char {
				case '0' ..= '9', 'a' ..= 'z', 'A' ..= 'Z', '_':
					continue
				}
				name_valid = false
				break
			}

			name_valid &&= len(name) > 0

			if !name_valid {
				error(checker, v.path, "'%s' is not a valid package name, consider renaming the imported package: `import foo \"%s\"`", name, path)
				continue
			}
		}

		library     := checker.libraries[path]
		entity_kind := Entity_Kind.Library
		if library == nil {
			error(checker, v.path, "Imported library does not exist: \"%v\"", path)
			entity_kind = .Invalid
		}

		checker.used_libraries[library] = path

		e: ^Entity
		if v.alias != nil {
			e = entity_new(checker, entity_kind, v.alias, t_invalid)
		} else {
			e = entity_new_no_ident(checker, entity_kind, name, t_invalid)
		}
		e.library = library
		e.decl    = v
		e.flags   = { .Resolved, }
		v.entity  = e
		scope_insert_entity(checker, e)
	}

	for stmt in stmts {
		v := stmt.derived_stmt.(^Decl_Extension) or_continue

		if checker.scope.kind != .Global {
			error(checker, v, "extension declarations must be placed at file scope")
			return
		}

		extension := check_expr(checker, v.extension)
		_, ok     := extension.value.(string)
		if !ok {
			error(checker, extension, "expected a constant string in extension name")
		}

		for stmt in v.body {
			v, ok := stmt.derived_stmt.(^Decl_Value)
			if !ok {
				error(checker, v, "only procedure declarations are allowed in extension declarations")
				continue
			}

			if len(v.lhs) != 1 {
				error(checker, v, "only procedure declarations are allowed in extension declarations")
				continue
			}

			if len(v.values) != 1 {
				error(checker, v, "only procedure declarations are allowed in extension declarations")
				continue
			}

			if v.mutable {
				error(checker, v, "only procedure declarations are allowed in extension declarations")
				continue
			}

			type := type_any_new(checker.allocator)
			e    := entity_new(checker, .Proc, v.lhs[0], type, decl = v, flags = { .Extension_Proc, })
			scope_insert_entity(checker, e)
			append(entities, e)
		}
	}

	for stmt in stmts {
		d := stmt.derived_stmt.(^Decl_Value) or_continue
		if d.mutable && !global {
			continue
		}

		flags := check_decl_attributes(checker, d, true)

		entity_kind := Entity_Kind.Invalid
		for lhs in d.lhs {
			ident: ^Expr_Ident
			ok:     bool
			if ident, ok = lhs.derived_expr.?; !ok {
				error(checker, lhs, "variable declaration must be an identifier")
				continue
			}

			type := type_any_new(checker.allocator)
			e    := entity_new(checker, entity_kind, ident, type, decl = d, flags = flags)
			scope_insert_entity(checker, e)
			append(entities, e)
		}

		if len(d.values) != 0 {
			if len(d.values) > len(d.lhs) {
				error(checker, d, "too many values in multi value declaration, expected %d, got %d", len(d.lhs), len(d.values))
			}
			if len(d.values) < len(d.lhs) {
				error(checker, d, "not enough values in multi value declaration, expected %d, got %d", len(d.lhs), len(d.values))
			}
		}
	}

	for stmt in stmts {
		v    := stmt.derived_stmt.(^Stmt_When) or_continue
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

check_decl_init_value :: proc(checker: ^Checker, value: Operand, expect_constant: bool) {
	switch value.mode {
	case .Const:
	case .RValue, .LValue:
		if .Constant_Compound in value.flags || !expect_constant {
			break
		}
		error(checker, value, "expected a constant expression in global variable declaration")
	case .Builtin:
		error(checker, value, "expected an expression, got builtin")
	case .Type:
		error(checker, value, "expected an expression, got type")
	case .No_Value:
		error(checker, value, "expected an expression, got no value")
	case .Library:
		error(checker, value, "expected an expression, got library")
	case .Ellipsis:
		error(checker, value, "illegal use of ellipsis ('..')")
	case .Label:
		error(checker, value, "invalid use of label")
	case .Proc:
		error(checker, value, "invalid use of procedure")
	case .Proc_Group:
		error(checker, value, "invalid use of procedure group")
	case .Invalid:
	}
}

decl_resolve :: proc(checker: ^Checker, e: ^Entity) {
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
	d           := e.decl.derived_decl.(^Decl_Value)
	value_index := -1
	for lhs, i in d.lhs {
		ident := lhs.derived_expr.(^Expr_Ident) or_else {}
		if ident.text == e.name {
			value_index = i
			break
		}
	}
	assert(value_index != -1)

	type: ^Type
	if d.type_expr != nil {
		type = check_type(checker, d.type_expr)
	}

	assign_type :: proc(dst, src: ^Type) {
		size := size_of(Type)
		switch v in src.variant {
		case ^Type_Struct:
			size = size_of(Type_Struct)
		case ^Type_Matrix:
			size = size_of(Type_Matrix)
		case ^Type_Array:
			size = size_of(Type_Array)
		case ^Type_Buffer:
			size = size_of(Type_Buffer)
		case ^Type_Proc:
			size = size_of(Type_Proc)
		case ^Type_Proc_Group:
			size = size_of(Type_Proc_Group)
		case ^Type_Image:
			size = size_of(Type_Image)
		case ^Type_Enum:
			size = size_of(Type_Enum)
		case ^Type_Bit_Set:
			size = size_of(Type_Bit_Set)
		case ^Type_Complex:
			size = size_of(Type_Complex)
		case ^Type_Opaque:
			size = size_of(Type_Opaque)
		case ^Type_Named:
			size = size_of(Type_Named)
		case ^Type_Fixed:
			size = size_of(Type_Fixed)
		}
		mem.copy(dst, src, size)
	}

	if len(d.values) == 0 {
		check_decl_interface_type(checker, e.decl.derived_decl.(^Decl_Value), type)
		e.kind                  = .Var
		d.lhs[value_index].type = type
		assign_type(e.type, type)
		return
	}

	if value_index >= len(d.values) {
		return
	}

	v := check_expr_internal(
		checker,
		d.values[value_index],
		d.attributes,
		type,
		false,
		is_entry_point = d.shader_stage != nil,
	)

	switch v.mode {
	case .Invalid:
		e.kind = .Invalid
	case .Type:
		// extension ops will have their kind set to .Proc, we should probably have an actual destinction here with '---'
		if e.kind == .Proc {
			break
		}
		e.kind = .Type
		if .Type_Distinct in v.flags {
			v.type = type_named_new(e.name, v.type, checker.allocator)
		}
	case .Proc:
		e.kind = .Proc
	case .Proc_Group:
		e.kind = .Proc_Group
	case .Library:
		e.kind    = .Library
		e.library = v.library
	case .Builtin:
		e.kind       = .Builtin
		e.builtin_id = v.builtin_id
	case .Const:
		e.kind  = .Const
		e.value = v.value
	case .RValue, .LValue:
		if !d.mutable {
			error(checker, v, "expected a constant expression or type in constant declaration")
			e.kind = .Invalid
		}
	case .No_Value:
		error(checker, v, "expected an expression, got no value")
	case .Ellipsis:
		error(checker, v, "illegal use of ellipsis ('..')")
	case .Label:
		error(checker, v, "invalid use of label")
	}

	if d.mutable {
		e.kind  = .Var
		e.value = nil
		check_decl_init_value(checker, v, true)
	}

	if type == nil {
		type = v.type
		if e.kind != .Const {
			type = default_type(type)
		}
	} else {
		check_assignment(checker, type, v.type, v.expr, "value declaration")
	}

	assign_type(e.type, type)

	if v.mode == .Proc {
		e.flags -= { .In_Progress, }
		e.flags += { .Resolved, }

		if d.shader_stage != nil {
			checker.shader_stage = d.shader_stage
		}
		if lit, ok := d.values[value_index].derived.(^Expr_Proc_Lit); ok {
			_ = check_expr_or_type(checker, lit, d.attributes, type, true, is_entry_point = d.shader_stage != nil)
			if d.shader_stage != nil {
				checker.shader_stage = nil
			}
		}
	}

	if .Enable_Reflection in checker.flags && d.shader_stage != nil {
		type    := type.variant.(^Type_Proc)
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

	d.lhs[value_index].type    = type
	d.values[value_index].type = type
}

check_const_stmts :: proc(checker: ^Checker, stmts: []^Ast_Stmt) {
	entities := make([dynamic]^Entity, context.temp_allocator)
	collect_decls(checker, stmts, checker.scope.kind == .Global, &entities)
	for e in entities {
		decl_resolve(checker, e)
	}
}

check_stmt_list :: proc(checker: ^Checker, stmts: []^Ast_Stmt, ignore_constants := false) -> (diverging: bool) {
	if !ignore_constants {
		check_const_stmts(checker, stmts)
	}

	for stmt, i in stmts {
		d := check_stmt(checker, stmt)
		if d && !diverging && i != len(stmts) - 1 {
			error(checker, stmt, "statements after this statement are never executed")
		}
		diverging ||= d
	}

	return diverging
}

@(private = "file")
checker_init :: proc(
	checker:       ^Checker,
	defines:       map[string]Const_Value,
	shared_types:  map[string]^Type,
	libraries:     map[string]Library,
	flags:         Checker_Flags,
	allocator       := context.allocator,
	error_allocator := context.allocator,
) {
	checker.allocator                         = allocator
	checker.reflection.interface.allocator    = allocator
	checker.reflection.entry_points.allocator = allocator
	checker.error_allocator                   = error_allocator
	checker.errors                            = make([dynamic]Error, error_allocator)
	checker.flags                             = flags
	checker.libraries                         = make(map[string]^Library, allocator)
	checker.used_libraries                    = make(map[^Library]string, allocator)

	_ = scope_push(checker, .Global)

	create_builtin_type :: proc(checker: ^Checker, type: ^Type, type_expr := #caller_expression(type)) {
		name := type_expr[len("t_"):]
		scope_insert_entity(checker, entity_new_no_ident(checker, .Type, name, type, flags = { .Resolved, }))
	}

	create_builtin_type(checker, t_bool)
	scope_insert_entity(checker, entity_new_no_ident(checker, .Const, "true",  t_bool, value = true,  flags = { .Resolved, }))
	scope_insert_entity(checker, entity_new_no_ident(checker, .Const, "false", t_bool, value = false, flags = { .Resolved, }))

	create_builtin_type(checker, t_i8)
	create_builtin_type(checker, t_i16)
	create_builtin_type(checker, t_i32)
	create_builtin_type(checker, t_i64)

	create_builtin_type(checker, t_u8)
	create_builtin_type(checker, t_u16)
	create_builtin_type(checker, t_u32)
	create_builtin_type(checker, t_u64)

	create_builtin_type(checker, t_f16)
	create_builtin_type(checker, t_f32)
	create_builtin_type(checker, t_f64)

	create_builtin_type(checker, t_complex64)
	create_builtin_type(checker, t_complex128)

	create_builtin_type(checker, t_quaternion128)
	create_builtin_type(checker, t_quaternion256)

	create_builtin_type(checker, t_any)

	@(require_results)
	find_or_create_lib :: proc(checker: ^Checker, name: string) -> (library: ^Library) {
		library = checker.libraries[name]
		if library == nil {
			checker.libraries[name] = new_clone(Library{ scope = scope_new(nil, .Global, checker.allocator), })
			library                 = checker.libraries[name]
		}
		return
	}

	create_library_type :: proc(checker: ^Checker, library: ^Library, type: ^Type, type_expr := #caller_expression(type)) {
		name := strings.trim_prefix(type_expr, "t_")
		library.scope.entities[name] = entity_new_no_ident(checker, .Type, name, type, flags = { .Resolved, })
	}

	for name, builtin in builtin_names {
		create_builtin_proc :: proc(checker: ^Checker, name: string, builtin: Builtin_Id) -> ^Entity {
			return entity_new_no_ident(
				checker,
				.Builtin,
				name,
				t_invalid,
				builtin_id = builtin,
				flags      = { .Resolved, },
			)
		}

		name     := name
		dot      := strings.index(name, ".")
		if dot >= 0 {
			lib                     := find_or_create_lib(checker, name[:dot])
			name                     = name[dot + 1:]
			lib.scope.entities[name] = create_builtin_proc(checker, name, builtin)
		} else {
			lib                         := find_or_create_lib(checker, "base:builtin")
			e                           := create_builtin_proc(checker, name, builtin)
			lib.scope.entities[name]     = e
			checker.scope.entities[name] = e
		}
	}

	for name, &lib in libraries {
		assert(name not_in checker.libraries, "base libraries can not be overwritten")
		checker.libraries[name] = &lib
	}

	file_scope              := scope_push(checker, .Global)
	file_scope.allow_imports = true

	checker.shared_types = shared_types
	checker.config_vars  = defines
}

@(require_results)
type_info_to_type :: proc(ti: ^reflect.Type_Info, allocator := context.allocator) -> (type: ^Type, ok: bool) {
	switch v in ti.variant {
	case reflect.Type_Info_Named:
		return type_info_to_type(v.base, allocator)
	case reflect.Type_Info_Integer:
		switch ti.size {
		case 1:
			return t_i8  if v.signed else t_u8, true
		case 2:
			return t_i16 if v.signed else t_u16, true
		case 4:
			return t_i32 if v.signed else t_u32, true
		case 8:
			return t_i64 if v.signed else t_u64, true
		case:
			return
		}
	case reflect.Type_Info_Rune:
		return t_i32, true
	case reflect.Type_Info_Float:
		switch ti.size {
		case 4:
			return t_f32, true
		case 8:
			return t_f64, true
		case:
			return
		}
	case reflect.Type_Info_Complex:
		elem: ^Type
		switch ti.size {
		case 8:
			elem = t_f32
		case 16:
			elem = t_f64
		case:
			return
		}
		return type_array_new(elem, 2, allocator), true
	case reflect.Type_Info_Quaternion:
		elem: ^Type
		switch ti.size {
		case 16:
			elem = t_f32
		case 32:
			elem = t_f64
		case:
			return
		}
		return type_array_new(elem, 4, allocator), true
	case reflect.Type_Info_String:
		return
	case reflect.Type_Info_Boolean:
		switch ti.size {
		case 1:
			return t_bool, true
		case 2:
			return t_i16, true
		case 4:
			return t_i32, true
		case 8:
			return t_i64, true
		case:
			return
		}
	case reflect.Type_Info_Any:
		return
	case reflect.Type_Info_Type_Id:
		return
	case reflect.Type_Info_Pointer:
		return
	case reflect.Type_Info_Multi_Pointer:
		return
	case reflect.Type_Info_Procedure:
		return
	case reflect.Type_Info_Array:
		return type_array_new(type_info_to_type(v.elem, allocator) or_return, i64(v.count), allocator), true
	case reflect.Type_Info_Enumerated_Array:
		unimplemented()
	case reflect.Type_Info_Dynamic_Array, reflect.Type_Info_Fixed_Capacity_Dynamic_Array:
		return
	case reflect.Type_Info_Slice:
		return
	case reflect.Type_Info_Parameters:
		return
	case reflect.Type_Info_Struct:
		if .raw_union in v.flags {
			if v.field_count != 2 {
				return
			}
			if ti.size != 8 {
				return
			}
			tag, ok := reflect.struct_tag_lookup(auto_cast v.tags[1], "hephaistos")
			if !ok {
				return
			}
			if tag != "buffer_device_address" {
				return
			}
			ptr  := v.types[1].variant.(reflect.Type_Info_Pointer)
			elem := type_info_to_type(ptr.elem, allocator) or_return
			return type_buffer_new(elem, true, allocator), true
		}

		fields := make([]^Entity, v.field_count, allocator)
		scope  := scope_new(nil, .Struct, allocator)
		for &f, i in fields {
			f             = new(Entity, allocator)
			f.kind        = .Struct_Field
			f.name        = v.names[i]
			f.type        = type_info_to_type(v.types[i], allocator) or_return
			f.offset      = i64(v.offsets[i])
			f.flags       = { .Resolved, }
			f.field_index = i

			scope.entities[f.name] = f
		}
		s       := type_new(.Struct, Type_Struct, allocator)
		s.size   = i64(ti.size)
		s.align  = i64(ti.align)
		s.fields = fields
		s.scope  = scope
		return s, true
	case reflect.Type_Info_Union:
		return
	case reflect.Type_Info_Enum:
		e      := type_new(.Enum, Type_Enum, allocator)
		values := make([]^Entity, len(v.values), allocator)
		scope  := scope_new(nil, .Enum, allocator)
		for &value, i in values {
			value       = new(Entity, allocator)
			value.kind  = .Enum_Value
			value.value = i64(v.values[i])
			value.name  = v.names[i]
			value.flags = { .Resolved, }
			value.type  = e

			scope.entities[value.name] = value
		}
		e.backing = type_info_to_type(v.base, allocator) or_return
		e.size    = e.backing.size
		e.align   = e.backing.align
		e.values  = values
		e.scope   = scope
		return e, true
	case reflect.Type_Info_Map:
		return
	case reflect.Type_Info_Bit_Set:
		return type_info_to_type(v.underlying, allocator)
	case reflect.Type_Info_Simd_Vector:
		return type_array_new(type_info_to_type(v.elem, allocator) or_return, i64(v.count), allocator), true
	case reflect.Type_Info_Matrix:
		elem := type_info_to_type(v.elem, allocator) or_return
		col  := type_array_new(elem, i64(v.row_count), allocator)
		return type_matrix_new(col, i64(v.column_count), allocator), true
	case reflect.Type_Info_Soa_Pointer:
		return
	case reflect.Type_Info_Bit_Field:
		return type_info_to_type(v.backing_type, allocator)
	}
	unreachable()
}

@(require_results)
shared_types_from_typeids :: proc(typeids: []typeid, allocator := context.allocator) -> (ts: map[string]^Type) {
	ts = make(map[string]^Type, allocator)
	for t in typeids {
		ti            := type_info_of(t)
		named         := ti.variant.(reflect.Type_Info_Named) or_else panic("only named types can be shared")
		type          := type_info_to_type(named.base, allocator) or_else fmt.panicf("type can not be shared: %v", ti)
		ts[named.name] = type
	}
	return
}

@(require_results)
check :: proc(
	stmts:     []^Ast_Stmt,
	defines:   map[string]Const_Value = {},
	types:     []typeid               = {},
	libraries: map[string]Library     = {},
	flags:     Checker_Flags          = {},
	allocator       := context.allocator,
	error_allocator := context.allocator,
) -> (checker: Checker, errors: []Error) {
	shared_types := shared_types_from_typeids(types, allocator)
	return check_with_types(stmts, defines, shared_types, libraries, flags, allocator, error_allocator)
}

@(require_results)
check_with_types :: proc(
	stmts:     []^Ast_Stmt,
	defines:   map[string]Const_Value = {},
	types:     map[string]^Type       = {},
	libraries: map[string]Library     = {},
	flags:     Checker_Flags          = {},
	allocator       := context.allocator,
	error_allocator := context.allocator,
) -> (checker: Checker, errors: []Error) {
	checker_init(&checker, defines, types, libraries, flags, allocator, error_allocator)
	check_stmt_list(&checker, stmts)
	check_scope_end(&checker)
	return checker, checker.errors[:]
}

@(require_results)
op_is_relation :: proc(token_kind: Token_Kind) -> bool {
	#partial switch token_kind {
	case .Equal, .Not_Equal, .Less_Equal, .Greater_Equal, .Less, .Greater:
		return true
	}
	return false
}

@(require_results)
evaluate_const_binary_op :: proc(checker: ^Checker, lhs, rhs: Const_Value, expr: ^Expr_Binary, truncating_integer_division: ^bool) -> Const_Value {
	assert(lhs != nil)
	assert(rhs != nil)

	lhs := lhs
	rhs := rhs

	lhs_tag := (^intrinsics.type_union_tag_type(Const_Value))(uintptr(&lhs) + intrinsics.type_union_tag_offset(Const_Value))^
	rhs_tag := (^intrinsics.type_union_tag_type(Const_Value))(uintptr(&rhs) + intrinsics.type_union_tag_offset(Const_Value))^

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
			truncating_integer_division^ = l % r != 0
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

	error(checker, expr, "mismatched types in binary expression: %v vs %v", lhs, rhs)
	return nil
}

@(require_results)
check_proc_type :: proc(checker: ^Checker, p: ^Expr_Proc_Sig, is_entry_point: bool) -> ^Type_Proc {
	@(require_results)
	check_field_list :: proc(checker: ^Checker, fields: []Ast_Field, args: bool, scope: ^Scope, is_entry_point: bool) -> (out_fields: [dynamic]^Entity) {
		out_fields.allocator = checker.allocator
		reserve(&out_fields, len(fields))

		locations          := make(map[i64]string, context.temp_allocator)
		explicit_locations := false

		usage := "input" if args else "output"

		for i := 0; i < len(fields); {
			start := i
			type: ^Type
			for i < len(fields) {
				defer i += 1
				field := fields[i]
				ident: string
				if field.name != nil {
					ident = field.name.text
				}

				location := i64(i)
				if field.location != nil {
					// TODO: matrices with mutliple locations

					if !is_entry_point {
						error(checker, field.location, "location specifiers are only allowed on entry points")
					}

					loc := check_expr(checker, field.location)
					if l, ok := loc.value.(i64); ok && l != -1 {
						if i == 0 {
							explicit_locations = true
						}

						if !explicit_locations {
							error(checker, field.location, "location specifiers have to be specified for either all or none of the %ss", usage)
						}

						location = l

						if prev, prev_found := locations[location]; prev_found {
							error(checker, field.location, "duplicate location specifier: location %v is already used by '%s'", location, prev)
						}
						locations[location] = ident
					} else {
						error(checker, field.location, "location specifier has to be a constant integer")
					}
				} else {
					if explicit_locations {
						error(checker, field.name, "location specifiers have to be specified for either all or none of the %ss", usage)
					}
				}

				e := entity_new(checker, .Proc_Param if args else .Proc_Return, field.name, t_invalid, flags = field.flags | { .Resolved, })
				if is_entry_point {
					e.location = location
				}
				scope_insert_entity(checker, e, scope)
				append(&out_fields, e)

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
				if !implicitly_castable(value.type, type) {
					error(
						checker,
						field.name.start,
						field.value.end,
						"default value type does not match declared type: %v vs %v",
						type,
						value.type,
					)
				}
				break
			}

			for i in start ..< i {
				if type == nil {
					error(checker, fields[i].name, "field is missing a type")
					out_fields[i].type = t_invalid
				} else {
					out_fields[i].type = type
				}
			}
		}

		return
	}

	scope   := scope_new(nil, .Proc_Sig, checker.allocator)
	args    := check_field_list(checker, p.args,    true,  scope, is_entry_point)
	returns := check_field_list(checker, p.returns, false, scope, is_entry_point)

	t          := type_new(.Proc, Type_Proc, checker.allocator)
	t.args      = args[:]
	t.returns   = returns[:]
	t.diverging = p.diverging

	if len(returns) == 1 {
		t.return_type = returns[0].type
	} else {
		return_type       := type_new(.Tuple, Type_Struct, checker.allocator)
		return_type.fields = returns[:]
		t.return_type      = return_type
	}

	return t
}

@(require_results)
check_expr_internal :: proc(
	checker:          ^Checker,
	expr:             ^Ast_Expr,
	attributes:      []Ast_Field,
	type_hint:        ^Type = nil,
	check_proc_bodies: bool = true,
	is_entry_point:    bool = false,
) -> (operand: Operand) {
	operand.expr = expr
	operand.mode = .Invalid
	operand.type = t_invalid

	defer {
		#partial switch operand.mode {
		case .RValue, .LValue, .Const, .Type:
			assert(operand.type.kind != .Invalid)
		}
		expr.type        = operand.type
		expr.const_value = operand.value
	}

	switch v in expr.derived_expr {
	case ^Expr_Constant:
		switch val in v.value {
		case i64:
			operand.type  = t_int
			operand.value = val
		case f64:
			operand.type  = t_float
			operand.value = val
		case bool:
			operand.type  = t_bool
			operand.value = val
		case string:
			operand.type  = t_string
			operand.value = val
		}

		operand.mode = .RValue
		switch v.imaginary {
		case .i:
			operand.type = t_complex64
		case .j, .k:
			operand.type = t_quaternion128
		case .real:
			operand.mode = .Const
		}

		return

	case ^Expr_Binary:
		if v.op == .In {
			rhs  := check_expr(checker, v.rhs)
			base := base_type(rhs.type)

			operand.type = t_bool
			operand.mode = .RValue

			if rhs.mode == .Invalid {
				_ = check_expr(checker, v.lhs, type_hint = t_invalid)
				return
			}

			if !type_is_bit_set(base) {
				error(checker, v, "'in' expressions are only allowed on bit sets")
				return
			}
			bits := base.variant.(^Type_Bit_Set)
			lhs  := check_expr(checker, v.lhs, type_hint = bits.enum_type)

			if !type_equal(lhs.type, bits.enum_type) {
				error(checker, v.lhs, "expected expression of type %v, got %v", bits.enum_type, lhs.type)
			}

			return
		}

		lhs := check_expr(checker, v.lhs, type_hint = type_hint)
		rhs := check_expr(checker, v.rhs, type_hint = lhs.type)

		if lhs.mode == .Invalid && rhs.mode == .Invalid {
			if op_is_relation(v.op) {
				operand.type = t_bool
				operand.mode = .RValue
			}
			return
		}

		if type_is_invalid(lhs.type) {
			operand.mode = .RValue
			operand.type = rhs.type
			if op_is_relation(v.op) {
				operand.type = t_bool
			}
			return
		}

		if type_is_invalid(rhs.type) {
			operand.mode = .RValue
			operand.type = lhs.type
			if op_is_relation(v.op) {
				operand.type = t_bool
			}
			return
		}

		operand.type = op_result_type(lhs.type, rhs.type, v.op == .Multiply, checker.allocator)
		if operand.type.kind == .Invalid {
			error(checker, expr, "mismatched types in binary expression: %v vs %v", lhs.type, rhs.type)
			operand.mode = .Invalid
			return
		}

		if v.op != .Multiply || !(type_is_matrix(lhs.type) || type_is_matrix(rhs.type)) {
			v.lhs.type = operand.type
			v.rhs.type = operand.type
		}

		if !operator_applicable(operand.type, v.op) {
			error(checker, v, "operator `%v` is not defined for `%v %v %v`", token_to_string(v.op), lhs.type, token_to_string(v.op), rhs.type)
			return
		}

		operand.mode = .RValue
		if op_is_relation(v.op) {
			operand.type = t_bool
		}

		if lhs.mode == .Const && rhs.mode == .Const {
			truncating_integer_division: bool
			operand.value = evaluate_const_binary_op(checker, lhs.value, rhs.value, v, &truncating_integer_division)
			operand.mode  = .Const
			if truncating_integer_division && type_hint != nil && implicitly_castable(t_float, type_hint) {
				error(checker, v, "result of integer division is being implicitly converted to floating point, consider explicitly casting the expression to '%v'", type_hint)
			}
		}

	case ^Expr_Ident:
		if v.text == "_" {
			error(checker, v, "invalid use of blank identifier ('_')")
			return
		}
		e, ok := check_ident(checker, v)
		if !ok {
			operand.type = t_invalid
			operand.mode = .Invalid
			return
		}
		entity_to_operand(checker, e, &operand)
		return

	case ^Expr_Interface:
		if info, ok := interface_infos[v.ident.text]; ok {
			switch info.usage[checker.shader_stage] {
			case nil:
				error(checker, v.ident, "builtin %s can not be used in %s", v.ident.text, shader_stage_names[checker.shader_stage])
				operand.mode = .LValue
			case .In:
				operand.mode = .RValue
			case .Out:
				operand.mode = .LValue
			}
			operand.type = info.type
			assert(info.type != nil)
		} else {
			error(checker, v.ident, "unknown builtin: '%s'", v.ident.text)
			return
		}

	case ^Expr_Proc_Lit:
		type: ^Type_Proc
		if v.type == nil {
			type = check_proc_type(checker, v, is_entry_point)
		} else {
			// the type may have already been checked to allow recursion and we don't want to error twice
			type = v.type.variant.?
		}

		operand.type = type
		operand.mode = .Proc

		if !check_proc_bodies {
			return
		}

		scope_push(checker, .Proc).proc_type = type
		defer scope_pop(checker)

		for arg in type.args {
			scope_insert_entity(checker, arg)
		}

		for ret in type.returns {
			scope_insert_entity(checker, ret)
		}

		v.scope = scope_push(checker, .Block)
		defer scope_pop(checker)

		diverging := check_stmt_list(checker, v.body)

		if !diverging && len(type.returns) != 0 {
			error(checker, v.end, "procedure is missing a return statement")
		}

	case ^Expr_Proc_Sig:
		operand.type = check_proc_type(checker, v, false)
		operand.mode = .Type

	case ^Expr_Proc_Group:
		members := make([]^Type_Proc, len(v.members), checker.allocator)
		for member, i in v.members {
			if _, ok := member.derived.(^Expr_Proc_Lit); ok {
				error(checker, member, "members of procedure groups need to be named, got procedure literal")
				continue
			}

			m := check_expr(checker, member)
			if m.mode != .Proc {
				error(checker, m, "expected a procedure as proc group member")
			} else {
				members[i] = m.type.variant.(^Type_Proc)
			}
		}

		// TODO: check for duplicates in members

		type        := type_new(.Proc_Group, Type_Proc_Group, checker.allocator)
		type.members = members

		operand.mode = .Proc_Group
		operand.type = type
		return
	case ^Expr_Paren:
		return check_expr_internal(checker, v.expr, {}, type_hint, check_proc_bodies = check_proc_bodies, is_entry_point = is_entry_point)

	case ^Expr_Ellipsis:
		operand := check_expr_internal(checker, v.expr, {})
		if type_is_array(operand.type) {
			operand.mode = .Ellipsis
		} else {
			error(checker, operand, "'..' can only be applied to arrays, got %v", operand.type)
			operand.mode = .Invalid
			operand.type = t_invalid
		}
		return operand

	case ^Expr_Selector:
		defer v.selector.type = operand.type

		if v.lhs == nil {
			if type_hint == nil {
				error(checker, v, "missing type in implicit selector")
				return
			}

			if type_hint.kind == .Invalid {
				return
			}

			base := base_type(type_hint)

			if base.kind != .Enum {
				error(checker, v, "implicit selectors can only be used for enum types, got '%v'", type_hint)
				return
			}

			entity, ok := check_ident(checker, v.selector, base.variant.(^Type_Enum).scope)
			if !ok {
				return
			}

			operand.type  = type_hint
			operand.value = entity.value
			operand.mode  = .Const
			return
		}

		lhs := check_expr_internal(checker, v.lhs, {})

		#partial switch lhs.mode {
		case .Builtin:
			error(checker, operand, "expected an expression, got builtin")
			return
		case .No_Value:
			error(checker, operand, "expected an expression, got no value")
			return
		case .Invalid:
			return
		}

		if lhs.mode == .Library {
			e, ok := check_ident(checker, v.selector, lhs.library.scope)
			if !ok {
				return
			}
			entity_to_operand(checker, e, &operand)
			return
		}

		base := base_type(lhs.type)

		if lhs.mode == .Type {
			if base.kind != .Enum {
				error(checker, v, "expected an expression or an enum type, got '%v'", lhs.type)
				return
			}


			entity, ok := check_ident(checker, v.selector, base.variant.(^Type_Enum).scope)
			if !ok {
				return
			}

			operand.type  = lhs.type
			operand.value = entity.value
			operand.mode  = .Const
			return
		}

		#partial switch base.kind {
		case .Array:
			array    := base.variant.(^Type_Array)
			selector := v.selector.text
			indices  := make([dynamic]u32, 0, len(selector), checker.allocator)

			duplicates := false
			seen: [4]bool
			for char in selector {
				index: i64 = -1
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
				append(&indices, u32(index))

				if index == -1 || index >= array.count {
					error(checker, v, "can not swizzle vector of type '%s' with coordinate '%v'", array, char)
				}
				if index != -1 {
					if seen[index] {
						duplicates = true
					}
					seen[index] = true
				}
			}

			v.swizzle = indices[:]

			operand.mode = lhs.mode
			if duplicates {
				operand.mode = .RValue
			}

			switch i64(len(selector)) {
			case 1:
				operand.type = array.elem
			case array.count:
				operand.type = array
			case:
				operand.type = type_array_new(array.elem, i64(len(selector)), checker.allocator)
			}

			return
		case .Struct:
			type        := base.variant.(^Type_Struct)
			entity      := check_ident(checker, v.selector, type.scope) or_break
			operand.type = entity.type
			operand.mode = lhs.mode
		case .Invalid:
		case:
			error(checker, v, "expression of type %v has no field called '%s'", lhs.type, v.selector.text)
		}

	case ^Expr_Call:
		if directive, ok := v.lhs.derived_expr.(^Expr_Directive); ok {
			v.is_directive = true
			operand.type   = t_invalid
			switch directive.directive {
			case .Invalid:
				operand.type = t_invalid
				operand.mode = .Invalid
			case .Assert:
				cond:    bool
				message: string
				switch len(v.args) {
				case 0:
					error(checker, v, "#assert expects one to two arguments, got 0")
				case:
					error(checker, v, "#assert expects one to two arguments, got %d", len(v.args))
					fallthrough
				case 2:
					msg := check_expr(checker, v.args[1].value)
					ok: bool
					message, ok = msg.value.(string)
					if !ok {
						error(checker, v.args[1].value, "expected a constant string as #assert message")
					}
					fallthrough
				case 1:
					e := check_expr(checker, v.args[0].value)
					ok: bool
					cond, ok = e.value.(bool)
					if ok {
						break
					}
					cond = true
					if e.mode != .Invalid {
						error(checker, v.args[0].value, "expected a constant boolean in #assert")
					}
				}
				if !cond {
					error(checker, v, "Compile time assertion failure: %v", message)
				}
				operand.mode = .No_Value
			case .Panic:
				message: string
				switch len(v.args) {
				case 0:
					error(checker, v, "#panic expects one argument, got 0")
				case:
					error(checker, v, "#panic expects one argument, got %d", len(v.args))
					fallthrough
				case 1:
					msg := check_expr(checker, v.args[0].value)
					ok: bool
					message, ok = msg.value.(string)
					if !ok {
						error(checker, v.args[0].value, "expected a constant string as #panic message")
					}
				}
				error(checker, v, "Compile time panic: %v", message)
				operand.mode = .No_Value
			case .Import:
				if len(v.args) != 1 {
					error(checker, v, "#import directive expects one argument, got %d", len(v.args))
					return
				}

				name: string
				if ident, ok := v.args[0].value.derived_expr.(^Expr_Ident); ok {
					name = ident.text
				} else {
					error(checker, v.args[0].value, "expected an identifier as the name of the config variable")
					return
				}

				type, ok := checker.shared_types[name]
				if !ok {
					error(checker, v.args[0].value, "unknown shared type: %s", name)
					return
				}

				// only for the lsp
				v.args[0].value.type = type
				v.lhs.type           = type

				operand.type = type
				operand.mode = .Type
			case .Config:
				if len(v.args) != 2 {
					error(checker, v, "#config directive expects two arguments, got %d", len(v.args))
					return
				}
				default := check_expr(checker, v.args[1].value)
				#partial switch _ in default.value {
				case i64, f64, bool:
				case:
					error(checker, default, "default value for config variable has to be a constant boolean or number, got: %v")
					return
				}
				operand.value = default.value
				operand.type = default.type
				operand.mode = .Const

				name: string
				if ident, ok := v.args[0].value.derived_expr.(^Expr_Ident); ok {
					name = ident.text
				} else {
					error(checker, v.args[0].value, "expected an identifier as the name of the config variable")
					return
				}

				if definition, ok := checker.config_vars[name]; ok {
					if reflect.get_union_variant_raw_tag(definition) != reflect.get_union_variant_raw_tag(default.value) {
						error(checker, v, "type of defined value does not match the type of the default value")
						return
					}
					operand.value = definition
				}
			case .Capability:
				operand.mode = .No_Value
			}
			return
		}
		fn := check_expr_internal(checker, v.lhs, {})
		#partial switch fn.mode {
		case .Invalid:
			for arg in v.args {
				_ = check_expr(checker, arg.value, type_hint = t_invalid)
			}
			return
		case .Builtin:
			return check_builtin(checker, v, fn)
		case .Type:
			v.is_cast = true

			if len(v.args) != 1 {
				error(checker, v, "too many arguments in cast to %v", fn.type)
				return
			}
			value := check_expr(checker, v.args[0].value)
			if !castable(value.type, fn.type) {
				error(checker, v, "can not cast expression from type %v to %v", value.type, fn.type)
			}
			if .Vet_Cast in checker.flags && type_equal(value.type, fn.type) {
				error(checker, v, "uneeded cast to identical type '%v'", value.type)
			}
			operand.type = fn.type
			operand.mode = .RValue
			if value.mode == .Const && type_is_numeric(core_type(fn.type)){
				operand.value = value.value
				operand.mode  = .Const
			}
		case .Proc_Group:
			group      := fn.type.variant.(^Type_Proc_Group)
			candidates := make([dynamic]^Type_Proc, len(group.members), context.temp_allocator)
			copy(candidates[:], group.members[:])

			arg_index := 0
			for arg in v.args {
				type_hint: ^Type
				if len(candidates) == 1 {
					candidate := candidates[0]
					if arg_index < len(candidate.args) {
						type_hint = candidate.args[arg_index].type
					}
				}

				args := []^Type{ check_expr(checker, arg.value, type_hint = type_hint).type, }
				deconstruct_tuple(checker, &args)

				for arg in args {
					for i := 0; i < len(candidates); {
						remove: bool
						defer if remove {
							unordered_remove(&candidates, i)
						} else {
							i += 1
						}

						candidate := candidates[i]
						if arg_index >= len(candidate.args) {
							remove = true
							continue
						}

						if !implicitly_castable(arg, candidate.args[arg_index].type) {
							remove = true
							continue
						}
					}
					arg_index += 1
				}
			}

			for i := 0; i < len(candidates); {
				candidate := candidates[i]
				if arg_index != len(candidate.args) {
					unordered_remove(&candidates, i)
				} else {
					i += 1
				}
			}

			switch len(candidates) {
			case 0:
				error(checker, fn, "no matching overload in procedure group: %v", group)
			case 1:
				for member, i in group.members {
					if member == candidates[0] {
						v.group_member = i
						break
					}
				}

				{
					fn := candidates[0]
					arg_index := 0
					for arg in v.args {
						type_hint: ^Type
						type_hint = fn.args[arg_index].type

						args := []^Type{ check_expr(checker, arg.value, type_hint = type_hint).type, }
						deconstruct_tuple(checker, &args)

						if len(args) == 1 {
							v.args[arg_index].value.type = fn.args[arg_index].type
						}
						arg_index += len(args)
					}
				}

				operand.mode = .RValue
				operand.type = candidates[0].return_type
				return
			case:
				error(checker, fn, "ambigous overloads in procedure group: %v", group)
			}

			operand.type = t_invalid
			operand.mode = .Invalid
			return

		case:
			if fn.type.kind != .Proc {
				error(checker, v, "expected a procedure in call expression")
				return
			}

			proc_type := fn.type.variant.(^Type_Proc)
			arg_index := 0
			for e in v.args {
				type_hint: ^Type
				if arg_index < len(proc_type.args) {
					type_hint = proc_type.args[arg_index].type
				}
				value := check_expr(checker, e.value, type_hint = type_hint)

				arg_types: []^Type = { value.type, }
				deconstruct_tuple(checker, &arg_types)

				for arg_type in arg_types {
					defer arg_index += 1
					if arg_index >= len(proc_type.args) {
						continue
					}
					check_assignment(checker, proc_type.args[arg_index].type, arg_type, value.expr, "procedure argument")
					if .By_Ptr in proc_type.args[arg_index].flags && value.mode != .LValue {
						error(checker, value, "argument has '#by_ptr' tag, but the provided value is not addressable")
					}
					if .Const in proc_type.args[arg_index].flags && value.mode != .Const {
						error(checker, value, "argument has '#const' tag, but the provided value is not constant")
					}
					if len(arg_types) == 1 {
						e.value.type = proc_type.args[arg_index].type
					}
				}
			}

			if arg_index != len(proc_type.args) {
				error(checker, v, "expected %d arguments but got %d", len(proc_type.args), arg_index)
			}

			operand.mode = len(proc_type.returns) == 0 ? .No_Value : .RValue
			operand.type = proc_type.return_type
			if proc_type.diverging {
				operand.flags |= { .Diverging, }
			}
		}
	case ^Expr_Compound:
		defer v.constant = .Constant_Compound in operand.flags

		type: ^Type
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
			operand.flags |= { .Constant_Compound, }
			if type.kind == .Invalid {
				operand.mode = .Invalid
			}
			return
		}

		named: bool
		for f, i in v.fields {
			if i == 0 {
				named = f.name != nil
			}
			if named != (f.name != nil) {
				err := "mixture of 'field = value' and value elements is not allowed"
				if f.name != nil {
					error(checker, f.name, err)
				} else {
					error(checker, f.value, err)
				}
			}
		}
		v.named = named

		base := base_type(type)

		#partial switch base.kind {
		case .Struct:
			type := base.variant.(^Type_Struct)

			operand.flags |= { .Constant_Compound, }

			if named {
				seen := make(map[string]struct{}, context.temp_allocator)
				for &field in v.fields {
					if field.name == nil {
						continue
					}
					name := field.name.text

					if name in seen {
						error(checker, field.name, "duplicate values in compound literal: %v", name)
					}
					seen[name] = {}

					entity := check_ident(checker, field.name, type.scope) or_continue

					field_operand := check_expr(checker, field.value, type_hint = entity.type)
					if field_operand.mode != .Const && .Constant_Compound not_in field_operand.flags {
						operand.flags -= { .Constant_Compound, }
					}
					check_assignment(checker, entity.type, field_operand.type, field.value, "struct literal")

					field.value.type = entity.type
				}
			} else {
				if len(v.fields) != len(type.fields) {
					error(checker, v, "expected %d values in compound literal but got %d", len(type.fields), len(v.fields))
					return
				}

				for field, i in v.fields {
					struct_field := type.fields[i]

					field_operand := check_expr(checker, field.value, type_hint = struct_field.type)
					if field_operand.mode != .Const && .Constant_Compound not_in field_operand.flags {
						operand.flags -= { .Constant_Compound, }
					}
					check_assignment(checker, struct_field.type, field_operand.type, field.value, "struct literal")

					field.value.type = struct_field.type
				}
			}
		case .Array:
			operand.flags |= { .Constant_Compound, }

			type := base.variant.(^Type_Array)
			if named {
				if type.count > 4 {
					error(checker, v, "swizzled initializers are only supported for arrays with up to 4 elements.")
				}
				seen: [4]bool
				for &field in v.fields {
					if field.name == nil {
						continue
					}
					name    := field.name.text
					indices := make([dynamic]u32, 0, len(name), checker.allocator)

					coords: [4]i64
					n := i64(len(name))
					for char, i in name {
						index: i64 = -1
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
						append(&indices, u32(index))
						if index == -1 || index >= type.count {
							error(checker, field.name, "can not swizzle vector of type '%s' with coordinate '%v'", type, char)
							return
						}
						if seen[index] {
							error(checker, field.name, "duplicate coordinate in vector compound literal: '%c'", char)
						}
						seen[index] = true
						coords[i]   = index
					}

					expected_type: ^Type
					if n == 1 {
						expected_type = type.elem
					} else {
						expected_type = type_array_new(type.elem, n, checker.allocator)
					}

					field.name.type = expected_type

					value := check_expr(checker, field.value, type_hint = expected_type)
					if value.mode != .Const && .Constant_Compound not_in value.flags {
						operand.flags -= { .Constant_Compound, }
					}
					check_assignment(checker, expected_type, value.type, field.value, "array literal")
					field.value.type = expected_type
					field.swizzle    = indices[:]
				}
				return
			}

			n_values: i64
			for field in v.fields {
				f := check_expr(checker, field.value, type_hint = type.elem, allow_ellipsis = true)
				t := f.type
				if f.mode == .Ellipsis {
					v        := f.type.variant.(^Type_Array)
					t         = v.elem
					n_values += v.count

					if f.mode != .Const && .Constant_Compound not_in f.flags {
						operand.flags -= { .Constant_Compound, }
					}
				} else {
					if f.mode != .Const && .Constant_Compound not_in f.flags {
						operand.flags -= { .Constant_Compound, }
					}

					if type_is_tuple(t) {
						error(checker, field.value, "multi valued expression found where single value was expected")
						n_values += 1
					} else {
						n_values        += 1
						field.value.type = type.elem
					}
				}

				check_assignment(checker, type.elem, t, field.value, "array literal")
			}

			if n_values != type.count {
				error(checker, v, "expected %d values in compound literal but got %d", type.count, n_values)
				return
			}
		case .Matrix:
			type := type.variant.(^Type_Matrix)
			if named {
				error(checker, v, "named values are not supported for matrix literals")
				return
			}
			if i64(len(v.fields)) != type.col_type.count * type.cols {
				error(checker, v, "expected %d values in compound literal but got %d", type.col_type.count * type.cols, len(v.fields))
				return
			}
			for field in v.fields {
				f := check_expr(checker, field.value, type_hint = type.col_type.elem)
				check_assignment(checker, type.col_type.elem, f.type, field.value, "matrix literal")
				field.value.type = type.col_type.elem
			}
		case .Bit_Set:
			type := type.variant.(^Type_Bit_Set)
			if named {
				error(checker, v, "named values are not supported for bit_set literals")
				return
			}
			operand.mode = .Const
			const_value: i64
			for field in v.fields {
				value := check_expr(checker, field.value, type_hint = type.enum_type)
				check_assignment(checker, type.enum_type, value.type, field.value, "array literal")
				if value.mode == .Const {
					bit: i64 = 1 << uint(value.value.(i64))
					if const_value & bit != 0 {
						error(checker, value, "duplicate value in bit_set literal")
					}
					const_value |= bit
				} else {
					operand.mode = .RValue
				}
			}
			if operand.mode == .Const {
				operand.value = const_value
			}
		case .Invalid:
			operand.mode = .Invalid
		case:
			error(checker, v, "illegal type in compound literal: %v", type)
		}

		return

	case ^Expr_Index:
		lhs := check_expr(checker, v.lhs)
		rhs := check_expr(checker, v.rhs)
		v.rhs.type = default_type(rhs.type)

		operand.mode = lhs.mode
		operand.type = t_invalid

		lhs_type := base_type(lhs.type)

		#partial switch lhs_type.kind {
		case .Matrix:
			if !type_is_integer(rhs.type) && rhs.mode != .Invalid {
				error(checker, rhs, "expected an integer as the index, but got %v", rhs.type)
			}
			operand.type = type_matrix_elem(lhs_type)
		case .Array:
			len := type_array_len(lhs_type)
			if value, ok := rhs.value.(i64); ok {
				if value >= len || len < 0 {
					error(checker, rhs, "array index out of bounds: %d ..< %d, got %d", 0, len, value)
				}
			}
			if !type_is_integer(rhs.type) && rhs.mode != .Invalid {
				error(checker, rhs, "expected an integer as the index, but got %v", rhs.type)
			}
			operand.type = type_array_elem(lhs_type)
		case .Buffer:
			if !type_is_integer(rhs.type) && rhs.mode != .Invalid {
				error(checker, rhs, "expected an integer as the index, but got %v", rhs.type)
			}
			operand.type = type_buffer_elem(lhs_type)
		case .Sampler:
			sampler := lhs_type.variant.(^Type_Image)
			if rhs.mode != .Invalid {
				if sampler.dimensions == 1 {
					if !type_is_numeric(rhs.type) {
						error(
							checker,
							rhs,
							"expected a scalar to sample texture of type %v, got: %v",
							sampler,
							rhs.type,
						)
					}
				} else if !type_is_array(rhs.type) || type_array_len(rhs.type) != sampler.dimensions {
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
			image := lhs_type.variant.(^Type_Image)
			if rhs.mode != .Invalid {
				if image.dimensions == 1 {
					if !type_is_integer(rhs.type) {
						error(
							checker,
							rhs,
							"expected an integer to access texel from image of type %v, got: %v",
							image,
							rhs.type,
						)
					}
				} else {
					if type_is_integer(rhs.type) {
						v.rhs.type = type_array_new(default_type(rhs.type), image.dimensions, checker.allocator)
					} else if !type_is_array(rhs.type) || !type_is_numeric(type_array_elem(rhs.type)) || type_array_len(rhs.type) != image.dimensions {
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
			}

			operand.type = image.texel_type
		case .Invalid:
			return
		}

		if operand.type.kind == .Invalid {
			error(checker, v, "expression of type %v can not be indexed", lhs_type)
			return
		}

	case ^Expr_Cast:
		value       := check_expr(checker, v.value)
		operand.type = check_type(checker, v.type_expr)
		if !castable(value.type, operand.type) {
			error(checker, v, "can not cast expression from type %v to %v", value.type, operand.type)
		}
		if .Vet_Cast in checker.flags && type_equal(value.type, operand.type) {
			error(checker, v, "uneeded cast to identical type '%v'", value.type)
		}
		operand.mode = .RValue
	case ^Expr_Unary:
		@(require_results)
		is_valid_unary_operator :: proc(op: Token_Kind) -> bool {
			#partial switch op {
			case .Xor, .Not, .Add, .Subtract:
				return true
			}
			return false
		}
		expr := check_expr(checker, v.expr)
		if !operator_applicable(expr.type, v.op) && is_valid_unary_operator(v.op) {
			error(checker, v, "operator `%v` is not defined for `%v%v`", token_to_string(v.op), token_to_string(v.op), expr.type)
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
	case ^Expr_Ternary:
		cond       := check_expr(checker, v.cond)
		then_value := check_expr(checker, v.then_expr, type_hint = type_hint)
		else_value := check_expr(checker, v.else_expr, type_hint = type_hint)

		if cond.type.kind != .Bool {
			error(checker, cond, "expected a boolean as the condition in ternary, got %v", cond.type)
			return
		}

		operand.mode = .RValue
		if then_value.mode == .Invalid {
			operand.type = else_value.type
		} else if else_value.mode == .Invalid {
			operand.type = then_value.type
		} else {
			operand.type = default_type(op_result_type(then_value.type, else_value.type))

			if operand.type.kind == .Invalid {
				error(checker, cond, "mismatched types in ternary expr: %v vs %v", then_value.type, else_value.type)
				return
			}

			v.then_expr.type = operand.type
			v.else_expr.type = operand.type
		}

	case ^Expr_Type_Matrix:
		rows := check_expr(checker, v.rows)
		if rows.mode != .Const || (rows.type.kind != .Int && rows.type.kind != .Uint) {
			error(checker, rows, "expected a constant integer")
		}
		cols: i64
		if v.cols == nil {
			cols = rows.value.(i64) or_else 0
		} else {
			cols_expr := check_expr(checker, v.cols)
			if cols_expr.mode != .Const || (cols_expr.type.kind != .Int && cols_expr.type.kind != .Uint) {
				error(checker, cols_expr, "expected a constant integer")
			} else {
				cols = cols_expr.value.(i64)
			}
		}

		elem := check_type(checker, v.elem)
		if elem.kind == .Invalid {
			return
		}

		col_type    := type_array_new(default_type(elem), rows.value.(i64) or_else 0, checker.allocator)
		operand.type = type_matrix_new(col_type, cols, checker.allocator)
		operand.mode = .Type
	case ^Expr_Type_Array:
		elem := default_type(check_type(checker, v.elem))
		if elem.kind == .Invalid {
			return
		}
		if v.count == nil {
			if elem.size == 0 {
				error(checker, v.elem, "buffer element type must have a non-zero size, got %v", elem)
				return
			}
			operand.type = type_buffer_new(elem, v.physical, checker.allocator)
			operand.mode = .Type
		} else {
			count := check_expr(checker, v.count)
			if c, ok := count.value.(i64); ok {
				if c < 1 {
					error(checker, count, "array size has to be a positive integer, got %d", c)
					return
				}
				operand.type = type_array_new(elem, c, checker.allocator)
				operand.mode = .Type
			} else {
				error(checker, count, "expected a constant integer as the count of an array")
			}
		}

	case ^Expr_Type_Struct:
		operand.mode   = .Type
		operand.flags |= { .Type_Distinct, }

		type   := type_new(.Struct, Type_Struct, checker.allocator)
		fields := make([dynamic]^Entity, 0, len(v.fields), checker.allocator)
		scope  := scope_new(nil, .Struct, checker.allocator)
		offset := i64(0)
		align  := i64(1)
		for i := 0; i < len(v.fields); {
			start := i
			type: ^Type
			for ; i < len(v.fields); i += 1 {
				field := v.fields[i]

				if field.type == nil {
					continue
				}
				type = check_type(checker, field.type)
				i   += 1
				break
			}

			if type == nil && i == len(v.fields) {
				error(checker, v.fields[len(v.fields) - 1].name, "struct field is missing a type")
				operand.mode = .Type
				operand.type = t_invalid
				return
			}

			if type.align != 0 {
				offset = align_forward_i64(offset, type.align)
			}

			align = max(align, type.align)
			for i in start ..< i {
				entity            := entity_new(checker, .Struct_Field, v.fields[i].name, type, flags = { .Resolved, })
				entity.offset      = i64(offset)
				entity.field_index = i
				append(&fields, entity)
				scope_insert_entity(checker, entity, scope)

				offset += type.size
				offset  = align_forward_i64(offset, align)
			}
		}

		type.fields  = fields[:]
		type.size    = align_forward_i64(offset, align)
		type.align   = align
		type.scope   = scope

		operand.type = type
		operand.mode = .Type
	case ^Expr_Type_Enum:
		operand.mode   = .Type
		operand.flags |= { .Type_Distinct, }

		type   := type_new(.Enum, Type_Enum, checker.allocator)
		values := make([dynamic]^Entity, 0, len(v.values), checker.allocator)
		scope  := scope_new(nil, .Enum, checker.allocator)

		max_value:     i64
		min_value:     i64
		current_value: i64

		for value in v.values {
			val: i64
			if value.value == nil {
				val            = current_value
				max_value      = max(max_value, current_value)
				current_value += 1
			} else {
				enum_value := check_expr(checker, value.value)

				ok: bool
				if val, ok = enum_value.value.(i64); ok {
					max_value     = max(max_value, val)
					min_value     = min(min_value, val)
					current_value = val + 1
				} else {
					error(checker, enum_value, "enum value has to be a constant integer")
				}
			}

			entity := entity_new(checker, .Enum_Value, value.name, type, value = val, flags = { .Resolved, })
			append(&values, entity)
			scope_insert_entity(checker, entity, scope)
		}

		backing: ^Type
		if v.backing != nil {
			backing = check_type(checker, v.backing)
		} else {
			backing = t_i32
		}

		type.values  = values[:]
		type.size    = backing.size
		type.align   = backing.align
		type.backing = backing
		type.scope   = scope

		operand.type = type
		operand.mode = .Type
	case ^Expr_Type_Image:
		dimensions := check_expr(checker, v.dimensions)
		dim, ok := dimensions.value.(i64)
		if !ok {
			error(checker, dimensions, "expected a constant integer as the dimension of a sampler")
			return
		}

		if dim < 1 || dim > 3 {
			error(checker, dimensions, "sampler dimension has to be between 1 and 3, got %d", dim)
			return
		}

		image_format: spv.ImageFormat
		if v.format.text != "" {
			for name, format in image_format_names {
				if v.format.text == name {
					image_format = format
					break
				}
			}
			if image_format == nil {
				error(checker, v.format, "unknown image format")
			}
		}

		texel_type := default_type(check_type(checker, v.texel_type))
		if !(type_is_numeric(texel_type) || type_is_array(texel_type)) {
			error(checker, v.texel_type, "texel type of sampler has to be either a numeric type or a vector, got: %v", texel_type)
			return
		}

		if v.is_sampler {
			operand.type = type_sampler_new(texel_type, dim, checker.allocator)
		} else {
			operand.type = type_image_new(texel_type, dim, v.format.text, checker.allocator)
		}
		operand.mode = .Type
	case ^Expr_Type_Bit_Set:
		enum_type   := check_type(checker, v.enum_type)
		backing     := check_type(checker, v.backing)
		operand.type = type_bit_set_new(enum_type, backing, checker.allocator)
		operand.mode = .Type

	case ^Expr_Type_Opaque:
		backing: ^Type
		if v.backing != nil {
			backing = check_type(checker, v.backing)
		}
		operand.type = type_opaque_new(v.name.text, backing, checker.allocator)
		operand.mode = .Type

	case ^Expr_Type_Distinct:
		operand.type   = check_type(checker, v.backing)
		operand.mode   = .Type
		operand.flags |= { .Type_Distinct, }

	case ^Expr_Type_Fixed:
		type                := type_new(.Fixed, Type_Fixed, checker.allocator)
		type.signed          = v.signed
		type.fractional_bits = v.fractional_bits
		required_bits       := v.integral_bits + v.fractional_bits

		switch required_bits {
		case 8:
			type.backing = t_i8  if v.signed else t_u8
		case 16:
			type.backing = t_i16 if v.signed else t_u16
		case 32:
			type.backing = t_i32 if v.signed else t_u32
		case 64:
			type.backing = t_i64 if v.signed else t_u64
		case:
			error(checker, v, "invalid number of bits in fixed point type: '%d'", required_bits)
			return
		}

		type.size  = type.backing.size
		type.align = type.backing.align

		operand.type = type
		operand.mode = .Type

	case ^Expr_Directive:
		error(checker, v, "invalid use of directive")
	}

	return
}

@(init)
image_format_table_init :: proc "contextless" () {
	context = runtime.default_context()

	for &name, image_format in image_format_names {
		name = strings.to_lower(reflect.enum_name_from_value(image_format) or_else panic(""))
	}
}

image_format_names: [spv.ImageFormat]string

@(require_results)
check_expr_or_type :: proc(
	checker:           ^Checker,
	expr:              ^Ast_Expr,
	attributes:        []Ast_Field = {},
	type_hint:         ^Type       = nil,
	check_proc_bodies: bool        = true,
	is_entry_point:    bool        = false,
	allow_proc_groups: bool        = false,
	allow_ellipsis:    bool        = false,
) -> (operand: Operand) {
	operand = check_expr_internal(checker, expr, attributes, type_hint, check_proc_bodies)
	switch operand.mode {
	case .RValue, .LValue, .Const, .Type, .Proc:
		assert(operand.type != nil)
		return
	case .Proc_Group:
		if allow_proc_groups {
			return
		}
		error(checker, operand, "expected an expression, got procedure group")
	case .Builtin:
		error(checker, operand, "expected an expression, got builtin")
	case .No_Value:
		error(checker, operand, "expected an expression, got no value")
	case .Library:
		error(checker, operand, "expected an expression, got library")
	case .Ellipsis:
		if allow_ellipsis {
			return
		}
		error(checker, operand, "illegal use of ellipsis ('..')")
	case .Label:
		error(checker, operand, "invalid use of label")
	case .Invalid:
	}


	operand.mode = .Invalid
	operand.type = t_invalid
	return
}

@(require_results)
check_expr :: proc(
	checker:        ^Checker,
	expr:           ^Ast_Expr,
	attributes:     []Ast_Field = {},
	type_hint:      ^Type       = nil,
	allow_no_value: bool        = false,
	allow_ellipsis: bool        = false,
) -> (operand: Operand) {
	operand = check_expr_internal(checker, expr, attributes, type_hint)
	switch operand.mode {
	case .RValue, .LValue, .Const, .Proc, .Proc_Group:
		assert(operand.type != nil)
		return
	case .Builtin:
		error(checker, operand, "expected an expression, got builtin")
	case .Type:
		error(checker, operand, "expected an expression, got type")
	case .No_Value:
		if allow_no_value {
			return
		}
		error(checker, operand, "expected an expression, got no value")
	case .Library:
		error(checker, operand, "expected an expression, got library")
	case .Ellipsis:
		if allow_ellipsis {
			return
		}
		error(checker, operand, "illegal use of ellipsis ('..')")
	case .Label:
		error(checker, operand, "invalid use of label")
	case .Invalid:
	}

	operand.mode = .Invalid
	operand.type = t_invalid
	return
}

@(require_results)
check_type :: proc(checker: ^Checker, expr: ^Ast_Expr, attributes: []Ast_Field = {}) -> ^Type {
	operand := check_expr_internal(checker, expr, attributes)
	switch operand.mode {
	case .RValue, .LValue, .Const, .Proc, .Proc_Group, .Ellipsis:
		error(checker, operand, "expected a type, got expression")
	case .Builtin:
		error(checker, operand, "expected a type, got builtin")
	case .Type:
		assert(operand.type != nil)
		return operand.type
	case .No_Value:
		error(checker, operand, "expected a type, got no value")
	case .Library:
		error(checker, operand, "expected a type, got library")
	case .Label:
		error(checker, operand, "invalid use of label")
	case .Invalid:
	}

	return t_invalid
}

entity_to_operand :: proc(checker: ^Checker, e: ^Entity, operand: ^Operand) {
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
	case .Proc_Group:
		operand.mode = .Proc_Group
	case .Builtin:
		operand.mode       = .Builtin
		operand.builtin_id = e.builtin_id
	case .Library:
		operand.mode    = .Library
		operand.library = e.library
	case .Label:
		operand.mode  = .Label
		operand.scope = e.scope
	case .Proc_Param:
		operand.mode = .RValue
		operand.type = e.type
	case .Proc_Return:
		operand.mode = .LValue
		operand.type = e.type
	case .Struct_Field, .Enum_Value:
		unreachable()
	}

	if operand.type.kind == .Invalid {
		#partial switch operand.mode {
		case .RValue, .LValue, .Const, .Type:
			operand.mode = .Invalid
		}
	}
}

deconstruct_tuple :: proc(checker: ^Checker, ts: ^[]^Type) -> bool {
	type := ts[0]
	if type.kind != .Tuple {
		return false
	}

	tuple := type.variant.(^Type_Struct)
	ts^    = make([]^Type, len(tuple.fields), context.temp_allocator)
	for field, i in tuple.fields {
		ts[i] = field.type
	}

	return true
}

@(require_results)
check_attribute_matches :: proc(checker: ^Checker, a: Ast_Field, name: string) -> bool {
	name := name
	extension: string
	if dot := strings.index(name, "."); dot >= 0 {
		extension = name[:dot]
		name      = name[dot + 1:]
	}

	return name == a.name.text

	// if a.location != nil {
	// 	library := expect_ident(checker, a.location) or_else panic("")
	// 	e, ok := scope_lookup(checker, { text = library, location = a.location.start, })
	// 	if ok && e.kind != .Library {
	// 		error(checker, a.location, "expected a library")
	// 	}
	// } else {
	// 	if extension != "" {
	// 		error(checker, a.name, "attribute '%v' is part of the '%s' extension, use `@(%s.%s)`", name, extension, extension, name)
	// 	}
	// }
	// return true
}
