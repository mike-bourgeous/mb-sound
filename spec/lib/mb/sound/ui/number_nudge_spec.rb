require 'mb/sound/ui/number_nudge'

RSpec.describe(MB::Sound::UI::NumberNudge, :aggregate_failures) do
  let(:nudge) { MB::Sound::UI::NumberNudge }

  # The cursor at the first byte of +mark+ in +code+ (+after+: past it).
  def pos(code, mark, after: false)
    i = code.index(mark) or raise "no #{mark.inspect} in #{code.inspect}"
    after ? i + mark.length : i
  end

  describe '.literals' do
    it 'finds numbers in code, with their signs, and nothing in strings, symbols, identifiers, labels, or comments' do
      code = %q{fx :d13, ->{ it.chebyshev(h1: 0.1, h3: -3, h13: 1).filter(:highpass, cutoff: 300) } # 7 bars}
      expect(nudge.literals(code).map(&:text)).to eq(['0.1', '-3', '1', '300'])

      code = %q{x = "a 5 #{2}"; :h13; C4; A1..A4; 1.n8; 0.5.beat; 3/4r; 1e-3; 48_000; -10.db; 150..1500; n8}
      expect(nudge.literals(code).map(&:text)).to eq(%w[2 1 0.5 3 4r 1e-3 48_000 -10 150 1500])
    end

    it 'keeps a binary minus out of the number' do
      expect(nudge.literals('a - 3; b-2; c -1; d(-4)').map(&:text)).to eq(%w[3 2 -1 -4])
    end

    it 'gives byte offsets' do
      code = 'p "é", 12'
      l = nudge.literals(code).first
      expect(code.byteslice(l.start, l.stop - l.start)).to eq('12')
    end
  end

  describe '.at, .neighbor, .nearest' do
    let(:code) { 'f(cutoff: 300, q: 0.5).at(150..1500)' }

    it 'finds the number under the cursor or right after it' do
      expect(nudge.at(code, pos(code, '300')).text).to eq('300')
      expect(nudge.at(code, pos(code, '00,')).text).to eq('300')
      expect(nudge.at(code, pos(code, '300', after: true)).text).to eq('300')
      expect(nudge.at(code, pos(code, '..')).text).to eq('150')
      expect(nudge.at(code, pos(code, '1500')).text).to eq('1500')
      expect(nudge.at(code, pos(code, 'cutoff'))).to be_nil
    end

    it 'steps between numbers and finds the nearest' do
      expect(nudge.neighbor(code, pos(code, '300'), 1).text).to eq('0.5')
      expect(nudge.neighbor(code, pos(code, '0.5'), -1).text).to eq('300')
      expect(nudge.neighbor(code, pos(code, '1500'), 1)).to be_nil
      expect(nudge.neighbor(code, 0, -1)).to be_nil
      expect(nudge.nearest(code, 0).text).to eq('300')
      expect(nudge.nearest(code, code.length).text).to eq('1500')
      expect(nudge.nearest('A1..A4', 2)).to be_nil
    end
  end

  describe '.step' do
    {
      ['300', 1] => '301', ['300', -1] => '299', ['300', 1, :coarse] => '310',
      ['0.125', 1] => '0.126', ['0.125', -1, :coarse] => '0.115', ['0.125', 1, :fine] => '0.1251',
      ['0.19', 1] => '0.20', ['0.1', 2] => '0.3', ['0.29', 1] => '0.30',
      ['1', -1] => '0', ['0', -1] => '-1', ['-1', 1] => '0', ['-3', 5] => '2',
      ['-0.1', 1] => '0.0', ['0.0', -1] => '-0.1', ['-0.1', 1, :fine] => '-0.09',
      ['9', 1] => '10', ['10', -1] => '9', ['99', 1] => '100',
      ['48_000', 1] => '48_001', ['1_000', -1] => '999', ['999_999', 1] => '1_000_000',
      ['1e-3', 1] => '2e-3', ['1.5e3', 1] => '1.6e3', ['2.5E+2', -1, :coarse] => '1.5E+2',
      ['4r', 1] => '5r', ['0.5r', 1] => '0.6r', ['2i', 1] => '3i', ['-10', 3] => '-7',
    }.each do |(text, steps, size), out|
      it "steps #{text} by #{steps} (#{size || :normal}) to #{out}" do
        expect(nudge.step(text, steps, size || :normal)).to eq(out)
      end
    end

    it 'keeps an Integer an Integer and refuses a fine step on one, naming the way to finer steps' do
      expect { nudge.step('300', 1, :fine) }.to raise_error(MB::Sound::UI::NumberNudge::Refused, /300 is an Integer: write 300\.0 for finer steps/)
      expect { nudge.step('-2', 1, :fine) }.to raise_error(MB::Sound::UI::NumberNudge::Refused, /write -2\.0/)
    end

    it 'refuses hexadecimal, binary, and octal literals' do
      %w[0x1f 0b101 0o7 07 0d12].each do |t|
        expect { nudge.step(t, 1) }.to raise_error(MB::Sound::UI::NumberNudge::Refused), t
      end
    end

    it 'never writes binary float noise over many steps' do
      t = '0.1'
      20.times { t = nudge.step(t, 1) }
      expect(t).to eq('2.1')
      20.times { t = nudge.step(t, -1, :coarse) }
      expect(t).to eq('-17.9')
    end
  end

  describe '.nudge' do
    it 'replaces the number at the cursor, keeping the cursor on the same digit from its end' do
      code = 'track(:t) { it.hz.ramp.filter(:lowpass, cutoff: 999, quality: 5.bar.lfo.at(1..5)) }'
      r = nudge.nudge(code, pos(code, '9, q'), 1)
      expect(r[:code]).to eq(code.sub('999', '1000'))
      expect(r[:code][r[:pos]]).to eq('0') # the last digit, as before
      expect(r.values_at(:from, :to)).to eq(%w[999 1000])

      r = nudge.nudge(code, pos(code, '5.bar'), -1)
      expect(r[:code]).to include('quality: 4.bar')
      r = nudge.nudge(code, pos(code, '5))'), 1, :coarse)
      expect(r[:code]).to include('at(1..15)')
    end

    it 'takes the sign away and back through zero' do
      r = nudge.nudge('h3: -1, h5: 2', 5, 1)
      expect(r[:code]).to eq('h3: 0, h5: 2')
      r = nudge.nudge(r[:code], r[:pos], -2)
      expect(r[:code]).to eq('h3: -2, h5: 2')
      expect(r[:code][r[:pos]]).to eq('2') # still on the last digit
    end

    it 'refuses where there is no number' do
      expect { nudge.nudge('seq(A1, A4)', 5, 1) }.to raise_error(MB::Sound::UI::NumberNudge::Refused, /no number/)
      expect { nudge.nudge('"5 dB"', 1, 1) }.to raise_error(MB::Sound::UI::NumberNudge::Refused)
      expect { nudge.nudge(':h13', 3, 1) }.to raise_error(MB::Sound::UI::NumberNudge::Refused)
    end
  end
end
