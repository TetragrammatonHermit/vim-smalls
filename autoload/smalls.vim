let s:plog            = smalls#util#import("plog")
let s:getchar         = smalls#util#import("getchar")
let s:getchar_timeout = smalls#util#import("getchar_timeout")

" Util:
function! s:msg(msg) "{{{1
  redraw
  call s:echohl('Smalls ', 'Type')
  call s:echohl(a:msg, 'Normal')
endfunction

function! s:echohl(msg, color) "{{{1
  silent execute 'echohl ' . a:color
  echon a:msg
  echohl Normal
endfunction

function! s:preserve_env(mode) "{{{1
  " to get precise start point in visual mode.
  if (a:mode  =~# "v\\|V\\|\<C-v>" ) | exe "normal! gvo\<Esc>" | endif
  let [ l, c ] = [ line('.'), col('.') ]
  " for neatly revert original visual start/end pos
  if (a:mode  =~# "v\\|V\\|\<C-v>" ) | exe "normal! gvo\<Esc>" | endif
  return {
        \ 'mode': a:mode,
        \ 'w0': line('w0'),
        \ 'w$': line('w$'),
        \ 'l': l,
        \ 'c': c,
        \ 'p': smalls#pos#new([ l, c ]),
        \ }
endfunction


function! s:options_set(options) "{{{1
  let R = {}
  let curbuf = bufname('')
  for [var, val] in items(a:options)
    let R[var] = getbufvar(curbuf, var)
    call setbufvar(curbuf, var, val)
    unlet var val
  endfor
  return R
endfunction

function! s:options_restore(options) "{{{1
  for [var, val] in items(a:options)
    call setbufvar(bufname(''), var, val)
    unlet var val
  endfor
endfunction

function! s:hl_restorecmd(hlname) "{{{1
  redir => HL_SAVE
  execute 'silent! highlight ' . a:hlname
  redir END
  return 'highlight ' . a:hlname . ' ' .
        \  substitute(matchstr(HL_SAVE, 'xxx \zs.*'), "\n", ' ', 'g')
endfunction

function! s:hide_cursor()
  highlight Cursor ctermfg=NONE ctermbg=NONE guifg=NONE guibg=NONE
endfunction
"}}}

let s:vim_options = {
      \ '&scrolloff':  0,
      \ '&modified':   0,
      \ '&cursorline': 0,
      \ '&modifiable': 1,
      \ '&readonly':   0,
      \ '&spell':      0,
      \ }
" Main:
let s:smalls = {}

function! s:smalls.init(mode) "{{{1
  let self.lastmsg      = ''
  let self._notfound    = 0
  let self._auto_set    = 0
  let self.env          = s:preserve_env(a:mode)
  let self.hl           = smalls#highlighter#new(self.env)
  let self.finder       = smalls#finder#new(self.env)
  let self.keyboard_cli = smalls#keyboard#cli#new(self)
  let self._break       = 0
endfunction

function! s:smalls.finish() "{{{1

  if ( self._notfound && g:smalls_blink_on_notfound ) ||
        \ ( self._auto_set && g:smalls_auto_set_blink )
    call self.hl.blink_cursor()
  endif

  if self._notfound && self._is_visual()
    normal! gv
  endif
  redraw

  if !empty(self.lastmsg)
    call s:msg(self.lastmsg)
  endif

  call self.update_status('')
endfunction

function! s:smalls.loop() "{{{1
  call self.update_status('cli')
  let kbd = self.keyboard_cli

  while 1
    call self.hl.shade()
    call self.hl.cursor()

    let timeout = 
          \ ( g:smalls_auto_jump &&
          \ ( kbd.data_len() >= g:smalls_auto_jump_min_input_length ))
          \ ? g:smalls_auto_jump_timeout : -1
    try
      call kbd.read_input(timeout)
    catch /KEYBOARD_TIMEOUT/
      call self.do_jump(kbd)
    endtry

    if self.auto_excursion &&
          \ kbd.data_len() >=# g:smalls_auto_excursion_min_input_length
      call self.do_excursion(kbd)
    endif
    call self.hl.clear()

    if kbd.data_len() ==# 0
      continue
    endif
    if self._break
      break
    endif

    let auto_set_need = g:smalls_auto_set &&
          \ kbd.data_len() >=# g:smalls_auto_set_min_input_length
    let found = auto_set_need
          \ ? self.finder.all(kbd.data) : self.finder.one(kbd.data)

    if len(found) ==# 1 && auto_set_need
      let self._auto_set = 1
      call kbd.do_jump_first()
      break
    endif
    if empty(found)
      throw 'NotFound'
    endif
    call self.hl.candidate(kbd.data, ( auto_set_need ? found[0] : found ))
  endwhile
endfunction

function! s:smalls.start(mode, ...)  "{{{1
  try
    let self.auto_excursion = a:0 ? 1 : 0
    let options_saved = s:options_set(s:vim_options)
    let hl_cursor_cmd = s:hl_restorecmd('Cursor')

    call self.init(a:mode)
    call s:hide_cursor()
    call self.loop()
  catch
    if v:exception ==# "NotFound"
      let self._notfound = 1
    elseif v:exception ==# "Canceled"
      if self._is_visual()
        normal! gv
      endif
    endif
    let self.lastmsg = v:exception
  finally
    call self.hl.clear()
    call s:options_restore(options_saved)
    execute hl_cursor_cmd
    call self.finish()
  endtry
endfunction

function! s:smalls.do_jump(kbd) "{{{1
  call self.hl.clear()
  call self.hl.shade()

  let pos_new = self.get_jump_target(a:kbd.data)
  if !empty(pos_new)
    call self._jump_to_pos(pos_new)
  endif
  let self._break = 1
endfunction

function! s:smalls.do_jump_first(kbd) "{{{1
  let found = self.finder.one(a:kbd.data)
  if !empty(found)
    let pos_new = smalls#pos#new(found)
    call self._jump_to_pos(pos_new)
  endif
  let self._break = 1
endfunction

function! s:smalls._jump_to_pos(pos) "{{{1
  call s:smalls._adjust_col(a:pos)
  if self._is_visual()
    call a:pos.jump(self.env.mode)
  else
    call a:pos.jump()
  endif
endfunction

function! s:smalls._set_to_pos(pos) "{{{1
  call s:smalls._adjust_col(a:pos)
  call a:pos.jump()
endfunction

function! s:smalls._is_visual() "{{{1
  return self.env.mode =~# "v\\|V\\|\<C-v>"
  " return (self.env.mode != 'n' && self.env.mode != 'o')
endfunction

function! s:smalls._need_adjust_col(pos)
  if self.env.mode ==# 'n' | return 0 | endif
  if self.env.mode ==# 'o' | return self._is_forward(a:pos) | endif
  if self._is_visual()
    return self.env.mode =~# 'v\|V'
          \ ? self._is_forward(a:pos)
          \ : self._is_col_forward(a:pos.col)
  endif
endfunction

function! s:smalls._adjust_col(pos) "{{{1
  if self._need_adjust_col(a:pos)
    let a:pos.col += self.keyboard_cli.data_len() - 1
  endif
  if self.env.mode ==# 'o'
        \ && g:smalls_operator_motion_inclusive
        \ && self._is_forward(a:pos)
    let a:pos.col += 1
    if a:pos.col > len(getline(a:pos.line)) " line end
      let a:pos.line += 1
      let a:pos.col = 1
    endif
  endif
endfunction

function! s:smalls._is_forward(dst_pos) "{{{1
  return ( self.env.p.line < a:dst_pos.line ) ||
        \ (( self.env.p.line == a:dst_pos.line ) && ( self.env.p.col < a:dst_pos.col ))
endfunction

function! s:smalls._is_col_forward(col) "{{{1
  return ( self.env.p.col <= a:col )
endfunction

function! s:smalls.update_status(mode)
  " force to update statusline by meaningless option update ':help statusline'
  let g:smalls_current_mode = a:mode
  let &ro = &ro
  redraw
endfunction

function! s:smalls.do_excursion(kbd, ...) "{{{1
  let word = a:kbd.data
  if empty(word) | return [] | endif

  call self.update_status('excursion')
  let first_action = a:0 ? a:1 : ''
  let poslist = self.finder.all(word)
  let kbd     = smalls#keyboard#excursion#new(self, word, poslist)

  try
    while 1
      call self.hl.clear()
      call self.hl.shade()
      call self.hl.cursor()

      if !empty(first_action)
        call kbd['do_' . first_action]()
        let first_action = ''
      endif

      call self.hl.candidate(word, kbd.pos())
      if self._break
        break
      endif
      call kbd.read_input()
      redraw
    endwhile
  catch 'BACK_CLI'
    call self.update_status('cli')
    let self._break = 0
  endtry
endfunction

function! s:smalls.get_jump_target(word) "{{{1
  if empty(a:word) | return [] | endif
  let poslist = self.finder.all(a:word)
  let pos_new = smalls#jump#new(self.env, self.hl).get_pos(poslist)
  return pos_new
endfunction
"}}}

" PublicInterface:
function! smalls#start(...) "{{{1
  call call( s:smalls.start, a:000, s:smalls)
endfunction "}}}

function! smalls#debug() "{{{
endfunction
"}}}
" vim: foldmethod=marker
