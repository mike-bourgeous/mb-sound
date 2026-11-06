# Session fuzzing over small random songs (spec/support/session_fuzz.rb):
# renders finish without errors or unexpected warnings, buffer sizes give
# the same mix within -80 dB, plans don't change it, and timeline-following
# parts launched mid-song match the same parts from bar 1, and warming
# changes before they land doesn't change it either, nor do carrying
# rebuilds of the tracks (what a bind does; carry-1).
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
     render_budget: { seconds: 60 + seeds.length * 100, reason: 'each random song renders 2-3 bars 9-13 times (plus warm-up sandboxes): 58.6 s a seed on average, up to 116 s (seeds 1-60 and 770000-770047, fuzz-fixes-2; 60 a seed left batch9 soak groups of 12 seeds at 680-822 s against 760)' } do
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
    %w[track( scene go swap stop mute unmute solo turn tween .freq tr808( tr909( launch tweak meter L.inst. :dnb_sub bus( feed master flow( markov( seek glide(:length) key_level kept_t].each do |word|
      expect(all).to include(word)
    end
    expect(all).to match(/\{ swap :t\d, grid\(.*\)\.loop\.\w+/) # (parity-1: a kit swapped to a Kit transform)
    songs.each { |code| expect { Prism.parse(code).errors.then { |e| raise e.map(&:message).join(', ') unless e.empty? } }.not_to raise_error }
  end

  it 'unwires a track only while it is still wired (seed 771036)' do
    # (a track has one wire, and unwire of a track nothing is wired into
    # raises in scripts by design: two wire lines for one track, each
    # with its unwire, made the second unwire a user error)
    rng = Random.new(5)
    codes = SessionFuzz::COMMANDS.flat_map { |cmd|
      Array.new(40) {
        cmd.call(SessionFuzz::Step.new(rng: rng, t: :t1, on: ', on: :now', scenes: %i[s1 s2], swappable: %i[t1],
                                       instruments: %i[t2], knob: true, clip_for: ->(_) { 'seq(C4).n8.loop' }, bgs: 0))
      }
    }.compact.grep(/unwire/)
    expect(codes).not_to be_empty
    expect(codes).to all(match(/\{ unwire :t1 if wires\.key\?\(:t1\) \}/))
  end

  it 'builds a command (or skips the step) from every entry of the append-only COMMANDS list' do
    expect(SessionFuzz::COMMANDS.length).to be >= 15
    rng = Random.new(3)
    SessionFuzz::COMMANDS.each_with_index do |cmd, i|
      [true, false].each do |full|
        step = SessionFuzz::Step.new(rng: rng, t: :t1, on: ', on: :now', scenes: %i[s1 s2], swappable: full ? %i[t1] : [],
                                     instruments: full ? %i[t2] : nil, knob: full, clip_for: ->(_) { 'seq(C4).n8.loop' }, bgs: 0)
        code = cmd.call(step)
        next expect(full).to(eq(false), "command #{i} skipped a step that has everything") if code.nil?

        expect(code).to be_a(String)
        expect(Prism.parse(code).errors).to eq([]), "command #{i}: #{code}"
      end
    end
  end

  # The seeds that found the followed tempo LFO's end bar (omnibus16), as
  # generated with the 15 commands of their day (their songs gain later
  # generation steps' lines; SessionFuzz::COMMANDS is append-only)
  it 'renders seeds 52, 82, and 127 to the same end bar at 367 and 800 frames', render_budget: { seconds: 120, reason: 'three random songs at two buffer sizes' } do
    [52, 82, 127].each do |seed|
      song = SessionFuzz.generate(Random.new(seed), commands: 15)
      expect(song.code).to match(/tempo \d+\.beats?\.lfo|tempo \d\.bars\.lfo/), "seed #{seed} no longer draws a tempo LFO"
      expect(SessionFuzz.check(:buffer_size, song)).to be_nil, "seed #{seed}"
    end
  end

  # The 2026-10-30 batch soak's finds (batch-fixes-1030), as generated with
  # the 16 commands of their day: every relation, as the soak checked them
  it 'holds every relation for seeds 766010 and 766044', :slow, render_budget: { seconds: 200, reason: 'two random songs, every relation' } do
    [766010, 766044].each do |seed|
      song = SessionFuzz.generate(Random.new(seed), commands: 16)
      SessionFuzz::RELATIONS.each do |rel|
        expect(SessionFuzz.check(rel, song)).to be_nil.or(eq(:skip)), "seed #{seed} #{rel}"
      end
    end
  end

  # Shrunk songs of fixed finds (omnibus13, omnibus15), kept so they stay fixed
  {
    'an uneven-step tween launched where a step starts between samples (seed 116)' => [
      :timeline, ['bpm 174'], ['at_bar(1, beat: 2) { bg :x1, tween([300.0, 3000.0, 800.0], [1.beat, 3.beats]) * 0.0002, on: :now }'], 2,
    ],
    # (tween-curves-1: the glide read the step it was leaving along the
    # next step's :hold, and resumed glides started from a rounded Float
    # elapsed time, so a :hold launched mid-step jumped a sample apart)
    'a tween with a curve per step launched mid-step between samples (seed 293)' => [
      :timeline, ['bpm 174', 'knob :busy, 0.5'], ['at_bar(1, beat: 3) { bg :x1, tween([0.0, 1.0, 0.25, 0.75], [1.beat, 2.beats], curve: [:fast, :hold, :sharp]) * 0.5, on: :now }'], 1,
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
    # (omnibus15: a scene restarting the track stopped its cue, and the
    # launch landing after it raised on the render thread)
    'a launch landing after a scene restarted the cued track (seed 6)' => [
      :runs, ['bpm 126'], [
        'track(:t2, q: 1/4r) { |clip| clip.synth(voices: 1) { |v| v.hz.triangle * v.amp_env(0.002, 0.05, 0.6, 0.02) } * 0.3 }',
        'scene :s1, t2: seq(C5, D5).n8, others: :keep',
        'at_bar(2, beat: 2) { go :s1, on: :now }',
        'at_bar(2) { cue :t2, seq(A4, C5).n8.loop }',
        'at_bar(2, beat: 3) { launch }',
      ], 2,
    ],
    # (omnibus15: a cue of a playing part in a scheduled block is a
    # pre-listen still queued when the launch decides; seed 34)
    'a pre-listen launched while it is still queued (seed 34)' => [
      :runs, ['bpm 120'], [
        'track(:t1, q: 1) { |clip| clip.synth(voices: 3) { |v| v.hz.square * v.amp_env(0.002, 0.05, 0.6, 0.02) } * 0.3 }',
        "track(:t2, q: 1/2r) { |kit| tr808(kit) * 0.5 }",
        "scene :s1, t2: grid(16, kick: 'X..x..x.', hat: '.x.x.x.x', open_hat: '...x').loop, others: :keep",
        'at_bar(1) { go :s1, on: :now }',
        'at_bar(2) { bg :t1, seq(A4, C5).n8.loop, on: :now; cue :t1 }',
        'at_bar(2, beat: 3) { launch :t1 }',
      ], 3,
    ],
    # (omnibus16: generative-g4's FUZZ_BASE=41 FUZZ=150 seeds 52, 82, 127;
    # a render's end bar under a followed tempo LFO came from the tempo at
    # its last buffer's start, 1-2 frames off at 367-frame buffers)
    'a followed tempo LFO up to the end bar' => [
      :buffer_size, ['bpm 174'], [
        'bg :a, 220.hz.sine.at(0.1)',
        'at_bar(2, beat: 4) { tempo 2.beats.lfo.at(150..170) }',
      ], 2,
    ],
    # (omnibus16: dropouts-2's seeds 11 and 28; a master chain landing
    # inside a buffer was sampled from the buffer's start, zeros before its
    # start priming softclip's ADAA state)
    'a master chain landing inside a buffer' => [
      :buffer_size, ['bpm 120'], [
        'track(:t1, q: 1) { |clip| clip.synth(voices: 2) { |v| v.hz.saw * v.amp_env(0.002, 0.05, 0.6, 0.02) } * 0.3 }',
        'scene :s1, t1: seq(G4.n16, B4.n16, D5.n8).loop',
        'at_bar(1) { go :s1, on: :now }',
        'at_bar(1, beat: 3) { master { |m| m.softclip(0, 0.9) } }',
      ], 1,
    ],
    # (omnibus16: a started player waiting after a seek back played again
    # from the start of the span holding its start, not its own sample)
    'a clipless part after a seek back before its start' => [
      :buffer_size, ['bpm 120'], [
        'at_bar(1, beat: 2) { bg :held, 0.05.constant, in: 1/8r }',
        'at_bar(1, beat: 4) { seek 1, 2.25 }',
      ], 2,
    ],
    # (batch-fixes-1030, the 2026-10-30 batch soak's seed 766010: a player
    # waiting after a seek back restarted its timeline nodes only when its
    # start fell inside a span, so a scene's loop starting on an 800-frame
    # buffer's edge played from where the seek put it, a beat late)
    'a loop starting on a buffer edge after a seek back (seed 766010)' => [
      :buffer_size, ['bpm 150'], [
        'knob :busy, 0.5',
        'track :t2, :dnb_sub, q: 1',
        'scene :s1, t2: seq(A3, R, C4.n4, E4).n16.loop, fade: 1/4r',
        'at_bar(3, beat: 2) { bg :t2, seq(C5, D5).n16, on: :now; bg :t2, seq(E5, G5).n8.loop, in: 1/4r }',
        'at_bar(2, beat: 2) { flow(seed: 22, on: :beat) { generate markov(s1: { s1: 3 }, seed: 67), s1: [1, 2.beats] } }',
        'at_bar(3, beat: 4) { seek 3 }',
      ], 3,
    ],
    # (batch-fixes-1030, seed 766044: a player fading out rendered to the
    # end of the buffer holding its fade's end, so the kick inside a
    # scene's faded-out kit fed `duck(:t1, only: :kick)` up to a buffer
    # longer)
    'a kick sidechain inside a kit a scene fades out (seed 766044)' => [
      :buffer_size, ['bpm 137.5'], [
        'knob :busy, 0.5',
        'track(:t1, q: 1) { |kit| tr808(kit) * 0.5 }',
        "scene :s1, t1: grid(16, kick: 'x...x...', snare: '....x...').loop, others: :keep",
        "scene :s2, t1: grid(16, cymbal: 'X'), fade: 1/4r",
        'at_bar(2) { flow(seed: 28, on: :beat) { generate markov(s1: { s1: 3, s2: 3 }, s2: { s1: knob(:busy), s2: 2 }, seed: 71), s1: [1, 2.beats], s2: [1, 2.beats] } }',
        "at_bar(1, beat: 2) { bg :t1, grid(16, kick: 'x...x...', open_hat: '..x...x.').loop, in: 1/4r; bg :ducked, 0.2.constant.duck(:t1, only: :kick, amount: -12.db), in: 1/4r }",
      ], 2,
    ],
    # (session-2, FUZZ=60 seed 16: a bus quiet long enough to sleep on a
    # grid frame slept through the rest of the span even when the send
    # turned up there was loud, so the send reached it a buffer late)
    'a send turned up on the grid frame where its bus falls asleep (seed 16)' => [
      :buffer_size, ['bpm 120'], [
        'knob :tint, 0, range: 0..1',
        'bg :t1, 0.2.constant, on: :now',
        'bus(:colour) { |sig| sig * 0.5 }',
        'at_bar(1) { feed :t1, :colour, :tint }',
        'at_bar(1, beat: 3) { turn :tint, 1 }',
      ], 1,
    ],
    # (the 2026-11-01 batch soak, fix-batch-1101: the seek forgot the time
    # its block ran for, so a render with nothing playing ended at the
    # start of the buffer holding the seek, 125600 frames at 800 and 125514
    # at 367; since session-2's exact render ends)
    'a block seeking back from its own time with nothing playing (seed 768014)' => [
      :buffer_size, ['bpm 137.5', 'meter 3, 4', 'knob :busy, 0.5'], [
        'at_bar(2, beat: 4) { seek 2, 2.999 }',
      ], 3,
    ],
    # (the same seed after that fix, FUZZ=24 FUZZ_BASE=768000: an fx swap
    # split off on the floor sample of bar 3 hid the seek on its ceiling
    # sample from Seeks#frames_before_seek, so the seek landed at the next
    # buffer's start; since carry-1's floor splits)
    'an fx swap and a seek landing on one time between samples (seed 768014)' => [
      :buffer_size, ['bpm 137.5', 'meter 3, 4', 'knob :busy, 0.5'], [
        'track :t3, L.inst.jungle.jungle_sub, q: 1',
        'scene :s1, t3: seq(C3.n4, G3.n8.dotted, Eb3.n16).loop, others: :keep',
        'at_bar(1) { go :s1, on: :now }',
        'at_bar(3) { fx :t3, :dub }',
        'at_bar(2, beat: 4) { seek 2, 2.999 }',
      ], 3,
    ],
    # (the 2026-11-04 batch 11 soak, fix-batch-1104: a one-shot clip's idle
    # Synth lanes ended their gates in the buffer that read its last
    # event, and those gates, read again while another lane rang out,
    # stayed there; the seek back to before the clip's start brought them
    # back that buffer behind their note numbers, so the replayed first
    # note sounded 572 frames late at 800-frame buffers and 310 at 367;
    # since Notes::Node#keep_time)
    'a seek back past a one-shot synth clip that ended on the seek (seed 771024)' => [
      :buffer_size, ['bpm 126', 'meter 3, 4'], [
        'knob :busy, 0.5',
        'at_bar(1, beat: 2) { tempo 90, over: 3.beats; after(in: 2.beats) { seek 1, 5/2r } }',
        'at_bar(1, beat: 3) { bg :lib, preset(:square_bass, midi: seq(C5, D5).n8).at(0.3); turn :"lib/cutoff", 300.0, over: 1/2r }',
      ], 2,
    ],
    # (the same soak, seed 771036: two wires of :t3 on one beat, each with
    # its unwire; the second wire replaced the first, the first line's
    # unwire unwired :t3, and the second's raised "No stream is wired into
    # :t3", as a user's script would; the generator's unwire is guarded
    # since fix-batch-1104)
    'two wires of one track on one beat, each unwired while still wired (seed 771036)' => [
      :runs, ['bpm 126'], [
        'knob :busy, 0.5',
        'track(:t3, q: 1) { |clip| clip.synth(voices: 2) { |v| v.hz.sine * v.amp_env(0.002, 0.05, 0.6, 0.02) } * 0.3 }',
        'at_bar(1, beat: 4) { wire :t3, seq(G3.n4, D4.n8.dotted, B3.n16).loop.stream.echo(1.n16, 2), on: :now; after(in: 2.beats) { unwire :t3 if wires.key?(:t3) } }',
        'at_bar(1, beat: 4) { wire :t3, seq(A3, C4.n4, E4).n8.loop.stream, on: :now; after(in: 2.beats) { unwire :t3 if wires.key?(:t3) } }',
      ], 1,
    ],
    'the same without a tempo ramp or preset (seed 771024)' => [
      :buffer_size, ['bpm 126', 'meter 3, 4'], [
        'at_bar(1, beat: 3) { bg :lib, seq(C5, D5).n8.synth { |v| v.hz.square * v.amp_env(0.002, 0.05, 0.6, 0.02) }.at(0.3) }',
        'at_bar(1, beat: 4) { seek 1, 5/2r }',
      ], 2,
    ],
    # (lesson-fixes-1: a console swap didn't change the track's clip, so
    # `bg :t1` after a stop played the scene's clip again; seed 5's case)
    'a swapped instrument track stopped and launched again by name' => [
      :runs, ['bpm 137.5', 'meter 3, 4'], [
        'track :t1, :dnb_sub, q: 1',
        'scene :s1, t1: seq(C3.n4, G3.n8.dotted, Eb3.n16).loop',
        'at_bar(1) { go :s1, on: :now }',
        'at_bar(2, beat: 17/8r) { swap :t1, seq(F3, A3, C4, E4).n4.loop, on: :now }',
        'kept_t1 = []',
        'at_bar(2, beat: 19/8r) { s = Session.current; s.change(:probe, :t1, s.now) { kept_t1.replace(s.timeline_nodes_of(:t1).grep(MIDI::ClipSource).map { |n| (n.ring_clip || n.pending_clip || n.clip).lineage.last }) }; stop :t1, fade: 0 }',
        'at_bar(2, beat: 21/8r) { bg :t1, on: :now }',
        'at_bar(2, beat: 23/8r) { s = Session.current; s.change(:probe, :t1, s.now) { now = s.timeline_nodes_of(:t1).grep(MIDI::ClipSource).map { |n| (n.ring_clip || n.pending_clip || n.clip).lineage.last }; ' \
          'raise "t1 played other clips after its relaunch" unless kept_t1.empty? || now.empty? || kept_t1.all? { |r| now.any? { |c| c.equal?(r) } } } }',
      ], 2,
    ],
    # (fix-808-fuzz, tempo-2's seed 28: the swap landed inside a 367-frame
    # buffer on the frame the fade ended, saw the faded player neither
    # playing nor stopped, and swapped the scene's queued launch instead
    # (the ratchet played at 367, the plain kit at 800); since parity-1's
    # Kit#ratchet, the first transform such a swap could carry)
    'a kit stopped with a fade, relaunched by its scene, and swapped on the fade end (seed 28)' => [
      :buffer_size, ['bpm 120', 'knob :busy, 0.5'], [
        'track(:t1, q: 1) { |kit| tr808(kit) * 0.5 }',
        "scene :s1, t1: grid(8, kick: 'x.x.', hat: 'xxxx').loop, others: :keep",
        'at_bar(1) { go :s1, on: :now }',
        'at_bar(1, beat: 3) { go :s1 }',
        'at_bar(1, beat: 2) { stop :t1, fade: 1/4r }',
        "at_bar(1, beat: 3) { swap :t1, grid(8, kick: 'x.x.', hat: 'xxxx').loop.ratchet(2) }",
      ], 2,
    ],
    # (fix-808-fuzz, ux-notes-2's seed 42: drum voices ended on whole
    # buffers, so the one-shot kit's render was 25600 frames at 800 and
    # 26424 at 367; since session-2's exact render ends made the lengths
    # count)
    'a one-shot kit ending after its scene launches it (seed 42)' => [
      :buffer_size, ['bpm 137.5', 'knob :busy, 0.5'], [
        'track(:t1, q: 1) { |kit| tr808(kit) * 0.5 }',
        "scene :s1, t1: grid(16, clap: '..x.'), others: :keep",
        'at_bar(1) { go :s1, on: :now }',
      ], 1,
    ],
    # (fix-batch-1102b, FUZZ=24's seed 13: an idle render kept time for a
    # queued level change, then ended at the start of the buffer holding
    # it: 91200 frames at 800, 91383 at 367; it ends on the change's frame)
    'a queued change landing after every sound ended (FUZZ=24 seed 13)' => [
      :buffer_size, ['bpm 126', 'knob :busy, 0.5'], [
        'at_bar(1, beat: 4) { level :t2, 0, on: :bar }',
      ], 2,
    ],
    # (fuzz-fixes-2: after the seek back to bar 2, the flow's pass there
    # launched :s1 now, and the stop of :t1's cue that the scene's start
    # of :t1 makes (Session::Cue#end_cue_at_start) cancelled the cue
    # queued for bar 3, so `launch` found nothing cued; merge:gate's seed
    # 427306, shrunk with the cue and its launch kept together)
    'a cue queued for after a flow relaunch that a seek back moved earlier (seed 427306)' => [
      :runs, ['bpm 137.5'], [
        'knob :cut, 1200.0, range: 200.0..4000.0',
        'track(:t1, q: 1) { |clip| clip.synth(voices: 2) { |v| v.hz.sine * v.amp_env(0.002, 0.05, 0.6, 0.02) }.filter(:lowpass, cutoff: knob(:cut), quality: 2) * 0.3 }',
        "track(:t2, q: 1/2r) { |kit| tr808(kit) * 0.5 }",
        "scene :s1, t1: seq(C5, D5).n8, t2: grid(16, kick: 'X..x..x.', hat: '.x.x.x.x', open_hat: '...x').loop, others: :keep",
        'at_bar(2) { tempo 160, over: 3.beats; after(in: 2.beats) { seek 2, 1 } }',
        'at_bar(3) { cue :t1, seq(A4, C5).n8.loop }',
        'at_bar(3, beat: 3) { launch }',
        'at_bar(2) { flow(seed: 54, on: :beat) { generate markov(s1: { s1: 2 }, seed: 25), s1: 1 } }',
      ], 2,
    ],
  }.each do |name, (relation, header, lines, bars)|
    it "holds #{relation} for #{name}" do
      expect(SessionFuzz.check(relation, SessionFuzz::Song.new(header: header, lines: lines, bars: bars))).to be_nil
    end
  end

  # (batch 16's soak, fix-fuzz-1106: the parity-1 kit swap of t3's first
  # grid landed while the flow played :s2, whose beats clip has no kit
  # rows: a user error by design, ClipSwaps#kit_swap_mapping; kit swaps
  # are generated only where every scene gives the track a grid with the
  # first one's rows)
  it 'swaps a kit only where every scene plays it a grid with those rows (seed 773034)', render_budget: { seconds: 60, reason: 'one random song' } do
    song = SessionFuzz.generate(Random.new(773034))
    expect(song.code).to include('t3: beats(16')
    expect(song.code).not_to match(/swap :t3, grid/)
    expect(SessionFuzz.check(:runs, song)).to be_nil

    expect(SessionFuzz.kit_rows?("grid(16, kick: 'x...', hat: 'x.x.').loop", %w[kick hat])).to eq(true)
    expect(SessionFuzz.kit_rows?("grid(16, kick: 'x...').loop", %w[kick hat])).to eq(false)
    expect(SessionFuzz.kit_rows?('beats(16, seed: 3) { kick [1, 0, 0, 0] * 4 }', %w[kick])).to eq(false)
  end

  # The :carry relation's finds (carry-1), shrunk: each song's carrying
  # rebuilds come from its track lines and length (SessionFuzz.carry_lines)
  {
    'a rebuild landing between samples (137.5 BPM)' => [
      ['bpm 137.5', 'knob :busy, 0.5'], [
        'track(:t2, q: 1/4r) { |clip| clip.synth(voices: 3) { |v| v.hz.sine * v.amp_env(0.002, 0.05, 0.6, 0.02) } * 0.3 }',
        'scene :s1, t2: seq(C4, E4, G4).n8.loop',
        'at_bar(1) { go :s1, on: :now }',
      ], 3, false,
    ],
    'one-shot clips and a seek back before the rebuilds' => [
      ['bpm 174', 'knob :busy, 0.5'], [
        'track(:t1, q: 1/2r) { |clip| clip.synth(voices: 1) { |v| v.hz.square * v.amp_env(0.002, 0.05, 0.6, 0.02) } * 0.3 }',
        'track(:t2, q: 1/2r) { |clip| clip.synth(voices: 3) { |v| v.hz.square * v.amp_env(0.002, 0.05, 0.6, 0.02) } * 0.3 }',
        'track(:t3, q: 1/2r) { |clip| clip.synth(voices: 2) { |v| v.hz.sine * v.amp_env(0.002, 0.05, 0.6, 0.02) } * 0.3 }',
        'scene :s1, t1: seq(C5, D5).n8, t2: seq(C5, D5).n8, t3: seq(C3.n4, G3.n8.dotted, Eb3.n16).loop, fade: 1/4r',
        'at_bar(1) { go :s1, on: :now }',
        'at_bar(1, beat: 4) { seek 1, 2.25 }',
      ], 1, false,
    ],
    'a kit rebuilt while a launch with other rows waits' => [
      ['bpm 137.5', 'knob :busy, 0.5'], [
        'track(:t1, q: 1/4r) { |kit| tr808(kit) * 0.5 }',
        "scene :s1, t1: grid(16, kick: 'X..x..x.', hat: '.x.x.x.x', open_hat: '...x').loop, fade: 1/4r",
        'at_bar(1) { go :s1, on: :now }',
        "at_bar(1, beat: 2) { bg :t1, grid(16, kick: 'x...x...', open_hat: '..x...x.').loop, on: :bar }",
      ], 1, false,
    ],
    'a mute landing with a rebuild' => [
      ['bpm 112', 'knob :busy, 0.5'], [
        'track(:t1, q: 1/4r) { |kit| tr808(kit) * 0.5 }',
        'track(:t2, q: 1) { |clip| clip.synth(voices: 1) { |v| v.hz.triangle * v.amp_env(0.002, 0.05, 0.6, 0.02) } * 0.3 }',
        "scene :s1, t1: grid(16, kick: 'X..x..x.', hat: '.x.x.x.x', open_hat: '...x').loop, t2: motifs(scale(:dorian, :d).weights, 8, density: knob(:busy), mutate: knob(:busy), evolve: 1, seed: 4), others: :keep",
        'at_bar(1) { go :s1, on: :now }',
        'at_bar(2, beat: 2) { mute :t1 }',
      ], 3, true,
    ],
    'a flow ringing a track out where its rebuild lands (seed 61)' => [
      ['bpm 137.5', 'knob :busy, 0.5'], [
        'knob :cut, 1200.0, range: 200.0..4000.0',
        'track(:t1, q: 1/2r) { |clip| clip.synth(voices: 1) { |v| v.hz.sine * v.amp_env(0.002, 0.05, 0.6, 0.02) }.filter(:lowpass, cutoff: knob(:cut), quality: 2) * 0.3 }',
        'track(:t2, q: 1) { |kit| tr808(kit) * 0.5 }',
        'track :t3, :dnb_sub, q: 1',
        'scene :s1, t1: motifs(scale(:dorian, :d).weights, 8, density: knob(:busy), mutate: knob(:busy), evolve: 1, seed: 4), t2: beats(16, energy: knob(:busy), hold: 2, seed: 2) { kick [1, 0, 0, 0] * 4; hat euclid(10, 16), mutate: 0.5; fill every: 2, snare: 0.6 }, t3: melody(scale(:minor, :a).weights, 8, rest: knob(:busy), vary: true, seed: 2).loop',
        'scene :s2, t1: seq(C4, E4, G4).n8.loop',
        'at_bar(1) { flow(seed: 79, on: :beat) { generate markov(s1: { s1: 3, s2: 1 }, s2: { s1: 2, s2: 1 }, seed: 14), s1: 1..2, s2: 1 } }',
      ], 3, true,
    ],
    'a flow replacing a kit before its rebuild lands (seed 132)' => [
      ['bpm 120', 'meter 3, 4', 'knob :busy, 0.5'], [
        'track(:t1, q: 1/4r) { |kit| tr909(kit) * 0.5 }',
        'track(:t3, q: 1/4r) { |kit| tr808(kit) * 0.5 }',
        "scene :s1, t1: grid(16, kick: 'X..x..x.', hat: '.x.x.x.x', open_hat: '...x').loop, t3: grid(16, kick: 'x...x...', snare: '....x...').loop",
        "scene :s2, t1: grid(16, kick: 'X..x..x.', hat: '.x.x.x.x', open_hat: '...x').loop, t3: grid(16, clap: '..x.'), others: :keep",
        'at_bar(1) { flow(seed: 43, on: :beat) { generate markov(s1: { s1: knob(:busy), s2: 1 }, s2: { s1: 3, s2: knob(:busy) }, seed: 86), s1: 1, s2: 2.beats } }',
      ], 3, true,
    ],
    # (t3's rebuild lands on bar 3 while it sleeps muted, a frame before
    # its unmute: it starts fresh by design, so the mixes are compared up
    # to its landing, past t1's carried rebuild on bar 2; the batch-end
    # soak of omnibus19 found it, fix-batch-1031)
    'a muted, sleeping track rebuilt before its unmute (seed 767029)' => [
      ['bpm 112', 'knob :busy, 0.5'], sleeping_rebuild = [
        'knob :cut, 1200.0, range: 200.0..4000.0',
        'track :t1, :dnb_sub, q: 1',
        'track(:t2, q: 1/2r) { |clip| clip.synth(voices: 3) { |v| v.hz.square * v.amp_env(0.002, 0.05, 0.6, 0.02) }.filter(:lowpass, cutoff: knob(:cut), quality: 2) * 0.3 }',
        'track(:t3, q: 1/2r) { |clip| clip.synth(voices: 2) { |v| v.hz.triangle * v.amp_env(0.002, 0.05, 0.6, 0.02) }.filter(:lowpass, cutoff: knob(:cut), quality: 2) * 0.3 }',
        'scene :s1, t1: seq(F3, A3, C4, E4).n4.loop, t2: seq(C3.n4, G3.n8.dotted, Eb3.n16).loop, t3: seq(A3, R, C4.n4, E4).n16.loop',
        'at_bar(1) { go :s1, on: :now }',
        'at_bar(3) { unmute :t3, on: :now }',
        'at_bar(1, beat: 2) { mute :t3 }',
      ].freeze, 3, false,
    ],
    # (the 2026-11-01 batch soak, fix-batch-1101: the rebuilt synth's
    # one-shot ended 1/2 a whole note late, so the flow's scene at bar 3
    # found t2 still playing and built its patch again instead of swapping
    # the clip in; since carry-1)
    'a one-shot swapped into a rebuilt synth before a flow relaunches it (seed 768044)' => [
      ['bpm 126', 'knob :busy, 0.5'], [
        'track(:t2, q: 1/4r) { |clip| clip.synth(voices: 3) { |v| v.hz.saw * v.amp_env(0.002, 0.05, 0.6, 0.02) } * 0.3 }',
        'scene :s1, t2: seq(C3.n4, G3.n8.dotted, Eb3.n16).loop',
        'at_bar(1) { go :s1, on: :now }',
        'at_bar(2, beat: 2) { bg :t2, seq(C5, D5).n16, on: :now; bg :t2, seq(E5, G5).n8.loop, in: 1/4r }',
        'at_bar(3) { flow(seed: 74, on: :beat) { generate markov(s1: { s1: knob(:busy) }, seed: 33), s1: 1..2 } }',
      ], 3, false,
    ],
    # (batch 16's soak, fix-fuzz-1106: t1's rebuild and a seek back landed
    # on bar 2 beat 3; the rebuilt graph's first start, after the seek,
    # took over the replaced clip source's notes as if no jump had
    # happened, so they rang on instead of ending, and the seek's position
    # wasn't chased; shrunk from a song whose seek came with a regions lane)
    'a rebuild landing on the frame of a seek back (seed 773017)' => [
      ['bpm 150', 'knob :busy, 0.5'], [
        'track(:t1, q: 1/4r) { |clip| clip.synth(voices: 3) { |v| v.hz.triangle * v.amp_env(0.002, 0.05, 0.6, 0.02) } * 0.3 }',
        'scene :s1, t1: seq(C4, E4, G4).n8.loop',
        'at_bar(1) { go :s1, on: :now }',
        'at_bar(1, beat: 4) { after(in: 3.beats) { seek 1, 1.1 } }',
      ], 3, false,
    ],
  }.each do |name, (header, lines, bars, slow)|
    it "holds carry for #{name}", *(slow ? [:slow] : []), render_budget: { seconds: 90, reason: 'a song rendered twice with and without its rebuilds' } do
      song = SessionFuzz::Song.new(header: header, lines: lines, bars: bars)
      expect(SessionFuzz.carry_lines(song)).not_to be_empty
      expect(SessionFuzz.check(:carry, song)).to be_nil
    end
  end

  it 'notes where a carrying rebuild of a sleeping track landed fresh', render_budget: { seconds: 90, reason: 'a song rendered twice with and without its rebuilds' } do
    song = SessionFuzz::Song.new(header: ['bpm 112', 'knob :busy, 0.5'], lines: sleeping_rebuild, bars: 3)
    expect(SessionFuzz.check(:carry, song)).to be_nil
    # (bar 3 at 112 BPM: the floor of 2 bars' 205714.29 frames)
    expect(CarryCheck.fresh_frames).to eq([(2 * 4 * 60 * 48000r / 112).floor])
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

  # (fuzz-fixes-2: seed 427306 shrank to a `launch` with its cue dropped,
  # a plain user error with the bug's own message)
  it 'drops a cue and the launch that needs it together while shrinking' do
    lines = ['at_bar(3) { cue :t1, seq(A4, C5).n8.loop }', 'at_bar(1) { go :s1 }', 'at_bar(3, beat: 3) { launch }',
             'at_bar(2) { bg :t2, seq(A4, C5).n8.loop, on: :now; cue :t2 }', 'at_bar(2, beat: 3) { launch :t2 }']
    expect(SessionFuzz.drop_line(lines, 0)).to eq(lines.values_at(1, 3, 4))
    expect(SessionFuzz.drop_line(lines, 3)).to eq(lines.values_at(0, 1, 2))
    expect(SessionFuzz.drop_line(lines, 2)).to eq(lines.values_at(0, 1, 3, 4))
  end

  # (fuzz-fixes-2: batch9's soak ran out of render budget inside seed
  # 770035's :plan renders, and the error was shrunk and reported as a
  # plan mismatch)
  it 'raises the render budget running out instead of reporting it as the relation failing' do
    # (a song of its own: songs :runs found an error in are skipped by the
    # other relations, and the next example's song raises)
    song = SessionFuzz::Song.new(header: ['bpm 120'], lines: ['bg :a, 221.hz.sine * 0.1'], bars: 1)
    allow(SessionFuzz).to receive(:render).and_raise(RenderBudget::Exceeded, 'over budget')
    %i[runs plan].each { |rel| expect { SessionFuzz.check(rel, song) }.to raise_error(RenderBudget::Exceeded) }
  end

  it 'fails a song whose render runs past RENDER_CAP' do
    stub_const('SessionFuzz::RENDER_CAP', 0.5)
    song = SessionFuzz::Song.new(header: ['bpm 120'], lines: ['bg :a, 220.hz.sine * 0.1'], bars: 2)
    expect(SessionFuzz.check(:runs, song)).to match(/\ASessionFuzz::RenderCapped: .*RENDER_CAP \(0\.5 s\)/)
  end
end
