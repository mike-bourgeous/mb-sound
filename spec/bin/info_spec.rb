RSpec.describe('bin/info.rb') do
  it 'can print help' do
    expect(MB::U.remove_ansi(`bin/info.rb --help`)).to include('bin/info.rb filename')
    expect($?).not_to be_success
  end

  it 'can parse a FLAC file' do
    expect(MB::U.remove_ansi(`bin/info.rb sounds/piano0.flac`)).to include(/sample_rate.*48000/)
    expect($?).to be_success
  end
end
