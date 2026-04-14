package hephaistos_parser

import "base:runtime"

import "core:fmt"
import "core:reflect"
import "core:strings"

import "../ast"
import "../tokenizer"

Parser :: struct {
	current:         int,
	tokens:          []tokenizer.Token,
	errors:          [dynamic]tokenizer.Error,
	end_location:    tokenizer.Location,
	allocator:       runtime.Allocator,
	error_allocator: runtime.Allocator,
}

@(require_results)
token_peek :: proc(parser: ^Parser, lookahead := 0) -> tokenizer.Token {
	return parser.tokens[min(parser.current + lookahead, len(parser.tokens) - 1)]
}

token_advance :: proc(parser: ^Parser) -> (t: tokenizer.Token) {
	t = token_peek(parser)
	parser.end_location = t.location
	parser.end_location.column += len(t.text)
	parser.end_location.offset += len(t.text)
	parser.current += 1
	return
}

token_expect :: proc(parser: ^Parser, kind: tokenizer.Token_Kind, after: string = "") -> (token: tokenizer.Token, ok: bool) {
	token = token_advance(parser)
	if token.kind != kind {
		e := tokenizer.to_string(kind)
		g := tokenizer.to_string(token.kind)
		if after != "" {
			error(parser, token, "expected '%s' after %s, got '%s'", e, after, g)
		} else {
			error(parser, token, "expected '%s', got '%s'", e, g)
		}
		return
	}
	ok = true
	return
}

parse_field_list :: proc(
	parser:               ^Parser,
	terminator:           tokenizer.Token_Kind,
	allow_default_values: bool,
	allow_locations := false,
	types           := true,
) -> (_fields: []ast.Field, ok: bool) {
	fields := make([dynamic]ast.Field, parser.allocator)

	loop: for {
		#partial switch token_peek(parser).kind {
		case terminator, .EOF:
			break loop
		}
		ident := token_expect(parser, .Ident) or_return
		type: ^ast.Expr
		if types {
			if token_peek(parser).kind == .Colon {
				token_advance(parser)

				if token_peek(parser).kind != .Assign {
					type = parse_expr(parser) or_return
				}
			} else if token_peek(parser).kind == .Assign {
				break
			}
		}

		value: ^ast.Expr
		if allow_default_values && token_peek(parser).kind == .Assign {
			token_advance(parser)
			value = parse_expr(parser) or_return
		}

		location: ^ast.Expr
		if allow_locations {
			// TODO: make a decision
			if token_peek(parser).kind == .Attribute || token_peek(parser).kind == .Arrow {
				token_advance(parser)
				location = parse_expr(parser) or_return
			}
		}

		append(&fields, ast.Field {
			ident    = ident,
			value    = value,
			type     = type,
			location = location,
		})

		if token_peek(parser).kind == .Comma {
			token_advance(parser)
		} else {
			break
		}
	}

	token_expect(parser, terminator)

	return fields[:], true
}

parse_arg_list :: proc(parser: ^Parser, terminator: tokenizer.Token_Kind) -> (_fields: []ast.Field, ok: bool) {
	fields := make([dynamic]ast.Field, parser.allocator)

	loop: for {
		#partial switch token_peek(parser).kind {
		case terminator, .EOF:
			break loop
		}

		ident: tokenizer.Token
		if token_peek(parser, 1).kind == .Assign {
			ident = token_expect(parser, .Ident) or_return
			token_expect(parser, .Assign) or_return
		}

		value := parse_expr(parser) or_return

		append(&fields, ast.Field {
			ident = ident,
			value = value,
		})

		if token_peek(parser).kind == .Comma {
			token_advance(parser)
		} else {
			break
		}
	}
	token_expect(parser, terminator)

	return fields[:], true
}

parse_proc_signature :: proc(parser: ^Parser) -> (args, returns: []ast.Field, ok: bool) {
	token_expect(parser, .Proc) or_return
	token_expect(parser, .Open_Paren)
	args = parse_field_list(parser, .Close_Paren, true, true) or_return

	if token_peek(parser).kind == .Arrow {
		token_advance(parser)

		if token_peek(parser).kind == .Open_Paren {
			token_advance(parser)
			returns = parse_field_list(parser, .Close_Paren, true, true) or_return
		} else {
			returns         = make([]ast.Field, 1, parser.allocator)
			returns[0].type = parse_expr(parser, allow_compound_literals = false) or_return
		}
	}

	return args, returns, true
}

