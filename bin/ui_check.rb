#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 MB_SOUND_YJIT=1 ruby
# Reports what this terminal supports for the tiled console (ui :tiles).
#
# Asks the terminal (in the alternate screen, for a moment) and prints a
# report to paste into bug reports: synchronized output (DEC 2026), the
# width it draws East Asian ambiguous characters with (1 or 2 columns: 2
# means the console's glyphs should be ASCII), the kitty keyboard protocol,
# bracketed paste, focus and SGR mouse reports, left/right margins (DECSLRM),
# its name (XTVERSION), and the environment (TERM, tmux, ssh).  OSC 52
# clipboard writes can't be queried: --copy sends one to try by pasting.
#
#     bin/ui_check.rb               # the report
#     bin/ui_check.rb --copy        # also puts a marker on the clipboard with OSC 52 (paste it to check)
#     bin/ui_check.rb --keys        # shows each key as the tiled console reads it (Ctrl-] is the NAV key); q q quits
#
# Expected in iTerm2 and Konsole: sync yes, ambiguous width 1 (unless the
# profile treats ambiguous characters as wide), bracketed paste yes.  Inside
# tmux, answers come from tmux.  Without a terminal it says so and exits.

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  module UICheck
    # DEC private modes asked about with DECRQM, and what they are.
    MODES = {
      2026 => 'synchronized output (frames without tearing)',
      2004 => 'bracketed paste',
      1004 => 'focus reports',
      1006 => 'SGR mouse reports',
      69 => 'left/right margins (DECSLRM; not used by :tiles)',
      2027 => 'grapheme clusters (mode 2027)',
    }.freeze

    module_function

    # Writes the queries and collects the raw replies (until the DA1 reply
    # that fences them, or +timeout+).
    def ask(input, output, timeout)
      queries = +"\e[1;1H▽\e[6n\e[1;1H\e[2K"
      MODES.each_key { |m| queries << "\e[?#{m}$p" }
      queries << "\e[?u\e[>0q\e[>c\e[c"
      output.write(queries)
      output.flush
      buf = +''.b
      deadline = MB::U.clock_now + timeout
      until buf.match?(/\e\[\?[\d;]*c/n)
        left = deadline - MB::U.clock_now
        break if left <= 0 || !input.wait_readable(left)
        buf << input.read_nonblock(4096, exception: false).to_s.b
      end
      buf
    end

    # The report's lines from raw replies +r+.
    def report(r, size)
      lines = []
      amb = r[/\e\[\d+;(\d+)R/n, 1]
      lines << "Ambiguous width:   #{amb ? "#{amb.to_i - 1} column#{amb.to_i - 1 == 1 ? '' : 's'}" : 'no cursor report'}#{amb && amb.to_i - 1 == 2 ? '  (the console uses ASCII glyphs)' : ''}"
      MODES.each do |m, what|
        v = r[/\e\[\?#{m};(\d)\$y/n, 1]
        state = case v
                when nil then 'no answer'
                when '0' then 'not recognized'
                when '1', '3' then 'yes (set)'
                when '2', '4' then 'yes'
                end
        lines << format('%-18s %s', "Mode #{m}:", "#{state}  #{what}")
      end
      kitty = r[/\e\[\?(\d+)u/n, 1]
      lines << "Kitty keyboard:    #{kitty ? "yes (flags #{kitty})" : 'no answer'}"
      name = r[/\eP>\|([^\e]*)\e\\/n, 1]
      lines << "Terminal name:     #{name ? name.force_encoding('UTF-8').scrub : 'no answer (XTVERSION)'}"
      da1 = r[/\e\[\?([\d;]*)c/n, 1]
      lines << "Device attributes: #{da1 ? "?#{da1}" : 'no answer (the queries timed out)'}"
      da2 = r[/\e\[>([\d;]*)c/n, 1]
      lines << "Secondary DA:      #{da2 ? ">#{da2}" : 'no answer'}"
      lines << "Size:              #{size[0]} rows x #{size[1]} columns"
      env = %w[TERM TERM_PROGRAM TERM_PROGRAM_VERSION COLORTERM LANG LC_ALL].filter_map { |k| "#{k}=#{ENV[k]}" if ENV[k] }
      lines << "Environment:       #{env.join(' ')}"
      lines << "Multiplexer/ssh:   #{[ENV['TMUX'] && 'tmux', ENV['STY'] && 'screen', ENV['SSH_TTY'] && 'ssh'].compact.join(', ').then { |s| s.empty? ? 'none' : s }}"
      lines
    end
  end

  if main_script?(__FILE__)
    MB::Sound.script(
      copy: [false, 'Also put a marker on the clipboard with OSC 52 (paste it somewhere to check)'],
      keys: [false, 'Show keys as the tiled console decodes them (q twice quits; 30 s idle quits)'],
      timeout: [1.0, 'Seconds to wait for answers', '-t', Float, 0.05..10.0],
    ) { |_args, p|
      unless $stdin.tty? && $stdout.tty?
        puts 'Not a terminal: run bin/ui_check.rb in the terminal to check (iTerm2, Konsole, tmux, ...).'
        next
      end

      term = MB::Term::Terminal.new(input: $stdin.dup, output: $stdout.dup)
      raw = nil
      begin
        term.enter
        raw = UICheck.ask(term.input, term.output, p.timeout)
      ensure
        term.leave
      end
      size = term.size
      puts 'Terminal features for the tiled console (ui :tiles), from the terminal itself:'
      UICheck.report(raw, size).each { |l| puts "  #{l}" }
      puts "  Raw replies:       #{raw.inspect[0, 300]}" if ENV['UI_CHECK_RAW']

      if p.copy
        marker = "mb-sound ui_check #{Time.now.strftime('%H:%M:%S')}"
        term.copy(marker)
        puts "OSC 52: sent #{marker.inspect} to the clipboard; paste it somewhere (iTerm2: allow 'Applications in terminal may access clipboard')."
      end

      if p.keys
        puts 'Keys (q twice quits): each key as MB::Term::Input::Decoder reads it, with its bytes.'
        dec = MB::Term::Input::Decoder.new
        $stdin.raw do |io|
          qs = 0
          last = MB::U.clock_now
          loop do
            ready = io.wait_readable(dec.pending? ? dec.esc_timeout : 1.0)
            events = ready ? dec.feed(io.read_nonblock(4096, exception: false).to_s) : (dec.pending? ? dec.flush : [])
            events.each do |e|
              last = MB::U.clock_now
              desc = e.is_a?(MB::Term::Input::Key) ? "#{e}  #{e.bytes.inspect}#{e.chord == MB::Term::Input::Router::NAV_KEY.chord ? '  (the NAV key)' : ''}" : e.inspect
              $stdout.write("#{desc}\r\n")
              qs = e.is_a?(MB::Term::Input::Key) && e.key == 'q' ? qs + 1 : 0
            end
            break if qs >= 2 || MB::U.clock_now - last > 30
          end
        end
      end
    }
  end
end
