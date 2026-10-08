module MB
  module Sound
    # Warms up YJIT, Ruby's JIT compiler, before live playback.
    #
    # With YJIT on (bin/ scripts enable it in their shebang), a method is
    # compiled after it has been called a number of times.  Until then a
    # graph runs about 20% slower than without the JIT (fm_bass at 128-sample
    # buffers: ~5.5 ms per buffer for the first ~100 buffers, then ~3 ms
    # instead of ~4.5 ms without YJIT).  Those slow first buffers could make
    # a live output grow its queue (DeviceOutput never shrinks it), so live
    # playback first runs a throwaway graph of the common node types: YJIT
    # compiles per method, not per object, so this warms every graph that
    # uses them.  Renders don't need it.
    module WarmUpMethods
      # A fake MIDI input for #warm_up(midi: true), read through a
      # MIDI::LiveSource.
      class WarmUpMIDI
        NOTES = [40, 47, 52, 45].freeze

        def initialize
          @reads = 0
        end

        # For MIDI::LiveSource (RtMidi-style deltas in seconds): a note on or
        # off and a mod wheel move every other read.
        def read_raw
          @reads += 1
          return [] if @reads.odd?

          step = @reads / 2
          note = NOTES[(step / 2) % NOTES.length]
          status = step.even? ? 0x90 : 0x80
          [[0.01, [status, note, step.even? ? 100 : 0].pack('C*')], [0.001, [0xb0, 1, step % 128].pack('C*')]]
        end

        def frame_times?
          false
        end

        def frame_rate
          nil
        end

        def close
        end
      end

      # Runs a throwaway graph of common node types (band-limited and naive
      # oscillators, FM, pwm, arithmetic, Tees, filters, delay, envelopes,
      # shapers, procs, clip-driven voices) for +calls+ buffers of +buffer+
      # samples, so YJIT compiles their methods before live playback.  With
      # +midi: true+ (synth scripts), MIDI synth voices too: a
      # MIDI::LiveSource read through a Synth of Notes voices (envelopes,
      # cutoff, vibrato, glide, and an FM pair as in bin/synths/fm_bass.rb)
      # and a mono Notes voice.  Does
      # nothing (returns nil) without YJIT; otherwise returns the time taken
      # in seconds.
      #
      # Example (bin/sound.rb):
      #     warm_up
      #     warm_up(midi: true)
      def warm_up(calls: 200, buffer: 128, midi: false)
        return nil unless defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?

        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        lfo = 0.3.hz.lfo.at(0.2..0.8)
        osc = 110.hz.ramp.at(0.3) + 220.hz.pulse(lfo).at(0.2) + 330.hz.triangle.skew(0.3).at(0.2) +
          55.hz.sine.fm(110.hz.at(40)).at(0.3) + 165.hz.aramp.at(0.1) + 82.hz.sine.pm(164.hz.at(2)).at(0.2)
        env = osc * adsr(0.01, 0.1, 0.5, 0.2, hold: 1000)
        shaped = (env.softclip + env.clip(-0.5, 0.5) + env.abs * 0.1 + env.quantize(0.01)) * lfo
        # Clip-driven voices, as in songs
        notes = seq(Note.new(48), Note.new(55), nil, Note.new(60)).n16.loop
        voice = notes.tone.ramp.at(0.5).filter(:lowpass, cutoff: 150 + 1200 * notes.env(0.001, 0.1, 0.1, 0.05), quality: 4) *
          notes.env(0.003, 0.15, 0.6, 0.08)

        graph = (shaped + voice).filter(:lowpass, cutoff: 2000, quality: 0.7)
          .delay(0.005, feedback: -12.db, dry: 1, wet: 0.5)
          .proc { |buf| buf }

        Plan.install(graph)
        calls.times { graph.sample(buffer) }
        warm_up_plans(buffer)

        warm_up_notes(calls: [calls, 60].min, buffer: buffer) if midi

        Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      end

      private

      # Builds and compiles a fused plan (see Plan) again and again, so
      # the planner's Ruby is compiled before a live graph's first block
      # plans its regions (cold, that took about 10 ms per Synth lane).
      def warm_up_plans(buffer)
        return unless Plan.enabled

        trig = Notes.new(seq(Note.new(48), Note.new(55)).n16.loop).trigger
        lfo = 0.2.hz.triangle.lfo.at(-20..-6)
        graph = (220.hz.complex_sine.pm(110.hz.sine.reset(trig) * 0.7.hz.lfo.at(0..2)).real * (10 ** (lfo / 20)) +
          330.hz.ramp.reset(trig).at(0.2) - 0.5.constant * 165.hz.square.pwm(0.3)) * 0.5
        inst = Plan.install(graph)
        return unless inst

        40.times do
          inst.rebuild
          graph.sample(buffer)
        end
        inst.uninstall
      end

      # The MIDI path: a LiveSource on a fake input (live MIDI timing), a
      # Synth whose Notes voices use the common helpers (key-synced tones,
      # envelopes with GM scaling, cutoff and quality, vibrato from the mod
      # wheel, glide, and FM operators as in the FM synth scripts), and a
      # mono Notes voice on the same stream.
      def warm_up_notes(calls:, buffer:)
        stream = MIDI::Stream.new(MIDI::LiveSource.new(WarmUpMIDI.new))
        synth = Synth.new(stream, voices: 2, spares: 1, seed: 1) { |v|
          pitch = v.hz.glide(50.ms)
          op = pitch.transpose(1.oct).tone.complex_sine.at(1) * v.fm_env(0, 0.2, 0, 0.1)
          fm = (pitch.tone.complex_sine.at(1).pm(op * v.mod) * v.amp_env(0, 0.3, 0.5, 0.1)).real * 0.1
          v.hz.vibrato.saw.filter(:lowpass, cutoff: v.cutoff(600), quality: v.quality(2)) * v.amp_env(0.005, 0.1, 0.6, 0.05) + fm
        }
        mono = Notes.new(stream)
        graph = synth + mono.hz.square.at(0.1) * mono.env(0.01, 0.1, 0.5, 0.05) * mono.mod

        calls.times { graph.sample(buffer) }
      end
    end
  end
end
