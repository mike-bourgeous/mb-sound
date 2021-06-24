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

  before(:each) {
    FileUtils.mkdir_p('tmp')
    File.unlink('tmp/play_noise_test.txt') rescue nil
    File.write('tmp/play_noise_test.txt', test_sequence)
  }

  it 'can play each type of noise via simulated keyboard input' do
    text = nil
    elapsed = Benchmark.realtime do
      text = `OUTPUT_TYPE=null bin/play_noise.rb white 7 < tmp/play_noise_test.txt 2>&1`
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
