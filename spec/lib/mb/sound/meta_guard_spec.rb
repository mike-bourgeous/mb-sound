# The metadata guard (metadata-2; the maintainer, 2026-11-11: "Try to
# guard against metadata becoming interpreted as data, as is always the
# risk").  Metadata describes; it never decides: nothing in lib/ may read
# it to choose what plays, how a graph builds, what a lookup finds, or what
# a loader constructs (design/notes/metadata.md, "Metadata never acts as
# data").
#
# A static scan over lib/ with Prism: every call that reads metadata
# (`x.meta`, `meta`, `.metadata`, `.carried_meta`, `.meta_source`) and
# every read of `@carried_meta` outside lib/mb/sound/meta.rb must sit in a
# file of ALLOWED, each with its reason (printers and summaries, writers
# and readers of formats, the inspector and help, importers writing it).
# Even there, no read may sit in a render, plan, build, or lookup method
# (FORBIDDEN_DEFS), and no file of FORBIDDEN_PATHS (the plan layer, the DSL
# method modules, the loader, the library's search and resolution,
# Session names) may read it at all.
#
# A new read fails here: show it (a printer goes in ALLOWED with its
# reason), or, if code needs the fact to decide something, make the fact
# data with its own reader (a Document#header key, an Entry field, a node
# setting) and keep the description in metadata.
#
# Layer-aware (round 2's layers, design/notes/metadata.md): raw facts
# (MB::Sound::Facts readers, `facts`, MIDIFile#meta_events, Riff.read and
# friends) may be read only by interpreters and readers (ALLOWED_RAW, per
# method); typed data anywhere; description and provenance (`meta`,
# `meta_source`, `provenance`, `why`, ...) only by printers, writers, and
# interpreters recording it (ALLOWED).
require 'prism'