parse_stmt_list :: proc(
	parser:          ^Parser,
	terminator:       tokenizer.Token_Kind = .Close_Brace,
	extra_terminator: tokenizer.Token_Kind = nil,
) -> (_stmts: []^ast.Stmt, ok: bool) {
	for token_peek(parser).kind == .Semicolon {
		token_advance(parser)
	}

	stmts := make([dynamic]^ast.Stmt, parser.allocator)
	for {
		#partial switch token_peek(parser).kind {
		case .EOF:
			token_expect(parser, terminator) or_return
			return stmts[:], true
		case terminator, extra_terminator:
			return stmts[:], true
		}

		stmt, ok := parse_stmt(parser)
		if ok {
			append(&stmts, stmt)
		} else {
			for token_peek(parser).kind != .Semicolon && token_peek(parser).kind != .EOF {
				token_advance(parser)
			}
		}

		for token_peek(parser).kind == .Semicolon {
			token_advance(parser)
		}
	}
}

parse_atom_expr :: proc(parser: ^Parser, allow_compound_literals: bool) -> (expr: ^ast.Expr, ok: bool) {
	token := token_peek(parser) 
	#partial switch token.kind {
	case .Ident:
		token_advance(parser)
		expr := ast.new(ast.Expr_Ident, token.location, parser.end_location, parser.allocator)
		expr.ident = token

		if allow_compound_literals && token_peek(parser).kind == .Open_Brace {
			token_advance(parser)
			values := parse_arg_list(parser, .Close_Brace) or_return
			comp   := ast.new(ast.Expr_Compound, token.location, parser.end_location, parser.allocator)
			comp.fields    = values
			comp.type_expr = expr
			return comp, true
		}

		return expr, true

	case .Dollar:
		token_advance(parser)
		ident := token_expect(parser, .Ident) or_return
		expr := ast.new(ast.Expr_Interface, token.location, parser.end_location, parser.allocator)
		expr.ident = ident
		return expr, true

	case .Literal:
		token_advance(parser)
		expr := ast.new(ast.Expr_Constant, token.location, parser.end_location, parser.allocator)
		#partial switch token.value_kind {
		case .Int:
			expr.value = token.value.int
		case .Float:
			expr.value = token.value.float
		case .Bool:
			expr.value = token.value.bool
		case .String:
			expr.value = token.text[1:len(token.text) - 1]
		case:
			unreachable()
		}
		expr.imaginary = token.imaginary
		return expr, true

	case .Open_Brace:
		token_advance(parser)
		fields := parse_arg_list(parser, .Close_Brace) or_return
		expr   := ast.new(ast.Expr_Compound, token.location, parser.end_location, parser.allocator)
		expr.fields = fields
		return expr, true

	case .Proc:
		if token_peek(parser, 1).kind == .Open_Brace {
			token_expect(parser, .Proc)
			token_expect(parser, .Open_Brace)

			members := make([dynamic]^ast.Expr, parser.allocator)
			for {
				if token_peek(parser).kind == .Close_Brace {
					break
				}

				append(&members, parse_expr(parser) or_break)
				token_expect(parser, .Comma) or_break
			}
			token_expect(parser, .Close_Brace)

			group        := ast.new(ast.Expr_Proc_Group, token.location, parser.end_location, parser.allocator)
			group.members = members[:]
			return group, true
		}
		args, returns := parse_proc_signature(parser) or_return
		if token_peek(parser).kind == .Open_Brace {
			token_advance(parser)
			body := parse_stmt_list(parser) or_return
			token_advance(parser)

			lit := ast.new(ast.Expr_Proc_Lit, token.location, parser.end_location, parser.allocator)
			lit.args    = args
			lit.returns = returns
			lit.body    = body
			return lit, true
		} else {
			sig := ast.new(ast.Expr_Proc_Sig, token.location, parser.end_location, parser.allocator)
			sig.args    = args
			sig.returns = returns
			return sig, true
		}

	case .Struct:
		token_advance(parser)
		token_expect(parser, .Open_Brace) or_return
		fields := parse_field_list(parser, .Close_Brace, false) or_return
		s      := ast.new(ast.Type_Struct, token.location, parser.end_location, parser.allocator)
		s.fields = fields
		if allow_compound_literals && token_peek(parser).kind == .Open_Brace {
			token_advance(parser)
			values := parse_arg_list(parser, .Close_Brace) or_return
			comp   := ast.new(ast.Expr_Compound, token.location, parser.end_location, parser.allocator)
			comp.fields    = values
			comp.type_expr = s
			return comp, true
		}
		return s, true

	case .Enum:
		token_advance(parser)
		token_expect(parser, .Open_Brace) or_return
		values := parse_field_list(parser, .Close_Brace, false, types = false) or_return
		s      := ast.new(ast.Type_Enum, token.location, parser.end_location, parser.allocator)
		s.values = values
		return s, true

	case .Bit_Set:
		token_advance(parser)
		token_expect(parser, .Open_Bracket) or_return
		enum_type  := parse_expr(parser) or_return
		token_expect(parser, .Semicolon) or_return
		backing    := parse_expr(parser) or_return
		token_expect(parser, .Close_Bracket) or_return
		b          := ast.new(ast.Type_Bit_Set, token.location, parser.end_location, parser.allocator)
		b.enum_type = enum_type
		b.backing   = backing
		return b, true

	case .Matrix:
		token_advance(parser)
		token_expect(parser, .Open_Bracket) or_return
		rows := parse_expr(parser) or_return
		cols: ^ast.Expr
		if token_peek(parser).kind == .Comma {
			token_advance(parser)
			cols = parse_expr(parser) or_return
		}
		token_expect(parser, .Close_Bracket) or_return
		elem := parse_expr(parser) or_return

		m := ast.new(ast.Type_Matrix, token.location, parser.end_location, parser.allocator)
		m.rows = rows
		m.cols = cols
		m.elem = elem

		if allow_compound_literals && token_peek(parser).kind == .Open_Brace {
			token_advance(parser)
			values := parse_arg_list(parser, .Close_Brace) or_return
			comp   := ast.new(ast.Expr_Compound, token.location, parser.end_location, parser.allocator)
			comp.fields    = values
			comp.type_expr = m
			return comp, true
		}

		return m, true

	case .Open_Bracket:
		token_expect(parser, .Open_Bracket) or_return
		count: ^ast.Expr
		physical: bool
		if token_peek(parser).kind == .Pointer {
			physical = true
			token_advance(parser)
		} else if token_peek(parser).kind != .Close_Bracket {
			count = parse_expr(parser) or_return
		}
		token_expect(parser, .Close_Bracket) or_return
		elem := parse_expr(parser, allow_compound_literals = false) or_return

		a := ast.new(ast.Type_Array, token.location, parser.end_location, parser.allocator)
		a.count    = count
		a.elem     = elem
		a.physical = physical

		if allow_compound_literals && token_peek(parser).kind == .Open_Brace {
			token_advance(parser)
			values := parse_arg_list(parser, .Close_Brace) or_return
			comp   := ast.new(ast.Expr_Compound, token.location, parser.end_location, parser.allocator)
			comp.fields    = values
			comp.type_expr = a
			return comp, true
		}

		return a, true

	case .Sampler, .Image:
		token_advance(parser)
		token_expect(parser, .Open_Bracket) or_return
		dim := parse_expr(parser) or_return
		token_expect(parser, .Close_Bracket) or_return
		texel := parse_expr(parser, allow_compound_literals = false) or_return

		s := ast.new(ast.Type_Image, token.location, parser.end_location, parser.allocator)
		s.dimensions = dim
		s.texel_type = texel
		s.is_sampler = token.kind == .Sampler
		return s, true

	case .Open_Paren:
		token_advance(parser)
		expr := parse_expr(parser) or_return
		token_expect(parser, .Close_Paren) or_return
		paren := ast.new(ast.Expr_Paren, token.location, parser.end_location, parser.allocator)
		paren.expr = expr
		return paren, true

	case .Add, .Subtract, .Xor, .Not:
		token_advance(parser)
		expr      := parse_atom_expr(parser, allow_compound_literals = allow_compound_literals) or_return
		unary     := ast.new(ast.Expr_Unary, token.location, parser.end_location, parser.allocator)
		unary.expr = expr
		unary.op   = token.kind
		return unary, true

	case .Cast:
		token_advance(parser)
		token_expect(parser, .Open_Paren, "cast") or_return
		type := parse_expr(parser) or_return
		token_expect(parser, .Close_Paren) or_return
		value := parse_expr(parser) or_return
		c     := ast.new(ast.Expr_Cast, token.location, parser.end_location, parser.allocator)
		c.type_expr = type
		c.value     = value
		return c, true

	case .Directive:
		token_advance(parser)
		directive_token: tokenizer.Token
		if token_peek(parser).kind == .Import {
			directive_token = token_advance(parser)
		} else {
			directive_token = token_expect(parser, .Ident, "directive") or_return
		}

		directive: ast.Directive
		for name, d in ast.directive_names {
			if name == directive_token.text {
				directive = d
				break
			}
		}

		if directive != nil {
			token_expect(parser, .Open_Paren, "directive") or_return
			args       := parse_arg_list(parser, .Close_Paren) or_return
			d          := ast.new(ast.Expr_Directive, token.location, parser.end_location, parser.allocator)
			d.token     = directive_token
			d.directive = directive

			c     := ast.new(ast.Expr_Call, token.location, parser.end_location, parser.allocator)
			c.lhs  = d
			c.args = args

			return c, true
		}

		switch directive_token.text {
		case "format":
			token_expect(parser, .Open_Paren, "#format") or_return
			format := token_expect(parser, .Ident, "#format") or_return
			token_expect(parser, .Close_Paren, "#format") or_return

			image := parse_expr(parser) or_return
			if image, ok := image.derived_expr.(^ast.Type_Image); ok {
				image.format = format
			} else {
				error(parser, directive_token, "'#format' directive can only be applied to image types")
			}

			return image, true
		case:
			error(parser, directive_token, "unknown directive: '%s'", directive_token.text)
		}
	case .Period:
		token_advance(parser)
		ident     := token_expect(parser, .Ident) or_return
		s         := ast.new(ast.Expr_Selector, token.location, parser.end_location, parser.allocator)
		s.lhs      = nil
		s.selector = ident
		return s, true
	}

	error(parser, token, "unexpected token")
	return
}

