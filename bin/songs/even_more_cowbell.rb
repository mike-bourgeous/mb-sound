#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# Even more cowbell: a kit-builder kit that stacks every cowbell we can
# make over the scratch kick and snare (the Bench favourite): the 808's
# cowbell tuned to a little melody, an FM bell, a sampled cowbell (an 808
# cowbell bounced, crushed to 12 bits at 26 kHz, and played an octave
# down), and "fever", a cowbell whose one knob turns up the level and the
# ring together.  Each 2 bars add another one.
#
# Usage:
#     bin/songs/even_more_cowbell.rb                 # plays live in the background session
#     bin/songs/even_more_cowbell.rb cowbell.flac    # renders to a file instead (-f to overwrite)
#     bin/songs/even_more_cowbell.rb --fever 2       # I've got a fever
#     bin/songs/even_more_cowbell.rb --help          # all options
#
# Or in bin/sound.rb:
#     load 'bin/songs/even_more_cowbell.rb'
#     cb = MB::Sound.cowbell_kit
#     bg :cb, cb.kit(cb.grid(16, kick: 'X...x..x..x.x...', snare: '....X.......X...', fever: 'x.xx.x.xx.x.x.xx').loop, fever: { fever: 2 })
#
# Snippets to try in bin/sound.rb:
#     bg :bells, kit(grid(16, cb: 'x..x..x.x..x.x..').loop) { tr808 :cowbell }               # the 808's
#     bg :more, tr808(grid(16, cowbell: 'X.x.x.X..x.X.x..').loop, more_cowbell: 12)            # more_cowbell: in dB
#     bg :fm, kit(grid(16, cb: 'x.x.').loop) { voice(:cowbell, gm: 56) { |h| h.fm(800, ratio: 1.48, index: 1.2, index_decay: 0.05, decay: 0.35) } }

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The song's length in bars.
  EVEN_MORE_COWBELL_BARS = 12

  # A kit-builder kit (a Drums::Machine): the scratch kick and snare plus
  # four cowbells (see the file's header).
  def self.cowbell_kit
    # A sampled cowbell: the 808's, bounced and crushed like an SP-1200
    sampled = bounce(1.beat, bpm: 112) { tr808(grid(4, cowbell: 'X'), cowbell: { decay: 0.6 }) }.lofi(:sp1200)

    kit(name: :cowbell) {
      # The scratch kick and snare
      voice(:kick, tune: 48) { body(tune, decay: 0.6, sweep: 4).softclip(0.6) + click(0.4) }
      voice(:snare, snappy: 0.7) { body(190, decay: 0.1) * 0.5 + noise(decay: 0.2, highpass: 1500, lowpass: 9000) * snappy }

      # The 808's cowbell (its tune knob plays a melody in the song)
      tr808 :cowbell

      # An FM bell: inharmonic, bright at the strike
      voice :fm_bell, tune: 800, gm: 67, level: 0.45 do |h|
        h.fm(h.tune, ratio: 1.48, index: 1.2, index_decay: 0.05, decay: 0.35)
      end

      # The sampled one, an octave down (tune in semitones)
      voice :sampled, sampled, tune: -12, gm: 68, level: 0.8

      # Fever: the one knob turns up both the level and the ring
      voice :fever, fever: 1, gm: 58, level: 0.35 do |h|
        f = h.fever
        h.metal(540, freqs: [540.0, 800.0]).filter(:bandpass, cutoff: 2640, quality: 1.5) *
          h.mix(h.env(0.02) * 0.6, h.env(Drums.exp2(f - 1) * 0.42) * 0.4) * (2.2 * Drums.exp2(f - 1))
      end
    }
  end

  # Starts the song on the current session.  +fever+ is the last cowbell's
  # fever (1 normal, 2 twice the level and the ring).
  def self.even_more_cowbell(fever: 1.5)
    bpm 112
    cb = cowbell_kit
    melody = seq(540, 540, 600, 480).n2.loop

    rows = {
      kick:    'X...x..x..x.x...',
      snare:   '....X.......X...',
      cowbell: 'x..x..x.x..x.x..',
      fm_bell: '..x...x...x..x.x',
      sampled: 'x.......x.....x.',
      fever:   'x.xx.x.xx.x.x.xx',
    }
    play_rows = ->(names) {
      # (a new tune node per kit: the old kit stops reading when replaced)
      cb.kit(cb.grid(16, **rows.slice(*names)).loop, shuffle: 2, cowbell: { tune: melody.value }, fever: { fever: fever })
    }

    master_gain(-3.db)
    master { |mix| mix.softclip(0.7, 0.98) }

    bg :cowbells, play_rows.([:kick, :snare])
    at_bar(3) { swap_in(:cowbells, play_rows.([:kick, :snare, :cowbell])) }
    at_bar(5) { swap_in(:cowbells, play_rows.([:kick, :snare, :cowbell, :fm_bell])) }
    at_bar(7) { swap_in(:cowbells, play_rows.([:kick, :snare, :cowbell, :fm_bell, :sampled])) }
    at_bar(9) { swap_in(:cowbells, play_rows.(rows.keys)) }
    at_bar(11) { outro fade: 2 }
  end

  # Replaces player +name+'s kit with +kit+ (a new graph; cut, not faded).
  def self.swap_in(name, kit)
    bg name, kit, fade: 0
  end

  if main_script?(__FILE__)
    song_script(
      bars: EVEN_MORE_COWBELL_BARS,
      fever: [1.5, Float, '-F', 'Fever of the last cowbell (1 normal; 2 twice the level and ring)', 0.5..3.0],
    ) { |p| even_more_cowbell(fever: p.fever) }
  end
end
