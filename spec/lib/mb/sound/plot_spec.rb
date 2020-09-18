RSpec.describe MB::Sound::Plot do
  describe '#plot' do
    context 'with the dumb terminal type' do
      it 'can plot to an array of lines' do
        plot = MB::Sound::Plot.terminal
        expect(plot.width).to be < 300
        expect(plot.height).to be < 200

        lines = plot.plot({test: [-1, 0, 1, 0, -1], data: [1, 0, 1, 0, 1, 0]}, print: false)
        expect(lines.length).to be_between(plot.height - 3, plot.height + 2)

        graph = lines.join("\n")
        expect(graph).to include('test')
        expect(graph).to include('data')

        # Make sure no colors got mangled by later color replacements
        expect(graph.gsub(/\e\[[0-9;]*[A-Za-z]/, '')).not_to match(/[\[;]/)
      end

      it 'can plot to the terminal' do
        begin
          orig_stdout = $stdout
          buf = String.new(encoding: 'UTF-8')
          strio = StringIO.new(buf)

          plot = MB::Sound::Plot.terminal

          $stdout = strio
          plot.plot({test: [-1, 0, 1, 0, -1], data: [1, 0, 1, 0, 1, 0]})
          $stdout = orig_stdout

          expect(buf).to include('test')
          expect(buf).to include('data')

          # Make sure no colors got mangled by later color replacements
          expect(buf.gsub(/\e\[[0-9;]*[A-Za-z]/, '')).not_to match(/[\[;]/)
        ensure
          $stdout = orig_stdout
        end
      end
    end
  end

  pending 'can plot to an image'
end
