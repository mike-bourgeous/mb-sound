RSpec.describe(MB::Sound::Generative::KeyFollow, :aggregate_failures) do
  # Plays +clip+ (as note numbers) in a rendering Session at 120 BPM (a bar
  # is 96000 samples) for +bars+ bars in buffers of +size+, running +setup+
  # in the Session first.  Returns { bar => sorted pitch classes } and the
  # raw output.
  def play(clip, bars: 4, size: 800, &setup)
    s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 1, sleep: false), transport: MB::Sound::Sequence::Transport.new(bpm: 120),
                               channels: 1, buffer_size: size, realtime: false, raise_errors: true, master_gain: 1)
    MB::Sound::Session.with_context(session: s) {
      MB::Sound.bg(:a, clip.number * 0.001, on: :now)
      setup&.call
    }
    out = []
    n = 0
    while n < bars * 96000
      b = s.process_buffer[0]
      out << b.dup
      n += b.length
    end
    data = SpecBuffers.join(out)[0...(bars * 96000)]
    by_bar = Hash.new { |h, k| h[k] = [] }
    data.to_a.each_slice(800).with_index { |sl, i| v = (sl[0] * 1000).round; by_bar[i * 800 / 96000 + 1] << v % 12 if v > 0 }
    [by_bar.transform_values { |l| l.uniq.sort }, data]
  ensure
    s&.close
  end

  def classes(scale) = scale.offsets.map { |o| (scale.root_class + o) % 12 }.sort

  let(:c_phrygian) { classes(MB::Sound::Scale[:phrygian, :c]) }
  let(:d_phrygian) { classes(MB::Sound::Scale[:phrygian, :d]) }

  describe 'scales' do
    it 'marks scales made without a root as following the key, printing without one' do
      expect(MB::Sound.scale(:phrygian).following).to eq(:root)
      expect(MB::Sound.scale(:phrygian, :key).following).to eq(:root)
      expect(MB::Sound.scale.following).to eq(:key)
      expect(MB::Sound.scale(:key).following).to eq(:key)
      expect(MB::Sound.scale(:phrygian, :d).following).to be_nil
      expect(MB::Sound::RubyValue.to_ruby(MB::Sound.scale(:phrygian))).to eq('scale(:phrygian)')
      expect(MB::Sound::RubyValue.to_ruby(MB::Sound.scale)).to eq('scale(:key)')
      expect(MB::Sound::RubyValue.to_ruby(MB::Sound.scale(:minor, :a))).to eq('scale(:minor, A4)')
      # As values they are the scale of the key when made
      expect(MB::Sound.scale(:phrygian)).to eq(MB::Sound::Scale[:phrygian, :c])
      d = MB::Sound::MusicalKey.new(root: 2, mode: :dorian)
      expect(MB::Sound.scale(:phrygian).at_key(d)).to eq(MB::Sound::Scale[:phrygian, :d])
      expect(MB::Sound.scale.at_key(d)).to eq(MB::Sound::Scale[:dorian, :d])
      expect(MB::Sound.scale(:phrygian, :e).at_key(d)).to eq(MB::Sound::Scale[:phrygian, :e])
    end

    it 'finds and rebuilds values made from following scales' do
      kf = MB::Sound::Generative::KeyFollow
      w = MB::Sound.scale(:dorian).weights.blur(0.1) + MB::Sound.tones(MB::Sound::D3) * 2
      expect(kf.follows?(w)).to eq(true)
      expect(kf.follows?(MB::Sound.scale(:dorian, :d).weights)).to eq(false)
      g = MB::Sound::MusicalKey.new(root: 7, mode: :major)
      expect(kf.resolve(w, g).to_a).to eq((MB::Sound.scale(:dorian, :g).weights.blur(0.1) + MB::Sound.tones(MB::Sound::D3) * 2).to_a)
      expect(kf.resolve(w, g)).to equal(kf.resolve(w, g)) # cached
      h = MB::Sound.harmony(0 => MB::Sound.scale(:minor), 2.bars => MB::Sound.scale(:major), loop: 4.bars)
      expect(kf.follows?(h)).to eq(true)
      expect(kf.resolve(h, g).at(0r).to_a).to eq(MB::Sound.scale(:minor, :g).weights.to_a)
    end
  end

  describe 'generators' do
    it 'moves a motifs over a rootless scale to the new root at a key change, on the cycle starting there' do
      clip = -> { MB::Sound.motifs(MB::Sound.scale(:phrygian), 8, evolve: 1, density: 0.9, range: MB::Sound::C3..MB::Sound::C5, seed: 3) }
      bars, = play(clip.()) { MB::Sound.key(:d, at: MB::Sound.bar(3)) }
      [1, 2].each { |b| expect(bars[b] - c_phrygian).to eq([]), "bar #{b}: #{bars[b]}" }
      [3, 4].each { |b| expect(bars[b] - d_phrygian).to eq([]), "bar #{b}: #{bars[b]}" }
      expect(bars[3]).to include(2)
      # The same without the change: C phrygian throughout
      # (a new clip: decisions are remembered per Session epoch, and every
      # new Session starts at epoch 0)
      still, = play(clip.())
      expect(still.values.flatten.uniq - c_phrygian).to eq([])
    end

    it 'follows key changes queued by scheduled blocks and scenes, at any buffer size' do
      clip = -> { MB::Sound.motifs(MB::Sound.scale(:minor), 4, step: 1.n16, evolve: 1, density: 0.9, seed: 5) }
      ref_bars, ref = play(clip.()) { MB::Sound.at_bar(3) { MB::Sound.key(:fs) } }
      expect(ref_bars[3] - classes(MB::Sound::Scale[:minor, :fs])).to eq([])
      expect(ref_bars[2] - classes(MB::Sound::Scale[:minor, :c])).to eq([])
      [[367], *slow_tier([[128]])].each do |(size)|
        _, got = play(clip.(), size: size) { MB::Sound.at_bar(3) { MB::Sound.key(:fs) } }
        expect(got).to eq(ref), "buffer size #{size}"
      end
    end

    it 'plays the session key with no source, and its root and mode with bare scale' do
      m, = play(MB::Sound.motifs(8, density: 0.9, seed: 2)) { MB::Sound.key(:d, :dorian, at: MB::Sound.bar(3)) }
      expect(m[1] - classes(MB::Sound::Scale[:major, :c])).to eq([])
      expect(m[3] - classes(MB::Sound::Scale[:dorian, :d])).to eq([])
      expect(m[3]).to include(11)

      mel, = play(MB::Sound.melody(8, vary: true, seed: 2).loop) { MB::Sound.key(:e, :phrygian, at: MB::Sound.bar(3)) }
      expect(mel[2] - classes(MB::Sound::Scale[:major, :c])).to eq([])
      expect(mel[3] - classes(MB::Sound::Scale[:phrygian, :e])).to eq([])

      st, = play(MB::Sound.strikes(every: 1.n8, chance: 0.9, gap: 1, seed: 2)) { MB::Sound.key(:a, :minor_pentatonic, at: MB::Sound.bar(3)) }
      expect(st[4] - classes(MB::Sound::Scale[:minor_pentatonic, :a])).to eq([])

      gen = MB::Sound.generate(1.bar, sc: MB::Sound.scale) { |_cycle, dice, sc:|
        n = sc.notes(MB::Sound::A3..MB::Sound::A5)
        Array.new(8) { |i| [i * 1/8r, 1/16r, dice.pick(n, :n, i), 0.7] }
      }
      g, = play(gen) { MB::Sound.key(:fs, :minor, at: MB::Sound.bar(2)) }
      expect(g[2] - classes(MB::Sound::Scale[:minor, :fs])).to eq([])
      expect(g[2]).to include(6)

      # A fixed melody (not a generator) without a scale stays chromatic
      expect(MB::Sound.melody(32, seed: 1).events.map { |e| e.value % 12 }.uniq.length).to be > 7
    end

    it 'keeps fixed scales fixed' do
      clip = MB::Sound.motifs(MB::Sound.scale(:phrygian, :c), 8, density: 0.9, seed: 3)
      bars, = play(clip) { MB::Sound.key(:d, at: MB::Sound.bar(2)) }
      expect(bars.values.flatten.uniq - c_phrygian).to eq([])
    end
  end

  describe 'progression' do
    it 'is chords on degrees of the key, each a bar, looping, following the key' do
      pr = MB::Sound.progression(:i, :VI, :III, :VII)
      expect(pr.to_ruby).to eq('progression(:i, :VI, :III, :VII)')
      expect(MB::Sound.progression(1, 6, 3, 7).chords).to eq(pr.chords)
      expect(pr.length).to eq(4)
      top = ->(h, pos) { h.at(pos).to_a.each_with_index.sort_by { |x, i| [-x, i] }.first(3).map(&:last).sort }
      dm = pr.harmony(MB::Sound::MusicalKey.new(root: 2, mode: :minor))
      expect([0r, 1r, 2r, 3r, 4r].map { |p| top.(dm, p) }).to eq([[2, 5, 9], [2, 5, 10], [0, 5, 9], [0, 4, 7], [2, 5, 9]])
      long = MB::Sound.progression([1, 2.bars], 5, scale: MB::Sound.scale(:minor, :a))
      expect(long.follows_key?).to eq(false)
      expect(long.length).to eq(3)
      expect(long.to_ruby).to eq('progression([1, 2.bars], 5, scale: scale(:minor, A4))')
      expect { MB::Sound.progression }.to raise_error(ArgumentError, /needs chords/)
      expect { MB::Sound.progression(:viii) }.to raise_error(ArgumentError, /Roman numeral/)
      expect { MB::Sound.progression(0) }.to raise_error(ArgumentError, /count from 1/)
      expect { MB::Sound.progression(1, every: 1) }.to raise_error(ArgumentError, /lengths like 1.bar/)
    end

    it 'voices a motifs into each chord, in the key as it changes' do
      clip = MB::Sound.motifs(MB::Sound.progression(:i, :iv), 8, density: 0.9, range: MB::Sound::A3..MB::Sound::A5, seed: 4)
      bars, = play(clip, bars: 4) { MB::Sound.key(:d, :minor, at: MB::Sound.bar(3)) }
      # C major's i then iv (C, F) in bars 1-2; D minor's i (D minor) in bar 3
      expect(bars[1] - classes(MB::Sound::Scale[:major, :c])).to eq([])
      expect(bars[3] - classes(MB::Sound::Scale[:minor, :d])).to eq([])
      expect(bars[3]).to include(2)
    end

    it 'spreads over a range for strikes, still following the key' do
      pr = MB::Sound.progression(1, 4)
      field = pr.over(MB::Sound::A2..MB::Sound::A3)
      expect(field.to_ruby).to eq('progression(1, 4).over(A2..A3)')
      expect(MB::Sound::Generative::KeyFollow.follows?(field)).to eq(true)
      st, = play(MB::Sound.strikes(field, every: 1.n8, chance: 0.9, gap: 1, seed: 3)) { MB::Sound.key(:eb, :minor, at: MB::Sound.bar(3)) }
      expect(st[1] - classes(MB::Sound::Scale[:major, :c])).to eq([])
      expect(st[3] - classes(MB::Sound::Scale[:minor, :eb])).to eq([])
    end

    it 'prints back and loads in graph documents' do
      MB::Sound.seed(1)
      clip = MB::Sound.motifs(MB::Sound.progression(:i, :VI, scale: MB::Sound.scale(:minor)), 4, seed: 3)
      graph = clip.number * 0.001
      doc = MB::Sound::GraphIO.dump(graph, name: 'progression')
      expect(doc).to include('motifs(progression(:i, :VI, scale: scale(:minor)), 4, seed: 3)')
      loaded = MB::Sound::GraphIO.load(doc)
      a = RecipeHelpers.render(graph, buffers: 20, size: 512)
      b = RecipeHelpers.render(loaded, buffers: 20, size: 512)
      expect(b).to eq(a)
    end
  end
end
