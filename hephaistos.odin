package hephaistos

import "base:runtime"

import "core:fmt"
import "core:io"
import "core:reflect"
import "core:terminal/ansi"

import "ast"
import "cg"
import "checker"
import "parser"
import "tokenizer"
import "types"

import spv "spirv-odin"

Token              :: tokenizer.Token
Error              :: tokenizer.Error
tokenize           :: tokenizer.tokenize

parse              :: parser.parse

check              :: checker.check
Checker            :: checker.Checker
Checker_Flags      :: checker.Flags
Buffer_Address     :: checker.Buffer_Address
Reflection_Info    :: checker.Reflection_Info
Entry_Point_Info   :: checker.Entry_Point_Info
Library            :: checker.Library

Const_Value        :: types.Const_Value
Type               :: types.Type

cg_generate        :: cg.generate

Ast_Node           :: ast.Node
Ast_Expr           :: ast.Expr
Ast_Stmt           :: ast.Stmt
Ast_Decl           :: ast.Decl

Ast_Field          :: ast.Field
Ast_Switch_Case    :: ast.Switch_Case

Ast_Shader_Stage   :: ast.Shader_Stage
Ast_Builtin_Id     :: ast.Builtin_Id

Ast_Expr_Binary    :: ast.Expr_Binary
Ast_Expr_Unary     :: ast.Expr_Unary
Ast_Expr_Constant  :: ast.Expr_Constant
Ast_Expr_Ident     :: ast.Expr_Ident
Ast_Expr_Interface :: ast.Expr_Interface
Ast_Expr_Config    :: ast.Expr_Config
Ast_Expr_Proc_Lit  :: ast.Expr_Proc_Lit
Ast_Expr_Proc_Sig  :: ast.Expr_Proc_Sig
Ast_Expr_Call      :: ast.Expr_Call
Ast_Expr_Paren     :: ast.Expr_Paren
Ast_Expr_Selector  :: ast.Expr_Selector
Ast_Expr_Compound  :: ast.Expr_Compound
Ast_Expr_Index     :: ast.Expr_Index
Ast_Expr_Cast      :: ast.Expr_Cast

Ast_Type_Struct    :: ast.Type_Struct
Ast_Type_Array     :: ast.Type_Array
Ast_Type_Matrix    :: ast.Type_Matrix
Ast_Type_Import    :: ast.Type_Import
Ast_Type_Image     :: ast.Type_Image
Ast_Type_Enum      :: ast.Type_Enum

Ast_Decl_Value     :: ast.Decl_Value

Ast_Stmt_Return    :: ast.Stmt_Return
Ast_Stmt_Break     :: ast.Stmt_Break
Ast_Stmt_Continue  :: ast.Stmt_Continue
Ast_Stmt_For_Range :: ast.Stmt_For_Range
Ast_Stmt_For       :: ast.Stmt_For
Ast_Stmt_Block     :: ast.Stmt_Block
Ast_Stmt_If        :: ast.Stmt_If
Ast_Stmt_When      :: ast.Stmt_When
Ast_Stmt_Switch    :: ast.Stmt_Switch
Ast_Stmt_Assign    :: ast.Stmt_Assign
Ast_Stmt_Expr      :: ast.Stmt_Expr

Ast_Any_Node       :: ast.Any_Node
Ast_Any_Expr       :: ast.Any_Expr
Ast_Any_Decl       :: ast.Any_Decl
Ast_Any_Stmt       :: ast.Any_Stmt

SPIR_V_VERSION_CURRENT :: spv.VERSION
SPIR_V_VERSION_1_0     :: 0x00010000 // use with OpenGL
SPIR_V_VERSION_1_1     :: 0x00010100
SPIR_V_VERSION_1_2     :: 0x00010200
SPIR_V_VERSION_1_3     :: 0x00010300
SPIR_V_VERSION_1_4     :: 0x00010400
SPIR_V_VERSION_1_5     :: 0x00010500
SPIR_V_VERSION_1_6     :: 0x00010600

