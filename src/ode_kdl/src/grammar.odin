/*
    Ported to Odin from ckdl (https://github.com/tjol/ckdl)
    Original C implementation Copyright (c) Thomas Jollans (MIT License)

    Character classification for the KDL v2 grammar. Ported from ckdl's
    src/grammar.h / tokenizer.c character-class functions, v2-only (no
    kdl_character_set parameter — this port doesn't support KDL v1).
*/
package kdl

///////////////////////////////////////////////////////////////////////////////
// Grammar

    @(private)
    is_whitespace :: proc(c: rune) -> bool {
        switch c {
        case 0x0009, // Character Tabulation
             0x0020, // Space
             0x00A0, // No-Break Space
             0x1680, // Ogham Space Mark
             0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
             0x202F, // Narrow No-Break Space
             0x205F, // Medium Mathematical Space
             0x3000, // Ideographic Space
             0x000B: // Vertical Tab (v2)
            return true
        }
        return false
    }

    @(private)
    is_newline :: proc(c: rune) -> bool {
        switch c {
        case 0x000D, // CR
             0x000A, // LF
             0x0085, // NEL
             0x000C, // FF
             0x2028, // LS
             0x2029: // PS
            return true
        }
        return false
    }

    @(private)
    is_illegal_char :: proc(c: rune) -> bool {
        return c <= 0x0008 || // control characters
            (0x000E <= c && c <= 0x001F) ||
            c == 0x007F || // delete
            (0xD800 <= c && c <= 0xDFFF) || // UTF-16 surrogates
            c == 0x200E || c == 0x200F || // directional control characters
            (0x202A <= c && c <= 0x202E) ||
            (0x2066 <= c && c <= 0x2069) ||
            c == 0xFEFF || // ZWNBSP = BOM
            c > 0x10FFFF // not a codepoint
    }

    @(private)
    is_word_char :: proc(c: rune) -> bool {
        return c > 0x20 && c <= 0x10FFFF && c != '\\' && c != '/' && c != '(' && c != ')' && c != '{' &&
            c != '}' && c != ';' && c != '[' && c != ']' && c != '"' && c != '=' &&
            !is_whitespace(c) && !is_newline(c) && !is_illegal_char(c)
    }

    @(private)
    is_id :: proc(c: rune) -> bool {
        return is_word_char(c) && c != '#'
    }

    @(private)
    is_word_start :: proc(c: rune) -> bool {
        return is_id(c) && (c < '0' || c > '9')
    }

    @(private)
    is_id_start :: proc(c: rune) -> bool {
        return is_word_start(c)
    }

    @(private)
    is_end_of_word :: proc(c: rune) -> bool {
        return is_whitespace(c) || is_newline(c) || c == ';' || c == ')' || c == '}' || c == '/' ||
            c == '\\' || c == '='
    }