binding_powers: #sparse [tokenizer.Token_Kind]int = #partial {
	.Question_Mark  = 2,
	.If             = 2,

	.And            = 3,
	.Or             = 3,

	.Less           = 4,
	.Greater        = 4,
	.Equal          = 4,
	.Not_Equal      = 4,
	.Less_Equal     = 4,
	.Greater_Equal  = 4,

	.Add            = 5,
	.Subtract       = 5,

	.Bit_And        = 6,
	.Bit_Or         = 6,
	.Multiply       = 6,
	.Divide         = 6,
	.Shift_Left     = 6,
	.Shift_Right    = 6,
	.Modulo         = 6,
	.Modulo_Floored = 6,
}

parse_expr :: proc(parser: ^Parser, min_power := 0, allow_compound_literals := true) -> (expr: ^ast.Expr, ok: bool) {
	lhs := parse_atom_expr(parser, allow_compound_literals) or_return
	for {
		op := token_peek(parser)
		#partial switch op.kind {
		case .Period:
			token_advance(parser)
			ident    := token_expect(parser, .Ident) or_return
			selector := ast.new(ast.Expr_Selector, lhs.start, parser.end_location, parser.allocator)
			selector.lhs      = lhs
			selector.selector = ident
			lhs               = selector
			continue

		case .Open_Paren:
			token_advance(parser)
			args := parse_arg_list(parser, .Close_Paren) or_return
			call := ast.new(ast.Expr_Call, lhs.start, parser.end_location, parser.allocator)
			call.lhs  = lhs
			call.args = args
			lhs       = call
			continue

		case .Open_Bracket:
			token_advance(parser)
			rhs := parse_expr(parser) or_return
			token_expect(parser, .Close_Bracket) or_return
			index := ast.new(ast.Expr_Index, lhs.start, parser.end_location, parser.allocator)
			index.lhs = lhs
			index.rhs = rhs
			lhs       = index
			continue
		}

		power := binding_powers[op.kind]
		if power == 0 || power <= min_power {
			break
		}

		#partial switch op.kind {
		case .Question_Mark:
			token_advance(parser)
			then_expr := parse_expr(parser) or_return
			token_expect(parser, .Colon, "ternary then expression") or_return
			else_expr  := parse_expr(parser) or_return
			t          := ast.new(ast.Expr_Ternary, lhs.start, parser.end_location, parser.allocator)
			t.cond      = lhs
			t.then_expr = then_expr
			t.else_expr = else_expr
			lhs         = t
			continue

		case .If:
			token_advance(parser)
			cond := parse_expr(parser) or_return
			token_expect(parser, .Else, "ternary condition") or_return
			else_expr  := parse_expr(parser) or_return
			t          := ast.new(ast.Expr_Ternary, lhs.start, parser.end_location, parser.allocator)
			t.cond      = cond
			t.then_expr = lhs
			t.else_expr = else_expr
			lhs         = t
			continue
		}

		token_advance(parser)
		rhs := parse_expr(parser, power, allow_compound_literals) or_return
		e   := ast.new(ast.Expr_Binary, lhs.start, parser.end_location, parser.allocator)

		e.op  = op.kind
		e.lhs = lhs
		e.rhs = rhs

		lhs  = e
	}
	return lhs, true
}

