RSpec.describe('MB::Sound::Generative probability scales', :aggregate_failures) do
  let(:dorian) { MB::Sound.scale(:dorian, :d).weights }
  let(:f_major) { MB::Sound.scale(:major, :f).weights }

  # Ruby text of a value, built again (the console's DSL in scope).
  def rebuild(v)
    MB::Sound.module_eval(v.to_ruby)
  end

  describe MB::Sound::Generative::Weights do
    it 'holds a scale as pitch class weights' do
      expect(dorian.pc).to eq([1, 0, 1, 0, 1, 1, 0, 1, 0, 1, 0, 1].map(&:to_f))
      expect(dorian[:d]).to eq(1)
      expect(dorian[MB::Sound::Cs4]).to eq(0)
      expect(dorian[2]).to eq(1)
      expect(dorian.to_s).to eq('C█ C#  D█ D#  E█ F█ F#  G█ G#  A█ A#  B█')
      expect(MB::Sound.scale(:minor, :a).weights(4, 1, 3, 1, 3, 1, 1).pc.values_at(9, 0, 4, 11)).to eq([4.0, 3.0, 3.0, 1.0])
      expect(MB::Sound.tones(MB::Sound::D3, MB::Sound::F3, MB::Sound::A3).pc.each_index.select { |i| dorian.pc[i] > 0 && MB::Sound.tones(MB::Sound::D3, MB::Sound::F3, MB::Sound::A3).pc[i] > 0 }).to eq([2, 5, 9])
    end

    it 'composites with operators, as values' do
      h = dorian + MB::Sound.tones(:d, :f, :a) * 2
      expect(h[:d]).to eq(3)
      expect(h[:e]).to eq(1)
      expect((2 * dorian)[:d]).to eq(2)
      expect((dorian * MB::Sound.tones(:d, :e))[:f]).to eq(0)
      expect((dorian - 0.5)[:d]).to eq(0.5)
      expect((dorian - 2)[:d]).to eq(0)
      expect(((dorian + 1) ** 2)[:d]).to eq(4)
      expect((dorian / 4)[:d]).to eq(0.25)
      expect(dorian).to be_frozen
      expect { MB::Sound::Generative::Weights.new([1] * 11) }.to raise_error(ArgumentError, /12/)
      expect { dorian * -1 }.to raise_error(ArgumentError, /negative/)
    end

    it 'blurs into neighbors, keeping the total' do
      b = dorian.blur(0.2)
      expect(b.sum).to be_within(1e-12).of(dorian.sum)
      expect(b[:cs]).to be > 0
      expect(b[:d]).to be < 1
      expect(b[:cs]).to be < b[:d]
      wide = dorian.blur(0.3, reach: 3)
      expect(wide.sum).to be_within(1e-12).of(dorian.sum)
      expect(MB::Sound.tones(:c).blur(0.3, reach: 3)[:ds]).to be > 0
      expect { dorian.blur(2) }.to raise_error(ArgumentError, /0 to 1/)
    end

    it 'blends between keys through their common tones' do
      half = dorian.blend(f_major, 0.5)
      # D dorian and F major share C D E F G A; B and Bb each half
      expect(half[:c]).to eq(half[:d])
      expect(half[:b]).to be_within(1e-12).of(half[:as])
      expect(half[:b]).to be_within(1e-12).of(half[:d] / 2)
      expect(dorian.blend(f_major, 0).pc).to eq(dorian.normalize.pc)
      expect(dorian.blend(f_major, 1.5).pc).to eq(f_major.normalize.pc)
      expect(dorian.blend(MB::Sound.scale(:major, :f), 1).pc).to eq(f_major.normalize.pc)
    end

    it 'prints itself back as the expression that made it' do
      h = dorian.blur(0.1) + MB::Sound.tones(MB::Sound::D3, MB::Sound::F3, MB::Sound::A3, MB::Sound::C4) * 1.2
      expect(h.to_ruby).to eq('scale(:dorian, D4).weights.blur(0.1) + tones(D3, F3, A3, C4) * 1.2')
      expect(rebuild(h)).to eq(h)
      x = (dorian + f_major) * (dorian + 1)
      expect(x.to_ruby).to eq('(scale(:dorian, D4).weights + scale(:major, F4).weights) * (scale(:dorian, D4).weights + 1)')
      expect(rebuild(x)).to eq(x)
      y = dorian + (f_major + dorian)
      expect(y.to_ruby).to eq('scale(:dorian, D4).weights + (scale(:major, F4).weights + scale(:dorian, D4).weights)')
      z = (dorian ** 2) ** 0.5
      expect(z.to_ruby).to eq('(scale(:dorian, D4).weights ** 2) ** 0.5')
      expect(rebuild(z)).to eq(z)
      expect(MB::Sound.weights(1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.5).to_ruby).to eq('weights(1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.5)')
      expect(dorian.blend(f_major, 0.25).blur(0.3, reach: 2).to_ruby).to eq('scale(:dorian, D4).weights.blend(scale(:major, F4).weights, 0.25).blur(0.3, reach: 2)')
    end
  end

  describe MB::Sound::Generative::Field do
    let(:field) { dorian.over(MB::Sound::A3..MB::Sound::A5, around: MB::Sound::E5, width: 6) }

    it 'spreads weights over a range with a bell' do
      expect(field.notes).to eq((57..81).to_a)
      expect(field[76]).to eq(1)          # E5, the bell's center
      expect(field[74]).to be < 1
      expect(field[61]).to eq(0)          # C#4: not in D dorian
      expect(field[90]).to eq(0)
      expect(field.tonal.first(4)).to eq([62, 64, 65, 67]) # inside the bell (5% and up)
      expect(field.home(63)).to eq(62)
      expect(dorian.over(48..60).weights.uniq.sort).to eq([0.0, 1.0])
      expect(rebuild(field)).to eq(field)
      expect(field.to_ruby).to eq('scale(:dorian, D4).weights.over(A3..A5, around: E5, width: 6)')
      expect { dorian.over(60..40) }.to raise_error(ArgumentError, /low to high/)
      expect { dorian.over(0..200) }.to raise_error(ArgumentError, /128/)
    end

    it 'draws notes by weight' do
      d = MB::Sound.dice(1)
      notes = Array.new(4000) { |i| d.pick(field, :n, i) }
      t = notes.tally
      expect(t.keys - field.notes).to be_empty
      expect(t.keys).not_to include(61)
      expect(t[76]).to be > t[57] * 4
      sharp = field ** 3
      t2 = Array.new(4000) { |i| d.pick(sharp, :n, i) }.tally
      expect(t2[76].to_f / t2[67]).to be > t[76].to_f / t[67]
      expect(field.near(62, 0.5)).to eq(62)
    end
  end

  describe MB::Sound::Generative::Harmony do
    let(:h) { MB::Sound.harmony(0 => MB::Sound.scale(:dorian, :d), 12.bars => MB::Sound.scale(:dorian, :d), 20.bars => MB::Sound.scale(:major, :f)) }

    it 'blends keyframes over clip positions' do
      expect(h.at(0r).pc).to eq(dorian.pc)
      expect(h.at(12).pc).to eq(dorian.pc)
      expect(h.at(16.bars).pc).to eq((dorian.blend(f_major, 0.5) * 7).pc) # the shape of Weights#blend, at the keyframes' total
      # Between equal keyframes it holds still (it used to drop to sum 1 off the keyframes)
      h.at(6.bars).pc.zip(dorian.pc).each { |a, b| expect(a).to be_within(1e-12).of(b) }
      expect(h.at(12 - 1r / 1024).sum).to be_within(1e-12).of(7)
      expect(h.at(20).pc).to eq(f_major.pc)
      expect(h.at(1000).pc).to eq(f_major.pc)
      expect(h.at(16)).to equal(h.at(16)) # cached
    end

    it 'steps, loops, and curves' do
      c = MB::Sound.harmony(0 => [MB::Sound::D3, MB::Sound::F3, MB::Sound::A3], 1.bar => [MB::Sound::As2, MB::Sound::D3, MB::Sound::F3], loop: 2.bars, curve: :step)
      expect(c.at(1r / 2)[:a]).to eq(1)
      expect(c.at(1)[:as]).to eq(1)
      expect(c.at(5r / 2)[:a]).to eq(1)
      expect(c.at(7)[:as]).to eq(1)
      l = MB::Sound.harmony(0 => dorian, 1.bar => f_major, loop: 2.bars)
      # Halfway through the wrap from F major back to D dorian
      expect(l.at(3r / 2).pc).to eq(l.at(3r / 2 + 4).pc)
      expect(l.at(3r / 2).pc).to eq((f_major.blend(dorian, 0.5) * 7).pc)
      w = MB::Sound.harmony(0 => dorian, 1.bar => MB::Sound.tones(MB::Sound::D3, MB::Sound::F3, MB::Sound::A3))
      expect(w.at(1r / 4).sum).to be_within(1e-12).of(7 * 0.75 + 3 * 0.25) # the total moves from 7 to 3
      s = MB::Sound.harmony(0 => dorian, 1.bar => f_major, curve: :smoothstep)
      expect(s.at(1r / 4)[:as]).to be < MB::Sound.harmony(0 => dorian, 1.bar => f_major).at(1r / 4)[:as]
      expect { MB::Sound.harmony(a: dorian) }.to raise_error(ArgumentError, /positions/)
      expect { MB::Sound.harmony(0 => dorian, 2.bars => f_major, loop: 1.bar) }.to raise_error(ArgumentError, /loop/)
    end

    it 'combines harmonies moment by moment' do
      key = MB::Sound.harmony(0 => dorian, 2.bars => f_major, loop: 4.bars)
      chords = MB::Sound.harmony(0 => [MB::Sound::D3, MB::Sound::F3, MB::Sound::A3], 1.bar => [MB::Sound::G2, MB::Sound::B2, MB::Sound::D3], loop: 2.bars, curve: :step)
      both = key.blur(0.1) + chords * 2
      [0r, 1r / 2, 1, 5r / 2, 3, 7r / 2].each do |t|
        expect(both.at(t)).to eq(key.at(t).blur(0.1) + chords.at(t) * 2)
        expect(both.at(t + 4)).to eq(both.at(t))
      end
      expect(both.period).to be_nil # (chords loop every 2, the key every 4)
      same = key + MB::Sound.harmony(0 => dorian, 1.bar => f_major, loop: 4.bars)
      expect(same.period).to eq(4)
      expect(same.at(9r / 2)).to eq(same.at(1r / 2))
      expect(MB::Sound.harmony(0 => dorian).blur(0.1) + key).to be_a(MB::Sound::Generative::Harmony)
    end

    it 'applies operators and blur at each moment, and prints back' do
      b = h.blur(0.2) + MB::Sound.tones(:d) * 2
      expect(b.at(16.bars)).to eq(h.at(16.bars).blur(0.2) + MB::Sound.tones(:d) * 2)
      expect(b.to_ruby).to eq('harmony(0 => scale(:dorian, D4), 12.bars => scale(:dorian, D4), 20.bars => scale(:major, F4)).blur(0.2) + tones(:d) * 2')
      expect(rebuild(b).at(16.bars)).to eq(b.at(16.bars))
      f = b.over(MB::Sound::A3..MB::Sound::A5, around: MB::Sound::E5)
      expect(f.at(16.bars)).to eq(b.at(16.bars).over(MB::Sound::A3..MB::Sound::A5, around: MB::Sound::E5))
      expect(f.notes).to eq((57..81).to_a)
      looped = MB::Sound.harmony(0 => dorian, 1.bar => f_major, loop: 2.bars, curve: :step)
      expect(looped.to_ruby).to eq('harmony(0 => scale(:dorian, D4).weights, 1.bar => scale(:major, F4).weights, curve: :step, loop: 2.bars)')
    end

    it 'combines Weights with Harmonies on either side' do
      key = MB::Sound.harmony(0 => dorian, 2.bars => f_major, loop: 4.bars)
      chords = MB::Sound.harmony(0 => MB::Sound.chord(:min7, root: :d3), 1.bar => MB::Sound.chord(:'7', root: :g2), loop: 2.bars, curve: :step)
      w = dorian.blur(0.2)
      sum = w + chords * 2
      expect(sum).to be_a(MB::Sound::Generative::Harmony)
      expect(sum.to_ruby).to eq('scale(:dorian, D4).weights.blur(0.2) + harmony(0 => chord(:min7, root: :d3), 1.bar => chord(:"7", root: :g2), curve: :step, loop: 2.bars) * 2')
      masked = w * chords
      less = w - chords
      [0r, 1r / 2, 1, 3r / 2, 7, 9r / 2].each do |t|
        expect(sum.at(t)).to eq(chords.at(t) * 2 + w)
        expect(sum.at(t).pc).to eq((chords * 2 + w).at(t).pc) # commutative, bit for bit
        expect(masked.at(t).pc).to eq((chords * w).at(t).pc)
        expect(less.at(t)).to eq(w - chords.at(t))
        expect((w + key).at(t)).to eq(key.at(t) + w)
      end
      expect(sum.period).to eq(2)
      expect((w + key).period).to eq(4)
      expect((sum + key).period).to be_nil # (2 and 4)
      expect((w + chords).blur(0.1).period).to eq(2)
      expect((w + chords).blur(0.1).at(3r / 2)).to eq((w + chords.at(3r / 2)).blur(0.1))
      expect(rebuild(sum).at(3r / 2)).to eq(sum.at(3r / 2))
      expect(rebuild(less).at(1r / 2)).to eq(less.at(1r / 2))
      expect((2 * chords + w).at(1)).to eq(sum.at(1))
    end

    it 'blends Weights toward a Harmony as a Harmony' do
      key = MB::Sound.harmony(0 => f_major, 2.bars => MB::Sound.chord(:min7, root: :g), loop: 4.bars)
      b = dorian.blend(key, 0.3)
      expect(b).to be_a(MB::Sound::Generative::Harmony)
      expect(b.to_ruby).to eq('scale(:dorian, D4).weights.blend(harmony(0 => scale(:major, F4).weights, 2.bars => chord(:min7, root: :g), loop: 4.bars), 0.3)')
      [0r, 1r / 2, 1, 3, 5, 13r / 2].each do |t|
        expect(b.at(t)).to eq(dorian.blend(key.at(t), 0.3))
      end
      expect(b.period).to eq(4)
      expect(rebuild(b).at(3)).to eq(b.at(3))
      expect(dorian.blend(f_major, 0.3)).to be_a(MB::Sound::Generative::Weights)
    end

    it 'requires lengths for keys and loops (0 may start), suggesting .bars' do
      expect { MB::Sound.harmony(0 => dorian, 12 => f_major) }.to raise_error(ArgumentError, /write 12\.bars/)
      expect { MB::Sound.harmony(0 => dorian, 1r / 2 => f_major) }.to raise_error(ArgumentError, %r{write \(\(1/2\)\)\.bars|write \(1/2r\)\.bars|write \(\(1/2r\)\)\.bars|\(1/2r\)})
      expect { MB::Sound.harmony(0 => dorian, 1.5 => f_major) }.to raise_error(ArgumentError, /write \(1\.5\)\.bars/)
      expect { MB::Sound.harmony(0 => dorian, 1.bar => f_major, loop: 4) }.to raise_error(ArgumentError, /loops are lengths: write 4\.bars/)
      expect { MB::Sound.harmony(0 => dorian, 2.seconds => f_major) }.to raise_error(ArgumentError, /follow the tempo/)
      expect { MB::Sound.harmony(0 => dorian, -1 => f_major) }.to raise_error(ArgumentError, /from 0/)
      expect(MB::Sound.harmony(0.0 => dorian, 3.beats => f_major).keys.map(&:first)).to eq([0r, 3r / 4])
      expect(MB::Sound.harmony(0r => dorian).at(5)).to eq(dorian)
    end

    it 'reads plain numbers as bars in live mode, with a warning' do
      allow(MB::Sound).to receive(:live?).and_return(true)
      h = nil
      expect { h = MB::Sound.harmony(0 => dorian, 12 => f_major, loop: 16) }.to output(/write 12\.bars.*read as 12\.bars.*write 16\.bars/m).to_stderr
      expect(h.keys.map(&:first)).to eq([0r, 12r])
      expect(h.loop_length).to eq(16)
    end

    it 'takes named chords as keyframes' do
      c = MB::Sound.harmony(0 => MB::Sound.chord(:min, root: :d3), 1.bar => MB::Sound.chord(:maj, root: :bb2), loop: 2.bars, curve: :step)
      expect(c.at(1r / 2)).to eq(MB::Sound.tones(:d, :f, :a))
      expect(c.at(3r / 2)).to eq(MB::Sound.tones(:as, :d, :f))
      expect(c.to_ruby).to eq('harmony(0 => chord(:min, root: :d3), 1.bar => chord(:maj, root: :bb2), curve: :step, loop: 2.bars)')
      expect(rebuild(c).at(3r / 2)).to eq(c.at(3r / 2))
    end
  end

  describe MB::Sound::Generative::Chord do
    it 'makes chord layers from qualities and roots, like tones' do
      expect(MB::Sound.chord(:min7, root: :d).weights).to eq(MB::Sound.tones(MB::Sound::D3, MB::Sound::F3, MB::Sound::A3, MB::Sound::C4))
      expect(MB::Sound.chord(:min7, root: :d).weights.to_ruby).to eq('chord(:min7, root: :d).weights')
      h = dorian.blur(0.15) + MB::Sound.chord(:min7, root: :d).weights * 1.5
      expect(h).to eq(dorian.blur(0.15) + MB::Sound.tones(:d, :f, :a, :c) * 1.5)
      expect(h.to_ruby).to eq('scale(:dorian, D4).weights.blur(0.15) + chord(:min7, root: :d).weights * 1.5')
      expect(rebuild(h)).to eq(h)

      w = MB::Sound.chord(:min7, root: MB::Sound::D3).weights(2, 1, 1.5, 1)
      expect(w.pc.values_at(2, 5, 9, 0)).to eq([2, 1, 1.5, 1])
      expect(w.to_ruby).to eq('chord(:min7, root: D3).weights(2, 1, 1.5, 1)')
      expect(rebuild(w)).to eq(w)
      expect { MB::Sound.chord(:min, root: :d).weights(-1) }.to raise_error(ArgumentError, /not negative/)
    end

    it 'knows the common qualities and their aliases' do
      {
        maj: [0, 4, 7], min: [0, 3, 7], dim: [0, 3, 6], aug: [0, 4, 8], sus2: [0, 2, 7], sus4: [0, 5, 7],
        '7': [0, 4, 7, 10], dom7: [0, 4, 7, 10], maj7: [0, 4, 7, 11], min7: [0, 3, 7, 10], m7: [0, 3, 7, 10],
        m7b5: [0, 3, 6, 10], min7b5: [0, 3, 6, 10], dim7: [0, 3, 6, 9], '6': [0, 4, 7, 9], maj6: [0, 4, 7, 9],
        min6: [0, 3, 7, 9], m6: [0, 3, 7, 9], '9': [0, 4, 7, 10, 14], maj9: [0, 4, 7, 11, 14], min9: [0, 3, 7, 10, 14],
        add9: [0, 4, 7, 14], power: [0, 7],
      }.each do |q, offsets|
        expect(MB::Sound.chord(q, root: MB::Sound::C4).notes.map(&:number)).to eq(offsets.map { |o| 60 + o }), q.inspect
      end
      expect(MB::Sound.chord('min7', root: :c).quality).to eq(:min7)
      expect { MB::Sound.chord(:nope, root: :c) }.to raise_error(ArgumentError, /Unknown chord quality :nope/)
    end

    it 'takes roots as names, Notes, numbers, and Pitches, with inversions' do
      expect(MB::Sound.chord(:maj, root: :d).notes.map(&:number)).to eq([MB::Sound::D4, MB::Sound::Fs4, MB::Sound::A4].map(&:number)) # octave 4 like scale
      expect(MB::Sound.chord(:maj, root: :fs2).notes.first.number).to eq(MB::Sound::Fs2.number)
      expect(MB::Sound.chord(:maj, root: 50).root).to eq(MB::Sound::D3.number)
      expect(MB::Sound.chord(:min, root: 146.83.hz).root).to eq(MB::Sound::D3.number) # nearest note
      expect(MB::Sound.chord(:maj7, root: MB::Sound::F3, inversion: 1).notes.map(&:number)).to eq([MB::Sound::A3, MB::Sound::C4, MB::Sound::E4, MB::Sound::F4].map(&:number))
      expect(MB::Sound.chord(:maj7, root: MB::Sound::F3, inversion: 3).notes.map(&:number)).to eq([64, 65, 69, 72])
      inv = MB::Sound.chord(:min, root: :a3, inversion: 2)
      expect(inv.weights).to eq(MB::Sound.chord(:min, root: :a3).weights)
      expect(inv.to_ruby).to eq('chord(:min, root: :a3, inversion: 2)')
      expect(rebuild(inv)).to eq(inv)
      expect { MB::Sound.chord(:min, root: :a3, inversion: 3) }.to raise_error(ArgumentError, /inversion is an Integer from 0 to 2/)
      expect { MB::Sound.chord(:min, root: 50.5) }.to raise_error(ArgumentError, /root/)
      expect { MB::Sound.chord(:min, root: 'x') }.to raise_error(ArgumentError, /Unknown root/)
    end

    it 'leaves every other chord call to the MIDI transform' do
      [
        -> { MB::Sound.chord(0, 7, 15) }, -> { MB::Sound.chord(:min7) }, -> { MB::Sound.chord('maj') },
        -> { MB::Sound.chord(2, 4, scale: :major, root: :c) }, -> { MB::Sound.chord(-1.oct, velocity: 0.5) },
        -> { MB::Sound.chord(:fifth, overlap: :stack) },
      ].each do |call|
        expect(call.()).to be_a(MB::Sound::MIDI::Transform::Spec)
      end
      expect(MB::Sound.seq(MB::Sound::C4).chord(:maj)).to be_a(MB::Sound::MIDI::Stream)
    end
  end
end
