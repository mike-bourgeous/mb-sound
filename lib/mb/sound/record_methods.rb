require 'fileutils'

module MB
  module Sound
    # Console methods for recording a performance (see
    # design/notes/arrangement.md, Recording): MIDI into tracks (a looper,
    # `rec 4`, and Capture MIDI, `capture :lead`) and the master bus to an
    # audio file (`rec 'sets/take3.flac'`).  MB::Sound extends itself with
    # this module.
    #
    # Example (bin/sound.rb):
    #     track(:lead, q: 1) { |c| c.synth(voices: 4) { |v| v.hz.saw.lp4(1800) * v.amp_env } }
    #     arm :lead              # hear the keyboard through the lead's patch
    #     rec 4                  # the next 4 bars loop on :lead when they close
    #     capture :lead          # or: what you just played, from the next bar
    #     capture :lead, 2, quantize: 16      # the last 2 bars, on 16ths
    #     captures               # the clips recorded so far, by name
    #     rec 'sets/take3.flac'  # the master bus, from now; `rec` alone: a timestamped file
    #     stop_rec on: :bar
    module RecordMethods
      # Arms tracks: `rec` and `capture` without names record into them,
      # and each track's patch plays the live MIDI input (a monitor player
      # named "track/live") unless +monitor: false+.  +input:+ picks a
      # named MIDI input (see MidiMethods#midi; the default input
      # otherwise).  Returns the :arm journal entries.  Also available as
      # #arm_track.
      def arm(*names, monitor: true, input: nil)
        session = Session.current
        attach_session_midi(session, input)
        session.arrangement.arm(*names, monitor: monitor, input: input)
      end
      alias arm_track arm

      # Disarms tracks (every armed track if none are named) and stops
      # their monitors.  Also available as #disarm_track.
      def disarm(*names)
        Session.current.arrangement.disarm(*names)
      end
      alias disarm_track disarm

      # The armed tracks (a Hash from name to MIDI input name).  Also
      # available as #armed_tracks.
      def armed
        Session.current.arrangement.armed
      end
      alias armed_tracks armed

      # Records.  With a length (bars, or a Duration such as 4.bars), MIDI:
      # a loop of that length from the next launch point of each armed
      # track (or the tracks named after the length, or before it: `rec
      # :lead, 4`), which swaps into the track when it closes (see
      # Arrangement#record for +quantize:+, +humanize:+, +channel:+,
      # +sustain:+).  With a path (or nothing), audio: the master bus, from
      # the launch point (now by default) until #stop_rec, to that file or a
      # timestamped one in the take directory (Take#home, `sets/` with
      # +repo: true+, else the user data directory, as Take#save chooses).
      # Returns the journal entry.  Also available as #record.
      def rec(*args, at: nil, on: nil, in: nil, repo: false, overwrite: false, input: nil, quantize: nil, humanize: nil, channel: nil, sustain: true)
        point = LaunchPoint.of(binding) or return nil
        session = Session.current

        if args.empty? || args.first.is_a?(String)
          raise ArgumentError, "Audio recordings take one path (got #{args.inspect})" if args.length > 1
          return record_audio_file(session, args.first, point, repo: repo, overwrite: overwrite)
        end

        length = args.find { |a| a.is_a?(Numeric) || a.is_a?(Sequence::Duration) }
        names = args - [length]
        unless length && names.all?(Symbol)
          return MB::Sound.live_error(ArgumentError.new("rec takes a length in bars (rec 4, rec 4.bars, rec :lead, 4) or an audio path (got #{args.inspect})"))
        end

        attach_session_midi(session, input)
        session.arrangement.record(length, *names, at: point, input: input, quantize: quantize, humanize: humanize, channel: channel, sustain: sustain)
      end
      alias record rec

      # Stops recording the master bus (see #rec) at the launch point (now
      # by default).  Returns the journal entry.  Also available as
      # #stop_recording.
      def stop_rec(at: nil, on: nil, in: nil)
        point = LaunchPoint.of(binding) or return nil
        session = Session.current
        c = session.stop_recording(at: point, start_time: point.given? ? nil : schedule_time(session))
        session.journal[c.seq]
      end
      alias stop_recording stop_rec

      # Captures what was just played into tracks (the armed ones if none
      # are named): from the next launch point of each track the last
      # +length+ bars (or a Duration; by default the last phrase, see
      # Arrangement#capture) loop on it.  Options as in #rec.  Returns the
      # :capture journal entry.  Also available as #capture_midi.
      def capture(*names, length: nil, at: nil, on: nil, in: nil, input: nil, quantize: nil, humanize: nil, channel: nil, sustain: true)
        point = LaunchPoint.of(binding) or return nil
        number = names.find { |a| a.is_a?(Numeric) || a.is_a?(Sequence::Duration) }
        if number
          raise ArgumentError, 'Give the capture length once (capture :lead, 2 or length: 2)' if length
          length = number
          names -= [number]
        end

        session = Session.current
        attach_session_midi(session, input)
        session.arrangement.capture(*names, length: length, at: point, input: input, quantize: quantize, humanize: humanize, channel: channel, sustain: sustain)
      end
      alias capture_midi capture

      # The clips recorded by #rec and #capture (a Hash from name, like
      # :lead_1, to Sequence::Clip), to play elsewhere (`scene :verse,
      # lead: captures[:lead_2]`).  Also available as #recorded_clips.
      def captures
        Session.current.arrangement.captures
      end
      alias recorded_clips captures

      # The audio recordings of the master bus (see #rec), as text.
      def recordings
        Session.current.recordings.map(&:to_s)
      end

      private

      # Gives the session's MIDI input live input unless it replays a take
      # (see MidiMethods#attach_live_midi); warns if there is no MIDI input.
      def attach_session_midi(session, input)
        attach_live_midi(session, input)
      rescue => e
        warn "No live MIDI input (#{e.class}: #{e.message})"
      end

      # The scheduled block's time inside one (see Session::Changes#now).
      def schedule_time(session)
        context = Session.context
        context && context[:session].equal?(session) ? context[:time] : nil
      end

      def record_audio_file(session, path, point, repo:, overwrite:)
        path ||= File.join(Take.current.home || (repo ? File.expand_path('../../../sets', __dir__) : Take.data_dir), "rec_#{Time.now.strftime('%Y%m%d_%H%M%S')}.flac")
        path = File.expand_path(path)
        replay = Session.perform&.[](:source) == :replay
        unless replay
          FileUtils.mkdir_p(File.dirname(path))
          if File.exist?(path) && !overwrite
            return MB::Sound.live_error(ArgumentError.new("#{path} exists; pass overwrite: true to replace it"))
          end
        end

        c = session.record_audio(path, at: point, start_time: point.given? ? nil : schedule_time(session), overwrite: true)
        session.ensure_running
        entry = session.journal[c.seq]
        puts "Recording the master bus to \e[1m#{path}\e[0m (#{entry})" unless replay
        entry
      end
    end
  end
end