parse_expr_list :: proc(parser: ^Parser, allow_compound_literals := true) -> (exprs: []^ast.Expr, ok: bool) {
	es := make([dynamic]^ast.Expr, parser.allocator)
	for token_peek(parser).kind != .EOF {
		append(&es, parse_expr(parser, allow_compound_literals = allow_compound_literals) or_return)
		if token_peek(parser).kind == .Comma {
			token_advance(parser)
		} else {
			break
		}
	}
	return es[:], true
}

parse_simple_stmt :: proc(parser: ^Parser, attributes: []ast.Field = {}) -> (stmt: ^ast.Stmt, ok: bool) {
	token := token_peek(parser)
	#partial switch token.kind {
	case .Literal:
		expr := parse_expr(parser, allow_compound_literals = false) or_return
		se   := ast.new(ast.Stmt_Expr, token.location, parser.end_location, parser.allocator)
		se.expr = expr
		return se, true
	case .Ident, .Cast, .Open_Paren, .Dollar, .Directive:
		lhs := parse_expr_list(parser, false) or_return
		#partial switch t := token_peek(parser); t.kind {
		case .Assign:
			assign_token := token_advance(parser)
			rhs          := parse_expr_list(parser) or_return
			assign       := ast.new(ast.Stmt_Assign, token.location, parser.end_location, parser.allocator)
			assign.lhs    = lhs[:]
			assign.rhs    = rhs
			assign.op     = assign_token.value.op
			return assign, true
		case .Colon:
			token_advance(parser)
			if token_peek(parser).kind == .Assign || token_peek(parser).kind == .Colon {
				mutable     := token_advance(parser).kind == .Assign
				values      := parse_expr_list(parser) or_return
				decl        := ast.new(ast.Decl_Value, token.location, parser.end_location, parser.allocator)
				decl.lhs        = lhs
				decl.values     = values
				decl.mutable    = mutable
				decl.attributes = attributes
				return decl, true
			} else {
				type := parse_expr(parser) or_return
				if token_peek(parser).kind == .Assign || token_peek(parser).kind == .Colon {
					mutable       := token_advance(parser).kind == .Assign
					values        := parse_expr_list(parser) or_return
					decl          := ast.new(ast.Decl_Value, token.location, parser.end_location, parser.allocator)
					decl.lhs        = lhs
					decl.values     = values
					decl.mutable    = mutable
					decl.type_expr  = type
					decl.attributes = attributes
					return decl, true
				} else {
					decl           := ast.new(ast.Decl_Value, token.location, parser.end_location, parser.allocator)
					decl.lhs        = lhs
					decl.mutable    = true
					decl.type_expr  = type
					decl.attributes = attributes
					return decl, true
				}
			}
		case:
			if len(lhs) == 1 {
				se := ast.new(ast.Stmt_Expr, token.location, parser.end_location, parser.allocator)
				se.expr = lhs[0]
				return se, true
			}
		}
	case .Return:
		token_advance(parser)
		values := make([dynamic]^ast.Expr, parser.allocator)
		for token_peek(parser).kind != .Semicolon {
			if len(values) != 0 {
				token_expect(parser, .Comma)
			}
			value := parse_expr(parser) or_return
			append(&values, value)
		}
		ret := ast.new(ast.Stmt_Return, token.location, parser.end_location, parser.allocator)
		ret.values = values[:]

		return ret, true
	case .Continue:
		token_advance(parser)
		label: tokenizer.Token
		if token_peek(parser).kind == .Ident {
			label = token_advance(parser)
		}
		cont := ast.new(ast.Stmt_Continue, token.location, parser.end_location, parser.allocator)
		cont.label = label

		return cont, true
	case .Break:
		token_advance(parser)
		label: tokenizer.Token
		if token_peek(parser).kind == .Ident {
			label = token_advance(parser)
		}
		brk := ast.new(ast.Stmt_Break, token.location, parser.end_location, parser.allocator)
		brk.label = label

		return brk, true
	}

	error(parser, token, "unexpected token")
	return
}

