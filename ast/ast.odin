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
	library:    tokenizer.Token,
}

Directive :: enum {
	Invalid = 0,
	Assert,
	Panic,
	Import,
	Config,
}

@(rodata)
directive_names: [Directive]string = {
	.Invalid = "<invalid>",
	.Assert  = "assert",
	.Panic   = "panic",
	.Import  = "import",
	.Config  = "config",
}

Expr_Directive :: struct {
	using node: Expr,
	directive:  Directive,
	token:      tokenizer.Token,
}

Shader_Stage :: enum {
	Invalid = 0,
	Vertex,
	Fragment,
	Geometry,
	Tesselation,
	Compute,
	Ray_Generation,
	Intersection,
	Any_Hit,
	Closest_Hit,
	Miss,
}

@(rodata)
shader_stage_names: [Shader_Stage]string = {
	.Invalid          = "<invalid>",
	.Vertex           = "vertex_shader",
	.Fragment         = "fragment_shader",
	.Geometry         = "geometry_shader",
	.Tesselation      = "tesselation_shader",
	.Compute          = "compute_shader",

	.Ray_Generation   = "ray_generation_shader",
	.Intersection     = "intersection_shader",
	.Any_Hit          = "any_hit_shader",
	.Closest_Hit      = "closest_hit_shader",
	.Miss             = "miss_shader",
}

Expr_Proc_Lit :: struct {
	using sig:    Expr_Proc_Sig,
	body:         []^Stmt,
	shader_stage: Shader_Stage,
}

Expr_Proc_Sig :: struct {
	using node: Expr,
	args:       []Field,
	returns:    []Field,
}

Expr_Proc_Group :: struct {
	using node: Expr,
	members:    []^Expr,
}

Builtin_Id :: enum {
	Invalid = 0,

	Min,
	Max,
	Clamp,

	Inverse,
	Transpose,
	Determinant,

	Dot,
	Cross,
	Distance,
	Normalize,
	Length,
	Reflect,
	Refract,

	Pow,
	Sqrt,
	Sin,
	Cos,
	Tan,
	Sinh,
	Cosh,
	Tanh,
	Asin,
	Acos,
	Atan,
	Asinh,
	Acosh,
	Atanh,
	Atan2,
	Exp,
	Log,
	Exp2,
	Log2,
	Fract,
	Floor,
	Ceil,
	Round,
	Trunc,
	Inverse_Sqrt,
	Abs,
	Sign,

	Smooth_Step,
	Lerp,

	Real,
	Imag,
	Jmag,
	Kmag,

	Texture_Size,
	Image_Size,

	Discard,

	Ddx,
	Ddy,

	Size_Of,
	Align_Of,
	Type_Of,

	/* intrinsics */

	Type_Is_Array,
	Type_Is_Float,
	Type_Is_Boolean,
	Type_Is_Integer,
	Type_Is_Numeric,
	Type_Is_Complex,
	Type_Is_Quaternion,
	Type_Is_Matrix,

	Count_Ones,
	Count_Zeros,
	Count_Leading_Zeros,
	Count_Trailing_Zeros,
	Count_Leading_Ones,
	Count_Trailing_Ones,
	Find_Lsb,
	Find_Msb,
	Reverse_Bits,

	Barrier,

	/** extensions **/

	/* clock */
	Read_Subgroup_Clock,
	Read_Device_Clock,

	/* raytracing */
	Trace_Ray,
	Report_Intersection,
	Ignore_Intersection,
	Terminate_Ray,
}

Expr_Call :: struct {
	using node:   Expr,
	lhs:         ^Expr,
	args:       []Field,
	group_member: Maybe(int),
	builtin:      Builtin_Id,
	is_cast:      bool,
	is_directive: bool,
}

Expr_Paren :: struct {
	using node: Expr,
	expr:      ^Expr,
}

Expr_Selector :: struct {
	using node: Expr,
	lhs:       ^Expr,
	selector:   tokenizer.Token,
	library:    string,
}

Expr_Compound :: struct {
	using node: Expr,
	type_expr: ^Expr,
	fields:   []Field,
	named:      bool,
	constant:   bool,
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

Expr_Ellipsis :: struct {
	using node: Expr,
	expr:      ^Expr,
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

Type_Image :: struct {
	using node: Expr,
	dimensions: ^Expr,
	texel_type: ^Expr,
	is_sampler: bool,
	format:     tokenizer.Token,
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
	Shared,

	Ray_Payload,
	Incoming_Ray_Payload,
	Hit_Attribute,
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

Decl_Import :: struct {
	using node: Decl,
	library:    tokenizer.Token,
	name:       string,
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
	^Expr_Proc_Group,
	^Expr_Paren,
	^Expr_Selector,
	^Expr_Call,
	^Expr_Compound,
	^Expr_Index,
	^Expr_Cast,
	^Expr_Unary,
	^Expr_Interface,
	^Expr_Directive,
	^Expr_Ternary,
	^Expr_Ellipsis,

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
	^Decl_Import,
}

Any_Expr :: union {
	^Expr_Constant,
	^Expr_Binary,
	^Expr_Ident,
	^Expr_Proc_Lit,
	^Expr_Proc_Sig,
	^Expr_Proc_Group,
	^Expr_Paren,
	^Expr_Selector,
	^Expr_Call,
	^Expr_Compound,
	^Expr_Index,
	^Expr_Cast,
	^Expr_Unary,
	^Expr_Interface,
	^Expr_Directive,
	^Expr_Ternary,
	^Expr_Ellipsis,

	^Type_Struct,
	^Type_Array,
	^Type_Matrix,
	^Type_Image,
	^Type_Enum,
	^Type_Bit_Set,
}

Any_Decl :: union {
	^Decl_Value,
	^Decl_Import,
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
	^Decl_Import,
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
	library:  tokenizer.Token,
	type:     ^Expr,
	value:    ^Expr,
	location: ^Expr,
}
