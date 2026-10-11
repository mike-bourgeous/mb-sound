require_relative '../../../../support/graph_sweep'

RSpec.describe('MB::Sound::Sequence::Clip#ghost_chords', :aggregate_failures) do
  # Note constants (A3 etc.) as in the console
  include MB::Sound::NoteConstants if defined?(MB::Sound::NoteConstants)

  let(:s) { MB::Sound }
  let(:am) { s.scale(:minor, :a) }

  def numbers(clip)
    clip.events.map { |e| MB::Sound::Sequence::Clip.ghost_number(e.value) }
  end

  # The hook from the melody reference: A minor triad tones plus B as a
  # passing note, one bar of eighths with rests
  let(:hook) { s.seq(s::A3, s::C4, s::Rest, s::E4, s::C4, s::Rest, s::A3, s::B3).n8.loop }

  it 'moves each bar onto its ghost chord, keeping the rhythm' do
    g = hook.ghost_chords(1, 4, 7, 6, scale: am)
    expect(g.length).to eq(4)
    expect(g.looping?).to eq(true)
    expect(g.events.map(&:start)).to eq((0...4).flat_map { |b| hook.events.map { |e| e.start + b } })
    expect(g.events.map(&:length)).to eq(hook.events.map(&:length) * 4)

    # Derived from note constants: Am (A C E), Dm (D F A), G (G B D), F (F A C)
    bars = numbers(g).each_slice(6).to_a
    expect(bars[0]).to eq([s::A3, s::C4, s::E4, s::C4, s::A3, s::C4].map(&:number)) # B3 is nearer C4
    expect(bars[1]).to eq([s::A3, s::D4, s::F4, s::D4, s::A3, s::A3].map(&:number))
    expect(bars[2]).to eq([s::G3, s::B3, s::D4, s::B3, s::G3, s::B3].map(&:number))
    expect(bars[3]).to eq([s::A3, s::C4, s::F4, s::C4, s::A3, s::C4].map(&:number))
  end

  it 'leaves chord tones where they are' do
    g = hook.ghost_chords(1, scale: am)
    expect(g.length).to eq(1)
    expect(numbers(g)[0..4]).to eq(numbers(hook)[0..4])
  end

  it 'breaks ties by the contour, or down or up' do
    # D4 is halfway between C4 and E4 over Am
    up = s.seq(s::B3, s::D4).n2.ghost_chords(1, scale: am)
    down = s.seq(s::F4, s::D4).n2.ghost_chords(1, scale: am)
    same = s.seq(s::D4, s::D4).n2.ghost_chords(1, scale: am)
    expect(numbers(up)[1]).to eq(s::E4.number)
    expect(numbers(down)[1]).to eq(s::C4.number)
    expect(numbers(same)).to eq([s::C4, s::C4].map(&:number)) # first note and repeats go down
    expect(numbers(s.seq(s::B3, s::D4).n2.ghost_chords(1, scale: am, tie: :down))[1]).to eq(s::C4.number)
    expect(numbers(s.seq(s::F4, s::D4).n2.ghost_chords(1, scale: am, tie: :up))[1]).to eq(s::E4.number)

    # A looping clip's first note compares with its last
    loop = s.seq(s::D4, s::B3).n2.loop.ghost_chords(1, scale: am)
    expect(numbers(loop)[0]).to eq(s::E4.number)
  end

  it 'builds harmonic minor chords' do
    g = hook.ghost_chords(5, scale: :minor, root: :a, harmonic: true)
    # E major: E G# B
    expect(numbers(g)).to eq([s::Gs3, s::B3, s::E4, s::B3, s::Gs3, s::B3].map(&:number))
    expect { hook.ghost_chords(5, scale: :major, harmonic: true) }.to raise_error(ArgumentError, /seventh/)
  end

  it 'takes explicit chords, nil spans, seventh chords, and per lengths' do
    g = hook.ghost_chords([s::F3, s::A3, s::C4], nil, per: 2.bars)
    expect(g.length).to eq(4)
    bars = numbers(g).each_slice(6).to_a
    expect(bars[0]).to eq([s::A3, s::C4, s::F4, s::C4, s::A3, s::C4].map(&:number))
    expect(bars[2]).to eq(numbers(hook)) # nil: untouched

    sev = s.seq(s::Fs4).n1.ghost_chords(1, scale: am, size: 4) # Am7 has G; a triad would take E
    expect(numbers(sev)).to eq([s::G4.number])

    half = hook.ghost_chords(1, 4, per: 2.beats, scale: am)
    expect(half.length).to eq(1)
    expect(numbers(half)[3]).to eq(s::D4.number) # C4 in the second half bar, over Dm
  end

  it 'keeps short notes as passing notes when asked' do
    clip = s.seq(s::A3.n4, s::B3.n16, s::C4.n8).ghost_chords(1, scale: am, passing: 1.n8)
    expect(numbers(clip)).to eq([s::A3, s::B3, s::C4].map(&:number))
  end

  it 'keeps non-looping clips their length' do
    clip = s.seq(s::C4, s::D4, s::E4, s::G4).n4.ghost_chords(1, 6, per: 2.beats, scale: am)
    expect(clip.length).to eq(1)
    expect(clip.looping?).to eq(false)
    # Am, then F (F A C): D4 ties C4/E4 going up; G4 nearer to F4 than A4? both 2: up from E4
    expect(numbers(clip)).to eq([s::C4, s::E4, s::F4, s::A4].map(&:number))
    expect(numbers(clip)).to all(be_a(Integer))
  end

  it 'remembers its source, so swaps rederive it' do
    g = hook.ghost_chords(1, 4, scale: am)
    expect(g.source).to equal(hook)
    other = s.seq(s::E4, s::C4).n4.loop
    expect(numbers(g.rederive(other))).to eq(numbers(other.ghost_chords(1, 4, scale: am)))
  end

  it 'rejects bad chords and options' do
    expect { hook.ghost_chords }.to raise_error(ArgumentError, /at least one/)
    expect { hook.ghost_chords(0, scale: am) }.to raise_error(ArgumentError, /count from 1/)
    expect { hook.ghost_chords(:iv, scale: am) }.to raise_error(ArgumentError, /scale degree/)
    expect { hook.ghost_chords(1, tie: :sideways) }.to raise_error(ArgumentError, /Tie/)
    expect { s.seq(s::A3).n8.loop.ghost_chords(1, 2, 3, per: 1.n128 * 61) }.to raise_error(ArgumentError, /repeat/)
  end

  it 'prints itself back as Ruby, through a graph document too' do
    build = -> { hook.ghost_chords(1, 4, 7, 6, scale: s.scale(:minor, :a)).synth(voices: 2) { |v| v.hz.saw * v.gate } }
    graph = build.call
    code = graph.to_ruby
    expect(code).to include('ghost_chords(1, 4, 7, 6, scale: scale(:minor, A4))')
    expect(code).to include('Rest')
    expect(code).not_to include('FIXME')

    ref = RecipeHelpers.render(build.call, buffers: 50, size: 800)
    copy = MB::Sound::GraphIO.load(MB::Sound::GraphIO.dump(build.call, name: 'ghost'))
    got = RecipeHelpers.render(copy, buffers: 50, size: 800)
    expect(RecipeHelpers.max_diff(ref, got)).to eq(0)
    expect(ref.map { |r| r.abs.max }.max).to be > 0
  end
end
