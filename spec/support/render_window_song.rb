# The small song of the render window specs (render_window_spec.rb,
# render_window_script_spec.rb).
module RenderWindowSong
  # A small song with a form at +bpm+: a held-note synth through an echo
  # (tails and held notes cross the section edges), a pick drawing from the
  # form's seed, and a 2/4 bar (a meter change) before the drop.
  def song(bpm: 168)
    MB::Sound.bpm bpm
    set = MB::Sound::Session.current.arrangement
    set.track(:lead) { |c| c.synth(voices: 2) { |v| v.hz.saw * v.env(0.01, 0.3, 0.5, 0.8) }.at(-12.db).delay(0.15, feedback: 0.6) }
    set.track(:hum) { |c| c.tone.triangle * c.amp_env * 0.2 }
    set.scene(:intro, lead: MB::Sound.seq(MB::Sound::C4, MB::Sound::E4).n4.loop, hum: MB::Sound.seq(MB::Sound::C3).n1.loop)
    set.scene(:gap, lead: MB::Sound.seq(MB::Sound::G4).n4.loop) { MB::Sound.meter 2, 4 }
    set.scene(:drop, lead: MB::Sound.seq(MB::Sound::A3, MB::Sound::C4, MB::Sound::E4).n8.loop, hum: MB::Sound.seq(MB::Sound::A2).n2.loop) { MB::Sound.meter 4, 4 }
    set.scene(:outro, lead: MB::Sound.seq(MB::Sound::G3).n2.loop)
    MB::Sound.flow(seed: 5, on: :now) do
      intro 2
      gap 1
      drop 2
      pick :drop, :intro
      outro 2
    end
  end

  def frame_of(pos, bpm: 168)
    (pos * 240 / bpm.to_r * 48000).floor
  end
end
