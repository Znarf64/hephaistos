package hephaistos_checker

import "core:mem"

import "../ast"
import "../types"

Entity_Kind :: enum u32 {
	Invalid = 0,

	Const,
	Type,
	Var,
	Proc,
	Proc_Group,
	Builtin,
	Library,
	Label,
}

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

Entity_Flag :: enum {
	Readonly,

	In_Progress,
	Resolved,
}

Entity_Flags :: bit_set[Entity_Flag]

Entity :: struct {
	kind:       Entity_Kind,
	ident:      ^ast.Expr_Ident,
	name:       string,
	type:       ^types.Type,
	decl:       ^ast.Decl,
	library:    string,
	value:      types.Const_Value,
	builtin_id: ast.Builtin_Id,
	interface:  ast.Interface_Kind,
	flags:      Entity_Flags,
	scope:      ^Scope,
}

entity_new :: proc {
	entity_new_ident,
	entity_new_name,
}

@(require_results)
entity_new_ident :: proc(
	kind:       Entity_Kind,
	ident:      ^ast.Expr_Ident,
	type:       ^types.Type,
	decl:       ^ast.Decl      = nil,
	builtin_id: ast.Builtin_Id = nil,
	flags:      Entity_Flags   = {},
	allocator:  mem.Allocator,
) -> ^Entity {
	assert(type != nil)

	e           := new(Entity, allocator)
	e.kind       = kind
	e.type       = type
	e.ident      = ident
	e.name       = ident.ident.text
	e.decl       = decl
	e.builtin_id = builtin_id
	e.flags      = flags
	return e
}

@(require_results)
entity_new_name :: proc(
	kind:       Entity_Kind,
	name:       string,
	type:       ^types.Type,
	decl:       ^ast.Decl      = nil,
	builtin_id: ast.Builtin_Id = nil,
	flags:      Entity_Flags   = {},
	allocator:  mem.Allocator,
) -> ^Entity {
	e           := new(Entity, allocator)
	e.kind       = kind
	e.type       = type
	e.ident      = nil
	e.name       = name
	e.decl       = decl
	e.builtin_id = builtin_id
	e.flags      = flags
	return e
}
