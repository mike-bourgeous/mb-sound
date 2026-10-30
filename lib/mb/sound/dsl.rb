require_relative '../sound'

module MB
  module Sound
    # The console's command surface at the top level of a plain Ruby file:
    #
    #     require 'mb/sound/dsl'     # (or require 'mb-sound/dsl')
    #
    #     bpm 124
    #     bass = seq(A1, R, A1, C2, R, E2, D2, R).n8.repeat(4)
    #     bg :bass, bass.synth(voices: 1) { |v| v.hz.saw.lp4(v.cutoff(900)) * v.amp_env }.at(-6.db)
    #     bg :hat, grid(16, 'x.x.x.x.x.x.x.xx').repeat(4)
    #
    # (`ruby song.rb` plays it and ends after the four bars ring out.)
    #
    # bin/sound.rb evaluates in MB::Sound, so every MB::Sound method and
    # constant is in reach there.  Requiring this file gives the requiring
    # program's top level the same, without changing Object for every
    # library:
    #
    # - Methods: Ruby's top-level object (`main`) is extended with this
    #   module, which forwards each public command of MB::Sound (the
    #   *Methods modules MB::Sound extends) to MB::Sound, so commands keep
    #   their state on MB::Sound exactly as in the console.  Forwarders are
    #   generated when this file loads; commands added later (console help
    #   loads HelpMethods on first use) are forwarded through
    #   #method_missing, which then defines their forwarders.  Only `main`
    #   gets them: methods of other objects and classes see nothing new.
    # - Constants: a constant missing at the top level (lexical scope
    #   Object) resolves to the Note of that name (C4, Ab3) or to the
    #   MB::Sound constant (R, T, Session, Sequence), the way they resolve
    #   inside `module MB::Sound`.  Lookups inside other classes and modules
    #   raise NameError as before.  (`Object.const_get(:C4)` also resolves,
    #   since Ruby can't tell it from a top-level lookup.)
    # - The end of the program: when the file's code finishes normally
    #   while the background Session still has something playing or queued
    #   (`bg`, `track`, `start`), the program waits for it to end, as
    #   PlaybackMethods#wait at the end of a script does (tails included).
    #   An explicit `wait` at the end still works (nothing is left to wait
    #   for afterwards); an exception, `exit`, or Ctrl-C ends the program
    #   right away.  `MB::Sound::DSL.wait_at_exit = false` turns it off.
    #
    # Scripts keep their rules: errors raise (MB::Sound.live is false, as in
    # bin/ scripts; see LiveMethods), and the script helpers
    # (`song_script`, `synth_script`, ...) work at the top level too.
    # See design/notes/scripts.md.
    module DSL
      @wait_at_exit = true

      class << self
        # True (default) to wait for background playback when the program
        # ends normally (see DSL).
        attr_accessor :wait_at_exit

        # The MB::Sound commands this module forwards: public singleton
        # methods from MB::Sound's own modules (not Module's or Object's),
        # excluding setters (a top-level `x = 1` is a local variable) and
        # const_missing.
        def commands
          MB::Sound.singleton_class.ancestors
            .take_while { |m| m != Module }
            .select { |m| m.name.nil? || m.name.start_with?('MB::') || m == MB::Sound.singleton_class }
            .flat_map { |m| m.public_instance_methods(false) }
            .uniq
            .reject { |name| name.end_with?('=') || name == :const_missing }
        end

        # Defines forwarders for every command that doesn't have one yet.
        # Returns the names defined.
        def refresh!
          added = commands - instance_methods(false) - private_instance_methods(false)
          added.each { |name| define_forwarder(name) }
          added
        end

        # Defines the forwarder for +name+ (`def name(...) =
        # MB::Sound.name(...)`, so arguments, keywords, and blocks pass
        # through untouched).
        def define_forwarder(name)
          raise ArgumentError, "Not a command name: #{name.inspect}" unless name.match?(/\A[a-z_][A-Za-z0-9_]*[?!]?\z/)

          module_eval("def #{name}(...) = ::MB::Sound.#{name}(...)", __FILE__, __LINE__)
        end

        # Extends Ruby's top-level object with this module and installs the
        # top-level constant lookup and the end-of-program wait (see DSL).
        # Called when this file loads; returns the top-level object.
        def install!
          refresh!
          main = TOPLEVEL_BINDING.receiver
          main.extend(self)
          Object.singleton_class.prepend(Constants) unless Object.singleton_class.include?(Constants)
          ExitClose.register(ExitWait, first: true)
          main
        end

        # True if the top-level constant +name+ comes from MB::Sound (see
        # Constants).
        def constant?(name)
          (defined?(MB::Sound::Note) && name != :Note && MB::Sound::Note.name?(name)) ||
            MB::Sound.const_defined?(name, false)
        end
      end

      # Prepended to Object's singleton class: top-level lookups of Note
      # names and MB::Sound constants (see DSL).
      module Constants
        def const_missing(name)
          return super unless equal?(Object) && MB::Sound::DSL.constant?(name)

          MB::Sound.const_get(name)
        end
      end

      # Closed first at exit (see ExitClose.register's +:first+): waits for
      # the background Session while it plays, unless an exception (exit,
      # Ctrl-C) is ending the program.
      module ExitWait
        # Waits for background playback to end (see DSL).  Returns true if
        # it waited.
        def self.close
          return false unless MB::Sound::DSL.wait_at_exit && $!.nil?

          session = Session.existing
          return false unless session&.running? && (!session.idle? || session.schedule_due?)

          MB::Sound.wait
          true
        rescue Interrupt
          false
        end
      end

      # Commands added to MB::Sound after this file loaded (HelpMethods)
      # get their forwarders on first use.
      def method_missing(name, *args, **kwargs, &block)
        return super unless MB::Sound::DSL.refresh!.include?(name)

        public_send(name, *args, **kwargs, &block)
      end

      def respond_to_missing?(name, include_private = false)
        MB::Sound::DSL.commands.include?(name) || super
      end
    end
  end
end

MB::Sound::DSL.install!
