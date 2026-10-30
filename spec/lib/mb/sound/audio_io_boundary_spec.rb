require_relative '../../../support/boundary_check'

# The audio and MIDI I/O layer as a possible gem ("mb-audio-io";
# tests-gems.md B2/B3, the maintainer's D4 = option 2 on 2026-10-30: a
# guard first, nothing moved).  Its C (fast_audio with miniaudio and the
# JACK client, fast_midi with RtMidi) includes nothing from mb-sound; MIDI's
# I/O comes along because JACK MIDI shares the audio client (one client per
# process).  The Ruby reads the mb-sound names in ADAPTERS today; any other
# crossing fails here (spec/support/boundary_check.rb has the rules).
module AudioIOBoundary
  FILES = (
    %w[array_input background_output concealment device_input device_output exit_close ffmpeg_input ffmpeg_output
       input_buffer_wrapper output_buffer_wrapper io_base io_input io_output jack null_input null_output].map { |f| "mb/sound/#{f}.rb" } +
    %w[event source file_source live_source input output virtual_input midi_file control_map realtime_reader tempo_map].map { |f| "mb/sound/midi/#{f}.rb" }
  ).freeze

  EXT_DIRS = %w[ext/mb/sound/fast_audio ext/mb/sound/fast_midi].freeze

  # Libraries the files may require (the standard library and gems).
  REQUIRES = %w[set json shellwords forwardable tempfile builder midilib].freeze
  # Constants of those libraries, loaded only when used.
  EXTERNAL = %w[Builder].freeze

  # The crossings of today, by what an extraction would do with them.
  ADAPTERS = {
    'inputs are graph nodes: a gem would give plain readers, mb-sound would wrap them in nodes' => [
      'mb/sound/array_input.rb: GraphNode', 'mb/sound/array_input.rb: GraphNode::IOSampleMixin',
      'mb/sound/device_input.rb: GraphNode', 'mb/sound/device_input.rb: GraphNode::IOSampleMixin',
      'mb/sound/input_buffer_wrapper.rb: GraphNode', 'mb/sound/input_buffer_wrapper.rb: GraphNode::IOSampleMixin',
      'mb/sound/io_input.rb: GraphNode', 'mb/sound/io_input.rb: GraphNode::IOSampleMixin',
      'mb/sound/null_input.rb: GraphNode', 'mb/sound/null_input.rb: GraphNode::IOSampleMixin',
      'mb/sound/output_buffer_wrapper.rb: GraphNode', 'mb/sound/output_buffer_wrapper.rb: GraphNode::IOSampleMixin',
      'mb/sound/midi/source.rb: GraphNode::Nameable', 'mb/sound/midi/source.rb: GraphNode::Traversable',
    ],
    'small value and buffer types the gem would take along or replace' => [
      'mb/sound/input_buffer_wrapper.rb: CircularBuffer', 'mb/sound/output_buffer_wrapper.rb: CircularBuffer',
      'mb/sound/concealment.rb: Length::Samples', 'mb/sound/midi/live_source.rb: Length',
    ],
    "mb-sound's Internal helpers (quiet_stderr and friends)" => [
      'mb/sound/device_output.rb: Internal', 'mb/sound/midi/input.rb: Internal',
    ],
    'MIDI parts that stay in mb-sound (events transposed by transforms, note lists, streams, Param-based control specs)' => [
      'mb/sound/midi/event.rb: Transform::Steps', 'mb/sound/midi/event.rb: Transform::Transpose',
      'mb/sound/midi/file_source.rb: NoteList', 'mb/sound/midi/midi_file.rb: NoteList',
      'mb/sound/midi/realtime_reader.rb: Stream', 'mb/sound/midi/control_map.rb: ControlSpec',
    ],
  }.freeze

  def self.crossings(files = FILES) = BoundaryCheck.crossings(files, ext_dirs: EXT_DIRS, requires: REQUIRES, external: EXTERNAL)
end

RSpec.describe('audio and MIDI I/O boundary') do
  it 'reads only the mb-sound names listed in ADAPTERS' do
    found = AudioIOBoundary.crossings
    listed = AudioIOBoundary::ADAPTERS.values.flatten
    new_ones = found.reject { |c| listed.include?(c.key) }
    gone = listed - found.map(&:key)
    expect(new_ones.map(&:to_s)).to eq([]), "the audio/MIDI I/O layer reaches into mb-sound (add an adapter on mb-sound's side, or list it in ADAPTERS with what an extraction would do):\n#{new_ones.join("\n")}"
    expect(gone).to eq([]), "ADAPTERS lists crossings that are gone; remove them:\n#{gone.join("\n")}"
  end

  it "keeps its C free of mb-sound's shared headers" do
    sources = AudioIOBoundary::EXT_DIRS.flat_map { |d| Dir[File.join(BoundaryCheck::ROOT, d, '**', '*.{c,h}')] }
    expect(sources.length).to be > 3
    shared = sources.select { |f| File.read(f, encoding: 'binary').match?(/#include\s+"[^"]*(mb_ext_helpers|\.\.\/include\/)/) }
    expect(shared.map { |f| f.delete_prefix("#{BoundaryCheck::ROOT}/") }).to eq([])
  end

  it 'would catch a new reference to mb-sound' do
    path = tmp_path('io_probe.rb')
    File.write(path, "module MB; module Sound; class DeviceOutput; def f = Session.current || MB::Sound.live_error(x); end; end; end\n")
    found = AudioIOBoundary.crossings(AudioIOBoundary::FILES + [path]).select { |c| c.file.end_with?('io_probe.rb') }
    expect(found.map(&:name)).to contain_exactly('Session', 'MB::Sound.live_error')
  end
end
