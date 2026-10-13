module MB
  module Sound
    # House (a stub from general knowledge, not from the persona panel):
    # four on the floor at 124 on the tr909.
    Genre.define :house, 'House (stub)' do
      about 'A stub from general knowledge (not researched by the panel): four on the floor, offbeat open hats, ' \
            'a bouncing bass, electric piano stabs, 16- and 32-bar phrases, on a TR-909.'
      tempo 124, range: 118..128
      meter 4, 4
      phrases 8, 16, 32
      key :minor, :a

      flow do
        fill :clap_roll, every: 16
        intro     16
        groove    16
        breakdown 16, fill: [:riser, 4]
        drop      32
        outro     16
      end

      four = 'X...X...X...X...'
      offbeat = '..6...6...6...6.'
      roll = { clap: grid(16, '....3.4.5.6.7.8X') }
      kit :intro, grid(16, kick: four, closed_hat: '5.3.5.3.5.3.5.3.').loop(align: :launch)
      kit :groove, grid(16, kick: four, clap: '....X.......X...', open_hat: offbeat, closed_hat: '5.3.5.3.5.3.5.3.').loop(align: :launch)
        .nofill(:clap, name: :clap_roll).fill(:clap_roll, **roll)
      kit :breakdown, grid(16, closed_hat: '..3...3...3...3.').loop(align: :launch)

      clip :bass, seq(R, A1, A2, R, R, A1, A2, R, R, A1, A2, R, R, G1, G2, R).n16.legato(0.6).loop(align: :launch)
      clip :chords, (0...3).map { |i| seq(*[[A3, C4, E4], [G3, B3, D4]].flat_map { |c| [R, c[i], R, R, R, c[i], R, R] }).n8 }.reduce(:&).loop(align: :launch)
      clip :bar, seq(R).n1.loop

      knob :cut, 8000, range: 200..12000, curve: :exp, unit: 'Hz'

      role :drums, :tr909, level: -4.db, about: 'the tr909, the house kit'
      role :bass, :funk_bass, about: 'an offbeat bass bouncing between octaves'
      role :keys, :tine_piano, filter: :cut, level: -4.db, about: 'electric piano stabs'
      role :riser, :riser, params: { bars: 4 }, fade: 1/8r, about: 'noise riser'

      scene :intro, drums: :intro
      scene :groove, drums: :groove, bass: :bass, keys: :chords, cut: [8000, { from: 800, over: 16 }]
      scene :breakdown, drums: :breakdown, keys: :chords, cut: 1500
      scene :drop, drums: :groove, bass: :bass, keys: :chords, cut: 8000
      scene :outro, drums: :intro, bass: :bass
      scene :riser, riser: :bar, others: :keep

      loudness(-10..-8)
      true_peak(-1.db)
      mono_below 120 # club systems
      master :compress, threshold: -14.db, ratio: 2, attack: 0.01, release: 0.12
      # (for the 909's peaky kick: more drive into a softclip, then the
      # limiter; drums-2 round 2, short form -8.9 LUFS)
      master :at, 9.db
      master :softclip, 0.45, 0.95
      master :limit, ceiling: -1.db
      master_gain 0.db

      tip 'A stub: tempo, form, and grids from general knowledge; a later panel should research and refine it.'
      tip 'Four on the floor, claps or snares on 2 and 4, open hats on the offbeats; the groove lives in the hats and the bass.'
      tip 'DJ structure: 16-32 bar intros and outros of drums, changes on 8- and 16-bar lines, a breakdown and a drop.'
    end
  end
end
