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

  it 'records warnings while tiles are up, counts them on the status line, and shows them in a pane with NAV m' do
    @tiles, @term = ui_tiles(:tiles, source: -> { ui_fake_snapshot })
    MB::Sound::UI.instance_variable_set(:@tiles, @tiles) # (UI.screen)
    expect(@term.wait_for('t> ')).to eq(true)
    # Not the console's terminal here, so warnings still print as well
    expect { 2.times { warn 'spec warning: something clipped' } }.to output(/something clipped/).to_stderr
    expect(MB::Sound::UI.messages.recent(1)[0].count).to eq(2)
    expect(@term.wait_for(' ! 1 (m) ')).to eq(true), @term.text
    @term.write("\x1d")
    expect(@term.wait_for(' NAV ')).to eq(true)
    @term.type('m')
    expect(@term.wait_for('×2 spec warning: something clipped')).to eq(true), @term.text
    expect(@term.text).not_to include(' ! 1 (m) ')
    @term.type('m')
    @term.settle
    expect(@tiles.tiler.layout.panes).not_to include(:messages)
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
