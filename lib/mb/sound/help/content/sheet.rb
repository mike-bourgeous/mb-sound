# The one-screen sheet (`help`).  Each line is a block that is shown, not
# run; the guard spec checks every method it calls exists.  Names like
# `g`, `b`, `bass2` stand for your own graphs and clips.
module MB
  module Sound
    Help::Sheet.group :start do
      line('in the background') { bg :bass, g }
      line('4-bar fade; fade: 0 cuts') { stop :bass }
      line('all out / right now') { outro; panic }
      line('what plays') { now }
      line('master level') { master_gain(-6.db) }
    end

    Help::Sheet.group :sound do
      line { 110.hz.saw.lp4(800, resonance: 0.4) }
      line { 55.hz.unison(5, detune: 0.2) { |p| p.saw } }
      line('one-shot envelope') { env([[1, 0.01], [0, 1, 60]]) }
      line { g.delay(1.n8.dotted, feedback: 0.4) }
      line { stereo(l, r).reverb(:hall, mix: 0.3) }
      line { g.feedback { |fb, x| x + fb.delay(5.ms) * 0.8 } }
      line { g.compress.limit(ceiling: -1) }
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
      line { knob :cut, 800, range: 100..8000, curve: :exp }
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
      line { loudness 'x.flac' }
      line('explain a graph') { help g }
    end
  end
end
