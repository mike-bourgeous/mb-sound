# The one-screen sheet (`help`).  Each line is a block that is shown, not
# run; the guard spec checks every method it calls exists.  Names like
# `g`, `b`, `bass2` stand for your own graphs and clips.
module MB
  module Sound
    Help::Sheet.group :start do
      line('in the background') { bg :bass, g }
      line('4-bar fade; fade: 0 cuts') { stop :bass }
      line('all out / right now') { outro; panic }
      line('what plays; a set to explore') { now; demo }
      line('master level') { master_gain(-6.db) }
    end

    Help::Sheet.group :sound do
      line { 110.hz.saw.lp4(800, resonance: 0.4) }
      line { 55.hz.unison(5, detune: 0.2) { |p| p.saw } }
      line('one-shot envelope') { env([[1, 0.01], [0, 1, 60]]) }
      line { g.delay(1.n8.dotted, feedback: 0.4) }
      line { stereo(l, r).reverb(:hall, mix: 0.3) }
      line { g.feedback { |fb, x| x + fb.delay(5.ms) * 0.8 } }
      line { g.compress.limit(ceiling: -1.db) }
      line { tr808(grid(16, kick: 'x...x...').loop) }
    end

    Help::Sheet.group :time do
      line('clip in eighths') { seq(C4, E4, G4).n8.loop }
      line { bpm 128; meter 7, 8 }
      line('run at bar 9') { at_bar(9) { go :drop } }
      line { every(4) { turn :cut, 300 } }
      line('locks to the beat') { 1.beat.hz.lfo.triangle }
    end

    Help::Sheet.group :arrange do
      line('a patch for clips') { track(:bass, q: 1) { |c| c.tone.saw * c.amp_env } }
      line { scene :drop, bass: b, drums: beat }
      line('at its q; on:/in:/at:') { go :drop, at: bar(33) }
      line('clips, same graph') { swap :bass, bass2 }
      line { flow { intro 4; verse 8; goto :top; outro 8 } }
      line('at the next bar') { undo; redo! }
    end

    Help::Sheet.group :perform do
      line { knob :cut, (100.hz..8000.hz).at(800.hz) }
      line { turn :cut, 4000, over: 2.bars }
      line { snap :a; recall :a, over: 4.bars }
      line('next MIDI cc') { learn :cut }
      line { mute :pad, on: :bar, fade: 1; solo :bass }
      line('form controls') { loop!; onward; goto :top; finish }
      line { master { |mix| mix.squeeze.limit } }
    end

    Help::Sheet.group :keep do
      line('replay script') { take.save }
      line('MIDI into a track') { rec 4; capture :lead }
      line('the mix to a file') { rec_audio 'set.flac'; stop_rec_audio }
      line { render 'x.flac', g, bars: 8 }
      line('graph as Ruby') { ruby g }
      line { save :dark, g; preset :dark, mix: 0.6 }
    end

    Help::Sheet.group :look do
      line { plot g; spectrum g }
      line('the live mix') { vis }
      line('dashboard band') { ui; ui :deck; ui off }
      line { loudness 'x.flac' }
      line('explain a graph') { help g }
    end
  end
end

module MB
  module Sound
    module Help
      # What each section of the sheet is for (`help :start`, ...; the
      # section pages add the rest from the topics, lessons, and sheet).
      SECTIONS = {
        start: <<~TEXT,
          Everything plays in one background session.  `bg :name, graph` starts a
          player (by name, so `bg :name` again replaces it and `stop :name` fades it),
          `play` plays one thing in the foreground until it ends or Ctrl-C, and
          `outro` or `panic` end everything.

          Levels: oscillators are full scale, and the master bus is -10 dB, so a few
          parts mix with headroom; `help.level` sets a comfortable listening level.
        TEXT
        sound: <<~TEXT,
          Sounds are graphs of nodes built by chaining methods: a pitch makes a
          tone (`110.hz.saw`), and every node has filters, envelopes, effects,
          and arithmetic (`a * 0.5 + b`).  Drums, samplers, SoundFonts, wavetables,
          granular clouds, and the SQ-80 voice are nodes too.
        TEXT
        time: <<~TEXT,
          Time is bars and beats on the session's timeline: clips of notes
          (`seq`, `grid`), tempo and meter, blocks scheduled at bars, and
          tempo-locked LFOs and delays.  Lengths like `1.n8.dotted`, `2.bars`,
          and `250.ms` work wherever a length does.
        TEXT
        arrange: <<~TEXT,
          A set is tracks (named players with a patch for their clips), scenes
          (which clip each track plays), and a flow (the song's form).  Changes
          land on launch points (`on: :bar`, `in: 2.beats`, `at: bar(33)`),
          and `undo` takes the last one back at the next bar.
        TEXT
        perform: <<~TEXT,
          While it plays: knobs you turn (or move from MIDI controllers), mute and
          solo, master effects on the whole mix, and form controls that steer
          the flow live.
        TEXT
        keep: <<~TEXT,
          Keep what happened: the take (every line typed, replayable), MIDI
          recorded into tracks, the mix as an audio file, renders, graphs as
          Ruby, and presets to load later.
        TEXT
        look: <<~TEXT,
          See and measure: plots and spectra, the live scope (`vis`), the
          terminal UI (`ui`, `ui :tiles`, `keys`), loudness, and `help node`
          for what a graph is made of.
        TEXT
      }.freeze
    end
  end
end
