package hephaistos_checker

import "../ast"
import "../types"

Entity       :: ast.Entity
Entity_Kind  :: ast.Entity_Kind
Entity_Flag  :: ast.Entity_Flag
Entity_Flags :: ast.Entity_Flags
Scope        :: ast.Scope
Scope_Kind   :: ast.Scope_Kind

@(rodata)
entity_kind_strings := [Entity_Kind]string{
	.Invalid      = "invalid",
	.Const        = "const",
	.Type         = "type",
	.Var          = "variable",
	.Proc         = "proc",
	.Proc_Group   = "proc group",
	.Builtin      = "builtin",
	.Library      = "library",
	.Label        = "label",
	.Struct_Field = "struct field",
	.Enum_Value   = "enum value",
}

@(require_results)
entity_new :: proc(
	checker:   ^Checker,
	kind:       ast.Entity_Kind,
	ident:     ^ast.Expr_Ident,
	type:      ^types.Type,
	decl:      ^ast.Decl          = nil,
	value:      types.Const_Value = nil,
	builtin_id: ast.Builtin_Id    = nil,
	flags:      ast.Entity_Flags  = {},
) -> (e: ^ast.Entity) {
	assert(type != nil)

	e  = new(ast.Entity, checker.allocator)
	e^ = {
		kind       = kind,
		type       = type,
		ident      = ident,
		name       = ident.text,
		decl       = decl,
		value      = value,
		builtin_id = builtin_id,
		flags      = flags,
	}

	e.references.allocator = checker.allocator
	if .Enable_References in checker.flags {
		append(&e.references, ident)
	}

	ident.entity = e

	return
}

@(require_results)
entity_new_no_ident :: proc(
	checker:   ^Checker,
	kind:       ast.Entity_Kind,
	name:       string,
	type:      ^types.Type,
	decl:      ^ast.Decl          = nil,
	builtin_id: ast.Builtin_Id    = nil,
	value:      types.Const_Value = nil,
	flags:      ast.Entity_Flags  = {},
) -> (e: ^ast.Entity) {
	e  = new(ast.Entity, checker.allocator)
	e^ = {
		kind       = kind,
		type       = type,
		ident      = nil,
		name       = name,
		decl       = decl,
		value      = value,
		builtin_id = builtin_id,
		flags      = flags,
	}

	e.references.allocator = checker.allocator

	return e
}
