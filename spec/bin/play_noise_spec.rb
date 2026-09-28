require 'benchmark'

RSpec.describe('bin/play_noise.rb') do
  let(:test_sequence) {
    # Each 10x gain increment/decrement line delays by about half a second
    <<-EOF.gsub(/\s+/, '')
    #{'-+' * 10}
    b
    #{'-+' * 10}
    w
    #{'-+' * 10}
    p
    #{'-+' * 10}
    !
    #{'<' * 10}
    #{'>' * 10}
    ~
    #{'-+' * 10}
    w
    #{'-+' * 10}
    q
    EOF
  }

  let(:input_file) { tmp_path('play_noise_test.txt') }

  before(:each) {
    File.write(input_file, test_sequence)
  }

  it 'can play each type of noise via simulated keyboard input' do
    text = nil
    elapsed = Benchmark.realtime do
      text = `OUTPUT_TYPE=null bin/play_noise.rb white -c 7 < #{input_file.shellescape} 2>&1`
    end
    result = ($?)
    text.gsub!("\r", "\n")
    text = MB::Util.remove_ansi(text)

    expect(result).to be_success
    expect(text).to match(/white.*brown.*white.*pink.*power.*wave.*white.*goodbye/mi)
    expect(elapsed).to be > 2
  rescue Exception => e
    puts "FAILED TEXT (#{e.class}): #{text}"
    raise
  end
end