module MetaGuard
  ROOT = File.expand_path('../../../..', __dir__)

  # Calls that read an object's metadata.  (`metadata` also names other
  # things' file tags, FFMPEGInput#metadata and Wavetable#metadata: those
  # reads are listed below with that reason, so every reader of the name
  # stays visible.)
  # (Provenance is description too: `provenance` and `why`.  `why` also
  # names other things' reasons, listed below as such.)
  READS = %i[meta metadata carried_meta meta_source provenance why].freeze

  # Calls that read the raw layer: Facts (`facts`, `Facts.of_*`), a MIDI
  # file's meta events, and the WAV chunk reader (`Riff.read`, `read!`,
  # `parse`, `chunk`).
  RAW_CALLS = %i[facts meta_events].freeze
  RAW_RECEIVERS = { 'Facts' => /\Aof_/, 'Riff' => /\A(read!?|parse|chunk)\z/ }.freeze

  # Interpreters and readers: the only methods that may read raw facts,
  # with why.
  ALLOWED_RAW = {
    'lib/mb/sound/sample.rb' => ['Sample.loop_metadata interprets a loop file (offsets for provenance)', %i[loop_metadata]],
    'lib/mb/sound/sample/source.rb' => ['the facts of a sound file, for Facts.interpret', %i[file_facts]],
    'lib/mb/sound/sample/loop_info.rb' => ['LoopInfo, the loop file interpreter, reads WAV chunks (and those FLAC keeps)', %i[read from_flac]],
    'lib/mb/sound/meta/formats.rb' => ['the format readers and writers', %i[append_wav read_sidecar read_wav read_midi]],
    'lib/mb/sound/sampler/sf2.rb' => ['the SoundFont INFO list\'s facts, interpreted into Font#name and description', %i[meta]],
    'lib/mb/sound/graph_io/document.rb' => ['the graph line\'s facts, interpreted into #header and #meta', %i[read_graph_line]],
  }.freeze

  # Files that may read metadata, with why (and what they do with it):
  # a reason alone for files whose every method shows or writes metadata,
  # else [reason, methods] naming the only methods that may read it (a
  # new reader in a file of data code, such as a Sample method deciding
  # something from meta, fails even though the file reads metadata
  # elsewhere).
  ALLOWED = {
    'lib/mb/sound/meta.rb' => 'the metadata module itself (Carrier, Store, summaries, statements)',
    'lib/mb/sound/meta_methods.rb' => 'console commands that show and add metadata (meta, metas)',
    'lib/mb/sound/help/now.rb' => '`now` shows one line about the set\'s metadata',
    'lib/mb/sound/help/content/topics.rb' => 'help :meta examples',
    'lib/mb/sound/graph_io/set_writer.rb' => 'set documents write the `meta` lines',
    'lib/mb/sound/sample/source.rb' => ['Sample#with_meta/#note make copies with more metadata; #tags writes :source as the mb_sample_source tag', %i[with_meta note tags]],
    'lib/mb/sound/sample.rb' => ['#save writes the metadata into the file; #summary prints it and the provenance; loop_metadata and detect_tempo/detect_key record provenance (interpreters); #follow names its material\'s reason (Material#why, another thing\'s why) in a message', %i[save summary loop_metadata detect_tempo detect_key follow]],
    'lib/mb/sound/sample/loop_info.rb' => ['LoopInfo::Entry#reason prints its reasons; .detected records a detected key\'s reason', %i[reason detected]],
    'lib/mb/sound/provenance.rb' => 'Provenance itself (its readers and printer)',
    'lib/mb/sound/graph_io/document.rb' => ['the graph line\'s interpreters record provenance', %i[read_graph_line]],
    'lib/mb/sound/analysis/perceived_pitch.rb' => ['a pitch candidate\'s reason in its printer (another thing named why)', %i[to_s]],
    'lib/mb/sound/graph_io.rb' => ['GraphIO.header_split: the descriptive metadata a save writes again', %i[header_split]],
    'lib/mb/sound/library.rb' => ['an Entry carries its document\'s description as Entry#meta (copied, never searched); gem shelves read gemspec metadata (a gem\'s own declaration of its shelf, not mb-sound metadata)', %i[document_entry gem_shelves]],
    'lib/mb/sound/library/saving.rb' => ['a replacing save keeps the old document\'s descriptive metadata', %i[save]],
    'lib/mb/sound/take.rb' => ['takes write their metadata as the replay\'s meta:', %i[to_ruby replay]],
    'lib/mb/sound/graph_io/comments.rb' => ['a document\'s comments become notes, and the writer asks which notes to print as comments', %i[args notes_of args_of]],
    'lib/mb/sound/ui/inspect.rb' => ['the inspector shows a node\'s notes (quoted: Meta.notes_text)', %i[notes_of]],
    # (other things named meta or metadata)
    'lib/mb/sound/io_methods.rb' => ['MB::Sound.read hands back an FFMPEGInput\'s file tags (not mb-sound metadata)', %i[read]],
    'lib/mb/sound/player/items.rb' => ['the player shows a file\'s ffmpeg tags (not mb-sound metadata)', %i[load_file]],
    'lib/mb/sound/wavetable.rb' => ['a wavetable file\'s own tags (its frame layout; file data, not mb-sound metadata)', %i[save]],
    'lib/mb/sound/latency_probe.rb' => 'the latency probe\'s own meta.json (its measurement header, not mb-sound metadata)',
    'lib/mb/sound/dropout_probe.rb' => 'the dropout probe\'s own report header (not mb-sound metadata)',
    'lib/mb/sound/dropout_probe/report.rb' => 'the dropout probe\'s own report header (not mb-sound metadata)',
  }.freeze

  # Reads of other things that share a name with metadata readers, in
  # files the rules would otherwise refuse (by "file: name", with why).
  NOT_METADATA = {
    'lib/mb/sound/library/index.rb: why' => 'a search hit\'s reasons, printed in the results table (Index::Hit#why)',
  }.freeze

  # Methods that render, plan, build, or look things up: no metadata read
  # may sit in one, whatever the file.
  FORBIDDEN_DEFS = %i[
    sample sample_c sample_ruby sample_all get_sampler plan_describe plan_ops plan_inputs plan_state
    find_by_name find_all_by_name resolve lookup build build_node load load_rack load_set eval_call call_args
    process_buffer render_buffer
  ].freeze

  # Files that may never read metadata: the plan layer and kernels, the
  # DSL method modules (they build graphs), the document loader, the
  # library's search and resolution, and Session names.
  FORBIDDEN_PATHS = [
    %r{\Alib/mb/sound/plan(/|\.rb\z)},
    %r{\Alib/mb/sound/kernels},
    %r{\Alib/mb/sound/graph_node/\w+_methods\.rb\z},
    %r{\Alib/mb/sound/graph_io/(loader|registry|file_guard)\.rb\z},
    %r{\Alib/mb/sound/library/(index|heads|finder|file_loader)\.rb\z},
    %r{\Alib/mb/sound/session/names\.rb\z},
  ].freeze

  # [file, line, enclosing method, what] for every metadata read in
  # +source+ (read from +file+).
  def self.reads(source, file)
    tree = Prism.parse(source).value
    out = []
    stack = [[tree, nil]]
    until stack.empty?
      n, d = stack.pop
      d = n.name if n.is_a?(Prism::DefNode)
      if n.is_a?(Prism::CallNode) && raw?(n)
        out << [file, n.location.start_line, d, n.name.to_s, :raw]
      elsif n.is_a?(Prism::CallNode) && READS.include?(n.name)
        out << [file, n.location.start_line, d, n.name.to_s]
      elsif n.is_a?(Prism::InstanceVariableReadNode) && n.name == :@carried_meta && file != 'lib/mb/sound/meta.rb'
        out << [file, n.location.start_line, d, '@carried_meta']
      end
      n.compact_child_nodes.each { |c| stack << [c, d] }
    end
    out.sort_by { |_, line, _, _| line }
  end

  # True if call +n+ reads raw facts.
  def self.raw?(n)
    return true if RAW_CALLS.include?(n.name)
    r = n.receiver&.slice.to_s
    RAW_RECEIVERS.any? { |name, re| (r == name || r.end_with?("::#{name}")) && n.name.to_s.match?(re) }
  end

  def self.all_reads
    @all_reads ||= Dir[File.join(ROOT, 'lib/**/*.rb')].sort.flat_map { |path|
      rel = path.delete_prefix("#{ROOT}/")
      reads(File.read(path), rel)
    }
  end

  def self.problems(reads)
    reads.filter_map do |file, line, d, what, layer|
      next if NOT_METADATA.key?("#{file}: #{what}")
      if layer == :raw
        allowed = ALLOWED_RAW[file]
        next if allowed && allowed[1].include?(d)
        next "#{file}:#{line}: reads raw facts (#{what}) in #{d ? "##{d}" : 'the file body'}, not an interpreter in ALLOWED_RAW: raw facts are read only by interpreters; use the typed data they make"
      end
      if FORBIDDEN_PATHS.any? { |re| file.match?(re) }
        "#{file}:#{line}: reads #{what} in a file that renders, builds, loads, or looks up (FORBIDDEN_PATHS)"
      elsif FORBIDDEN_DEFS.include?(d)
        "#{file}:#{line}: reads #{what} in ##{d}, a render, plan, build, or lookup method"
      elsif !ALLOWED.key?(file)
        "#{file}:#{line}: reads #{what} in #{d ? "##{d}" : 'the file body'}, a file not in ALLOWED (a printer or format adds itself with its reason; code that decides needs data, not metadata)"
      elsif ALLOWED[file].is_a?(Array) && !ALLOWED[file][1].include?(d)
        "#{file}:#{line}: reads #{what} in #{d ? "##{d}" : 'the file body'}, not one of the methods ALLOWED there (#{ALLOWED[file][1].join(', ')}): show it, or make the fact data"
      end
    end
  end

