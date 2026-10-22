require 'mb/sound/sound_guard'

RSpec.describe(MB::Sound::SoundGuard, :aggregate_failures) do
  let(:rate) { 48000 }
  let(:fp_class) { MB::Sound::SoundGuard::Fingerprint }

  CLICKS = [0.5, 1.0, 1.4, 2.0, 2.3].freeze

  # Three seconds of a stereo saw chord fading in over 0.3 s with clicks at
  # +clicks+, +gain+ dB, optionally lowpassed or with noise added.
  def music(gain: 0, seconds: 3.0, clicks: CLICKS, lowpass: nil, noise_db: nil, mono: false)
    n = (seconds * rate).round
    t = Numo::DFloat.new(n).seq / rate
    saw = ->(f) { 2 * ((t * f) % 1) - 1 }
    fade = (t / 0.3).clip(0, 1)
    l = (saw.(220) * 0.2 + saw.(330) * 0.1 + saw.(1760) * 0.03) * fade
    r = mono ? l.dup : (saw.(220) * 0.2 + saw.(277.2) * 0.1 + saw.(1760) * 0.03) * fade
    clicks.each do |c|
      s = (c * rate).round
      next if s >= n
      e = [s + 200, n].min
      l[s...e] += 0.8
      r[s...e] += 0.8
    end
    out = [l, r]
    if lowpass
      out = out.map { |c|
        f = MB::Sound::Filter::Cookbook.new(:lowpass, rate, lowpass, quality: 0.707)
        Numo::DFloat.cast(f.process(c))
      }
    end
    if noise_db
      Numo::NArray.srand(1)
      out = out.map { |c| c + Numo::DFloat.new(n).rand(-1.0, 1.0) * 10**(noise_db / 20.0) }
    end
    g = 10**(gain / 20.0)
    out.map { |c| Numo::SFloat.cast(c * g) }
  end

  def fingerprint(data)
    fp_class.extract(data, name: :spec)
  end

  describe MB::Sound::SoundGuard::Fingerprint do
    let(:fp) { fingerprint(music) }

    it 'measures loudness, spectra, envelope, onsets, and width' do
      l = MB::Sound.loudness(music)
      expect(fp[:loudness][:integrated]).to be_within(0.01).of(l.integrated)
      expect(fp[:loudness][:true_peak]).to be_within(0.01).of(l.true_peak)
      expect(fp.duration).to eq(3.0)
      expect(fp[:channels]).to eq(2)
      expect(fp[:mel_mean].length).to eq(fp_class::MEL_BANDS)
      expect(fp[:mel].length).to eq(7) # six whole segments and the last frame
      expect(fp[:mel].map(&:length).uniq).to eq([fp_class::MEL_BANDS])
      expect(fp[:momentary].length).to be_within(1).of(30)
      expect(fp[:envelope].length).to be_within(2).of(3.0 * rate / fp_class::ENVELOPE_HOP)
      expect(fp[:centroid]).to be_between(220, 4000)

      # The start of a render is always an onset, the strongest here
      times = fp[:onsets].map(&:first)
      ([0.0] + CLICKS).each { |c| expect(times).to include(be_within(0.02).of(c)) }

      expect(fp[:stereo][:width]).to be_between(-30, 0)
      expect(fp[:stereo][:band_width].length).to eq(3)
    end

    it 'reads a mono mix as mono and one channel as no stereo' do
      expect(fingerprint(music(mono: true))[:stereo][:width]).to eq(-60.0)
      expect(fingerprint([music[0]])[:stereo]).to be_nil
    end

    it 'measures files the same as their data' do
      path = tmp_path('fp.flac')
      MB::Sound.write(path, music, sample_rate: rate)
      from_file = fp_class.extract(path, name: :spec)
      expect(from_file[:loudness][:integrated]).to be_within(0.05).of(fp[:loudness][:integrated])
      expect(fp.compare(from_file)).to be_pass
    end

    it 'round-trips through JSON, one segment per line' do
      path = tmp_path('fp.json')
      fp.save(path)
      loaded = fp_class.load(path)
      expect(loaded.data).to eq(JSON.parse(JSON.generate(fp.data), symbolize_names: true))
      expect(File.readlines(path).length).to be > fp[:mel].length
      expect(fp.compare(loaded).distances.values).to all(eq(0))
    end

    it 'refuses another format' do
      expect { fp_class.new(fp.data.merge(format: 0)) }.to raise_error(ArgumentError, /refingerprint/)
    end
  end

  describe MB::Sound::SoundGuard::Comparison do
    let(:base) { fingerprint(music) }

    it 'passes identical renders and changes far below hearing' do
      expect(base.compare(fingerprint(music))).to be_pass
      quiet_noise = base.compare(fingerprint(music(noise_db: -90)))
      expect(quiet_noise).to be_pass
      expect(base.compare(fingerprint(music(gain: 0.1)))).to be_pass
    end

    it 'fails a 1 dB gain change on loudness only' do
      c = base.compare(fingerprint(music(gain: 1)))
      expect(c).not_to be_pass
      expect(c.distances[:loudness]).to be_within(0.02).of(1.0)
      expect(c.failures).to include(:loudness)
      expect(c.distances[:spectrum]).to be < 0.05
      expect(c.distances[:envelope]).to be < 0.2
    end

    it 'fails a darker mix on its spectrum and centroid' do
      c = base.compare(fingerprint(music(lowpass: 2000)))
      expect(c.failures).to include(:spectrum, :centroid)
    end

    it 'fails moved onsets' do
      c = base.compare(fingerprint(music(clicks: CLICKS.map { |t| t + 0.1 })))
      expect(c.distances[:onsets]).to be >= 0.5
      expect(c.failures).to include(:onsets)
    end

    it 'fails a change of width or channel count, and of length' do
      expect(base.compare(fingerprint(music(mono: true))).failures).to include(:width)
      expect(base.compare(fingerprint([music[0]])).distances[:width]).to eq(Float::INFINITY)
      expect(base.compare(fingerprint(music(seconds: 3.5))).failures).to include(:duration)
    end

    it 'takes other thresholds and reports each distance' do
      c = base.compare(fingerprint(music(gain: 1)), thresholds: { loudness: 2.0, true_peak: 2.0, loudness_curve: 2.0 })
      expect(c).to be_pass
      expect(c.to_s).to match(/loudness\s+1\.0\d+ LU\s+\(limit 2(\.0)?\)/)
      expect(c.to_h[:loudness]).to include(pass: true, threshold: 2.0)
      expect(c.worst_ratio).to be < 1
    end
  end

  describe MB::Sound::SoundGuard::GoldenSet do
    let(:root) { MB::Sound::SoundGuard.root }

    it 'loads the repository set: scripts exist, no SQ-80, every piece approved with the current format' do
      set = MB::Sound::SoundGuard::GoldenSet.load
      expect(set.pieces.length).to be_between(10, 20)
      set.pieces.each_value do |piece|
        expect(File.exist?(File.join(root, piece.script))).to eq(true), piece.name.to_s if piece.script?
        expect(piece.args.join(' ')).not_to match(/sq80/i)
        path = set.fingerprint_path(piece)
        expect(File.exist?(path)).to eq(true), "#{piece.name} has no fingerprint (rake golden:approve[#{piece.name}])"
        expect { MB::Sound::SoundGuard::Fingerprint.load(path) }.not_to raise_error if File.exist?(path)
      end
      expect(File.read(File.join(root, MB::Sound::SoundGuard::GoldenSet::DEFINITION))).not_to match(/^[^#]*sq80/i)
    end

    it 'checks piece definitions' do
      set = MB::Sound::SoundGuard::GoldenSet.new(root)
      set.piece(:tone, 'spec/test_data/golden_tone.rb', genre: :spec, covers: 'spec')
      expect { set.piece(:tone, 'spec/test_data/golden_tone.rb', genre: :spec, covers: 'x') }.to raise_error(ArgumentError, /twice/)
      expect { set.piece(:nope, 'bin/no_such.rb', genre: :spec, covers: 'x') }.to raise_error(ArgumentError, /no script/)
      expect { set.piece(:blk, genre: :spec, covers: 'x') { 1 } }.to raise_error(ArgumentError, /bars: and bpm:/)
      expect { set.select(['tome']) }.to raise_error(ArgumentError, /tone/)
      expect(set.select([]).map(&:name)).to eq([:tone])
    end
  end

  describe MB::Sound::SoundGuard::Runner do
    it 'approves, passes the same render, and fails a changed one with a Bench set' do
      dir = tmp_path('golden')
      set = MB::Sound::SoundGuard::GoldenSet.new(MB::Sound::SoundGuard.root, fingerprints_dir: File.join(dir, 'fingerprints'))
      set.piece(:tone, 'spec/test_data/golden_tone.rb', genre: :spec, covers: 'spec')
      set.piece(:louder, 'spec/test_data/golden_tone.rb', '--gain', '0', genre: :spec, covers: 'spec')
      io = StringIO.new
      runner = MB::Sound::SoundGuard::Runner.new(set, parallel: 2, io: io, golden_dir: dir)

      approved = runner.approve(set.select([]))
      expect(approved).to all(be_ok)
      expect(File.exist?(File.join(dir, 'approved', 'tone.flac'))).to eq(true)
      expect(File.exist?(File.join(dir, 'fingerprints', 'louder.json'))).to eq(true)

      # The same renders pass; then "louder" gets louder (a new piece
      # definition, the same approved fingerprint)
      expect(runner.check(set.select([]), run_dir: runner.dir).map(&:status)).to eq([:pass, :pass])

      changed = MB::Sound::SoundGuard::GoldenSet.new(MB::Sound::SoundGuard.root, fingerprints_dir: File.join(dir, 'fingerprints'))
      changed.piece(:louder, 'spec/test_data/golden_tone.rb', '--gain', '1.5', genre: :spec, covers: 'spec')
      runner = MB::Sound::SoundGuard::Runner.new(changed, io: io, golden_dir: dir)
      results = runner.check(changed.select([]))
      expect(results.map(&:status)).to eq([:fail])
      expect(results[0].comparison.failures).to include(:loudness)

      report = File.read(File.join(runner.dir, 'report.txt'))
      expect(report).to match(/louder: FAIL/)
      bench = File.read(File.join(runner.dir, 'bench_set.py'))
      expect(bench).to include('sets.append(json.loads(')
      expect(bench).to include('louder_approved.mp3', 'louder_new.mp3', 'golden_tone.rb')
      expect(File.exist?(File.join(runner.dir, 'bench', 'louder_new.mp3'))).to eq(true)

      # Re-approving the check run's render updates the fingerprint
      runner.approve(changed.select([]), run_dir: runner.dir)
      expect(runner.check(changed.select([]), run_dir: runner.dir).map(&:status)).to eq([:pass])
    end
  end
end
