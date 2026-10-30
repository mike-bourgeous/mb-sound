require_relative '../../../support/ruby_value_check'

# MB::Sound::RubyValue, the one printer for plain values (printers-1): every
# value prints in one spelling (Rationals as 3/4r and 3r) and reloads as an
# equal value of the same class, and no code outside it formats Rationals
# as Ruby itself.
# (constants in a module of their own: spec files share the top level)
module RubyValueSpec; end

RSpec.describe(MB::Sound::RubyValue, :aggregate_failures) do
  let(:rv) { MB::Sound::RubyValue }

  # [source, printed] pairs: each source builds a value inside MB::Sound
  # that prints as +printed+.
  RubyValueSpec::CASES = [
    ['3/4r', '3/4r'], ['3r', '3r'], ['-3/4r', '-3/4r'], ['-3r', '-3r'], ['Rational(1, 192)', '1/192r'],
    ['0.5', '0.5'], ['2', '2'], ['-2', '-2'], ['1.0e-05', '1.0e-05'], ['2.0', '2.0'],
    ['Float::INFINITY', 'Float::INFINITY'], ['-Float::INFINITY', '-Float::INFINITY'], ['Complex(1, 2)', 'Complex(1, 2)'],
    ['-6.db', '-6.db'], ['(13/2r).db', '(13/2r).db'], ['3r.db', '3r.db'], ['-6.5.db', '-6.5.db'],
    ['440.hz', '440.hz'], ['440.5.hz', '440.5.hz'], ['(881/2r).hz', '440.5.hz'], ['A4', 'A4'], ['Cs3', 'Cs3'], ['1.bar.hz', '1.bar.hz'],
    ['2.seconds', '2.seconds'], ['(1/60r).seconds', '(1/60r).seconds'], ['3r.seconds', '3r.seconds'], ['0.25.seconds', '250.ms'],
    ['250.ms', '250.ms'], ['(-0.5).seconds', '(-500).ms'], ['(-1/3r).seconds', '(-1/3r).seconds'], ['96.samples', '96.samples'], ['(3/2r).samples', '(3/2r).samples'],
    ['1.n8.dotted', '1.n8.dotted'], ['3.n16', '3.n16'], ['2.bars', '2.bars'], ['(3/2r).bars', '(3/2r).bars'], ['1.5.bars', '1.5.bars'],
    ['2r.bars', '2r.bars'], ['3.beats', '3.beats'], ['Sequence::Duration.new(1/192r)', 'Sequence::Duration.new(1/192r)'],
    ['7.semitones', '7.st'], ['-7.semitones', '(-7).st'], ['(1/2r).octaves', '(1/2r).oct'], ['50.cents', '50.cents'],
    ['90.degrees', '90.degrees'], ['0.25.cycles', '0.25.cycles'], ['(1/4r).cycles', '(1/4r).cycles'],
    ['1..2', '1..2'], ['1/4r..3/4r', '1/4r..3/4r'], ['1...4', '1...4'], ['(1..)', '1..'], ['-1.0..1.0', '-1.0..1.0'],
    [':a', ':a'], [':"a b"', ':"a b"'], ["'x'", '"x"'], ['nil', 'nil'], ['true', 'true'],
    ['[1, 3/4r, :a]', '[1, 3/4r, :a]'], ['{ a: 3r, "b c": 1, 2 => 4 }', '{ a: 3r, "b c": 1, 2 => 4 }'], ['{}', '{}'],
    ['(150.hz..8000.hz).at(2400.hz)', '(150.hz..8000.hz).at(2400.hz)'], ['(0r..1r).at(1/4r)', '(0r..1r).at(1/4r)'],
    ['138.bpm', '138.bpm'], ['(555/4r).bpm', '(555/4r).bpm'], ['138.75.bpm', '138.75.bpm'],
    ['scale(:minor, :a)', 'scale(:minor, A4)'], ['0.5.attack', '0.5.attack'], ['(1/2r).attack', '(1/2r).attack'],
    ['Curve[:back, overshoot: 0.3]', 'Curve[:back, overshoot: 0.3]'],
  ].freeze

  RubyValueSpec::CASES.each do |source, printed|
    it "prints #{source} as #{printed}, which reloads as the same value" do
      v = RubyValueCheck.reload(source)
      text = rv.to_ruby(v)
      expect(text).to eq(printed)
      expect(RubyValueCheck.same?(RubyValueCheck.reload(text), v)).to eq(true), "#{text} reloads as #{RubyValueCheck.reload(text).inspect}"
    end
  end

  it 'reloads every printed case through the graph document loader (no eval)' do
    RubyValueSpec::CASES.each do |source, printed|
      v = RubyValueCheck.reload(source)
      got = RubyValueCheck.load_value(printed)
      expect(RubyValueCheck.same?(got, v)).to eq(true), "#{source}: #{printed} loads as #{got.inspect} (#{got.class})"
    end
  end

  it 'prints long Floats that are exactly k/10 dB as k.db only with gains: true' do
    g = 10 ** (-6 / 20.0)
    expect(rv.to_ruby(g)).to eq(g.to_s)
    expect(rv.to_ruby(g, gains: true)).to eq('-6.db')
    expect(rv.to_ruby([g], gains: true)).to eq('[-6.db]')
  end

  it 'prints nested values through the block' do
    expect(rv.to_ruby([1, :a]) { |x| "<#{x}>" }).to eq('[<1>, <a>]')
    expect(rv.to_ruby({ a: 3/4r }) { |x| "<#{x}>" }).to eq('{ a: <3/4> }')
    expect(rv.to_ruby(1..2) { |x| "n(#{x})" }).to eq('n(1)..n(2)')
  end

  it 'gives operand precedences for parentheses' do
    expect(rv.precedence(3/4r)).to eq(:quotient)
    expect(rv.precedence(-3)).to eq(:unary)
    expect(rv.precedence(3r)).to eq(:atom)
    expect(rv.precedence(-6.db)).to eq(:atom)
    expect(rv.unit(3/4r, 'seconds')).to eq('(3/4r).seconds')
    expect(rv.unit(-2, 'st')).to eq('(-2).st')
  end

  it 'raises Unprintable for values it has no spelling for (text returns nil)' do
    expect { rv.to_ruby(Object.new) }.to raise_error(MB::Sound::RubyValue::Unprintable, /can't print a Object/)
    expect(rv.text(Object.new)).to be_nil
  end

  describe 'guard' do
    # Files outside RubyValue that format Rationals themselves, and why
    # they may.
    RubyValueSpec::ALLOWED = {
      'lib/mb/sound/table.rb' => 'table cells for people (3/4, no r), not Ruby',
      'lib/mb/sound/sequence/transport.rb' => 'time signature labels ("7/8"), not Ruby',
      'lib/mb/sound/clock.rb' => 'describe: "5/4 of the session tempo", words, not Ruby',
    }.freeze

    # Private Rational spellings: `"#{r.numerator}r"`, `"#{n}r/#{d}"`,
    # `"#{n}/#{d}r"`, and whole Rationals printed as their numerator.
    RubyValueSpec::PATTERNS = [
      /numerator\}r/,
      /\}r\/#\{/,
      /denominator\}r/,
      /denominator == 1 \?[^:]*numerator\.to_s/,
      /numerator\}\/#\{[^}]*denominator\}/,
    ].freeze

    it 'finds no Rational formatting outside RubyValue' do
      root = File.expand_path('../../../..', __dir__)
      files = Dir[File.join(root, '{lib,bin}/**/*.rb')] - [File.join(root, 'lib/mb/sound/ruby_value.rb')]
      found = files.flat_map { |f|
        rel = f.delete_prefix("#{root}/")
        next [] if RubyValueSpec::ALLOWED.key?(rel)
        File.readlines(f).each_with_index.filter_map { |line, i|
          next if line.strip.start_with?('#')
          "#{rel}:#{i + 1}: #{line.strip}" if RubyValueSpec::PATTERNS.any? { |p| line.match?(p) }
        }
      }
      expect(found).to eq([]), "print values with MB::Sound::RubyValue (to_ruby, number, rational, unit) instead:\n#{found.join("\n")}"
    end
  end
end
