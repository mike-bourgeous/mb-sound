# Session fuzzing over small random songs (spec/support/session_fuzz.rb):
# renders finish without errors or unexpected warnings, buffer sizes give
# the same mix within -80 dB, plans don't change it, and timeline-following
# parts launched mid-song match the same parts from bar 1.
# Everyday: SEEDS seeds from a fixed base plus one from RSpec's seed;
# FUZZ=N runs N seeds (the long mode), FUZZ_SEED=n one seed (a repro),
# FUZZ_BASE=n moves the fixed base.
require_relative '../../../support/session_fuzz'

RSpec.describe('session fuzzing') do
  seeds =
    if ENV['FUZZ_SEED']
      [Integer(ENV['FUZZ_SEED'])]
    else
      base = Integer(ENV['FUZZ_BASE'] || 1)
      count = Integer(ENV['FUZZ'] || 2)
      extra = ENV['FUZZ'] ? [] : [100_000 + (RSpec.configuration.seed.to_i * 7) % 900_000]
      (base...(base + count)).to_a + extra
    end

  after { MB::Sound.rewind }

  it "holds every relation for #{seeds.length} random songs#{ENV['FUZZ'] ? '' : ' (FUZZ=N for more)'}",
     render_budget: { seconds: 40 + seeds.length * 60, reason: 'each random song renders 2-3 bars about 4 times, plus its timeline parts twice' } do
    counts = Hash.new(0)
    failures = seeds.flat_map { |s| SessionFuzz.run_seed(s, counts: counts) }
    summary = counts.sort.map { |k, v| "#{k} #{v}" }.join(', ')
    puts "session fuzz: #{seeds.length} seeds: #{summary}" if ENV['FUZZ'] || ENV['FUZZ_SEED']
    expect(counts[:invalid]).to be <= [seeds.length * 0.1, 1].max, "#{counts[:invalid]} songs had generated user errors (SessionFuzz::INVALID)"
    expect(failures).to eq([]), failures.map(&:to_s).join("\n\n")
  end

  it 'generates valid songs that use every kind of command' do
    songs = (1..40).map { |s| SessionFuzz.generate(Random.new(s)).code }
    all = songs.join("\n")
    %w[track( scene go swap stop mute unmute solo turn tween .freq tr808( tr909( launch tweak meter L.inst. :dnb_sub].each do |word|
      expect(all).to include(word)
    end
    songs.each { |code| expect { Prism.parse(code).errors.then { |e| raise e.map(&:message).join(', ') unless e.empty? } }.not_to raise_error }
  end

  # Shrunk songs of fixed finds (omnibus13), kept so they stay fixed
  {
    'an uneven-step tween launched where a step starts between samples (seed 116)' => [
      :timeline, ['bpm 174'], ['at_bar(1, beat: 2) { bg :x1, tween([300.0, 3000.0, 800.0], [1.beat, 3.beats]) * 0.0002, on: :now }'], 2,
    ],
    'a tr808 track revived by a scene after ringing out (seed 1194)' => [
      :buffer_size, ['bpm 112'], [
        'track(:t1, q: 1/2r) { |kit| tr808(kit) * 0.5 }',
        "scene :s1, t1: grid(16, kick: 'X..x..x.', hat: '.x.x.x.x', open_hat: '...x').loop, others: :keep",
        'at_bar(1) { go :s1, on: :now }',
        'at_bar(3, beat: 2) { go :s1 }',
        'at_bar(1, beat: 2) { stop :t1, ring: true }',
      ], 4,
    ],
  }.each do |name, (relation, header, lines, bars)|
    it "holds #{relation} for #{name}" do
      expect(SessionFuzz.check(relation, SessionFuzz::Song.new(header: header, lines: lines, bars: bars))).to be_nil
    end
  end

  it 'shrinks a failing song to the lines that fail' do
    song = SessionFuzz::Song.new(
      header: ['bpm 120'],
      lines: ['knob :cut, 1200.0, range: 200.0..4000.0', 'bg :a, 220.hz.sine * 0.1', 'at_bar(2) { bg :b, 330.hz.sine * 0.1 }'],
      bars: 3
    )
    allow(SessionFuzz).to receive(:check).and_wrap_original { |m, rel, s| s.code.include?('330') ? 'mismatch' : m.call(rel, s) }
    small = SessionFuzz.shrink(song, :buffer_size, 'mismatch')
    expect(small.lines).to eq(['at_bar(2) { bg :b, 330.hz.sine * 0.1 }'])
    expect(small.bars).to eq(1)
  end
end