end

RSpec.describe('metadata guard: metadata never acts as data') do
  it 'finds metadata reads only in ALLOWED files, outside render, plan, build, and lookup code' do
    found = MetaGuard.problems(MetaGuard.all_reads)
    expect(found).to eq([]), "metadata acting as data?\n#{found.join("\n")}"
  end

  it 'lists only files that exist and read metadata' do
    reading = MetaGuard.all_reads.reject { |r| r[4] == :raw }.map(&:first).uniq
    raw = MetaGuard.all_reads.select { |r| r[4] == :raw }.map(&:first).uniq
    stale = MetaGuard::ALLOWED.keys.select { |f| File.exist?(File.join(MetaGuard::ROOT, f)) && !reading.include?(f) } +
            MetaGuard::ALLOWED_RAW.keys.reject { |f| raw.include?(f) }
    missing = MetaGuard::ALLOWED.keys.reject { |f| File.exist?(File.join(MetaGuard::ROOT, f)) }
    expect(stale).to eq([]), "ALLOWED files that no longer read metadata (remove them): #{stale.join(', ')}"
    expect(missing).to eq([])
  end

  it 'catches a read in a render method, a forbidden file, or an unlisted file' do
    src = <<~RUBY
      class X
        def sample(count)
          return @zeros if meta[:mute]
          @carried_meta
        end

        def summary = meta.notes.join
      end
    RUBY
    r = MetaGuard.reads(src, 'lib/mb/sound/x.rb')
    expect(r.map { |_, l, d, w| [l, d, w] }).to eq([[3, :sample, 'meta'], [4, :sample, '@carried_meta'], [7, :summary, 'meta']])
    p = MetaGuard.problems(r)
    expect(p.length).to eq(3)
    expect(p[0]).to include('in #sample, a render')
    expect(p[2]).to include('not in ALLOWED')
    expect(MetaGuard.problems(MetaGuard.reads("def x = doc.meta[:rack]\n", 'lib/mb/sound/graph_io/loader.rb'))[0]).to include('FORBIDDEN_PATHS')
    expect(MetaGuard.problems(MetaGuard.reads("def to_ruby = doc.meta[:rack]\n", 'lib/mb/sound/take.rb'))).to eq([])
    # (acid-loop-info-1's Sample#acid_one_shot? read meta[:one_shot] to decide #follow)
    one_shot = MetaGuard.problems(MetaGuard.reads("def acid_one_shot? = meta[:one_shot] == true\n", 'lib/mb/sound/sample.rb'))
    expect(one_shot[0]).to include('not one of the methods ALLOWED there')
  end

  it 'lets only interpreters read raw facts, and only printers read provenance' do
    src = <<~RUBY
      def follow = Riff.read(path).acid.tempo
      def stretch_to(x) = Facts.of_riff(riff)['acid.tempo']
      def loop_metadata = Sample::Riff.read(path)
      def sample(n) = provenance(:bpm).via == :acid ? 1 : 0
    RUBY
    r = MetaGuard.reads(src, 'lib/mb/sound/sample.rb')
    expect(r.map { |_, l, d, w, k| [l, d, w, k] }).to eq([[1, :follow, 'read', :raw], [2, :stretch_to, 'of_riff', :raw], [3, :loop_metadata, 'read', :raw], [4, :sample, 'provenance', nil]])
    p = MetaGuard.problems(r)
    expect(p.length).to eq(3)
    expect(p[0]).to include('reads raw facts (read) in #follow, not an interpreter')
    expect(p[2]).to include('in #sample, a render')
  end
end
