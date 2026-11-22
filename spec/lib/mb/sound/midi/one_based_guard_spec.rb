# Guard (midi-one-based-1, the maintainer's 2026-11-22 "yes" to MIDI
# channels and programs counted from 1 everywhere a person types or sees
# them): every method in MB::Sound with a parameter named channel,
# program, or bank (or channels, in the MIDI layers) is either checked
# here to refuse 0 with the "count from 1" hint (and to take 1), or listed
# in ALLOWED with the reason it isn't a user-facing MIDI number.  A new
# method taking a MIDI channel fails this spec until it is one or the
# other, so a 0-based argument can't come back unnoticed.  The help topics,
# the bin/ scripts, and the doc comments of the checked methods must not
# describe channels or programs as counted from 0.
require 'set'
require_relative '../../../../support/midi_writer'
require 'mb/sound/help'

module OneBasedGuard
  NAMES = %i[channel program bank].freeze
  # (channels also names audio channel counts everywhere; only these
  # namespaces' channels are MIDI channel filters)
  MIDI_SPACES = /\AMB::Sound::(MIDI|Notes|Sequence|MidiMethods|RecordMethods|Arrangement::Recording)\b/

  # [owner#method, param] => why it isn't a user-facing MIDI number
  WIRE = 'the wire level: MIDI::Event fields, constructors, and #with_channel stay 0-based (the status nibble)'
  INTERNAL = 'internal: given the wire\'s 0-based channel after a user-facing method converted it (MIDI::Channel.of)'
  AUDIO = 'an audio channel index or count, not a MIDI channel'
  ALLOWED = {
    'MB::Sound::MIDI::Event#initialize(channel)' => WIRE,
    'MB::Sound::MIDI::Event#with_channel(channel)' => WIRE,
    'MB::Sound::MIDI::Event.bend(channel)' => WIRE,
    'MB::Sound::MIDI::Event.cc(channel)' => WIRE,
    'MB::Sound::MIDI::Event.cc_raw(channel)' => WIRE,
    'MB::Sound::MIDI::Event.channel_pressure(channel)' => WIRE,
    'MB::Sound::MIDI::Event.choke(channel)' => WIRE,
    'MB::Sound::MIDI::Event.glide(channel)' => WIRE,
    'MB::Sound::MIDI::Event.note_bytes(channel)' => WIRE,
    'MB::Sound::MIDI::Event.note_off(channel)' => WIRE,
    'MB::Sound::MIDI::Event.note_on(channel)' => WIRE,
    'MB::Sound::MIDI::Event.poly_pressure(channel)' => WIRE,
    'MB::Sound::MIDI::Event.program(channel)' => WIRE,
    'MB::Sound::MIDI::Event.program(program)' => WIRE,
    'MB::Sound::MIDI::VirtualInput#note_on(channel)' => "#{WIRE}; sends Events for the on-screen keyboard and live keys",
    'MB::Sound::MIDI::VirtualInput#note_off(channel)' => "#{WIRE}; sends Events for the on-screen keyboard and live keys",
    'MB::Sound::MIDI::VirtualInput#cc(channel)' => "#{WIRE}; sends Events for the on-screen keyboard and live keys",
    'MB::Sound::UI::Keyboard#initialize(channel)' => 'the on-screen keyboard\'s internal channel; its pane and #inspect show it counted from 1',
    'MB::Sound::UI::Keyboard::Link#note_on(channel)' => 'the on-screen keyboard\'s VirtualInput (wire level)',
    'MB::Sound::UI::Keyboard::Link#note_off(channel)' => 'the on-screen keyboard\'s VirtualInput (wire level)',
    'MB::Sound::UI::Keyboard::Link#cc(channel)' => 'the on-screen keyboard\'s VirtualInput (wire level)',
    'MB::Sound::MIDI::ClipSource#initialize(channel)' => "#{INTERNAL} (Clip#stream)",
    'MB::Sound::MIDI::Capture.clip(channel)' => "#{INTERNAL} (rec, capture)",
    'MB::Sound::Sequence::ControlLane.from_events(channel)' => INTERNAL,
    'MB::Sound::Sequence::ControlLane#event(channel)' => INTERNAL,
    'MB::Sound::Sequence::ControlLane#setup_events(channel)' => INTERNAL,
    'MB::Sound::MIDI::Import#select_channel(channel)' => "#{INTERNAL} (midi_clip)",
    'MB::Sound::MIDI::NoteList.stats(channel)' => "#{INTERNAL} (FileSource#note_stats)",
    'MB::Sound::MIDI::Output::NoteBalancer#held?(channel)' => INTERNAL,
    'MB::Sound::MIDI::Param.session_cc(channel)' => "#{INTERNAL} (cc)",
    'MB::Sound::MIDI::Param::Reading#cc(channel)' => "#{INTERNAL} (cc)",
    'MB::Sound::Session::MidiInput#cc_at(channel)' => "#{INTERNAL} (cc)",
    'MB::Sound::MIDI::Allocator#choke_channel(channel)' => INTERNAL,
    'MB::Sound::MIDI::Allocator#forget_channel(channel)' => INTERNAL,
    'MB::Sound::MIDI::Allocator#mono_clear(channel)' => INTERNAL,
    'MB::Sound::MIDI::Allocator#release_channel(channel)' => INTERNAL,
    'MB::Sound::Arrangement::Recording#capture_into(channel)' => "#{INTERNAL} (rec, capture)",
    'MB::Sound::Arrangement::Recording#recording_channel(channel)' => 'the conversion itself (MIDI::Channel.of_optional)',
    'MB::Sound::MIDI::Destination#panic(channels)' => 'nil or :all, never a number',
    'MB::Sound::MIDI::Destination#initialize(bank)' => 'bank select bytes (CC 0 and 32 data, 0..127), shown as such by synths',
    'MB::Sound::MIDI::Destination.check_bank(bank)' => 'bank select bytes (CC 0 and 32 data, 0..127), shown as such by synths',
    'MB::Sound::MidiOutMethods#midi_out(bank)' => 'bank select bytes (CC 0 and 32 data, 0..127), shown as such by synths',
    'MB::Sound::Sampler::SF2::Font#[](program)' => 'SoundFont preset numbers are the file\'s own, counted from 0 as SoundFont editors show them (an open question for the maintainer)',
    'MB::Sound::GraphNode::FilterBank#response(channel)' => AUDIO,
    'MB::Sound::GraphNode::InputChannelSplit#internal_sample(channel)' => AUDIO,
    'MB::Sound::Synth#sum_into(channel)' => AUDIO,
    'MB::Sound::Sample::Spectral::Stream#pull(channel)' => AUDIO,
    'MB::Sound::GraphNode::InputChannelSplit::InputChannelNode#initialize(channel)' => AUDIO,
    'MB::Sound::GraphNode::RegionPlayer#initialize(channel)' => AUDIO,
    'MB::Sound::GraphNode::LoopPlayer#initialize(channel)' => AUDIO,
    'MB::Sound::GraphNode::SamplerVoice#initialize(channel)' => AUDIO,
    'MB::Sound::Notes::Aftertouch#initialize(channel)' => 'the channel pressure node it reads, not a channel number',
    'MB::Sound::GraphNode::FilterBank::Router#initialize(bank)' => 'a filter bank',
    'MB::Sound::Plan::Builder#filter_bank(bank)' => 'a filter bank',
    'MB::Sound::Plan::Op::FilterBank#initialize(bank)' => 'a filter bank',
    'MB::Sound::GraphNode::Dynamics::Crossover.process_ruby(program)' => 'a filter program, not a MIDI program',
    'MB::Sound::Plan::Program::Lowering#initialize(program)' => 'a plan program, not a MIDI program',
    'MB::Sound::Plan::ScaleMatch.core(program)' => 'a plan program, not a MIDI program',
    'MB::Sound::Plan::ScaleMatch.pad(program)' => 'a plan program, not a MIDI program',
  }.freeze

  ZERO_BASED = /\b(0-based|zero-based|counts? from 0)\b|\bchannels? 0\s*(\.\.|to)\s*15\b|\bprograms? 0\s*(\.\.|to)\s*127\b|\bchannel 0\b/i

  # Runs a recording command on a fresh non-realtime Session with a
  # track to record into, then closes it.  (A capture of nothing played
  # raises "Nothing played" after the channel check: that counts as taking
  # the channel.)
  module RecGuard
    def self.call
      s = MB::Sound::Session.new(realtime: false)
      MB::Sound::Session.with_context(session: s) do
        MB::Sound.track(:rec_guard) { |c| c.synth { |v| v.gate * 0.0 } }
        yield s
      rescue ArgumentError => e
        raise unless e.message.include?('Nothing played')
      end
    ensure
      s&.close
      MB::Sound.rewind
    end
  end

  # Every [owner#method, param] in MB::Sound with a guarded parameter name,
  # looking through prepended wrappers (*args) to the method they wrap.
  def self.guarded_params
    out = {}
    ObjectSpace.each_object(Module).select { |m| m.name&.start_with?('MB::Sound') }.each do |m|
      list = (m.public_instance_methods(false) + m.private_instance_methods(false) + m.protected_instance_methods(false)).map { |n| ['#', n, m.instance_method(n)] }
      list += m.singleton_methods(false).map { |n| ['.', n, m.method(n).unbind] }
      list.each do |sep, name, um|
        chain = []
        while um
          chain << um
          um = um.super_method
        end
        chain.each do |u|
          owner = u.owner
          next if owner.name.nil? && !owner.singleton_class?
          oname = owner.singleton_class? ? owner.attached_object.name : owner.name
          next unless oname&.start_with?('MB::Sound')
          s = owner.singleton_class? ? '.' : sep
          u.parameters.each do |_, p|
            next unless NAMES.include?(p) || (p == :channels && oname.match?(MIDI_SPACES))
            out["#{oname}#{s}#{name}(#{p})"] = u.source_location&.join(':')
          end
        end
      end
    end
    out
  end

