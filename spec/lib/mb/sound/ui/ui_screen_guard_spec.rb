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
    File.open(File::NULL) do |null|
      STDIN.reopen(null)
      expect(UIScreenGuard.problems).to contain_exactly(/tiled screen is still up/, /stdin was left reopened/)
      UIScreenGuard.clean_up
    end
    expect(fake.stopped).to eq(true)
    expect(UIScreenGuard.problems).to eq([])
  ensure
    MB::Sound::UI.instance_variable_set(:@tiles, nil)
  end

  it 'finds nothing after a spec screen that cleaned up' do
    tiles, term = ui_tiles(:tiles, rows: 24, cols: 80)
    expect(term.wait_for('t> ')).to eq(true)
    tiles.stop
    term.close
    expect(UIScreenGuard.problems).to eq([])
  end
end
