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
      # A fake MIDI input for #warm_up: each MIDI::Manager#update gets one
      # batch of events (a note on or off, and a mod wheel move), in the
      # format MIDI::Input#read returns.
      class WarmUpMIDI
        NOTES = [40, 47, 52, 45].freeze

        def initialize
          @reads = 0
        end

        def read(blocking: false)
          @reads += 1
          return [[]] if @reads.odd? # ends Manager#update's read loop

          step = @reads / 2
          note = NOTES[(step / 2) % NOTES.length]
          status = step.even? ? 0x90 : 0x80
          [[[0.0, [status, note, step.even? ? 100 : 0].pack('C*')], [0.0, [0xb0, 1, step % 128].pack('C*')]]]
        end

        def close
        end
      end

      # Runs a throwaway graph of common node types (band-limited and naive
      # oscillators, FM, pwm, arithmetic, Tees, filters, delay, envelopes,
      # shapers, procs, clip-driven voices) for +calls+ buffers of +buffer+
      # samples, so YJIT compiles their methods before live playback.  With
      # +midi: true+ (synth scripts), MIDI synth voices too (VoicePool and
      # MidiDsl nodes, as in bin/synths/fm_bass.rb; about 0.5 s more).  Does
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

        calls.times { graph.sample(buffer) }

        warm_up_midi(calls: [calls, 40].min, buffer: buffer) if midi

        Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      end

      private

      # MIDI synth voices (VoicePool, MidiDsl nodes), as in
      # bin/synths/fm_bass.rb, fed by a fake MIDI input that plays notes and
      # moves the mod wheel.  Voices are slow to run, and YJIT compiles a
      # method after about 30 calls, so they get fewer buffers.
      def warm_up_midi(calls:, buffer:)
        manager = MIDI::Manager.new(input: WarmUpMIDI.new, update_rate: 48000.0 / buffer)
        voices = synth(manager, osc_count: 2, parameter_map: false) { |midi|
          base = midi.number.smooth(0.1).freq
          mod = midi.cc(1, range: 1.0..2.0)
          (base.tone.complex_sine.at(1).pm(mod * base.tone.at(1)) * midi.env(0, 0.2, 0.5, 0.1)).real * 0.1
        }

        calls.times { voices.sample(buffer) }
      ensure
        manager&.close
      end
    end
  end
end
