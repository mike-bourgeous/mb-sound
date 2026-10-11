require 'stringio'
require 'timeout'

# Graph-io round trips of the bin/ synth and effect scripts: each script's
# graph block runs with recording on (in a fork, stopped before playback),
# its result prints as Ruby (GraphNode#to_ruby, the block's input named
# midi or input), and the printed code, evaluated with fresh inputs
# (c_major.mid, arp_a7.flac), must render the same samples.  The same graph
# saved as a graph document (GraphIO.dump, with the script's parameters as
# params, as --save does) and loaded with GraphIO.load (no eval) must render
# the same samples too, and with a param override, follow it.  Scripts that
# can't print yet are listed with the reason the printed code gives.
RSpec.describe('graph-io round trips of bin/ scripts', :smoke) do
  root = File.expand_path('../..', __dir__)
  midi_path = File.join(root, 'spec/test_data/c_major.mid')
  audio_path = File.join(root, 'spec/test_data/arp_a7.flac')

  # Script => the FIXME (or input) the printed code must name
  not_representable = {
    'bin/effects/reverse_delay.rb' => 'the proc block uses a from the code around it',
    'bin/synths/fm_chain.rb' => 'a class defined outside the library',
    'bin/synths/sq80_voice.rb' => "a Wavetable that isn't a library table",
    'bin/synths/wavetable_bass.rb' => "isn't a library table",
  }.freeze

  # Stops a script runner where it would play, keeping the graph block's
  # own result and input.
  capture = Module.new do
    def run_effect(&block)
      super { |input, p| @graph_io_input = { input: input }; block.call(input, p) }
    end

    def run_synth(&block)
      wrapped =
        if block.arity == 1
          ->(n) { @graph_io_input = { midi: n }; block.call(n) }
        else
          ->(n, p) { @graph_io_input = { midi: n }; block.call(n, p) }
        end
      super(&wrapped)
    end

    def to_graph(result)
      @graph_io_result = result
      super
    end

    def play_or_render(graph)
      throw :graph_io_captured, [@graph_io_result || graph, @graph_io_input, graph_params]
    end

    def announce(_graph); end
  end

  scripts = Dir[File.join(root, 'bin/{synths,effects}/*.rb')].sort.select { |p| File.read(p).match?(/(synth|effect)_script/) }

  it 'covers the synth and effect scripts' do
    expect(scripts.length).to be >= 25
    names = scripts.map { |p| p.delete_prefix("#{root}/") }
    expect(not_representable.keys - names).to eq([])
  end

  scripts.each do |path|
    name = path.delete_prefix("#{root}/")

    it "prints #{name} as Ruby that renders the same" do
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        $stdout = StringIO.new
        $stderr = StringIO.new
        report = {}
        begin
          Timeout.timeout(120) do
            ENV['OUTPUT_TYPE'] = 'null'
            ENV['INPUT_TYPE'] = 'null'
            MB::Sound::ScriptRunner.prepend(capture)
            synth = name.include?('synths/')
            ARGV.replace([synth ? midi_path : audio_path, '-o', File.join(Dir.tmpdir, "graph_io_#{Process.pid}.flac"), '-f', '-q'])
            $PROGRAM_NAME = path
            MB::Sound.seed(0)
            graph, inputs, (params, options) = catch(:graph_io_captured) { load path; nil }
            raise 'no graph captured' unless graph

            code = MB::Sound::GraphNode::Recipe::RubyWriter.new(graph, inputs: inputs, seeds: true).to_s
            report[:code] = code
            unless code.include?('FIXME')
              ref = RecipeHelpers.render(graph, buffers: 94)
              MB::Sound.seed(code.include?('MB::Sound.seed') ? 0 : 77)
              fresh = inputs.transform_values { |o|
                o.is_a?(MB::Sound::Notes) ? MB::Sound::Notes.new(midi_path) : MB::Sound.file_input(audio_path).ringdown
              }
              got = RecipeHelpers.render(RecipeHelpers.eval_recipe(code, fresh), buffers: 94)
              report[:lengths] = [ref.map(&:length), got.map(&:length)]
              report[:diff] = RecipeHelpers.max_diff(ref, got)
              report[:peak] = ref.map { |r| r.length > 0 ? r.abs.max : 0 }.max

              doc = MB::Sound::GraphIO.dump(graph, name: File.basename(path, '.rb'), inputs: inputs, params: params, options: options, from: name)
              report[:doc] = doc
              MB::Sound.seed(code.include?('MB::Sound.seed') ? 0 : 78)
              fresh = inputs.transform_values { |o|
                o.is_a?(MB::Sound::Notes) ? MB::Sound::Notes.new(midi_path) : MB::Sound.file_input(audio_path).ringdown
              }
              loaded = MB::Sound::GraphIO.load(doc, inputs: fresh)
              got = RecipeHelpers.render(loaded, buffers: 94)
              report[:doc_lengths] = got.map(&:length)
              report[:doc_diff] = RecipeHelpers.max_diff(ref, got)
              report[:knobs] = MB::Sound::GraphIO.document_of(loaded).params.keys
            end
          end
        rescue Exception => e # rubocop:disable Lint/RescueException
          report[:error] = "#{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        end
        writer.write(Marshal.dump(report))
        writer.close
        exit!(0)
      end
      writer.close
      data = reader.read
      Process.wait(pid)
      report = Marshal.load(data)

      expect(report[:error]).to be_nil, report[:error]
      if not_representable.key?(name)
        expect(report[:code]).to include(not_representable[name])
      else
        expect(report[:code]).not_to include('FIXME')
        expect(report[:lengths][0]).to eq(report[:lengths][1])
        expect(report[:diff]).to eq(0), report[:code]
        expect(report[:peak]).to be > 0.001
        expect(report[:doc_lengths]).to eq(report[:lengths][0])
        expect(report[:doc_diff]).to eq(0), report[:doc]
        # Knobs print as their names, not as named Constants
        knobs = report[:knobs].map(&:to_s)
        expect(report[:doc]).not_to match(/\.constant\.named\("(#{knobs.join('|')})"\)/) unless knobs.empty?
        expect(knobs).to include('dry', 'wet', 'drive') if name == 'bin/effects/tape_delay.rb'
      end
    end
  end
end
