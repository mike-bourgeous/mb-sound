RSpec.describe('Negating Notes, Steps, and nodes (audit for Note#!)') do
  # Note#! and Seq::Step#! mark accents (`!A1`), so `!x`, `!!x`, and
  # `not x` on anything that may hold a Note or Step no longer give a
  # Boolean.  lib/ tests such values with #nil? (or `if x`, which doesn't
  # call #!).  This scan catches bare negations of variables whose names
  # suggest notes, pitches, steps, or graph nodes.
  risky_names = %w[
    note notes pitch step steps item items value master source sync_source node nodes
    input inputs freq frequency cutoff tone signal other
  ].freeze

  risky = /(?:(?<![!=\w])!!?\s*|\bnot\s+)@?(?:#{risky_names.join('|')})\b(?!\s*(?:\.|&\.|\(|\[|\?|=[^=]))/

  it 'finds no bare negations of note-like or node-like variables in lib/' do
    hits = Dir[File.expand_path('../../../../lib/**/*.rb', __dir__)].flat_map { |path|
      File.readlines(path).each_with_index.filter_map { |line, idx|
        code = line.sub(/(?<!['"])#(?![{]).*$/, '') # drop comments (roughly)
        "#{path.sub(%r{.*/lib/}, 'lib/')}:#{idx + 1}: #{line.strip}" if code.match?(risky)
      }
    }

    expect(hits).to eq([])
  end

  it 'the scan catches the patterns it is meant to' do
    expect('x if !note').to match(risky)
    expect('a = !!@source').to match(risky)
    expect('return if not pitch').to match(risky)
    expect('x if !note.nil?').not_to match(risky)
    expect('x if !value&.empty?').not_to match(risky)
    expect('x if a != note').not_to match(risky)
  end

  it 'overrides ! only on Notes and Steps' do
    expect(!MB::Sound::C4).to be_a(MB::Sound::Sequence::Seq::Step)
    expect((!MB::Sound::C4).accented?).to eq(true)
    expect(!(!MB::Sound::C4)).to be_a(MB::Sound::Sequence::Seq::Step)
    expect(!440.hz).to eq(false)
    expect(!440.hz.ramp).to eq(false)
    expect(!MB::Sound.seq(MB::Sound::C4)).to eq(false)
  end

  describe 'paths that take Notes' do
    it 'compares Notes with != without calling #!' do
      c = MB::Sound::C4
      expect(c != MB::Sound::D4).to eq(true)
      expect(c != c).to eq(false)
    end

    it 'syncs a tone to a Note master' do
      t = 220.hz.ramp.sync(MB::Sound::A2)
      expect(t.sample(256).abs.max).to be > 0.1
    end

    it 'uses a Note as a filter cutoff' do
      sig = 220.hz.ramp.lp4(MB::Sound::C6, resonance: 0.3)
      expect(sig.sample(256).abs.max).to be > 0.01
    end

    it 'makes Ranges of Notes' do
      expect((MB::Sound::C4..MB::Sound::E4).to_a.map(&:number)).to eq([60, 61, 62, 63, 64])
    end

    it 'sequences Notes and Pitches' do
      clip = MB::Sound.seq(MB::Sound::C4, nil, 440.hz, MB::Sound::E4).n8
      expect(clip.events.length).to eq(3)
    end
  end
end
