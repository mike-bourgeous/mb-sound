# Session fuzzing (fuzz-fixes-1, 2026-10-25): a seeded generator of small
# Sessions (tracks with synth, drum, and pitch patches, clips including
# drum grids and tweens, scenes, scheduled launches, swaps, stops, mutes,
# solos, knob turns, tempo ramps and followed tempo LFOs, seeks back across a
# clipless part's start), each a short render-style Ruby script (the repro is
# the code), rendered by MB::Sound.render and checked against relations
# that must hold for any song (spec/lib/mb/sound/session_fuzz_spec.rb):
#
# - :runs: the render finishes without an error (800-frame buffers);
#   steps include re-bgs of looped clips after one-shots and cue/launch
#   sequences (omnibus15), and flows generated as they play from a
#   (sometimes knob-steered) Markov chain over the scenes (generative-g4)
# - :buffer_size: 367-frame buffers give the same mix within -80 dB of the
#   peak ("ears win"), and the same length
# - :plan: plans off gives the same mix, bit for bit (both at the default
#   MB::Sound.precision :fast; fast-sine-1), and so do plans whose rebuilds
#   wait for a block boundary (Plan.rebuilds :next_span, as a realtime
#   Session's render thread defers them; render-rebuild-1)
# - :timeline: a timeline-following part (a looping tween, a looping
#   clip's frequency) launched partway through the song plays from the
#   launch what it plays there when started at bar 1, within -80 dB
# - :warm: warming every change before it lands (Session::Warming.always:
#   copies built and played in sandboxes) gives the same mix, bit for bit
#
# Renders use exact_lanes: true (synth lanes freed on the 800-frame grid,
# so voice allocation is the same at any buffer size; see Synth).
# A failure is shrunk (lines dropped, bars cut) while the same relation
# still fails, and reported with its seed and minimal script:
#
#   FUZZ_SEED=12 bundle exec rspec spec/lib/mb/sound/session_fuzz_spec.rb
#   FUZZ=200 bundle exec rspec spec/lib/mb/sound/session_fuzz_spec.rb   # the long mode
require 'stringio'
require_relative 'recipe_helpers'

