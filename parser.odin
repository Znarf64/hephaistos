package hephaistos

import "base:runtime"

import "core:strconv"

Parser :: struct {
	current:         int,
	tokens:          []Token,
	errors:          [dynamic]Error,
	end_location:    Location,
	allocator:       runtime.Allocator,
	error_allocator: runtime.Allocator,
}

blank_ident: ^Expr_Ident

@(init)
blank_ident_init :: proc "contextless" () {
	@(static)
	_ident: Expr_Ident
	_ident = {
		text         = "_",
		derived      = blank_ident,
		derived_expr = blank_ident,
	}
	blank_ident = &_ident
}

@(require_results)
token_peek :: proc(parser: ^Parser, lookahead := 0) -> Token {
	return parser.tokens[min(parser.current + lookahead, len(parser.tokens) - 1)]
}

token_advance :: proc(parser: ^Parser) -> (t: Token) {
	t                           = token_peek(parser)
	parser.end_location         = t.location
	parser.end_location.column += i32(len(t.text))
	parser.end_location.offset += i32(len(t.text))
	parser.current             += 1
	return
}

token_expect :: proc(parser: ^Parser, kind: Token_Kind, after: string = "") -> (token: Token, ok: bool) {
	token = token_advance(parser)
	if token.kind != kind {
		e := token_to_string(kind)
		g := token_to_string(token.kind)
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

@(require_results)
parse_field_list :: proc(
	parser:               ^Parser,
	terminator:           Token_Kind,
	allow_default_values: bool,
	allow_locations := false,
	types           := true,
) -> (_fields: []Ast_Field, ok: bool) {
	fields := make([dynamic]Ast_Field, parser.allocator)

	loop: for {
		flags: Entity_Flags
		#partial switch token_peek(parser).kind {
		case terminator, .EOF:
			break loop
		}
		for token_peek(parser).kind == .Directive {
			token_advance(parser)
			ident := token_expect(parser, .Ident, "'#'") or_continue
			switch ident.text {
			case "const":
				flags |= { .Const, }
			case "by_ptr":
				flags |= { .By_Ptr, }
			}
		}
		name := parse_ident(parser) or_return
		type: ^Ast_Expr
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

		value: ^Ast_Expr
		if allow_default_values && token_peek(parser).kind == .Assign {
			token_advance(parser)
			value = parse_expr(parser) or_return
		}

		location: ^Ast_Expr
		if allow_locations {
			if token_peek(parser).kind == .Attribute {
				token_advance(parser)
				location = parse_expr(parser) or_return
			}
		}

		append(&fields, Ast_Field {
			name     = name,
			value    = value,
			type     = type,
			location = location,
			flags    = flags,
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

parse_arg_list :: proc(parser: ^Parser, terminator: Token_Kind) -> (_fields: []Ast_Field, ok: bool) {
	fields := make([dynamic]Ast_Field, parser.allocator)

	loop: for {
		#partial switch token_peek(parser).kind {
		case terminator, .EOF:
			break loop
		}

		name: ^Expr_Ident
		if token_peek(parser, 1).kind == .Assign {
			name = parse_ident(parser) or_return
			token_expect(parser, .Assign) or_return
		}

		value := parse_expr(parser) or_return

		append(&fields, Ast_Field {
			name  = name,
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

parse_proc_signature :: proc(parser: ^Parser) -> (args, returns: []Ast_Field, diverging, ok: bool) {
	token_expect(parser, .Proc) or_return
	token_expect(parser, .Open_Paren)
	args = parse_field_list(parser, .Close_Paren, true, true) or_return

	parse_returns: if token_peek(parser).kind == .Arrow {
		token_advance(parser)

		if token_peek(parser).kind == .Not {
			token_advance(parser)
			diverging = true
			break parse_returns
		}

		if token_peek(parser).kind == .Open_Paren {
			token_advance(parser)
			returns = parse_field_list(parser, .Close_Paren, true, true) or_return
		} else {
			returns         = make([]Ast_Field, 1, parser.allocator)
			returns[0].name = blank_ident
			returns[0].type = parse_expr(parser, allow_compound_literals = false) or_return
		}
	}

	return args, returns, diverging, true
}

parse_stmt_list :: proc(
	parser:          ^Parser,
	terminator:       Token_Kind = .Close_Brace,
	extra_terminator: Token_Kind = nil,
) -> (_stmts: []^Ast_Stmt, ok: bool) {
	for token_peek(parser).kind == .Semicolon {
		token_advance(parser)
	}

	stmts := make([dynamic]^Ast_Stmt, parser.allocator)
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

@(require_results)
parse_operand :: proc(parser: ^Parser, allow_compound_literals: bool) -> (expr: ^Ast_Expr, ok: bool) {
	token := token_peek(parser)
	#partial switch token.kind {
	case .Ident:
		token_advance(parser)
		expr     := ast_new(Expr_Ident, token.location, parser.end_location, parser.allocator)
		expr.text = token.text
		return expr, true

	case .Dollar:
		token_advance(parser)
		ident := token_expect(parser, .Ident) or_return
		expr  := ast_new(Expr_Interface, token.location, parser.end_location, parser.allocator)
		expr.ident = ident
		return expr, true

	case .String_Literal, .Float_Literal, .Integer_Literal:
		token_advance(parser)
		return literal_to_expression(token, parser.allocator), true

	case .Open_Brace:
		token_advance(parser)
		fields := parse_arg_list(parser, .Close_Brace) or_return
		expr   := ast_new(Expr_Compound, token.location, parser.end_location, parser.allocator)
		expr.fields = fields
		return expr, true

	case .Proc:
		if token_peek(parser, 1).kind == .Open_Brace {
			token_expect(parser, .Proc)
			token_expect(parser, .Open_Brace)

			members := make([dynamic]^Ast_Expr, parser.allocator)
			for {
				if token_peek(parser).kind == .Close_Brace {
					break
				}

				append(&members, parse_expr(parser) or_break)
				token_expect(parser, .Comma) or_break
			}
			token_expect(parser, .Close_Brace)

			group        := ast_new(Expr_Proc_Group, token.location, parser.end_location, parser.allocator)
			group.members = members[:]
			return group, true
		}
		args, returns, diverging := parse_proc_signature(parser) or_return
		if token_peek(parser).kind == .Open_Brace {
			token_advance(parser)
			body := parse_stmt_list(parser) or_return
			token_advance(parser)

			lit          := ast_new(Expr_Proc_Lit, token.location, parser.end_location, parser.allocator)
			lit.args      = args
			lit.returns   = returns
			lit.body      = body
			lit.diverging = diverging
			return lit, true
		} else {
			sig          := ast_new(Expr_Proc_Sig, token.location, parser.end_location, parser.allocator)
			sig.args      = args
			sig.returns   = returns
			sig.diverging = diverging
			return sig, true
		}

	case .Struct:
		token_advance(parser)
		token_expect(parser, .Open_Brace) or_return
		fields := parse_field_list(parser, .Close_Brace, false) or_return
		s      := ast_new(Expr_Type_Struct, token.location, parser.end_location, parser.allocator)
		s.fields = fields
		return s, true

	case .Enum:
		token_advance(parser)
		backing: ^Ast_Expr
		if token_peek(parser).kind != .Open_Brace {
			backing = parse_expr(parser, allow_compound_literals = false) or_else nil
		}
		token_expect(parser, .Open_Brace) or_return
		values   := parse_field_list(parser, .Close_Brace, true, types = false) or_return
		s        := ast_new(Expr_Type_Enum, token.location, parser.end_location, parser.allocator)
		s.values  = values
		s.backing = backing
		return s, true

	case .Bit_Set:
		token_advance(parser)
		token_expect(parser, .Open_Bracket) or_return
		enum_type  := parse_expr(parser) or_return
		token_expect(parser, .Semicolon) or_return
		backing    := parse_expr(parser) or_return
		token_expect(parser, .Close_Bracket) or_return
		b          := ast_new(Expr_Type_Bit_Set, token.location, parser.end_location, parser.allocator)
		b.enum_type = enum_type
		b.backing   = backing
		return b, true

	case .Matrix:
		token_advance(parser)
		token_expect(parser, .Open_Bracket) or_return
		rows := parse_expr(parser) or_return
		cols: ^Ast_Expr
		if token_peek(parser).kind == .Comma {
			token_advance(parser)
			cols = parse_expr(parser) or_return
		}
		token_expect(parser, .Close_Bracket) or_return
		elem := parse_expr(parser, allow_compound_literals = false) or_return

		m := ast_new(Expr_Type_Matrix, token.location, parser.end_location, parser.allocator)
		m.rows = rows
		m.cols = cols
		m.elem = elem

		return m, true

	case .Open_Bracket:
		token_expect(parser, .Open_Bracket) or_return
		count: ^Ast_Expr
		physical: bool
		if token_peek(parser).kind == .Pointer {
			physical = true
			token_advance(parser)
		} else if token_peek(parser).kind != .Close_Bracket {
			count = parse_expr(parser) or_return
		}
		token_expect(parser, .Close_Bracket) or_return
		elem := parse_expr(parser, allow_compound_literals = false) or_return

		a := ast_new(Expr_Type_Array, token.location, parser.end_location, parser.allocator)
		a.count    = count
		a.elem     = elem
		a.physical = physical

		return a, true

	case .Sampler, .Image:
		token_advance(parser)
		token_expect(parser, .Open_Bracket) or_return
		dim := parse_expr(parser) or_return
		token_expect(parser, .Close_Bracket) or_return
		texel := parse_expr(parser, allow_compound_literals = false) or_return

		s := ast_new(Expr_Type_Image, token.location, parser.end_location, parser.allocator)
		s.dimensions = dim
		s.texel_type = texel
		s.is_sampler = token.kind == .Sampler
		return s, true

	case .Opaque:
		token_advance(parser)
		token_expect(parser, .Open_Paren) or_return
		ident := parse_ident(parser) or_return
		backing: ^Ast_Expr
		if token_peek(parser).kind == .Comma {
			token_advance(parser)
			backing = parse_expr(parser) or_return
		}
		token_expect(parser, .Close_Paren) or_return
		o        := ast_new(Expr_Type_Opaque, token.location, parser.end_location, parser.allocator)
		o.name    = ident
		o.backing = backing
		return o, true

	case .Distinct:
		token_advance(parser)
		type     := parse_expr(parser) or_return
		d        := ast_new(Expr_Type_Distinct, token.location, parser.end_location, parser.allocator)
		d.backing = type
		return d, true

	case .Open_Paren:
		token_advance(parser)
		expr := parse_expr(parser) or_return
		token_expect(parser, .Close_Paren) or_return
		paren := ast_new(Expr_Paren, token.location, parser.end_location, parser.allocator)
		paren.expr = expr
		return paren, true

	case .Directive:
		token_advance(parser)
		directive_token: Token
		if token_peek(parser).kind == .Import {
			directive_token = token_advance(parser)
		} else {
			directive_token = token_expect(parser, .Ident, "directive") or_return
		}

		directive: Directive
		for name, d in directive_names {
			if name == directive_token.text {
				directive = d
				break
			}
		}

		if directive != nil {
			token_expect(parser, .Open_Paren, "directive") or_return
			args       := parse_arg_list(parser, .Close_Paren) or_return
			d          := ast_new(Expr_Directive, token.location, parser.end_location, parser.allocator)
			d.token     = directive_token
			d.directive = directive

			c     := ast_new(Expr_Call, token.location, parser.end_location, parser.allocator)
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
			if image, ok := image.derived_expr.(^Expr_Type_Image); ok {
				image.format = format
			} else {
				error(parser, directive_token, "'#format' directive can only be applied to image types")
			}

			return image, true
		case:
			error(parser, directive_token, "unknown directive: '%s'", directive_token.text)
			return
		}
	case .Ellipsis:
		token_advance(parser)
		e            := parse_expr(parser, allow_compound_literals = allow_compound_literals) or_return
		ellipsis     := ast_new(Expr_Ellipsis, token.location, parser.end_location, parser.allocator)
		ellipsis.expr = e
		return ellipsis, true
	}

	error(parser, token, "unexpected token")
	return
}

@(require_results)
parse_unary_expr :: proc(parser: ^Parser, allow_compound_literals: bool) -> (expr: ^Ast_Expr, ok: bool) {
	token := token_peek(parser)
	#partial switch token.kind {
	case .Cast:
		token_advance(parser)
		token_expect(parser, .Open_Paren, "cast") or_return
		type := parse_expr(parser) or_return
		token_expect(parser, .Close_Paren) or_return
		value      := parse_unary_expr(parser, allow_compound_literals) or_return
		c          := ast_new(Expr_Cast, token.location, parser.end_location, parser.allocator)
		c.type_expr = type
		c.value     = value
		return c, true
	case .Add, .Subtract, .Not, .Xor:
		token_advance(parser)
		expr      := parse_unary_expr(parser, allow_compound_literals = allow_compound_literals) or_return
		unary     := ast_new(Expr_Unary, token.location, parser.end_location, parser.allocator)
		unary.expr = expr
		unary.op   = token.kind
		return unary, true
	case .Period:
		token_advance(parser)
		selector  := token_expect(parser, .Ident, "'.'") or_return
		ident     := ast_new(Expr_Ident, selector.location, parser.end_location, parser.allocator)
		ident.text = selector.text
		s         := ast_new(Expr_Selector, token.location, parser.end_location, parser.allocator)
		s.lhs      = nil
		s.selector = ident
		return s, true
	}

	return parse_atom_expr(parser, allow_compound_literals)
}

@(require_results)
parse_ident :: proc(parser: ^Parser) -> (ident: ^Expr_Ident, ok: bool) {
	start     := token_expect(parser, .Ident) or_return
	ident      = ast_new(Expr_Ident, start.location, parser.end_location, parser.allocator)
	ident.text = start.text
	ok         = true
	return
}

@(require_results)
parse_atom_expr :: proc(parser: ^Parser, allow_compound_literals: bool) -> (expr: ^Ast_Expr, ok: bool) {
	operand := parse_operand(parser, allow_compound_literals) or_return

	loop: for {
		token := token_peek(parser)
		#partial switch token.kind {
		case .Open_Paren:
			token_advance(parser)
			args     := parse_arg_list(parser, .Close_Paren) or_return
			call     := ast_new(Expr_Call, operand.start, parser.end_location, parser.allocator)
			call.lhs  = operand
			call.args = args
			operand   = call
		case .Open_Bracket:
			token_advance(parser)
			rhs := parse_expr(parser) or_return
			token_expect(parser, .Close_Bracket) or_return
			index    := ast_new(Expr_Index, operand.start, parser.end_location, parser.allocator)
			index.lhs = operand
			index.rhs = rhs
			operand   = index
		case .Period:
			token_advance(parser)
			rhs              := parse_ident(parser) or_return
			selector         := ast_new(Expr_Selector, operand.start, parser.end_location, parser.allocator)
			selector.lhs      = operand
			selector.selector = rhs
			operand           = selector
		case .Open_Brace:
			if !allow_compound_literals {
				break loop
			}
			token_advance(parser)
			values        := parse_arg_list(parser, .Close_Brace) or_return
			comp          := ast_new(Expr_Compound, token.location, parser.end_location, parser.allocator)
			comp.fields    = values
			comp.type_expr = operand
			operand        = comp
		case:
			break loop
		}
	}

	return operand, true
}

@(rodata)
binding_powers: #sparse [Token_Kind]int = #partial {
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

@(require_results)
parse_expr :: proc(parser: ^Parser, min_power := 0, allow_compound_literals := true) -> (expr: ^Ast_Expr, ok: bool) {
	lhs := parse_unary_expr(parser, allow_compound_literals) or_return
	for {
		op := token_peek(parser)

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
			t          := ast_new(Expr_Ternary, lhs.start, parser.end_location, parser.allocator)
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
			t          := ast_new(Expr_Ternary, lhs.start, parser.end_location, parser.allocator)
			t.cond      = cond
			t.then_expr = lhs
			t.else_expr = else_expr
			lhs         = t
			continue
		}

		token_advance(parser)
		rhs := parse_expr(parser, power, allow_compound_literals) or_return
		e   := ast_new(Expr_Binary, lhs.start, parser.end_location, parser.allocator)

		e.op  = op.kind
		e.lhs = lhs
		e.rhs = rhs

		lhs  = e
	}
	return lhs, true
}

parse_expr_list :: proc(parser: ^Parser, allow_compound_literals := true) -> (exprs: []^Ast_Expr, ok: bool) {
	es := make([dynamic]^Ast_Expr, parser.allocator)
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

@(require_results)
parse_simple_stmt :: proc(parser: ^Parser, attributes: []Ast_Field = {}, allow_compound_literals := true) -> (stmt: ^Ast_Stmt, ok: bool) {
	token := token_peek(parser)
	#partial switch token.kind {
	case .String_Literal, .Float_Literal, .Integer_Literal:
		expr   := parse_expr(parser, allow_compound_literals = allow_compound_literals) or_return
		se     := ast_new(Stmt_Expr, token.location, parser.end_location, parser.allocator)
		se.expr = expr
		return se, true
	case .Ident, .Cast, .Open_Paren, .Dollar, .Directive:
		lhs := parse_expr_list(parser, allow_compound_literals) or_return
		#partial switch t := token_peek(parser); t.kind {
		case .Assign:
			assign_token := token_advance(parser)
			rhs          := parse_expr_list(parser, allow_compound_literals) or_return
			if len(rhs) == 0 {
				error(parser, token, "Expected at least one value in assignment")
			}
			assign       := ast_new(Stmt_Assign, token.location, parser.end_location, parser.allocator)
			assign.lhs    = lhs
			assign.rhs    = rhs
			assign.op     = assign_token.assign_op
			return assign, true
		case .Colon:
			for l in lhs {
				if _, ok := l.derived_expr.(^Expr_Ident); !ok {
					error(parser, l.start, l.end, "Expected identifier in left hand side of declaration")
				}
			}
			idents := ([^]^Expr_Ident)(&lhs[0])[:len(lhs)]
			token_advance(parser)
			if token_peek(parser).kind == .Assign || token_peek(parser).kind == .Colon {
				mutable        := token_advance(parser).kind == .Assign
				values         := parse_expr_list(parser) or_return
				if len(values) == 0 {
					error(parser, token, "Expected at least one value in declaration")
				}
				decl           := ast_new(Decl_Value, token.location, parser.end_location, parser.allocator)
				decl.lhs        = idents
				decl.values     = values
				decl.mutable    = mutable
				decl.attributes = attributes
				return decl, true
			} else {
				type := parse_expr(parser) or_return
				if token_peek(parser).kind == .Assign || token_peek(parser).kind == .Colon {
					mutable       := token_advance(parser).kind == .Assign
					values        := parse_expr_list(parser) or_return
					if len(values) == 0 {
						error(parser, token, "Expected at least one value in declaration")
					}
					decl          := ast_new(Decl_Value, token.location, parser.end_location, parser.allocator)
					decl.lhs        = idents
					decl.values     = values
					decl.mutable    = mutable
					decl.type_expr  = type
					decl.attributes = attributes
					return decl, true
				} else {
					decl           := ast_new(Decl_Value, token.location, parser.end_location, parser.allocator)
					decl.lhs        = idents
					decl.mutable    = true
					decl.type_expr  = type
					decl.attributes = attributes
					return decl, true
				}
			}
		case:
			if len(lhs) == 1 {
				se := ast_new(Stmt_Expr, token.location, parser.end_location, parser.allocator)
				se.expr = lhs[0]
				return se, true
			}
		}
	case .Return:
		token_advance(parser)
		values := make([dynamic]^Ast_Expr, parser.allocator)
		for token_peek(parser).kind != .Semicolon {
			if len(values) != 0 {
				token_expect(parser, .Comma)
			}
			value := parse_expr(parser, allow_compound_literals = allow_compound_literals) or_return
			append(&values, value)
		}
		ret := ast_new(Stmt_Return, token.location, parser.end_location, parser.allocator)
		ret.values = values[:]

		return ret, true
	case .Continue:
		token_advance(parser)
		label: ^Expr_Ident
		if token_peek(parser).kind == .Ident {
			label = parse_ident(parser) or_return
		}
		cont := ast_new(Stmt_Continue, token.location, parser.end_location, parser.allocator)
		cont.label = label

		return cont, true
	case .Break:
		token_advance(parser)
		label: ^Expr_Ident
		if token_peek(parser).kind == .Ident {
			label = parse_ident(parser) or_return
		}
		brk := ast_new(Stmt_Break, token.location, parser.end_location, parser.allocator)
		brk.label = label

		return brk, true
	}

	error(parser, token, "unexpected token")
	return
}

parse_attributes :: proc(parser: ^Parser) -> (_attributes: []Ast_Field, ok: bool) {
	token_expect(parser, .Attribute)
	attributes := make([dynamic]Ast_Field, parser.allocator)

	parse_attr_list :: proc(parser: ^Parser, attributes: ^[dynamic]Ast_Field) -> bool {
		loop: for {
			#partial switch token_peek(parser).kind {
			case .Close_Paren, .EOF:
				break loop
			}

			name := parse_ident(parser) or_return

			library: ^Ast_Expr
			if token_peek(parser).kind == .Period {
				token_advance(parser)
				library = name
				name    = parse_ident(parser) or_return
			}

			value: ^Ast_Expr
			if token_peek(parser).kind == .Assign {
				token_advance(parser)
				value = parse_expr(parser) or_return
			}

			append(attributes, Ast_Field {
				name     = name,
				value    = value,
				location = library,
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
		append(&attributes, Ast_Field {
			name = parse_ident(parser) or_return,
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

@(require_results)
literal_to_expression :: proc(token: Token, allocator: runtime.Allocator) -> ^Expr_Constant {
	end_location        := token.location
	end_location.column += i32(len(token.text))
	end_location.offset += i32(len(token.text))

	text := token.text
	if token.imaginary != nil {
		text = text[:len(text) - 1]
	}

	expr          := ast_new(Expr_Constant, token.location, end_location, allocator)
	expr.imaginary = token.imaginary

	#partial switch token.kind {
	case .String_Literal:
		expr.value = token.text[1:len(token.text) - 1]
	case .Float_Literal:
		expr.value = strconv.parse_f64(text) or_else panic("Failed to parse float literal (this should not happen)")
	case .Integer_Literal:
		expr.value = strconv.parse_i64(text) or_else panic("Failed to parse integer literal (this should not happen)")
	case:
		panic("not a literal")
	}
	return expr
}

parse_stmt :: proc(parser: ^Parser, label: ^Expr_Ident = nil, attributes: []Ast_Field = {}) -> (stmt: ^Ast_Stmt, ok: bool) {
	token := token_peek(parser)
	#partial switch token.kind {
	case .Attribute:
		if len(attributes) != 0 {
			error(parser, token, "only one set of attributes can be applied to a statement")
		}
		return parse_stmt(parser, label, parse_attributes(parser) or_return)
	case .Return, .Continue, .Break, .String_Literal, .Open_Paren, .Cast, .Dollar, .Directive:
		return parse_simple_stmt(parser, attributes)
	case .Import:
		token_advance(parser)
		alias: ^Expr_Ident
		if token_peek(parser).kind == .Ident {
			alias = parse_ident(parser) or_return
		}

		string_literal   := token_expect(parser, .String_Literal, "import") or_return
		import_decl      := ast_new(Decl_Import, token.location, parser.end_location, parser.allocator)
		import_decl.path  = literal_to_expression(string_literal, parser.allocator)
		import_decl.alias = alias
		return import_decl, true
	case .Extension:
		token_advance(parser)
		extension := parse_expr(parser, allow_compound_literals = false) or_return
		token_expect(parser, .Open_Brace) or_return
		body          := parse_stmt_list(parser) or_return
		token_advance(parser)
		decl          := ast_new(Decl_Extension, token.location, parser.end_location, parser.allocator)
		decl.extension = extension
		decl.body      = body
		return decl, true
	case .Ident:
		if token_peek(parser, 1).kind == .Colon {
			#partial switch token_peek(parser, 2).kind {
			case .For, .If, .Switch, .Open_Brace:
				token_advance(parser)
				label     := ast_new(Expr_Ident, token.location, parser.end_location, parser.allocator)
				label.text = token.text
				token_advance(parser)
				return parse_stmt(parser, label)
			}
		}
		return parse_simple_stmt(parser, attributes)
	case .For:
		token_advance(parser)
		init: ^Ast_Stmt
		cond: ^Ast_Expr
		post: ^Ast_Stmt

		parse_header: if token_peek(parser).kind != .Open_Brace {
			if token_peek(parser).kind == .Semicolon {
				token_advance(parser)
			} else {
				s := parse_simple_stmt(parser, allow_compound_literals = false) or_return
				if expr_stmt, ok := s.derived.(^Stmt_Expr); ok {
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

						ident, ok := expr_stmt.expr.derived_expr.(^Expr_Ident)
						if !ok {
							error(parser, ident.start, ident.end, "expected an identifier as iteration variable in `for x in ...` style loop")
						}

						start_location := token.location
						if label != nil {
							start_location = label.start
						}

						range_stmt           := ast_new(Stmt_For_Range, start_location, parser.end_location, parser.allocator)
						range_stmt.variable   = ident
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
				cond = parse_expr(parser, allow_compound_literals = false) or_return
			}
			token_expect(parser, .Semicolon) or_return

			if token_peek(parser).kind != .Open_Brace {
				post = parse_simple_stmt(parser, allow_compound_literals = false) or_return
			}
		}

		token_expect(parser, .Open_Brace) or_return

		body := parse_stmt_list(parser) or_return
		token_advance(parser)

		start_location := token.location
		if label != nil {
			start_location = label.start
		}

		for_stmt := ast_new(Stmt_For, start_location, parser.end_location, parser.allocator)
		for_stmt.label = label
		for_stmt.init  = init
		for_stmt.cond  = cond
		for_stmt.post  = post
		for_stmt.body  = body
		return for_stmt, true
	case .If:
		token_advance(parser)
		init: ^Ast_Stmt
		cond: ^Ast_Expr
		parse_if_header: {
			s := parse_simple_stmt(parser, allow_compound_literals = false) or_return
			if expr_stmt, ok := s.derived.(^Stmt_Expr); ok {
				cond = expr_stmt.expr
				break parse_if_header
			}
			init = s
			token_expect(parser, .Semicolon) or_return
			cond = parse_expr(parser, allow_compound_literals = false) or_return
		}

		token_expect(parser, .Open_Brace) or_return
		then_block := parse_stmt_list(parser) or_return
		token_expect(parser, .Close_Brace) or_return
		else_block: []^Ast_Stmt
		if token_peek(parser).kind == .Else {
			token_advance(parser)

			if token_peek(parser).kind == .If {
				else_if      := parse_stmt(parser) or_return
				else_block    = make([]^Ast_Stmt, 1, parser.allocator)
				else_block[0] = else_if
			} else {
				token_expect(parser, .Open_Brace) or_return
				else_block = parse_stmt_list(parser) or_return
				token_expect(parser, .Close_Brace)
			}
		}

		start_location := token.location
		if label != nil {
			start_location = label.start
		}

		if_stmt := ast_new(Stmt_If, start_location, parser.end_location, parser.allocator)
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
		else_block: []^Ast_Stmt
		if token_peek(parser).kind == .Else {
			token_advance(parser)
			token_expect(parser, .Open_Brace) or_return
			else_block = parse_stmt_list(parser) or_return
			token_expect(parser, .Close_Brace)
		}

		when_stmt := ast_new(Stmt_When, token.location, parser.end_location, parser.allocator)
		when_stmt.label      = label
		when_stmt.cond       = cond
		when_stmt.then_block = then_block
		when_stmt.else_block = else_block
		return when_stmt, true
	case .Switch:
		token_advance(parser)
		init: ^Ast_Stmt
		cond: ^Ast_Expr
		parse_switch_header: {
			s := parse_simple_stmt(parser, allow_compound_literals = false) or_return
			if expr_stmt, ok := s.derived.(^Stmt_Expr); ok {
				cond = expr_stmt.expr
				break parse_switch_header
			}
			init = s
			token_expect(parser, .Semicolon) or_return
			cond = parse_expr(parser, allow_compound_literals = false) or_return
		}

		token_expect(parser, .Open_Brace) or_return

		cases := make([dynamic]Switch_Case, parser.allocator)
		for token_peek(parser).kind != .Close_Brace && token_peek(parser).kind != .EOF {
			token_expect(parser, .Case) or_continue
			value: ^Ast_Expr
			if token_peek(parser).kind != .Colon {
				value = parse_expr(parser) or_continue
			}
			token_expect(parser, .Colon)
			append(&cases, Switch_Case {
				value = value,
				body  = parse_stmt_list(parser, .Close_Brace, .Case) or_continue,
			})
		}
		token_expect(parser, .Close_Brace)

		start_location := token.location
		if label != nil {
			start_location = label.start
		}

		s := ast_new(Stmt_Switch, start_location, parser.end_location, parser.allocator)
		s.label = label
		s.init  = init
		s.cond  = cond
		s.cases = cases[:]

		return s, true

	case .Open_Brace:
		token_advance(parser)
		stmts := parse_stmt_list(parser) or_return
		token_advance(parser)

		start_location := token.location
		if label != nil {
			start_location = label.start
		}

		block := ast_new(Stmt_Block, start_location, parser.end_location, parser.allocator)
		block.label = label
		block.body  = stmts
		return block, true
	}

	error(parser, token, "unexpected token")
	return
}

parse :: proc(
	tokens: []Token,
	allocator       := context.allocator,
	error_allocator := context.allocator,
) -> ([]^Ast_Stmt, []Error) {
	parser: Parser = {
		allocator       = allocator,
		error_allocator = error_allocator,
		errors          = make([dynamic]Error, error_allocator),
		tokens          = tokens,
	}

	for token_peek(&parser).kind == .Semicolon {
		token_advance(&parser)
	}

	global_stmts, _ := parse_stmt_list(&parser, .EOF)

	return global_stmts, parser.errors[:]
}
