# Underrun concealment (ext/mb/sound/fast_audio/mb_conceal.h): the C kernel
# on synthetic ring states against its Ruby reference, what it plays, and
# the Playback device path on miniaudio's null backend.
require_relative '../../../support/device_capture'

RSpec.describe('MB::Sound::FastAudio::Concealer', :aggregate_failures) do
  # The C kernel and the Ruby reference run the same operations in the same
  # order (float32 history and output, double arithmetic), so they agree to
  # within float32 rounding; measured identical on x86-64 (GCC, no FMA
  # contraction by default).  A compiler that contracts multiply-adds may
  # differ by a rounding step, well under this tolerance.
  def mirror_tolerance = 1e-6

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

  # Runs +pulls+ ([queued, frames, quiet] each: frames the writer adds to
  # the queue, then one device pull) through the C kernel and the
  # reference, checking that they take the same frames, and returns both
  # outputs joined per channel.
  def run_both(settings, pulls, channels: 2, rate: self.rate)
    c = MB::Sound::FastAudio::Concealer.new(channels, rate, settings)
    r = conceal::Reference.new(channels, rate, settings)
    t = 0
    queue = Array.new(channels) { Numo::SFloat[] }
    co = Array.new(channels) { [] }
    ro = Array.new(channels) { [] }
    pulls.each do |add, frames, quiet|
      if add > 0
        sig = signal(t, add, channels)
        t += add
        queue = queue.zip(sig).map { |q, x| SpecBuffers.join([q, x]) }
      end
      cs, ct = c.pull(interleave(queue), frames, quiet)
      rr, rt = r.pull(queue, frames, quiet: quiet)
      expect(ct).to eq(rt)
      queue = queue.map { |q| rest(q, ct) }
      cc = deinterleave(cs, frames, channels)
      channels.times { |k| co[k] << cc[k]; ro[k] << rr[k] }
    end
    cs = c.state
    rs = r.state
    expect(cs.except(:gain)).to eq(rs.except(:gain))
    expect(cs[:gain]).to be_within(mirror_tolerance).of(rs[:gain])
    [co.map { |x| SpecBuffers.join(x) }, ro.map { |x| SpecBuffers.join(x) }, c]
  end

  # A stutter: steady pulls, gaps (nothing queued for +len+ pulls), a short
  # delivery after the first, more audio.
  def stutter(n, gaps: [[10, 6], [30, 1], [34, 20]], total: 70)
    pulls = Array.new(total) { [n, n, false] }
    gaps.each { |at, len| len.times { |i| pulls[at + i] = [0, n, false] } }
    pulls[gaps[0][0] + gaps[0][1]] = [n / 3, n, false] # audio back, short again
    pulls
  end

  # +x+ from +i+ on (empty at its end; Numo raises for x[x.length..]).
  def rest(x, i) = i < x.length ? x[i..].dup : Numo::SFloat[]

  # Fills +k+'s history with +x+ (one channel) in one pull.
  def feed(k, x)
    k.pull(x.to_binary, x.length, false)
  end

  # One pull of +n+ frames with nothing queued; returns the mono output.
  def dry(k, n, quiet = false)
    deinterleave(k.pull('', n, quiet)[0], n, 1)[0]
  end

  describe 'C kernel against the Ruby reference' do
    {
      'repeat, 128-frame pulls' => [:repeat, 128, 2],
      'repeat, mono, 1024-frame pulls' => [:repeat, 1024, 1],
      'fixed grain' => [:fixed, 256, 2],
      'grain range override' => [{ grain: 0.005..0.012, history: 0.03, fade: 0.2, return_fade: 0.004 }, 64, 2],
      'hold before the decay' => [{ hold: 0.03, fade: 0.1 }, 128, 2],
      'no alignment or level cap' => [{ align: 0, level: nil }, 128, 2],
    }.each do |name, (spec, n, ch)|
      it "plays the same samples (#{name})" do
        co, ro, = run_both(conceal.settings(spec), stutter(n), channels: ch)
        ch.times { |k| expect((co[k] - ro[k]).abs.max).to be <= mirror_tolerance }
        expect(co[0].abs.max).to be > 0.3
      end
    end

    it 'plays the same samples at 44.1 kHz with one-frame pulls over a gap edge' do
      pulls = Array.new(60) { [128, 128, false] } + Array.new(40) { [0, 1, false] } + Array.new(3000) { [1, 1, false] }
      co, ro, c = run_both(conceal.settings(:repeat), pulls, rate: 44100)
      2.times { |k| expect((co[k] - ro[k]).abs.max).to be <= mirror_tolerance }
      expect(c.state[:active]).to eq(false)
    end

    it 'plays the same samples when the writer marked the end' do
      pulls = Array.new(40) { [256, 256, false] } + Array.new(3) { [0, 256, false] } + Array.new(10) { [0, 256, true] }
      co, ro, c = run_both(conceal.settings(:repeat), pulls)
      2.times { |k| expect((co[k] - ro[k]).abs.max).to be <= mirror_tolerance }
      expect(c.state[:faded]).to eq(true)
    end

    it 'plays the same samples landing from silence, mid-seam, and on a grain that reaches the gap' do
      # Long gaps fade to zeros; short ones land wherever the grains are
      pulls = Array.new(40) { [128, 128, false] } + Array.new(70) { [0, 512, false] } + [[64, 128, false]] +
              Array.new(30) { [128, 128, false] } + (0...24).flat_map { |i| [[0, 128, false]] * (i % 5) + [[100, 128, false]] } +
              Array.new(20) { [128, 128, false] }
      co, ro, = run_both(conceal.settings(:repeat), pulls)
      2.times { |k| expect((co[k] - ro[k]).abs.max).to be <= mirror_tolerance }
    end
  end

  describe 'concealment' do
    let(:n) { 128 }

    it 'fills a gap without a step, then lands on the late audio and plays it from where it stopped' do
      settings = conceal.settings(:repeat)
      k = MB::Sound::FastAudio::Concealer.new(1, rate, settings)
      input = signal(0, 60 * n, 1)[0]
      out = []
      pos = 0
      queued = 0
      60.times do |i|
        queued = [queued + n, 60 * n - pos].min unless (20...28).cover?(i)
        played, taken = k.pull(input[pos...(pos + queued)].to_binary, n, false)
        out << deinterleave(played, n, 1)[0]
        pos += taken
        queued -= taken
      end
      until pos == input.length
        played, taken = k.pull(rest(input, pos).to_binary, n, false)
        out << deinterleave(played, n, 1)[0]
        pos += taken
      end
      out = SpecBuffers.join(out)

      gap = (20 * n)...(28 * n)
      expect(out[gap].abs.max).to be > 0.3
      # No step into the gap bigger than the signal's own steps
      steps = (out[1..] - out[0...-1]).abs
      expect(steps[(gap.begin - 1)..(gap.begin + 10)].max).to be < 1.5 * (input[1..] - input[0...-1]).abs.max

      # The landing ends on the last frame before the gap, and the late
      # audio continues it exactly (late, not dropped): 5 ms into a last
      # grain of 5-17 ms, at most after a running seam
      t0 = 20 * n
      back = (gap.end..(out.length - 2400)).find { |i| out[i...(i + 2400)] == input[t0...(t0 + 2400)] }
      expect(back).not_to be_nil
      expect(back - gap.end).to be_between(240, 2880)
      expect(out[back - 1]).to eq(input[t0 - 1])
      expect(out[back...(back + input.length - t0)]).to eq(input[t0..])
      expect(k.state[:events]).to eq(2) # (and a gap after the input's end)
    end

    it 'fades out over a long gap (-60 dB over :fade, then zeros)' do
      k = MB::Sound::FastAudio::Concealer.new(1, rate, conceal.settings(hold: 0, fade: 0.25))
      feed(k, signal(0, 9600, 1)[0])
      out = dry(k, rate / 2)
      first = out[0...2400].abs.max
      expect(first).to be > 0.3
      expect(out[(rate / 8)...(rate / 8 + 2400)].abs.max).to be_between(first * 10**(-36 / 20.0), first * 10**(-24 / 20.0))
      expect(out[(rate / 4 + 10)..].abs.max).to eq(0)
      expect(k.state[:faded]).to eq(true)
    end

    it 'fades back in from silence when audio arrives after a faded gap' do
      k = MB::Sound::FastAudio::Concealer.new(1, rate, conceal.settings(hold: 0, fade: 0.25))
      x = signal(0, 9600 + 4800, 1)[0]
      feed(k, x[0...9600])
      dry(k, rate / 2)
      out = []
      q = x[9600..]
      until q.empty?
        played, taken = k.pull(q.to_binary, n, false)
        out << deinterleave(played, n, 1)[0]
        q = rest(q, taken)
      end
      out = SpecBuffers.join(out)
      # From (almost) zero, no step, to the late audio at full level
      expect(out[0].abs).to be < 0.01
      back = (0..(out.length - 4800)).find { |i| out[i...(i + 4800)] == x[9600..] }
      expect(back).to be_between(240, 2880)
      expect((out[1...back] - out[0...(back - 1)]).abs.max).to be < 1.5 * (x[1..] - x[0...-1]).abs.max
    end

    it 'holds full level for :hold, then falls 60 dB over :fade' do
      k = MB::Sound::FastAudio::Concealer.new(1, rate, conceal.settings(hold: 0.1, fade: 0.25))
      feed(k, signal(0, 9600, 1)[0])
      out = dry(k, rate / 2)
      first = out[0...2400].abs.max
      expect(first).to be > 0.3
      # Still at full level just before the hold ends (the grains' own
      # level varies, so compare with the signal's peak)
      expect(out[(rate / 10 - 2400)...(rate / 10)].abs.max).to be > 0.3
      # Half the fade after the hold: -30 dB
      half = rate / 10 + rate / 8
      expect(out[half...(half + 2400)].abs.max).to be_between(first * 10**(-36 / 20.0), first * 10**(-24 / 20.0))
      expect(out[(rate / 10 + rate / 4 + 10)..].abs.max).to eq(0)
    end

    it 'skips the hold once the writer marks the end' do
      k = MB::Sound::FastAudio::Concealer.new(1, rate, conceal.settings(:repeat).merge(hold: 0.5))
      feed(k, signal(0, 9600, 1)[0])
      dry(k, 256)
      out = dry(k, 2400, true)
      expect(out[1000..].abs.max).to eq(0)
    end

    it 'leaves the gap silent with :silence, after an end mark, or without enough history' do
      k = MB::Sound::FastAudio::Concealer.new(1, rate, conceal.settings(:silence))
      feed(k, signal(0, 9600, 1)[0])
      expect(dry(k, 512).abs.max).to eq(0)

      k = MB::Sound::FastAudio::Concealer.new(1, rate, conceal.settings(:repeat))
      feed(k, signal(0, 9600, 1)[0])
      expect(dry(k, 512, true).abs.max).to eq(0)

      k = MB::Sound::FastAudio::Concealer.new(1, rate, conceal.settings(:repeat))
      feed(k, signal(0, 500, 1)[0])
      expect(dry(k, 512).abs.max).to eq(0)
      expect(k.state[:events]).to eq(0)
    end

    it 'fades a running concealment out quickly once the writer marks the end' do
      k = MB::Sound::FastAudio::Concealer.new(1, rate, conceal.settings(:repeat))
      feed(k, signal(0, 9600, 1)[0])
      dry(k, 256)
      out = dry(k, 2400, true)
      expect(out[0...64].abs.max).to be > 0.1
      expect(out[1000..].abs.max).to eq(0) # 20 ms to -60 dB
    end
  end

  # The maintainer's pops and chirps (audio-safety-2, 2026-11-01): returns
  # cut short by the queue running dry again stepped by the real audio's
  # level, grains of tones crossed out of phase (beating, swelling into the
  # peak clip, and a phase sweep: a chirp), the crossfade back met the late
  # audio at an unrelated phase, and drum hits filled quiet gaps.  The
  # guard: tones, a pad, drums, noise, and clipped audio through single
  # gaps, partial pulls, bursts, and stutters (shorter than :hold, so the
  # fill's level is the grains' own), measured against the source around
  # the gap.  A fill must not be louder than the audio it stands in for
  # (peak at most peak_db over, and 5 ms RMS within level_db of the 40 ms
  # around the gap), nor have a corner much sharper than the source's
  # sharpest within 120 ms (the largest |second difference|, within
  # click_db), tones keep their shape (a sine fit to every 5 ms window
  # leaves tone_db or less), and the late audio after the landing is the
  # source's, sample for sample.  Measured before the fix (the old kernel,
  # these patterns): corners up to 48 dB sharper on a 440 Hz sine, 76 dB on
  # 80 Hz, 21 dB on the pad; tone residuals -0.1 to -10 dB; drum fills
  # 11 dB over the audio around them.  After: 0, 0, and 9.5 dB; -50 dB or
  # better; 6.8 dB.
  describe 'never pops (fill guard)' do
    level_db = 7.5
    peak_db = 1.0
    click_db = 10.0
    tone_db = -40.0

    def fs = 48000

    def tone(hz, db, seconds: 0.6)
      t = Numo::DFloat.new((seconds * fs).round).seq / fs
      c = Numo::SFloat.cast(Numo::NMath.sin(t * 2 * Math::PI * hz) * 10**(db / 20.0))
      [c, c.dup]
    end

    def pad
      t = Numo::DFloat.new(28800).seq / fs
      x = [220.0, 277.6, 330.4].sum { |f| Numo::NMath.sin(t * 2 * Math::PI * f) * 0.15 + Numo::NMath.sin(t * 6 * Math::PI * f) * 0.02 }
      x *= Numo::NMath.sin(t * 2 * Math::PI * 0.7) * 0.2 + 0.8
      [Numo::SFloat.cast(x), Numo::SFloat.cast(x * 0.9)]
    end

    # A pitched-down sine kick every 125 ms and a decaying noise hat
    # between.
    def drums
      r = Random.new(7)
      x = Numo::DFloat.zeros(28800)
      (0...28800).step(6000) do |s|
        n = [6000, 28800 - s].min
        t = Numo::DFloat.new(n).seq / fs
        x[s...(s + n)] += Numo::NMath.sin(2 * Math::PI * (50 * t + 60 * (1 - Numo::NMath.exp(-t * 30)) / 30)) * Numo::NMath.exp(-t * 18) * 0.8
        h = s + 3000
        next if h + 2400 > 28800
        env = Numo::NMath.exp(-(Numo::DFloat.new(2400).seq / fs) * 60)
        x[h...(h + 2400)] += Numo::DFloat.cast(Array.new(2400) { r.rand(-0.3..0.3) }) * env
      end
      [Numo::SFloat.cast(x), Numo::SFloat.cast(x)]
    end

    def noise
      r = Random.new(3)
      c = Numo::SFloat.cast(Array.new(28800) { r.rand(-0.3..0.3) })
      [c, c.dup]
    end

    # (source, the tone's frequency if it is a pure tone)
    sources = {
      'a sine (440 Hz, -10 dBFS)' => [-> { tone(440, -10) }, 440],
      'a low sine (80 Hz, -6 dBFS)' => [-> { tone(80, -6) }, 80],
      'a sine clipped as a +15 dB monitor trim clipped it' => [-> { tone(440, -10).map { |c| (c * 10**(15 / 20.0)).clip(-1, 1) } }, nil],
      'a pad' => [-> { pad }, nil],
      'drums' => [-> { drums }, nil],
      'noise' => [-> { noise }, nil],
    }

    # Writer deliveries (frames queued before each 512-frame pull) at the
    # gap; afterwards the writer catches up at once.
    patterns = {
      'one period dry' => [0],
      'a quarter period dry' => [384],
      'partial, then dry' => [200, 0],
      'bursts' => [0, 512, 0, 512, 0],
      'stutter' => [100] * 8,
      'short stutter' => [300, 0, 60, 0, 400],
      'four periods dry' => [0, 0, 0, 0],
    }

    # Plays +audio+ through the kernel in 512-frame pulls, the writer
    # queueing one period per pull until +at+, then +pattern+, then the
    # deficit at once.  Returns the output channels, the output frame where
    # the first gap began, the first output frame of the first pull after
    # the pattern that played only real audio (it and every such pull later
    # checked against the source), and the source frame it played.
    def run_plan(audio, pattern, at)
      ch = audio.length
      k = MB::Sound::FastAudio::Concealer.new(ch, fs, MB::Sound::Concealment.settings(:repeat))
      len = audio[0].length
      deliveries = Array.new(at / 512, 512) + [at % 512] + pattern
      gap_pulls = deliveries.length
      deficit = deliveries.length * 512 - deliveries.sum
      deliveries << 512 + deficit
      out = []
      wpos = rpos = 0
      back = nil
      until rpos == len
        wpos = [wpos + (deliveries.shift || 512), len].min
        queued = ''
        if wpos > rpos
          m = Numo::SFloat.zeros(wpos - rpos, ch)
          ch.times { |c| m[true, c] = audio[c][rpos...wpos] }
          queued = m.to_binary
        end
        played, taken = k.pull(queued, 512, false)
        o = Numo::SFloat.from_binary(played).reshape(512, ch)
        if taken == 512 && out.length >= gap_pulls
          ch.times { |c| expect(o[true, c]).to eq(audio[c][rpos...(rpos + 512)]), "pull #{out.length}: the late audio changed" }
          back ||= [out.length * 512, rpos]
        end
        out << o
        rpos += taken
      end
      joined = Numo::SFloat.zeros(out.length * 512, ch)
      out.each_with_index { |o, i| joined[(i * 512)...((i + 1) * 512), true] = o }
      out = ch.times.map { |c| joined[true, c].dup }
      gap = (0...at + 512).find { |i| out[0][i] != audio[0][i] }
      [out, gap, *back]
    end

    def db(x) = 20 * Math.log10([x, 1e-12].max)
    def d2(c) = (c[2..] - c[1...-1] * 2 + c[0...-2]).abs

    def rms_max(c, a, b, w = 240)
      (a..(b - w)).step(w / 2).map { |s| Math.sqrt((c[s...(s + w)]**2).mean) }.max || 0
    end

    # The worst 5 ms window's residual after fitting a sine of +hz+ (any
    # amplitude and phase), in dB under the window's energy.
    def tone_resid(c, a, b, hz)
      (a..(b - 240)).step(120).map { |s|
        t = Numo::DFloat.new(240).seq(s) * (2 * Math::PI * hz / fs)
        x = Numo::DFloat.cast(c[s...(s + 240)])
        sn = Numo::NMath.sin(t)
        cs = Numo::NMath.cos(t)
        a11 = (sn * sn).sum
        a12 = (sn * cs).sum
        a22 = (cs * cs).sum
        b1 = (sn * x).sum
        b2 = (cs * x).sum
        det = a11 * a22 - a12 * a12
        r = x - sn * ((b1 * a22 - b2 * a12) / det) - cs * ((a11 * b2 - a12 * b1) / det)
        10 * Math.log10([(r * r).sum / (x * x).sum, 1e-20].max)
      }.max
    end

    sources.each do |sname, (make, hz)|
      it "fills gaps in #{sname} no louder than the audio around them, without clicks" do
        src = instance_exec(&make)
        [9600 + 37, 14400 + 211].each do |at|
          patterns.each do |pname, pattern|
            # Output frame i is source frame i up to the gap; the late audio
            # follows the fill and the landing unchanged (run_plan checks)
            out, gap, back, src_back = run_plan(src, pattern, at)
            expect(gap).not_to be_nil
            expect(back).not_to be_nil

            fill = gap...back
            a = gap - 5760
            b = src_back + 5760
            peak = db(out.map { |c| c[fill].abs.max }.max) - db(src.map { |c| c[a...b].abs.max }.max)
            level = db(out.map { |c| rms_max(c, gap - 120, back + 120) }.max) -
                    db(src.map { |c| rms_max(c, gap - 960, src_back + 960) }.max)
            click = db(out.map { |c| d2(c[(gap - 2)...(back + 2)]).max }.max) - db(src.map { |c| d2(c[a...b]).max }.max)
            expect(peak).to be <= peak_db + 0.01, "#{pname} at #{at}: fill peak #{peak.round(1)} dB over the source's"
            expect(out.map { |c| c[fill].abs.max }.max).to be <= 1.0, "#{pname} at #{at}: fill over full scale"
            expect(level).to be <= level_db, "#{pname} at #{at}: fill #{level.round(1)} dB over the audio around the gap"
            expect(click).to be <= click_db, "#{pname} at #{at}: a corner #{click.round(1)} dB sharper than the source's"
            next unless hz

            resid = tone_resid(out[0], gap - 240, back + 240, hz)
            expect(resid).to be <= tone_db, "#{pname} at #{at}: the tone's shape off by #{resid.round(1)} dB"
          end
        end
      end
    end
  end

  describe 'Playback (null backend)' do
    include DeviceCapture

    def playback(conceal_settings, capture: DeviceCapture.size(48000))
      MB::Sound::FastAudio::Playback.new(
        [:null], -1, 'mb-sound-spec', 1, 1, rate, 0, 0, 4096, capture, 2, false, 0, nil, conceal_settings
      ).tap { |p| @playbacks << p; remember_capture(p, capture) }
    end

    def wait_until(timeout: 3)
      deadline = MB::U.clock_now + timeout
      sleep 0.005 until yield || MB::U.clock_now > deadline
    end

    before { @playbacks = [] }
    after { @playbacks.each(&:close) }

    # The capture from its first nonzero sample (wait for the frames an
    # example reads with #wait_for_played: spec/support/device_capture.rb)
    def captured(pb)
      x, start = capture_and_start(pb)
      raise 'Nothing was played' if start.nil?
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
      wait_for_capture(pb)

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
        a = signal(0, 2400, 1)[0]
        pb = playback(settings, capture: DeviceCapture.size(24000))
        pb.write([a])
        pb.end_stream if mark
        wait_until { pb.stats[:queued] == 0 }
        wait_for_played(pb, 24000)
        x = captured(pb)
        expect(x[2400..].abs.max).to eq(0)
        expect(pb.stats[:concealed]).to eq(0)
        expect(pb.stats[:underruns]).to eq(1)
      end
    end
  end
end
