module MB
  module Sound
    module MIDI
      # A list of the MIDI controllers (MIDI::ControlSpecs) that a synth,
      # effect, or graph responds to, for the console (`midi.controls`,
      # `synth.controls`), the script runner's parameter listing, and
      # controller maps for the Sony/MAGIX ACID DAW (#to_acid_xml), which
      # let ACID show and automate a script's parameters by name.
      #
      # Sources (the constructor and #add take any number):
      # - a MIDI::ControlSpec, an Array of them, or another ControlMap
      # - anything with #control_specs: a MB::Sound::Notes (the controller
      #   nodes in use on its control stream, shared by every lane of a
      #   synth), a MB::Sound::Synth (its lanes' controllers, output
      #   controls, and sustain pedals), or a Notes::Control node
      # - a graph node or Channels bundle: every node upstream of it with
      #   #control_specs (controller nodes, synths)
      #
      # Equal specs are kept once.  Different specs on the same controller
      # (e.g. p.midi_cc parameters of a synth script on CC 1 and the
      # synth's vibrato on CC 1, or Notes#bend and the bend inside v.hz)
      # are listed together, and share one entry in the ACID XML, named
      # after all of them, with the first spec's default as its neutral
      # value (like the old Manager#to_acid_xml).  Pitch bend and channel
      # pressure specs (ControlSpec.bend, .pressure) come after the CCs,
      # pressure first (sorted by MIDI status byte).
      #
      #     map = MB::Sound::MIDI::ControlMap.new(synth, p.midi)
      #     puts map
      #     File.write('synth.xml', map.to_acid_xml(name: 'My synth'))
      #
      # Enumerable over the specs (sorted by ControlSpec#key: CC number,
      # then pressure and bend; then in the order they were added).
      class ControlMap
        include Enumerable

        # The ACID curve types offered for continuous controllers.
        ACID_CURVES = ['HOLD', 'LINEAR', 'LOG FAST', 'LOG SLOW', 'CUBIC SHARP TANGENT', 'CUBIC SMOOTH'].freeze

        # Creates a map from any number of +sources+ (see the class
        # description).
        def initialize(*sources)
          @specs = []
          add(*sources)
        end

        # Adds the controllers of +sources+ (see the class description).
        # Returns self.
        def add(*sources)
          sources.each do |src|
            case src
            when nil
              next
            when ControlSpec
              @specs << src unless @specs.include?(src)
            when ControlMap, Array
              src.each { |s| add(s) }
            else
              found = false
              if src.respond_to?(:control_specs)
                add(src.control_specs)
                found = true
              end

              if src.respond_to?(:graph) && src.respond_to?(:outputs)
                graph_nodes(src).each { |n| add(n.control_specs) if !n.equal?(src) && n.respond_to?(:control_specs) }
                found = true
              end

              raise ArgumentError, "Can't find MIDI controls in #{src.inspect}" unless found
            end
          end

          self
        end
        alias << add

        # Yields each spec, sorted by controller number (then in the order
        # added).
        def each(&block)
          return enum_for(:each) unless block

          sorted.each(&block)
          self
        end

        # The number of specs (more than #numbers when several specs share
        # a controller).
        def size
          @specs.size
        end
        alias length size

        def empty?
          @specs.empty?
        end

        # The CC numbers in use, sorted (see #types for bend and pressure).
        def numbers
          @specs.select(&:cc?).map(&:number).uniq.sort
        end

        # The controller types in use (:cc, :pressure, :bend), sorted.
        def types
          sorted.map(&:type).uniq
        end

        # The specs on CC +number+, or with +:bend+ or +:pressure+ the pitch
        # bend or channel pressure specs (an Array, empty if none).
        def [](number)
          if number.is_a?(Symbol)
            sorted.select { |s| s.type == number }
          else
            sorted.select { |s| s.cc? && s.number == number }
          end
        end

        # A Hash from controller (a CC number, or :pressure or :bend) to an
        # Array of the specs on it, sorted (see ControlSpec#key).
        def groups
          sorted.group_by { |s| s.cc? ? s.number : s.type }
        end

        def ==(other)
          other.is_a?(ControlMap) && other.to_a == to_a
        end

        # A plain-text listing, one line per spec (see ControlSpec#to_s),
        # with descriptions.
        def to_s
          return 'MIDI controls: none' if empty?

          lines = map { |s| "  #{s.cc? ? s.to_s.sub(/\ACC (\d+)/) { format('CC %3d', $1.to_i) } : s.to_s}#{" - #{s.description}" if s.description}" }
          "MIDI controls:\n#{lines.join("\n")}"
        end

        def inspect
          "#<#{self.class.name} #{map { |s| s.cc? ? "CC #{s.number} #{s.name}" : s.name }.join(', ')}>"
        end

        # Pry and pp show the listing (see #to_s).
        def pretty_print(q)
          q.text(to_s)
        end

        # Returns a String containing an XML controller map for the Sony/MAGIX
        # ACID music software, named +name+ (the script's name by default),
        # in the format of the old MIDI::Manager#to_acid_xml: one <param> per
        # controller number, sorted, named after its specs (joined with
        # ", "), continuous controllers on MIDI channel 1 with a neutral
        # value of the first spec's default, and switches (every spec on
        # the number a :switch, e.g. the sustain pedal) on any channel with
        # ACID's HOLD curve.  Channel pressure and pitch bend entries follow
        # the CCs, as the old MIDI::Parameter wrote them (any channel,
        # MIDIMsg 208 or 224, ccMsg 0, Max 127 or 16383).
        def to_acid_xml(name: File.basename($0))
          require 'builder'

          xml = Builder::XmlMarkup.new(indent: 2)
          xml.instruct!
          grouped = groups
          xml.parammap(mapname: name, ver: 1, summary: '', params: grouped.length) do |m|
            grouped.each do |number, specs|
              if !specs.first.cc?
                acid_param(m, number, specs)
              elsif specs.all? { |s| s.curve == :switch }
                acid_switch(m, number, specs)
              else
                acid_param(m, number, specs)
              end
            end
          end

          xml.target!
        end

        # Writes #to_acid_xml to +path+ (named after the script by default).
        # Returns the path.
        def write_acid_xml(path, name: File.basename($0))
          File.write(path, to_acid_xml(name: name))
          path
        end

        private

        def sorted
          @specs.each_with_index.sort_by { |s, idx| [*s.key, idx] }.map(&:first)
        end

        def graph_nodes(src)
          [src, *src.outputs].flat_map { |n| [n, *(n.respond_to?(:graph) ? n.graph : [])] }.uniq
        end

        def acid_name(specs)
          specs.map(&:name).uniq.join(', ')
        end

        # A continuous entry: a CC on channel 1, or pitch bend or channel
        # pressure on any channel (the old MIDI::Parameter#to_acid_xml).
        def acid_param(xml, number, specs)
          spec = specs.find { |s| s.curve != :switch } || specs.first
          xml.param(name: acid_name(specs)) do |p|
            p.flags do |f|
              f.flag('DEFAULT')
              f.flag('ACTIVE')
              f.flag('LOCAL')
            end
            p.ChannelMask(spec.cc? ? 1 : 65535)
            p.MIDIMsg(spec.status)
            p.ccMsg(spec.cc? ? number : 0)
            p.CurveType('LINEAR')
            p.CurveMask do |c|
              ACID_CURVES.each { |curve| c.curve(curve) }
            end
            p.Min(0)
            p.Max(spec.raw_max)
            p.Neutral(spec.default)
          end
        end

        def acid_switch(xml, number, specs)
          xml.param(name: acid_name(specs)) do |p|
            p.flags do |f|
              f.flag('DEFAULT')
              f.flag('ACTIVE')
              f.flag('LOCAL')
              f.flag('SWITCH')
            end
            p.ChannelMask(65535)
            p.MIDIMsg(176)
            p.ccMsg(number)
            p.CurveType('HOLD')
            p.CurveMask do |c|
              c.curve('HOLD')
            end
            p.Min(0)
            p.Max(127)
            p.Neutral(specs.first.default)
          end
        end
      end
    end
  end
end
