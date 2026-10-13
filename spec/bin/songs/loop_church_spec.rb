RSpec.describe('bin/songs/loop_church.rb') do
  before(:all) { require File.expand_path('../../../bin/songs/loop_church.rb', __dir__) }

  around do |ex|
    old = ENV['LOOP_CHURCH_AUDIO']
    ENV['LOOP_CHURCH_AUDIO'] = tmp_path('rec_audio.flac') # (rec_audio of the master bus)
    ex.run
  ensure
    old ? ENV['LOOP_CHURCH_AUDIO'] = old : ENV.delete('LOOP_CHURCH_AUDIO')
  end

  after { MB::Sound.rewind }

  it "writes out the hands' parts: the beat in bars 1-2, the bass from bar 3" do
    hands = MB::Sound.loop_church_hands
    bar = 240.0 / MB::Sound::LOOP_CHURCH_BPM
    expect(hands.keys).to eq([:pads, :left, :right, :lead, :voice])
    first_bass = hands[:left].select(&:note_on?).map(&:time).min
    expect(first_bass).to be_within(0.02).of(2 * bar)
    expect(hands[:pads].select(&:note_on?).map(&:time).min).to be < 0.01
  end

  it 'records the beat with the looper and plays it back from bar 3, under the limiter' do
    path = tmp_path('lc.flac')
    out, status = fork_script('bin/songs/loop_church.rb', '-q', '--bars', '4', '-o', path)
    expect(status).to be_success, out
    data = MB::Sound.read(path)
    bar = (48000 * 240 / MB::Sound::LOOP_CHURCH_BPM.to_f).round
    expect(peak_db(data[0][0...bar])).to be > -20          # the armed beat, monitored
    expect(peak_db(data[0][(2 * bar)...(3 * bar)])).to be > -20 # the loop (and the bass)
    expect(data.map { |c| c.abs.max }.max).to be <= -1.db + 1e-3
    expect(File.size(ENV['LOOP_CHURCH_AUDIO'])).to be > 1000 # rec_audio's copy of the master bus
  end
end