parse_attributes :: proc(parser: ^Parser) -> (_attributes: []ast.Field, ok: bool) {
	token_expect(parser, .Attribute)
	attributes := make([dynamic]ast.Field, parser.allocator)

	parse_attr_list :: proc(parser: ^Parser, attributes: ^[dynamic]ast.Field) -> bool {
		loop: for {
			#partial switch token_peek(parser).kind {
			case .Close_Paren, .EOF:
				break loop
			}

			ident := token_expect(parser, .Ident) or_return

			value: ^ast.Expr
			if token_peek(parser).kind == .Assign {
				token_advance(parser)
				value = parse_expr(parser) or_return
			}

			append(attributes, ast.Field {
				ident = ident,
				value = value,
			})

			if token_peek(parser).kind == .Comma {
				token_advance(parser)
			} else {
				break
			}
		}

		token_expect(parser, .Close_Paren)
		return true
	}

	#partial switch token := token_peek(parser); token.kind {
	case .Ident:
		append(&attributes, ast.Field {
			ident = token,
		})
		return attributes[:], true
	case .Open_Paren:
		token_advance(parser)
		defer if token_peek(parser).kind == .Semicolon do token_advance(parser)
		parse_attr_list(parser, &attributes) or_return
		return attributes[:], true
	case:
		error(parser, token, "expected identifier or '(', got '%s'", token.text)
	}
	return
}

