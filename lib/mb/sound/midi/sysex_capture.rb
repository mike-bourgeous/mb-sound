require 'fileutils'

module MB
  module Sound
    module MIDI
      # Receives SysEx dumps from live MIDI inputs in the background and
      # saves each message to a .syx file as it completes (the console's
      # `sysex.capture`; SysExMethods).  Listens on one or more MIDI sources
      # (every source by default, or those whose names contain +from+), so
      # a dump is caught whichever port of a multi-port interface it comes
      # in on, and says which port it came from.
      #
      # A thread polls the inputs every POLL seconds and builds messages
      # with SysEx::Assembler (whole messages, or pieces from JACK bridges).
      # The capture ends after +count+ messages, +timeout+ seconds (a dump
      # still arriving then gets GRACE seconds after its last bytes), or
      # #stop, and closes its inputs.  Files never replace others (see
      # SysEx.save): by default <handoff inbox>/sysex/<date>_<time>_<what>.syx
      # (Internal.checkout_inbox: tmp/sysex/ of the main checkout,
      # $MB_SOUND_CHECKOUT_TMP, or the user data directory's tmp/).
      #
      #     cap = MIDI::SysExCapture.start('USB', timeout: 120)
      #     cap.wait
      #     cap.messages.last.decode   # e.g. SQ80::Programs
      #
      # States and transitions are declared in TRANSITIONS.
      class SysExCapture
        # State => { event => next state }.  The ended states take no
        # events (a #stop after the end does nothing).
        TRANSITIONS = {
          listening: { count: :finished, timeout: :timed_out, stop: :stopped, error: :failed },
          finished: {},
          timed_out: {},
          stopped: {},
          failed: {},
        }.freeze

        # Every state.
        STATES = TRANSITIONS.keys.freeze

        # How the end states read in status lines.
        ENDINGS = {
          finished: 'done', timed_out: 'timed out', stopped: 'stopped', failed: 'failed',
        }.freeze

        # Seconds between polls of the inputs.
        POLL = 0.01

        # Seconds a dump in progress may go on past the timeout once no new
        # bytes arrive.
        GRACE = 1.0

        # The default listening time in seconds.
        DEFAULT_TIMEOUT = 60

        # The longest message RtMidi input keeps (1 MiB; JACK input keeps 64
        # KiB per piece, and dumps arrive in pieces there).
        MAX_MESSAGE = 1 << 20

        # One input listened to: the source's +name+, the +input+ (anything
        # with #read_raw ([[time, bytes], ...]) and #close; #dropped
        # optional), and its Assembler.
        Listener = Struct.new(:name, :input, :assembler, :dropped)

        class << self
          # The MIDI sources to listen on for +from+, as [[api, index, name],
          # ...]: nil for every source of the first API that has any (our
          # own ports left out), an Integer for that source of the default
          # API, a String for every source whose name contains it (any
          # case), a Regexp for every source it matches; the first API (see
          # Input.search_apis) with a match wins.  Raises ArgumentError
          # with the sources when nothing matches.
          #
          # TODO: merge with the by-name device lookup the MIDI output work
          # adds, once both are in.
          def sources(from = nil, api: nil)
            unless from.nil? || from.is_a?(Integer) || from.is_a?(String) || from.is_a?(Regexp) || from.is_a?(Symbol)
              raise ArgumentError, "Listen on MIDI sources by part of a name (a String), a Regexp, or an index (got #{from.class})"
            end

            from = from.to_s if from.is_a?(Symbol)
            lists = {}
            Input.search_apis(api).each_with_index do |a, i|
              names = begin
                Input.port_names(a, :input)
              rescue FastMIDI::Error, FastAudio::Error
                raise if i == 0 && api
                []
              end
              lists[a] = names
              found = names.each_with_index.select { |n, idx|
                next false if own_port?(n)

                case from
                when nil then true
                when Integer then i == 0 && idx == from
                when Regexp then from.match?(n)
                else n.downcase.include?(from.downcase)
                end
              }
              return found.map { |n, idx| [a, idx, n] } unless found.empty?
            end

            what = from.nil? ? 'No MIDI sources found' : "No MIDI source matches #{from.inspect}"
            raise ArgumentError, "#{what}.  Sources:\n#{Input.port_list(lists)}"
          end

          # True if +name+ is a port of this process (our own MIDI outputs).
          def own_port?(name)
            [DeviceOutput.client_name, Jack.client_name].compact.any? { |c| name.start_with?("#{c}:") }
          end

          # Opens inputs on the sources for +from+ (see .sources) and starts
          # a capture on them (options as for #initialize).
          def start(from = nil, api: nil, **opts)
            found = sources(from, api: api)
            inputs = []
            begin
              found.each do |a, idx, name|
                inputs << [name, Input.new(connect: idx, api: a, queue_size: 8192, max_message: MAX_MESSAGE, from_env: false)]
              end
            rescue StandardError
              inputs.each { |_, inp| inp.close }
              raise
            end
            new(inputs, **opts)
          end

          # The default folder for captured files: sysex/ in the handoff
          # inbox (Internal.checkout_inbox).
          def default_dir
            Internal.checkout_inbox('sysex')
          end
        end

        attr_reader :state, :error, :timeout, :count

        # Captures SysEx from +inputs+ (pairs of [source name, input]; see
        # Listener).  +timeout+ seconds (nil: until #stop or +count+),
        # +count+ messages (nil: until the timeout or #stop).  +path+ names
        # the first file (later messages get -2, -3, ...; see SysEx.save),
        # else files go in +dir+ (.default_dir) with generated names; +save+
        # false keeps messages in memory only.  +out+ is called with each
        # line to print (Internal.console_puts by default).  +thread+ false
        # starts no thread (call #poll; specs), +clock+ gives seconds.
        def initialize(inputs, timeout: DEFAULT_TIMEOUT, count: nil, path: nil, dir: nil, save: true,
                       out: nil, thread: true, clock: nil)
          raise ArgumentError, 'A SysEx capture needs at least one input' if inputs.empty?
          raise ArgumentError, "timeout: is seconds or nil (got #{timeout.inspect})" unless timeout.nil? || (timeout.is_a?(Numeric) && timeout > 0)
          raise ArgumentError, "count: is a number of messages or nil (got #{count.inspect})" unless count.nil? || (count.is_a?(Integer) && count > 0)

          @listeners = inputs.map { |name, input| Listener.new(name.to_s, input, SysEx::Assembler.new, 0) }
          @timeout = timeout
          @count = count
          @path = path && File.expand_path(path.to_s)
          @dir = dir && File.expand_path(dir.to_s)
          @save = save
          @out = out || Internal.method(:console_puts)
          @clock = clock || -> { MB::U.clock_now }
          @lock = Mutex.new
          @messages = []
          @paths = []
          @lines = []
          @state = :listening
          @error = nil
          @started = @clock.call
          @ended = nil
          @last_bytes = @started
          @thread = nil
          ExitClose.register(self)
          @thread = Thread.new { run } if thread
        end

        # The source names listened to.
        def sources = @listeners.map(&:name)

        # The messages received so far (SysEx::Messages, a copy).
        def messages = @lock.synchronize { @messages.dup }

        # The files written so far (a copy).
        def paths = @lock.synchronize { @paths.dup }

        # True while listening.
        def listening? = @state == :listening

        # Seconds since the start (until the end, once ended).
        def elapsed = (@ended || @clock.call) - @started

        # Reads the inputs once, saving finished messages, and ends the
        # capture when +count+ or the timeout is reached.  Returns true while
        # still listening.
        def poll
          listening = @lock.synchronize do
            next false unless @state == :listening

            read_inputs
            now = @clock.call
            if @count && @messages.length >= @count
              finish(:count)
            elsif @timeout && now - @started >= @timeout && !(receiving? && now - @last_bytes < GRACE)
              finish(:timeout)
            end
            @state == :listening
          end
          flush_lines
          listening
        rescue StandardError => e
          @lock.synchronize { finish(:error, e) if @state == :listening }
          flush_lines
          false
        end

        # Stops listening (keeping what arrived; a dump cut short is kept
        # as incomplete).  Does nothing once ended.  Returns self.
        def stop
          @lock.synchronize { finish(:stop) if @state == :listening }
          flush_lines
          @thread&.join(2) unless Thread.current == @thread
          self
        end
        alias close stop

        # Waits until the capture ends (at most +seconds+, nil for no
        # limit).  Returns self.
        def wait(seconds = nil)
          if @thread
            @thread.join(seconds)
          else
            deadline = seconds && MB::U.clock_now + seconds
            sleep POLL while poll && (deadline.nil? || MB::U.clock_now < deadline)
          end
          self
        end

        # One line: what the capture does or did.
        def status
          @lock.synchronize do
            n = @messages.length
            got = "#{n} message#{'s' unless n == 1}"
            if @state == :listening
              limit = @timeout ? " of #{clock(@timeout)}" : ''
              rx = @listeners.find { |l| l.assembler.receiving? }
              receiving = rx ? ", receiving #{rx.assembler.pending_bytes} bytes from #{rx.name}" : ''
              "sysex: listening on #{source_names} for #{clock(elapsed)}#{limit}, #{got}#{receiving} (sysex.stop to stop)"
            else
              saved = @paths.empty? ? '' : "; saved #{@paths.length == 1 ? @paths.first : "#{@paths.length} files in #{File.dirname(@paths.first)}"}"
              err = @error ? " (#{@error.class}: #{@error.message})" : ''
              "sysex: #{ENDINGS[@state]} after #{clock(elapsed)}, #{got}#{saved}#{err}"
            end
          end
        end
        alias to_s status

        def inspect = "#<MIDI::SysExCapture #{status}>"

        private

        def run
          Thread.current.name = 'sysex capture'
          Thread.current.report_on_exception = false
          sleep POLL while poll
        end

        def receiving? = @listeners.any? { |l| l.assembler.receiving? }

        # (under @lock) Queues a line to print once the lock is released
        # (#flush_lines), so printing (a screen's lock) never waits inside it.
        def say(line) = @lines << line

        # Prints the queued lines.
        def flush_lines
          lines = @lock.synchronize do
            l = @lines
            @lines = []
            l
          end
          lines.each { |l| @out.call(l) }
        end

        # (under @lock)
        def read_inputs
          @listeners.each do |l|
            l.input.read_raw.each do |_time, bytes|
              @last_bytes = @clock.call if bytes.include?("\xF0".b) || l.assembler.receiving?
              l.assembler.push(bytes).each { |b, complete| add(b, complete, l.name) }
            end

            next unless l.input.respond_to?(:dropped)

            d = l.input.dropped.to_i
            if d > l.dropped
              say("sysex: #{d - l.dropped} message#{'s' if d - l.dropped > 1} from #{l.name} were lost (too long or the queue was full)")
              l.dropped = d
            end
          end
        end

        # (under @lock)
        def add(bytes, complete, port)
          msg = SysEx::Message.new(bytes: bytes, port: port, time: Time.now, complete: complete)
          @messages << msg
          path = @save ? save(msg) : nil
          @paths << path if path
          say("sysex: #{msg}#{"\n  saved #{path}" if path}")
        end

        def save(msg)
          path = @path || File.join(@dir || self.class.default_dir,
                                    "#{msg.time.strftime('%Y-%m-%d_%H%M%S')}_#{msg.slug}#{'_incomplete' unless msg.complete?}.syx")
          SysEx.save(path, msg.bytes)
        end

        # (under @lock) Moves to the state for +event+, flushes dumps in
        # progress, closes the inputs, and prints the end.
        def finish(event, error = nil)
          to = TRANSITIONS.fetch(@state)[event]
          return unless to

          @listeners.each { |l| l.assembler.flush.each { |b, complete| add(b, complete, l.name) } } unless event == :error
          @error = error
          @state = to
          @ended = @clock.call
          @listeners.each do |l|
            l.input.close
          rescue StandardError
            nil
          end
          ExitClose.unregister(self)
          n = @messages.length
          if event == :error
            say("sysex: capture failed: #{error.class}: #{error.message}")
          elsif n == 0
            say("sysex: #{ENDINGS[to]} after #{clock(elapsed)}, nothing received")
          elsif event != :count
            say("sysex: #{ENDINGS[to]} after #{clock(elapsed)}, #{n} message#{'s' unless n == 1}")
          end
        end

        def source_names
          return @listeners.first.name if @listeners.length == 1

          "#{@listeners.length} sources"
        end

        # m:ss
        def clock(seconds)
          m, s = seconds.to_f.round.divmod(60)
          format('%d:%02d', m, s)
        end
      end
    end
  end
end
