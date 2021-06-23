RSpec.describe('Noise generation scripts') do
  let(:output) { 'tmp/write_noise_test.flac' }
  let(:out_sound) { MB::Sound.read(output) }

  before(:each) do
    FileUtils.mkdir_p('tmp')
    File.unlink(output) rescue nil
  end

  ['brown', 'pink', 'white'].each do |n|
    describe "bin/write_#{n}_noise.rb" do
      it 'generates a non-silent file' do
        text = `bin/write_#{n}_noise.rb #{output} 1 2401 0.1 2>&1`
        result = ($?)
        expect(result).to be_success
        expect(out_sound.length).to eq(1)
        expect(out_sound[0].length).to eq(4800)
        expect(out_sound[0].min).to be < -0.25
        expect(out_sound[0].max).to be > 0.25

      rescue Exception => e
        puts "FAILED OUTPUT (#{e.class}): #{text}"
        raise
      end

      it 'can generate multiple channels' do
        text = `bin/write_#{n}_noise.rb #{output} 4 2401 0.1 2>&1`
        result = ($?)
        expect(result).to be_success
        expect(out_sound.length).to eq(4)
        out_sound.each do |c|
          expect(c.length).to eq(4800)
          expect(c.min).to be < -0.25
          expect(c.max).to be > 0.25
        end

      rescue Exception => e
        puts "\n\nFAILED OUTPUT (#{e.class}): #{text}\n\n"
        raise
      end
    end
  end
end