parse_stmt :: proc(parser: ^Parser, label: tokenizer.Token = {}, attributes: []ast.Field = {}) -> (stmt: ^ast.Stmt, ok: bool) {
	token := token_peek(parser)
	#partial switch token.kind {
	case .Attribute:
		if len(attributes) != 0 {
			error(parser, token, "only one set of attributes can be applied to a statement")
		}
		return parse_stmt(parser, label, parse_attributes(parser) or_return)
	case .Return, .Continue, .Break, .Literal, .Open_Paren, .Cast, .Dollar, .Directive:
		return parse_simple_stmt(parser, attributes)
	case .Import:
		token_advance(parser)
		alias: tokenizer.Token
		if token_peek(parser).kind == .Ident {
			alias = token_advance(parser)
		}
		lit := token_expect(parser, .Literal, "import") or_return
		if lit.value_kind != .String {
			error(parser, token, "expected a string literal after `import` keyword")
			return
		}

		name: string
		if alias.text != "" {
			name = alias.text
		} else {
			name = lit.text[1:len(lit.text) - 1]
			cut := strings.last_index_any(name, ":/")
			if cut != -1 && cut != len(name) - 1 {
				name = name[cut + 1:]
			}

			valid := true
			for char in name {
				switch char {
				case '0' ..= '9', 'a' ..= 'z', 'A' ..= 'Z', '_':
					continue
				}
				valid = false
				break
			}

			if !valid {
				error(parser, lit, "'%s' is not a valid package name, consider renaming the imported package: `import foo %s`", name, lit.text)
			}
		}

		import_decl        := ast.new(ast.Decl_Import, token.location, parser.end_location, parser.allocator)
		import_decl.name    = name
		import_decl.library = lit
		return import_decl, true
	case .Ident:
		if token_peek(parser, 1).kind == .Colon {
			#partial switch token_peek(parser, 2).kind {
			case .For, .If, .Switch, .Open_Brace:
				token_advance(parser)
				token_advance(parser)
				return parse_stmt(parser, token)
			}
		}
		return parse_simple_stmt(parser, attributes)
	case .For:
		token_advance(parser)
		init: ^ast.Stmt
		cond: ^ast.Expr
		post: ^ast.Stmt

		parse_header: if token_peek(parser).kind != .Open_Brace {
			if token_peek(parser).kind == .Semicolon {
				token_advance(parser)
			} else {
				s := parse_simple_stmt(parser) or_return
				if expr_stmt, ok := s.derived.(^ast.Stmt_Expr); ok {
					if token_peek(parser).kind == .In {
						token_advance(parser)
						start     := parse_expr(parser) or_return
						inclusive := false
						#partial switch token_peek(parser).kind {
						case .Range_Equal:
							token_advance(parser)
							inclusive = true
						case .Range_Less:
							token_advance(parser)
						case:
							token_expect(parser, .Range_Less) or_return
						}
						end := parse_expr(parser, allow_compound_literals = false) or_return
						token_expect(parser, .Open_Brace) or_return
						body := parse_stmt_list(parser) or_return
						token_advance(parser)

						range_stmt           := ast.new(ast.Stmt_For_Range, token.location, parser.end_location, parser.allocator)
						range_stmt.variable   = expr_stmt.expr
						range_stmt.label      = label
						range_stmt.start_expr = start
						range_stmt.inclusive  = inclusive
						range_stmt.end_expr   = end
						range_stmt.body       = body

						return range_stmt, true
					}
					cond = expr_stmt.expr
					break parse_header
				}
				init = s
				token_expect(parser, .Semicolon) or_return
			}

			if token_peek(parser).kind != .Semicolon {
				cond = parse_expr(parser) or_return
			}
			token_expect(parser, .Semicolon) or_return

			if token_peek(parser).kind != .Open_Brace {
				post = parse_simple_stmt(parser) or_return
			}
		}

		token_expect(parser, .Open_Brace) or_return

		body := parse_stmt_list(parser) or_return
		token_advance(parser)

		for_stmt := ast.new(ast.Stmt_For, token.location, parser.end_location, parser.allocator)
		for_stmt.label = label
		for_stmt.init  = init
		for_stmt.cond  = cond
		for_stmt.post  = post
		for_stmt.body  = body
		return for_stmt, true
	case .If:
		token_advance(parser)
		init: ^ast.Stmt
		cond: ^ast.Expr
		parse_if_header: {
			s := parse_simple_stmt(parser) or_return
			if expr_stmt, ok := s.derived.(^ast.Stmt_Expr); ok {
				cond = expr_stmt.expr
				break parse_if_header
			}
			init = s
			token_expect(parser, .Semicolon) or_return
			cond = parse_expr(parser, allow_compound_literals = false) or_return
		}

		token_expect(parser, .Open_Brace) or_return
		then_block := parse_stmt_list(parser) or_return
		token_advance(parser)
		else_block: []^ast.Stmt
		if token_peek(parser).kind == .Else {
			token_advance(parser)
			token_expect(parser, .Open_Brace) or_return
			else_block = parse_stmt_list(parser) or_return
			token_expect(parser, .Close_Brace)
		}

		if_stmt := ast.new(ast.Stmt_If, token.location, parser.end_location, parser.allocator)
		if_stmt.label      = label
		if_stmt.init       = init
		if_stmt.cond       = cond
		if_stmt.then_block = then_block
		if_stmt.else_block = else_block
		return if_stmt, true
	case .When:
		token_advance(parser)
		cond := parse_expr(parser, allow_compound_literals = false) or_return

		token_expect(parser, .Open_Brace) or_return
		then_block := parse_stmt_list(parser) or_return
		token_advance(parser)
		else_block: []^ast.Stmt
		if token_peek(parser).kind == .Else {
			token_advance(parser)
			token_expect(parser, .Open_Brace) or_return
			else_block = parse_stmt_list(parser) or_return
			token_expect(parser, .Close_Brace)
		}

		when_stmt := ast.new(ast.Stmt_When, token.location, parser.end_location, parser.allocator)
		when_stmt.label      = label
		when_stmt.cond       = cond
		when_stmt.then_block = then_block
		when_stmt.else_block = else_block
		return when_stmt, true
	case .Switch:
		token_advance(parser)
		init: ^ast.Stmt
		cond: ^ast.Expr
		parse_switch_header: {
			s := parse_simple_stmt(parser) or_return
			if expr_stmt, ok := s.derived.(^ast.Stmt_Expr); ok {
				cond = expr_stmt.expr
				break parse_switch_header
			}
			init = s
			token_expect(parser, .Semicolon) or_return
			cond = parse_expr(parser, allow_compound_literals = false) or_return
		}

		token_expect(parser, .Open_Brace) or_return

		cases := make([dynamic]ast.Switch_Case, parser.allocator)
		for token_peek(parser).kind != .Close_Brace && !parser_at_end(parser) {
			token_expect(parser, .Case) or_continue
			value: ^ast.Expr
			if token_peek(parser).kind != .Colon {
				value = parse_expr(parser) or_continue
			}
			token_expect(parser, .Colon)
			append(&cases, ast.Switch_Case {
				value = value,
				body  = parse_stmt_list(parser, .Close_Brace, .Case) or_continue,
			})
		}
		token_expect(parser, .Close_Brace)

		s := ast.new(ast.Stmt_Switch, token.location, parser.end_location, parser.allocator)
		s.init  = init
		s.cond  = cond
		s.cases = cases[:]

		return s, true

	case .Open_Brace:
		token_advance(parser)
		stmts := parse_stmt_list(parser) or_return
		token_advance(parser)

		block := ast.new(ast.Stmt_Block, token.location, parser.end_location, parser.allocator)
		block.label = label
		block.body  = stmts
		return block, true
	}

	error(parser, token, "unexpected token")
	return
}

