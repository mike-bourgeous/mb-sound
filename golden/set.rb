# The golden set (design/notes/sound_guards.md): approved renders across the
# maintainer's genres, re-rendered by `bundle exec rake golden:check` and
# compared by perceptual fingerprints (golden/fingerprints/<name>.json).
# Each piece is a song script with its options (rendered as
# `ruby -Ilib SCRIPT -q -f -o OUT OPTIONS`) or a block returning a graph (a
# preset on a phrase, rendered for bars: at bpm:).  Keep pieces short (15-50
# s of audio): the whole set renders in a few minutes.
#
# No SQ-80 patches until the maintainer lifts the ban (2026-10-19).  The
# factory bank joins later, one piece per patch family.
#
# After adding or changing a piece: rake golden:approve[name] (and commit
# its fingerprint).
module MB::Sound
  SoundGuard.golden_set do
    # Ambient / generative
    piece :ambient, 'bin/songs/genre_demo.rb', '-G', 'ambient', '-s', '20',
      genre: :ambient, covers: 'genre template: modal bowls on clocks in seconds, rain and wind through a :weather bus, sounding, reverb'
    piece :generative, 'bin/songs/generative_blur.rb', '-b', '8',
      genre: :generative, covers: 'generators (seeded dice), blurred harmony, a granular cloud with weighted pitch draws'
    piece :chimes, 'bin/songs/wind_chimes.rb', '-b', '4',
      genre: :ambient, covers: 'dust, drift, modal resonators (textures)'

    # Cinematic
    piece :swarm, 'bin/songs/swarm_song.rb', '-b', '6',
      genre: :cinematic, covers: 'a Deep-Note-like swarm of gliding saws (unison swarm, curves), antialiased saws'

    # Lo-fi
    piece :press_chop, 'bin/songs/press_and_chop.rb', '-b', '8',
      genre: :lofi, covers: 'sampler: bounced presses, chops with pitch marks, lofi(:sp1200) edits, keymaps'

    # Industrial
    piece :grit, 'bin/songs/node_graph_grit.rb',
      genre: :industrial, covers: 'a bass under rising distortion (shapers, ADAA clip/softclip), filter pinging'

    # EDM
    piece :supersaw, 'bin/songs/unison_song.rb', '-b', '8',
      genre: :edm, covers: 'unison supersaw pad spread in stereo, detuned bass'

    # Dark techno
    piece :techno, 'bin/songs/genre_demo.rb', '-G', 'techno', '-s', '30',
      genre: :dark_techno, covers: 'genre template: tr909 kit, rumble and echo buses, sidechain ducking, mastering chain'

    # Electronica
    piece :wavetables, 'bin/songs/wavetable_song.rb', '-b', '8',
      genre: :electronica, covers: 'wavetable scan pad, sampled piano (sample mode), arp waveform changes, mipmaps'
    piece :feedback, 'bin/songs/feedback_song.rb', '-b', '8',
      genre: :electronica, covers: 'feedback loops: Karplus-Strong plucks, tape echo with saturation, flanger, TR-808 drums'

    # House
    piece :house, 'bin/songs/genre_demo.rb', '-G', 'house', '-s', '30',
      genre: :house, covers: 'genre template: house kit and bass, buses, pump, master chain'
    piece :vocal_club, 'bin/songs/vocal_lead_song.rb', '-b', '8', '--master', 'club',
      genre: :house, covers: 'formant filter + resonant lp4 + key-tracked decimator lead; the :club mastering preset (loudest-window targeting)'
    piece :drums909, 'bin/songs/drums_909.rb', '-b', '8',
      genre: :house, covers: 'TR-909 machine: analog kick/snare, ROM hats, shuffle, flams'

    # DnB / acid
    piece :tunnel_vision, 'bin/songs/tunnel_vision.rb', '-b', '16',
      genre: :dnb, covers: 'neuro DnB roller: reese, buses and sends, drum bus, master chain'
    piece :acid, 'bin/songs/acid_song.rb', '-b', '8',
      genre: :electronica, covers: 'diode ladder 303 voice, accents and slides (Seq#acid)'

    # Presets on a phrase (the factory bank's first members)
    piece :reese, bars: 4, bpm: 174,
      genre: :dnb, covers: 'preset :dnb_reese on a bass line (graph document load, unison, lp4)' do
      preset :dnb_reese, midi: seq(F1, F1, R, Ab1, F1, R, Eb1, C1).n8.loop
    end
    piece :tine_keys, bars: 4, bpm: 96,
      genre: :lofi, covers: 'preset :tine_piano (FM tine, pickup drive) on soft chords' do
      preset :tine_piano, midi: (seq(A3, F3, C4, G3).n2 & seq(C4, A3, E4, B3).n2 & seq(E4, C4, G4, D4).n2)
    end
  end
end
