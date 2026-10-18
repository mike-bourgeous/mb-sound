module MB
  module Sound
    class Arrangement
      # Patches are checked when they are stored (ux-r3 item 6; pattern F,
      # "fail at definition, not at first use"): #track, #scene, and #arm
      # build the patch once right away, so a mistake inside it shows at
      # the prompt that caused it, with the track's name and the line in
      # the patch, instead of in the messages pane bars later when a scene
      # or the live monitor first builds it.
      #
      # Every method that stores a Track or Scene calls #check_patch
      # (a guard spec walks this file's methods with Prism to keep it so).
      #
      # The check builds the patch in the Session's context with the
      # random state kept (a check draws no seeds the song would see) and
      # throws the graph away.  It needs something to build from: the
      # clip the track will play (a scene's value, the track's clip), else
      # PROBE, a one-note loop on C2 (MIDI 36, the GM kick, so drum kits
      # find a voice).  A patch written for another kind of
      # source (a Kit's methods on the probe clip, a kit with no kick)
      # can't be checked without one, so a NoMethodError whose receiver is
      # the probe itself, or a SourceMismatch, passes (it is checked again
      # with the real clip when a scene or `bg` gives it one).
      module PatchCheck
        # A patch failed to build: an ArgumentError naming the track, what
        # it was built from, and the line inside the patch.
        class PatchError < ArgumentError
          # The track's name.
          attr_reader :track

          # The exception the patch raised.
          attr_reader :original

          def initialize(message, track: nil, original: nil)
            super(message)
            @track = track
            @original = original
          end
        end

        # What a patch is built from when nothing better is known.
        def self.probe
          @probe ||= MB::Sound.seq(MB::Sound::C2).n4.loop.named(:patch_check)
        end

        # Builds +patch+ for track +name+ from +source+ (a clip, kit, or
        # live clip; PROBE if nil) and throws the graph away.  Returns true
        # if it built (or can't be checked without the right kind of
        # source), else reports the error (see #report_patch_error) and
        # returns nil: raised in scripts and specs, printed at the prompt
        # in live mode.  +what+ says what stored the patch, for the message
        # (e.g. "track :y", "scene :drop").
        def check_patch(name, patch, source = nil, what: "track #{name.inspect}")
          return true if patch.nil?
          probe = source.nil?
          source ||= PatchCheck.probe
          build_checked(name, patch, source, probe, what)
        end

        # The build of #check_patch (separate, so only the patch's own
        # errors are rescued).
        def build_checked(name, patch, source, probe, what)
          MB::Sound.keeping_random_state do
            Session.with_context(session: @session) do
              GraphNode::Mixer.with_ring(@session.ring || GraphNode::Mixer.ring_mode) { patch.call(source) }
            end
          end
          true
        rescue ScriptError, StandardError => e
          return true if probe && source_mismatch?(e, source)
          report_patch_error(patch_error(name, patch, source, e, what))
        end

        # True if +error+ (or an error that caused it) says the patch needs
        # another kind of source than +source+: a NoMethodError on the
        # source itself, or a SourceMismatch (a drum kit with no voice for
        # the test clip's note).
        def source_mismatch?(error, source)
          e = error
          8.times do
            return false if e.nil?
            return true if e.is_a?(SourceMismatch) || (e.is_a?(NoMethodError) && e.receiver.equal?(source))
            e = e.cause
          end
          false
        end

        # A PatchError for +error+ raised by +patch+.
        def patch_error(name, patch, source, error, what)
          where = patch_line(patch, error)
          from = source.equal?(PatchCheck.probe) ? 'a test clip' : (source.is_a?(Session::MidiInput::LiveClip) ? 'live MIDI' : name_of(source))
          PatchError.new(
            "#{what}: the patch raised #{error.class}: #{error.message.lines.first.to_s.chomp} " \
            "(#{where ? "at #{where}, " : ''}built from #{from}); nothing was changed",
            track: name, original: error
          ).tap { |pe| pe.set_backtrace(error.backtrace || []) }
        end

        # The first line of +error+'s backtrace in the file the patch was
        # written in ("(pry):3", "bin/songs/x.rb:40"), else where the patch
        # starts.
        def patch_line(patch, error)
          file, line = patch.source_location
          return nil unless file
          hit = (error.backtrace_locations || []).find { |l| l.path == file || l.absolute_path == file }
          short = file.start_with?("#{Dir.pwd}/") ? file.delete_prefix("#{Dir.pwd}/") : file
          "#{short}:#{hit ? hit.lineno : line}"
        rescue StandardError
          nil
        end

        # Prints +message+ as a warning in scripts and specs; in live mode
        # at the prompt and in the UI's messages (see #report_patch_error).
        def notice_patch_problem(message)
          return warn(message) unless MB::Sound.live?
          to_prompt(message)
        end

        # Raises +error+ in scripts and specs.  In live mode, prints it at
        # the prompt (so it shows in the console, or the tiled screen's
        # REPL pane) and records it in the UI's messages, and returns nil.
        def report_patch_error(error)
          @last_patch_error = error
          raise error unless MB::Sound.live?

          to_prompt("#{error.class.name.split('::').last}: #{error.message}")
        end

        private

        # Prints +text+ in red on the console (the tiled screen's REPL pane
        # when it is up) and adds it to the UI's messages.  Returns nil.
        def to_prompt(text)
          $stdout.puts "\e[31m#{text}\e[0m"
          $stdout.flush
          MB::Sound::UI.messages.add(text, severity: :error) if defined?(MB::Sound::UI) && MB::Sound::UI.respond_to?(:screen) && MB::Sound::UI.screen
          nil
        end
      end
    end
  end
end
