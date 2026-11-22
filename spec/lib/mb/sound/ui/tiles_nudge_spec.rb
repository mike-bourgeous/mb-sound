require_relative '../../../../support/ui_helpers'

# The prompt's number nudge in the tiles' REPL pane (repl-scrub-1): the
# screen's Router passes Alt-arrows to the pane's Reline, which nudges a
# number in a recalled track line (wrapped over several rows of the pane)
# and runs it; each run redefines the track at its launch point in a
# Session playing it, the prompt keeps the line with the cursor on the
# number, history keeps one entry for the run, and undo steps back.  The
# plain console (and the take) is spec/bin/sound_nudge_spec.rb.
RSpec.describe('UI::Tiles REPL number nudge', :aggregate_failures) do
  after do
    @tiles&.stop
    @term&.close
    @session&.close
  end

  def host = @tiles.instance_variable_get(:@host)

  # The REPL's prompt line as Reline drew it (its wrapped rows joined) and
  # the character under the cursor.
  def prompt_text
    host.synchronize do
      rows = host.vt.lines.map(&:rstrip)
      start = rows.rindex { |l| l.match?(/\At[>*]( |\z)/) } or return [nil, nil]
      stop = (start...rows.length).find { |i| rows[i + 1].to_s.empty? } || rows.length - 1
      [rows[start..stop].join, host.vt.lines[host.vt.row][host.vt.col]]
    end
  end

  # The constants above 1000 in :t's playing graph (its cutoff).
  def cutoffs
    pl = @session.instance_variable_get(:@players).values.find { |p| p.name == :t && p.current? }
    pl.input.graph.grep(MB::Sound::GraphNode::Constant).map(&:constant).select { |c| c > 1000 }
  end

  # Renders +bars+ bars (960 bpm: a quarter second each).
  def render_bars(bars = 1)
    (bars * 48_000 / 4 / 800 + 2).times { @session.process_buffer }
  end

  it 'nudges a number in a recalled long line, redefining a playing track at each step' do
    MB::Sound::UI::NudgeKeys.install!
    @session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false, buffer_size: 800), realtime: false,
                                      transport: MB::Sound::Sequence::Transport.new(bpm: 960))
    s = @session
    MB::Sound::Session.with_context(session: s) do
      MB::Sound.track(:t, q: 1) { |c| c.hz.ramp.at(-20.db).filter(:lowpass, cutoff: 1200, quality: 2) }
      MB::Sound.bg(:t, MB::Sound.seq(MB::Sound::A2).n1.loop)
    end
    render_bars(2)
    expect(cutoffs).to eq([1200])

    # The console's commands on this Session
    ctx = Object.new
    %i[track undo].each do |m|
      ctx.define_singleton_method(m) { |*a, **k, &b| MB::Sound::Session.with_context(session: s) { MB::Sound.public_send(m, *a, **k, &b) } }
    end
    @tiles, @term = ui_tiles(:tiles, rows: 30, cols: 100, context: ctx.instance_eval { binding })
    expect(@term.wait_for('t> ')).to eq(true), @term.text

    # A line as long as the maintainer's: it wraps in the pane
    line = 'track(:t, q: 1) { it.hz.ramp.at(-20.db).filter(:lowpass, cutoff: 1200, quality: 2).softclip(0.5, 0.95).at(0.75) }'
    @term.type("#{line}\r")
    expect(wait_until { prompt_text[0] == 't>' }).to eq(true), prompt_text.inspect
    render_bars
    expect(wait_until { cutoffs == [1200] }).to eq(true)
    redefs = -> { s.journal.changes.count { |e| e.subject == :t } }
    before = redefs.call

    @term.write("\e[A") # Up: the line again
    expect(wait_until { prompt_text[0] == "t> #{line}" }).to eq(true), prompt_text.inspect
    @term.write("\e[1;4D" * 5) # back over 0.75, 0.95, 0.5, 2, to the cutoff
    expect(wait_until { prompt_text[1] == '0' }).to eq(true), prompt_text.inspect

    1.upto(3) do |i|
      @term.write(i == 3 ? "\e\e[A" : "\e[1;3A") # (the third in the Esc-then-arrow form)
      want = "t> #{line.sub('1200', "120#{i}")}"
      expect(wait_until { prompt_text == [want, i.to_s] }).to eq(true), "#{i}: #{prompt_text.inspect}"
      render_bars
      expect(wait_until { cutoffs == [1200 + i] }).to eq(true), "#{i}: #{cutoffs.inspect}"
    end
    expect(redefs.call - before).to eq(3)
    expect(Reline::HISTORY.to_a.map { |l| l[/cutoff: \d+/] }).to eq(['cutoff: 1200', 'cutoff: 1203'])

    # Undo: the last step back at the next bar
    @term.write("\x05\x15")
    @term.type("undo\r")
    expect(@term.wait_for('=> #<undo')).to eq(true), @term.text
    render_bars
    expect(wait_until { cutoffs == [1202] }).to eq(true), cutoffs.inspect
  end
end
