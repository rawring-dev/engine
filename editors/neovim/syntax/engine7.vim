" Vim syntax file
" Language:    engine7
" Maintainer:  engine7 contributors
" Description: Legacy :syntax highlighting for the engine7 surface language.
"
" This is a regex-based highlighter, not a parser: there is no tree-sitter
" grammar for engine7.  The keyword classes and the small set of heuristics
" implemented here mirror the shared model in editors/README.md so that the
" Neovim and VS Code plugins highlight programs the same way.
"
" Group names are e7*-prefixed and linked to the conventional Vim groups at
" the end of the file; colorschemes own the actual colors.

if exists("b:current_syntax")
  finish
endif

let s:cpo_save = &cpo
set cpo&vim

" engine7 keywords are all lowercase and identifiers are case sensitive.
syn case match
" The layout-sensitive (indentation) form means a line's highlighting can
" depend on earlier lines; files are small, so always scan from the start.
syn sync fromstart


" ---------------------------------------------------------------------------
" Comments: '#' to end of line.  There are no block or doc comments.
" ---------------------------------------------------------------------------
syn match e7Comment /#.*$/


" ---------------------------------------------------------------------------
" Strings: both "..." and '...' are accepted by the lexer; a backslash
" escapes the next byte.  The regions contain only the escape item, so
" comments and keywords never leak into a string.
" ---------------------------------------------------------------------------
syn region e7String start=/"/ skip=/\\./ end=/"/ contains=e7Escape
syn region e7String start=/'/ skip=/\\./ end=/'/ contains=e7Escape
syn match e7Escape /\\./ contained


" ---------------------------------------------------------------------------
" Numbers.  Integers are digits with optional '_' separators; floats are
" digits '.' digits with an optional exponent.  The float item is defined
" after the integer item so that, at a shared start, the float wins.
" Collections use [0-9] rather than \d: inside [] Vim treats \d as a literal
" character, which would silently break the integer item.
" ---------------------------------------------------------------------------
syn match e7Number /\<[0-9][0-9_]*\>/
syn match e7Number /\<[0-9][0-9_]*\.[0-9][0-9_]*\%([eE][+-]\?[0-9][0-9_]*\)\?/


" ---------------------------------------------------------------------------
" Literals and keyword classes (exactly the reserved words of the lexer).
" ---------------------------------------------------------------------------
syn keyword e7Boolean true false
syn keyword e7Constant nil

syn keyword e7Conditional if elif else match
syn keyword e7Repeat loop while for in
syn keyword e7Statement ret break cont disown
syn keyword e7Include use mod
syn keyword e7Structure struct enum table trigger sys plugin
syn keyword e7Storage pub
syn keyword e7Keyword impl trait async await spawn detach cancel unsafe
syn keyword e7Keyword select from where res
syn keyword e7Keyword as not and or xor
syn keyword e7Keyword crate self super mut raw


