require 'fileutils'

# Generators in the library (lib-gen-1; design/notes/library.md,
# "Generators"): L.gen (clip generators) and L.flow (section chains), the
# genre templates' and demo songs' generators as entries, the recorded
# `L.gen.x(...)` call, tracks, auditions, and library files.
module MB
  module Sound
    # The references of spec/lib/mb/sound/library/generators_spec.rb.
    module LibGenSpecRefs
      extend MB::Sound::Library::Generators::NoteNames

      # The inline code each entry replaced (copied from master-ai 7c0e765a
      # before the move: the scripts and templates built these), by entry
      # name: ->(seed) { clip }.  Each entry's build with the same seed must
      # give the same events, cycle for cycle.
      INLINE = {
        techno_beat: ->(seed) {
          beats(16, hold: 2, swing: 0.53, energy: 0.5, over: 4, seed: seed) do
            kick [1, 0, 0, 0] * 4, keep: [0, 4, 8, 12], drift: 0.1
            clap [0, 0, 0, 0, 1, 0, 0, 0] * 2, keep: [4, 12], level: 0.85
            snare [0, 0, 0, 0.1, 0, 0, 0.15, 0, 0, 0.1, 0, 0, 0, 0.2, 0, 0.25], drift: 0.2, level: 0.5
            hat euclid(10, 16), mutate: 0.5, drift: 0.15, level: 0.7
            open_hat [0, 0, 0.8, 0] * 4, drift: 0.25, level: 0.6
            ride euclid(5, 16), mutate: 0.3, level: 0.45
            fill every: 8, snare: 0.7, low_tom: 0.35, mid_tom: 0.35
          end
        },
        acid_rhythm: ->(seed) {
          chords = harmony([[D3, F3, A3], [Ds3, G3, As3], [C3, Ds3, G3], [D3, F3, A3]].each_with_index.to_h { |c, i| [(2 * i).bars, c] }, curve: :step, loop: 8.bars)
          h = scale(:phrygian, :d).weights + chords * 1.5
          rhythm(h.over(D2..D3, around: A2), [1, 0, 0.35, 0.5, 0, 0.3, 0.6, 0.2] * 2, energy: 0.5, hold: 2, length: 1, seed: seed)
        },
        phrygian_motif: ->(seed) {
          chords = harmony([[D3, F3, A3], [Ds3, G3, As3], [C3, Ds3, G3], [D3, F3, A3]].each_with_index.to_h { |c, i| [(2 * i).bars, c] }, curve: :step, loop: 8.bars)
          h = scale(:phrygian, :d).weights + chords * 1.5
          motifs(h, 16, step: 1.n16, form: %i[a a b a], answer: { b: :a }, density: 0.5, mutate: 0.15, vary: 0.2, evolve: 1, range: A3..A5, around: E4, seed: seed)
        },
      }.freeze

      # generative_demo.rb's harmony as the script built it.
      DEMO = ->() {
        key = harmony(
          0 => scale(:dorian, :d), 12.bars => scale(:dorian, :d), 18.bars => scale(:major, :f),
          26.bars => scale(:major, :f), 30.bars => scale(:dorian, :d), loop: 32.bars
        )
        list = [
          [D3, F3, A3, C4], [G2, B2, D3, F3], [C3, E3, G3, B3], [A2, C3, E3, G3],
          [D3, F3, A3, C4], [G2, B2, D3, F3], [E3, G3, B3, D4], [A2, C3, E3, G3],
          [D3, F3, A3, C4], [F3, A3, C4, E4], [As2, D3, F3, A3], [G2, As2, D3, F3],
          [C3, E3, G3, As3], [F3, A3, C4, E4], [As2, D3, F3, A3], [A2, C3, E3, G3],
        ]
        chords = harmony(list.each_with_index.to_h { |c, i| [(2 * i).bars, c] }, curve: :step, loop: 32.bars)
        [key, chords, key + chords * 1.5]
      }

      DEMO_INLINE = {
        koto_motif: ->(seed) {
          _, _, h = instance_exec(&DEMO)
          motifs(h, 8, step: 1.n8, form: %i[a a b a], answer: { b: :a }, vary: 0.2, mutate: 0.25, evolve: 2, range: A3..A5, around: E4, seed: seed)
        },
        probability_melody: ->(seed) {
          _, _, h = instance_exec(&DEMO)
          melody(h, rhythm: euclid(5, 8, A3, step: 8), range: A3..A5, start: D4, vary: true, seed: seed).loop
        },
        dorian_melody: ->(seed) { melody(scale(:dorian, :d), rhythm: euclid(5, 8, A3, step: 8), range: A3..A5, vary: true, seed: seed).loop },
        rin_strikes: ->(seed) {
          _, _, h = instance_exec(&DEMO)
          strikes(h.over(A4..A6, around: E5, width: 7), every: 1.n8, chance: 0.2, gap: 4, length: 2.bars, seed: seed)
        },
        bowl_strikes: ->(seed) {
          key, chords, = instance_exec(&DEMO)
          strikes((key + chords * 4).over(D2..D4, around: A2, width: 6), every: 1.n2, chance: 0.45, gap: 2, sharpen: 3, note: 1.bar, seed: seed)
        },
        chord_pad: ->(seed) {
          _, chords, = instance_exec(&DEMO)
          generate(2.bars, values: (50..62).to_a, seed: seed) { |cycle, dice|
            w = chords.at(cycle * 2)
            notes = (50..62).select { |n| w[n] > 0 }
            notes = notes.reject.with_index { |_, i| i == 1 && dice.chance(0.4, :drop) }
            notes.map { |n| [0r, 2r, n, 0.35 + 0.15 * dice.rand(:vel, n)] }
          }
        },
        pentatonic_bass: ->(seed) {
          rhythm = euclid(5, 8, A1, velocity: 0.8) | euclid(3, 8, A1, rotate: 1, velocity: 0.7)
          melody(scale(:minor_pentatonic, A1), rhythm: rhythm, leap: 2, range: E1..A2, seed: seed, vary: true).loop
        },
        tin_roof_motif: ->(seed) {
          seq(
            A4, R, R, D5, R, B4, R, R,   R, R, E5.maybe(0.6), R, R, R, R, R,
            G4, R, R, A4, R, R, R, R,    R, D5, R, R, B4.maybe(0.5), R, R, R,
          ).n8.humanize(1.n64, velocity: 0.15, seed: seed).loop(align: :launch)
        },
        tin_roof_harp: ->(seed) {
          seq(
            D5, R, A4, B4.maybe(0.7), R, D5, R, E5,  R, G4, R, R, A4.maybe(0.5), R, R, R,
          ).n16.swing(0.6).humanize(1.n128, velocity: 0.2, seed: seed).loop(align: :launch)
        },
      }.freeze

      # The ambient template's walk as it built it.
      AMBIENT = ->() {
        keys = markov(d: { g: 2, a: 2, e: 0.5 }, g: { d: 2, a: 0.5 }, a: { d: 2, e: 1 }, e: { a: 2, d: 1 }, seed: 61).take(24)
        roots = { d: D2, g: G1, a: A1, e: E2 }
        walk = harmony(keys.each_with_index.flat_map { |k, i|
          w = scale(:yo, k).weights + tones(roots[k]) * 0.5
          [[(16 * i).bars, w], [(16 * i + 12).bars, w]]
        }.to_h, loop: 384.bars)
        bass = harmony(keys.each_with_index.to_h { |k, i| [(16 * i).bars, [roots[k]]] }, curve: :step, loop: 384.bars)
        [walk, bass]
      }

      AMBIENT_INLINE = {
        ambient_roots: ->(seed) {
          _, bass = instance_exec(&AMBIENT)
          strikes(bass.over(G1..Fs2), every: 8.bars, length: 8.bars, chance: 1.0, gap: 1, sharpen: 4, velocity: 0.7, note: 8.bars, seed: seed)
        },
        ambient_motif: ->(seed) {
          walk, = instance_exec(&AMBIENT)
          motifs(walk, 32, step: 1.n4, form: %i[a b a c], answer: { b: :a }, density: 0.1, vary: 0.3, mutate: 0.2, evolve: 2,
                        range: G4..G5, around: D5, velocity: 0.45..0.8, legato: 1.0, seed: seed)
        },
        ambient_figure: ->(seed) {
          walk, = instance_exec(&AMBIENT)
          motifs(walk, 16, step: 1.n16, form: %i[a a b a], answer: { b: :a }, density: 0.45, vary: 0.2, mutate: 0.15,
                        range: G4..E5, around: B4, velocity: 0.5..0.8, seed: seed).swing(0.6)
        },
      }.freeze

      # generative_blur.rb's line and cloud (the field is
      # GenerativeBlur.field, which moved whole; spec/bin/songs checks the
      # renders).
      BLUR_INLINE = {
        blur_line: ->(seed) {
          f = MB::Sound::Library::Generators::GenerativeBlur.field(0.03, transition: :slow, chord_blend: 0.25, octaves: 2)
          strikes(f, every: Rational(1, 64).whole, chance: 1, gap: 1, sharpen: 1, velocity: 0.45..0.8, seed: seed)
        },
        blur_cloud: ->(seed) {
          f = MB::Sound::Library::Generators::GenerativeBlur.field(0.03, transition: 1, chord_blend: 0.5, octaves: 3)
          c = MB::Sound::Library::Generators::GenerativeBlur.cloud_settings(120)
          strikes(f, every: Rational(1, c[:division]).whole, chance: c[:chance], gap: 1, sharpen: 1, seed: seed)
        },
      }.freeze

      # The genre templates' chains as the templates wrote them.
      CHAINS = {
        dnb_chain: ->(seed) {
          lsystem(%i[intro body outro], body: { %i[build drop turn body] => 2, %i[build drop turn] => 1 },
                  turn: { %i[breakdown pullup drop2] => 2, %i[breakdown pullup drop] => 1 }, generations: 3, seed: seed)
        },
        jungle_chain: ->(seed) {
          lsystem(%i[intro lift body outro], body: { %i[roll drop turn body] => 2, %i[roll drop turn] => 2, %i[drop turn] => 1 },
                  turn: { %i[breakdown drop2] => 3, %i[breakdown drop] => 1 }, generations: 3, seed: seed)
        },
        house_chain: ->(seed) {
          lsystem(%i[intro groove body outro outro2],
                  body: { %i[breakdown drop pickup body] => 2, %i[breakdown drop pickup] => 1, %i[breakdown2 drop2] => 1, %i[breakdown drop2] => 1 },
                  generations: 3, seed: seed)
        },
        funk_chain: ->(seed) {
          markov(beat: { bass: 1 }, bass: { keys: 1 }, keys: { perc: 1 }, perc: { groove: 1 },
                 groove: { bridge: 2, peak: 1.5, groove: 0.5 }, bridge: { groove: 2, peak: 1 },
                 peak: { groove: 0.5, strip: 2 }, strip: { groove: 0.5, outro: 2 }, outro: {}, seed: seed)
        },
        techno_chain: ->(seed) {
          markov(intro: { hats: 1 }, hats: { build: 1 }, build: { peak: 1 },
                 peak: { peak_b: 2, breakdown: 1 }, peak_b: { peak: 1, breakdown: 2, peak2: 0.5 },
                 breakdown: { peak2: 2, build: 1 }, peak2: { peak_b: 0.5, outro: 1.5, breakdown: 0.5 },
                 outro: { outro_b: 1 }, outro_b: { outro_c: 1 }, outro_c: {}, seed: seed)
        },
        ambient_chain: ->(seed) {
          markov(emerge: { drift: 1 }, drift: { bloom: 3, hush: 1, tide: 1, drift: 0.5 }, bloom: { tide: 2, hush: 1.5, drift: 1 },
                 hush: { drift: 2, tide: 1, emerge: 0.5 }, tide: { hush: 2, drift: 1.5, dissolve: 0.5 }, dissolve: { emerge: 1 }, seed: seed)
        },
      }.freeze
    end
  end
