" Repository-local embedded Neovim; no changes to the user's configuration.
set runtimepath^=editors/neovim
filetype plugin indent on
syntax enable
set termguicolors number hidden noswapfile nobackup nowritebackup
set background=dark
colorscheme habamax
set mouse= clipboard= splitbelow splitright
set noshowmode laststatus=2
set guicursor=
set title
" Avoid terminal protocol negotiation that the embedded terminal does not use.
set notitle

" Notify the host only after a successful source write, including :wall.
augroup engine7_embedded
    autocmd!
    autocmd BufWritePost *.e7,*.tri,*.engine7 call writefile([reltimestr(reltime())], $E7_EDITOR_SAVE_FILE)
augroup END
