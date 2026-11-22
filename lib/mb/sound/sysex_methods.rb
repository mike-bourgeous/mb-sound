module MB
  module Sound
    # The console's `sysex` command: receive SysEx dumps (patches, banks)
    # from hardware into .syx files without blocking the console, load
    # them back, and send them out again (MIDI::SysEx, MIDI::SysExCapture;
    # design note midi.md, SysEx).
    module SysExMethods
      # What `sysex` returns: the commands, and the capture's status line
      # when printed.
      class Console
        def initialize
          @capture = nil
          @outputs = {}
        end

        # Listens for SysEx in the background and saves each message to a
        # .syx file as it arrives (never replacing a file), printing what
        # came from which MIDI port.  +from+: nil listens on every MIDI
        # source; part of a source's name (any case) listens on every
        # source matching it; an Integer on that source (sysex.ports lists
        # them).  Ends after +timeout+ seconds (nil: never), +count+
        # messages (nil: no limit), or `sysex.stop`.  +path+ names the
        # first file (later ones get -2, -3, ...); by default files go in
        # tmp/sysex/ of the main checkout (the handoff inbox), named by
        # date, time, and what the message is.  +api+ picks the MIDI API
        # (:alsa, :jack, :core).  +request+ (bytes, e.g.
        # `SQ80::SysEx.request(:program)`) is sent to the MIDI destination
        # +to+ once listening, for instruments that answer dump requests.
        # Returns the console (printed as the status line).
        #
        #     sysex.capture                    # every source, 60 s
        #     sysex.capture 'USB', timeout: 300, count: 1
        #     sysex                            # status
        #     sysex.stop
        def capture(from = nil, timeout: MIDI::SysExCapture::DEFAULT_TIMEOUT, count: nil, path: nil, api: nil, request: nil, to: nil)
          if @capture&.listening?
            puts "#{@capture.status.sub('sysex: listening', 'sysex: already listening')}"
            return self
          end
          raise ArgumentError, 'sysex.capture: request: needs to: (the MIDI destination to send it to)' if request && to.nil?

          @capture = MIDI::SysExCapture.start(from, api: api, timeout: timeout, count: count, path: path)
          names = @capture.sources
          shown = names.length > 6 ? names.first(6) + ["... (#{names.length - 6} more)"] : names
          puts "sysex: listening on #{shown.join(', ')}"
          transmit(request, to: to, api: api) if request
          self
        end

        # Stops the capture (keeping what arrived).  Returns the console.
        def stop
          @capture&.stop
          self
        end

        # Waits until the capture ends (at most +seconds+; nil for no
        # limit), for scripts.  Returns the console.
        def wait(seconds = nil)
          @capture&.wait(seconds)
          self
        end

        # The messages of the latest capture (MIDI::SysEx::Messages; each
        # prints one line, `.decode` gives programs, `.save(path)` writes
        # it).
        def messages
          @capture ? @capture.messages : []
        end

        # The last message received, or nil.
        def last
          messages.last
        end

        # The files the latest capture wrote.
        def paths
          @capture ? @capture.paths : []
        end

        # Lists the MIDI sources a capture can listen on, numbered, and
        # returns their names (+api+ as for #capture).
        def ports(api: nil)
          names = MIDI::Input.ports(api: api)
          names.each_with_index { |n, i| puts format('  %2d: %s', i, n) }
          puts '  (no MIDI sources)' if names.empty?
          names
        end

        # The messages of the .syx file at +path+ (a MIDI::SysEx::Dump: one
        # line per message; `.programs` decodes them, e.g. SQ-80 programs
        # that print their panel values; `.save(path)`).
        def load(path)
          MIDI::SysEx.load(path)
        end

        # Sends SysEx to the MIDI destination whose name contains +to+ (an
        # index works too; see MIDI::Output): +source+ is a .syx file name,
        # a Dump or Message, or bytes (an Array or binary String).  Each
        # message goes out whole through MIDI::Output#write; the output
        # stays open for the next send.  Returns the number of messages.
        #
        #     sysex.transmit 'tmp/sysex/patch.syx', to: 'USB'
        #     sysex.transmit SQ80::SysEx.request(:program), to: 'USB'
        def transmit(source, to:, api: nil)
          list = MIDI::SysEx.messages(source)
          raise ArgumentError, 'sysex.transmit: no SysEx messages (F0 ... F7) to send' if list.empty?

          incomplete = list.reject(&:complete?)
          raise ArgumentError, "sysex.transmit: #{incomplete.length} message(s) have no F7 (incomplete); not sent" unless incomplete.empty?

          key = [to, api]
          out = @outputs[key]
          out = @outputs[key] = MIDI::Output.new(connect: to, api: api, same_key: :raw) if out.nil? || out.closed?
          list.each { |m| out.write(m.bytes) }
          bytes = list.sum(&:size)
          puts "sysex: sent #{list.length} message#{'s' unless list.length == 1} (#{bytes} bytes) to #{out.connected_to || out.port}"
          list.length
        end

        # Closes the outputs #transmit opened.  Returns nil.
        def close
          @outputs.each_value(&:close)
          @outputs.clear
          nil
        end

        # The capture's status line.
        def status
          @capture ? @capture.status : 'sysex: nothing captured yet (sysex.capture listens; sysex.ports lists the sources)'
        end
        alias to_s status

        def inspect = status
        def pretty_print(q) = q.text(status)
      end

      class << self
        # The console's one Console.
        def console
          @console ||= Console.new
        end

        # Stops any capture and forgets the console (specs).
        def reset
          @console&.stop
          @console&.close
          @console = nil
        end
      end

      # SysEx in the console: `sysex.capture` receives dumps from MIDI
      # hardware in the background (each message saved to a .syx file in
      # tmp/sysex/, never replacing one), `sysex` prints its status,
      # `sysex.stop` ends it, `sysex.load(path)` reads a file back
      # (`.programs` decodes SQ-80 programs), `sysex.transmit(path, to:)`
      # sends one out, `sysex.ports` lists the MIDI sources.
      #
      #     sysex.capture 'USB', timeout: 300   # then send the dump from the instrument
      #     sysex.last.decode.first             # an SQ-80 program's panel values
      #     sysex.load('tmp/sysex/x.syx').programs
      def sysex
        SysExMethods.console
      end
    end
  end
end
