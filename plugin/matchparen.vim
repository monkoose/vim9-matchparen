vim9script

# Exit quickly when:
# - this plugin was already loaded (or disabled)
# - 'compatible' is set
# - there are no colors (looks like the cursor jumps)
if exists('g:loaded_matchparen')
    || &compatible
    || str2nr(&t_Co) < 8 && !has('gui_running')
  finish
endif
g:loaded_matchparen = 1

# Configuration {{{1
var config: dict<any> = {
  on_startup: true,
  syntax_ignored: false,
  syntax_groups: ['string', 'comment', 'character'],
  ft_syntax_groups: {
    sh: ['string', 'comment', 'singlequote', 'doublequote'],
    lisp: ['string', 'comment', 'escape', 'symbol'],
  },
  timeout: 200,
  timeout_insert: 100,
  # debounce_time should be <= timeout_insert and timeout, otherwise
  # there would be missing brackets highlight in some situations in insert mode
  debounce_time: 100,
}

extend(config, get(g:, 'matchparen_config', {}))

if empty(prop_type_get('matchparen'))
  prop_type_add('matchparen', {highlight: 'MatchParen'})
endif

# Variables {{{1
var before: number
var c_lnum: number
var c_col: number
var m_lnum: number
var m_col: number
var timer: number
var matchpairs: string
var pairs: dict<list<string>>
var curbuf: string

const props: dict<any> = {length: 1, type: 'matchparen'}

# Functions {{{1
def ParseMatchpairs()
  if matchpairs != &matchpairs
    matchpairs = &matchpairs
    const splitted_matchpairs = matchpairs
                                  ->split(',')
                                  ->map((_, v) => split(v, ':'))
    pairs = {}
    for [opening, closing] in splitted_matchpairs
      pairs[opening] = [escape(opening, '[]'), escape(closing, '[]'),  'nW', 'w$']
      pairs[closing] = [escape(opening, '[]'), escape(closing, '[]'), 'bnW', 'w0']
    endfor
  endif
enddef

def UpdateHighlight(in_insert: bool = false)
# The function that is invoked (very often) to define a highlighting for any
# matching paren.
  if !!config.debounce_time
    timer_stop(timer)
  endif

  # Nothing to highlight if we're in a closed fold
  if foldclosed('.') != -1
    RemoveHighlight()
    return
  endif

  # Save cursor position so it can be used later
  const saved_cursor = getcurpos()
  # Get the character under the cursor and check if it's in 'matchpairs'
  [_, c_lnum, c_col; _] = saved_cursor
  const text = getline(c_lnum)
  const charcol = charcol('.')
  var c = text[charcol - 1]
  before = 0
  # In Insert mode try character before the cursor
  if in_insert
    const c_before = charcol == 1 ? '' : text[charcol - 2]
    if has_key(pairs, c_before)
      if c_col > 1
        before = strlen(c_before)
        c = c_before
      endif
    else
      # Still not on matching bracket
      if !has_key(pairs, c)
        RemoveHighlight()
        return
      endif
    endif
  else
    if !has_key(pairs, c)
      RemoveHighlight()
      return
    endif
  endif

  def ProcessHighlight()
    # Find the match.
    # When it was just before the cursor, move the latter there for a moment.
    if before > 0
      cursor(c_lnum, c_col - before)
    endif

    var Skip: func: bool
    try
      Skip = GetSkip()
    # synstack() inside InStringOrComment() might throw:
    # E363: pattern uses more memory than 'maxmempattern'.
    catch /^Vim\%((\a\+)\)\=:E363:/
      # We won't find anything, so skip searching to keep Vim responsive.
      RemoveHighlight()
      return
    endtry

    # Figure out the arguments for searchpairpos()
    # Use a stopline to limit the search to lines visible in the window
    var c2: string
    var s_flags: string
    var stopline: string
    [c, c2, s_flags, stopline] = pairs[c]

    # Limit the search time to avoid a hang on very long lines.
    const timeout = in_insert ? config.timeout_insert : config.timeout
    try
      [m_lnum, m_col] = searchpairpos(c, '', c2, s_flags, 'Skip()', line(stopline), timeout)
    catch /^Vim\%((\a\+)\)\=:E363:/
    endtry

    if before > 0
      setpos('.', saved_cursor)
    endif

    RemoveHighlight()
    if m_lnum > 0
      prop_add(c_lnum, c_col - before, props)
      prop_add(m_lnum, m_col, props)
    endif
  enddef

  if !!config.debounce_time
    timer = timer_start(config.debounce_time, (_) => {
      ProcessHighlight()
    })
  else
    ProcessHighlight()
  endif
enddef