end

RSpec.describe MB::Sound::Library::Generators do
  def refs = MB::Sound::LibGenSpecRefs

  let(:lib) { MB::Sound::Library }
  let(:gens) { MB::Sound::Library::Generators }
  let(:user) { File.dirname(tmp_path('user/x')) }

  around do |ex|
    old = ENV.to_h.slice('MB_SOUND_USER_PRESETS', 'MB_SOUND_PRESETS')
    ENV.delete('MB_SOUND_PRESETS')
    ENV['MB_SOUND_USER_PRESETS'] = user
    lib.reload!
    ex.run
  ensure
    ENV.delete('MB_SOUND_PRESETS')
    old.each { |k, v| ENV[k] = v }
    lib.reload!
  end

  # Runs +block+ in MB::Sound (the DSL), as the scripts and templates did.
  def dsl(&block)
    MB::Sound.instance_exec(&block)
  end

  # Cycles 0...n of +clip+'s events.
  def cycles(clip, n = 6)
    (0...n).map { |c| clip.events_for(c) }
  end

  describe 'the shipped entries' do
    it 'are frozen L.gen and L.flow entries with Params, an about line, tags, and instruments that exist' do
      gen = MB::Sound::L.gen.entries
      flow = MB::Sound::L.flow.entries
      expect(gen.map(&:name)).to include(*refs::INLINE.keys, *refs::DEMO_INLINE.keys, *refs::AMBIENT_INLINE.keys, *refs::BLUR_INLINE.keys)
      expect(flow.map(&:name)).to match_array(refs::CHAINS.keys)
      (gen + flow).each do |e|
        expect(e).to be_frozen
        expect(e.family).to eq(e.kind)
        expect(e.about).to be_a(String)
        expect(e.tags).not_to be_empty
        expect(e.params).not_to be_empty
        expect(e.params.values).to all(be_a(MB::Sound::Param))
        expect(e.params.keys).to include(:seed)
        expect(e.head_path).to eq("L.#{e.kind == :flow ? 'flow' : 'gen'}.#{e.name}")
        expect(e.location).to match(%r{\Alib/mb/sound/.*\.rb:\d+\z})
      end
      gen.each { |e| expect(MB::Sound::Arrangement::InstrumentPatch.entry_for(e.settings[:instrument], track: :x)).to be_a(lib::Entry) }
      flow.each { |e| expect(e.settings[:bars]).to be_a(Hash) }
      expect(lib.index.problems).to eq([])
    end

    it 'build the clips the inline code built, cycle for cycle, for each seed' do
      refs::INLINE.merge(refs::DEMO_INLINE, refs::AMBIENT_INLINE, refs::BLUR_INLINE).each do |name, inline|
        [nil, 3].each do |seed|
          entry = lib.index.lookup(:generator, name)
          seed ||= entry.params[:seed].default
          built = entry.call(seed: seed)
          expect(built).to be_a(MB::Sound::Sequence::Clip)
          ref = MB::Sound.instance_exec(seed, &inline)
          n = name.to_s.start_with?('blur') ? 3 : 6
          expect(cycles(built, n)).to eq(cycles(ref, n)), "#{name} seed #{seed}"
          expect(built.length).to eq(ref.length)
          expect(built.looping?).to eq(ref.looping?)
        end
      end
    end

    it 'steer like the inline code with other values (a knob-steered beat renders the same through a document)' do
      ref = MB::Sound.instance_exec(4, &refs::INLINE[:techno_beat])
      expect(cycles(MB::Sound::L.gen.techno_beat(seed: 4, energy: 0.5))).to eq(cycles(ref))
      hot = MB::Sound.instance_exec { beats(16, hold: 2, swing: 0.53, energy: 0.9, over: 4, seed: 4) { kick [1, 0, 0, 0] * 4; hat euclid(10, 16), mutate: 0.5 } }
      expect(cycles(MB::Sound::L.gen.techno_beat(seed: 4, energy: 0.9))).not_to eq(cycles(MB::Sound::L.gen.techno_beat(seed: 4)))
      expect(hot).to be_a(MB::Sound::Sequence::Clip)
    end

    it 'give the chains the templates wrote, draw for draw, for each seed' do
      refs::CHAINS.each do |name, inline|
        entry = lib.index.lookup(:flow, name)
        [entry.params[:seed].default, 9].each do |seed|
          built = entry.call(seed: seed)
          ref = MB::Sound.instance_exec(seed, &inline)
          expect(built).to eq(ref)
          expect(built.chain_ruby).to eq(ref.to_ruby)
          take = built.respond_to?(:take) ? ->(s) { s.take(30) } : ->(s) { s.word }
          expect(take.(built)).to eq(take.(ref)), "#{name} seed #{seed}"
        end
      end
    end

    it 'are what the genre templates play: one source' do
      refs::CHAINS.each_key do |name|
        g = name.to_s.delete_suffix('_chain').to_sym
        t = MB::Sound.genre(g)
        entry = lib.index.lookup(:flow, name)
        expect(t.generator.source).to eq(entry.call)
        expect(t.generator.bars).to eq(entry.settings[:bars])
        expect(t.generator.ruby).to eq("generator L.flow.#{name}(seed: #{entry.params[:seed].default})") # (the seed written out: gen-knobs-1)
        expect(t.generative(seed: 4).form.to_ruby).to include("generate L.flow.#{name}(seed: 4), bars:")
      end
      amb = MB::Sound.genre(:ambient)
      expect(amb.generator.sections).to eq(12)
      { drone: :ambient_roots, motif: :ambient_motif, harp: :ambient_figure }.each do |clip, name|
        expect(cycles(amb.clips[clip], 4)).to eq(cycles(MB::Sound.instance_exec(lib.index.lookup(:generator, name).params[:seed].default, &refs::AMBIENT_INLINE[name]), 4))
        expect(amb.to_ruby).to include("clip #{clip.inspect}, L.gen.#{name}(seed: #{lib.index.lookup(:generator, name).params[:seed].default})")
      end
    end
  end

  describe 'calls' do
    it 'print back as the library call and load again (graph documents walk L.gen chains)' do
      expect(MB::Sound::L.gen.techno_beat(seed: 3).to_ruby).to eq('L.gen.techno_beat(seed: 3)')
      # (a call at its defaults prints its seed: the maintainer, 2026-11-02, "Write the seed")
      expect(MB::Sound::L.gen.techno_beat.().to_ruby).to eq('L.gen.techno_beat(seed: 5)')
      expect(MB::Sound::L.gen.techno_beat(energy: 0.8).to_ruby).to eq('L.gen.techno_beat(seed: 5, energy: 0.8)')
      expect(MB::Sound::L.gen.techno_beat.to_ruby).to eq('L.gen.techno_beat(seed: 5)')
      expect(MB::Sound::L.flow.techno_chain(seed: 4).to_ruby).to eq('L.flow.techno_chain(seed: 4)')
      expect(MB::Sound::L.flow.techno_chain.().reseed(5).to_ruby).to eq('L.flow.techno_chain(seed: 5)')
      expect(MB::Sound::L.flow.techno_chain(seed: 4).reseed(132).to_ruby).to eq('L.flow.techno_chain(seed: 132)')
      expect(MB::Sound::L.flow.techno_chain.().to_ruby).to eq('L.flow.techno_chain(seed: 132)')

      g = MB::Sound.tr909(MB::Sound::L.gen.techno_beat(seed: 3, energy: 0.8))
      text = MB::Sound::GraphIO.dump(g, name: 'beat')
      expect(text).to include('tr909(L.gen.techno_beat(seed: 3, energy: 0.8)')
      g2 = MB::Sound::GraphIO.load(text)
      a = SpecBuffers.join(4.times.map { g.sample(2400).dup })
      b = SpecBuffers.join(4.times.map { g2.sample(2400).dup })
      expect(a.abs.max).to be > 0.01
      expect(b).to eq(a)

      pad = MB::Sound::GraphIO.load("graph #{MB::Sound::GraphIO::FORMAT}, name: \"p\"\nL.gen.chord_pad.().synth { |v| v.hz.sine * v.amp_env }\n")
      expect(pad).to be_a(MB::Sound::Synth)
    end

    it 'remember what built a clip or chain through garbage collection (an ObjectSpace::WeakMap would forget its values)' do
      c = MB::Sound::L.gen.techno_beat(seed: 3)
      m = MB::Sound::L.flow.techno_chain(seed: 3)
      2.times { GC.start(full_mark: true, immediate_sweep: true) }
      expect(gens.instrument(c)).to eq(:tr909)
      expect(c.to_ruby).to eq('L.gen.techno_beat(seed: 3)')
      expect(gens.origin(m).entry.name).to eq(:techno_chain)
    end

    it 'take keywords only, with did-you-mean for typos, and words with arguments call their entry' do
      expect { MB::Sound::L.gen.techno_beat(enrgy: 0.3) }.to raise_error(ArgumentError, /unknown keyword enrgy:.*energy:/m)
      expect { MB::Sound::L.gen.techno_beat.(3) }.to raise_error(ArgumentError, /takes its params as keywords/)
      expect { MB::Sound::L.gen.generative_steer(seed: 3) }.to raise_error(ArgumentError, /name one/)
      expect(MB::Sound::L.gen.techno_beat).to be_a(lib::Entry)
      expect(MB::Sound::L.gen.techno_beat.words).not_to include(:generator)
    end

    it 'complete under L.gen and L.flow without running anything' do
      expect(lib::Heads.completions('L.gen.tec')).to eq(['L.gen.techno', 'L.gen.techno_beat']) # (a tag, then the entry)
      expect(lib::Heads.completions('L.flow.techno_')).to eq(['L.flow.techno_chain'])
      expect(lib::Heads.completions('L.')).to include('L.gen', 'L.flow')
    end
  end

  describe 'on tracks' do
    before { @sessions = [] }
    after {
      @sessions.each(&:close)
      MB::Sound.rewind
    }

    # A Session that runs +setup+ in its context, then a scene playing
    # +track+'s clip, for +buffers+ buffers; returns [session, left].
    def run(track, setup, buffers: 60)
      MB::Sound.rewind
      MB::Sound.seed(1)
      out = MB::Sound::Sampler::CaptureOutput.new(channels: 2, buffer_size: 800)
      s = MB::Sound::Session.new(output: out, realtime: false)
      @sessions << s
      MB::Sound::Session.with_context(session: s) {
        setup.call
        MB::Sound.scene(:a, track => :on)
        MB::Sound.go(:a, on: :now)
      }
      buffers.times { s.process_buffer }
      [s, Numo::DFloat.cast(out.captured[0])]
    end

    it 'play a generator entry on its instrument, or on the one given (either order), as the clip with that instrument' do
      s, got = run(:drums, -> { MB::Sound.track(:drums, MB::Sound::L.gen.techno_beat) })
      expect(s.arrangement.tracks[:drums].clip.to_ruby).to eq('L.gen.techno_beat(seed: 5)')
      _, ref = run(:drums, -> { MB::Sound.track(:drums, MB::Sound::L.gen.techno_beat.(), :tr909) })
      expect(got.abs.max).to be > 0.01
      expect(got).to eq(ref)

      _, got = run(:lead, -> { MB::Sound.track(:lead, MB::Sound::L.gen.phrygian_motif, :tine_piano) })
      _, ref = run(:lead, -> { MB::Sound.track(:lead, :tine_piano, MB::Sound::L.gen.phrygian_motif.()) })
      _, other = run(:lead, -> { MB::Sound.track(:lead, MB::Sound::L.gen.phrygian_motif) })
      expect(got.abs.max).to be > 0.001
      expect(got).to eq(ref)
      expect(other).not_to eq(got)

      _, got = run(:bass, -> { MB::Sound.track(:bass, MB::Sound::L.gen.acid_rhythm(seed: 2)) })
      _, ref = run(:bass, -> { MB::Sound.track(:bass, MB::Sound::L.gen.acid_rhythm(seed: 2), :acid) })
      expect(got).to eq(ref)
    end

    # (lesson-fixes-1: `bg :drums, L.gen.techno_beat` played the 8-bar
    # audition in place of the track, while `bg :drums, L.gen.techno_beat()`
    # played on it)
    it 'bg of a bare entry on a track plays its clip at the defaults on the track; instruments and effects point to track and fx' do
      track = -> { MB::Sound.track(:drums, MB::Sound::L.gen.techno_beat(seed: 3)) }
      s, got = run(:drums, -> { track.(); MB::Sound.bg(:drums, MB::Sound::L.gen.techno_beat, on: :now) })
      expect(s.arrangement.tracks[:drums].clip.to_ruby).to eq('L.gen.techno_beat(seed: 5)')
      expect(s.players[:drums]).not_to include('8 bars')
      _, ref = run(:drums, -> { track.(); MB::Sound.bg(:drums, MB::Sound::L.gen.techno_beat.(), on: :now) })
      expect(got.abs.max).to be > 0.01
      expect(got).to eq(ref)

      run(:drums, -> {
        track.()
        expect { MB::Sound.bg(:drums, MB::Sound::L.inst.dnb.dnb_reese) }.to raise_error(ArgumentError, /L\.inst\.dnb_reese is an instrument, and :drums is a track: track :drums, L\.inst\.dnb_reese gives it/)
        expect { MB::Sound.bg(:drums, MB::Sound::L.fx.reverb.hall) }.to raise_error(ArgumentError, /is an effect, and :drums is a track: fx :drums, L\.fx\./)
      }, buffers: 1)

      # A new player still auditions it
      s, _ = run(:drums, -> { track.(); MB::Sound.bg(:x, MB::Sound::L.gen.techno_beat, on: :now) }, buffers: 1)
      expect(s.players[:x]).to include('8 bars')
    end
  end

  describe 'play and audition' do
    it 'play a generator on its instrument for 8 bars and sketch a chain a bar a section' do
      g = lib::Audition.playable(MB::Sound::L.gen.koto_motif)
      expect(g.description).to eq('L.gen.koto_motif on ambient_koto, 8 bars')
      s = lib::Audition.playable(MB::Sound::L.flow.techno_chain)
      expect(s.description).to start_with('L.flow.techno_chain sketched, a bar a section: intro 16, hats [8, 16], build')
      expect(s.note).to include('genre(:techno).generative.play')
      frames = 0
      loop do
        bufs = s.nodes.map { |n| n.sample(4800) }
        break if bufs.any?(&:nil?)
        frames += 4800
        raise 'the sketch never ended' if frames > 48000 * 40
      end
      expect(frames).to be_between(48000 * 20, 48000 * 30)
    end
  end

  describe 'library files' do
    def write(rel, text, dir: user)
      path = File.join(dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
      lib.reload!
      path
    end

    it 'hold generators and flows with keyword params and param lines, used like the shipped ones' do
      write('gen/mine.rb', <<~RUBY)
        library 1
        generator :my_beat, instrument: :tr909, tags: %i[drums mine], about: 'A plain four with hats' do |seed: 2|
          param :energy, (0.0..1.0).at(0.6), description: 'How busy'
          beats(16, energy: energy, seed: seed) { kick [1, 0, 0, 0] * 4; hat euclid(7, 16), mutate: 0.3 }
        end
        flow :my_chain, bars: { a: 8, b: [4, 8] }, tags: %i[mine], about: 'Two sections trading' do |seed: 5|
          markov(a: { b: 1 }, b: { a: 1, c: 0.5 }, c: {}, seed: seed)
        end
      RUBY
      expect(lib.index.problems).to eq([])
      e = MB::Sound::L.gen.my_beat
      expect(e.shelf.name).to eq(:user)
      expect(e.params.keys).to eq(%i[seed energy])
      expect(e.params[:energy].range).to eq(0.0..1.0)
      expect(e.params[:energy].default).to eq(0.6)
      expect(e.params[:energy].description).to eq('How busy')
      expect(e.params[:seed].description).to eq(gens::DESCRIPTIONS[:seed])
      expect(e.source).to start_with('generator :my_beat')
      built = MB::Sound::L.gen.my_beat(seed: 3)
      ref = MB::Sound.instance_exec { beats(16, energy: 0.6, seed: 3) { kick [1, 0, 0, 0] * 4; hat euclid(7, 16), mutate: 0.3 } }
      expect(cycles(built)).to eq(cycles(ref))
      expect(cycles(MB::Sound::L.gen.my_beat(energy: 0.2))).to eq(cycles(MB::Sound.instance_exec { beats(16, energy: 0.2, seed: 2) { kick [1, 0, 0, 0] * 4; hat euclid(7, 16), mutate: 0.3 } }))
      expect(built.to_ruby).to eq('L.gen.my_beat(seed: 3)')
      expect(gens.instrument(built)).to eq(:tr909)

      f = lib.index.lookup(:flow, :my_chain)
      expect(f.settings[:bars]).to eq(a: 8, b: [4, 8])
      expect(MB::Sound::L.flow.my_chain(seed: 6)).to eq(MB::Sound.markov(a: { b: 1 }, b: { a: 1, c: 0.5 }, c: {}, seed: 6))
      expect(MB::Sound::L.flow.my_chain(seed: 6).to_ruby).to eq('L.flow.my_chain(seed: 6)')
    end

    it 'list what a generator line gets wrong as problems' do
      write('gen/bad.rb', "generator :bad, colour: 1 do |seed: 1|\n  seq(C4).loop\nend\n")
      write('gen/bad2.rb', "flow :bad2 do |seed: 1|\n  markov(a: {}, seed: seed)\nend\n")
      write('gen/bad3.rb', "generator :bad3 do |seed|\n  seq(C4).loop\nend\n")
      expect { lib.index.entries }.to output(/colour.*\n.*bars:.*\n.*keywords/m).to_stderr
      text = lib.index.problems.join("\n")
      expect(text).to include('generator bad: unknown setting colour:', 'flow bad2 needs bars:', 'generator bad3: params are keywords with defaults')
    end
  end

  describe 'save' do
    let(:save_dir) { File.dirname(tmp_path('presets/x')) }

    around do |ex|
      ENV['MB_SOUND_PRESETS'] = save_dir
      lib.reload!
      ex.run
    ensure
      ENV.delete('MB_SOUND_PRESETS')
      lib.reload!
    end

    it 'writes a generator clip and a chain as library statements, knobs read becoming params' do
      clip = MB::Sound::L.gen.techno_beat(seed: 3)
      path = nil
      expect { path = MB::Sound.save(:beat3, clip, tags: %i[mine], about: 'Seed 3') }.to output(/Saved beat3/).to_stdout
      expect(path).to eq(File.join(save_dir, 'gen', 'beat3.rb'))
      expect(File.read(path)).to eq(<<~RUBY)
        library 1
        generator :beat3, instrument: :tr909, tags: %i[mine], about: "Seed 3" do
          L.gen.techno_beat(seed: 3)
        end
      RUBY
      expect(cycles(MB::Sound::L.gen.beat3.())).to eq(cycles(clip))
      expect { MB::Sound.save(:beat3, clip) }.to output(/Not saved: beat3 exists.*save!/).to_stderr
      expect { MB::Sound.save(:beat3, clip, bump: true) }.to output(/Saved beat3_v2/).to_stdout

      s = MB::Sound::Session.new(realtime: false)
      begin
        steered = MB::Sound::Session.with_context(session: s) {
          MB::Sound.knob(:energy, 0.4)
          MB::Sound.motifs(MB::Sound.scale(:dorian, :d), 8, density: MB::Sound.knob(:energy), seed: 2)
        }
        expect { MB::Sound.save!(:steered, steered) }.to output(/Saved steered/).to_stdout
      ensure
        s.close
      end
      text = File.read(File.join(save_dir, 'gen', 'steered.rb'))
      expect(text).to include("generator :steered do\n  param :energy, 0.4\n  motifs(scale(:dorian, D4), 8, density: energy, seed: 2)\nend")
      e = MB::Sound::L.gen.steered
      expect(e.params[:energy].default).to eq(0.4)
      ref = MB::Sound.motifs(MB::Sound.scale(:dorian, :d), 8, density: 0.4, seed: 2)
      expect(cycles(e.call)).to eq(cycles(ref))

      expect { MB::Sound.save(:chain4, MB::Sound::L.flow.techno_chain(seed: 4)) }.to output(/Saved chain4/).to_stdout
      f = lib.index.lookup(:flow, :chain4)
      expect(f.settings[:bars]).to eq(lib.index.lookup(:flow, :techno_chain).settings[:bars])
      expect(f.call).to eq(MB::Sound::L.flow.techno_chain(seed: 4))
      expect { MB::Sound.save(:bare, MB::Sound.markov(a: { b: 1 }, b: {}, seed: 1)) }.to output(/Not saved: .*bars:/).to_stderr
    end
  end

  describe 'flow and collect' do
    it 'plays a chain as a flow with its entry bars (loop: true starts it over), and generate takes the entry' do
      s = MB::Sound::Session.new(realtime: false)
      begin
        MB::Sound::Session.with_context(session: s) do
          f = MB::Sound.flow(MB::Sound::L.flow.techno_chain(seed: 4), play: false)
          bars = lib.index.lookup(:flow, :techno_chain).settings[:bars]
          expect(f.to_ruby).to eq("flow do\n  generate L.flow.techno_chain(seed: 4), bars: #{MB::Sound::Genre.ruby(bars)}\nend")
          ref = MB::Sound::L.flow.techno_chain(seed: 4).flow(bars)
          pass = ->(form) { form.plan(seed: 0).first(12).map { |x| [x.section, x.length] } }
          expect(pass.(f)).to eq(pass.(ref))
          g = MB::Sound.flow(MB::Sound::L.flow.dnb_chain, loop: true, play: false)
          expect(g.to_ruby).to start_with("flow do\n  label :top\n  generate L.flow.dnb_chain(seed: 174), bars:")
          h = MB::Sound::Form.build { generate MB::Sound::L.flow.dnb_chain }
          dnb_bars = lib.index.lookup(:flow, :dnb_chain).settings[:bars]
          expect(pass.(h)).to eq(pass.(MB::Sound::Form.build { generate MB::Sound::L.flow.dnb_chain.(), bars: dnb_bars }))
          expect { MB::Sound.flow(MB::Sound::L.flow.dnb_chain) { intro 8 } }.to raise_error(ArgumentError, /not both/)
        end
      ensure
        s.close
      end
    end

    it 'collects file generators a song used and pins the built-ins by their definitions' do
      project = File.dirname(tmp_path('song/x'))
      FileUtils.mkdir_p(project)
      File.write(File.join(project, 'Gemfile'), "gem 'mb-sound'\n")
      path = File.join(user, 'gen/mine.rb')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "generator :mine, tags: %i[test] do |seed: 1|\n  L.gen.techno_beat(seed: seed)\nend\n")
      Dir.chdir(project) do
        lib.reload!
        lib.index.clear_uses
        MB::Sound::L.gen.mine.()
        out = nil
        expect { out = MB::Sound.collect }.to output(/Collected generator :mine from the user shelf to presets\/gen\/mine\.rb/).to_stdout
        expect(File.read(File.join(project, 'presets/gen/mine.rb'))).to include("generator :mine, tags: %i[test] do |seed: 1|")
        pins = File.read(File.join(project, 'presets/pins.rb'))
        expect(pins).to match(/pin :generator, :techno_beat, mb_sound: ".*", fingerprint: "\h{16}"/)
        expect(out.map { |e, _| e.name }).to include(:mine)
      end
      expect(lib::Pins.fingerprint_text(lib.index.lookup(:flow, :techno_chain))).to start_with('Library::Generators.flow :techno_chain')
      expect(lib::Pins.fingerprint(lib.index.lookup(:generator, :koto_motif))).to match(/\A\h{16}\z/)
    end
  end
end
