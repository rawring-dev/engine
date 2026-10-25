" engine7 filetype settings.
"
" The lexer rejects tabs in indentation, so expandtab matters.  Line comments
" start with '#'; the suffixes make ':find'/'gf' work on engine7 modules.

if exists("b:did_ftplugin")
  finish
endif
let b:did_ftplugin = 1

setlocal commentstring=#\ %s
setlocal comments=:#
setlocal expandtab
setlocal shiftwidth=4
setlocal tabstop=4
setlocal softtabstop=4
setlocal suffixesadd=.tri,.e7

let b:undo_ftplugin = "setlocal commentstring< comments< expandtab< shiftwidth< tabstop< softtabstop< suffixesadd<"
