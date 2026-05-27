package hephaistos

import "core:fmt"

error_parser_start_end :: proc(parser: ^Parser, start, end: Location, format: string, args: ..any) {
	append(&parser.errors, Error {
		location = start,
		end      = end,
		message  = fmt.aprintf(format, ..args, allocator = parser.error_allocator),
	})
}

error_parser_single_token :: proc(parser: ^Parser, token: Token, format: string, args: ..any) {
	append(&parser.errors, Error {
		location = token.location,
		end      = {
			line   = token.location.line,
			column = token.location.column + i32(len(token.text)),
			offset = token.location.offset + i32(len(token.text)),
		},
		message  = fmt.aprintf(format, ..args, allocator = parser.error_allocator),
	})
}


error_checker_operand :: proc(checker: ^Checker, operand: Operand, message: string, args: ..any) {
	append(&checker.errors, Error {
		location = operand.expr.start,
		end     = operand.expr.end,
		message = fmt.aprintf(message, ..args, allocator = checker.error_allocator),
	})
}

error_checker_location :: proc(checker: ^Checker, location: Location, message: string, args: ..any) {
	append(&checker.errors, Error {
		location = location,
		end      = location,
		message  = fmt.aprintf(message, ..args, allocator = checker.error_allocator),
	})
}

error_checker_start_end :: proc(checker: ^Checker, start, end: Location, message: string, args: ..any) {
	append(&checker.errors, Error {
		location = start,
		end      = end,
		message  = fmt.aprintf(message, ..args, allocator = checker.error_allocator),
	})
}

error_checker_token :: proc(checker: ^Checker, token: Token, message: string, args: ..any) {
	end        := token.location
	end.offset += i32(len(token.text))
	end.column += i32(len(token.text))
	append(&checker.errors, Error {
		location = token.location,
		end      = end,
		message  = fmt.aprintf(message, ..args, allocator = checker.error_allocator),
	})
}

error_checker_ast_node :: proc(checker: ^Checker, ast_node: ^Ast_Node, message: string, args: ..any) {
	append(&checker.errors, Error {
		location = ast_node.start,
		end      = ast_node.end,
		message  = fmt.aprintf(message, ..args, allocator = checker.error_allocator),
	})
}

error :: proc {
	error_parser_start_end,
	error_parser_single_token,

	error_checker_operand,
	error_checker_location,
	error_checker_token,
	error_checker_ast_node,
	error_checker_start_end,
}

