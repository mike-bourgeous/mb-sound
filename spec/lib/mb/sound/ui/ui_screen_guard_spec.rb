require_relative '../../../../support/ui_helpers'

# The guard behind every example (spec/support/ui_screen_guard.rb): a screen
# left up or fds left reopened are named, and cleaned up.
RSpec.describe(UIScreenGuard, :aggregate_failures) do
  it 'names a leftover tiled screen and a reopened stdin, and puts both back' do
    fake = Struct.new(:layout_name, :stopped) do
      def active? = !stopped
      def hidden? = false
      def stop = self.stopped = true
    end.new(:tiles, false)
    MB::Sound::UI.instance_variable_set(:@tiles, fake)
    path = tmp_path('stdin.txt')
    File.write(path, '')
    File.open(path) do |other| # (not /dev/null: a worker's stdin may be that already)
      STDIN.reopen(other)
      expect(UIScreenGuard.problems).to contain_exactly(/tiled screen is still up/, /stdin was left reopened/)
      UIScreenGuard.clean_up
    end
    expect(fake.stopped).to eq(true)
    expect(UIScreenGuard.problems).to eq([])
  ensure
    MB::Sound::UI.instance_variable_set(:@tiles, nil)
  end

  # (fix-fits-isolation: a design left open made a later spec's track of
  # the same name rebuild on the next buffer instead of the next bar)
  it 'names a sound design left open, and closes it' do
    s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), channels: 1, realtime: false)
    MB::Sound::Session.with_context(session: s) { MB::Sound::UI::Design.open(:lead) }
    expect(MB::Sound::UI::Design.designing?(:lead)).to eq(true)
    expect(UIScreenGuard.problems).to eq(['sound design is still open on :lead (UI::Design.close)'])
    UIScreenGuard.clean_up
    expect(MB::Sound::UI::Design.designing?(:lead)).to eq(false)
    expect(MB::Sound::UI::Design.last).to be_nil
    expect(UIScreenGuard.problems).to eq([])
  ensure
    s&.close
    MB::Sound.rewind
  end

  it 'finds nothing after a spec screen that cleaned up' do
    tiles, term = ui_tiles(:tiles, rows: 24, cols: 80)
    expect(term.wait_for('t> ')).to eq(true)
    tiles.stop
    term.close
    expect(UIScreenGuard.problems).to eq([])
  end
end
