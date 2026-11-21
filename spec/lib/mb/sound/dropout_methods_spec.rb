require_relative '../../../support/ui_helpers'

# The console's `dropouts` command (console-offers-1): a DropoutProbe on the
# default Session, saved to the handoff inbox, one line per action.
RSpec.describe(MB::Sound::DropoutMethods, :aggregate_failures) do
  before do
    @inbox = File.dirname(tmp_path('inbox/x'))
    ENV['MB_SOUND_CHECKOUT_TMP'] = @inbox # (restored by env_restore)
    described_class.probe = nil
  end

  after do
    p = described_class.probe
    p.stop if p&.running?
    described_class.probe = nil
    if @session
      @session.close
      MB::Sound::Session.use_output(nil)
    end
    MB::Sound.rewind
  end

  # The default Session on miniaudio's null device (the probe's trace
  # needs a DeviceOutput), playing a constant.
  def start_session
    output = MB::Sound::DeviceOutput.new(channels: 1, backends: [:null], latency: 0.03, buffer_size: 512, adaptive: false)
    MB::Sound::Session.use_output(output)
    @session = MB::Sound::Session.default
    @session.add(0.1.constant, name: :quiet)
    Thread.pass until @session.running?
    @session
  end

  it 'starts, says how it goes in one line, reports while running, and stops with the report and the saved files' do
    session = start_session
    s = MB::Sound.dropouts(system: false, settle: 0.3, startup: 0)
    expect(s).to be_a(described_class::Status)
    dir = File.join(@inbox, 'dropout_probe')
    expect(s.inspect).to match(%r{\Adropouts: probing null "NULL Playback Device" at 48000 Hz, buffer 512, .*; saves to #{Regexp.escape(dir)}/console-\d{8}-\d{6}\.json \(dropouts :report, :stop\)\z})
    expect(s.inspect.lines.length).to eq(1)
    probe = described_class.probe
    expect(probe).to be_running
    expect(probe.session).to equal(session)

    expect(MB::Sound.dropouts.inspect).to match(/\Adropouts: probing for 0:0\d, 0 dropouts so far \(dropouts :report, :stop; saves to /)
    expect(MB::Sound.dropouts(:start).inspect).to start_with('dropouts: already probing for 0:0')

    # A render stall: the probe's line for it, then the status names it
    stall = false
    tap = session.add_tap { |_| (stall = false; MB::Sound::FastLatency.spin(0.12)) if stall }
    sleep 0.3
    expect {
      stall = true
      expect(wait_until(timeout: 5) { !probe.dropouts.empty? }).to eq(true)
    }.to output(/^dropout 1 at .*: render/).to_stdout
    session.remove_tap(tap)
    expect(MB::Sound.dropouts.inspect).to match(/\d+ dropouts? so far, most likely render \(\d+ of \d+\)/)

    r = nil
    expect { r = MB::Sound.dropouts(:report) }.to output(/Dropout probe: console for .*Likely causes:.*render/m).to_stdout
    expect(r.inspect).to start_with('dropouts: probing for')
    expect(probe).to be_running

    expect { r = MB::Sound.dropouts.stop }.to output(/Likely causes:/).to_stdout
    expect(r.inspect).to match(%r{\Adropouts: stopped after 0:0\d, \d+ dropouts?, most likely render \(\d+ of \d+\); saved #{Regexp.escape(dir)}/console-[\d-]+\.json \(\.csv and \.txt beside it\)\z})
    expect(probe).not_to be_running
    %i[json csv txt].each { |k| expect(File.exist?(probe.paths[k])).to eq(true), k.to_s }
    expect(File.read(probe.paths[:txt])).to include('render overrun')

    expect(MB::Sound.dropouts(:stop).inspect).to eq('dropouts: none running (dropouts starts one)')
    expect { MB::Sound.dropouts(:report) }.to output(/Likely causes:/).to_stdout # (the last run's)
    expect { MB::Sound.dropouts(:stp) }.to raise_error(ArgumentError, /dropouts takes :start, :report, :stop \(got :stp; did you mean :stop\?\)/)
    expect { MB::Sound.dropouts(:report, system: false) }.to raise_error(ArgumentError, /takes no options/)
  end

  it 'says so before any probe ran, and follows the default Session when it is replaced' do
    expect(MB::Sound.dropouts(:report).inspect).to eq('dropouts: no probe has run (dropouts starts one)')
    expect(MB::Sound.dropouts(:stop).inspect).to eq('dropouts: none running (dropouts starts one)')

    start_session
    MB::Sound.dropouts(system: false)
    probe = described_class.probe
    expect(wait_until { probe.meta[:outputs] == 1 }).to eq(true)
    @session.close
    out2 = MB::Sound::DeviceOutput.new(channels: 1, backends: [:null], latency: 0.03, buffer_size: 256, adaptive: false)
    MB::Sound::Session.use_output(out2) # (as `latency :low` does)
    @session = MB::Sound::Session.default
    expect(wait_until { probe.session.equal?(@session) && probe.meta[:outputs] == 2 }).to eq(true)
    expect(probe.meta[:buffer]).to eq(256)
  end

  it 'starts with the console when MB_SOUND_DROPOUT_PROBE is set, as scripts do' do
    expect(described_class.start_from_env(env: { 'MB_SOUND_DROPOUT_PROBE' => '0' })).to be_nil
    start_session
    probe = nil
    MB::Sound::DropoutProbe.arm(system: false) # (no system probe here; the variable alone gives one)
    expect { probe = described_class.start_from_env(env: { 'MB_SOUND_DROPOUT_PROBE' => '1' }) }
      .to output(%r{\Adropouts: probing null .*\(MB_SOUND_DROPOUT_PROBE\); saves to .*/dropout_probe/console-[\d-]+\.json \(dropouts :report, :stop\)\n\z}).to_stdout
    expect(probe).to be_running
    expect(described_class.probe).to equal(probe)
    expect(probe.options[:follow]).to eq(true)
    expect(MB::Sound.dropouts.inspect).to start_with('dropouts: probing for')
  end

  it 'saves to tmp/dropout_probe in the checkout tmp (MB_SOUND_CHECKOUT_TMP), as the probe does by default' do
    expect(MB::Sound::DropoutProbe.dir).to eq(File.join(@inbox, 'dropout_probe'))
    expect(MB::Sound::DropoutProbe.default_path('x')).to match(%r{\A#{Regexp.escape(@inbox)}/dropout_probe/x-\d{8}-\d{6}\.json\z})
  end

  describe 'MB::Sound::Internal.console_puts' do
    after do
      @tiles&.stop
      @term&.close
      MB::Sound::UI.instance_variable_set(:@tiles, nil)
    end

    it 'prints on stdout without a screen' do
      expect { MB::Sound::Internal.console_puts('a line') }.to output("a line\n").to_stdout
    end

    it "puts a background thread's line above the REPL pane's prompt with the tiles up, keeping the line being typed" do
      @tiles, @term = ui_tiles(:tiles)
      expect(@term.wait_for('t> ')).to eq(true)
      MB::Sound::UI.instance_variable_set(:@tiles, @tiles)
      @term.type('6 * ')
      expect(@term.wait_for('t> 6 * ')).to eq(true)
      out = StringIO.new
      $stdout = out
      begin
        Thread.new { MB::Sound::Internal.console_puts('dropout 1 at 12:00:00.000 (+0:01.000): 5.0 ms short') }.join
      ensure
        $stdout = STDOUT
      end
      expect(out.string).to eq('') # (not on the process's stdout)
      expect(@term.wait_for('dropout 1 at 12:00:00.000')).to eq(true)
      @term.type("7\r")
      expect(@term.wait_for('=> 42')).to eq(true)
      lines = @term.lines
      expect(lines.index { |l| l.include?('dropout 1 at') }).to be < lines.index { |l| l.include?('=> 42') }
    end
  end
end
