RSpec.describe(MB::Sound::Notes, 'poly pressure') do
  let(:ev) { MB::Sound::MIDI::Event }

  # An Event parsed from raw MIDI bytes at +time+ (seconds).
  def raw(time, *bytes)
    ev.parse(bytes, time: time.to_r)
  end

  # A source of raw byte events, plus a late CC so it doesn't end.
  def source(*events)
    MIDIListSource.new(events, [ev.cc(99, 0, time: 1000r)])
  end

  # Samples +node+ +buffers+ times; returns the concatenated output.
  def run(node, buffers:, buffer: 480)
    buffers.times.map { node.sample(buffer).dup }.reduce(:concatenate)
  end

  # Value at +seconds+.
  def at(data, seconds)
    data[(seconds * 48000).round]
  end

  it 'parses 0xA0 bytes as poly pressure events' do
    e = raw(0, 0xA2, 61, 127)
    expect(e).to have_attributes(type: :poly_pressure, channel: 2, note: 61, value: 1.0, raw: 127)
  end

  describe 'Notes#poly_pressure' do
    it 'follows the newest held note, starting each note at 0 and holding after release' do
      v = MB::Sound::Notes.new(source(
        raw(0.0, 0x90, 60, 100),
        raw(0.01, 0xA0, 60, 64),
        raw(0.02, 0x90, 64, 100),
        raw(0.03, 0xA0, 60, 127),  # the covered note's pressure
        raw(0.04, 0xA0, 64, 32),
        raw(0.05, 0x80, 64, 0),    # uncovers 60
        raw(0.06, 0x80, 60, 0),
      ))
      out = run(v.poly_pressure, buffers: 10)
      expect(at(out, 0.005)).to eq(0)
      expect(at(out, 0.015)).to be_within(1e-6).of(64 / 127.0)
      expect(at(out, 0.025)).to eq(0)
      expect(at(out, 0.035)).to eq(0)
      expect(at(out, 0.045)).to be_within(1e-6).of(32 / 127.0)
      expect(at(out, 0.055)).to eq(1)
      expect(at(out, 0.07)).to eq(1)
    end

    it 'ignores channel pressure, and #aftertouch takes the larger of both' do
      v = MB::Sound::Notes.new(source(
        raw(0.0, 0x90, 60, 100),
        raw(0.01, 0xD0, 50),
        raw(0.02, 0xA0, 60, 100),
        raw(0.03, 0xD0, 120),
      ))
      after = v.aftertouch
      poly = v.poly_pressure.get_sampler
      p_out = []
      a_out = []
      9.times { p_out << poly.sample(480).dup; a_out << after.sample(480).dup }
      p_out = p_out.reduce(:concatenate)
      a_out = a_out.reduce(:concatenate)
      expect(at(p_out, 0.015)).to eq(0)
      expect(at(a_out, 0.015)).to be_within(1e-6).of(50 / 127.0)
      expect(at(a_out, 0.025)).to be_within(1e-6).of(100 / 127.0)
      expect(at(a_out, 0.035)).to be_within(1e-6).of(120 / 127.0)
      expect(v.pressure).to equal(v.channel_pressure)
      expect(v.key_pressure).to equal(v.poly_pressure)
    end
  end

  describe 'in a Synth' do
    it 'gives every lane its own key pressure' do
      events = source(
        raw(0.0, 0x90, 48, 100), raw(0.0, 0x90, 52, 100), raw(0.0, 0x90, 55, 100),
        raw(0.01, 0xA0, 48, 127), raw(0.01, 0xA0, 52, 64),
        raw(0.02, 0xA0, 55, 32), raw(0.02, 0xA0, 48, 0),
        raw(0.02, 0xA0, 60, 100), # not held: goes nowhere
      )
      synth = MB::Sound::Synth.new(events, voices: 3, spares: 0, skip_idle: false) { |v| v.poly_pressure }
      lanes = 6.times.map { synth.sample_individual(480).map(&:dup) }.transpose.map { |l| l.reduce(:concatenate) }
      values = ->(t) { lanes.map { |l| at(l, t).round(4) }.sort }
      expect(values.(0.005)).to eq([0, 0, 0])
      expect(values.(0.015)).to eq([0, (64 / 127.0).round(4), 1.0].sort)
      expect(values.(0.025)).to eq([0, (32 / 127.0).round(4), (64 / 127.0).round(4)].sort)
    end

    it 'routes raw bytes from a live input through the Allocator' do
      input = Class.new {
        attr_accessor :queue
        def initialize = @queue = []
        def read_raw = @queue.tap { @queue = [] }
        def frame_times? = false
        def frame_rate = nil
        def close; end
        def closed? = false
      }.new
      src = MB::Sound::MIDI::LiveSource.new(input, timing: :asap)
      synth = MB::Sound::Synth.new(MB::Sound::MIDI::Stream.new(src), voices: 2, spares: 0, skip_idle: false) { |v| v.poly_pressure * 1 }
      input.queue = [[0.0, [0x90, 60, 100].pack('C*')], [0.0, [0x90, 67, 100].pack('C*')]]
      synth.sample_individual(480)
      input.queue = [[0.001, [0xA0, 67, 127].pack('C*')]]
      out = synth.sample_individual(480).map { |b| b[-1].round(4) }
      expect(out.sort).to eq([0.0, 1.0])
      input.queue = [[0.001, [0xA0, 60, 64].pack('C*')]]
      out = synth.sample_individual(480).map { |b| b[-1].round(4) }
      expect(out.sort).to eq([(64 / 127.0).round(4), 1.0])
    end

    it 'plays a MIDI file with poly pressure on each key of a chord' do
      # spec/test_data/poly_chord.mid (make_poly_chord.rb), 120 BPM: over
      # the first two bars C4 presses in, E4 later, and G4 pulses
      synth = MB::Sound::Synth.new('spec/test_data/poly_chord.mid', voices: 4, skip_idle: false) { |v| v.poly_pressure }
      lanes = 340.times.map { synth.sample_individual(480).map(&:dup) }.transpose.map { |l| l.reduce(:concatenate) }
      values = ->(t) { lanes.map { |l| at(l, t) }.sort }
      expect(values.(1.5).count { |v| v > 0 }).to eq(2)    # C4 and G4, not E4
      expect(values.(1.5)[-2]).to be_within(0.03).of(0.57) # G4
      expect(values.(1.5)[-1]).to be_within(0.03).of(0.875) # C4
      expect(values.(3.2).count { |v| v > 0.9 }).to eq(2)  # C4 and E4
    end
  end

  describe 'controls' do
    it 'lists poly pressure in control maps but leaves it out of ACID XML' do
      spec = MB::Sound::MIDI::ControlSpec.poly_pressure
      expect(spec).to have_attributes(type: :poly_pressure, number: nil, name: 'Poly Aftertouch', status: 0xa0)
      v = MB::Sound::Notes.new(source(raw(0, 0x90, 60, 1)))
      v.poly_pressure
      v.mod
      expect(v.controls.types).to eq([:cc, :poly_pressure])
      xml = v.controls.to_acid_xml(name: 'x')
      expect(xml).to include(%Q{params="#{v.controls.groups.length - 1}"})
      expect(xml).not_to include('Poly')
    end

    it 'gives #aftertouch both pressure specs' do
      v = MB::Sound::Notes.new(source(raw(0, 0x90, 60, 1)))
      map = MB::Sound::MIDI::ControlMap.new(v.aftertouch)
      expect(map.types).to eq([:poly_pressure, :pressure])
    end
  end
end
