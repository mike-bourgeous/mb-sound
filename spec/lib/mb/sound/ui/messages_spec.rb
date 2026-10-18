require_relative '../../../../support/ui_helpers'

# Warnings while a UI is up (ux-1 item 11).
RSpec.describe(MB::Sound::UI::Messages, :aggregate_failures) do
  after do
    @tiles&.stop
    @term&.close
    MB::Sound::UI.instance_variable_set(:@tiles, nil)
    MB::Sound::UI.messages.clear
  end

  it 'deduplicates by text, counts repeats, and summarizes' do
    m = described_class.new
    m.add("\e[33mclipped a peak\e[0m\n", now: 1.0)
    m.add('clipped a peak', now: 2.0)
    m.add('ArgumentError: no (live mode: ignored)', severity: :error, now: 3.0)
    expect(m.total).to eq(3)
    expect(m.recent.map { |e| [e.text, e.count, e.severity] }).to eq([['ArgumentError: no (live mode: ignored)', 1, :error], ['clipped a peak', 2, :warn]])
    expect(m.unread).to eq(2)
    m.mark_read
    expect(m.unread).to eq(0)
    expect(m.summary).to eq("ui: 3 messages (2 different) while the UI was up:\n  ArgumentError: no (live mode: ignored)\n  ×2 clipped a peak")
    expect(described_class.severity_of('x (live mode: ignored)')).to eq(:error)
    expect(described_class.severity_of('x', :deprecated)).to eq(:note)
  end

  it 'records warnings while tiles are up, opens the messages pane for a new one, and NAV m takes it away (ux-1 r3 item 25)' do
    @tiles, @term = ui_tiles(:tiles, source: -> { ui_fake_snapshot })
    MB::Sound::UI.instance_variable_set(:@tiles, @tiles) # (UI.screen)
    expect(@term.wait_for('t> ')).to eq(true)
    before = @tiles.tiler.layout
    # Not the console's terminal here, so warnings still print as well
    expect { 2.times { warn 'spec warning: something clipped' } }.to output(/something clipped/).to_stderr
    expect(MB::Sound::UI.messages.recent(1)[0].count).to eq(2)
    expect(@term.wait_for('×2 spec warning: something clipped')).to eq(true), @term.text
    expect(@tiles.tiler.layout.panes).to include(:messages)
    expect(@term.text).to include('warn: spec warning: something clipped')
    expect(@term.text).not_to include(' ! 1 (m) ')
    @term.write("\x1d")
    expect(@term.wait_for(' NAV ')).to eq(true)
    @term.type('m')
    @term.settle
    expect(@tiles.tiler.layout.panes).not_to include(:messages)
    expect(@tiles.tiler.layout.root).to eq(before.root)
  end

  # The painter notices messages on its next frame, which may come before
  # or after an action's own flash; holding the screen's lock fixes the
  # order (the 2026-10-17 Mac failure of tiles_keys_spec's capture example,
  # where the painter's late look replaced the capture summary).
  it "orders a message's flash and an action's flash by when they happened, not when the painter looked" do
    @tiles, @term = ui_tiles(:tiles, source: -> { ui_fake_snapshot })
    MB::Sound::UI.instance_variable_set(:@tiles, @tiles) # (UI.screen)
    expect(@term.wait_for('t> ')).to eq(true)
    lock = @tiles.instance_variable_get(:@lock)
    flash = -> { @tiles.instance_variable_get(:@flash)&.first }

    # A message, then a summary naming it: the pane opens, the summary stays
    lock.synchronize do
      expect { warn 'spec warning: a track failed' }.to output(/a track failed/).to_stderr
      @tiles.send(:flash, 'action: one thing done; :x failed (m: messages)', :warn)
    end
    @tiles.refresh
    expect(@tiles.tiler.layout.panes).to include(:messages)
    expect(flash.()).to eq('action: one thing done; :x failed (m: messages)')

    # A flash, then a message: the message's flash replaces it
    @tiles.messages(false)
    lock.synchronize do
      @tiles.send(:flash, 'an older flash', :ok)
      expect { warn 'spec warning: newer' }.to output(/newer/).to_stderr
    end
    @tiles.refresh
    expect(@tiles.tiler.layout.panes).to include(:messages)
    expect(flash.()).to eq('warn: spec warning: newer  (NAV m: away)')
  end

  it "prints the REPL's own command's warnings in the REPL, and the palette's output and value there too (ux-1 r3 items 22, 25)" do
    @tiles, @term = ui_tiles(:tiles, rows: 40, cols: 120)
    MB::Sound::UI.instance_variable_set(:@tiles, @tiles)
    expect(@term.wait_for('t> ')).to eq(true)
    # (the REPL's stderr: the pane when adopted; this Pry's is the process's)
    expect {
      @term.type("warn 'from the repl command'; 6 * 7\r")
      expect(@term.wait_for('=> 42')).to eq(true)
    }.to output(/from the repl command/).to_stderr
    expect(MB::Sound::UI.messages.total).to eq(0), MB::Sound::UI.messages.recent.map(&:text).inspect
    expect(@tiles.tiler.layout.panes).not_to include(:messages)

    # A palette line printing many lines: into the REPL pane, the status line stays one line
    status = @tiles.rows - 1
    @term.write("\x1d")
    expect(@term.wait_for(' NAV ')).to eq(true)
    @term.type(":puts((1..30).map { |i| \"pal \#{i}\" }); warn 'pal warn'; \"a\\nb\"\r")
    expect(wait_until { @tiles.host.vt.text.include?('pal 30') }).to eq(true), @tiles.host.vt.text
    vt = @tiles.host.vt.text + @tiles.host.vt.scrollback.join("\n")
    expect(vt).to include('pal 1', 'pal warn', '=> "a\\nb"')
    @term.settle
    expect(@term.lines[status]).to include(' NAV ')
    expect(@term.lines[0]).to eq(@tiles.to_text.lines[0].chomp) # (nothing scrolled the screen)
    expect(@tiles.router.mode).to eq(:nav)
    expect(MB::Sound::UI::Tiles.one_line("a\nb\e[31mc")).to eq('a ...')
  end

  it 'keeps warnings off a terminal the screen owns, and summarizes them when the UI turns off' do
    @tiles, @term = ui_tiles(:tiles)
    MB::Sound::UI.instance_variable_set(:@tiles, @tiles)
    allow(@tiles).to receive(:owns_terminal?).and_return(true)
    expect { warn 'spec warning: kept off the screen' }.not_to output.to_stderr
    expect { MB::Sound::UI.off }.to output(/ui: 1 message while the UI was up:\n  spec warning: kept off the screen/).to_stdout
    expect(MB::Sound::UI.messages.total).to eq(0)
  end
end
