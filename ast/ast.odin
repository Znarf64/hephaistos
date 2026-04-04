package hephaistos_ast

import "base:intrinsics"

@(require)
import "core:mem"

import "../tokenizer"
import "../types"

Node :: struct {
	start, end: tokenizer.Location,
	derived:    Any_Node,
}

Expr :: struct {
	using expr_base: Node,
	derived_expr:    Any_Expr,
	type:           ^types.Type,
	const_value:     types.Const_Value,
}

Stmt :: struct {
	using stmt_base: Node,
	attributes:      []Field,
	derived_stmt:    Any_Stmt,
}

Decl :: struct {
	using decl_base: Stmt,
	derived_decl:    Any_Decl,
}


Expr_Binary :: struct {
	using node: Expr,
	op:         tokenizer.Token_Kind,
	lhs, rhs:  ^Expr,
}

Expr_Unary :: struct {
	using node: Expr,
	op:         tokenizer.Token_Kind,
	expr:      ^Expr,
}

Expr_Ternary :: struct {
	using node: Expr,
	cond:      ^Expr,
	then_expr: ^Expr,
	else_expr: ^Expr,
}

Expr_Constant :: struct {
	using node: Expr,
	value:      types.Const_Value,
	imaginary:  tokenizer.Imaginary,
}

Expr_Ident :: struct {
	using node: Expr,
	ident:      tokenizer.Token,
}

Expr_Interface :: struct {
	using node: Expr,
	ident:      tokenizer.Token,
}

Expr_Config :: struct {
	using node: Expr,
	ident:      tokenizer.Token,
	default:    ^Expr,
}

Shader_Stage :: enum {
	Invalid = 0,
	Vertex,
	Fragment,
	Geometry,
	Tesselation,
	Compute,
}

@(rodata)
shader_stage_names: [Shader_Stage]string = {
	.Invalid     = "<invalid>",
	.Vertex      = "vertex_shader",
	.Fragment    = "fragment_shader",
	.Geometry    = "geometry_shader",
	.Tesselation = "tesselation_shader",
	.Compute     = "compute_shader",
}

Expr_Proc_Lit :: struct {
	using node:   Expr,
	args:         []Field,
	returns:      []Field,
	body:         []^Stmt,
	shader_stage: Shader_Stage,
}

Expr_Proc_Sig :: struct {
	using node: Expr,
	args:       []Field,
	returns:    []Field,
}

Builtin_Id :: enum {
	Invalid = 0,
	Dot,
	Cross,
	Min,
	Max,
	Clamp,
	Inverse,
	Transpose,
	Determinant,
	Pow,
	Sqrt,
	Sin,
	Cos,
	Tan,
	Normalize,
	Length,
	Exp,
	Log,
	Exp2,
	Log2,
	Floor,
	Ceil,
	Fract,
	Lerp,
	Round,
	Trunc,
	Smooth_Step,
	Distance,
	Inverse_Sqrt,
	Abs,
	Bit_Count,
	Bit_Reverse,

	Texture_Size,
	Image_Size,

	Discard,

	Ddx,
	Ddy,
	
	Size_Of,
	Align_Of,
	Type_Of,
}

Expr_Call :: struct {
	using node: Expr,
	lhs:       ^Expr,
	args:     []Field,
	is_cast:    bool,
	builtin:    Builtin_Id,
}

Expr_Paren :: struct {
	using node: Expr,
	expr:      ^Expr,
}

Expr_Selector :: struct {
	using node: Expr,
	lhs:       ^Expr,
	selector:   tokenizer.Token,
}

Expr_Compound :: struct {
	using node: Expr,
	type_expr: ^Expr,
	fields:   []Field,
	named:      bool,
}

Expr_Index :: struct {
	using node: Expr,
	lhs, rhs:  ^Expr,
}

Expr_Cast :: struct {
	using node: Expr,
	value:     ^Expr,
	type_expr: ^Expr,
}


Type_Struct :: struct {
	using node: Expr,
	fields:     []Field,
}

Type_Array :: struct {
	using node: Expr,
	count:     ^Expr,
	elem:      ^Expr,
	physical:   bool,
}

Type_Matrix :: struct {
	using node: Expr,
	rows:      ^Expr,
	cols:      ^Expr,
	elem:      ^Expr,
}

Type_Import :: struct {
	using node: Expr,
	ident:      tokenizer.Token,
}

Type_Image :: struct {
	using node: Expr,
	dimensions: ^Expr,
	texel_type: ^Expr,
	is_sampler: bool,
}

Type_Enum :: struct {
	using node: Expr,
	values:     []Field,
	backing:    ^Expr,
}

Type_Bit_Set :: struct {
	using node: Expr,
	enum_type: ^Expr,
	backing:   ^Expr,
}


Interface_Kind :: enum {
	None = 0,
	Uniform,
	Uniform_Buffer,
	Push_Constant,
	Storage_Buffer,
}

