" Detect engine7 source files: *.tri (canonical), with *.e7 and *.engine7
" accepted as aliases.
"
" Neovim's filetype detection would otherwise classify unknown extensions as
" the generic "conf" fallback, so register the extensions before that fallback
" runs.  The plain autocmd keeps this file useful for legacy Vim.

if has("nvim")
  lua vim.filetype.add({ extension = { tri = "engine7", e7 = "engine7", engine7 = "engine7" } })
else
  augroup engine7_ftdetect
    autocmd!
    autocmd BufRead,BufNewFile *.tri,*.e7,*.engine7 setfiletype engine7
  augroup END
endif
