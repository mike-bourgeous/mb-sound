require 'timeout'
require_relative '../../../support/module_writer'

# bin/play.rb's player (play-ui-1): files of every kind end by one rule, and
# the keys' actions (seek, sections, pause, volume, next/previous) land
# where they should.
RSpec.describe(MB::Sound::Player, :aggregate_failures) do
  let(:w) { ModuleWriter }

  # Virtual-clock outputs that keep what they're given (channel 0), one per
  # file.
  let(:outputs) { [] }
  let(:audio) {
    -> {
      Class.new(MB::Sound::NullOutput) {
        def written = @written ||= []
        def write(data)
          written << data[0].dup
          super
        end
        def mono = SpecBuffers.join(written)
      }.new(channels: 2, sleep: :virtual, buffer_size: 256).tap { |o| outputs << o }
    }
  }
  let(:err) { StringIO.new }

  before { ENV['OUTPUT_TYPE'] = 'null' }

  after do
    MB::Sound::Session.default.close
    MB::Sound.use_output(nil)
    MB::Sound::Session.monitor_gain = 1.0
    MB::Sound.rewind
    MB::Sound.bpm(120)
    ENV.delete('OUTPUT_TYPE')
  end

  # A ramp of +seconds+ with no repeated values (so a sample says where in
  # the file it came from), as a stereo FLAC.
  def ramp_file(seconds = 12)
    n = (48000 * seconds).round
    x = (Numo::SFloat.new(n).seq + 1) / (n + 1) * 0.9
    path = tmp_path('ramp.flac')
    MB::Sound.write(path, [x, x], sample_rate: 48000)
    path
  end

  def module_path
    p0 = w.pattern(4, { [0, 0] => { note: 60, sample: 1 }, [16, 1] => { note: 64, sample: 1 } })
    p1 = w.pattern(4, { [0, 2] => { note: 67, sample: 1 } })
    w.mod(tmp_path('player.mod'), samples: [{ name: 'saw', data: w.saw(2000), loop: [1000, 2000] }], patterns: [p0, p1], orders: [0, 1])
  end

  def player(paths, **opts) = described_class.new(paths, ui: false, err: err, audio: audio, **opts)

  # Runs +pl+ on a thread; yields it once its first file plays; returns
  # what #run returned.
  def run_player(pl, seconds = 60)
    th = Thread.new { pl.run }
    th.report_on_exception = false
    Timeout.timeout(seconds) {
      Thread.pass until pl.state == :playing || !th.alive?
      yield pl if block_given? && th.alive?
      th.value
    }
  ensure
    th&.kill if th&.alive?
  end

  # Waits for the player's thread to act on what was queued (the virtual
  # clock moves while it waits for its file).
  def settle(pl, seconds = 0.05)
    Timeout.timeout(10) { Thread.pass until pl.instance_variable_get(:@actions).empty? && pl.acted == @queued }
    MB::Sound::Internal.wait_audio(pl.session, seconds)
  end

  # Queues +action+ (counting it for #settle).
  def act(pl, action, times = 1)
    @queued = @queued.to_i + times
    times.times { pl.act(action) }
  end

  it 'picks an item by file type' do
    expect(described_class::Item.for('a.flac')).to be_a(described_class::AudioItem)
    expect(described_class::Item.for('a.MID')).to be_a(described_class::MidiItem)
    expect(described_class::Item.for(module_path)).to be_a(described_class::ModuleItem)
    expect(described_class::Item.for('a.sfz')).to be_a(described_class::OtherItem)
  end

  it 'plays a sound file, a MIDI file, and a module to their ends, one after another' do
    files = ['spec/test_data/arp_a7.flac', 'spec/test_data/c_major.mid', module_path]
    expect(run_player(player(files))).to eq(3)
    expect(MB::U.remove_ansi(err.string).scan(/Playing (\S+)/).flatten).to eq(%w[arp_a7.flac c_major.mid player.mod])
    expect(outputs.length).to eq(3) # (a fresh Session each)
  end

  it 'says which files it could not play and goes on' do
    expect(run_player(player(['nope.flac', 'spec/test_data/arp_a7.flac']))).to eq(1)
    expect(err.string).to match(/Can't play nope\.flac/)
  end

  it 'seeks a sound file forward and back, landing on exact samples after a 5 ms crossfade' do
    path = ramp_file
    pl = player([path])
    run_player(pl) do
      MB::Sound::Internal.wait_audio(pl.session, 1.0)
      act(pl, :seek_forward)
      settle(pl, 1.0)
      expect(pl.said[0]).to match(/forward to 0:0[67]/)
      act(pl, :quit)
    end
    data = pl.items[0].instance_variable_get(:@data) || MB::Sound.read(path)[0]
    data = data.is_a?(Array) ? data[0] : data
    o = outputs[0].mono
    # The output is the file in two runs: from its start, then from 5 s
    # further on, with a crossfade of at most 5 ms between them
    first = o.to_a.index { |v| v > 0 }
    expect(o[first]).to eq(data[0])
    jumps = (o.diff.abs > 1e-4).where.to_a.select { |i| i > first }
    expect(jumps).not_to be_empty
    seam = jumps.first
    run_from = seam + 300 # past the crossfade
    k = data.to_a.index(o[run_from]) # (the ramp: every value once)
    expect(k).not_to be_nil
    span = [o.length - run_from, 20_000].min
    expect(o[run_from...(run_from + span)]).to eq(data[k...(k + span)])
    delta = k - (run_from - first)
    expect(delta).to be_within(256 * 2).of(5 * 48000)
    expect(jumps.last - seam).to be < 240 + 2
  end

  it 'steps a module by sections and bars on its timeline (Session#seek)' do
    pl = player([module_path])
    run_player(pl) do
      item = pl.item
      starts = item.sections.map(&:first)
      MB::Sound::Internal.wait_audio(pl.session, 0.5)
      act(pl, :jump_forward)
      settle(pl)
      expect(pl.said[0]).to start_with('p01')
      expect(pl.session.transport.position).to be >= starts[1]
      expect(pl.session.transport.position).to be < starts[1] + 1/4r
      act(pl, :jump_back) # (within a second of p01's start: back to p00)
      settle(pl)
      expect(pl.said[0]).to start_with('p00')
      expect(pl.session.transport.position).to be < 1/4r
      act(pl, :seek_forward)
      settle(pl)
      expect(pl.said[0]).to eq('bar 2')
      act(pl, :quit)
    end
  end

  it 'pauses and plays on (frames held while paused), turns the volume, and stops at 0 dB' do
    pl = player([ramp_file])
    run_player(pl) do
      s = pl.session
      MB::Sound::Internal.wait_audio(s, 0.2)
      act(pl, :pause)
      settle(pl, 0.1)
      held = s.frames_rendered
      MB::Sound::Internal.wait_audio(s, 0.2)
      expect([pl.state, s.paused?, s.frames_rendered]).to eq([:paused, true, held])
      act(pl, :pause)
      settle(pl, 0.1)
      expect(s.frames_rendered).to be > held
      expect(pl.state).to eq(:playing)

      act(pl, :volume_up)
      settle(pl)
      expect(pl.said[0]).to match(/0 dB is the top/)
      act(pl, :volume_down)
      settle(pl)
      expect(pl.said[0]).to eq('volume -2 dB')
      expect(MB::Sound::Session.monitor_gain).to be_within(1e-9).of(10**(-2 / 20.0))
      act(pl, :volume_down, 40)
      settle(pl)
      expect(pl.said[0]).to eq('volume muted')
      expect(MB::Sound::Session.monitor_gain).to eq(0.0)
      act(pl, :volume_up)
      settle(pl)
      expect(pl.said[0]).to eq('volume -60 dB')
      act(pl, :quit)
    end
  end

  it 'moves to the next and previous files (p restarts first, then goes back)' do
    path = ramp_file(30)
    pl = player([path, 'spec/test_data/arp_a7.flac'])
    run_player(pl) do
      act(pl, :next_item)
      Timeout.timeout(20) { Thread.pass until pl.index == 1 && pl.state == :playing }
      act(pl, :prev_item)
      Timeout.timeout(20) { Thread.pass until pl.index == 0 && pl.state == :playing }
      MB::Sound::Internal.wait_audio(pl.session, 4.0)
      act(pl, :prev_item)
      settle(pl)
      expect(pl.said[0]).to eq('from the start')
      expect(pl.index).to eq(0)
      act(pl, :quit)
    end
  end

  it 'seeks a MIDI file by rebuilding its synth from the new position' do
    pl = player(['spec/test_data/c_major.mid'])
    run_player(pl) do
      MB::Sound::Internal.wait_audio(pl.session, 0.5)
      act(pl, :seek_forward)
      settle(pl, 0.2)
      expect(pl.said[0]).to match(/forward to 0:05/)
      expect(pl.position).to be_within(0.5).of(5.7)
      act(pl, :quit)
    end
  end

  it "binds the player screen's keys only to its actions and ? to the key list" do
    actions = MB::Sound::UI::Keys::PLAYER_SCREEN.entries.map(&:action).uniq
    expect(actions.sort).to eq((described_class::ACTIONS + [:help]).sort)
  end
end
