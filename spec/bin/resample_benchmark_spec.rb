RSpec.describe('bin/resample_benchmark.rb') do
  it 'runs' do
    text = `bin/resample_benchmark.rb --samples 4800 2>&1`
    expect($?).to be_success
    expect(text).to include('upsampling')
    expect(text).to include('downsampling')
  end
end
