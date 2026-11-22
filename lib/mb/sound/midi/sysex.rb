module MB
  module Sound
    module MIDI
      # System Exclusive messages: patch and bank dumps, requests, anything
      # a device sends between F0 and F7.  Hardware-agnostic: who made a
      # message comes from its manufacturer ID (MANUFACTURERS), and readers
      # for one device family (SQ80::SysEx) register a description and a
      # decoder for their messages with .register.
      #
      #     dump = MIDI::SysEx.load('patch.syx')  # a Dump: prints one line per message
      #     dump.programs                         # decoded programs (registered readers)
      #     MIDI::SysEx.save('copy.syx', dump)    # never overwrites: copy-2.syx if taken
      #
      # MIDI::SysExCapture receives them from live MIDI inputs (the console's
      # `sysex.capture`; SysExMethods).
      module SysEx
        # Manufacturer IDs (one byte, or three starting with 0) and names, for
        # descriptions.  Not complete: other IDs print as hex.
        MANUFACTURERS = {
          [0x01] => 'Sequential',
          [0x04] => 'Moog',
          [0x06] => 'Lexicon',
          [0x07] => 'Kurzweil',
          [0x0F] => 'Ensoniq',
          [0x10] => 'Oberheim',
          [0x18] => 'E-mu',
          [0x40] => 'Kawai',
          [0x41] => 'Roland',
          [0x42] => 'Korg',
          [0x43] => 'Yamaha',
          [0x44] => 'Casio',
          [0x47] => 'Akai',
          [0x7D] => 'non-commercial',
          [0x7E] => 'universal non-real-time',
          [0x7F] => 'universal real-time',
          [0x00, 0x00, 0x0E] => 'Alesis',
          [0x00, 0x20, 0x29] => 'Novation',
          [0x00, 0x20, 0x32] => 'Behringer',
          [0x00, 0x20, 0x33] => 'Access',
          [0x00, 0x20, 0x3C] => 'Elektron',
          [0x00, 0x20, 0x6B] => 'Arturia',
          [0x00, 0x21, 0x09] => 'Native Instruments',
        }.freeze

        # The longest message the Assembler and the files keep (16 MiB).
        MAX_BYTES = 16 * 1024 * 1024

        # A complete message: F0, data bytes (0x00-0x7F), F7.
        COMPLETE = /\A\xF0[\x00-\x7F]*\xF7\z/n

        class FormatError < ArgumentError; end

        # A reader registered for one manufacturer's messages (see .register).
        Reader = Data.define(:id, :name, :describe, :decode, :slug)

        @readers = {}

        class << self
          # Registers a reader for messages with manufacturer ID +id+ (an
          # Integer or Array of bytes) named +name+: +describe+ is called
          # with a message's bytes (an Array) and returns a short
          # description (or nil if it doesn't know the message), +decode+
          # returns the message's decoded objects (e.g. programs; an Array,
          # maybe empty), and +slug+ returns a short file-name part (or
          # nil).  Each Proc may raise; the message is then described
          # generically.  A later registration for the same ID and name
          # replaces the earlier one.
          def register(id, name, describe:, decode: nil, slug: nil)
            id = Array(id)
            list = (@readers[id] ||= [])
            list.reject! { |r| r.name == name }
            list << Reader.new(id: id, name: name, describe: describe, decode: decode, slug: slug)
            nil
          end

          # The readers registered for manufacturer ID +id+ (an Array).
          def readers(id)
            @readers.fetch(Array(id), [])
          end

          # The manufacturer ID of +bytes+ (an Array starting with F0): one
          # byte, or three when the first is 0.  Nil if too short.
          def manufacturer_id(bytes)
            return nil if bytes.length < 2
            return bytes[1, 3] if bytes[1] == 0 && bytes.length >= 4

            [bytes[1]]
          end

          # The manufacturer's name (MANUFACTURERS) or its ID in hex.
          def manufacturer(bytes)
            id = manufacturer_id(bytes)
            return 'no manufacturer' unless id

            MANUFACTURERS[id] || "manufacturer #{id.map { |b| format('%02X', b) }.join(' ')}"
          end

          # A short description of SysEx +bytes+ (an Array or binary
          # String): what a registered reader says, else the manufacturer.
          def describe(bytes)
            bytes = bytes.bytes if bytes.is_a?(String)
            id = manufacturer_id(bytes)
            readers(id).each do |r|
              text = begin
                r.describe.call(bytes)
              rescue StandardError
                nil
              end
              return text if text
            end
            manufacturer(bytes)
          end

          # What registered readers decode from +bytes+ (e.g. programs), in
          # order; an empty Array if none knows the message.
          def decode(bytes)
            bytes = bytes.bytes if bytes.is_a?(String)
            readers(manufacturer_id(bytes)).flat_map do |r|
              next [] unless r.decode

              begin
                Array(r.decode.call(bytes))
              rescue StandardError
                []
              end
            end
          end

          # A short file-name part for +bytes+: a registered reader's slug,
          # else the manufacturer's name (lowercase, dashes).
          def slug(bytes)
            bytes = bytes.bytes if bytes.is_a?(String)
            text = readers(manufacturer_id(bytes)).lazy.map { |r|
              begin
                r.slug&.call(bytes)
              rescue StandardError
                nil
              end
            }.find(&:itself)
            clean_slug(text || manufacturer(bytes))
          end

          # +text+ for a file name: lowercase letters, digits, and dashes, at
          # most 48 characters ('sysex' if nothing is left).
          def clean_slug(text)
            s = text.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')[0, 48].sub(/-+\z/, '')
            s.empty? ? 'sysex' : s
          end

          # The messages in +source+ (a file name, a binary String, an Array
          # of bytes, or a Dump/Message/Array of them) as Messages: one per
          # F0 ... F7, plus incomplete ones (cut short by another status
          # byte or the end of the data; Message#complete? false).  Bytes
          # outside messages are skipped.  +port+ and +time+ go into each
          # Message.
          def messages(source, port: nil, time: nil)
            case source
            when Dump then return source.messages
            when Message then return [source]
            end
            if source.is_a?(Array) && source.all?(Message)
              return source
            end

            data = case source
                   when Array then source.pack('C*')
                   when String then source.encoding == Encoding::BINARY ? source : File.binread(source)
                   else raise ArgumentError, "SysEx comes from a file name, a binary String, bytes, or Messages (got #{source.class})"
                   end
            asm = Assembler.new
            found = asm.push(data) + asm.flush
            found.map { |bytes, complete| Message.new(bytes: bytes, port: port, time: time, complete: complete) }
          end

          # The messages of the .syx file at +path+ as a Dump (one line per
          # message when printed; Dump#programs decodes them).  Raises
          # FormatError if the file has no SysEx message.
          def load(path)
            path = File.expand_path(path.to_s)
            list = messages(File.binread(path), port: path)
            raise FormatError, "#{path} has no SysEx messages (F0 ... F7)" if list.empty?

            Dump.new(messages: list, path: path)
          end

          # Writes +source+ (anything .messages takes) to +path+ as raw
          # SysEx bytes, never replacing a file: if +path+ is taken, the
          # first free of name-2.syx, name-3.syx, ... (made atomically, so
          # two writers never share a name).  Creates the folder.  Returns
          # the path written.
          def save(path, source)
            data = source.is_a?(String) && source.encoding == Encoding::BINARY ? source : messages(source).map(&:bytes).join
            FileUtils.mkdir_p(File.dirname(path))
            base = path.sub(/(\.[^.\/]*)?\z/, '')
            ext = path[/\.[^.\/]*\z/] || ''
            (1..10_000).each do |n|
              candidate = n == 1 ? path : "#{base}-#{n}#{ext}"
              begin
                File.open(candidate, File::WRONLY | File::CREAT | File::EXCL | File::BINARY) { |f| f.write(data) }
                return candidate
              rescue Errno::EEXIST
                next
              end
            end
            raise IOError, "No free file name like #{path}"
          end
        end

        # One SysEx message: +bytes+ (a frozen binary String from F0 to F7),
        # +port+ (the MIDI source it came from, or the file it was read
        # from; nil if neither), +time+ (when it arrived, or nil),
        # +complete+ (false if it was cut short: no F7 at the end).
        Message = Data.define(:bytes, :port, :time, :complete) do
          def initialize(bytes:, port: nil, time: nil, complete: true)
            super(bytes: bytes.b.freeze, port: port, time: time, complete: complete)
          end

          def complete? = complete
          def size = bytes.bytesize
          def to_a = bytes.bytes

          # The manufacturer's name (or its ID in hex).
          def manufacturer = SysEx.manufacturer(to_a)

          # What a registered reader says about the message, else the
          # manufacturer.
          def description = SysEx.describe(to_a)

          # What registered readers decode from the message (e.g. programs).
          def decode = SysEx.decode(to_a)

          # A short file-name part (see SysEx.slug).
          def slug = SysEx.slug(to_a)

          # The message as a MIDI::Event (type :sysex).
          def to_event = Event.parse(bytes)

          # Writes the message to +path+ (never replacing a file; see
          # SysEx.save).  Returns the path written.
          def save(path) = SysEx.save(path, bytes)

          def to_s
            "#{description}, #{size} bytes#{' (INCOMPLETE: no F7)' unless complete?}#{" from #{port}" if port}"
          end

          def inspect = "#<SysEx::Message #{self}>"
          def pretty_print(q) = q.text(to_s)
        end

        # The messages of a .syx file (SysEx.load): +messages+ and the
        # +path+ they came from.  Prints one line per message.
        Dump = Data.define(:messages, :path) do
          include Enumerable

          def each(&) = messages.each(&)
          def [](i) = messages[i]
          def size = messages.size
          alias_method :length, :size

          # All the bytes, as a binary String.
          def bytes = messages.map(&:bytes).join

          # What registered readers decode from the messages (e.g. SQ-80
          # programs; SQ80::Program prints its panel values), in order.
          def programs = messages.flat_map(&:decode)

          # Writes the messages to +path+ (never replacing a file; see
          # SysEx.save).  Returns the path written.
          def save(path) = SysEx.save(path, bytes)

          def to_s
            head = "#{path}: #{size} SysEx message#{'s' unless size == 1}, #{bytes.bytesize} bytes"
            ([head] + messages.each_with_index.map { |m, i| "  #{i + 1}. #{m.description}, #{m.size} bytes#{' (INCOMPLETE)' unless m.complete?}" }).join("\n")
          end

          def inspect = "#<SysEx::Dump #{path} (#{size} messages)>"
          def pretty_print(q) = q.text(to_s)
        end

        # Builds whole SysEx messages from MIDI input as it arrives: whole
        # messages (RtMidi joins a dump's pieces), or a dump split into
        # pieces (JACK MIDI from ALSA bridges, PipeWire: F0 and the first
        # bytes, then data bytes, the last piece ending in F7).  Real-time
        # bytes (F8-FF) inside a dump are skipped, as MIDI allows them
        # there; any other status byte ends a dump early (incomplete), and
        # so does a dump longer than +max_bytes+.  Other messages (notes,
        # controllers) are ignored.
        class Assembler
          def initialize(max_bytes: MAX_BYTES)
            @max = max_bytes
            @buf = nil
          end

          # True while a dump has started and not ended.
          def receiving? = !@buf.nil?

          # Bytes of the dump being received (0 if none).
          def pending_bytes = @buf ? @buf.bytesize : 0

          # Takes the bytes of one MIDI input message (a binary String) and
          # returns the messages it completes: [[bytes, complete], ...].
          def push(data)
            data = data.b
            if @buf.nil?
              return [[data, true]] if data.bytesize <= @max && COMPLETE.match?(data)
              return [] unless data.include?("\xF0".b)
            end

            out = []
            data.each_byte do |b|
              if b >= 0xF8
                next
              elsif b == 0xF0
                out << [@buf, false] if @buf
                @buf = +"\xF0".b
              elsif b == 0xF7
                next unless @buf

                @buf << b
                out << [@buf, true]
                @buf = nil
              elsif b >= 0x80
                out << [@buf, false] if @buf
                @buf = nil
              elsif @buf
                @buf << b
                if @buf.bytesize >= @max
                  out << [@buf, false]
                  @buf = nil
                end
              end
            end
            out
          end

          # Ends a dump in progress (at the end of a file or a capture):
          # [[bytes, false]], or [] if none.
          def flush
            return [] unless @buf

            out = [[@buf, false]]
            @buf = nil
            out
          end
        end
      end
    end
  end
end