print_expr :: proc(b: ^strings.Builder, expr: ^ast.Expr, indent := 0) {
	if expr == nil {
		return
	}
	for _ in 0 ..< indent {
		fmt.sbprint(b, "\t")
	}
	fmt.sbprintln(b, expr.derived)
	#partial switch v in expr.derived_expr {
	case ^ast.Expr_Proc_Lit:
		for s in v.body {
			print_stmt(b, s, indent + 1)
		}
	case ^ast.Expr_Binary:
		print_expr(b, v.lhs, indent + 1)
		print_expr(b, v.rhs, indent + 1)
	}
}

// only used for debugging
print_stmt :: proc(b: ^strings.Builder, stmt: ^ast.Stmt, indent := 0) {
	if stmt == nil {
		return
	}
	for _ in 0 ..< indent {
		fmt.sbprint(b, "\t")
	}
	fmt.sbprintfln(b, "%v", reflect.union_variant_typeid(stmt.derived))
	switch v in stmt.derived_stmt {
	case ^ast.Stmt_Return:
		for v in v.values {
			print_expr(b, v, indent + 1)
		}
	case ^ast.Stmt_Break:
	case ^ast.Stmt_Continue:
	case ^ast.Stmt_For_Range:
		for s in v.body {
			print_stmt(b, s, indent + 1)
		}
	case ^ast.Stmt_For:
		for s in v.body {
			print_stmt(b, s, indent + 1)
		}
	case ^ast.Stmt_Block:
		for s in v.body {
			print_stmt(b, s, indent + 1)
		}
	case ^ast.Stmt_If:
		for s in v.then_block {
			print_stmt(b, s, indent + 1)
		}
		fmt.println("ELSE")
		for s in v.else_block {
			print_stmt(b, s, indent + 1)
		}
	case ^ast.Stmt_When:
		for s in v.then_block {
			print_stmt(b, s, indent + 1)
		}
		fmt.println("ELSE")
		for s in v.else_block {
			print_stmt(b, s, indent + 1)
		}
	case ^ast.Stmt_Switch:
	case ^ast.Stmt_Assign:
	case ^ast.Stmt_Expr:

	case ^ast.Decl_Value:
		print_expr(b, v.type_expr,  indent + 1)
		// print_expr(b, v.value, indent + 1)
	case ^ast.Decl_Import:
		fmt.println("IMPORT", v.library.text)
	}
}