def RemoveHighlight()
  # `:silent!` to suppress E16 in case `line('w$')` is 0
  silent! prop_remove({type: 'matchparen', all: true}, line('w0'), line('w$'))
enddef

def Toggle(args: string)
  if args == ''
    var usage: list<string> =<< trim END
      # to enable the plugin
      :MatchParen on

      # to disable the plugin
      :MatchParen off

      # to toggle the plugin
      :MatchParen toggle
    END
    echo join(usage, "\n")
    return
  endif

  if index(['on', 'off', 'toggle'], args) == -1
    redraw
    echohl ErrorMsg
    echomsg 'matchparen: invalid argument'
    echohl NONE
    return
  endif

  def Enable()
    Autocmds(true)
    ParseMatchpairs()
    UpdateHighlight()
  enddef

  def Disable()
    Autocmds(false)
    RemoveHighlight()
  enddef

  if args == 'on'
    Enable()
  elseif args == 'off'
    Disable()
  elseif args == 'toggle'
    if !exists('#matchparen')
      Enable()
    else
      Disable()
    endif
  endif
enddef

# Should return true when the current cursor position is in certain syntax types
# (string, comment,  etc.); evaluated inside  lambda passed as skip  argument to
# searchpairpos().
def InStringOrComment(syn_groups: list<string>): bool
  # can improve the performance when inserting characters in front of a paren
  # while there are closed folds in the buffer
  if foldclosed('.') != -1
    return false
  endif
  # After moving to the end of a line  with `$`, then onto the  line below with
  # `k`, `synstack()` might wrongly give an empty stack.  Possible bug:
  # https://github.com/vim/vim/issues/5252
  var synstack: list<number> = synstack('.', col('.'))
  if empty(synstack) && getcurpos()[-1] == v:maxcol
    # As a workaround, we ask for the syntax a second time.
    synstack = synstack('.', col('.'))
  endif
  # Iterate over synstack
  var synname: string
  for synID: number in synstack
    synname = synIDattr(synID, 'name')
    for group in syn_groups
      if synname =~? group
        return true
      endif
    endfor
  endfor
  return false
enddef

def GetSkip(): func(): bool
  if !exists('b:current_syntax') || config.syntax_ignored
    return () => false
  endif
  var syn_groups = get(config.ft_syntax_groups, &filetype, config.syntax_groups)
  # If evaluating the expression determines that the cursor is
  # currently in a text with some specific syntax type (like a string
  # or a comment), then we want searchpairpos() to find a pair within
  # a text of similar type; i.e. we want to ignore a pair of different
  # syntax type.
  if InStringOrComment(syn_groups)
    return () => !InStringOrComment(syn_groups)
  # Otherwise, the cursor is outside of these specific syntax types,
  # and we want searchpairpos() to find a pair which is also outside.
  else
    return () => InStringOrComment(syn_groups)
  endif
enddef

# Autocommands {{{1

# Wrap the autocommands inside a function so that they can be easily installed
# or removed on-demand later.
def Autocmds(enable: bool)
  if enable && !exists('#matchparen')
    augroup matchparen
      autocmd!
      autocmd BufEnter * curbuf = expand('<abuf>') | ParseMatchpairs()
      # FileType because 'matchpairs' could be (re)set by a filetype plugin
      autocmd WinScrolled,FileType * {
        if curbuf == expand('<abuf>')
          ParseMatchpairs()
        endif
      }
      autocmd OptionSet matchpairs {
        # <abuf> is always '', so we use bufnr() here until
        # https://github.com/vim/vim/issues/12418 fixed
        if v:option_type == 'global' || str2nr(curbuf) == bufnr()
          ParseMatchpairs()
        endif
      }
      autocmd CursorMoved,WinEnter,TextChanged * UpdateHighlight()
      autocmd InsertEnter,CursorMovedI,TextChangedI * UpdateHighlight(true)

      # In case we reload the buffer while the cursor is on a paren.
      # Need to delay with SafeState because when reloading, the cursor is
      # temporarily on line 1 col 1, no matter its position before the reload.
      autocmd BufReadPost * autocmd SafeState <buffer=abuf> ++once UpdateHighlight()

      # BufLeave is necessary when the cursor is on a parenthesis and we open
      # the quickfix window.
      autocmd WinLeave,BufLeave * RemoveHighlight()
    augroup END
  elseif !enable && exists('#matchparen')
    autocmd! matchparen
    augroup! matchparen
  endif
enddef

if config.on_startup
  Autocmds(true)
endif

# Commands {{{1

def Complete(_, _, _): list<string>
  return ['on', 'off', 'toggle']
enddef

# Define command that will disable and enable the plugin.
command -bar -complete=customlist,Complete -nargs=? MatchParen Toggle(<q-args>)
# }}}1

# vim: fdm=marker