end

RSpec.describe('MIDI channels and programs count from 1 (guard)', :aggregate_failures) do
  # [owner#method, param] => ->(n) { a call passing n }: must raise for 0
  # with the hint and take 1.
  def checked
    clip = MB::Sound.seq(MB::Sound::C4).n4
    path = nil
    file = -> { path ||= MidiWriter.write(tmp_path('one.mid'), tracks: [{ channel: 0, notes: [[0, 480, 60, 100]] }]) }
    {
      'MB::Sound::MidiMethods#cc(channel)' => ->(n) { MB::Sound.cc(1, channel: n) },
      'MB::Sound::MIDI::Param::CC#initialize(channel)' => ->(n) { MB::Sound::MIDI::Param::CC.new(1, channel: n) },
      'MB::Sound::MidiMethods#midi_clip(channel)' => ->(n) { MB::Sound.midi_clip(file.call, channel: n) },
      'MB::Sound::MIDI::Import#clip(channel)' => ->(n) { MB::Sound::MIDI::Import.new(file.call).clip(channel: n) },
      'MB::Sound::MIDI::FileSource#note_stats(channel)' => ->(n) { MB::Sound::MIDI::FileSource.new(file.call).note_stats(channel: n) },
      'MB::Sound::Note#to_midi(channel)' => ->(n) { MB::Sound::C4.to_midi(channel: n) },
      'MB::Sound::Pitch#to_midi(channel)' => ->(n) { 440.hz.to_midi(channel: n) },
      'MB::Sound::Tone#to_midi(channel)' => ->(n) { 440.hz.sine.to_midi(channel: n) },
      'MB::Sound::Sequence::Clip#stream(channel)' => ->(n) { clip.stream(channel: n) },
      'MB::Sound::MIDI::Stream#channel(channels)' => ->(n) { clip.stream.channel(n) },
      'MB::Sound::MIDI::Transform::Channel#initialize(channels)' => ->(n) { clip.stream.channel([n]) },
      'MB::Sound::MIDI::Transform::Rechannel#initialize(channel)' => ->(n) { clip.stream.rechannel(n) },
      'MB::Sound::MIDI::Stream#rechannel(channel)' => ->(n) { clip.stream.rechannel(n) },
      'MB::Sound::MIDI::Stream#to_channel(channel)' => ->(n) { clip.stream.to_channel(n) },
      'MB::Sound::MidiOutMethods#midi_out(channel)' => ->(n) { MB::Sound.midi_out(channel: n, log: true) },
      'MB::Sound::MidiOutMethods#midi_out(program)' => ->(n) { MB::Sound.midi_out(program: n, log: true) },
      'MB::Sound::MIDI::Destination#initialize(channel)' => ->(n) { MB::Sound::MIDI::Destination.new(channel: n, log: true) },
      'MB::Sound::MIDI::Destination#initialize(program)' => ->(n) { MB::Sound::MIDI::Destination.new(program: n, log: true) },
      'MB::Sound::MIDI::Destination.check_channel(channel)' => ->(n) { MB::Sound::MIDI::Destination.check_channel(n) },
      'MB::Sound::MIDI::Destination.check_program(program)' => ->(n) { MB::Sound::MIDI::Destination.check_program(n) },
      'MB::Sound::SQ80::SysEx.dump(channel)' => ->(n) { MB::Sound::SQ80::SysEx.dump([MB::Sound::SQ80::Program.init], channel: n) },
      'MB::Sound::SQ80::SysEx#dump(channel)' => ->(n) { MB::Sound::SQ80::SysEx.dump([MB::Sound::SQ80::Program.init], channel: n) },
      'MB::Sound::SQ80::SysEx.write(channel)' => ->(n) { MB::Sound::SQ80::SysEx.write(tmp_path('guard.syx'), [MB::Sound::SQ80::Program.init], channel: n) },
      'MB::Sound::SQ80::SysEx#write(channel)' => ->(n) { MB::Sound::SQ80::SysEx.write(tmp_path('guard.syx'), [MB::Sound::SQ80::Program.init], channel: n) },
      'MB::Sound::SQ80::SysEx.request(channel)' => ->(n) { MB::Sound::SQ80::SysEx.request(:program, channel: n) },
      'MB::Sound::SQ80::SysEx#request(channel)' => ->(n) { MB::Sound::SQ80::SysEx.request(:program, channel: n) },
      'MB::Sound::RecordMethods#rec(channel)' => ->(n) { OneBasedGuard::RecGuard.call { MB::Sound.rec(1, :rec_guard, channel: n) } },
      'MB::Sound::RecordMethods#record(channel)' => ->(n) { OneBasedGuard::RecGuard.call { MB::Sound.record(1, :rec_guard, channel: n) } },
      'MB::Sound::RecordMethods#capture(channel)' => ->(n) { OneBasedGuard::RecGuard.call { MB::Sound.capture(:rec_guard, length: 1, channel: n) } },
      'MB::Sound::RecordMethods#capture_midi(channel)' => ->(n) { OneBasedGuard::RecGuard.call { MB::Sound.capture_midi(:rec_guard, length: 1, channel: n) } },
      'MB::Sound::Arrangement::Recording#record(channel)' => ->(n) { OneBasedGuard::RecGuard.call { |s| s.arrangement.record(1, :rec_guard, channel: n) } },
      'MB::Sound::Arrangement::Recording#capture(channel)' => ->(n) { OneBasedGuard::RecGuard.call { |s| s.arrangement.capture(:rec_guard, length: 1, channel: n) } },
    }
  end

  it 'lists every channel, program, and bank parameter as checked or allowed with a reason' do
    found = OneBasedGuard.guarded_params
    known = checked.keys + OneBasedGuard::ALLOWED.keys
    missing = found.keys - known
    expect(missing).to be_empty, "Methods taking a MIDI channel, program, or bank must count from 1 (MIDI::Channel.of; add them to checked) or be ALLOWED with a reason:\n#{missing.map { |k| "  #{k} #{found[k]}" }.join("\n")}"
    stale = known - found.keys
    expect(stale).to be_empty, "Entries for methods that no longer take that parameter:\n  #{stale.join("\n  ")}"
  end

  it 'refuses 0 with the count-from-1 hint and takes 1 in every checked method' do
    allow(MB::Sound).to receive(:attach_live_midi) # (recordings read no live input here)
    checked.each do |key, call|
      expect { call.call(0) }.to raise_error(ArgumentError, /count from 1/), "#{key} should refuse 0"
      begin
        call.call(1)
      rescue StandardError => e
        raise "#{key} should take 1, raised #{e.class}: #{e.message}"
      end
      if key.end_with?('(program)')
        expect { call.call(129) }.to raise_error(ArgumentError, /1 to 128/), "#{key} should refuse 129"
      else
        expect { call.call(17) }.to raise_error(ArgumentError, /1 to 16/), "#{key} should refuse 17"
      end
    end
  end

  it 'never describes channels or programs as counted from 0 in help topics, bin/ scripts, or the checked methods\' doc comments' do
    MB::Sound::Help.index
    texts = MB::Sound::Help::TOPICS.values.map { |t| ["help :#{t.name}", t.about] }
    texts += Dir['bin/**/*.rb'].map { |f| [f, File.read(f)] }
    found = OneBasedGuard.guarded_params
    checked.each_key do |key|
      file, line = found[key]&.split(':')
      next unless file && File.exist?(file)
      lines = File.readlines(file)
      doc = []
      i = line.to_i - 2
      while i >= 0 && lines[i] =~ /\A\s*#/
        doc.unshift(lines[i])
        i -= 1
      end
      texts << ["#{key}'s doc comment", doc.join]
    end
    bad = texts.flat_map { |where, text|
      text.split(/(?<=[.!?])\s+|\n/).select { |l| l.match?(/channel|program/i) && l.match?(OneBasedGuard::ZERO_BASED) && !l.match?(/soundfont|preset|wire|Event#channel|byte|raises|refuse/i) }.map { |l| "#{where}: #{l.strip}" }
    }
    expect(bad).to be_empty, "MIDI channels and programs count from 1 for people (say \"the wire's 0-based number\" where the wire is meant):\n  #{bad.join("\n  ")}"
  end

  it 'says once, in each MIDI help topic, that channels count from 1' do
    MB::Sound::Help.index
    %i[midi midi_files midi_out wire].each do |t|
      expect(MB::Sound::Help::TOPICS.fetch(t).about).to match(/count from 1/), "help :#{t}"
    end
    expect(MB::Sound::Help::TOPICS.fetch(:soundfonts).about).to match(/counted from 0 as SoundFont editors show them/)
  end
end
