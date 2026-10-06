RSpec.describe(MB::Sound::Tone, '#wavetable', aggregate_failures: true) do
  let(:w) { MB::Sound::Wavetable }

  # Runs +make+ (a block returning a new tone) in C and in Ruby for
  # +buffers+ buffers of +count+ samples, expecting identical samples.
  def expect_c_and_ruby(buffers: 4, count: 300, &make)
    a = make.call
    b = make.call
    buffers.times do |i|
      ca = a.sample(count)
      rb = b.sample_ruby(count)
      expect(rb.to_a).to eq(ca.to_a), "buffer #{i}: max difference #{(ca - rb).abs.max}"
    end
  end

  # Power of the non-harmonic FFT bins below 20 kHz relative to the
  # harmonic bins (dB), for +node+ at k * 48000 / 65536 Hz (coherent
  # sampling, as in bin/aliasing.rb).
  def aliasing_db(k)
    n = 65536
    node = yield((k * 48000.0 / n).hz)
    node.sample(4800)
    data = Numo::DFloat.cast(Numo::NArray.concatenate(Array.new(n / 800 + 1) { node.sample(800).dup })[0...n])
    pow = MB::Sound.real_fft(data).abs**2
    bins = Numo::Int64.new(pow.length).seq
    top = (20000.0 / 48000 * n).to_i
    harmonic = (bins % k).eq(0) & bins.gt(0)
    other = (bins % k).ne(0) & bins.lt(top)
    10 * Math.log10(pow[other].sum / pow[harmonic].sum)
  end

  describe 'configuration' do
    it 'makes a wavetable tone from a Pitch' do
      t = 220.hz.wavetable(:saw, scan: 0.5, interpolation: :cubic)
      expect(t).to be_a(MB::Sound::Tone)
      expect(t).to be_wavetable
      expect(t.wave_type).to eq(:wavetable)
      expect(t.table).to equal(w[:saw])
      expect(t.scan).to eq(0.5)
      expect(t).to be_band_limited
    end

    it 'turns a Tone into a wavetable tone' do
      t = 220.hz.ramp.at(0.5).wavetable(:square)
      expect(t.wave_type).to eq(:wavetable)
      expect(t.amplitude).to eq(0.5)
    end

    it 'gives a Tone scan without an amplitude a 0..1 range' do
      scan = 1.hz.triangle
      220.hz.wavetable(:basic, scan: scan)
      expect(scan.range).to eq(0.0..1.0)
    end

    it 'takes a phasor as the scan input' do
      t = 220.hz.wavetable(:basic, scan: 0.5.hz.phasor)
      expect(t.sample(100)).to be_a(Numo::SFloat)
    end

    it 'lists the scan input in its sources' do
      scan = 1.hz.triangle
      expect(220.hz.wavetable(:basic, scan: scan).sources[:scan]).not_to be_nil
    end

    it 'rejects bad arguments' do
      expect { 220.hz.wavetable(:nope) }.to raise_error(ArgumentError, /No wavetable/)
      expect { 220.hz.wavetable(:saw, interpolation: :magic) }.to raise_error(ArgumentError, /interpolation/)
      expect { 220.hz.wavetable(:saw, scan: 'x') }.to raise_error(ArgumentError, /Scan/)
      expect { MB::Sound::Tone.new(wave_type: :wavetable) }.to raise_error(ArgumentError, /Tone#wavetable/)
    end

    it 'cannot change after it starts playing' do
      t = 220.hz.wavetable(:saw)
      t.sample(10)
      expect { t.wavetable(:square) }.to raise_error(FrozenError)
    end

    it 'raises an error for settings it cannot play' do
      expect { 220.hz.wavetable(w.from_harmonics([1], complex: true)).sync(ratio: 2).sample(10) }.to raise_error(ArgumentError, /synced/)
      expect { 220.hz.wavetable(:saw).noise.sync(ratio: 2).sample(10) }.to raise_error(ArgumentError, /noise/)

      s = w.from_samples(Numo::SFloat.zeros(100), mode: :sample, root: 100)
      expect { 220.hz.wavetable(s).pm(3.hz).sample(10) }.to raise_error(ArgumentError, /phase modulation/)
      expect { 220.hz.wavetable(s).pwm(0.3).sample(10) }.to raise_error(ArgumentError, /warp/)
      expect { 220.hz.wavetable(s).sync(ratio: 2).sample(10) }.to raise_error(ArgumentError, /synced/)
    end
  end

  describe 'cycle mode' do
    it 'gives the same samples in C and Ruby' do
      expect_c_and_ruby { 440.hz.wavetable(:saw) }
      expect_c_and_ruby { 440.hz.wavetable(:basic, scan: 0.3.hz.triangle).at(0.5..1) }
      expect_c_and_ruby { 440.hz.fm(5.hz.at(400)).wavetable(:saw, interpolation: :cubic) }
      expect_c_and_ruby { 440.hz.wavetable(:pulses, scan: 0.7).pm(220.hz.at(2)).pwm(3.hz.lfo.at(0.2..0.8)) }
      expect_c_and_ruby { 440.hz.wavetable(w.from_harmonics([1, 0.5, 0.25], complex: true)) }
    end

    it 'gives the same samples in C and Ruby with hard and soft sync' do
      expect_c_and_ruby { 220.hz.wavetable(:saw).sync(ratio: 3.hz.lfo.at(1.5..4)) }
      expect_c_and_ruby { 220.hz.wavetable(:basic, scan: 0.6).pwm(0.3).softsync(MB::Sound::C2) }
      expect_c_and_ruby { 220.hz.wavetable(w.from_harmonics([1, 1, 1], mips: false)).sync(ratio: 2.5) }
    end

    it 'syncs with band-limited steps' do
      synced = aliasing_db(1365) { |p| p.wavetable(:sine).sync(ratio: 2.37) }
      naive = aliasing_db(1365) { |p| p.wavetable(w.from_harmonics([1], mips: false)).sync(ratio: 2.37) }
      expect(synced).to be < -60
      expect(naive).to be > synced + 15
    end

    it 'band-limits the corners of a phase warp' do
      warped = aliasing_db(1365) { |p| p.wavetable(:sine).pwm(0.2) }
      expect(warped).to be < -65
    end

    it 'gives the same samples in C and Ruby with resets' do
      trigger = -> { MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(1200).tap { |z| z[[50, 333, 700]] = 1 }]) }
      expect_c_and_ruby { 330.hz.wavetable(:saw).reset(trigger.call) }
      expect_c_and_ruby { 330.hz.wavetable(:basic, scan: 0.6).reset(trigger.call, to: Math::PI / 2) }
    end

    it 'plays the table one cycle per period' do
      t = 100.hz.wavetable(:sine).sample(480)
      expected = Numo::SFloat.new(480).seq.map { |i| Math.sin(2 * Math::PI * i / 480) }
      expect(t).to all_be_within(1e-4).of_array(expected)
    end

    it 'plays an exact saw series with the Fourier amplitudes of a ramp up to the crossfade' do
      # 100 Hz is between the 255- and 127-harmonic levels: harmonics up to
      # 127 at full level
      data = Numo::DFloat.cast(100.hz.wavetable(w.from_harmonics(w::Library.saw)).sample(4800))
      amps = MB::Sound.real_fft(data).abs
      fourier = Numo::DFloat.cast(w::Library.saw(127)).abs
      expect(amps[(1..127).map { |h| h * 10 }]).to all_be_within(1e-4).of_array(fourier)
    end

    it 'plays the library saw at the level of a PolyBLEP ramp' do
      [55, 880].each do |f|
        t = f.hz.wavetable(:saw)
        r = f.hz.ramp
        a = Numo::DFloat.cast(Numo::NArray.concatenate(Array.new(12) { t.sample(800).dup }))
        b = Numo::DFloat.cast(Numo::NArray.concatenate(Array.new(12) { r.sample(800).dup }))
        expect(a.abs.max).to be_within(0.08).of(b.abs.max)
        expect(10 * Math.log10((a**2).mean / (b**2).mean)).to be_within(0.4).of(0)
      end
    end

    it 'aliases far less than naive and PolyBLEP ramps' do
      table = aliasing_db(1001) { |p| p.wavetable(:saw) }
      naive = aliasing_db(1001) { |p| p.aramp }
      blep = aliasing_db(1001) { |p| p.ramp }
      expect(table).to be < -100
      expect(table).to be < blep - 20
      expect(naive).to be > -50
    end

    it 'morphs across frames with the scan input' do
      sine = 100.hz.wavetable(:basic, scan: 0).sample(480)
      saw = 100.hz.wavetable(:basic, scan: 1).sample(480)
      expect(sine).to all_be_within(1e-4).of_array(100.hz.sine.sample(480))
      expect(saw).to all_be_within(1e-4).of_array(100.hz.wavetable(:saw).sample(480))

      half = 100.hz.wavetable(:basic, scan: 1.0 / 6).sample(480)
      tri = 100.hz.wavetable(:triangle).sample(480)
      expect(half).to all_be_within(1e-4).of_array(sine * 0.5 + tri * 0.5)
    end

    it 'keeps a steady level through a sweep across levels' do
      sweep = 2.hz.ramp.lfo.at(0..1)
      freq = (sweep * 6).proc { |v| 2**v * 100 } # 100 Hz to 6.4 kHz
      tone = freq.tone.wavetable(:sine)
      data = Numo::NArray.concatenate(Array.new(30) { tone.sample(800).dup })
      expect(data.abs.max).to be_within(1e-3).of(1)
    end

    it 'can be complex' do
      t = 100.hz.wavetable(w.from_harmonics([1], complex: true)).sample(480)
      expect(t).to be_a(Numo::SComplex)
      expect(t.imag).to all_be_within(1e-4).of_array(100.hz.sine.with_phase(Math::PI / 2).sample(480) * -1)
    end

    it 'can be noise with the distribution of the table (the same in C and Ruby)' do
      expect_c_and_ruby { 1.hz.wavetable(:saw).noise(seed: 3) }
      expect_c_and_ruby { 220.hz.wavetable(:basic, scan: 0.4).noise(0.001, seed: 4) }

      x = Numo::DFloat.cast(1.hz.wavetable(:saw).noise(seed: 5).sample(48000))
      expect(Math.sqrt((x**2).mean)).to be_within(0.01).of(Math.sqrt(1.0 / 3)) # uniform, like ramp noise
      expect(x.mean.abs).to be < 0.01
    end

    it 'band-limits resets' do
      trigger = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(800).tap { |z| z[401] = 1 }])
      t = 997.hz.wavetable(:sine).reset(trigger)
      data = t.sample(800)
      # The jump from the sine's value to 0 is spread over the next samples
      expect((data[401] - data[400]).abs).to be < 0.7
    end

    it 'has ports' do
      t = 100.hz.wavetable(:saw)
      wraps = t.wraps
      t.sample(1000)
      expect(wraps.sample(1000).ne(0).where.to_a).to eq([480, 960])
    end
  end

  describe 'sample mode' do
    let(:sound) { Numo::SFloat.new(4800).seq.map { |i| Math.sin(2 * Math::PI * 1000 * i / 48000) } }

    it 'plays the sound at the root pitch' do
      t = w.from_samples(sound, mode: :sample, root: 200)
      out = 200.hz.wavetable(t).sample(1000)
      expect(out).to all_be_within(1e-4).of_array(sound[0...1000])
    end

    it 'plays an octave up at twice the root' do
      t = w.from_samples(sound, mode: :sample, root: 200)
      out = 400.hz.wavetable(t).sample(1000)
      # (after the band-limited level's ringing at the abrupt start)
      expect(out[100..]).to all_be_within(1e-4).of_array(sound[(200...2000).step(2).to_a])
    end

    it 'gives the same samples in C and Ruby' do
      t = w.from_samples(sound, mode: :sample, root: 200, loop: 1000...1960)
      expect_c_and_ruby(buffers: 6, count: 1000) { 300.hz.fm(3.hz.at(50)).wavetable(t) }
      expect_c_and_ruby(buffers: 6, count: 1000) { 300.hz.wavetable(t, interpolation: :sinc).at(0.5) }
    end

    it 'loops' do
      t = w.from_samples(sound, mode: :sample, root: 200, loop: 1000...1960)
      tone = 200.hz.wavetable(t)
      out = Numo::NArray.concatenate(Array.new(10) { tone.sample(1000).dup })
      expect(out.length).to eq(10000)
      expect(out[5000...6000]).to all_be_within(1e-3).of_array(sound[(1000 + (5000 - 1000) % 960)...][0...1000].concatenate(sound[1000...1960])[0...1000])
    end

    it 'ends a one-shot without a reset input' do
      t = w.from_samples(sound[0...1000], mode: :sample, root: 200)
      tone = 200.hz.wavetable(t)
      expect(tone.sample(800)).not_to be_nil
      expect(tone.sample(800)).not_to be_nil
      expect(tone.sample(800)).to be_nil
    end

    it 'restarts a one-shot at every reset, never ending' do
      t = w.from_samples(sound[0...1000], mode: :sample, root: 200)
      trigger = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(4000).tap { |z| z[3000] = 1 }])
      tone = 200.hz.wavetable(t).reset(trigger)
      out = Numo::NArray.concatenate(Array.new(5) { tone.sample(800).dup })
      expect(out[1100...3000].abs.max).to be < 1e-3
      expect(out[3100...3900]).to all_be_within(1e-3).of_array(sound[100...900])
    end
  end

  describe 'key maps' do
    let(:low) { w.from_harmonics([1], size: 64) }
    let(:high) { w.from_harmonics([0, 1], size: 64) }

    it 'picks a zone by pitch' do
      map = w::KeyMap.new(MB::Sound::C2...MB::Sound::C4 => low, MB::Sound::C4..MB::Sound::C8 => high)
      expect(map.table_for(50)).to equal(low)
      expect(map.table_for(70)).to equal(high)
      expect(map.table_for(10)).to equal(low)
      expect(map.table_for(120)).to equal(high)

      a = MB::Sound::C3.wavetable(map).sample(800)
      expect(a).to all_be_within(1e-4).of_array(MB::Sound::C3.wavetable(low).sample(800))
      b = MB::Sound::C5.wavetable(map).sample(800)
      expect(b).to all_be_within(1e-4).of_array(MB::Sound::C5.wavetable(high).sample(800))
    end

    it 'can make consecutive zones' do
      map = w::KeyMap.zones([low, high], from: 40, size: 8)
      expect(map.zones.map { |z| z[0..1] }).to eq([[40, 48], [48, 56]])
      expect(map.table_for(47.9)).to equal(low)
      expect(map.table_for(48)).to equal(high)
    end

    it 'picks a new zone at each reset' do
      map = w::KeyMap.new(0...60 => low, 60..127 => high)
      freq = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(1600).fill(MB::Sound::C3.frequency).tap { |f| f[800..] = MB::Sound::C5.frequency }])
      trigger = MB::Sound::ArrayInput.new(data: [Numo::SFloat.zeros(1600).tap { |z| z[0] = 1; z[800] = 1 }])
      tone = freq.tone.wavetable(map).reset(trigger)
      tone.sample(800)
      expect(tone.send(:current_table)).to equal(low)
      tone.sample(800)
      expect(tone.send(:current_table)).to equal(high)
    end
  end
end
