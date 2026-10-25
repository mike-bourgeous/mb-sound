# Underrun concealment (ext/mb/sound/fast_audio/mb_conceal.h): the C kernel
# on synthetic ring states against its Ruby reference, what it plays, and
# the Playback device path on miniaudio's null backend.
RSpec.describe('MB::Sound::FastAudio::Concealer', :aggregate_failures) do
  let(:rate) { 48000 }
  let(:conceal) { MB::Sound::Concealment }

  # A test signal: two detuned partials plus a little noise, per channel.
  def signal(start, n, channels)
    t = Numo::DFloat.new(n).seq(start)
    channels.times.map { |c|
      Numo::SFloat.cast(Numo::NMath.sin(t * (0.031 + 0.007 * c)) * 0.5 + Numo::NMath.sin(t * 0.1173) * 0.2 +
                        Numo::DFloat.new(n).rand(-0.05, 0.05))
    }
  end

  def interleave(chans)
    return '' if chans.empty? || chans[0].empty?
    m = Numo::SFloat.zeros(chans[0].length, chans.length)
    chans.each_with_index { |c, k| m[true, k] = c }
    m.to_binary
  end

  def deinterleave(str, frames, channels)
    m = Numo::SFloat.from_binary(str).reshape(frames, channels)
    channels.times.map { |k| m[true, k].dup }
  end

  # Runs +pulls+ ([count, frames, quiet] each) through the C kernel and the
  # reference, returning both outputs joined per channel.
  def run_both(settings, pulls, channels: 2, rate: self.rate)
    c = MB::Sound::FastAudio::Concealer.new(channels, rate, settings)
    r = conceal::Reference.new(channels, rate, settings)
    t = 0
    co = Array.new(channels) { [] }
    ro = Array.new(channels) { [] }
    pulls.each do |count, frames, quiet|
      real = count > 0 ? signal(t, count, channels) : []
      t += count
      cc = deinterleave(c.process(interleave(real), frames, quiet), frames, channels)
      rr = r.process(real, frames, quiet: quiet)
      channels.times { |k| co[k] << cc[k]; ro[k] << rr[k] }
    end
    expect(c.state).to eq(r.state)
    [co.map { |x| SpecBuffers.join(x) }, ro.map { |x| SpecBuffers.join(x) }, c]
  end

  # A stutter: steady pulls, a gap of +gap+ pulls, a short pull, more audio.
  def stutter(n, gaps: [[10, 6], [30, 1], [34, 20]], total: 70)
    pulls = Array.new(total) { [n, n, false] }
    gaps.each { |at, len| len.times { |i| pulls[at + i] = [0, n, false] } }
    pulls[gaps[0][0] + gaps[0][1]] = [n / 3, n, false] # audio back, short again
    pulls
  end

  describe 'C kernel against the Ruby reference' do
    {
      'repeat, 128-frame pulls' => [:repeat, 128, 2],
      'repeat, mono, 1024-frame pulls' => [:repeat, 1024, 1],
      'fixed grain' => [:fixed, 256, 2],
      'grain range override' => [{ grain: 0.005..0.012, history: 0.03, fade: 0.2 }, 64, 2],
    }.each do |name, (spec, n, ch)|
      it "plays the same samples (#{name})" do
        co, ro, = run_both(conceal.settings(spec), stutter(n), channels: ch)
        ch.times { |k| expect((co[k] - ro[k]).abs.max).to eq(0) }
        expect(co[0].abs.max).to be > 0.3
      end
    end

    it 'plays the same samples at 44.1 kHz with one-frame pulls over a gap edge' do
      pulls = Array.new(60) { [128, 128, false] } + Array.new(40) { [0, 1, false] } + Array.new(30) { [1, 1, false] }
      co, ro, = run_both(conceal.settings(:repeat), pulls, rate: 44100)
      2.times { |k| expect((co[k] - ro[k]).abs.max).to eq(0) }
    end

    it 'plays the same samples when the writer marked the end' do
      pulls = Array.new(40) { [256, 256, false] } + Array.new(3) { [0, 256, false] } + Array.new(10) { [0, 256, true] }
      co, ro, c = run_both(conceal.settings(:repeat), pulls)
      2.times { |k| expect((co[k] - ro[k]).abs.max).to eq(0) }
      expect(c.state[:faded]).to eq(true)
    end
  end

  describe 'concealment' do
    let(:n) { 128 }

    it 'fills a gap without a step, then plays the late audio from where it stopped' do
      settings = conceal.settings(:repeat)
      k = MB::Sound::FastAudio::Concealer.new(1, rate, settings)
      input = signal(0, 60 * n, 1)[0]
      out = []
      pos = 0
      60.times do |i|
        if (20...28).cover?(i)
          out << deinterleave(k.process('', n, false), n, 1)[0]
        else
          out << deinterleave(k.process(input[pos...(pos + n)].to_binary, n, false), n, 1)[0]
          pos += n
        end
      end
      out = SpecBuffers.join(out)

      gap = (20 * n)...(28 * n)
      expect(out[gap].abs.max).to be > 0.3
      # No step into the gap bigger than the signal's own steps
      steps = (out[1..] - out[0...-1]).abs
      expect(steps[(gap.begin - 1)..(gap.begin + 10)].max).to be < 1.5 * (input[1..] - input[0...-1]).abs.max

      # After the 5 ms return crossfade, the real audio continues exactly
      # where it stopped (late, not dropped)
      back = 28 * n + 240
      expect(out[back...(60 * n)]).to eq(input[(back - 8 * n)...(52 * n)])
      expect(k.state[:events]).to eq(1)
      expect(k.state[:frames]).to eq(8 * n)
    end

    it 'fades out over a long gap (-60 dB over :fade, then zeros)' do
      k = MB::Sound::FastAudio::Concealer.new(1, rate, conceal.settings(fade: 0.25))
      k.process(signal(0, 9600, 1)[0].to_binary, 9600, false)
      out = deinterleave(k.process('', rate / 2, false), rate / 2, 1)[0]
      first = out[0...2400].abs.max
      expect(first).to be > 0.3
      expect(out[(rate / 8)...(rate / 8 + 2400)].abs.max).to be_between(first * 10**(-36 / 20.0), first * 10**(-24 / 20.0))
      expect(out[(rate / 4 + 10)..].abs.max).to eq(0)
      expect(k.state[:faded]).to eq(true)
    end

    it 'leaves the gap silent with :silence, after an end mark, or without enough history' do
      k = MB::Sound::FastAudio::Concealer.new(1, rate, conceal.settings(:silence))
      k.process(signal(0, 9600, 1)[0].to_binary, 9600, false)
      expect(deinterleave(k.process('', 512, false), 512, 1)[0].abs.max).to eq(0)

      k = MB::Sound::FastAudio::Concealer.new(1, rate, conceal.settings(:repeat))
      k.process(signal(0, 9600, 1)[0].to_binary, 9600, false)
      expect(deinterleave(k.process('', 512, true), 512, 1)[0].abs.max).to eq(0)

      k = MB::Sound::FastAudio::Concealer.new(1, rate, conceal.settings(:repeat))
      k.process(signal(0, 500, 1)[0].to_binary, 500, false)
      expect(deinterleave(k.process('', 512, false), 512, 1)[0].abs.max).to eq(0)
      expect(k.state[:events]).to eq(0)
    end

    it 'fades a running concealment out quickly once the writer marks the end' do
      k = MB::Sound::FastAudio::Concealer.new(1, rate, conceal.settings(:repeat))
      k.process(signal(0, 9600, 1)[0].to_binary, 9600, false)
      k.process('', 256, false)
      out = deinterleave(k.process('', 2400, true), 2400, 1)[0]
      expect(out[0...64].abs.max).to be > 0.1
      expect(out[1000..].abs.max).to eq(0) # 20 ms to -60 dB
    end
  end

  describe 'repetition' do
    # White noise history, a 0.7 s gap without decay: a fixed grain of L
    # frames with L/2-frame seams starts every L/2 frames, so the output has
    # that period (a comb of peaks at rate / (L/2) and its harmonics);
    # jittered grains have none.
    def concealed_noise(spec)
      settings = conceal.settings(spec.merge(fade: nil))
      k = MB::Sound::FastAudio::Concealer.new(1, rate, settings)
      MB::Sound.with_seed(5) {
        noise = Numo::SFloat.new(9600).rand(-0.5, 0.5)
        k.process(noise.to_binary, 9600, false)
      }
      deinterleave(k.process('', 32768, false), 32768, 1)[0]
    end

    # Power at the harmonics k * f0 (k = 2..20; the most of the 3 nearest
    # bins) over power halfway between them (measured the same way), in dB:
    # about 0 for a spectrum without a comb.
    def comb_db(x, f0)
      spec = Numo::Pocketfft.rfft(Numo::DFloat.cast(x).dup).abs**2
      bin = f0 * x.length / rate.to_f
      near = ->(f) { spec[((f * bin).round - 1)..((f * bin).round + 1)].max }
      peaks = (2..20).sum { |h| near.(h) }
      between = (2..20).sum { |h| near.(h + 0.5) }
      10 * Math.log10(peaks / between)
    end

    def autocorrelation(x, lag)
      a = Numo::DFloat.cast(x)
      (a[lag..] * a[0...-lag]).sum / (a * a).sum
    end

    it 'has no peaks at rate / grain length, unlike a fixed grain' do
      fixed = concealed_noise(mode: :fixed, grain: 0.03)
      jittered = concealed_noise(mode: :repeat)
      period = (0.03 * rate).round / 2 # a fixed grain's loop period (L - L/2)

      expect(comb_db(fixed, rate.to_f / period)).to be > 10
      expect(autocorrelation(fixed, period)).to be > 0.5
      expect(comb_db(jittered, rate.to_f / period).abs).to be < 3
      [480, 960, 1440, 1920, 2880].each do |lag|
        expect(autocorrelation(jittered, lag).abs).to be < 0.15
      end
    end
  end

  describe 'Playback (null backend)' do
    def playback(conceal_settings, capture: 48000)
      MB::Sound::FastAudio::Playback.new(
        [:null], -1, 'mb-sound-spec', 1, 1, rate, 0, 0, 4096, capture, 2, false, 0, nil, conceal_settings
      ).tap { |p| @playbacks << p }
    end

    def wait_until(timeout: 3)
      deadline = MB::U.clock_now + timeout
      sleep 0.005 until yield || MB::U.clock_now > deadline
    end

    before { @playbacks = [] }
    after { @playbacks.each(&:close) }

    def captured(pb)
      x = Numo::SFloat.from_binary(pb.captured)
      start = (0...x.length).find { |i| x[i] != 0 }
      x[start..]
    end

    it 'conceals a gap, counts it as an underrun, and plays the late audio after it' do
      pb = playback(conceal.settings(:repeat))
      a = signal(0, 4800, 1)[0]
      b = signal(4800, 4800, 1)[0]
      pb.write([a])
      wait_until { pb.stats[:concealed] >= 4800 }
      pb.write([b])
      wait_until { pb.stats[:queued] == 0 && pb.stats[:concealed_gaps] >= 2 }
      pb.end_stream

      x = captured(pb)
      stats = pb.stats
      expect(stats[:underruns]).to eq(2)
      expect(stats[:concealed_gaps]).to eq(2)
      expect(x[0...4800]).to eq(a)
      gap = stats[:frames_played] # (any gap length; find b after it)
      expect(x[4800...9600].abs.max).to be > 0.3
      found = (4800...(x.length - 4800)).find { |i| x[i + 300] == b[300] && x[(i + 300)...(i + 4800)] == b[300..] }
      expect(found).not_to be_nil, "b not found in #{gap} frames played"
    end

    it 'plays silence after the audio with :silence and after end_stream' do
      [[conceal.settings(:silence), false], [conceal.settings(:repeat), true]].each do |settings, mark|
        pb = playback(settings, capture: 24000)
        pb.write([signal(0, 2400, 1)[0]])
        pb.end_stream if mark
        wait_until { pb.stats[:queued] == 0 }
        wait_until { pb.captured.bytesize >= 24000 * 4 }
        x = captured(pb)
        expect(x[2400..].abs.max).to eq(0)
        expect(pb.stats[:concealed]).to eq(0)
        expect(pb.stats[:underruns]).to eq(1)
      end
    end
  end
end
