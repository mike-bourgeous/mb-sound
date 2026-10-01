RSpec.describe('Tempo-synced delays') do
  # 120 BPM at 48kHz: a bar is 96000 frames, a sixteenth note 6000.
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:output) { MB::Sound::NullOutput.new(channels: 2, sleep: false) }
  let(:session) { MB::Sound::Session.new(master_gain: 1, output: output, transport: transport, buffer_size: 800, realtime: false, raise_errors: true) }

  # An impulse at the start of every bar.
  let(:bar_clicks) { MB::Sound.grid(1, 'x').loop.trigger }

  after { session.close }

  # Renders +frames+ frames (in 800-frame buffers) and returns channel 0.
  def run(frames)
    Array.new(frames / 800) { session.process_buffer[0].dup }.reduce(:concatenate)
  end

  def clicks(data)
    data.to_a.each_index.select { |i| data[i] != 0 }
  end

  describe 'GraphNode#delay' do
    it 'accepts a Duration as the delay time, following the tempo' do
      session.add(bar_clicks.delay(3.n16, smoothing: false))
      expect(clicks(run(192000))).to eq([18000, 96000 + 18000])

      transport.bpm = 60 # 3/16 is now 36000 frames, a bar 192000
      expect(clicks(run(192000))).to eq([36000])
    end

    it 'accepts a Duration for seconds:' do
      session.add(bar_clicks.delay(seconds: 1.n8.dotted, smoothing: false))
      expect(clicks(run(96000))).to eq([18000])
    end

    it 'treats plain numbers as seconds' do
      session.add(bar_clicks.delay(0.25, smoothing: false))
      expect(clicks(run(96000))).to eq([12000])
    end

    it 'starts at its tempo-synced time, then glides after a tempo change by default' do
      node = bar_clicks.delay(1.n8)
      delay = node.base_filter
      session.add(node)
      run(9600)
      expect(delay.last_delay_samples).to eq(12000)

      transport.bpm = 60
      run(800)
      expect(delay.last_delay_samples).to be_between(12000, 24000).exclusive
    end

    it 'starts at the tempo of the session playing it' do
      node = bar_clicks.delay(1.n8)
      transport.bpm = 60
      session.add(node)
      run(800)
      expect(node.base_filter.last_delay_samples).to eq(24000)
    end

    it 'alternates between lengths with a square LFO over a range of Durations' do
      session.add(bar_clicks.delay(2.bars.lfo.square.at(3.n16..5.n16), smoothing: false))
      starts = clicks(run(96000 * 4)).map { |i| i % 96000 }
      expect(starts).to eq([30000, 18000, 30000, 18000]) # a square wave starts at the top of its range
    end

    it 'sizes buffers for slow tempos' do
      node = 1.constant.delay(1.bar)
      delay = node.base_filter
      expect(delay.delay_buffer_size).to be >= 6 * 48000 # one bar at 40 BPM is 6 seconds
    end

    it 'rejects more than one delay time' do
      expect { 1.constant.delay(1.n8, seconds: 1) }.to raise_error(ArgumentError, /not more than one/)
    end
  end

  describe 'Duration#delay' do
    it 'builds a tempo-synced delay filter for GraphNode#filter' do
      session.add(bar_clicks.filter(3.n16.delay(smoothing: false)))
      expect(clicks(run(96000))).to eq([18000])
    end
  end

  describe 'GraphNode#multitap' do
    it 'accepts Durations and is also available as multitap_delay' do
      l, r = bar_clicks.multitap_delay(1.n8.dotted, 0.25)
      session.add([l, r])
      data = Array.new(120) { session.process_buffer.map(&:dup) }.transpose.map { |c| c.reduce(:concatenate) }
      expect(clicks(data[0])).to eq([18000])
      expect(clicks(data[1])).to eq([12000])
    end
  end

  describe 'Tone#at with Durations' do
    it 'marks the tone as musical time' do
      expect(1.bar.lfo.at(3.n16..5.n16)).to be_musical_time
      expect(1.bar.lfo.at(0..1)).not_to be_musical_time
    end

    it 'rejects single Durations and mixed ranges' do
      expect { 1.bar.lfo.at(3.n16) }.to raise_error(ArgumentError, /Range of Durations/)
      expect { 1.bar.lfo.at(3.n16..1) }.to raise_error(ArgumentError, /Both ends/)
    end
  end
end
