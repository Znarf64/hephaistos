package hephaistos

Entity :: struct {
	kind:        Entity_Kind,
	ident:      ^Expr_Ident,
	name:        string,
	type:       ^Type,
	decl:       ^Ast_Decl,
	library:    ^Library,
	value:       Const_Value,
	builtin_id:  Builtin_Id,
	flags:       Entity_Flags,
	scope:      ^Scope,
	location:    i64,
	offset:      i64,
	field_index: int,
	references:  [dynamic]^Expr_Ident,
}

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

	Struct_Field,
	Enum_Value,
	Proc_Param,
	Proc_Return,
}

Entity_Flag :: enum {
	Readonly,
	Extension_Proc,

	In_Progress,
	Resolved,

	By_Ptr,
	Const,
}

Entity_Flags :: bit_set[Entity_Flag]

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
	.Proc_Param   = "parameter",
	.Proc_Return  = "return value",
}

@(require_results)
entity_new :: proc(
	checker:   ^Checker,
	kind:       Entity_Kind,
	ident:     ^Expr_Ident,
	type:      ^Type,
	decl:      ^Ast_Decl     = nil,
	value:      Const_Value  = nil,
	builtin_id: Builtin_Id   = nil,
	flags:      Entity_Flags = {},
) -> (e: ^Entity) {
	assert(type != nil)

	e  = new(Entity, checker.allocator)
	e^ = {
		kind        = kind,
		type        = type,
		ident       = ident,
		name        = ident.text,
		decl        = decl,
		value       = value,
		builtin_id  = builtin_id,
		flags       = flags,

		location    = -1,
		offset      = -1,
		field_index = -1,
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
	kind:       Entity_Kind,
	name:       string,
	type:      ^Type,
	decl:      ^Ast_Decl     = nil,
	builtin_id: Builtin_Id   = nil,
	value:      Const_Value  = nil,
	flags:      Entity_Flags = {},
) -> (e: ^Entity) {
	e  = new(Entity, checker.allocator)
	e^ = {
		kind        = kind,
		type        = type,
		ident       = nil,
		name        = name,
		decl        = decl,
		value       = value,
		builtin_id  = builtin_id,
		flags       = flags,

		location    = -1,
		offset      = -1,
		field_index = -1,
	}

	e.references.allocator = checker.allocator

	return e
}

Scope :: struct {
	parent:       ^Scope,
	entities:      map[string]^Entity,
	proc_type:    ^Type_Proc,
	kind:          Scope_Kind,
	allow_imports: bool,
}

Scope_Kind :: enum {
	Global,
	Proc,
	Proc_Sig,
	Block, // if or {}
	Loop,
	Switch,

	Enum,
	Struct,
}
