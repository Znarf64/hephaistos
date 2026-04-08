package hephaistos_checker

import "core:mem"

import "../ast"
import "../tokenizer"
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
}

@(rodata)
entity_kind_string := [Entity_Kind]string{
	.Invalid    = "invalid",
	.Const      = "const",
	.Type       = "type",
	.Var        = "variable",
	.Proc       = "proc",
	.Proc_Group = "proc group",
	.Builtin    = "builtin",
	.Library    = "library",
}

Entity_Flag :: enum {
	Readonly,

	In_Progress,
	Resolved,
}

Entity_Flags :: bit_set[Entity_Flag]

Entity :: struct {
	kind:       Entity_Kind,
	ident:      tokenizer.Token,
	name:       string,
	type:       ^types.Type,
	decl:       ^ast.Decl,
	library:    string,
	value:      types.Const_Value,
	builtin_id: ast.Builtin_Id,
	flags:      Entity_Flags,
	group_members: []^types.Type,
}

@(require_results)
entity_new :: proc(
	kind:       Entity_Kind,
	ident:      tokenizer.Token,
	type:       ^types.Type,
	value:      types.Const_Value = nil,
	decl:       ^ast.Decl         = nil,
	builtin_id: ast.Builtin_Id    = nil,
	flags:      Entity_Flags      = {},
	allocator:  mem.Allocator,
) -> ^Entity {
	e := new(Entity, allocator)
	e.kind       = kind
	e.type       = type
	e.ident      = ident
	e.name       = ident.text
	e.value      = value
	e.decl       = decl
	e.builtin_id = builtin_id
	e.flags      = flags
	return e
}
