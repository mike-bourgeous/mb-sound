module MB
  module Sound
    module MIDI
      class Stream
        # How a stream was made, so it can print itself back as Ruby (wires
        # in set documents and listings, `wire :lead, riff.stream.echo(1.n8,
        # 3)`; design/notes/arrangement.md, Wires): the +root+ source it
        # reads (a ClipSource, a clip's #stream, or a FileSource, a MIDI
        # file) and the transform calls made on it since, as frozen [name,
        # args, kwargs] +steps+.  Streams of live input, merges, and
        # transforms given a block or a Proc have none (#lineage is nil):
        # they can't be printed.  Stream::ARGUMENT_HELP, the wrapper of
        # every transform (stream_transforms.rb), records each call.
        Lineage = Data.define(:root, :steps)

        # How this stream was made (a Lineage), or nil if that isn't known
        # (see Lineage).
        def lineage
          return nil if @lineage == :none
          @lineage || root_lineage
        end

        private

        # A root stream's lineage: a clip's or a MIDI file's source with no
        # steps (nil for other sources).
        def root_lineage
          case @source
          when ClipSource, FileSource then Lineage.new(root: @source, steps: [].freeze)
          end
        end

        # Records that this stream is +parent+ through transform +name+
        # (see Lineages): no lineage if the parent has none or the call
        # takes a block (code, not data); #through adds its chain's steps.
        def adopt_lineage(parent, name, args, kwargs, block)
          base = parent.lineage
          steps =
            if base.nil? || block
              nil
            elsif name == :through
              spec = args.length == 1 && kwargs.empty? ? args[0] : nil
              if spec.is_a?(Transform::Spec) && spec.steps.none? { |s| s[3] }
                spec.steps.map { |n, a, k, _| [n, a, k].freeze }
              end
            else
              [[name, args.freeze, kwargs.freeze].freeze]
            end
          @lineage = steps ? Lineage.new(root: base.root, steps: (base.steps + steps).freeze) : :none
        end
      end
    end
  end
end
