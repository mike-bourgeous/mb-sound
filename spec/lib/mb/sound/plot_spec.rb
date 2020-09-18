require 'fileutils'

RSpec.describe MB::Sound::Plot do
  describe '#plot' do
    context 'with the dumb terminal type' do
      it 'can plot to an array of lines' do
        begin
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
        ensure
          plot&.close
        end
      end

      it 'can plot to the terminal' do
        begin
          plot = MB::Sound::Plot.terminal

          orig_stdout = $stdout
          buf = String.new(encoding: 'UTF-8')
          strio = StringIO.new(buf)

          $stdout = strio
          plot.plot({test: [-1, 0, 1, 0, -1], data: [1, 0, 1, 0, 1, 0]})
          $stdout = orig_stdout

          expect(buf).to include('test')
          expect(buf).to include('data')

          # Make sure no colors got mangled by later color replacements
          expect(buf.gsub(/\e\[[0-9;]*[A-Za-z]/, '')).not_to match(/[\[;]/)
        ensure
          $stdout = orig_stdout
          plot&.close
        end
      end

      pending 'rows and columns'
    end

    ['png', 'svg'].each do |t|
      it "can plot to a/an #{t} image" do
        name = "tmp/plot_test.#{t}"

        FileUtils.mkdir_p('tmp')
        File.unlink(name) rescue nil

        plot = MB::Sound::Plot.new
        plot.save_image(name, width: 768, height: 317)
        plot.plot({test123: [-1, 0, 1, 0, -1], data321: [1, 0, 1, 0, 1, 0]})
        plot.close

        expect(File.readable?(name)).to eq(true)

        info = MB::Sound::FFMPEGInput.parse_info(name, audio_only: false)
        expect(info[:streams][0][:width]).to eq(768)
        expect(info[:streams][0][:height]).to eq(317)
        expect(info[:format][:format_name]).to include(t)

        if t == 'svg'
          svg = File.read(name)
          expect(svg).to include('test123')
          expect(svg).to include('data321')
        end
      end
    end
  end
end
