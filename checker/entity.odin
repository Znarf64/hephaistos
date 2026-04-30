package hephaistos_checker

import "core:mem"

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
	.Invalid    = "invalid",
	.Const      = "const",
	.Type       = "type",
	.Var        = "variable",
	.Proc       = "proc",
	.Proc_Group = "proc group",
	.Builtin    = "builtin",
	.Library    = "library",
	.Label      = "Label",
}

entity_new :: proc {
	entity_new_ident,
	entity_new_name,
}

@(require_results)
entity_new_ident :: proc(
	kind:       ast.Entity_Kind,
	ident:     ^ast.Expr_Ident,
	type:      ^types.Type,
	decl:      ^ast.Decl         = nil,
	builtin_id: ast.Builtin_Id   = nil,
	flags:      ast.Entity_Flags = {},
	allocator:  mem.Allocator,
) -> ^ast.Entity {
	assert(type != nil)

	e           := new(ast.Entity, allocator)
	e.kind       = kind
	e.type       = type
	e.ident      = ident
	e.name       = ident.text
	e.decl       = decl
	e.builtin_id = builtin_id
	e.flags      = flags

	ident.entity = e

	return e
}

@(require_results)
entity_new_name :: proc(
	kind:       ast.Entity_Kind,
	name:       string,
	type:      ^types.Type,
	decl:      ^ast.Decl         = nil,
	builtin_id: ast.Builtin_Id   = nil,
	flags:      ast.Entity_Flags = {},
	allocator:  mem.Allocator,
) -> ^ast.Entity {
	e           := new(ast.Entity, allocator)
	e.kind       = kind
	e.type       = type
	e.ident      = nil
	e.name       = name
	e.decl       = decl
	e.builtin_id = builtin_id
	e.flags      = flags
	return e
}
