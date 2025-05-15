RSpec.describe('bin/resample_benchmark.rb') do
  it 'runs' do
    text = `SAMPLES=48000 bin/resample_benchmark.rb`
    expect($?).to be_success
    expect(text).to include('upsampling')
    expect(text).to include('downsampling')
  end
end