@(require_results)
check_library :: proc(
	source:        string,
	path:          string,
	defines:       map[string]Const_Value = {},
	shared_types:  []typeid               = {},
	libraries:     map[string]Library     = {},
	allocator       := context.allocator,
	error_allocator := context.allocator,
) -> (library: checker.Library, errors: []Error) {
	tokens: []Token
	tokens, errors = tokenize(source, false, context.temp_allocator, error_allocator)
	if len(errors) != 0 {
		return
	}

	stmts: []^Ast_Stmt
	stmts, errors = parse(tokens, context.temp_allocator, error_allocator)
	if len(errors) != 0 {
		return
	}

	c: Checker
	c, errors = check(stmts, defines, shared_types, libraries, {}, context.temp_allocator, error_allocator)
	if len(errors) != 0 {
		return
	}

	return checker.to_library(c), {}
}

@(require_results)
compile_shader :: proc(
	source:        string,
	path:          string,
	defines:       map[string]Const_Value = {},
	shared_types:  []typeid               = {},
	libraries:     map[string]Library     = {},
	spirv_version: u32                    = SPIR_V_VERSION_CURRENT,
	allocator       := context.allocator,
	error_allocator := context.allocator,
) -> (code: []u32, errors: []Error) {
	tokens: []Token
	tokens, errors = tokenize(source, false, context.temp_allocator, error_allocator)
	if len(errors) != 0 {
		return
	}

	stmts: []^Ast_Stmt
	stmts, errors = parse(tokens, context.temp_allocator, error_allocator)
	if len(errors) != 0 {
		return
	}

	checker: Checker
	checker, errors = check(stmts, defines, shared_types, libraries, {}, context.temp_allocator, error_allocator)
	if len(errors) != 0 {
		return
	}

	code = cg_generate(&checker, stmts, path, source, spirv_version, allocator = allocator)

	return
}

HEPHAISTOS_NO_TYPE_FORMATTER :: #config(HEPHAISTOS_NO_TYPE_FORMATTER, false)

// necessary to get usable error messages
when !HEPHAISTOS_NO_TYPE_FORMATTER {
	_user_formatters: map[typeid]fmt.User_Formatter
	@(init)
	_register_type_formatter :: proc "contextless" () {
		context = runtime.default_context()

		formatter :: proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
			#no_type_assert t := arg.(^Type)
			types.print_writer(fi.writer, t)
			return true
		}

		err := fmt.register_user_formatter(^Type, formatter)
		switch err {
		case .No_User_Formatter:
			fmt.set_user_formatters(&_user_formatters)
			err := fmt.register_user_formatter(^Type, formatter)
			assert(err == .None)
		case .Formatter_Previously_Found, .None:
			// don't care
		}

		ti := reflect.type_info_base(type_info_of(type_of(Type{}.variant)))
		for v in ti.variant.(reflect.Type_Info_Union).variants {
			err := fmt.register_user_formatter(v.id, formatter)
			assert(err == .None)
		}
	}

	@(fini)
	_destroy_user_formatter :: proc "contextless" () {
		context = runtime.default_context()

		delete(_user_formatters)
	}
} else {
	_ :: reflect
	_ :: runtime
}

print_error :: proc(w: io.Writer, file_name: string, lines: []string, error: Error) -> (n: int) {
	if error.line == 0 {
		return fmt.wprintf(w, ansi.CSI + ansi.FG_RED + ansi.SGR + "Error:" + ansi.CSI + ansi.RESET + ansi.SGR + " %s\n", error.message)
	}
	n += fmt.wprintf(w, ansi.CSI + ansi.BOLD   + ansi.SGR + "%s(%v:%v) ", file_name, error.line, error.column)
	n += fmt.wprintf(w, ansi.CSI + ansi.FG_RED + ansi.SGR + "Error:" + ansi.CSI + ansi.RESET + ansi.SGR + " %s\n", error.message)
	n += fmt.wprintln(w, lines[error.line - 1])
	for i in 1 ..< error.column {
		if lines[error.line - 1][i - 1] == '\t' {
			n += fmt.wprint(w, "\t")
		} else {
			n += fmt.wprint(w, " ")
		}
	}
	n += fmt.wprint(w, ansi.CSI + ansi.FG_GREEN + ansi.SGR + "^")
	for _ in error.column ..< error.end.column - 2 {
		n += fmt.wprint(w, "~")
	}
	if error.column < error.end.column - 1 {
		n += fmt.wprint(w, "^")
	}
	n += fmt.wprintln(w, ansi.CSI + ansi.RESET + ansi.SGR)
	return
}
