RSpec.describe(MB::Sound::Sequence::TempoNode) do
  # 120 BPM at 48kHz: a bar is 96000 frames.
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:output) { MB::Sound::NullOutput.new(channels: 2, sleep: false) }
  let(:session) { MB::Sound::Session.new(master_gain: 1, output: output, transport: transport, buffer_size: 800, realtime: false, raise_errors: true) }

  after { session.close }

  # Renders +frames+ frames (in 800-frame buffers) and returns channel 0.
  def run(frames)
    Array.new(frames / 800) { session.process_buffer[0].dup }.reduce(:concatenate)
  end

  describe 'modes' do
    it 'outputs the frequency or length of a duration at the current tempo' do
      hz = described_class.new(1.bar, mode: :hz, transport: transport)
      seconds = described_class.new(3.n16, mode: :seconds, transport: transport)
      expect(hz.sample(4).to_a).to eq([0.5] * 4)
      expect(seconds.value).to eq(0.375)

      transport.bpm = 60
      expect(hz.sample(4)[0]).to eq(0.25)
      expect(seconds.value).to eq(0.75)
    end

    it 'rejects unknown modes and empty durations' do
      expect { described_class.new(1.bar, mode: :bpm) }.to raise_error(ArgumentError, /Mode/)
      expect { described_class.new(0.bars, mode: :hz) }.to raise_error(ArgumentError, /longer than zero/)
      expect { described_class.new(4, mode: :hz) }.to raise_error(ArgumentError, /Duration/)
    end
  end

  describe 'Duration#lfo' do
    it 'makes a full-range LFO that plays forever and is not retriggered' do
      lfo = 1.bar.lfo
      expect(lfo).to be_a(MB::Sound::Tone)
      expect(lfo.lfo?).to eq(true)
      expect(lfo.range).to eq(-1.0..1.0)
    end

    it 'locks its phase to the timeline through tempo changes and seeks' do
      session.add(1.bar.lfo.ramp)
      data = run(192000)
      expect([0, 24000, 48000, 96000, 120000].map { |i| data[i].round(3) }).to eq([0, 0.5, 1, 0, 0.5])

      transport.bpm = 60 # a bar is now 192000 frames
      data = run(192000)
      expect([0, 48000, 191999].map { |i| data[i].round(3) }).to eq([0, 0.5, 0])

      transport.seek(3/4r)
      expect(run(800)[0].round(3)).to eq(-0.5)
    end

    it 'starts in phase with the timeline wherever the graph starts' do
      session.add(0.constant)
      run(4000)
      session.add(1.bar.lfo.ramp, at: :beat) # starts a quarter of the way through the bar
      data = run(24000)
      expect(data[24000 - 4000].round(3)).to eq(0.5)
    end

    it 'adds the phase offset from with_phase' do
      session.add(1.bar.lfo.ramp.with_phase(Math::PI / 2))
      expect(run(800)[0].round(3)).to eq(0.5)
    end

    it 'supports the other Tone methods' do
      session.add(1.bar.lfo.square.at(2..4))
      data = run(96000)
      expect(data[100]).to eq(4)
      expect(data[48100]).to eq(2)
    end

    it 'follows the render transport' do
      MB::Sound.render(tmp_path('tempo_lfo_spec.flac'), 1.bar.lfo.ramp, seconds: 1, bpm: 240, overwrite: true, gain: 1)
      data = MB::Sound.read(tmp_path('tempo_lfo_spec.flac'))[0]
      expect(data[12000]).to be_within(0.01).of(0.5) # a bar is one second at 240 BPM
    end
  end

  describe 'pauses' do
    it 'freezes an LFO in a master chain while the timeline is paused, then resyncs' do
      session.add(0.constant.until(800 / 48000.0))
      session.master { |mix| mix + 1.bar.lfo.ramp }
      run(1600) # the player ends and the timeline pauses at 800 frames
      frozen = run(4800)
      expect(frozen.to_a.uniq.length).to eq(1)

      session.add(0.constant)
      expect(run(800)[0].round(4)).to eq((1600.0 / 96000 * 2).round(4))
    end

    it 'lets a freewheeling LFO keep running while paused' do
      session.master { |mix| mix + 1.bar.lfo.ramp.freewheel }
      data = run(4800)
      expect(data[4799]).to be > data[0]
    end
  end

  it 'only allows tempo-synced tones to freewheel' do
    expect { 2.hz.freewheel }.to raise_error(ArgumentError, /tempo-synced/)
  end
end

RSpec.describe(MB::Sound::Tone) do
  describe '#lfo' do
    it 'defaults to full range without overriding explicit settings' do
      t = 2.hz.lfo
      expect(t.lfo?).to eq(true)
      expect(t.range).to eq(-1.0..1.0)

      t = 2.hz.at(0..3).lfo
      expect(t.range).to eq(0.0..3.0)

      expect(2.hz.lfo.at(5..6).range).to eq(5.0..6.0)
    end
  end
end
