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
      expect(h.at(16.bars).pc).to eq(dorian.blend(f_major, 0.5).pc)
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
      l = MB::Sound.harmony(0 => dorian, 1 => f_major, loop: 2)
      # Halfway through the wrap from F major back to D dorian
      expect(l.at(3r / 2).pc).to eq(l.at(3r / 2 + 4).pc)
      expect(l.at(3r / 2).pc).to eq(f_major.blend(dorian, 0.5).pc)
      s = MB::Sound.harmony(0 => dorian, 1 => f_major, curve: :smoothstep)
      expect(s.at(1r / 4)[:as]).to be < MB::Sound.harmony(0 => dorian, 1 => f_major).at(1r / 4)[:as]
      expect { MB::Sound.harmony(a: dorian) }.to raise_error(ArgumentError, /positions/)
      expect { MB::Sound.harmony(0 => dorian, 2 => f_major, loop: 1) }.to raise_error(ArgumentError, /loop/)
    end

    it 'combines harmonies moment by moment' do
      key = MB::Sound.harmony(0 => dorian, 2 => f_major, loop: 4)
      chords = MB::Sound.harmony(0 => [MB::Sound::D3, MB::Sound::F3, MB::Sound::A3], 1 => [MB::Sound::G2, MB::Sound::B2, MB::Sound::D3], loop: 2, curve: :step)
      both = key.blur(0.1) + chords * 2
      [0r, 1r / 2, 1, 5r / 2, 3, 7r / 2].each do |t|
        expect(both.at(t)).to eq(key.at(t).blur(0.1) + chords.at(t) * 2)
        expect(both.at(t + 4)).to eq(both.at(t))
      end
      expect(both.period).to be_nil # (chords loop every 2, the key every 4)
      same = key + MB::Sound.harmony(0 => dorian, 1 => f_major, loop: 4)
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
  end
end
