# Time math (session-core-1, arch-session section 9): conversions between
# tempos, seconds, whole notes, and frames live in Transport and TempoMap
# (design/notes/tempo_sync.md, "Time math"), so a later change to how
# tempo moves within a span changes them in one place.  This guard fails a
# new inline copy in lib/ or bin/; the examples below pin the helpers'
# arithmetic to the inline forms they replaced, bit for bit.
RSpec.describe('time math', :aggregate_failures) do
  root = File.expand_path('../../../../..', __dir__)
  home = %w[lib/mb/sound/sequence/transport.rb lib/mb/sound/sequence/tempo_map.rb]

  # [pattern, what to call instead]
  rules = [
    [%r{[*/]\s*240(?:\.0|r)?\b|\b240(?:\.0|r)?\s*[*/]}, 'TempoMap.seconds_at / .whole_notes_at / .whole_notes_per_second / .bpm_of (the literal 240)'],
    [%r{whole_notes_per_second(?:\.to_[rf])?\s*[*/]|[*/]\s*(?:[\w@.]+\.)?whole_notes_per_second\b}, 'Transport#seconds_of / #whole_notes_of / #frames_of / #whole_notes_per_frame'],
    [%r{\bwnps\b(?:\.to_[rf])?\s*[*/]|[*/]\s*@?\w*wnps\b}, 'TempoMap.seconds_for / .whole_notes_for (a rate held in a variable)'],
    [%r{\(\([^()]+ - [^()]+\) / @?[\w.]*per_(?:sample|frame)\)\.floor}, 'Transport.frame_at(pos, from, per_frame)'],
    [%r{[\w@.)\]] \+ [\w@.()]+ \* @?[\w.]*per_(?:sample|frame)\b}, 'Transport.position_at(from, offset, per_frame)'],
  ]

  # path => [[line text fragment, reason]]
  allowed = {
    'lib/mb/sound/ui/sound_panes.rb' => [['PLAYHEAD_STEP = 1 / 240.0', 'a frame-rate step (finer than a frame at 120 fps), not a tempo']],
  }

  it 'keeps tempo, seconds, whole-note, and frame conversions in Transport and TempoMap' do
    files = Dir.glob(File.join(root, '{lib,bin}/**/*.rb')).map { |f| f.delete_prefix("#{root}/") } - home
    found = []
    files.each do |f|
      File.foreach(File.join(root, f)).with_index(1) do |line, n|
        code = line.sub(/(?:^|\s)#(?![{]).*$/, '') # (comments)
        next if code.strip.empty?
        rules.each do |re, instead|
          next unless code.match?(re)
          next if allowed.fetch(f, []).any? { |frag, _| line.include?(frag) }
          found << "#{f}:#{n}: #{line.strip}\n    use #{instead}"
        end
      end
    end
    expect(found).to eq([]), "inline time math (see design/notes/tempo_sync.md, \"Time math\"):\n#{found.join("\n")}"
  end

  it 'lists only allowed lines that still exist' do
    allowed.each do |f, entries|
      text = File.read(File.join(root, f))
      entries.each { |frag, _| expect(text).to include(frag), "#{f}: #{frag.inspect} is gone; remove it from the allowed list" }
    end
  end

  describe 'helpers' do
    let(:t) { MB::Sound::Sequence::Transport.new(bpm: 138.75) }
    let(:map) { MB::Sound::Sequence::TempoMap }
    let(:wnps) { t.whole_notes_per_second }

    it 'converts tempos exactly' do
      expect(wnps).to eq(Rational(555, 4) / 240)
      expect(map.whole_notes_per_second(555/4r)).to eq(wnps)
      expect(map.bpm_of(wnps)).to eq(555/4r)
      expect(MB::Sound::Tempo.new(138.75).whole_notes_per_second).to eq(wnps)
    end

    it 'matches the inline Float forms bit for bit' do
      rng = Random.new(5)
      200.times do
        bpm = 40 + rng.rand * 200
        s = rng.rand * 30
        wn = rng.rand * 8
        tr = MB::Sound::Sequence::Transport.new(bpm: bpm)
        r = tr.whole_notes_per_second
        expect(map.seconds_at(1.0, bpm)).to eql(240.0 / bpm)
        expect(map.seconds_at(wn, bpm)).to eql(wn * 240.0 / bpm)
        expect(map.whole_notes_at(s, 128)).to eql(s * 128 / 240.0)
        expect(tr.seconds_of(wn)).to eql(wn / r)
        expect(tr.whole_notes_of(s)).to eql(s * r)
        expect(tr.whole_notes_of(1.0)).to eql(r.to_f)
        expect(tr.frames_of(wn, 48000.0)).to eql(wn / r * 48000.0)
      end
    end

    it 'keeps Rationals exact' do
      expect(t.seconds_of(1/4r)).to eq(1/4r / wnps)
      expect(t.whole_notes_of(3/2r)).to eq(3/2r * wnps)
      expect(t.frames_of(1r, 48000)).to eq(1r / wnps * 48000)
      expect(t.frames_of(1r, 48000)).to be_a(Rational)
      expect(map.seconds_for(1r, wnps)).to eq(1r / wnps)
      expect(map.whole_notes_for(2r, wnps)).to eq(2r * wnps)
    end

    it 'gives whole notes per frame exactly, cached while the tempo and rate hold' do
      ps = t.whole_notes_per_frame(48000)
      expect(ps).to eq(wnps / 48000)
      expect(t.whole_notes_per_frame(48000)).to equal(ps)
      expect(t.whole_notes_per_frame(48000.0)).to eq(ps) # (a Float rate reads exactly)
      expect(t.whole_notes_per_frame(44100)).to eq(wnps / 44100)
      t.bpm = 90
      expect(t.whole_notes_per_frame(48000)).to eq(t.whole_notes_per_second / 48000)
    end

    it 'steps through a span on exact frames' do
      tr = MB::Sound::Sequence::Transport
      ps = t.whole_notes_per_frame(48000)
      from = 7/3r
      expect(tr.position_at(from, 0, ps)).to eq(from)
      expect(tr.position_at(from, 480, ps)).to eq(from + 480 * ps)
      [0, 1, 479, 480, 12_345].each do |k|
        pos = tr.position_at(from, k, ps)
        expect(tr.frame_at(pos, from, ps)).to eq(k) # (an edge on an exact frame lands on it)
        expect(tr.frame_at(pos - ps / 2, from, ps)).to eq(k - 1)
      end
    end
  end
end