module SessionFuzz
  RELATIONS = %i[runs buffer_size plan timeline warm].freeze

  # Relations known to fail for a reason recorded elsewhere, as
  # { relation => [[Regexp on the script, 'reason'], ...] }: skipped, counted.
  KNOWN = {
    # (seed 116's uneven-step tween launched where a step starts between
    # samples, and seed 1194's tr808 revived after a ring-out, are fixed
    # since omnibus13; session_fuzz_spec keeps their shrunk songs)
    # (dropouts-2's master chain landing mid-buffer, which primed
    # softclip's ADAA state from zeros, is fixed since omnibus16;
    # session_fuzz_spec keeps a shrunk song)
  }.freeze

  # A generated song: +header+ lines (tempo, meter) always kept, +lines+
  # (definitions and scheduled commands) that shrinking may drop, the
  # render length in bars, and the pure parts (see #timeline_parts).
  Song = Struct.new(:header, :lines, :bars, keyword_init: true) do
    def code = (header + lines).join("\n")
    def to_s = code
  end

  Failure = Struct.new(:seed, :relation, :song, :message, :original, keyword_init: true) do
    def to_s
      "session relation #{relation} fails for seed #{seed} (FUZZ_SEED=#{seed}); shrunk from #{original.lines.length} to " \
        "#{song.code.lines.length} lines (render #{song.bars} bars):\n\n#{song.code.gsub(/^/, '  ')}\n\n#{message.to_s.lines.first(8).join}"
    end
  end

  TEMPOS = [112, 120, 126, 137.5, 150, 174].freeze
  SHAPES = %i[saw square triangle sine].freeze

  MELODIC = [
    'seq(C4, E4, G4).n8.loop', 'seq(A3, R, C4.n4, E4).n16.loop', 'seq(C3.n4, G3.n8.dotted, Eb3.n16).loop',
    'seq(C5, D5).n8', 'seq(F3, A3, C4, E4).n4.loop', 'seq(G4.n16, B4.n16, D5.n8).loop',
    # Generators steered by the knob :busy (G3: read at each cycle's decision point)
    'melody(scale(:minor, :a).weights, 8, rest: knob(:busy), vary: true, seed: 2).loop',
    'motifs(scale(:dorian, :d).weights, 8, density: knob(:busy), mutate: knob(:busy), evolve: 1, seed: 4)',
  ].freeze
  DRUMS = [
    "grid(16, kick: 'x...x...', snare: '....x...').loop", "grid(16, cymbal: 'X')", "grid(8, kick: 'x.x.', hat: 'xxxx').loop",
    "grid(16, clap: '..x.')", "grid(16, kick: 'X..x..x.', hat: '.x.x.x.x', open_hat: '...x').loop",
    'beats(16, energy: knob(:busy), hold: 2, seed: 2) { kick [1, 0, 0, 0] * 4; hat euclid(10, 16), mutate: 0.5; fill every: 2, snare: 0.6 }',
  ].freeze
  # Looping tweens (timeline-aligned): their output is a function of the
  # timeline position alone (with gains that bring them near 0.5)
  TWEENS = [
    'tween([200.0, 1000.0], 1.bar, curve: :linear) * 0.0005', 'tween([300.0, 3000.0, 800.0], [1.beat, 3.beats]) * 0.0002',
    'tween([0.0, 1.0, 0.3], 2.beats, curve: :bounce) * 0.5', 'tween([100.0, 900.0], 3.beats, curve: :elastic) * 0.0005',
  ].freeze
  # Library instruments for `track :t1, ...` (light ones: one voice each)
  INSTRUMENTS = [':dnb_sub', 'L.inst.jungle.jungle_sub', ':dnb_sub'].freeze

  # Clips whose frequency is a function of the timeline position alone
  FREQ_CLIPS = ['seq(C4, E4, G4).n8.loop', 'seq(A3, C4.n4, E4).n8.loop', 'seq(G3.n4, D4.n8.dotted, B3.n16).loop'].freeze

  module_function

  # --- generation -----------------------------------------------------

  def pick(rng, list) = list[rng.rand(list.length)]

  # +commands+: how many of COMMANDS the steps draw from (a seed found
  # when the list was shorter makes its old song with the old length).
  def generate(rng, commands: COMMANDS.length)
    bpm = pick(rng, TEMPOS)
    header = ["bpm #{bpm}"]
    header << 'meter 3, 4' if rng.rand < 0.15
    header << 'knob :busy, 0.5' # (steered generators read it)
    lines = []
    knob = rng.rand < 0.5
    lines << 'knob :cut, 1200.0, range: 200.0..4000.0' if knob

    tracks = {}
    instruments = nil
    rng.rand(1..3).times do |i|
      name = :"t#{i + 1}"
      q = pick(rng, ['1', '1/4r', '1/2r'])
      if rng.rand < 0.4
        kit = rng.rand < 0.75 ? 'tr808' : 'tr909'
        tracks[name] = :drums
        lines << "track(:#{name}, q: #{q}) { |kit| #{kit}(kit) * 0.5 }"
      elsif rng.rand < 0.2
        # A library instrument as the patch (library-instruments-1)
        tracks[name] = :synth
        (instruments ||= []) << name
        lines << "track :#{name}, #{pick(rng, INSTRUMENTS)}, q: #{q}"
      else
        tracks[name] = :synth
        cut = knob && rng.rand < 0.5 ? '.filter(:lowpass, cutoff: knob(:cut), quality: 2)' : ''
        lines << "track(:#{name}, q: #{q}) { |clip| clip.synth(voices: #{rng.rand(1..3)}) { |v| v.hz.#{pick(rng, SHAPES)} * v.amp_env(0.002, 0.05, 0.6, 0.02) }#{cut} * 0.3 }"
      end
    end
    clip_for = ->(name) { tracks[name] == :drums ? pick(rng, DRUMS) : pick(rng, MELODIC) }

    scenes = []
    first_clips = nil # (the first scene's clips, for kit swaps)
    swappable = nil # (synth tracks the first scene starts with looping clips: swaps need a player, and take Clips, not Kits)
    rng.rand(1..2).times do |i|
      sname = :"s#{i + 1}"
      parts = tracks.keys.select { rng.rand < 0.75 }
      parts = [tracks.keys.first] if parts.empty?
      extra = [', others: :keep', ', fade: 1/4r', ''][rng.rand(3)]
      clips = parts.to_h { |t| [t, clip_for.(t)] }
      swappable ||= clips.select { |t, c| tracks[t] == :synth && c.end_with?('.loop') }.keys
      first_clips ||= clips
      lines << "scene :#{sname}, #{clips.map { |t, c| "#{t}: #{c}" }.join(', ')}#{extra}"
      scenes << sname
    end

    bars = rng.rand(2..3)
    beats = header.any? { |l| l.start_with?('meter 3') } ? 3 : 4
    lines << "at_bar(1) { go :#{scenes.first}, on: :now }"
    names = tracks.keys
    step = Step.new(rng: rng, scenes: scenes, swappable: swappable, instruments: instruments, knob: knob, clip_for: clip_for, bgs: 0)
    rng.rand(1..5).times do
      bar = rng.rand(1..bars)
      beat = rng.rand(1..beats)
      beat = 2 if bar == 1 && beat == 1 # (after the first scene's launch)
      step.on = rng.rand < 0.5 ? ', on: :now' : ''
      step.t = pick(rng, names)
      cmd = COMMANDS[rng.rand(commands)].call(step)
      next unless cmd

      lines << "at_bar(#{bar}#{beat == 1 ? '' : ", beat: #{beat}"}) { #{cmd} }"
    end

    # (omnibus15) a synth track given a one-shot, then a looping clip
    # landing after the one-shot ended: the patch builds again instead of
    # swapping into ended voices (drawn after the steps above, so earlier
    # seeds keep their songs and only gain these lines)
    synths = tracks.select { |_, k| k == :synth }.keys
    if !synths.empty? && rng.rand < 0.35
      t = pick(rng, synths)
      lines << "at_bar(#{rng.rand(1..bars)}, beat: 2) { bg :#{t}, seq(C5, D5).n16, on: :now; bg :#{t}, seq(E5, G5).n8.loop, in: 1/4r }"
    end
    # (omnibus15) CUE and launch on a synth track: a cued clip launched by
    # `launch` alone, or a playing part pre-listened, then launched (its
    # pre-listen ends)
    if !synths.empty? && rng.rand < 0.35
      t = pick(rng, synths)
      bar = rng.rand(1..bars)
      if rng.rand < 0.5
        lines << "at_bar(#{bar}) { cue :#{t}, seq(A4, C5).n8.loop }"
        lines << "at_bar(#{bar}, beat: 3) { launch }"
      else
        lines << "at_bar(#{bar}) { bg :#{t}, seq(A4, C5).n8.loop, on: :now; cue :#{t} }"
        lines << "at_bar(#{bar}, beat: 3) { launch :#{t} }"
      end
    end
    # A bus with sends and a master chain, new to the session partway
    # through (dropouts-2's warm-ups; drawn last, so every seed keeps the
    # song it made before)
    if rng.rand < 0.35
      lines << "bus(:fx) { |sig| sig.#{pick(rng, BUS_FX)} }"
      lines << "at_bar(#{rng.rand(1..bars)}, beat: 2) { feed :#{pick(rng, names)}, :fx, -12.db }"
    end
    lines << "at_bar(#{rng.rand(1..bars)}, beat: 3) { master { |m| m.softclip(0, 0.9) } }" if rng.rand < 0.25
    # (generative-g4) a flow that writes itself as it plays: a Markov chain
    # over the scenes (a weight sometimes the knob :busy, read at each
    # commit point), lengths drawn per occurrence, from a launch point
    # (drawn last, so every seed keeps the song it made before)
    if rng.rand < 0.3
      weight = -> { rng.rand < 0.25 ? 'knob(:busy)' : rng.rand(1..3).to_s }
      chain = scenes.map { |a| "#{a}: { #{scenes.map { |b| "#{b}: #{weight.()}" }.join(', ')} }" }.join(', ')
      lengths = scenes.map { |a| "#{a}: #{pick(rng, ['1', '1..2', '[1, 2.beats]', '2.beats'])}" }.join(', ')
      lines << "at_bar(#{rng.rand(1..bars)}#{rng.rand < 0.5 ? ', beat: 2' : ''}) { flow(seed: #{rng.rand(1..99)}, on: :beat) { generate markov(#{chain}, seed: #{rng.rand(1..99)}), #{lengths} } }"
    end
    # (omnibus16) a clipless part started inside a bar, then a seek back
    # before its start: it plays again from the sample holding its start
    # (it restarted at the buffer's start before; drawn last, so every
    # seed keeps the song it made before)
    if rng.rand < 0.25
      bar = rng.rand(1..bars)
      start = pick(rng, ['on: :now', 'in: 1/8r', 'on: :beat'])
      lines << "at_bar(#{bar}, beat: 2) { bg :held, #{pick(rng, HELD)}, #{start} }"
      lines << "at_bar(#{bar}, beat: 4) { seek #{pick(rng, ["#{bar}", "#{bar}, 2", "#{bar}, 2.25", "#{bar}, 2.999"])} }"
    end
    # (parity-1) a drum track playing a looping grid swapped to that grid
    # transformed (Kit transforms run per row; drawn last, so every seed
    # keeps the song it made before)
    kits = first_clips.select { |t, c| tracks[t] == :drums && c.start_with?('grid(') && c.end_with?('.loop') }.keys
    if !kits.empty? && rng.rand < 0.35
      t = pick(rng, kits)
      fx = pick(rng, KIT_TRANSFORMS)
      lines << "at_bar(#{rng.rand(1..bars)}, beat: 3) { swap :#{t}, #{first_clips[t]}.#{fx} }"
    end
    # (omnibus17) track levels (the strip's fader): set now, at a launch
    # point, or over a ramp, and from a scene value (drawn last, so every
    # seed keeps the song it made before)
    if rng.rand < 0.35
      t = pick(rng, names)
      value = pick(rng, ['-6.db', '0.25', '0', '2.db'])
      how = pick(rng, ['', ', over: 1/2r', ', over: 3.beats, on: :beat', ', on: :bar'])
      lines << "at_bar(#{rng.rand(1..bars)}, beat: #{rng.rand(2..beats)}) { level :#{t}, #{value}#{how} }"
      if rng.rand < 0.5
        lines << "scene :lv, #{t}: #{pick(rng, ['-12.db', '[0.5, over: 1/4r]'])}, others: :keep"
        lines << "at_bar(#{bars}, beat: 2) { go :lv }"
      end
    end
    # (omnibus17, Munro's M3) a drums track given a kit with new rows on a
    # launch point as a part ducked by its kick starts there: both graphs
    # queue, and the duck must read the new kit (drawn last, so every seed
    # keeps the song it made before)
    drums = tracks.select { |_, k| k == :drums }.keys
    if !drums.empty? && rng.rand < 0.3
      t = pick(rng, drums)
      on = pick(rng, ['on: :bar', 'on: :beat', 'in: 1/4r'])
      lines << "at_bar(#{rng.rand(1..bars)}, beat: 2) { bg :#{t}, grid(16, kick: 'x...x...', open_hat: '..x...x.').loop, #{on}; " \
               "bg :ducked, 0.2.constant.duck(:#{t}, only: :kick, amount: -12.db), #{on} }"
    end
    # (omnibus17, Munro's M5) a trigger track ducking a part, through full
    # scenes that don't name it (it keeps pumping) and sometimes `pump:
    # :off` (drawn last, so every seed keeps the song it made before)
    if rng.rand < 0.25
      lines << "sidechain :pump, grid(16, '#{pick(rng, ['x...x...x...x...', 'x..x..x.x..x..x.'])}').loop, on: :now"
      lines << "bg :pumped, 0.2.constant.duck(:pump, amount: -12.db), on: :now"
      lines << "scene :nopump, others: :keep, pump: :off" if rng.rand < 0.5
      lines << "at_bar(#{bars}, beat: 3) { go :nopump }" if lines.last.start_with?('scene :nopump')
    end
    # (omnibus17, Kez's K10) a bus chain through a Synth reading the bus
    # input, with a send turned up after the bus slept: lanes wake inside
    # buffers and read the input in windows (drawn last, so every seed
    # keeps the song it made before)
    if rng.rand < 0.2
      lines << "knob :tint, 0, range: 0..1"
      lines << "bus(:colour) { |sig| seq([E2, G2, B2], [C2, E2, G2]).n1.loop.synth(voices: 4) { |v| (sig * 0.01).resonate(:bar, v.freq, decay: 0.3) * v.gate.smooth(4.ms) } }"
      lines << "at_bar(1) { feed :#{pick(rng, names)}, :colour, :tint }"
      lines << "at_bar(#{rng.rand(1..bars)}, beat: #{rng.rand(2..beats)}) { turn :tint, 1 }"
    end
    Song.new(header: header, lines: lines, bars: bars)
  end

  # What a scheduled step of #generate can see: the RNG, the step's track
  # (+t+) and launch-point suffix (+on+, ', on: :now' or ''), the song's
  # scenes, swappable synth tracks, library-instrument tracks, whether the
  # knob :cut exists, the clip picker, and the count of `bg :xN` players.
  Step = Struct.new(:rng, :t, :on, :scenes, :swappable, :instruments, :knob, :clip_for, :bgs, keyword_init: true) do
    def pick(list) = SessionFuzz.pick(rng, list)
    def bg_name = "x#{self.bgs += 1}"
  end

  # The commands a scheduled step draws from (uniformly by index; a
  # command listed twice is drawn twice as often): each takes a Step and
  # returns the command's code, or nil to skip the step.  APPEND ONLY
  # (test-infra-1, 2026-10-30): branches add commands at the end, so merges
  # add lines instead of colliding over `when` numbers (two branches both
  # claimed `when 12` on 2026-10-29).  Adding a command changes which song
  # every seed makes (the draw is rng.rand(COMMANDS.length)), as a new
  # `when` did, so a spec keeping a found seed passes the list's length
  # when it was found (`generate(rng, commands: 15)`), or keeps the shrunk
  # song as a script.  The first 15 are the old `case rng.rand(15)` arms
  # in order: seeds 0-1999 made the same songs after the change to this
  # list.
  COMMANDS = [
    ->(s) { "go :#{s.pick(s.scenes)}#{s.on}" },
    *[->(s) {
      next if s.swappable.empty?

      t = s.pick(s.swappable)
      "swap :#{t}, #{s.clip_for.(t)}#{s.on}"
    }] * 2,
    ->(s) { "stop :#{s.t}#{[', fade: 1/4r', ', ring: true', ''][s.rng.rand(3)]}" },
    ->(s) { "mute :#{s.t}#{[', fade: 1/4r', ''][s.rng.rand(2)]}#{s.on}" },
    ->(s) { "unmute :#{s.t}#{s.on}" },
    ->(s) { s.rng.rand < 0.5 ? "solo :#{s.t}#{s.on}" : "solo#{s.on.sub(",", "")}" },
    ->(s) {
      if s.knob && s.rng.rand < 0.5
        "turn :cut, #{s.pick([300.0, 2500.0, 3800.0])}#{[', over: 1', ', over: 1/2r', ''][s.rng.rand(3)]}#{s.on}"
      else
        "turn :busy, #{s.pick([0.1, 0.4, 0.9])}#{[', over: 1', ', over: 1/2r', ''][s.rng.rand(3)]}#{s.on}"
      end
    },
    ->(s) { "bg :#{s.bg_name}, #{s.pick(TWEENS)}, on: :now" },
    ->(s) { "bg :#{s.bg_name}, #{s.pick(FREQ_CLIPS)}.freq * 0.001, on: :now" },
    ->(s) { "bg :#{s.bg_name}, tr808(#{s.pick(DRUMS)}) * 0.5#{s.on}" },
    ->(s) {
      # (the clip matrix: slot 0 is the first clip a scene gave it)
      next if s.swappable.empty?

      t = s.pick(s.swappable)
      s.rng.rand < 0.5 ? "launch :#{t}, 0#{s.on}" : "tweak :#{t}, #{s.pick(['transpose: 2', ':reverse', ':halftime'])}#{s.on}"
    },
    ->(s) {
      # (a library instrument track given another instrument: rebuilt at its launch point)
      next unless s.instruments

      "track :#{s.pick(s.instruments)}, #{s.pick(INSTRUMENTS)}"
    },
    ->(s) {
      # (tempo-maps-1: a ramp from where the tempo is, or a followed tempo LFO)
      if s.rng.rand < 0.75
        "bpm #{s.pick([90, 140, 180])}, over: #{s.pick(['1', '1/2r', '3.beats'])}#{[', curve: :smooth', ''][s.rng.rand(2)]}#{s.on}"
      else
        "bpm #{s.pick(['1.bars.lfo.at(100..140)', '2.beats.lfo.at(150..170)'])}"
      end
    },
    ->(s) { "bg :#{s.bg_name}, #{s.pick(MELODIC)}#{s.on}" },
    ->(s) {
      # (ui-scaffold-1: an instrument track's param knob turned, so a later
      # instrument change carries it instead of resetting it)
      next unless s.instruments

      "turn :\"#{s.pick(s.instruments)}/release\", #{s.pick([0.02, 0.3])}#{s.on}"
    },
    # (new commands go here, at the end)
  ].freeze

  # Kit transforms for #generate's kit swaps.
  KIT_TRANSFORMS = [
    'reverse', 'rotate(1.n16)', 'rotate(-1/8r)', 'shift(1.n8)', 'shift(-1/16r)', 'swing(0.6)', 'humanize(4.ms, velocity: 0.1)',
    'chance(0.7)', 'every(2)', 'ratchet(2)', 'ratchet(2, rate: 1.n32)', 'permute', 'quantize(8, amount: 0.5)',
  ].freeze

  # Clipless sounds for #generate's seeks across starts.
  HELD = ['0.05.constant', '0.05.constant.filter(:lowpass, cutoff: 800)', 'noise.at(0.02).lp4(600)'].freeze

  # Bus chains for #generate.
  BUS_FX = ['reverb(:room, mix: 1)', 'delay(1.n8, feedback: 0.3) * 0.5', 'lp4(900) * 0.7'].freeze

  # --- rendering ------------------------------------------------------

  # Renders +code+ for +bars+ bars in +buffer_size+-frame buffers; returns
  # the mix (one DFloat per channel).
  def render(code, bars, buffer_size: 800, plans: true, rebuilds: :inline, warm: false)
    plan = MB::Sound::Plan
    old = [plan.enabled, plan.precision, plan.rebuilds]
    MB::Sound::Session::Warming.always = warm
    plan.enabled = plans
    plan.precision = :fast
    plan.rebuilds = rebuilds
    MB::Sound.rewind
    MB::Sound.seed(1)
    out = MB::Sound::Sampler::CaptureOutput.new(channels: 2, buffer_size: buffer_size)
    err = StringIO.new
    old_err = $stderr
    $stderr = err # (see #warnings)
    begin
      MB::Sound.render(out, bars: bars, buffer_size: buffer_size, channels: 2, gain: 1, exact_lanes: true) { RecipeHelpers.eval_recipe(code) }
    ensure
      $stderr = old_err
    end
    @warnings = err.string.lines.reject { |l| EXPECTED_WARNINGS.any? { |re| l.match?(re) } }
    out.captured.map { |c| Numo::DFloat.cast(c) }
  ensure
    MB::Sound::Session::Warming.always = false
    plan.enabled, plan.precision, plan.rebuilds = old
    MB::Sound.rewind
  end

  # Warnings a generated song may cause on purpose (commands for players
  # a scene or a one-shot clip has already ended); anything else printed
  # during a render fails :runs.
  EXPECTED_WARNINGS = [
    /\ANo background player :\w+ is playing/,
    # (a scene giving a kick-ducked drums track a kit without a kick)
    /has no node named :kick for a sidechain/,
  ].freeze

  # Errors that make a generated song invalid rather than show a bug
  # (commands for players other commands ended first)
  INVALID = [/No background player :\w+ is playing or stopped/, /doesn't play any of the clips being replaced/].freeze

  # The unexpected lines the last #render printed to stderr.
  def warnings = @warnings || []

  def peak(mix) = mix.map { |c| c.length == 0 ? 0.0 : c.abs.max }.max || 0.0

  def compare(ref, got, tolerance:, label:, from: 0)
    return "#{label}: #{got.length} channels, expected #{ref.length}" if ref.length != got.length

    ref.zip(got).each_with_index do |(r, g), i|
      # (a render ending early, once every sound ended, stops at the end
      # of the buffer after the one where they ended: lengths may differ by
      # up to two 800-frame buffers of silence; seed 140: 131019 frames at
      # 367, 132000 at 800)
      n = [r.length, g.length].min
      longer = r.length > n ? r[n..] : (g.length > n ? g[n..] : nil)
      if longer && (longer.length > 1600 || longer.abs.max > tolerance)
        return "#{label}: channel #{i} has #{g.length} frames, expected #{r.length} (the extra frames peak at #{longer.abs.max})"
      end
      next if n <= from

      d = (r[from...n] - g[from...n]).abs
      worst = d.max
      next if worst <= tolerance

      idx = d.max_index
      first = d.gt(tolerance).where[0]
      return "#{label}: channel #{i} differs by #{worst} (tolerance #{tolerance}) first at frame #{from + first}, worst at #{from + idx} (#{g[from + idx]} vs #{r[from + idx]})"
    end
    nil
  end

  # The frame of bar +bar+, beat +beat+ at +bpm+ (4 or +beats+ beats a bar;
  # launches land on the floor sample of their time)
  def frame_of(bar, beat, bpm, beats)
    (Rational(((bar - 1) * beats + (beat - 1)) * 48000 * 60) / Rational(bpm.to_s)).floor
  end

  # The timeline-following parts launched by +song+: [line index, bar,
  # beat, sound code] for each `bg ..., on: :now` of a looping tween or a
  # looping clip's frequency.
  def timeline_parts(song)
    song.lines.each_with_index.filter_map do |l, i|
      m = l.match(/\Aat_bar\((\d+)(?:, beat: (\d+))?\) \{ bg :x\d+, (.*), on: :now \}\z/) or next
      sound = m[3]
      next unless TWEENS.any? { |t| sound.start_with?(t) } || FREQ_CLIPS.any? { |c| sound.start_with?("#{c}.freq") }

      [i, Integer(m[1]), Integer(m[2] || 1), sound]
    end
  end

  # Checks +relation+ for +song+: nil if it holds, :skip if it doesn't
  # apply (a KNOWN case, no timeline parts, a song :runs found an error
  # in), :invalid for a song with a generated user error (INVALID), else
  # a failure message.
  def check(relation, song)
    code = song.code
    return :skip if KNOWN.fetch(relation, []).any? { |re, _| code.match?(re) }
    return :skip if relation != :runs && @errors&.key?(code) # (reported by :runs)

    case relation
    when :runs
      begin
        render(code, song.bars)
        warnings.empty? ? nil : "Warning: #{warnings.first(3).join}"
      rescue StandardError, SystemStackError => e
        (@errors ||= {})[code] = true
        # (a generated user error: swapping a player a stop or scene
        # already ended; the song is skipped, not failed)
        return :invalid if INVALID.any? { |re| e.message.match?(re) }

        raise
      end
    when :buffer_size
      ref = render(code, song.bars)
      got = render(code, song.bars, buffer_size: 367)
      compare(ref, got, tolerance: 1e-4 * [peak(ref), 1e-2].max, label: '367-frame buffers vs 800')
    when :plan
      ref = render(code, song.bars, plans: false)
      got = render(code, song.bars)
      compare(ref, got, tolerance: 0, label: 'planned vs unplanned') ||
        compare(ref, render(code, song.bars, rebuilds: :next_span), tolerance: 0, label: 'planned with deferred rebuilds vs unplanned')
    when :warm
      compare(render(code, song.bars), render(code, song.bars, warm: true), tolerance: 0, label: 'warmed changes vs not')
    when :timeline
      parts = timeline_parts(song)
      return :skip if parts.empty?

      bpm = song.header.first[/\d+(\.\d+)?/]
      beats = song.header.any? { |l| l.start_with?('meter 3') } ? 3 : 4
      parts.each do |_, bar, beat, sound|
        launched = (song.header + ['bg :z, 0.constant', "at_bar(#{bar}#{beat == 1 ? '' : ", beat: #{beat}"}) { bg :p, #{sound}, on: :now }"]).join("\n")
        whole = (song.header + ["bg :p, #{sound}, on: :now"]).join("\n")
        a = render(launched, song.bars)
        b = render(whole, song.bars)
        problem = compare(b, a, tolerance: 1e-4 * [peak(b), 1e-2].max, label: "#{sound} launched at bar #{bar} beat #{beat} vs from bar 1", from: frame_of(bar, beat, bpm, beats))
        return problem if problem
      end
      nil
    end
  rescue StandardError, SystemStackError => e
    "#{e.class}: #{e.message.lines.first(3).join} (#{e.backtrace&.find { |l| l.include?('/lib/mb/') }&.sub(/.*\/lib\//, 'lib/')})"
  end

  # --- shrinking ------------------------------------------------------

  # The failure's kind, for shrinking: an error's class, or the relation
  # (the error's class and message with numbers and names blurred, so an
  # error a dropped definition causes isn't the same failure)
  def kind(message)
    return :mismatch unless message.match?(/\A[A-Z][\w:]*: /)

    message.lines.first.sub(/ \(lib\/.*/, '').gsub(/\d+(\.\d+)?/, 'N')
  end

  def shrink(song, relation, message, limit: 60)
    want = kind(message)
    tries = 0
    fails = ->(s) {
      tries += 1
      r = check(relation, s)
      r.is_a?(String) && kind(r) == want
    }
    loop do
      smaller = nil
      # Fewer bars first (each render gets cheaper), then lines from the end
      if song.bars > 1
        s = Song.new(header: song.header, lines: song.lines, bars: song.bars - 1)
        smaller = s if fails.(s)
      end
      unless smaller
        (song.lines.length - 1).downto(0) do |i|
          break if tries > limit

          s = Song.new(header: song.header, lines: song.lines.reject.with_index { |_, j| j == i }, bars: song.bars)
          next unless fails.(s)

          smaller = s
          break
        end
      end
      return song unless smaller && tries <= limit

      song = smaller
    end
  end

  # Generates the song for +seed+, checks every relation, and returns the
  # Failures (shrunk).
  def run_seed(seed, relations: RELATIONS, counts: Hash.new(0))
    song = generate(Random.new(seed))
    counts[:songs] += 1
    relations.filter_map do |rel|
      r = check(rel, song)
      if r.nil?
        counts[rel] += 1
        nil
      elsif r == :invalid
        counts[:invalid] += 1
        nil
      elsif r == :skip
        counts[:"#{rel}_skipped"] += 1
        nil
      else
        small = shrink(song, rel, r)
        Failure.new(seed: seed, relation: rel, song: small, message: check(rel, small), original: song.code)
      end
    end
  end
end