" ---------------------------------------------------------------------------
" Types.
"   - Uppercase identifiers are types by convention (type paths, enum
"     variants, generic parameters, aggregate names).
"   - A lowercase name before optional generics and
"     '<- struct|enum|table|trigger|sys|plugin' is an aggregate declaration name.
"   - A name after 'trait' is a type.
"   - Contextual 'map' immediately before '[' is a type.
" A look-behind is used after 'trait' because a keyword item wins over a
" match that starts at the same position, so a '\zs' alone would lose.
" ---------------------------------------------------------------------------
syn match e7Type /\<[A-Z][A-Za-z0-9_]*\>/
syn match e7Type /\<map\ze[ \t]*\[/
syn match e7Type /\%(\<trait[ \t]\+\)\@<=[A-Za-z_][A-Za-z0-9_]*/
syn match e7Type /\<[a-z][A-Za-z0-9_]*\ze\%(<[^>\n]*>\)\?[ \t]*<-[ \t]*\%(struct\|enum\|table\|trigger\|sys\|plugin\)\>/


" ---------------------------------------------------------------------------
" Functions.
"   - Declaration names: name, optional generics, '<-', optional 'async',
"     then '('.
"   - Call names: a lowercase name directly before '('.  Keywords followed
"     by '(' (for example 'if(') are handled by the keyword items, which
"     have priority over matches; field accesses after '.' are handled by
"     the e7Field item below, which is defined later and therefore wins.
" ---------------------------------------------------------------------------
syn match e7Function /\<[a-z][A-Za-z0-9_]*\ze\%(<[^>\n]*>\)\?[ \t]*<-[ \t]*\%(async[ \t]*\)\?(/
syn match e7Function /\<[a-z_][A-Za-z0-9_]*\ze(/


" ---------------------------------------------------------------------------
" Fields and members.
"   - An identifier after '.' is a field (but not the second dot of a
"     '..' / '...' range).
"   - A lowercase identifier directly before a single ':' (not '::' and
"     not ':=') is a member: struct field, field initializer, pattern
"     binding, or parameter.
" ---------------------------------------------------------------------------
syn match e7Field /\.\@<=\%(\.\.\)\@<![A-Za-z_][A-Za-z0-9_]*/
syn match e7Field /\<[a-z][A-Za-z0-9_]*\ze:\%([:=]\)\@!/


" ---------------------------------------------------------------------------
" Built-in primitive scalar types.  They are not reserved words, but the
" shared model treats them as types ("String" is already covered by the
" uppercase rule).
"
" This item is defined *after* the e7Field member item on purpose: when two
" match items start at the same byte, the item defined last wins, so a
" primitive return type such as '-> i32:' is a type instead of a member.
" Non-primitive lowercase names before ':' still fall through to e7Field.
" The word boundaries keep identifiers such as 'xi32' and 'i32x' out.
" ---------------------------------------------------------------------------
syn match e7Type /\<\%(i8\|i16\|i32\|i64\|i128\|isize\|u8\|u16\|u32\|u64\|u128\|usize\|f16\|f32\|f64\|f128\|bool\|str\)\>/


" ---------------------------------------------------------------------------
" Attributes: '@' plus a '::'-separated path.
" ---------------------------------------------------------------------------
syn match e7Attribute /@[A-Za-z_][A-Za-z0-9_]*\%(::[A-Za-z_][A-Za-z0-9_]*\)*/


" ---------------------------------------------------------------------------
" Delimiters and operators.
"
" Vim gives priority to the syntax item defined last when several match
" start at the same position, so single-character items come first and the
" longer forms ('<-', ':=' , '::', '..', '..=', '...') come afterwards.
" That keeps '.' a delimiter while '..' / '..=' / '...' are operators.
" ---------------------------------------------------------------------------
syn match e7Delimiter /[()[\]{},;:.]/

syn match e7Operator /[+\-*\/%&|?!=<>]/
syn match e7Operator /<-/
syn match e7Operator /->/
syn match e7Operator /:=/
syn match e7Operator /==/
syn match e7Operator /!=/
syn match e7Operator /<=/
syn match e7Operator />=/
syn match e7Operator /+=/
syn match e7Operator /-=/
syn match e7Operator /\*=/
syn match e7Operator /\/=/
syn match e7Operator /%=/

syn match e7Delimiter /::/
syn match e7Operator /\.\./
syn match e7Operator /\.\.=/
syn match e7Operator /\.\.\./


" ---------------------------------------------------------------------------
" Colorscheme links (never hardcode colors).
" ---------------------------------------------------------------------------
hi def link e7Comment   Comment
hi def link e7String    String
hi def link e7Escape    SpecialChar
hi def link e7Number    Number
hi def link e7Boolean   Boolean
hi def link e7Constant  Constant
hi def link e7Conditional Conditional
hi def link e7Repeat    Repeat
hi def link e7Statement Statement
hi def link e7Include   Include
hi def link e7Structure Structure
hi def link e7Keyword   Keyword
hi def link e7Storage   StorageClass
hi def link e7Type      Type
hi def link e7Function  Function
hi def link e7Field     Identifier
hi def link e7Attribute PreProc
hi def link e7Operator  Operator
hi def link e7Delimiter Delimiter

let b:current_syntax = "engine7"

let &cpo = s:cpo_save
unlet s:cpo_save