parse :: proc(
	tokens: []tokenizer.Token,
	allocator       := context.allocator,
	error_allocator := context.allocator,
) -> ([]^ast.Stmt, []tokenizer.Error) {
	parser: Parser = {
		allocator       = allocator,
		error_allocator = error_allocator,
		errors          = make([dynamic]tokenizer.Error, error_allocator),
		tokens          = tokens,
	}

	for token_peek(&parser).kind == .Semicolon {
		token_advance(&parser)
	}

	global_stmts, _ := parse_stmt_list(&parser, .EOF)

	return global_stmts, parser.errors[:]
}

parser_at_end :: proc(parser: ^Parser) -> bool {
	return token_peek(parser).kind == .EOF
}

error_start_end :: proc(parser: ^Parser, start, end: tokenizer.Location, format: string, args: ..any) {
	append(&parser.errors, tokenizer.Error {
		location = start,
		end      = end,
		message  = fmt.aprintf(format, ..args, allocator = parser.error_allocator),
	})
}

error_single_token :: proc(parser: ^Parser, token: tokenizer.Token, format: string, args: ..any) {
	append(&parser.errors, tokenizer.Error {
		location = token.location,
		end      = {
			line   = token.location.line,
			column = token.location.column + len(token.text),
			offset = token.location.offset + len(token.text),
		},
		message  = fmt.aprintf(format, ..args, allocator = parser.error_allocator),
	})
}

error :: proc {
	error_start_end,
	error_single_token,
}
