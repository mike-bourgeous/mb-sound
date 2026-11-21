require_relative '../support/ui_helpers'

# The prompt's number nudge in the whole console (repl-scrub-1): bin/sound.rb
# in a pty (read by a MB::Term::VT) with a track playing.  A recalled
# track line, a jump to its cutoff, three nudges (the last in the Esc-then-
# arrow form): each runs the line as Enter would (a journaled redefinition
# landing at the track's launch point, a take line), the prompt keeps the
# line with the cursor on the number, history has one entry for the run,
# and undo steps back.  A nudge whose line fails prints the error and keeps
# the line.
RSpec.describe('bin/sound.rb number nudge', :aggregate_failures) do
  it 'nudges a number in a recalled track line, landing each step, and keeps the line on the prompt' do
    require 'pty'
    vt = MB::Term::VT.new(40, 130, scrollback: 3000)
    lock = Mutex.new
    env = {
      'MB_SOUND_HELP_DIR' => tmp_path('help'), 'COLUMNS' => '130', 'LINES' => '40', 'OUTPUT_TYPE' => 'null',
      'INPUTRC' => tmp_path('inputrc'), 'XDG_DATA_HOME' => tmp_path('xdg'), 'MB_SOUND_CHECKOUT_TMP' => tmp_path('checkout'),
    }
    File.write(env['INPUTRC'], "# empty\n")
    r, w, pid = PTY.spawn(env, 'bin/sound.rb')
    w.winsize = [40, 130]
    reader = Thread.new do
      loop do
        d = r.readpartial(65_536)
        lock.synchronize do
          vt.feed(d)
          x = vt.take_replies
          w.write(x) unless x.empty?
        end
      end
    rescue IOError, SystemCallError
      nil
    end

    text = -> { lock.synchronize { vt.text } }
    wait = lambda { |what, t = 20|
      d = MB::U.clock_now + t
      until MB::U.clock_now > d
        s = text.call
        return true if what.is_a?(Regexp) ? s.match?(what) : s.include?(what)
        sleep 0.03
      end
      false
    }
    count = ->(re) { text.call.scan(re).length }
    type = ->(s) { s.each_char { |c| w.write(c); sleep 0.002 } }
    # The prompt's line (wrapped rows joined) and the character under the cursor
    prompt_line = lambda {
      lock.synchronize do
        rows = vt.lines
        start = (0..vt.row).to_a.reverse.find { |i| rows[i].include?('MB::Sound(0) >') }
        [rows[start..vt.row].map(&:rstrip).join, rows[vt.row][vt.col]]
      end
    }
    # The inspected value of console code +setup+; +expr+ (a marker the
    # echoed line can't contain)
    probes = 0
    probe = lambda { |setup, expr|
      w.write("\x05\x15") # (Ctrl-E Ctrl-U: the nudged line off the prompt)
      sleep 0.1
      id = (probes += 1)
      type.("#{setup}; puts 'PRO' + 'BE#{id} ' + (#{expr}).inspect\r")
      expect(wait.(/^PROBE#{id} /)).to eq(true), text.call
      text.call[/^PROBE#{id} (.*)$/, 1].to_s.strip
    }

    expect(wait.(/MB::Sound\(0\) >/, 60)).to eq(true), text.call

    line = 'track(:t, q: 1) { it.hz.ramp.at(-20.db).filter(:lowpass, cutoff: 1200, quality: 2) }'
    type.("bpm 960\r")
    expect(wait.('=> ')).to eq(true), text.call
    type.("#{line}\r")
    expect(wait.('=> :t')).to eq(true), text.call
    type.("bg :t, seq(A2).n1.loop\r")
    expect(wait.('#<bg :t lands')).to eq(true), text.call
    sleep 0.35 # (a bar at 960 bpm is 0.25 s: :t plays)

    # Up twice: the track line; Alt-Shift-Left twice: quality's 2, then the cutoff
    w.write("\e[A")
    sleep 0.1
    w.write("\e[A")
    sleep 0.1
    w.write("\e[1;4D")
    sleep 0.05
    w.write("\e[1;4D")
    sleep 0.05
    expect(prompt_line.call).to eq(["sound.rb [4] MB::Sound(0) > #{line}", '0'])

    ["\e[1;3A", "\e[1;3A", "\e\e[A"].each_with_index do |key, i|
      runs = count.(/=> :t/)
      w.write(key)
      d = MB::U.clock_now + 10
      sleep 0.03 until count.(/=> :t/) > runs || MB::U.clock_now > d
      expect(count.(/=> :t/)).to eq(runs + 1), text.call
      sleep 0.35 # (past the next bar: the redefinition lands)
      expect(prompt_line.call).to eq(["sound.rb [#{5 + i}] MB::Sound(0) > #{line.sub('1200', "120#{i + 1}")}", "#{i + 1}"]), text.call
    end

    pl = 'pl = Session.current.instance_variable_get(:@players).values.find { _1.name == :t && _1.current? }'
    consts = 'pl.input.graph.grep(MB::Sound::GraphNode::Constant).map(&:constant).select { _1 > 1000 }'
    # (patterns that don't match this probe line itself)
    redefs = 'changes.grep(/track :t redefined/).length'
    take = 'Take.current.recent_lines(20).map { |_, c| c[/cutoff: 12\d\d/] }.compact'
    hist = 'Reline::HISTORY.to_a.map { _1[/cutoff: 12\d\d/] }.compact'
    out = probe.(pl, "[#{consts}, #{redefs}, #{take}, #{hist}]")
    # The graph at 1203; three redefinitions; the take has every step; history the recalled line and the latest
    expect(out).to eq('[[1203], 3, ["cutoff: 1200", "cutoff: 1201", "cutoff: 1202", "cutoff: 1203"], ["cutoff: 1200", "cutoff: 1203"]]')

    type.("undo\r")
    expect(wait.(/=> #<undo/)).to eq(true), text.call
    sleep 0.35
    out = probe.(pl, consts)
    expect(out).to eq('[1202]')

    # A nudge whose line fails: the error as Enter's, the line kept
    w.write("\x05\x15")
    type.('Math.sqrt(1)')
    w.write("\e[D")
    w.write("\e[1;3B")
    expect(wait.('=> 0.0')).to eq(true), text.call
    w.write("\e[1;3B")
    expect(wait.('Math::DomainError')).to eq(true), text.call
    sleep 0.2
    expect(prompt_line.call[0]).to end_with('MB::Sound(0) > Math.sqrt(-1)')
  ensure
    Process.kill(:KILL, pid) rescue nil
    Process.wait(pid) rescue nil
    reader&.join(1)
  end
end
