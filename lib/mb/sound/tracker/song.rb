module MB
  module Sound
    module Tracker
      # A tracker module's file was malformed beyond reading (a missing
      # signature, a header pointing outside the file, an impossible
      # count).  Problems that leave the rest of the song playable (a
      # truncated sample, a pattern pointer past the end) are warnings
      # instead (Song#problems).
      class FormatError < ArgumentError; end

      # One pattern cell: +note+ (a neutral note number, 60 playing a
      # sample at its base rate, or :off for key off, :cut for note cut,
      # :fade for IT's note fade; nil for none), +instrument+ (1-based, or
      # nil), +volume+ (the volume column, raw per format; nil for none),
      # +effect+ (the format's effect number: MOD/XM 0-35, S3M/IT letters
      # A=1..Z=26, 669 0-7; nil for none) with its +param+ (0-255), and
      # +period+ (a MOD's raw Amiga period, nil elsewhere).
      Cell = Data.define(:note, :instrument, :volume, :effect, :param, :period) do
        def initialize(note: nil, instrument: nil, volume: nil, effect: nil, param: 0, period: nil)
          super
        end

        # True if the cell holds nothing.
        def empty?
          note.nil? && instrument.nil? && volume.nil? && effect.nil?
        end
      end

      # A pattern: +rows+, each an Array of Cells (or nil) per channel.
      Pattern = Data.define(:rows) do
        def length = rows.length
      end

      # A sampled sound: +name+, +data+ (an Array of Numo::SFloat channels,
      # -1..1), +rate+ (the playback rate in Hz at note 60: MOD/XM 8363 for
      # finetune 0, S3M's C2Spd, IT's C5Speed), +loop+ ([start, end) frames
      # or nil) with +loop_mode+ (:forward or :ping_pong), +sustain_loop+
      # and +sustain_mode+ (IT; nil elsewhere), +volume+ (0..64), +finetune+
      # (MOD -8..7 eighths of a semitone; XM -128..127 128ths), +relative_note+
      # (XM semitones), +pan+ (0..255, or nil for none), +global_volume+
      # (IT, 0..64), +vibrato+ (IT auto-vibrato [speed, depth, rate, type]
      # or nil), +bits+ (8 or 16).
      SampleData = Data.define(:name, :data, :rate, :loop, :loop_mode, :sustain_loop, :sustain_mode, :volume, :finetune, :relative_note,
                               :pan, :global_volume, :vibrato, :bits) do
        def initialize(name:, data:, rate: 8363.0, loop: nil, loop_mode: nil, sustain_loop: nil, sustain_mode: nil, volume: 64, finetune: 0,
                       relative_note: 0, pan: nil, global_volume: 64, vibrato: nil, bits: 8)
          super
        end

        # Frames of audio.
        def length
          data.empty? ? 0 : data[0].length
        end

        def empty?
          length == 0
        end
      end

      # An envelope (XM/IT): +points+ [[tick, value], ...] (values 0..64
      # for volume, -32..32 for pan and pitch), +sustain+ and +loop+
      # ([first point, last point] or nil), and whether it is +enabled+.
      # +filter+ marks an IT pitch envelope used as a filter (not played).
      Envelope = Data.define(:points, :sustain, :loop, :enabled, :filter) do
        def initialize(points:, sustain: nil, loop: nil, enabled: true, filter: false)
          super
        end
      end

      # An instrument (XM/IT): +keymap+ (120 entries of [sample index (0-based)
      # or nil, note]), envelopes, +fadeout+ (per tick, of 65536 (XM) /
      # 1024 (IT)), +vibrato+ (XM auto-vibrato [type, sweep, depth, rate]),
      # +nna+/+dct+/+dca+ (IT new note actions: 0 cut, 1 continue, 2 off,
      # 3 fade; duplicate check types and actions), +global_volume+ (IT
      # 0..128), +pan+ (IT default pan 0..64, or nil).
      Instrument = Data.define(:name, :keymap, :volume_envelope, :pan_envelope, :pitch_envelope, :fadeout, :vibrato, :nna, :dct, :dca,
                               :global_volume, :pan) do
        def initialize(name:, keymap:, volume_envelope: nil, pan_envelope: nil, pitch_envelope: nil, fadeout: 0, vibrato: nil, nna: 0, dct: 0,
                       dca: 0, global_volume: 128, pan: nil)
          super
        end
      end

      # A module in a format-neutral form (see Tracker): what the readers
      # make and Tracker::Player plays.
      #
      # +format+ (:mod, :"669", :s3m, :xm, :it), +title+, +channels+ (the
      # count), +pans+ (per channel, -1..1), +channel_volumes+ (per
      # channel, 0..64), +samples+ (SampleData, index 0 = instrument 1 in
      # sample formats), +instruments+ (Instruments for XM and IT's
      # instrument mode, else nil), +patterns+, +orders+ (pattern numbers;
      # S3M/IT's 254 marker entries removed), +restart+ (the order a
      # finished song loops to, or nil to end), +speed+ (ticks per row),
      # +tempo+ (BPM: ticks are 2.5 / tempo seconds), +global_volume+
      # (0..64 of the format's scale: IT 0..128 halved), +linear+ (XM/IT
      # linear frequency slides), +flags+ (a Hash of format details: 669
      # per-order :tempos and :breaks; IT :old_effects, :compat_gxx), and
      # +problems+ (Strings the reader warns with: truncated data and the
      # like).
      Song = Data.define(:format, :title, :channels, :pans, :channel_volumes, :samples, :instruments, :patterns, :orders, :restart, :speed,
                         :tempo, :global_volume, :linear, :flags, :problems, :tracker) do
        def initialize(format:, title:, channels:, samples:, patterns:, orders:, pans: nil, channel_volumes: nil, instruments: nil, restart: nil,
                       speed: 6, tempo: 125, global_volume: 64, linear: false, flags: {}, problems: [], tracker: nil)
          pans ||= Array.new(channels, 0.0)
          channel_volumes ||= Array.new(channels, 64)
          super
        end

        # True if notes pick XM/IT instruments (else samples directly).
        def instruments?
          !instruments.nil?
        end

        # A one-line summary.
        def to_s
          "#{format} #{title.inspect}: #{channels} channels, #{orders.length} orders, #{patterns.length} patterns, " \
            "#{samples.count { |s| !s.empty? }} samples#{", #{instruments.length} instruments" if instruments}"
        end

        def inspect
          "#<MB::Sound::Tracker::Song #{self}>"
        end
      end
    end
  end
end
