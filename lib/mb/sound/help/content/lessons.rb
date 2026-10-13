# Lessons (`lesson`, `lesson :set`): short, for someone who knows Ruby and
# synthesis but not the newest console layers.  Every step's code is a block
# that the guard spec runs in order, then checks (each check must fail
# before its code and pass after), so a lesson that drifts from the API
# fails a spec instead of confusing a reader.  Names (tracks, scenes,
# sections, knobs, players) start with l_ so a lesson never changes your own
# song; lessons that launch scenes or forms (needs :idle_set) refuse to
# start over a playing form or scene (see Help::Lesson#busy).  Levels follow the topics' (tones at
# about -20 dB before the master bus), which the monitor trim (help.level)
# brings to the listening level.
#
# The full vimtutor-style tutorial these grow into is designed in
# design/notes/help_tutorial.md.
module MB
  module Sound
    Help.lesson :set, 'A set in five minutes', minutes: 5 do
      about 'Tracks, scenes, launch points, undo, and the take.'
      needs :idle_set

      step 'A track' do
        say <<~TEXT
          A track is a named player that remembers its patch (a block from a
          clip to a graph) and its launch quantization q: (bars).
        TEXT
        type { track(:l_bass, q: 1) { |c| c.tone.ramp.at(-10.db).lp4(500, resonance: 0.4) * c.amp_env } }
        check('a track named :l_bass') { tracks.key?(:l_bass) }
      end

      step 'Two scenes' do
        say <<~TEXT
          A scene is the state of every track.  Values are clips (played
          through the track's patch), :on for a track with a graph, or
          nothing (stopped, with others: :stop by default).
        TEXT
        type do
          scene :l_verse, l_bass: seq(A1, rest, A1, A2, rest, A1, G1, E1).n8.loop
          scene :l_lift, l_bass: seq(F1, rest, F1, F2, rest, F1, G1, C2).n8.loop
        end
        check('scenes :l_verse and :l_lift') { scenes.key?(:l_verse) && scenes.key?(:l_lift) }
      end

      step 'Launch' do
        say <<~TEXT
          `go` lands at each track's q: (the next bar here) and returns a
          journal entry saying where.  `on:`, `in:`, and `at: bar(n)` move it.
        TEXT
        type { go :l_verse }
        check('the :l_verse scene launched') { Session.current.arrangement.current_scene == :l_verse }
      end

      step 'Launch points' do
        say 'Queue the next scene two bars from now; `now` shows it waiting.'
        type { go :l_lift, in: 2.bars }
        check('a launch of :l_lift') { Session.current.arrangement.current_scene == :l_lift }
      end

      step 'Undo' do
        say <<~TEXT
          Every command is one undo step.  A change that hasn't landed is
          cancelled; one that has is undone at the next bar (`on: :now` for
          right away).  `changes` lists the steps.
        TEXT
        type { undo }
        check('the queued launch cancelled') { Session.current.journal.changes.none? { |e| e.status == :queued && e.to_s.include?('l_lift') } }
      end

      step 'Out' do
        say 'Ring it out.  `take.save` would write a script replaying all of this exactly.'
        type { stop :l_bass, fade: 1 }
        check(':l_bass fading out') { !players.key?(:l_bass) || players[:l_bass].to_s.match?(/fad|stop/) }
      end
    end

    Help.lesson :chop, 'Chopping a break', minutes: 4 do
      about 'Press a record, cut it into slices, and play a chop pattern from it.'

      step 'Press a record' do
        say <<~TEXT
          `bounce` renders any graph into a Sample offline, at its own tempo
          (the session's stays put).  This is a two-bar funk break played a
          little slow, the way records were sampled at 33 and pitched up.
        TEXT
        type {
          @l_rec = bounce(2.bars, bpm: 138.75) {
            tr808(grid(16, kick: 'X.....x...X.....|X.x.......X..x..', snare: '....X..3.3..X..3|.3..X..3....X.3.', hat: 'x.x.x.x.x.xxx.x.|x.x.x.x.x.x.x.xx'))
          }
        }
        check('a two-bar Sample in @l_rec') { @l_rec.is_a?(Sample) && @l_rec.bpm == 138.75 }
      end

      step 'Cut it into slices' do
        say <<~TEXT
          `slices(32)` cuts it into 32nd notes; `name` names runs of them (a
          kick is two slices long here).  `slices(:onsets)` would cut at the
          hits instead.
        TEXT
        type { @l_brk = @l_rec.slices(32).name(k: 0..1, h: 2..3, s: 4..5, g: 7) }
        check('32 slices with names in @l_brk') { @l_brk.is_a?(Sample::Slices) && @l_brk.names.key?(:s) }
      end

      step 'Write a chop' do
        say <<~TEXT
          A chop is a clip of slices, a sixteenth each: names or numbers,
          T (tie) to hold, R (rest), [:s, 2] for a slice two semitones up,
          and slices themselves (`@l_brk[:s].rev` plays backwards).  Each
          hit is a key (the slices sit on keys from C2) with a pitch mark,
          so transposing the clip pitches the hits, not the slices.
        TEXT
        type { @l_amen = @l_brk.chop(:k, T, :h, :g, :s, T, [:g, 2], :k, T, :k, :h, T, :s, T, [:s, 3], @l_brk[:s].rev).loop }
        check('a chop clip in @l_amen') { @l_amen.is_a?(Sequence::Clip) && @l_amen.events.length == 11 && @l_amen.events.all?(&:pitch) }
      end

      step 'Play it' do
        say <<~TEXT
          `clip.sampler(slices)` plays it on one voice, each hit cutting the
          last (with a 1 ms declick).  Three semitones up puts the 138.75 BPM
          record on a 165 BPM grid.
        TEXT
        type { bg :l_breaks, @l_amen.transpose(3).sampler(@l_brk).at(-14.db) }
        check('a player :l_breaks') { players.key?(:l_breaks) }
      end

      step 'Out' do
        say 'Fade it out.  `help :sampler` has more: lofi, loops, SFZ, capture.'
        type { stop :l_breaks, fade: 1 }
        check(':l_breaks fading out') { !players.key?(:l_breaks) || players[:l_breaks].to_s.match?(/fad|stop/) }
      end
    end

    Help.lesson :knobs, 'Knobs you can turn', minutes: 4 do
      about 'Knobs in graphs, turns with ramps and launch points, snapshots.'

      step 'Make a knob' do
        say 'A knob is a named value with a range and a curve (:exp suits frequencies).'
        type { knob :l_cut, 400, range: 100..8000, curve: :exp, unit: 'Hz' }
        check('a knob :l_cut') { knobs.key?(:l_cut) }
      end

      step 'Use it in a graph' do
        say '`knob(:l_cut)` reads the knob anywhere a node goes; every graph reading it hears the same frames.'
        type { bg :l_drone, 55.hz.ramp.at(-14.db).lp4(knob(:l_cut), resonance: 0.5) }
        check('a player :l_drone') { players.key?(:l_drone) }
      end

      step 'Turn it' do
        say 'Right away (with a 5 ms glide), or over: a length, shaped by curve:, at a launch point.'
        type { turn :l_cut, 3000, over: 2.bars, on: :bar }
        check('a turn of :l_cut') { Session.current.journal.changes.any? { |e| e.kind == :turn && e.subject == :l_cut } }
      end

      step 'Snapshots' do
        say 'snap remembers every knob; recall turns them back (over: works here too).'
        type do
          snap :l_bright
          turn :l_cut, 300
          recall :l_bright, over: 1.bar
        end
        check('a snapshot :l_bright') { snaps.key?(:l_bright) }
      end

      step 'Done' do
        say '`learn :l_cut` binds the next MIDI controller you move.  Stop the drone when you like.'
        type { stop :l_drone, fade: 0 }
        check('the drone stopped') { !players.key?(:l_drone) }
      end
    end

    Help.lesson :flow, 'Song forms', minutes: 6 do
      about 'A form over scenes: labels, gotos, and steering it live.'
      needs :idle_set

      step 'Scenes for sections' do
        say 'Sections play the scenes of the same name.'
        type do
          track(:l_lead, q: 1) { |c| c.tone.triangle.at(-12.db) * c.amp_env }
          scene :l_intro, l_lead: seq(A4, E4).n4.loop
          scene :l_verse, l_lead: seq(A4, C5, E5, C5).n8.loop
          scene :l_outro, l_lead: seq(A4).n2.loop
        end
        check('scenes :l_intro, :l_verse, :l_outro') { %i[l_intro l_verse l_outro].all? { |s| scenes.key?(s) } }
      end

      step 'A form' do
        say <<~TEXT
          What follows a section belongs to the flow: label, goto (with
          times:), pick.  The block is real Ruby; each section name becomes a
          method of the builder the first time it is used.
        TEXT
        type do
          flow do
            l_intro 1
            label :top
            l_verse 2
            goto :top, times: 1
            l_outro 1
          end
        end
        check('the form playing') { flow && !flow.ended? && flow.form.sections.key?(:l_verse) }
      end

      step 'Steer it' do
        say '`loop!` stays in the current section, `onward` moves on, `finish` jumps to the end.'
        type { loop! }
        check('the form looping') { flow&.looping? }
      end

      step 'Let it end' do
        say '`finish` plays the outro next; the form ends after it.'
        type do
          onward
          finish
        end
        check('the form finishing') { !flow&.looping? }
      end
    end

    Help.lesson :record, 'Recording', minutes: 5 do
      about 'MIDI into tracks (a looper and Capture MIDI) and the mix to a file.'
      needs :midi

      step 'Arm a track' do
        say <<~TEXT
          An armed track plays your MIDI keyboard through its patch (a
          monitor player named "l_keys/live") and is where recordings go.
          Play a few notes once it is armed.
        TEXT
        type do
          track(:l_keys, q: 1) { |c| c.synth(voices: 4) { |v| v.hz.triangle.at(-12.db) * v.amp_env } }
          arm :l_keys
        end
        check('the track :l_keys armed') { armed.key?(:l_keys) }
      end

      step 'Loop a few bars' do
        say <<~TEXT
          `rec 2` records the next two bars from the track's launch point,
          then the loop swaps in and plays on the track when it closes.
          Play something now.
        TEXT
        type { rec 2 }
        check('a recording queued on :l_keys') { Session.current.journal.changes.any? { |e| e.kind == :rec && e.subject == :l_keys } }
      end

      step 'Capture what you played' do
        say <<~TEXT
          Played something good before you pressed record?  `capture` keeps
          the last phrase (or `capture :l_keys, 2` for two bars), quantized
          if you like (`quantize: 16`).  `captures` lists every clip so far.
        TEXT
        type { capture :l_keys, 1 }
        # (a capture this step queued: the rec above adds to captures by
        # itself when it closes, and a capture with nothing played queues
        # nothing)
        start { Session.current.journal.changes.map(&:seq).max || 0 }
        check('a capture queued on :l_keys') { |before|
          Session.current.journal.changes.any? { |e| e.kind == :capture && e.subject == :l_keys && e.seq > before && !%i[failed cancelled].include?(e.status) }
        }
      end

      step 'Record the mix' do
        say <<~TEXT
          `rec_audio` writes the master bus to a file from a launch point
          until `stop_rec_audio`; with no path it makes a timestamped file
          next to your takes (during a lesson, in the help folder).
          `recordings` lists them.
        TEXT
        type { rec_audio }
        check('the mix recording') { Session.current.journal.changes.any? { |e| e.kind == :record && e.subject == :audio } }
      end

      step 'Wrap up' do
        say 'Stop the file, disarm, and `take.save` writes a script replaying the whole session, MIDI included.'
        type do
          stop_rec_audio
          disarm
        end
        check('nothing armed') { armed.empty? }
      end
    end
  end
end