Decl_Value :: struct {
	using node:     Decl,
	lhs:            []^Expr,
	type_expr:      ^Expr,
	values:         []^Expr,
	mutable:        bool,
	types:          []^types.Type,
	readonly:       bool,
	binding:        int,
	location:       int,
	descriptor_set: int,
	link_name:      string,
	local_size:     [3]i32,
	shader_stage:   Shader_Stage,
	interface:      Interface_Kind,
}

Stmt_Return :: struct {
	using node: Stmt,
	label:      tokenizer.Token,
	values:  []^Expr,
}

Stmt_Break :: struct {
	using node: Stmt,
	label:      tokenizer.Token,
}

Stmt_Continue :: struct {
	using node: Stmt,
	label:      tokenizer.Token,
}

Stmt_For_Range :: struct {
	using node: Stmt,
	label:      tokenizer.Token,
	start_expr: ^Expr,
	end_expr:   ^Expr,
	variable:   ^Expr,
	body:       []^Stmt,
	inclusive:  bool,
}

Stmt_For :: struct {
	using node: Stmt,
	label:      tokenizer.Token,
	init:       ^Stmt,
	cond:       ^Expr,
	post:       ^Stmt,
	body:       []^Stmt,
}

Stmt_Block :: struct {
	using node: Stmt,
	label:      tokenizer.Token,
	body:       []^Stmt,
}

Stmt_If :: struct {
	using node: Stmt,
	label:      tokenizer.Token,
	init:       ^Stmt,
	cond:       ^Expr,
	then_block: []^Stmt,
	else_block: []^Stmt,
}

Stmt_When :: struct {
	using node: Stmt,
	label:      tokenizer.Token,
	cond:       ^Expr,
	then_block: []^Stmt,
	else_block: []^Stmt,
}

Switch_Case :: struct {
	token: tokenizer.Token,
	value: ^Expr,
	body:  []^Stmt,
}

Stmt_Switch :: struct {
	using node:     Stmt,
	label:          tokenizer.Token,
	init:           ^Stmt,
	cond:           ^Expr,
	cases:          []Switch_Case,
	constant_cases: bool,
}

Stmt_Assign :: struct {
	using node: Stmt,
	lhs, rhs:   []^Expr,
	op:         tokenizer.Token_Kind,
	types:      []^types.Type,
}

Stmt_Expr :: struct {
	using node: Stmt,
	expr:      ^Expr,
}


Any_Node :: union {
	^Expr_Constant,
	^Expr_Binary,
	^Expr_Ident,
	^Expr_Proc_Lit,
	^Expr_Proc_Sig,
	^Expr_Paren,
	^Expr_Selector,
	^Expr_Call,
	^Expr_Compound,
	^Expr_Index,
	^Expr_Cast,
	^Expr_Unary,
	^Expr_Interface,
	^Expr_Config,
	^Expr_Ternary,

	^Type_Import,
	^Type_Struct,
	^Type_Array,
	^Type_Matrix,
	^Type_Image,
	^Type_Enum,
	^Type_Bit_Set,

	^Stmt_Return,
	^Stmt_Break,
	^Stmt_Continue,
	^Stmt_For_Range,
	^Stmt_For,
	^Stmt_Block,
	^Stmt_If,
	^Stmt_Switch,
	^Stmt_Assign,
	^Stmt_Expr,
	^Stmt_When,

	^Decl_Value,
}

Any_Expr :: union {
	^Expr_Constant,
	^Expr_Binary,
	^Expr_Ident,
	^Expr_Proc_Lit,
	^Expr_Proc_Sig,
	^Expr_Paren,
	^Expr_Selector,
	^Expr_Call,
	^Expr_Compound,
	^Expr_Index,
	^Expr_Cast,
	^Expr_Unary,
	^Expr_Interface,
	^Expr_Config,
	^Expr_Ternary,
	
	^Type_Import,
	^Type_Struct,
	^Type_Array,
	^Type_Matrix,
	^Type_Image,
	^Type_Enum,
	^Type_Bit_Set,
}

Any_Decl :: union {
	^Decl_Value,
}

Any_Stmt :: union {
	^Stmt_Return,
	^Stmt_Break,
	^Stmt_Continue,
	^Stmt_For_Range,
	^Stmt_For,
	^Stmt_Block,
	^Stmt_If,
	^Stmt_Switch,
	^Stmt_Assign,
	^Stmt_Expr,
	^Stmt_When,

	^Decl_Value,
}

new :: proc($T: typeid, start, end: tokenizer.Location, allocator: mem.Allocator) -> ^T {
	n, _ := mem.new(T, allocator)
	n.start   = start
	n.end     = end
	n.derived = n
	base: ^Node = n // dummy check
	_ = base // "Use" type to make -vet happy
	when intrinsics.type_has_field(T, "derived_expr") {
		n.derived_expr = n
	}
	when intrinsics.type_has_field(T, "derived_stmt") {
		n.derived_stmt = n
	}
	when intrinsics.type_has_field(T, "derived_decl") {
		n.derived_decl = n
	}
	return n
}

Field :: struct {
	ident:    tokenizer.Token,
	type:     ^Expr,
	value:    ^Expr,
	location: ^Expr,
}
