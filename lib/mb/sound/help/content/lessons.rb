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
        type { track(:l_bass, q: 1) { |c| c.tone.saw.at(-10.db).lp4(500, resonance: 0.4) * c.amp_env } }
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

    # Levels: the init voice plays at full level (~22 dB over the level
    # tone), so each track gets a level first (lesson-fixes-1).
    Help.lesson :design, 'Designing a sound', minutes: 5 do
      about 'The init voice, its knobs, a build switch, and your own patch\'s numbers as knobs.'

      step 'A blank voice' do
        say <<~TEXT
          `design` opens a track for sound design: `ui :sound` on its voice,
          the inspector's keys live (s f a o x the sections, arrows turn), the
          track playing on MAIN.  A new track starts from the init voice: two
          oscillators that morph sine, triangle, square, saw, a mix, FM, AM,
          and sync (all off), a filter with its envelope, an ADSR, glide.
          It plays at full level, so set the track's level first.
        TEXT
        type do
          level :l_lead, -16.db
          design :l_lead, seq(A3, C4, E4, G4).n8.loop
        end
        check('a track :l_lead on the init voice') { tracks.key?(:l_lead) && knobs.key?(:"l_lead/wave1") }
      end

      step 'Turn its knobs' do
        say <<~TEXT
          Every number of the init voice is a knob of the track
          (:"l_lead/cutoff", :"l_lead/wave2", ...): the inspector's arrows
          turn them, and so does `turn`.  Here OSC2 becomes a sine and OSC1
          bends its frequency: a two-operator FM bell.
        TEXT
        type do
          turn :"l_lead/wave1", 0.0
          turn :"l_lead/wave2", 0.0
          turn :"l_lead/fm", 1.5, over: 1.bar
        end
        check('FM turned up') { Session.current.journal.changes.any? { |e| e.kind == :turn && e.subject == :"l_lead/fm" } }
      end

      step 'A build switch' do
        say <<~TEXT
          sync is read when the voice builds (off costs nothing), so turning
          it rebuilds the track at its launch point, carrying the running
          voices over: the notes play on.  Then sweep OSC2 up for the
          classic sync lead.
        TEXT
        type do
          turn :"l_lead/fm", 0.0
          turn :"l_lead/sync", 1
          turn :"l_lead/tune2", 12.0, over: 2.bars
        end
        check('sync turned on') { Session.current.journal.changes.any? { |e| e.kind == :turn && e.subject == :"l_lead/sync" } }
      end

      step 'Your own patch' do
        say <<~TEXT
          A patch of your own shows its numbers in the inspector, dim with a
          dot: an envelope's points here.
        TEXT
        type do
          track(:l_pad) { |c| c.synth(voices: 4) { |v| v.hz.saw.at(-12.db).lp4(900.hz) * v.env([[1, 0.02], [0.6, 0.3], [0, 0.6]], release_at: 2) } }
          level :l_pad, -12.db
          design :l_pad, seq([A3, C4, E4], [G3, B3, D4]).n2.loop
        end
        check('a track :l_pad playing') { tracks.key?(:l_pad) && players.key?(:l_pad) }
      end

      step 'A number becomes a knob' do
        say <<~TEXT
          `bind` makes one of them a knob (in the inspector: Enter, or the
          arrows, which bind it now and turn it): the second point's time.
          The patch rebuilds reading the knob, the same sound until you turn
          it.  `env: :t2_level` is its level, `curve: :release` a chained
          `.curve(release: 30)`.
        TEXT
        type do
          bind :l_pad, env: :t2
          turn :"l_pad/t2", 1.2, over: 2.bars
        end
        check('a knob :"l_pad/t2"') { knobs.key?(:"l_pad/t2") }
      end

      step 'Out' do
        say '`design off` puts your screen back.  Stop both parts when you like.'
        type do
          stop :l_lead, fade: 0
          stop :l_pad, fade: 0
        end
        check('the parts stopped') { !players.key?(:l_lead) && !players.key?(:l_pad) }
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
          record on a 165 BPM grid.  A chop remembers its slices, so
          `play @l_amen` or `bg :x, @l_amen` plays them too.
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
        type { knob :l_cut, (100.hz..8000.hz).at(400.hz) }
        check('a knob :l_cut') { knobs.key?(:l_cut) }
      end

      step 'Use it in a graph' do
        say '`knob(:l_cut)` reads the knob anywhere a node goes; every graph reading it hears the same frames.'
        type { bg :l_drone, 55.hz.saw.at(-14.db).lp4(knob(:l_cut), resonance: 0.5) }
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

    # The material is bin/songs/generative_steer.rb's (D phrygian: the
    # techno beat, the acid row, the phrygian motif).  Levels: library
    # instruments play at full level, so each track gets one first (the
    # beat's fill toms peak 6 dB over its bars).
    Help.lesson :generative, 'Generative music from the library', minutes: 7 do
      about 'L.gen generators on tracks: seeds, track knobs steering them, a key that moves, a form that decides itself, and your own saved.'
      needs :idle_set

      step 'A bass line from the library' do
        say <<~TEXT
          `L.gen` lists the library's generators (beats, bass lines,
          motifs, bells, pads; `L.gen.techno` the techno ones).  Each is a
          preset with params; a track given one plays the looping clip it
          builds, on the entry's own instrument: here an acid row walking
          D phrygian.  Its params that steer it become the track's knobs
          (`:"l_bass/energy"`), as an instrument's do.  Library instruments
          play loud, so set a level first.
        TEXT
        type do
          track :l_bass, L.gen.acid_rhythm
          level :l_bass, -18.db
          bg :l_bass
        end
        check('L.gen.acid_rhythm playing on :l_bass') {
          Session.current.playing_after_queue?(:l_bass) && Help.track_built(:l_bass)&.entry&.name == :acid_rhythm && Help.track_knobs(:l_bass).key?(:energy)
        }
      end

      step 'A beat' do
        say <<~TEXT
          `L.gen.techno_beat` evolves: an anchored kick and clap, drifting
          ghost snares, mutating Euclidean hats, a fill every 8 bars.  It
          plays on the TR-909 and joins at the next bar.
        TEXT
        type do
          track :l_drums, L.gen.techno_beat
          level :l_drums, -21.db
          bg :l_drums
        end
        check('L.gen.techno_beat playing on :l_drums') { Session.current.playing_after_queue?(:l_drums) && Help.track_built(:l_drums)&.entry&.name == :techno_beat }
      end

      step 'Seeds' do
        say <<~TEXT
          A generator draws each bar from its seed and the bar's number, so
          the same seed plays the same music every time (seeks and takes
          too), and another seed is a variation of the same recipe.  `bg`
          gives a track a new clip at its next bar.  Calls print back with
          their seed written out (a saved set shows the default as
          `L.gen.techno_beat(seed: 5)`), so a set knows which line it
          played.
        TEXT
        type { bg :l_drums, L.gen.techno_beat(seed: 3) }
        check('the beat at seed 3') { Help.track_built(:l_drums)&.kwargs&.[](:seed) == 3 }
      end

      step 'Knobs steer them' do
        say <<~TEXT
          Each track's generator params are its knobs, named after the
          track: `:"l_drums/energy"`, `:"l_bass/energy"` (`knobs` lists
          them, the inspector shows them on its notes row, MIDI learn and
          scenes take them).  A generator reads them once a bar just before
          it starts, so a turn steers the next bar: below 0.5 the parts
          thin out, above it they fill in (raising it only adds hits).  A
          call that gives one keeps it: `L.gen.techno_beat(energy: 0.8)`, or
          `energy: knob(:x)` for one knob over several parts.
        TEXT
        type do
          turn :"l_drums/energy", 0.9, over: 4.bars
          turn :"l_bass/energy", 0.3
        end
        check('turns of :"l_drums/energy" and :"l_bass/energy"') {
          %i[l_drums/energy l_bass/energy].all? { |k| Session.current.journal.changes.any? { |e| e.kind == :turn && e.subject == k } }
        }
      end

      step 'A lead on another instrument' do
        say <<~TEXT
          An instrument after the generator plays it on that one instead.
          `phrygian_motif` makes one-bar phrases that come back (a a b a,
          b answering a, mutating a step now and then), here on the tine
          piano.
        TEXT
        type do
          track :l_lead, L.gen.phrygian_motif, :tine_piano
          level :l_lead, -16.db
          bg :l_lead
        end
        check('L.gen.phrygian_motif playing on :l_lead') { Session.current.playing_after_queue?(:l_lead) && Help.track_built(:l_lead)&.entry&.name == :phrygian_motif }
      end

      step 'A key that moves' do
        say <<~TEXT
          Melodic generators draw their notes from a probability scale
          (`harmony:`); give them one that changes over time and they
          follow: D phrygian for four bars, then G phrygian.  The bass and
          the lead share it, so they move together; the energy they leave
          out stays the tracks' knob.
        TEXT
        type do
          @l_key = harmony(0 => scale(:phrygian, :d), 4.bars => scale(:phrygian, :g), curve: :step, loop: 8.bars)
          bg :l_bass, L.gen.acid_rhythm(harmony: @l_key)
          bg :l_lead, L.gen.phrygian_motif(harmony: @l_key)
        end
        check('the bass and the lead on @l_key') { %i[l_bass l_lead].all? { |t| Help.track_built(t)&.kwargs&.[](:harmony).is_a?(Generative::Harmony) } }
      end

      step 'A form that decides itself' do
        say <<~TEXT
          Scenes say what plays (knob values too, the tracks' generator
          knobs among them); a chain picks each next scene by weight and
          `flow` plays it, drawing each section's length.
          `L.flow` holds the genre templates' chains (`L.flow.techno_chain`),
          which play over scenes named like their sections; this one plays
          over yours.  `goto :l_hush` forces the next section, `loop!` stays.
        TEXT
        type do
          scene :l_dark, l_drums: :on, l_bass: :on, "l_drums/energy": 0.4
          scene :l_lift, l_drums: :on, l_bass: :on, l_lead: :on, "l_drums/energy": 0.9, "l_lead/density": 0.7
          scene :l_hush, l_bass: :on, l_lead: :on, "l_bass/energy": 0.2, "l_lead/density": 0.3
          @l_moods = markov(l_dark: { l_lift: 2, l_hush: 1 }, l_lift: { l_dark: 1, l_hush: 1 }, l_hush: { l_lift: 1 }, seed: 2)
          flow @l_moods, bars: { l_dark: 4, l_lift: [4, 8], l_hush: 2 }
        end
        check('a generated form playing') { (pb = Session.current.arrangement.playback) && !pb.ended? && pb.form.sections.key?(:l_lift) }
      end

      step 'Keep your own' do
        say <<~TEXT
          `save` keeps a generator call as an entry of your own
          (`L.gen.l_beat`), the params it leaves out kept as its params, so
          on a track they are knobs again (`:"l_drums/energy"`), and a
          chain with its lengths (`L.flow.l_moods`: `flow L.flow.l_moods`
          plays it over these scenes).  During a lesson saves go to the
          lesson's own shelf, not yours; save again afterwards to keep them.
        TEXT
        type do
          save :l_beat, L.gen.techno_beat(seed: 3)
          save :l_moods, @l_moods, bars: { l_dark: 4, l_lift: [4, 8], l_hush: 2 }
          bg :l_drums, L.gen.l_beat
        end
        check('your L.gen.l_beat on :l_drums, steered by :"l_drums/energy"') {
          Help.track_built(:l_drums)&.entry&.name == :l_beat && Help.track_knobs(:l_drums)[:energy]&.name == :"l_drums/energy" &&
            Library.index.lookup(:flow, :l_moods, note: false)
        }
      end

      step 'Let it end' do
        say <<~TEXT
          `finish` ends the form after this section, and the parts ring out.
          `help :generative` has the methods the generators are made of
          (`beats`, `motifs`, `strikes`); bin/songs/generative_steer.rb is
          this material as a song.
        TEXT
        type { finish }
        check('the form ending after this section') { (pb = Session.current.arrangement.playback) && (pb.ended? || pb.upcoming.section.nil?) }
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
