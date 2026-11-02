require 'timeout'
require_relative '../../../support/module_writer'

# When a foreground playback is over (play-ui-1: "bin/play.rb didn't exit
# after cry4bass.mod ended"): one rule for every kind of sound, which ends
# where the per-kind lambdas waited forever.
RSpec.describe(MB::Sound::PlaybackEnd, :aggregate_failures) do
  let(:w) { ModuleWriter }
  let(:out) { MB::Sound::NullOutput.new(channels: 2, sleep: :virtual) }

  before(:each) do
    ENV['OUTPUT_TYPE'] = 'null'
    MB::Sound.use_output(out)
  end

  after(:each) do
    MB::Sound::Session.default.close
    MB::Sound.use_output(nil)
    MB::Sound.rewind
    MB::Sound.bpm(120)
    ENV.delete('OUTPUT_TYPE')
  end

  # A two-pattern MOD of about 5 s.
  def module_path
    p0 = w.pattern(4, { [0, 0] => { note: 60, sample: 1 }, [16, 1] => { note: 64, sample: 1 } })
    p1 = w.pattern(4, { [0, 2] => { note: 67, sample: 1 } })
    w.mod(tmp_path('end.mod'), samples: [{ name: 'saw', data: w.saw(2000), loop: [1000, 2000] }], patterns: [p0, p1], orders: [0, 1])
  end

  # Plays +sound+ in the foreground, failing instead of hanging.
  def play_within(sound, seconds = 60)
    Timeout.timeout(seconds) { MB::Sound.play(sound, plot: false) }
  end

  it 'has a row for every state and event it moves on, and only known states' do
    expect(described_class::TABLE.keys.map(&:first) - described_class::STATES).to eq([])
    expect(described_class::TABLE.keys.map(&:last) - described_class::EVENTS).to eq([])
    expect(described_class::TABLE.values - described_class::STATES).to eq([])
  end

  it "ends a module whose last scene launch ran late (its cut skipped) after the tail, stopping what still plays" do
    stub_const('MB::Sound::PlaybackEnd::MAX_TAIL_SECONDS', 1)
    # (a scene launch that finishes after its time: the scheduler skips the
    # late block's commands, so :fin never cuts the looping tracks, and the
    # old rule waited for them forever)
    allow_any_instance_of(MB::Sound::Arrangement).to receive(:go).and_wrap_original { |m, name, *a, **kw|
      if name == :fin
        t = MB::U.clock_now
        Thread.pass while MB::U.clock_now - t < 1.5
      end
      m.call(name, *a, **kw)
    }
    expect { play_within(module_path) }.to output(/Playing.*stopped what still played after 1 s/m).to_stderr
    s = MB::Sound::Session.default
    MB::Sound::Internal.wait_audio(s, 0.05)
    expect(s.idle?).to eq(true)
  end

  it 'ends a playback whose form never started (its start block lost)' do
    stub_const('MB::Sound::PlaybackEnd::START_SECONDS', 1)
    allow_any_instance_of(MB::Sound::Form::Playback).to receive(:begin_first)
    expect { play_within(module_path) }.to output(/Playing/).to_stderr
  end

  it 'ends with a warning when the render thread stops with an error' do
    s = MB::Sound::Session.default
    graph = 220.hz.sine
    expect {
      MB::Sound.bg(:play, graph, fade: 0)
      ending = described_class.new(s, busy: -> { s.playing_after_queue?(:play) })
      allow(s).to receive(:process_buffer).and_raise(RuntimeError, 'boom')
      Timeout.timeout(20) { MB::Sound::Internal.wait_audio(s, 0.01) until ending.over? }
      expect(ending.state).to eq(:failed)
      expect(ending.reason).to include('RuntimeError: boom')
    }.to output(/Background session stopped with an error: RuntimeError: boom/).to_stderr
  end

  it 'ends as stalled when the output stops taking audio' do
    stub_const('MB::Sound::PlaybackEnd::STALL_SECONDS', 0.3)
    s = MB::Sound::Session.default
    MB::Sound.bg(:play, 220.hz.sine, fade: 0)
    clock = 0.0
    ending = described_class.new(s, busy: -> { true }, clock: -> { clock })
    MB::Sound::Internal.wait_audio(s, 0.05)
    expect(ending.check).to eq(:playing)
    # (nothing consumes: the render thread waits in its write)
    frames = s.frames_rendered
    clock = 1.0
    expect(ending.check).to eq(:stalled) if s.frames_rendered == frames
    expect(ending.reason).to include('took no audio')
  end

  it "doesn't count a pause as a stall" do
    stub_const('MB::Sound::PlaybackEnd::STALL_SECONDS', 0.3)
    s = MB::Sound::Session.default
    MB::Sound.bg(:play, 220.hz.sine, fade: 0)
    clock = 0.0
    ending = described_class.new(s, busy: -> { true }, clock: -> { clock })
    MB::Sound::Internal.wait_audio(s, 0.05)
    s.paused = true
    MB::Sound::Internal.wait_audio(s, 0.05)
    expect(ending.check).to eq(:playing)
    clock = 5.0
    expect(ending.check).to eq(:playing)
  ensure
    s&.paused = false
  end

  context 'at 512-frame buffers (a JACK period)' do
    let(:out) { MB::Sound::NullOutput.new(channels: 2, sleep: :virtual, buffer_size: 512) }

    # (the regression: the form's last block, for the end of the one-tick
    # :fin, runs ahead of its time; :fin's cut leaves nothing playing, so
    # the timeline stops inside the tick, before that time, and
    # Session#schedule_waiting? stays true: the old rule waited for it
    # forever, as bin/play.rb did after cry4bass.mod on JACK)
    it 'ends a module right after its last tick' do
      s = MB::Sound::Session.default
      expect { play_within(module_path) }.to output(/Playing/).to_stderr
      expect(s.schedule_waiting?(repeating: false)).to eq(true) # (what the old rule waited for)
      expect(s.idle?).to eq(true)
      set = MB::Sound.mod_import(module_path)
      expect(s.frames_rendered / 48000.0).to be < set.seconds + 1.0
    end
  end

  it 'ends a sound file and a MIDI file the same way (the sound ends, the playback ends)' do
    %w[spec/test_data/arp_a7.flac spec/test_data/c_major.mid].each do |f|
      expect { play_within(f) }.to output(/Playing/).to_stderr
      expect(MB::Sound.players).not_to have_key(:play)
    end
  end
end
