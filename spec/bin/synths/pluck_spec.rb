require 'shellwords'

RSpec.describe('bin/synths/pluck.rb') do
  before(:all) { load File.expand_path('../../../bin/synths/pluck.rb', __dir__) }

  E = MB::Sound::MIDI::Event unless defined?(E)

  def render(events, seconds, **options)
    MB::Sound.seed(0)
    synth = MB::Sound::Synth.new(MB::Sound::MIDI::Stream.new(MIDIListSource.new(*events)), voices: 1) { |v| MB::Sound.pluck_voice(v, **options) }
    out = []
    (seconds * 48000 / 480).round.times { b = synth.sample(480); break if b.nil?; out.concat(b.to_a) }
    Numo::SFloat.cast(out)
  end

  let(:note) { [E.note_on(45, 0.9, time: 0r), E.note_off(45, time: 1r)] }

  it 'renders a MIDI file with the attack, brightness, and glide options' do
    out_file = tmp_path('pluck.flac')
    out = `bin/synths/pluck.rb -q -a 2 -A s -H 9000 -G 0.1 -v 1 spec/test_data/c_major.mid #{out_file.shellescape} 2>&1`
    expect($?).to be_success, out
    expect(File.size(out_file)).to be > 1000
  end

  it 'fades in over --attack periods after the first period' do
    period = (48000 / 110.0).round
    plain = render(note, 0.2)
    faded = render(note, 0.2, attack: 2)
    expect(faded[0...(period - 2)].abs.max).to eq(0)
    expect(faded[period...(2 * period)].abs.max).to be < plain[period...(2 * period)].abs.max * 0.6
    expect((faded[(4 * period)...(5 * period)] - plain[(4 * period)...(5 * period)]).abs.max).to be < 1e-3 * plain.abs.max
  end

  it 'glides legato notes without plucking again' do
    events = [E.note_on(45, 0.9, time: 0r), E.note_on(52, 0.9, time: 1/2r), E.note_off(45, time: 0.55r), E.note_off(52, time: 1r)]
    glide = render(events, 0.8, glide: 0.1)
    pluck = render(events, 0.8)
    before = glide[(0.45 * 48000).round...(0.5 * 48000).round].abs.max
    after = glide[(0.5 * 48000).round...(0.56 * 48000).round].abs.max
    expect(after).to be < before * 1.3
    expect(pluck[(0.5 * 48000).round...(0.56 * 48000).round].abs.max).to be > before * 3
  end
end
