RSpec.describe(MB::Sound::Analysis) do
  rate = 48000

  # A decaying 8-partial saw-like tone (partials 1/k) of MIDI note +midi+,
  # +cents+ off A = 440 Hz.
  tone = ->(midi, seconds, cents: 0) {
    n = (seconds * rate).round
    t = Numo::DFloat.new(n).seq / rate
    f = 440.0 * 2**((midi - 69 + cents / 100.0) / 12.0)
    y = Numo::DFloat.zeros(n)
    (1..8).each { |k| y += Numo::NMath.sin(t * 2 * Math::PI * f * k) / k }
    y * Numo::NMath.exp(-t * 1.5)
  }

  # Triads (semitones over +tonic+'s C3-octave note) with the root an
  # octave down, 0.6 s each.
  progression = ->(tonic, chords, cents: 0) {
    Numo::DFloat.hstack(chords.map { |c|
      notes = c.map { |x| 48 + tonic + x }
      notes.sum { |m| tone.(m, 0.6, cents: cents) } + tone.(notes[0] - 12, 0.6, cents: cents)
    })
  }
  major = [[0, 4, 7], [5, 9, 12], [7, 11, 14], [0, 4, 7]]
  minor = [[0, 3, 7], [5, 8, 12], [7, 11, 14], [0, 3, 7]] # harmonic minor V

  describe MB::Sound::Analysis::Chroma do
    it 'folds a tone onto its pitch class and estimates the tuning' do
      c = MB::Sound::Analysis::Chroma.new(tone.(57, 1.0, cents: 23)) # A3, 23 cents sharp
      expect(c.tuning).to be_within(3).of(23)
      expect(c.fold.to_a.each_with_index.max[1]).to eq(9)
      expect(c.fold.sum).to be_within(1e-9).of(1)
      expect(c.to_h.keys.first).to eq('C')
      expect(c.inspect).to include('tuning +2', 'A ')
    end

    it 'gives zeros for silence' do
      c = MB::Sound::Analysis::Chroma.new(Numo::DFloat.zeros(rate))
      expect(c.fold.to_a).to eq([0.0] * 12)
      expect(c.tuning).to eq(0.0)
    end

    it 'mixes channels down' do
      x = tone.(60, 0.5)
      expect(MB::Sound::Analysis::Chroma.new([x, x]).fold.to_a.map { |v| v.round(9) }).to eq(MB::Sound::Analysis::Chroma.new(x).fold.to_a.map { |v| v.round(9) })
    end
  end

  describe MB::Sound::Analysis::Key do
    it 'finds each profile itself with correlation 1' do
      major_profile, minor_profile = MB::Sound::Analysis::Key::PROFILES[:krumhansl]
      k = MB::Sound::Analysis::Key.detect(major_profile.rotate(-2)) # D major
      expect(k.key).to eq(:D)
      expect(k.correlation).to be_within(1e-4).of(1)
      expect(k.scores.length).to eq(24)
      k = MB::Sound::Analysis::Key.detect(minor_profile.rotate(-9)) # A minor
      expect(k.key).to eq(:Am)
      expect(k.relative).to eq(:C)
      expect(k.musical_key.to_s).to eq('A minor')
      expect(MB::Sound::Analysis::Key.detect(minor_profile, profile: :temperley).key).to eq(:Cm)
    end

    # Every key in the slow tier; C, G, and a detuned Eb in the normal one
    tonics = [0, 7, 3, *SlowTier.slow_tier([1, 2, 4, 5, 6, 8, 9, 10, 11], keep: 0)]
    tonics.each do |t|
      it "finds #{MB::Sound::Analysis::Key.symbol(t, :major)} major and #{MB::Sound::Analysis::Key.symbol(t, :minor)} from I-IV-V-I progressions" do
        cents = t == 3 ? 30 : 0
        [[major, :major], [minor, :minor]].each do |chords, mode|
          k = MB::Sound::Analysis::Key.of(progression.(t, chords, cents: cents))
          expect(k.key).to eq(MB::Sound::Analysis::Key.symbol(t, mode))
          expect(k).to be_clear
          expect(k.correlation).to be > 0.8
        end
      end
    end

    it 'spells and parses keys' do
      key = MB::Sound::Analysis::Key
      expect((0..11).map { |t| key.symbol(t, :major) }).to eq(%i[C Db D Eb E F F# G Ab A Bb B])
      expect((0..11).map { |t| key.symbol(t, :minor) }).to eq(%i[Cm C#m Dm Ebm Em Fm F#m Gm G#m Am Bbm Bm])
      expect(key.parse(:"A#m")).to eq([10, :minor])
      expect(key.parse('C minor')).to eq([0, :minor])
      expect(key.parse('Ebmaj')).to eq([3, :major])
      expect(key.parse(:nope)).to be_nil
      expect(key.same?(:"A#m", :Bbm)).to eq(true)
      expect(key.same?(:Am, :A)).to eq(false)
      expect(key.words(:"F#m")).to eq('F# minor')
    end

    it 'raises with suggestions for unknown profiles' do
      expect { MB::Sound::Analysis::Key.detect([1] * 12, profile: :krumhansel) }.to raise_error(ArgumentError, /Did you mean\?\s+:krumhansl/)
      expect { MB::Sound::Analysis::Key.detect([1] * 11) }.to raise_error(ArgumentError, /12 values/)
    end
  end

  describe 'Sample#detect_key' do
    let(:pad) { MB::Sound::Sample[[progression.(9, minor)]] }

    it 'sets a clear key with its reason, cached' do
      s = pad.detect_key
      expect(s.key).to eq(:Am)
      expect(s.meta_source[:key]).to eq(:detected)
      expect(s.meta[:why][:key]).to match(/\Adetected A minor \(r 0\.\d+, next /)
      expect(pad.key_analysis).to equal(pad.key_analysis)
    end

    it 'leaves drums and noise without a key' do
      noise = MB::Sound::Sample[[Numo::DFloat.new(rate).rand(-0.5, 0.5)]]
      s = noise.detect_key
      expect(s.key).to be_nil
      expect(s.meta[:why][:key]).to match(/percussive, spectral flatness .*: no key \(best /)
      expect(noise.detect_key(force: true).key).to eq(noise.key_analysis.key)
    end

    it 'detects keys of files when asked, and loops() finds them' do
      dir = File.dirname(tmp_path('pads/x'))
      FileUtils.mkdir_p(dir)
      MB::Sound.write(File.join(dir, 'pad_loop.flac'), [progression.(10, minor) * 0.2])  # Bbm, no key in the name
      MB::Sound.write(File.join(dir, 'Bbm pad.flac'), [progression.(5, major) * 0.2])     # the name wins (F major audio)
      MB::Sound.write(File.join(dir, 'other.flac'), [progression.(0, major) * 0.2])

      expect(MB::Sound::Sample[File.join(dir, 'pad_loop.flac')].key).to be_nil
      expect(MB::Sound::Sample[File.join(dir, 'pad_loop.flac'), detect: :key].key).to eq(:Bbm)
      expect { MB::Sound::Sample[File.join(dir, 'pad_loop.flac'), detect: :keys] }.to raise_error(ArgumentError, /Did you mean\?\s+:key\b/)

      plain = MB::Sound.loops(dir, key: :"A#m")
      expect(plain.map { |e| File.basename(e.path) }).to eq(['Bbm pad.flac'])
      found = MB::Sound.loops(dir, key: :"A#m", detect: :key)
      expect(found.map { |e| File.basename(e.path) }).to eq(['Bbm pad.flac', 'pad_loop.flac'])
      e = found[1]
      expect(e.sources[:key]).to eq(:detected)
      expect(e.reason).to match(/key detected Bb minor/)
      expect(MB::Sound.loops(dir, detect: :key).map(&:key)).to eq(%i[Bbm C Bbm])
      expect { MB::Sound.loops(dir, key: :H) }.to raise_error(ArgumentError, /key names/)
    end
  end
end
